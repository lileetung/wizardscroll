import AppKit
import AVFoundation
import Combine
import Foundation

struct EnvironmentStatus: Equatable {
    var runtimeReady = false
    var selectedASRModelReady = false
    var builtInTextModelReady = false
    var ollamaInstalled = false
    var ollamaRunning = false
    var isCheckingOllama = true
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case polishing
        case inserting
        case success
        case copied
        case failure(String)

        var menuBarSymbol: String {
            switch self {
            case .recording: "waveform.circle.fill"
            case .transcribing, .polishing, .inserting: "ellipsis.circle"
            case .success: "checkmark.circle.fill"
            case .copied: "doc.on.clipboard"
            case .failure: "exclamationmark.circle.fill"
            case .idle: "waveform.circle"
            }
        }

        var title: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Listening…"
            case .transcribing: "Transcribing…"
            case .polishing: "Polishing text…"
            case .inserting: "Pasting…"
            case .success: "Pasted"
            case .copied: "Copied — ⌘V to paste"
            case .failure(let message): message
            }
        }

        var isBusy: Bool {
            switch self {
            case .transcribing, .polishing, .inserting: true
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { NSLog("WizardScroll phase: %@", phase.title) }
    }
    @Published private(set) var runtimeState: RuntimeState = RuntimeLocator.currentState()
    @Published private(set) var lastTranscript = ""
    @Published private(set) var accessibilityGranted = false {
        didSet {
            // A modifier-only shortcut is watched with an event monitor, which
            // is set up again once Accessibility access arrives.
            if accessibilityGranted, !oldValue, !isHotKeySuspended, settings.dictationShortcut.isModifierOnly {
                registerHotKey(settings.dictationShortcut)
            }
        }
    }
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastFailureDetail = ""
    @Published private(set) var installerOutput = ""
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var preparingASRModel: ASRModel?
    @Published private(set) var asrModelDownloadProgress: RuntimeInstallProgress?
    @Published private(set) var asrModelDownloadError = ""
    @Published private(set) var ollamaModels: [OllamaModel] = []
    @Published private(set) var isDownloadingTextModel = false
    @Published private(set) var textModelDownloadProgress: RuntimeInstallProgress?
    @Published private(set) var textModelDownloadError = ""
    @Published private(set) var environmentStatus = EnvironmentStatus()
    @Published private(set) var shortcutError = ""

    let settings: AppSettings
    let history = DictationHistoryStore()

    var selectedOllamaModel: OllamaModel? {
        ollamaModels.first { $0.name == settings.ollamaModel } ?? OllamaModel.preferred(in: ollamaModels)
    }

    /// The user's Ollama models come first, so WizardScroll does not download
    /// another copy of a model they already have. The built-in model is the
    /// fallback when Ollama has none, or is not reachable.
    var polishingEngine: PolishingEngine? {
        if let model = selectedOllamaModel { return .ollama(model.name) }
        return environmentStatus.builtInTextModelReady ? .builtIn : nil
    }

    /// The built-in model is needed only without Ollama, or when Ollama runs
    /// but has no local text model. An Ollama that is installed but not yet
    /// running is opened instead.
    var needsBuiltInTextModel: Bool {
        guard !environmentStatus.isCheckingOllama else { return false }
        if environmentStatus.ollamaRunning { return ollamaModels.isEmpty }
        return !environmentStatus.ollamaInstalled
    }

    private let recorder = AudioRecorder()
    private let hotKey = GlobalHotKey()
    private let asr: QwenBridge
    private let polisher: TextPolisher
    private let ollama: OllamaClient
    private let isOllamaInstalled: () -> Bool
    private let textModelStore: TextModelStore
    private let paster = AccessibilityPaster()
    private var targetApplication: String?
    private var didStart = false
    private var didAttemptAutomaticRuntimeInstall = false
    private var automaticASRModelAttempts: Set<ASRModel> = []
    private var phaseResetTask: Task<Void, Never>?
    private var textModelDownloadTask: Task<Void, Never>?
    private var didAttemptAutomaticTextModelDownload = false
    private var shortcutObserver: AnyCancellable?
    private var isHotKeySuspended = false
    private var isStartingRecording = false
    /// When the shortcut went down in hold mode; nil while it is not held.
    private var holdStartedAt: Date?
    /// A hold that ended while the microphone was still starting.
    private var pendingHoldRelease: HoldRelease?

    private enum HoldRelease {
        case transcribe
        case cancel
    }

    /// Releases shorter than this are treated as accidental taps.
    private static let minimumHoldDuration: TimeInterval = 0.3

    init(
        settings: AppSettings? = nil,
        builtInGenerator: TextGenerating? = nil,
        ollama: OllamaClient = OllamaClient(),
        isOllamaInstalled: @escaping () -> Bool = { OllamaClient.isInstalled },
        textModelStore: TextModelStore = .live
    ) {
        self.settings = settings ?? AppSettings()
        let bridge = QwenBridge()
        asr = bridge
        self.ollama = ollama
        self.isOllamaInstalled = isOllamaInstalled
        polisher = TextPolisher(builtIn: builtInGenerator ?? bridge, ollama: ollama)
        self.textModelStore = textModelStore
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        registerHotKey(settings.dictationShortcut)
        // `$dictationShortcut` publishes before the property changes, so use
        // the value it delivers rather than reading the setting back.
        shortcutObserver = settings.$dictationShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shortcut in self?.registerHotKey(shortcut) }
        refreshEnvironment(autoInstallManagedComponents: true)
    }

    /// Releases the global shortcut so the shortcut recorder can capture any
    /// key combination, including the current one.
    func suspendHotKey() {
        isHotKeySuspended = true
        hotKey.unregister()
    }

    func resumeHotKey() {
        isHotKeySuspended = false
        registerHotKey(settings.dictationShortcut)
    }

    private func registerHotKey(_ shortcut: DictationShortcut) {
        do {
            try hotKey.register(
                shortcut,
                onPress: { [weak self] in Task { @MainActor in self?.hotKeyPressed() } },
                onRelease: { [weak self] in Task { @MainActor in self?.hotKeyReleased() } },
                onCancel: { [weak self] in Task { @MainActor in self?.hotKeyCancelled() } }
            )
            shortcutError = ""
        } catch {
            shortcutError = "\(shortcut.displayString) is unavailable: \(error.localizedDescription)"
            LocalDiagnostics.append(shortcutError)
        }
    }

    private func hotKeyPressed() {
        switch settings.dictationMode {
        case .toggle:
            // A lone modifier acts on release, once it is clear that it was not
            // the start of a key combination.
            if !settings.dictationShortcut.isModifierOnly { toggleDictation() }
        case .hold:
            // Ignore key repeat while the shortcut stays down.
            guard holdStartedAt == nil else { return }
            switch phase {
            case .idle, .success, .copied, .failure:
                holdStartedAt = .now
                pendingHoldRelease = nil
                beginRecording()
            case .recording, .transcribing, .polishing, .inserting:
                break
            }
        }
    }

    private func hotKeyReleased() {
        if settings.dictationMode == .toggle, settings.dictationShortcut.isModifierOnly {
            toggleDictation()
            return
        }
        guard let startedAt = holdStartedAt else { return }
        holdStartedAt = nil
        let release: HoldRelease = Date.now.timeIntervalSince(startedAt) < Self.minimumHoldDuration
            ? .cancel
            : .transcribe
        if isStartingRecording {
            pendingHoldRelease = release
        } else {
            finishHold(release)
        }
    }

    /// The modifier-only shortcut was part of a key combination, so a
    /// recording it started while held is discarded.
    private func hotKeyCancelled() {
        guard holdStartedAt != nil else { return }
        holdStartedAt = nil
        if isStartingRecording {
            pendingHoldRelease = .cancel
        } else {
            finishHold(.cancel)
        }
    }

    private func finishHold(_ release: HoldRelease) {
        guard case .recording = phase else { return }
        switch release {
        case .transcribe: stopAndTranscribe()
        case .cancel: cancelRecording()
        }
    }

    func shutdown() {
        phaseResetTask?.cancel()
        textModelDownloadTask?.cancel()
        hotKey.unregister()
        recorder.cancel()
        asr.shutdown()
    }

    func toggleDictation() {
        switch phase {
        case .recording:
            stopAndTranscribe()
        case .idle, .success, .copied, .failure:
            beginRecording()
        case .transcribing, .polishing, .inserting:
            break
        }
    }

    func cancelRecording() {
        recorder.cancel()
        audioLevel = 0
        phase = .idle
    }

    func requestAccessibilityPermission() {
        paster.openPermissionSettings()
        accessibilityGranted = paster.isTrusted
    }

    func refreshPermissions() {
        accessibilityGranted = paster.isTrusted
    }

    func refreshEnvironment() {
        refreshEnvironment(autoInstallManagedComponents: false)
    }

    private func refreshEnvironment(autoInstallManagedComponents: Bool) {
        let newRuntimeState = RuntimeLocator.currentState()
        runtimeState = newRuntimeState
        refreshPermissions()
        environmentStatus.runtimeReady = newRuntimeState.isReady
        environmentStatus.selectedASRModelReady = RuntimeLocator.isModelInstalled(settings.asrModel.modelID)
        environmentStatus.builtInTextModelReady = textModelStore.isInstalled()
        environmentStatus.ollamaInstalled = isOllamaInstalled()
        environmentStatus.isCheckingOllama = true

        if autoInstallManagedComponents,
           !didAttemptAutomaticRuntimeInstall,
           !environmentStatus.runtimeReady {
            didAttemptAutomaticRuntimeInstall = true
            installRuntime(automatic: true)
        }
        if environmentStatus.runtimeReady {
            ensureSelectedASRModelAvailable()
        }

        Task {
            await checkOllama()
            if autoInstallManagedComponents,
               environmentStatus.ollamaInstalled,
               !environmentStatus.ollamaRunning {
                openOllama()
            }
            ensureBuiltInTextModelAvailable()
        }
    }

    private func checkOllama() async {
        do {
            ollamaModels = try await ollama.availableModels()
            environmentStatus.ollamaRunning = true
        } catch {
            ollamaModels = []
            environmentStatus.ollamaRunning = false
        }
        environmentStatus.isCheckingOllama = false
    }

    /// Downloads the built-in model when nothing else can polish. `retry`
    /// allows another attempt after a failure; `userRequested` downloads it
    /// even though Ollama is installed.
    func ensureBuiltInTextModelAvailable(retry: Bool = false, userRequested: Bool = false) {
        if retry { textModelDownloadError = "" }
        environmentStatus.builtInTextModelReady = textModelStore.isInstalled()
        guard !environmentStatus.builtInTextModelReady, textModelStore.canDownload() else { return }
        guard !isDownloadingTextModel else { return }
        guard userRequested || needsBuiltInTextModel else { return }
        guard retry || userRequested || !didAttemptAutomaticTextModelDownload else { return }
        didAttemptAutomaticTextModelDownload = true
        isDownloadingTextModel = true
        textModelDownloadProgress = nil
        textModelDownloadError = ""
        textModelDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await textModelStore.download { [weak self] progress in
                    self?.textModelDownloadProgress = progress
                }
            } catch {
                textModelDownloadError = error.localizedDescription
            }
            isDownloadingTextModel = false
            textModelDownloadTask = nil
            textModelDownloadProgress = nil
            refreshEnvironment()
        }
    }

    func installRuntime() {
        installRuntime(automatic: false)
    }

    func ensureSelectedASRModelAvailable(retry: Bool = false) {
        environmentStatus.selectedASRModelReady = RuntimeLocator.isModelInstalled(settings.asrModel.modelID)
        if retry { asrModelDownloadError = "" }
        guard !environmentStatus.runtimeReady || !environmentStatus.selectedASRModelReady else { return }
        guard retry || !automaticASRModelAttempts.contains(settings.asrModel) else { return }
        installRuntime(automatic: true)
    }

    private func installRuntime(automatic: Bool) {
        guard !isInstallingRuntime else { return }
        let model = settings.asrModel
        automaticASRModelAttempts.insert(model)
        isInstallingRuntime = true
        preparingASRModel = model
        asrModelDownloadProgress = nil
        asrModelDownloadError = ""
        installerOutput = automatic
            ? "Preparing the selected speech recognition model…"
            : "Preparing the speech recognition runtime…"
        Task {
            do {
                let output = try await RuntimeInstaller.install(modelID: model.modelID) { progress in
                    self.asrModelDownloadProgress = progress
                }
                installerOutput = output
            } catch {
                installerOutput = error.localizedDescription
                if settings.asrModel == model {
                    asrModelDownloadError = error.localizedDescription
                }
            }
            isInstallingRuntime = false
            preparingASRModel = nil
            asrModelDownloadProgress = nil
            refreshEnvironment()
            if settings.asrModel != model {
                ensureSelectedASRModelAvailable()
            }
        }
    }

    func openOllama() {
        guard let applicationURL = OllamaClient.applicationURL else { return }
        NSWorkspace.shared.open(applicationURL)
        Task {
            // Ollama takes a few seconds to start its local service.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if (try? await ollama.availableModels()) != nil { break }
            }
            refreshEnvironment()
        }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        _ = paster.copyToClipboard(lastTranscript)
    }

    func revealDiagnostics() {
        LocalDiagnostics.ensureFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([LocalDiagnostics.fileURL])
    }

    private func beginRecording() {
        guard !phase.isBusy, !isStartingRecording else { return }
        runtimeState = RuntimeLocator.currentState()
        guard runtimeState.isReady else {
            phase = .failure("Set up speech recognition in General first")
            return
        }
        guard RuntimeLocator.isModelInstalled(settings.asrModel.modelID) else {
            phase = .failure("Download the selected speech model in General first")
            return
        }

        isStartingRecording = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                isStartingRecording = false
                if let release = pendingHoldRelease {
                    pendingHoldRelease = nil
                    finishHold(release)
                }
            }
            guard await AudioRecorder.requestMicrophonePermission() else {
                phase = .failure("Microphone permission is required")
                return
            }

            do {
                let frontmostApplication = NSWorkspace.shared.frontmostApplication
                targetApplication = frontmostApplication?.localizedName
                paster.prepareForInsertion(into: frontmostApplication)
                prepareTextModel()
                lastFailureDetail = ""
                LocalDiagnostics.append("Recording started; target=\(targetApplication ?? "unknown")")
                try recorder.start { [weak self] level in
                    DispatchQueue.main.async {
                        self?.audioLevel = level
                    }
                }
                phase = .recording(startedAt: .now)
            } catch {
                fail(stage: "Recording", error: error)
            }
        }
    }

    private func stopAndTranscribe() {
        let audioURL: URL
        do {
            audioURL = try recorder.stop()
            audioLevel = 0
        } catch {
            fail(stage: "Recording", error: error)
            return
        }

        phase = .transcribing
        let currentSettings = settings.snapshot
        let polishingEngine = polishingEngine
        let appName = targetApplication

        Task {
            defer { try? FileManager.default.removeItem(at: audioURL) }

            do {
                let result = try await asr.transcribe(
                    audioURL: audioURL,
                    model: currentSettings.asrModel.modelID,
                    language: currentSettings.language.runtimeValue,
                    vocabulary: currentSettings.vocabulary
                )
                let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawText.isEmpty else { throw DictationError.emptyTranscript }
                LocalDiagnostics.append("ASR completed; language=\(result.language); characters=\(rawText.count)")

                var finalText = rawText
                var wasPolished = false
                var note: String?

                phase = .polishing
                if let polishingEngine {
                    let polishingStartedAt = Date.now
                    do {
                        finalText = try await polisher.polish(
                            rawText,
                            engine: polishingEngine,
                            instructions: currentSettings.polishingPrompt,
                            targetApplication: appName,
                            vocabulary: currentSettings.vocabulary
                        )
                        wasPolished = true
                        let seconds = Date.now.timeIntervalSince(polishingStartedAt)
                        LocalDiagnostics.append("Polishing completed in \(String(format: "%.1f", seconds)) s; model=\(polishingEngine.title)")
                    } catch {
                        note = "Local text polishing failed; inserted raw transcript."
                        LocalDiagnostics.append("Polishing failed: \(error.localizedDescription)")
                        // Ollama may have quit; recheck so the next dictation
                        // reopens it or falls back to the built-in model.
                        refreshEnvironment()
                    }
                } else {
                    note = "Text model is not ready; inserted raw transcript."
                }

                // Keep the recognized text before attempting the macOS paste.
                // Accessibility can fail independently of ASR, and must never
                // make a successful local transcription disappear.
                lastTranscript = finalText
                phase = .inserting
                do {
                    try await paster.insert(finalText)
                    recordDictation(
                        rawText: rawText,
                        finalText: finalText,
                        language: result.language,
                        application: appName,
                        wasPolished: wasPolished,
                        note: note
                    )
                    accessibilityGranted = paster.isTrusted
                    phase = .success
                    resetPhaseSoon()
                } catch {
                    let copied = paster.copyToClipboard(finalText)
                    accessibilityGranted = paster.isTrusted
                    let pasteNote = copied
                        ? "Transcript copied for manual paste. \(error.localizedDescription)"
                        : "Automatic paste and clipboard copy both failed."
                    recordDictation(
                        rawText: rawText,
                        finalText: finalText,
                        language: result.language,
                        application: appName,
                        wasPolished: wasPolished,
                        note: [note, pasteNote].compactMap { $0 }.joined(separator: " ")
                    )
                    if copied {
                        lastFailureDetail = ""
                        LocalDiagnostics.append("Transcript copied for manual paste; reason=\(error.localizedDescription)")
                        phase = .copied
                        resetPhaseSoon(after: .seconds(3))
                    } else {
                        fail(stage: "Automatic paste", error: error)
                    }
                }
            } catch DictationError.emptyTranscript {
                // Silence is not a fault to investigate, so the HUD message is
                // enough and General shows nothing.
                lastFailureDetail = ""
                LocalDiagnostics.append("No speech detected")
                phase = .failure(DictationError.emptyTranscript.localizedDescription)
                resetPhaseSoon(after: .seconds(3))
            } catch {
                fail(stage: "Speech recognition", error: error)
            }
        }
    }

    /// Loads the text model and reads the system prompt for this destination
    /// app while the user speaks, so polishing does not wait for either. Both
    /// stay cached in the bridge, so repeat dictations skip this work.
    private func prepareTextModel() {
        guard let engine = polishingEngine else { return }
        let currentSettings = settings.snapshot
        let appName = targetApplication
        Task {
            do {
                try await polisher.prepare(
                    engine,
                    instructions: currentSettings.polishingPrompt,
                    targetApplication: appName,
                    vocabulary: currentSettings.vocabulary
                )
            } catch {
                LocalDiagnostics.append("Text model preparation failed: \(error.localizedDescription)")
            }
        }
    }

    private func fail(stage: String, error: Error) {
        fail(stage: stage, message: error.localizedDescription)
    }

    private func fail(stage: String, message: String) {
        lastFailureDetail = "\(stage): \(message)"
        LocalDiagnostics.append(lastFailureDetail)
        NSLog("WizardScroll failure: %@", lastFailureDetail)
        phase = .failure(message)
    }

    private func recordDictation(
        rawText: String,
        finalText: String,
        language: String,
        application: String?,
        wasPolished: Bool,
        note: String?
    ) {
        history.add(
            rawText: rawText,
            finalText: finalText,
            language: language,
            application: application,
            wasPolished: wasPolished,
            note: note
        )
    }

    private func resetPhaseSoon(after delay: Duration = .seconds(1.2)) {
        phaseResetTask?.cancel()
        let completedPhase = phase
        phaseResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, phase == completedPhase else { return }
            phase = .idle
            phaseResetTask = nil
        }
    }
}

enum DictationError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "No speech was detected."
        }
    }
}

private enum LocalDiagnostics {
    static let fileURL = RuntimeLocator.applicationSupportDirectory
        .appendingPathComponent("diagnostics.log")

    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Unable to create diagnostics log: %@", error.localizedDescription)
        }
    }

    static func append(_ message: String) {
        ensureFileExists()
        let timestamp = ISO8601DateFormatter().string(from: .now)
        guard let data = "[\(timestamp)] \(message)\n".data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("Unable to write diagnostics log: %@", error.localizedDescription)
        }
    }
}
