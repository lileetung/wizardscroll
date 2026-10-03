import Foundation

struct DictationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let rawText: String
    let finalText: String
    let language: String
    let application: String?
    let wasPolished: Bool
    let note: String?
}

@MainActor
final class DictationHistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []

    private let fileURL: URL
    private let maximumCount = 10

    init(fileURL: URL = RuntimeLocator.applicationSupportDirectory.appendingPathComponent("history.json")) {
        self.fileURL = fileURL
        load()
    }

    func add(
        rawText: String,
        finalText: String,
        language: String,
        application: String?,
        wasPolished: Bool,
        note: String?
    ) {
        records.insert(
            DictationRecord(
                id: UUID(),
                createdAt: .now,
                rawText: rawText,
                finalText: finalText,
                language: language,
                application: application,
                wasPolished: wasPolished,
                note: note
            ),
            at: 0
        )
        records = Array(records.prefix(maximumCount))
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.wizardscroll.decode([DictationRecord].self, from: data) else { return }
        records = Array(decoded.prefix(maximumCount))
        if decoded.count > maximumCount { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.wizardscroll.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Unable to save dictation history: %@", error.localizedDescription)
        }
    }
}

private extension JSONEncoder {
    static var wizardscroll: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var wizardscroll: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
