import Foundation

/// Talks to the user's own Ollama on this Mac, so WizardScroll can polish with
/// models they already have instead of downloading another copy.
@MainActor
final class OllamaClient: TextGenerating {
    private struct TagsResponse: Decodable {
        let models: [OllamaModel]
    }

    private struct LoadRequest: Encodable {
        let model: String
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model
            case keepAlive = "keep_alive"
        }
    }

    private struct ChatRequest: Encodable {
        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }

        let model: String
        let messages: [ChatMessage]
        let stream = false
        /// Sent only to models that think, which would otherwise spend time
        /// reasoning before they answer. Other models reject the option.
        let think: Bool?
        let keepAlive: String
        let options: Options

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, think, options
            case keepAlive = "keep_alive"
        }
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    /// Ollama unloads an idle model after 5 minutes by default, and loading a
    /// large one again takes several seconds. Keep it loaded between dictations.
    static let keepAlive = "30m"

    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession
    private var thinkingModels: Set<String> = []

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated static var applicationURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Ollama.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static var isInstalled: Bool {
        applicationURL != nil || RuntimeLocator.executableURL(named: "ollama") != nil
    }

    /// The local text models in Ollama. Throws when Ollama is not running.
    func availableModels() async throws -> [OllamaModel] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        try validate(response)
        let models = try JSONDecoder().decode(TagsResponse.self, from: data).models.filter(\.isLocalTextModel)
        thinkingModels = Set(models.filter(\.supportsThinking).map(\.name))
        return models
    }

    /// Loads the model into memory. Ollama caches the system prompt itself,
    /// so the messages are not needed here.
    func prepareTextModel(_ model: String, messages: [ChatMessage]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(LoadRequest(model: model, keepAlive: Self.keepAlive))
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func generateText(messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages,
            think: thinkingModels.contains(model) ? false : nil,
            keepAlive: Self.keepAlive,
            options: .init(temperature: 0.1, numPredict: maxTokens)
        ))
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.unavailable
        }
    }
}

enum OllamaError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "Ollama is not reachable at 127.0.0.1:11434"
        }
    }
}
