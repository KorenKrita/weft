import Foundation
import SwiftData
import Testing
@testable import WeftKit

@MainActor
private final class RecordingNotifier: NotificationPosting {
    var posted: [(kind: NotificationKind, body: String)] = []
    func post(_ kind: NotificationKind, title: String, body: String) { posted.append((kind, body)) }
}

private struct NoAI: AIClassifying {
    func availability() -> AIAvailability { .unavailable("test") }
    func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        throw ClassificationError.unknownCategory("")
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

@MainActor
struct RemindersTests {
    let container: ModelContainer
    let context: ModelContext
    let preferences: Preferences
    let sessions: SessionEngine
    fileprivate let notifier = RecordingNotifier()
    let suite = "me.weishu.Weft.reminders.\(UUID().uuidString)"
    /// Noon today, far from midnight whenever the tests run.
    let noon = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)

    init() throws {
        container = try WeftSchema.makeContainer(inMemory: true)
        context = container.mainContext
        preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        sessions = SessionEngine(modelContext: context,
                                 classifier: ClassificationService(modelContext: context, ai: NoAI()))
    }

    private func at(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }

    private func active(_ minutes: Double) -> TrackerSample {
        TrackerSample(date: at(minutes), context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode"),
                      category: nil, isAway: false)
    }

    private func away(_ minutes: Double, idle: Double = 0) -> TrackerSample {
        TrackerSample(date: at(minutes), context: nil, category: nil, isAway: true, idleSeconds: idle * 60)
    }

    private func work(_ reminder: BreakReminder, from start: Int, to end: Int) {
        for minute in start...end { reminder.handle(active(Double(minute))) }
    }

    @Test func breakReminderAfterAnHourOfWork() {
        let reminder = BreakReminder(preferences: preferences, sessions: sessions, notifier: notifier)
        work(reminder, from: 0, to: 59)
        #expect(notifier.posted.isEmpty)
        reminder.handle(active(60))
        #expect(notifier.posted.map(\.kind) == [.breakReminder])
        #expect(notifier.posted.first?.body.contains("60 minutes") == true)
    }

    @Test func aBlankedScreenIsNotABreak() {
        let reminder = BreakReminder(preferences: preferences, sessions: sessions, notifier: notifier)
        work(reminder, from: 0, to: 40)
        reminder.handle(away(40.5))  // the screen locks for half a minute
        work(reminder, from: 41, to: 60)
        #expect(notifier.posted.count == 1)
    }

    @Test func fiveMinutesAwayStartsANewStretch() {
        let reminder = BreakReminder(preferences: preferences, sessions: sessions, notifier: notifier)
        work(reminder, from: 0, to: 35)
        // Noticed at 40 after five idle minutes; the break began at the last input.
        reminder.handle(away(40, idle: 5))
        work(reminder, from: 41, to: 100)
        #expect(notifier.posted.isEmpty)
        reminder.handle(active(101))
        #expect(notifier.posted.count == 1)
    }

    @Test func aStretchSurvivesRelaunching() {
        let segment = ActivitySegment(context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode"),
                                      start: at(0), categoryKey: "code", source: .builtin)
        segment.end = at(58)
        context.insert(segment)
        let reminder = BreakReminder(preferences: preferences, sessions: sessions, notifier: notifier,
                                     modelContext: context, now: at(59))
        reminder.handle(active(59))
        #expect(notifier.posted.isEmpty)
        reminder.handle(active(60))
        #expect(notifier.posted.count == 1)
    }

    @Test func stretchStartLooksBackToTheLastRealBreak() {
        func segment(_ start: Double, _ end: Double) -> (start: Date, end: Date) { (at(start), at(end)) }
        let day = [segment(0, 30), segment(36, 50), segment(52, 70)]
        #expect(BreakReminder.stretchStart(day, now: at(71)) == at(36))
        #expect(BreakReminder.stretchStart(day, now: at(76)) == nil)
        #expect(BreakReminder.stretchStart([], now: at(0)) == nil)
    }

    @Test func workHoursNotifyOnceEvenAcrossRelaunches() {
        preferences.workHoursTarget = 1
        let segment = ActivitySegment(context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode"),
                                      start: at(-70), categoryKey: "code", source: .builtin)
        segment.end = at(0)
        context.insert(segment)

        // Weft starts after the target was already reached: it's still due.
        let monitor = WorkHoursMonitor(preferences: preferences, notifier: notifier, modelContext: context, now: at(0))
        monitor.handle(active(0))
        monitor.handle(active(1))
        #expect(notifier.posted.map(\.kind) == [.workHours])

        let relaunched = WorkHoursMonitor(preferences: preferences, notifier: notifier, modelContext: context, now: at(2))
        relaunched.handle(active(2))
        relaunched.handle(active(3))
        #expect(notifier.posted.count == 1)
    }
}
