import AppKit
import Carbon.HIToolbox
import SwiftUI

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppState.shared.settings
    @ObservedObject private var history = AppState.shared.history
    @State private var selection: Section = .general
    @State private var isEnvironmentCheckExpanded = false
    @State private var copiedHistoryRecordID: UUID?
    @State private var historyCopyFeedbackToken = UUID()
    @State private var vocabularyDraft = ""
    @FocusState private var isVocabularyDraftFocused: Bool

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case models = "Models"
        case vocabulary = "Vocabulary"
        case history = "History"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "switch.2"
            case .models: "cpu"
            case .vocabulary: "text.book.closed"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WizardScroll")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let version = appVersion {
                        Text("v\(version)")
                            .font(.callout)
                    }
                }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("app-version")
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            Group {
                switch selection {
                case .general: general
                case .models: models
                case .vocabulary: vocabulary
                case .history: historyView
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .buttonStyle(SettingsButtonStyle())
        }
        .frame(minWidth: 680, minHeight: 500)
        .onAppear { appState.refreshEnvironment() }
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var general: some View {
        settingsPage(title: "General", subtitle: "Summon polished text with your voice") {
            environmentCheckCard

            SettingsCard {
                settingRow("Shortcut", detail: settings.dictationMode.instructions) {
                    ShortcutRecorder(settings: settings, appState: appState)
                }
                if !appState.shortcutError.isEmpty {
                    Text(appState.shortcutError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if settings.dictationShortcut.isModifierOnly, !appState.accessibilityGranted {
                    Text("\(settings.dictationShortcut.displayString) works in other apps once Accessibility access is allowed.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Divider()
                settingRow("Recording mode", detail: "Choose how the shortcut controls recording") {
                    Picker("Recording mode", selection: $settings.dictationMode) {
                        ForEach(DictationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

        }
    }

    private var models: some View {
        settingsPage(title: "Models", subtitle: "Choose your speech and text models") {
            SettingsCard {
                Label("Speech recognition", systemImage: "waveform")
                    .font(.headline)
                Text("Turns your recording into text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                HStack {
                    Picker("Model", selection: $settings.asrModel) {
                        ForEach(ASRModel.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    .accessibilityIdentifier("asr-model-picker")
                    asrModelAvailabilityIndicator
                }
                asrModelDownloadStatus
                Divider()
                Picker("Language", selection: $settings.language) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
            }

            SettingsCard {
                Label("Polish transcript", systemImage: "sparkles")
                    .font(.headline)
                Text("Removes filler, repetition and false starts.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if !appState.ollamaModels.isEmpty {
                    HStack {
                        Picker("Model", selection: ollamaModelSelection) {
                            ForEach(appState.ollamaModels) { model in
                                Text("\(model.name) · \(model.sizeLabel)").tag(model.name)
                            }
                        }
                        .accessibilityIdentifier("text-model-picker")
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Model ready")
                            .accessibilityIdentifier("text-model-ready")
                        modelSourceLabel("from Ollama")
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Model")
                        Text("\(BuiltInTextModel.title) · ~\(BuiltInTextModel.downloadSizeLabel)")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("built-in-text-model")
                        textModelAvailabilityIndicator
                        modelSourceLabel("built-in")
                    }
                    if appState.environmentStatus.isCheckingOllama, appState.environmentStatus.ollamaInstalled {
                        Text("Checking Ollama…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if appState.environmentStatus.ollamaInstalled, !appState.environmentStatus.ollamaRunning {
                        HStack {
                            Text("Ollama is not running. Open it to use your Ollama models.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Ollama") { appState.openOllama() }
                        }
                    }
                    textModelDownloadStatus
                }
                Divider()
                settingRow(
                    "System prompt",
                    detail: "Uses the Taiwan Traditional Chinese default unless you customize it"
                ) {
                    Button("Edit…") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "system-prompt")
                    }
                }
            }
        }
        .onChange(of: settings.asrModel) { _, _ in
            appState.ensureSelectedASRModelAvailable(retry: true)
        }
    }

    @ViewBuilder
    private var asrModelAvailabilityIndicator: some View {
        if appState.environmentStatus.runtimeReady,
           appState.environmentStatus.selectedASRModelReady,
           appState.preparingASRModel != settings.asrModel {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Speech model ready")
                .accessibilityIdentifier("asr-model-ready")
                .help("Model downloaded and ready")
        } else if !appState.asrModelDownloadError.isEmpty {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Speech model download failed")
                .help(appState.asrModelDownloadError)
        } else if appState.isInstallingRuntime {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Preparing speech model")
                .accessibilityIdentifier("asr-model-preparing")
        }
    }

    @ViewBuilder
    private var asrModelDownloadStatus: some View {
        if appState.isInstallingRuntime,
           !appState.environmentStatus.selectedASRModelReady || appState.preparingASRModel == settings.asrModel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appState.preparingASRModel != settings.asrModel
                         ? "Waiting to download \(settings.asrModel.title)…"
                         : appState.asrModelDownloadProgress?.stage == .downloading
                         ? "Downloading \(settings.asrModel.title)…"
                         : "Preparing speech recognition…")
                        .accessibilityIdentifier("asr-model-download-status")
                    Spacer()
                    if appState.preparingASRModel == settings.asrModel,
                       let fraction = appState.asrModelDownloadProgress?.fractionCompleted {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if appState.preparingASRModel == settings.asrModel,
                   let fraction = appState.asrModelDownloadProgress?.fractionCompleted {
                    ProgressView(value: fraction)
                }
            }
        } else if !appState.asrModelDownloadError.isEmpty {
            HStack {
                Text(appState.asrModelDownloadError)
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(appState.asrModelDownloadError)
                    .accessibilityIdentifier("asr-model-download-error")
                Spacer()
                Button("Retry download") {
                    appState.ensureSelectedASRModelAvailable(retry: true)
                }
                .accessibilityIdentifier("retry-asr-model-download")
            }
        }
    }

    /// Where the polishing model comes from, shown after its status icon.
    private func modelSourceLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("text-model-source")
    }

    @ViewBuilder
    private var textModelAvailabilityIndicator: some View {
        if appState.environmentStatus.builtInTextModelReady {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Model ready")
                .accessibilityIdentifier("text-model-ready")
                .help("Model downloaded and ready")
        } else if !appState.textModelDownloadError.isEmpty {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Model download failed")
                .help(appState.textModelDownloadError)
        } else if appState.isDownloadingTextModel {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Downloading model")
                .accessibilityIdentifier("text-model-preparing")
        }
    }

    @ViewBuilder
    private var textModelDownloadStatus: some View {
        if appState.isDownloadingTextModel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading \(BuiltInTextModel.title)…")
                        .accessibilityIdentifier("text-model-download-status")
                    Spacer()
                    if let fraction = appState.textModelDownloadProgress?.fractionCompleted {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let fraction = appState.textModelDownloadProgress?.fractionCompleted {
                    ProgressView(value: fraction)
                }
            }
        } else if !appState.textModelDownloadError.isEmpty {
            HStack {
                Text(appState.textModelDownloadError)
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("text-model-download-error")
                Spacer()
                Button("Retry download") {
                    appState.ensureBuiltInTextModelAvailable(retry: true, userRequested: true)
                }
                .disabled(!appState.environmentStatus.runtimeReady)
                .accessibilityIdentifier("retry-text-model-download")
            }
        }
    }

    private var environmentCheckCard: some View {
        SettingsCard {
            DisclosureGroup(isExpanded: $isEnvironmentCheckExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    environmentRow(
                        title: "Accessibility",
                        detail: appState.accessibilityGranted
                            ? "Automatic insertion is enabled"
                            : "Enable the installed app; re-add it if the Accessibility switch is already on",
                        ready: appState.accessibilityGranted
                    ) {
                        if !appState.accessibilityGranted {
                            Button("Open Settings") { appState.requestAccessibilityPermission() }
                        }
                    }

                    Divider()
                    environmentRow(
                        title: "Speech recognition runtime and model",
                        detail: asrEnvironmentDetail,
                        ready: appState.environmentStatus.runtimeReady
                            && appState.environmentStatus.selectedASRModelReady
                    ) {
                        if !appState.environmentStatus.runtimeReady
                            || !appState.environmentStatus.selectedASRModelReady {
                            Button(appState.isInstallingRuntime ? "Downloading…" : "Download") {
                                appState.installRuntime()
                            }
                            .disabled(appState.isInstallingRuntime)
                        }
                    }

                    Divider()
                    environmentRow(
                        title: "Text polishing model",
                        detail: polishingModelEnvironmentDetail,
                        ready: appState.polishingEngine != nil
                    ) {
                        if appState.environmentStatus.ollamaInstalled,
                           !appState.environmentStatus.ollamaRunning,
                           !appState.environmentStatus.isCheckingOllama {
                            Button("Open Ollama") { appState.openOllama() }
                        } else if appState.polishingEngine == nil,
                                  !appState.environmentStatus.isCheckingOllama,
                                  !appState.isDownloadingTextModel {
                            Button("Download") {
                                appState.ensureBuiltInTextModelAvailable(retry: true, userRequested: true)
                            }
                            .disabled(!appState.environmentStatus.runtimeReady)
                        }
                    }

                    if appState.isInstallingRuntime {
                        ProgressView().controlSize(.small)
                    }
                    if !appState.installerOutput.isEmpty {
                        Text(appState.installerOutput)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName: isEnvironmentReady
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .foregroundStyle(isEnvironmentReady ? Color.green : Color.red)
                    .accessibilityLabel(isEnvironmentReady ? "Environment ready" : "Environment needs attention")
                    Text("Environment check").fontWeight(.semibold)
                    Spacer()
                }
            }
            .disclosureGroupStyle(TrailingDisclosureGroupStyle {
                Button("Refresh") { appState.refreshEnvironment() }
            })
        }
    }

    private var vocabulary: some View {
        settingsPage(
            title: "Vocabulary",
            subtitle: "Help recognize names and specialized terms more accurately."
        ) {
            SettingsCard {
                VStack(spacing: 10) {
                    ForEach(settings.vocabularyEntries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("vocabulary-\(entry.id.uuidString)")

                            Button {
                                settings.removeVocabularyEntry(id: entry.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .help("Remove vocabulary entry")
                            .accessibilityLabel("Remove vocabulary entry")
                            .accessibilityIdentifier("remove-vocabulary-\(entry.id.uuidString)")
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("Word or phrase, Enter to confirm", text: $vocabularyDraft)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            .focused($isVocabularyDraftFocused)
                            .onSubmit { confirmVocabularyDraft() }
                            .accessibilityLabel("Vocabulary draft")
                            .accessibilityIdentifier("vocabulary-draft")

                        Button { confirmVocabularyDraft() } label: {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.medium))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Confirm vocabulary entry")
                        .accessibilityLabel("Confirm vocabulary entry")
                        .accessibilityIdentifier("confirm-vocabulary-entry")

                        Button {
                            vocabularyDraft = ""
                            isVocabularyDraftFocused = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(vocabularyDraft.isEmpty)
                        .help("Clear draft")
                        .accessibilityLabel("Clear vocabulary draft")
                        .accessibilityIdentifier("clear-vocabulary-draft")
                    }
                }
            }
        }
    }

    private func confirmVocabularyDraft() {
        guard settings.addVocabularyEntry(text: vocabularyDraft) != nil else { return }
        vocabularyDraft = ""
        isVocabularyDraftFocused = true
    }

    private var historyView: some View {
        settingsPage(title: "History", subtitle: "The latest 10 dictations stored only on this Mac") {
            if history.records.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform", description: Text("Use \(settings.dictationShortcut.displayString) in any app to begin."))
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                HStack {
                    Text("\(history.records.count) items").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", role: .destructive) { history.clear() }
                }
                LazyVStack(spacing: 10) {
                    ForEach(history.records) { record in
                        HistoryRecordCard(
                            record: record,
                            isCopied: copiedHistoryRecordID == record.id
                        ) {
                            guard HistoryRecordCard.copyTranscript(record) else {
                                NSSound.beep()
                                return
                            }
                            copiedHistoryRecordID = record.id
                            historyCopyFeedbackToken = UUID()
                        }
                    }
                }
            }
        }
        .task(id: historyCopyFeedbackToken) {
            guard copiedHistoryRecordID != nil else { return }
            let feedbackToken = historyCopyFeedbackToken
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard historyCopyFeedbackToken == feedbackToken else { return }
            copiedHistoryRecordID = nil
        }
        .onDisappear { copiedHistoryRecordID = nil }
    }

    private func settingsPage<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.bold())
                    if let subtitle {
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }
                content()
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func settingRow<Trailing: View>(
        _ title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }

    private var isEnvironmentReady: Bool {
        let speechReady = appState.environmentStatus.runtimeReady
            && appState.environmentStatus.selectedASRModelReady
        return appState.accessibilityGranted && speechReady && appState.polishingEngine != nil
    }

    private var asrEnvironmentDetail: String {
        if appState.isInstallingRuntime { return "Downloading into WizardScroll's private storage" }
        if !appState.environmentStatus.runtimeReady { return "Will be prepared automatically at launch" }
        if !appState.environmentStatus.selectedASRModelReady { return "Selected model will download automatically" }
        return "Runtime and selected speech model are ready"
    }

    private var polishingModelEnvironmentDetail: String {
        let status = appState.environmentStatus
        if status.isCheckingOllama, status.ollamaInstalled { return "Checking Ollama…" }
        if case .ollama(let name) = appState.polishingEngine { return "Using \(name) in Ollama" }
        if status.ollamaInstalled, !status.ollamaRunning {
            return status.builtInTextModelReady
                ? "Ollama is not running; using \(BuiltInTextModel.title)"
                : "Ollama is not running"
        }
        if appState.isDownloadingTextModel { return "Downloading \(BuiltInTextModel.title)…" }
        if !appState.textModelDownloadError.isEmpty { return appState.textModelDownloadError }
        if status.builtInTextModelReady { return "Using \(BuiltInTextModel.title)" }
        guard status.runtimeReady else { return "Downloads after the speech recognition runtime is ready" }
        return "\(BuiltInTextModel.title) will download automatically"
    }

    private var ollamaModelSelection: Binding<String> {
        Binding(
            get: { appState.selectedOllamaModel?.name ?? "" },
            set: { settings.ollamaModel = $0 }
        )
    }

    private func environmentRow<Action: View>(
        title: String,
        detail: String,
        ready: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? Color.green : Color.red)
                .accessibilityLabel(ready ? "Passed" : "Failed")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }
}

struct HistoryRecordCard: View {
    let record: DictationRecord
    let isCopied: Bool
    let onCopy: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 7) {
                Text(record.finalText)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                HStack {
                    Text(record.createdAt, style: .relative)
                    if let app = record.application { Text("· \(app)") }
                    Text("· \(record.language)")
                    Spacer(minLength: 8)
                    Label("Copied", systemImage: "checkmark")
                        .fontWeight(.medium)
                        .foregroundStyle(Color.primary)
                        .opacity(isCopied ? 1 : 0)
                        .accessibilityHidden(!isCopied)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary.opacity(0.5))
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.primary.opacity(isCopied ? 0.45 : (isHovered ? 0.18 : 0)),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Click to copy")
        .accessibilityIdentifier("history-\(record.id.uuidString)")
        .accessibilityLabel(record.finalText)
        .accessibilityValue(isCopied ? "Copied" : "")
        .accessibilityHint("Copy this transcript to the clipboard.")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @MainActor
    @discardableResult
    static func copyTranscript(_ record: DictationRecord, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(record.finalText, forType: .string)
    }
}

private struct TrailingDisclosureGroupStyle<Accessory: View>: DisclosureGroupStyle {
    @ViewBuilder let accessory: () -> Accessory

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // The accessory sits outside the toggle button so clicking it
                // does not expand or collapse the group.
                toggleButton(configuration) {
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                accessory()
                toggleButton(configuration) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }

            if configuration.isExpanded {
                configuration.content
            }
        }
    }

    private func toggleButton<Label: View>(
        _ configuration: Configuration,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                configuration.isExpanded.toggle()
            }
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
    }
}

/// Shows the dictation shortcut and records a new one when clicked.
private struct ShortcutRecorder: View {
    @ObservedObject var settings: AppSettings
    let appState: AppState
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if settings.dictationShortcut != .default, !isRecording {
                Button("Reset") { settings.dictationShortcut = .default }
                    .help("Use \(DictationShortcut.default.displayString)")
            }
            Button(isRecording ? "Type shortcut…" : settings.dictationShortcut.displayString) {
                isRecording ? stopRecording() : startRecording()
            }
            .help(isRecording
                  ? "Press a key with ⌘, ⌥ or ⌃, an F-key, or a right-hand modifier on its own. Esc cancels."
                  : "Click to change the shortcut")
            .accessibilityIdentifier("shortcut-recorder")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        // The global shortcut would swallow its own key press before this
        // window sees it, so release it while recording.
        appState.suspendHotKey()
        isRecording = true
        // A modifier is recorded on release, when no key was pressed with it.
        var loneModifier: DictationShortcut?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let flags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting(.capsLock)
                let modifier = DictationShortcut(modifierKeyCode: Int(event.keyCode))
                if let modifier, modifier.isModifierKeyDown(in: event) {
                    loneModifier = flags == modifier.modifierFlag ? modifier : nil
                } else if let modifier, modifier == loneModifier, flags.isEmpty {
                    settings.dictationShortcut = modifier
                    stopRecording()
                } else {
                    loneModifier = nil
                }
                return nil
            }
            loneModifier = nil
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let shortcut = DictationShortcut(event: event) {
                settings.dictationShortcut = shortcut
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        appState.resumeHotKey()
    }
}

/// The one size and shape for text buttons and value badges, so every page
/// lines up with the shortcut badge.
private extension View {
    func settingsControlChrome(
        background: some ShapeStyle = .quaternary,
        foreground: some ShapeStyle = .primary
    ) -> some View {
        font(.body.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, isProminent: isProminent)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .settingsControlChrome(
                    background: isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    foreground: isProminent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SystemPromptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppState.shared.settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("System prompt", systemImage: "text.quote")
                    .font(.title2.bold())
                Spacer()
                Button("Restore default") { settings.resetPolishingPrompt() }
                    .disabled(settings.polishingPrompt == TextPolishingPrompt.defaultInstructions)
            }

            Text("Customize how each transcript is polished.")
                .foregroundStyle(.secondary)

            TextEditor(text: $settings.polishingPrompt)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

            HStack(alignment: .firstTextBaseline) {
                Text("Vocabulary and the destination app are included automatically. A blank prompt uses the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SettingsButtonStyle(isProminent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380)
        .buttonStyle(SettingsButtonStyle())
    }
}
