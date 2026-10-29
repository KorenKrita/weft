import Foundation

/// Where to reach a Chat Completions API: OpenAI itself, or anything that speaks the same
/// protocol (OpenRouter, DeepSeek, a local Ollama or LM Studio server…).
public struct RemoteModelConfig: Sendable, Equatable {
    public var baseURL: String
    public var model: String
    /// Empty for servers that don't need one, like a local Ollama.
    public var apiKey: String

    public static let defaultBaseURL = "https://api.openai.com/v1"

    public init(baseURL: String, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// `https://api.openai.com/v1` → `https://api.openai.com/v1/chat/completions`
    public var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }
}

public enum RemoteModelError: LocalizedError {
    case http(status: Int, message: String?)
    case emptyReply
    case unreadableReply

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message?): String(localized: "The server answered \(status): \(message)", bundle: .module)
        case .http(let status, nil): String(localized: "The server answered \(status).", bundle: .module)
        case .emptyReply: String(localized: "The model sent an empty reply.", bundle: .module)
        case .unreadableReply: String(localized: "The model's reply wasn't in the expected format.", bundle: .module)
        }
    }
}

/// Sends the same prompts as the on-device model to an OpenAI-compatible server. Nothing
/// fancier than plain chat messages, so it works with as many servers as possible: no
/// structured outputs, no sampling settings (reasoning models reject them).
public struct OpenAICompatibleClassifier: AIClassifying {
    public let config: RemoteModelConfig
    private let session: URLSession

    public init(config: RemoteModelConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func availability() -> AIAvailability {
        if config.endpoint == nil { return .unavailable(String(localized: "The API base URL isn't valid.", bundle: .module)) }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty { return .unavailable(String(localized: "No model is set.", bundle: .module)) }
        return .available
    }

    public func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        let candidates = ModelPrompts.candidates(categories)
        let instructions = ModelPrompts.classifyInstructions(candidates) + "\n\n" + """
            Reply with only this JSON object and nothing else:
            {"category": "<key from the list>", "confidence": "low" | "medium" | "high"}
            Use low confidence when the app or site could reasonably fit several categories.
            """
        let reply = try await complete(instructions: instructions, prompt: ModelPrompts.classifyPrompt(context, titles: titles))
        return try Self.parseClassification(reply, candidates: candidates)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        try await complete(instructions: ModelPrompts.describeInstructions(language: language), prompt: facts)
    }

    public func summarize(_ facts: String) async throws -> String {
        try await complete(instructions: ModelPrompts.summarizeInstructions, prompt: facts)
    }

    private func complete(instructions: String, prompt: String) async throws -> String {
        guard let endpoint = config.endpoint else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: config.model.trimmingCharacters(in: .whitespaces),
            messages: [.init(role: "system", content: instructions), .init(role: "user", content: prompt)]
        ))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw RemoteModelError.http(status: status, message: message)
        }
        let content = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content ?? ""
        let text = Self.stripReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteModelError.emptyReply }
        return text
    }

    /// Finds the JSON object in the reply, which may come wrapped in a code fence or prose,
    /// and accepts a category's name as well as its key.
    static func parseClassification(_ reply: String, candidates: [CategoryDefinition]) throws -> AIClassification {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let answer = try? JSONDecoder().decode(ClassificationReply.self, from: Data(reply[open...close].utf8))
        else { throw RemoteModelError.unreadableReply }
        let value = answer.category.trimmingCharacters(in: .whitespaces)
        guard let category = candidates.first(where: {
            $0.key.caseInsensitiveCompare(value) == .orderedSame || $0.name.caseInsensitiveCompare(value) == .orderedSame
        }) else { throw ClassificationError.unknownCategory(value) }
        let confidence = answer.confidence.flatMap { AIConfidence(rawValue: $0.lowercased()) } ?? .low
        return AIClassification(categoryKey: category.key, confidence: confidence)
    }

    /// Drops the `<think>…</think>` block that reasoning models served by Ollama and the
    /// like put before their answer.
    static func stripReasoning(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...])
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        var model: String
        var messages: [Message]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }

    private struct ClassificationReply: Decodable {
        var category: String
        var confidence: String?
    }
}
