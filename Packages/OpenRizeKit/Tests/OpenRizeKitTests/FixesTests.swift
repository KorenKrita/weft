import Foundation
import SwiftData
import Testing
@testable import OpenRizeKit

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
        container = try OpenRizeSchema.makeContainer(inMemory: true)
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

    @Test func maintenanceDropsOwnAppAndInternalPageDomains() throws {
        context.insert(ActivitySegment(context: ActivityContext(bundleID: "io.github.openrize.OpenRize", appName: "OpenRize"),
                                       start: .now, categoryKey: "utility", source: .builtin))
        let newtab = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "chrome://newtab/"),
                                     start: .now, categoryKey: "browsing", source: .builtin)
        // Simulate data written before internal pages were filtered.
        newtab.domain = "newtab"
        newtab.classificationKey = "com.google.Chrome|newtab"
        context.insert(newtab)

        Maintenance.run(modelContext: context, classifier: classifier, ownBundleID: "io.github.openrize.OpenRize")

        let remaining = try context.fetch(FetchDescriptor<ActivitySegment>())
        #expect(remaining.map(\.bundleID) == ["com.google.Chrome"])
        #expect(newtab.domain == nil)
        #expect(newtab.url == nil)
        #expect(newtab.classificationKey == "com.google.Chrome")
        #expect(newtab.categoryKey == "browsing")
    }

    @Test func maintenancePrefersRulesOverOlderAIAnswers() {
        let stale = ActivitySegment(context: ActivityContext(bundleID: "com.apple.UserNotificationCenter", appName: "UserNotificationCenter"),
                                    start: .now, categoryKey: "miscellaneous", source: .ai)
        context.insert(stale)
        Maintenance.run(modelContext: context, classifier: classifier, ownBundleID: nil)
        #expect(stale.categoryKey == "utility")
        #expect(stale.classificationSource == .builtin)
    }

    @Test func maintenanceDropsSessionsStoppedRightAway() throws {
        let start = Date.now
        context.insert(SessionRecord(kind: .focus, start: start, end: start + 59, plannedDuration: 25 * 60))
        context.insert(SessionRecord(kind: .breakTime, start: start, end: start + 60, plannedDuration: 60))
        context.insert(SessionRecord(kind: .focus, start: start, end: start + 20 * 60, plannedDuration: 25 * 60))
        Maintenance.run(modelContext: context, classifier: classifier, ownBundleID: nil)
        let kept = try context.fetch(FetchDescriptor<SessionRecord>()).map { $0.end.timeIntervalSince($0.start) }.sorted()
        #expect(kept == [60, 20 * 60])
    }

    @Test func glancingAtOpenRizeKeepsTheBlockerUp() {
        let defaults = UserDefaults(suiteName: "openrize-tests-\(UUID().uuidString)")!
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
