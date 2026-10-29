import Foundation
import SwiftData
import Testing
@testable import WeftKit

@MainActor
struct AgentActivityServiceTests {
    let home: URL
    let container: ModelContainer
    let service: AgentActivityService
    let log: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "weft-agents-\(UUID().uuidString)")
        let project = home.appending(path: ".claude/projects/-Users-me-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        log = project.appending(path: "session-1.jsonl")
        container = try WeftSchema.makeContainer(inMemory: true)
        let preferences = Preferences(defaults: UserDefaults(suiteName: "weft-agents-\(UUID().uuidString)")!)
        service = AgentActivityService(modelContext: container.mainContext, preferences: preferences, roots: AgentLogRoots(home: home))
    }

    private var spans: [AgentSpan] {
        (try? container.mainContext.fetch(FetchDescriptor<AgentSpan>(sortBy: [SortDescriptor(\.start)]))) ?? []
    }

    private var sessions: [AgentSession] { (try? container.mainContext.fetch(FetchDescriptor<AgentSession>())) ?? [] }

    private func write(_ lines: [String]) throws {
        try Fixture.lines(lines).write(to: log)
    }

    private func append(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines(lines))
        try handle.close()
    }

    @Test func readsALogIntoSpansAndASession() async throws {
        try write([
            Claude.aiTitle("Fix the build"),
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 70, id: "t1", source: "user_temporary"),
            Claude.assistant(at: 80),
            Claude.turnDuration(at: 81),
        ])
        await service.refresh()

        #expect(spans.map(\.key) == ["p1#0", "p1#1"])
        #expect(spans.first?.waitedOnUser == 60)
        #expect(spans.allSatisfy { !$0.isOpen && $0.sessionKey == "claude:session-1" })
        let session = try #require(sessions.first)
        #expect(session.key == "claude:session-1")
        #expect(session.title == "Fix the build")
        #expect(session.projectPath == "/Users/me/project")
        #expect(session.lastActivity == Fixture.date(81))
    }

    @Test func appendedLinesUpdateTheOpenTurnWithoutDuplicates() async throws {
        try write([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
            Claude.prompt(at: 100, uuid: "p2"),
            Claude.assistant(at: 110, toolUse: "t1"),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["p1#0", "p2#0"])
        #expect(spans.last?.isOpen == true)
        #expect(spans.last?.end == Fixture.date(110))

        try append([
            Claude.toolResult(at: 120, id: "t1"),
            Claude.assistant(at: 150),
            Claude.turnDuration(at: 151),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["p1#0", "p2#0"])
        #expect(spans.last?.isOpen == false)
        #expect(spans.last?.end == Fixture.date(151))

        // Nothing new: nothing changes.
        await service.refresh()
        #expect(spans.count == 2)
    }

    @Test func aReplacedFileIsReadAgainFromTheStart() async throws {
        try write([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["p1#0"])

        try FileManager.default.removeItem(at: log)
        try write([
            Claude.prompt(at: 1000, uuid: "q1"),
            Claude.assistant(at: 1010),
            Claude.turnDuration(at: 1011),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["q1#0"])
    }

    @Test func readingAgainRebuildsTheSameSpans() async throws {
        try write([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 70, id: "t1", source: "user_temporary"),
            Claude.turnDuration(at: 81),
        ])
        await service.refresh()
        let before = spans.map(\.key)
        service.reimport()
        await service.refresh()
        #expect(spans.map(\.key) == before)
        #expect(spans.count == 2)
    }

    @Test func promptsNobodyAnsweredLeaveNoTrace() async throws {
        try write([Claude.prompt("hello", at: 0, uuid: "p1", origin: nil, promptSource: "sdk")])
        await service.refresh()
        #expect(spans.isEmpty)
        #expect(sessions.isEmpty)
    }

    @Test func codexThreadsAreNamedFromTheIndex() async throws {
        let day = home.appending(path: ".codex/sessions/2026/10/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "01a18298-0a45-7dd2-ad73-c34ffce6b3d9"
        try Fixture.lines([
            Codex.header(id: thread),
            Codex.started("turn-1", at: 10),
            Codex.item(at: 20),
            Codex.ended("turn-1", at: 60),
        ]).write(to: day.appending(path: "rollout-2026-10-28T20-59-24-\(thread).jsonl"))
        try Fixture.lines([
            #"{"id":"\#(thread)","thread_name":"Old name","updated_at":"2026-10-28T00:00:00Z"}"#,
            #"{"id":"\#(thread)","thread_name":"Look into the runner","updated_at":"2026-10-28T01:00:00Z"}"#,
        ]).write(to: home.appending(path: ".codex/session_index.jsonl"))

        await service.refresh()
        let session = try #require(sessions.first)
        #expect(session.key == "codex:\(thread)")
        #expect(session.flavor == "codex")
        #expect(session.title == "Look into the runner")
        #expect(spans.map(\.key) == ["turn-1#0"])
    }

    @Test func waitingIdleCountsTimeAwayWhileAnAgentWorks() async throws {
        let now = Date.now
        let start = now.addingTimeInterval(-3600)
        let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })
        // Skip runs that straddle midnight, where "today" is too short to hold the test.
        guard Calendar.current.isDate(start, inSameDayAs: now) else { return }

        let segment = ActivitySegment(context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode"),
                                      start: start, categoryKey: "code", source: .builtin)
        segment.end = start.addingTimeInterval(600)
        container.mainContext.insert(segment)
        container.mainContext.insert(AgentSpan(key: "t#0", sessionKey: "claude:x", turnID: "t", fileKey: "/x",
                                               turnStart: start, start: start.addingTimeInterval(300),
                                               end: start.addingTimeInterval(1800), isOpen: false, trigger: .user,
                                               isSubagent: false, waitedOnUser: 0))
        try container.mainContext.save()

        #expect(service.waitingIdleToday(categories: categories, now: now) == 1200)
    }
}
