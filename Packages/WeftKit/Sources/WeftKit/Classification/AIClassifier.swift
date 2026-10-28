import Foundation
import FoundationModels
import Synchronization

public enum AIConfidence: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public struct AIClassification: Sendable, Equatable {
    public var categoryKey: String
    public var confidence: AIConfidence

    public init(categoryKey: String, confidence: AIConfidence) {
        self.categoryKey = categoryKey
        self.confidence = confidence
    }
}

public enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Abstraction over the model (on device or remote) so tests can inject a fake.
public protocol AIClassifying: Sendable {
    func availability() -> AIAvailability
    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification
    func summarize(_ facts: String) async throws -> String
    /// One sentence describing a stretch of activity, in `language`.
    func describeActivity(_ facts: String, language: String) async throws -> String
}

/// Classifies activity with Apple's on-device Foundation Models. The category list is
/// user-editable, so the output schema is built at runtime with `DynamicGenerationSchema`.
public struct FoundationModelsClassifier: AIClassifying {
    public init() {}

    public func availability() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            // Also what regions without Apple Intelligence may report.
            return .unavailable("Apple Intelligence isn't available on this Mac or in your region.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is turned off in System Settings.")
        case .unavailable(.modelNotReady):
            return .unavailable("The on-device model is still downloading.")
        case .unavailable:
            return .unavailable("The on-device model is unavailable.")
        }
    }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        let candidates = ModelPrompts.candidates(categories)
        let keys = candidates.map(\.key)

        let root = DynamicGenerationSchema(
            name: "ActivityClassification",
            properties: [
                .init(
                    name: "category",
                    description: "The category key that best describes the activity.",
                    schema: DynamicGenerationSchema(name: "CategoryKey", anyOf: keys)
                ),
                .init(
                    name: "confidence",
                    description: "How sure you are. Use low when the app or site could reasonably fit several categories.",
                    schema: DynamicGenerationSchema(name: "Confidence", anyOf: AIConfidence.allCases.map(\.rawValue))
                ),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session = LanguageModelSession(instructions: ModelPrompts.classifyInstructions(candidates))
        let response = try await session.respond(
            to: ModelPrompts.classifyPrompt(context), schema: schema, options: GenerationOptions(samplingMode: .greedy)
        )
        let key = try response.content.value(String.self, forProperty: "category")
        let confidence = try response.content.value(String.self, forProperty: "confidence")
        guard keys.contains(key) else { throw ClassificationError.unknownCategory(key) }
        return AIClassification(categoryKey: key, confidence: AIConfidence(rawValue: confidence) ?? .low)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        let session = LanguageModelSession(instructions: ModelPrompts.describeInstructions(language: language))
        return try await session.respond(to: facts).content
    }

    public func summarize(_ facts: String) async throws -> String {
        let session = LanguageModelSession(instructions: ModelPrompts.summarizeInstructions)
        return try await session.respond(to: facts).content
    }
}

/// Instructions and prompts shared by every model backend.
enum ModelPrompts {
    static func candidates(_ categories: [CategoryDefinition]) -> [CategoryDefinition] {
        categories.filter { !$0.isDoNotTrack && $0.key != CategoryDefinition.uncategorizedKey }
    }

    static func classifyInstructions(_ candidates: [CategoryDefinition]) -> String {
        let categoryList = candidates.map { "- \($0.key): \($0.hint)" }.joined(separator: "\n")
        return """
            You categorize what a person is doing on their Mac for a personal time tracker.
            Pick exactly one category key from this list:
            \(categoryList)

            Judge by what the app or website is for, not by incidental words in the window title.
            Use "browsing" only for a web browser tab whose site has no clear purpose; \
            never use it for a native app. For a native app you don't know, infer its \
            purpose from its name and bundle identifier.
            """
    }

    static func classifyPrompt(_ context: ActivityContext) -> String {
        var prompt = context.domain == nil
            ? "Native app: \(context.appName) (bundle identifier \(context.bundleID))"
            : "Web browser tab in \(context.appName)"
        if context.domain == nil, let category = CategoryGuess.appStoreCategory(bundleID: context.bundleID) {
            prompt += "\nApp Store category: \(category.replacingOccurrences(of: "-", with: " "))"
        }
        if let domain = context.domain { prompt += "\nWebsite: \(domain)" }
        if let title = context.title { prompt += "\nWindow title: \(title.prefix(200))" }
        return prompt
    }

    static func describeInstructions(language: String) -> String {
        // A native example per language keeps the output from reading like a translation.
        let example = language.localizedCaseInsensitiveContains("Chinese")
            ? "在终端里开发 weft 应用，在 GitHub 上查看 ActivityWatch 仓库，并调研了时间追踪工具的替代方案。"
            : "Worked on the weft app in the terminal, reviewed the ActivityWatch repo on GitHub and researched time-tracking alternatives."
        return """
            You write entries for a personal timesheet. Given the apps, websites and window \
            titles from a stretch of computer use, write ONE sentence (at most 30 words) that \
            says what the person did. Cover the two or three main things, naming the concrete \
            projects, topics or pages from the titles, and how (e.g. in the terminal, on GitHub). \
            Never mention durations, percentages or yourself.
            Write the sentence in \(language), as naturally as a native speaker would. Example:
            \(example)
            """
    }

    static let summarizeInstructions = """
        You are a supportive productivity coach. Given statistics about one day of computer \
        use, write a short review in the same language as the request: 2–3 sentences on how \
        the day went, then one concrete, specific suggestion for tomorrow. No headings, no lists.
        """
}

/// Forwards every call to the model chosen in Settings. Swapping it takes effect from the
/// next call on, so services can keep one reference for the app's lifetime.
public final class ModelRouter: AIClassifying {
    private let current: Mutex<any AIClassifying>

    public init(_ model: any AIClassifying) {
        current = Mutex(model)
    }

    public func use(_ model: any AIClassifying) {
        current.withLock { $0 = model }
    }

    private var model: any AIClassifying { current.withLock { $0 } }

    public func availability() -> AIAvailability { model.availability() }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        try await model.classify(context, categories: categories)
    }

    public func summarize(_ facts: String) async throws -> String {
        try await model.summarize(facts)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        try await model.describeActivity(facts, language: language)
    }
}

public enum ClassificationError: Error {
    case unknownCategory(String)
}
