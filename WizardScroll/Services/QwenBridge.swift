import Foundation

struct ASRResult {
    let text: String
    let language: String
}

struct ChatMessage: Codable, Equatable {
    let role: String
    let content: String
}

/// Generates text with a local model. The app uses `QwenBridge`; tests stub it.
@MainActor
protocol TextGenerating: AnyObject {
    /// Loads the model and computes the state after `messages`, the system
    /// prompt, so a later request that starts with them skips that work.
    func prepareTextModel(_ model: String, messages: [ChatMessage]) async throws
    func generateText(messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String
}

/// Runs the bundled Python bridge, which keeps Qwen3-ASR and the selected
/// Qwen text model loaded on MLX between requests.
@MainActor
final class QwenBridge: TextGenerating {
    private struct Request: Encodable {
        let id: String
        let type: String
        var audio: String?
        var model: String
        var language: String?
        var context: String?
        var messages: [ChatMessage]?
        var maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case id, type, audio, model, language, context, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct Response: Decodable {
        let id: String?
        let type: String
        let text: String?
        let language: String?
        let error: String?
    }

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = ""
    private var pending: [String: CheckedContinuation<Response, Error>] = [:]

    func transcribe(
        audioURL: URL,
        model: String,
        language: String?,
        vocabulary: String
    ) async throws -> ASRResult {
        NSLog("Qwen ASR request started: %@", audioURL.lastPathComponent)
        let response = try await send(Request(
            id: UUID().uuidString,
            type: "transcribe",
            audio: audioURL.path,
            model: model,
            language: language,
            context: vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ))
        guard response.type == "transcript", let text = response.text else { throw RuntimeError.invalidResponse }
        NSLog("Qwen ASR completed: %ld characters", text.count)
        return ASRResult(text: text, language: response.language ?? "Unknown")
    }

    func prepareTextModel(_ model: String, messages: [ChatMessage]) async throws {
        _ = try await send(Request(
            id: UUID().uuidString,
            type: "prepare_text_model",
            model: model,
            messages: messages
        ))
    }

    func generateText(messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
        let response = try await send(Request(
            id: UUID().uuidString,
            type: "polish",
            model: model,
            messages: messages,
            maxTokens: maxTokens
        ))
        guard response.type == "polished", let text = response.text else { throw RuntimeError.invalidResponse }
        return text
    }

    func shutdown() {
        process?.terminate()
        process = nil
        input = nil
        failAll(with: RuntimeError.processStopped("App is closing"))
    }

    private func send(_ request: Request) async throws -> Response {
        try startIfNeeded()
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        let response: Response = try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            do {
                try input?.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: request.id)
                continuation.resume(throwing: error)
            }
        }
        if response.type == "error" {
            let message = response.error ?? "Unknown error"
            NSLog("Qwen bridge request failed: %@", message)
            throw RuntimeError.processStopped(message)
        }
        return response
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }

        let state = RuntimeLocator.currentState()
        guard let pythonURL = state.pythonURL else { throw RuntimeError.missingPython }
        guard let bridgeURL = state.bridgeURL else { throw RuntimeError.missingBridge }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = pythonURL
        process.arguments = ["-u", bridgeURL.path]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = RuntimeLocator.processEnvironment(adding: [
            "HF_HOME": RuntimeLocator.huggingFaceHome.path,
            "HF_HUB_OFFLINE": "1",
            "PYTHONUNBUFFERED": "1"
        ])

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let string = String(data: data, encoding: .utf8), !string.isEmpty else { return }
            Task { @MainActor in self?.errorBuffer.append(string) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.input = nil
                self.failAll(with: RuntimeError.processStopped(self.errorBuffer.nilIfEmpty ?? "exit \(process.terminationStatus)"))
            }
        }

        try FileManager.default.createDirectory(
            at: RuntimeLocator.huggingFaceHome,
            withIntermediateDirectories: true
        )
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        errorBuffer = ""
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let response = try? JSONDecoder().decode(Response.self, from: Data(line)),
                  let id = response.id,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            continuation.resume(returning: response)
        }
    }

    private func failAll(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
