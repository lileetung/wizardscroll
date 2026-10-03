import Carbon.HIToolbox
import Combine
import Foundation

enum ASRModel: String, CaseIterable, Identifiable, Codable {
    case fast
    case accurate

    var id: String { rawValue }

    /// The repository's own model name, as it is downloaded.
    var title: String { String(modelID.split(separator: "/").last ?? "") }

    var modelID: String {
        switch self {
        case .fast: "moona3k/mlx-qwen3-asr-0.6b-4bit"
        case .accurate: "moona3k/mlx-qwen3-asr-1.7b-4bit"
        }
    }
}

enum DictationLanguage: String, CaseIterable, Identifiable, Codable {
    case automatic
    case chinese
    case english
    case cantonese
    case japanese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .chinese: "中文"
        case .english: "English"
        case .cantonese: "粵語"
        case .japanese: "日本語"
        }
    }

    var runtimeValue: String? {
        switch self {
        case .automatic: nil
        case .chinese: "Chinese"
        case .english: "English"
        case .cantonese: "Cantonese"
        case .japanese: "Japanese"
        }
    }
}

enum DictationMode: String, CaseIterable, Identifiable, Codable {
    case toggle
    case hold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: "Press to toggle"
        case .hold: "Hold to talk"
        }
    }

    var instructions: String {
        switch self {
        case .toggle: "Press once to record, then again to transcribe"
        case .hold: "Hold to record, release to transcribe"
        }
    }
}

/// A global shortcut stored as a Carbon key code and modifier mask, which is
/// what `RegisterEventHotKey` takes. A right-hand modifier key with no other
/// modifiers is a shortcut on its own, pressed by itself.
struct DictationShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key as shown to the user, captured when the shortcut is recorded so
    /// it matches the keyboard layout it was typed on.
    var keyLabel: String

    static let `default` = DictationShortcut(modifierKeyCode: kVK_RightOption)!

    /// The modifier keys that can be a shortcut on their own. Only the right
    /// ones qualify: the left ones are held too often while typing.
    static let modifierKeyLabels: [Int: String] = [
        kVK_RightOption: "Right ⌥", kVK_RightCommand: "Right ⌘",
        kVK_RightControl: "Right ⌃", kVK_RightShift: "Right ⇧"
    ]

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(modifierKeyCode: Int) {
        guard let label = Self.modifierKeyLabels[modifierKeyCode] else { return nil }
        self.init(keyCode: UInt32(modifierKeyCode), modifiers: 0, keyLabel: label)
    }

    var isModifierOnly: Bool {
        modifiers == 0 && Self.modifierKeyLabels[Int(keyCode)] != nil
    }

    static let modifierSymbols: [(mask: Int, symbol: String)] = [
        (controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")
    ]

    var displayString: String {
        let symbols = Self.modifierSymbols
            .filter { modifiers & UInt32($0.mask) != 0 }
            .map(\.symbol)
            .joined()
        return symbols.isEmpty ? keyLabel : "\(symbols) \(keyLabel)"
    }
}

struct VocabularyEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }
}

struct SettingsSnapshot {
    let asrModel: ASRModel
    let language: DictationLanguage
    let vocabulary: String
    let polishingPrompt: String
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let asrModel = "asrModel"
        static let language = "language"
        static let vocabulary = "vocabulary"
        static let vocabularyEntries = "vocabularyEntries"
        static let ollamaModel = "ollamaModel"
        static let polishingPrompt = "polishingPrompt"
        static let dictationShortcut = "dictationShortcut"
        static let dictationMode = "dictationMode"
    }

    @Published var dictationShortcut: DictationShortcut {
        didSet {
            if dictationShortcut == .default {
                defaults.removeObject(forKey: Key.dictationShortcut)
            } else if let data = try? JSONEncoder().encode(dictationShortcut) {
                defaults.set(data, forKey: Key.dictationShortcut)
            }
        }
    }
    @Published var dictationMode: DictationMode { didSet { defaults.set(dictationMode.rawValue, forKey: Key.dictationMode) } }

    @Published var asrModel: ASRModel { didSet { defaults.set(asrModel.rawValue, forKey: Key.asrModel) } }
    @Published var language: DictationLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published private(set) var vocabularyEntries: [VocabularyEntry] { didSet { saveVocabularyEntries() } }
    /// The Ollama model chosen for polishing. Empty until the user picks one,
    /// which leaves the choice to `OllamaModel.preferred(in:)`.
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) } }
    @Published var polishingPrompt: String {
        didSet {
            if polishingPrompt == TextPolishingPrompt.defaultInstructions {
                defaults.removeObject(forKey: Key.polishingPrompt)
            } else {
                defaults.set(polishingPrompt, forKey: Key.polishingPrompt)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dictationShortcut = defaults.data(forKey: Key.dictationShortcut)
            .flatMap { try? JSONDecoder().decode(DictationShortcut.self, from: $0) } ?? .default
        dictationMode = DictationMode(rawValue: defaults.string(forKey: Key.dictationMode) ?? "") ?? .toggle
        asrModel = ASRModel(rawValue: defaults.string(forKey: Key.asrModel) ?? "") ?? .fast
        language = DictationLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .automatic
        if let data = defaults.data(forKey: Key.vocabularyEntries),
           let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
            vocabularyEntries = entries.compactMap { entry in
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : VocabularyEntry(id: entry.id, text: text)
            }
        } else {
            // The old editor documented space-separated terms. Migrate those
            // terms once; new rows preserve phrases containing spaces.
            let terms = (defaults.string(forKey: Key.vocabulary) ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            vocabularyEntries = terms.map { VocabularyEntry(text: $0) }
        }
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? ""
        let savedPrompt = defaults.string(forKey: Key.polishingPrompt)
        if savedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            == TextPolishingPrompt.previousDefaultInstructions {
            polishingPrompt = TextPolishingPrompt.defaultInstructions
            defaults.removeObject(forKey: Key.polishingPrompt)
        } else {
            polishingPrompt = savedPrompt ?? TextPolishingPrompt.defaultInstructions
        }
        saveVocabularyEntries()
    }

    var vocabulary: String {
        vocabularyEntries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    @discardableResult
    func addVocabularyEntry(text: String) -> UUID? {
        let confirmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmedText.isEmpty else { return nil }
        let entry = VocabularyEntry(text: confirmedText)
        vocabularyEntries.append(entry)
        return entry.id
    }

    func removeVocabularyEntry(id: UUID) {
        guard let index = vocabularyEntries.firstIndex(where: { $0.id == id }) else { return }
        vocabularyEntries.remove(at: index)
    }

    private func saveVocabularyEntries() {
        guard let data = try? JSONEncoder().encode(vocabularyEntries) else { return }
        defaults.set(data, forKey: Key.vocabularyEntries)
        // Keep the runtime and older versions compatible with the saved rows.
        defaults.set(vocabulary, forKey: Key.vocabulary)
    }

    func resetPolishingPrompt() {
        polishingPrompt = TextPolishingPrompt.defaultInstructions
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            asrModel: asrModel,
            language: language,
            vocabulary: vocabulary,
            polishingPrompt: polishingPrompt
        )
    }
}
