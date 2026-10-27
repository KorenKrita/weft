import Foundation
import SwiftData
import Testing
@testable import WeftKit

private struct NoAI: AIClassifying {
    func availability() -> AIAvailability { .unavailable("test") }
    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        throw ClassificationError.unknownCategory("")
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

@MainActor
private final class RecordingNotifier: NotificationPosting {
    var posted: [NotificationKind] = []
    func post(_ kind: NotificationKind, title: String, body: String) { posted.append(kind) }
}

@MainActor
struct FixesTests {
    let container: ModelContainer
    let context: ModelContext
    let classifier: ClassificationService

    init() throws {
        container = try WeftSchema.makeContainer(inMemory: true)
        context = container.mainContext
        classifier = ClassificationService(modelContext: context, ai: NoAI())
    }

    private func segment(_ ctx: ActivityContext) -> ActivitySegment {
        let (key, source) = classifier.classify(ctx)
        let segment = ActivitySegment(context: ctx, start: .now, categoryKey: key, source: source)
        context.insert(segment)
        return segment
    }

    @Test func browserInternalPagesHaveNoDomain() {
        #expect(ActivityContext.domain(from: "chrome://newtab/") == nil)
        #expect(ActivityContext.domain(from: "about:blank") == nil)
        #expect(ActivityContext.domain(from: "file:///Users/x/a.html") == nil)
        #expect(ActivityContext.domain(from: "https://github.com/x") == "github.com")
        #expect(!ActivityContext.isWebURL("edge://settings"))
    }

    @Test func titleRuleOnlyTouchesMatchingSegments() {
        let ssh = segment(ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal", title: "ssh prod-db"))
        let zsh = segment(ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal", title: "zsh"))
        classifier.addRule(field: .titleContains, pattern: "SSH", categoryKey: "admin")
        #expect(ssh.categoryKey == "admin")
        #expect(ssh.classificationSource == .rule)
        #expect(zsh.categoryKey == "code")
    }

    @Test func domainRuleNeedsExactOrSubdomainMatch() {
        let real = segment(ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://gist.github.com/a"))
        let lookalike = segment(ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://notgithub.com/a"))
        classifier.addRule(field: .domain, pattern: "github.com", categoryKey: "learning")
        #expect(real.categoryKey == "learning")
        #expect(lookalike.categoryKey == "browsing")
    }

    @Test func maintenancePrefersRulesOverOlderAIAnswers() {
        let stale = ActivitySegment(context: ActivityContext(bundleID: "com.apple.UserNotificationCenter", appName: "UserNotificationCenter"),
                                    start: .now, categoryKey: "miscellaneous", source: .ai)
        context.insert(stale)
        Maintenance.run(modelContext: context, classifier: classifier)
        #expect(stale.categoryKey == "utility")
        #expect(stale.classificationSource == .builtin)
    }

    @Test func glancingAtWeftKeepsTheBlockerUp() {
        let suite = "me.weishu.Weft.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.refocusThresholdSeconds = 0
        let sessions = SessionEngine(modelContext: context, classifier: classifier)
        let distractionGuard = DistractionGuard(preferences: preferences, sessions: sessions, notifier: RecordingNotifier())
        sessions.start(.focus, minutes: 25)

        let tv = ActivityContext(bundleID: "com.apple.TV", appName: "TV")
        distractionGuard.handle(TrackerSample(date: .now, context: tv, category: classifier.category("entertainment"), isAway: false))
        #expect(distractionGuard.incident != nil)

        distractionGuard.handle(TrackerSample(date: .now, context: nil, category: nil, isAway: false, isOwnApp: true))
        #expect(distractionGuard.incident != nil)

        let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
        distractionGuard.handle(TrackerSample(date: .now, context: xcode, category: classifier.category("code"), isAway: false))
        #expect(distractionGuard.incident == nil)
        sessions.stop()
    }
}
