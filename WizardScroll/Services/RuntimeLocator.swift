import Foundation

struct RuntimeState: Equatable {
    let pythonURL: URL?
    let bridgeURL: URL?

    var isReady: Bool { pythonURL != nil && bridgeURL != nil }
    var label: String { isReady ? "Local runtime ready" : "Local runtime not installed" }
}

enum RuntimeLocator {
    static let applicationSupportDirectory: URL = {
        #if DEBUG
        if let testDirectory = ProcessInfo.processInfo.environment["WIZARDSCROLL_APP_SUPPORT"],
           testDirectory.hasPrefix("/") {
            return URL(fileURLWithPath: testDirectory, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WizardScroll", isDirectory: true)
    }()

    static var pythonURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("runtime/.venv/bin/python3")
    }

    /// Matches RUNTIME_VERSION in bootstrap-runtime.sh, which writes it to the
    /// ready marker after installing that version's packages.
    static let runtimeVersion = "2"

    static var runtimeReadyMarkerURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("runtime/.ready")
    }

    static var huggingFaceHome: URL {
        applicationSupportDirectory.appendingPathComponent("Models/huggingface", isDirectory: true)
    }

    /// GUI applications launched by Finder inherit a minimal PATH that omits
    /// Homebrew and user-local tools. Keep every local-runtime subprocess on
    /// one deterministic search path instead of relying on the launch shell.
    static func executableSearchPath(inheritedPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            NSHomeDirectory() + "/.local/bin"
        ]
        if let inheritedPath {
            candidates.append(contentsOf: inheritedPath.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        return candidates
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    static func processEnvironment(adding values: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executableSearchPath(inheritedPath: environment["PATH"])
        values.forEach { environment[$0.key] = $0.value }
        return environment
    }

    static func executableURL(named name: String) -> URL? {
        for directory in executableSearchPath().split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func bridgeURL() -> URL? {
        Bundle.main.url(forResource: "qwen_bridge", withExtension: "py")
    }

    static func installerURL() -> URL? {
        Bundle.main.url(forResource: "bootstrap-runtime", withExtension: "sh")
    }

    static func currentState() -> RuntimeState {
        let marker = try? String(contentsOf: runtimeReadyMarkerURL, encoding: .utf8)
        let runtimeComplete = marker?.trimmingCharacters(in: .whitespacesAndNewlines) == runtimeVersion
        let python = runtimeComplete && FileManager.default.isExecutableFile(atPath: pythonURL.path)
            ? pythonURL
            : nil
        return RuntimeState(pythonURL: python, bridgeURL: bridgeURL())
    }

    static func isModelInstalled(_ modelID: String) -> Bool {
        let cacheName = "models--" + modelID.split(separator: "/").joined(separator: "--")
        let snapshots = huggingFaceHome
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return false }
        return revisions.contains(where: hasCompleteWeights)
    }

    /// The Hub links a file into a snapshot only after it finishes downloading.
    /// Sharded models list their shards in an index, and every shard must be
    /// present; single-file models use one of the conventional names.
    private static func hasCompleteWeights(in revision: URL) -> Bool {
        let fileManager = FileManager.default
        let index = revision.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = object["weight_map"] as? [String: String] {
            let shards = Set(weightMap.values)
            return !shards.isEmpty && shards.allSatisfy {
                fileManager.fileExists(atPath: revision.appendingPathComponent($0).path)
            }
        }
        return ["weights.safetensors", "model.safetensors"].contains {
            fileManager.fileExists(atPath: revision.appendingPathComponent($0).path)
        }
    }
}

struct RuntimeInstallProgress: Decodable, Equatable, Sendable {
    enum Stage: String, Decodable, Sendable {
        case runtime
        case downloading
        case complete
    }

    let stage: Stage
    let completed: UInt64?
    let total: UInt64?

    var fractionCompleted: Double? {
        guard stage == .downloading, let completed, let total, total > 0 else { return nil }
        return min(Double(completed) / Double(total), 1)
    }
}

struct RuntimeInstallOutput {
    private var pending = Data()
    private(set) var output = ""

    mutating func append(_ data: Data, finishing: Bool = false) -> [RuntimeInstallProgress] {
        pending.append(data)
        var progress: [RuntimeInstallProgress] = []
        while let newline = pending.firstIndex(of: 10) {
            consume(Data(pending[..<newline]), progress: &progress)
            pending.removeSubrange(...newline)
        }
        if finishing, !pending.isEmpty {
            consume(pending, progress: &progress)
            pending.removeAll()
        }
        return progress
    }

    private mutating func consume(_ data: Data, progress: inout [RuntimeInstallProgress]) {
        let line = String(decoding: data, as: UTF8.self)
        let prefix = "WIZARDSCROLL_PROGRESS "
        if line.hasPrefix(prefix),
           let event = try? JSONDecoder().decode(
               RuntimeInstallProgress.self, from: Data(line.dropFirst(prefix.count).utf8)
           ) {
            progress.append(event)
        } else {
            output += line + "\n"
        }
    }
}

enum RuntimeInstaller {
    static func install(
        modelID: String,
        onProgress: @escaping @MainActor @Sendable (RuntimeInstallProgress) -> Void = { _ in }
    ) async throws -> String {
        guard let scriptURL = RuntimeLocator.installerURL() else {
            throw RuntimeError.missingInstaller
        }
        return try await run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, modelID],
            environment: RuntimeLocator.processEnvironment(adding: [
                "WIZARDSCROLL_APP_SUPPORT": RuntimeLocator.applicationSupportDirectory.path,
                "PYTHONUNBUFFERED": "1",
                // The installer output is shown as plain text in Settings.
                "NO_COLOR": "1"
            ]),
            onProgress: onProgress
        )
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onProgress: @escaping @MainActor @Sendable (RuntimeInstallProgress) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.environment = environment
            let termination = AsyncStream<Int32> { continuation in
                process.terminationHandler = { finishedProcess in
                    continuation.yield(finishedProcess.terminationStatus)
                    continuation.finish()
                }
            }
            try process.run()
            try output.fileHandleForWriting.close()
            defer { try? output.fileHandleForReading.close() }
            var parser = RuntimeInstallOutput()
            while true {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                for progress in parser.append(data) {
                    await onProgress(progress)
                }
            }
            for progress in parser.append(Data(), finishing: true) {
                await onProgress(progress)
            }
            // Progress callbacks can resume on a different executor thread. Wait
            // asynchronously instead of relying on Process's creating run loop.
            var terminationIterator = termination.makeAsyncIterator()
            guard await terminationIterator.next() == 0 else {
                throw RuntimeError.installFailed(parser.output)
            }
            return parser.output
        }.value
    }
}

enum RuntimeError: LocalizedError {
    case missingBridge
    case missingPython
    case missingInstaller
    case installFailed(String)
    case processStopped(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBridge: "The bundled speech recognition bridge is missing"
        case .missingPython: "Set up the speech recognition runtime in General"
        case .missingInstaller: "The bundled runtime installer is missing"
        case .installFailed(let output): "Runtime installation failed.\n\(output)"
        case .processStopped(let reason): "Speech recognition stopped: \(reason)"
        case .invalidResponse: "Speech recognition returned an invalid response"
        }
    }
}
