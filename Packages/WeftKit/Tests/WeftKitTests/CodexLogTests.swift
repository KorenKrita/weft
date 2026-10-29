import Foundation
import Testing
@testable import WeftKit

struct CodexLogTests {
    func date(_ seconds: Double) -> Date { Fixture.date(seconds) }

    @Test func turnsRunFromStartToComplete() {
        let (_, meta, turns) = Codex.parse([
            Codex.header(),
            Codex.started("turn-1", at: 10),
            Codex.item(at: 20),
            Codex.ended("turn-1", at: 60),
            Codex.started("turn-2", at: 600, trigger: "queue"),
            Codex.item(at: 610),
            Codex.ended("turn-2", at: 620, aborted: true),
        ])
        #expect(meta.sessionID == "thread-1")
        #expect(meta.cwd == "/Users/me/codex-project")
        #expect(!meta.skip)
        #expect(turns.map(\.id) == ["turn-1", "turn-2"])
        #expect(turns.map(\.endKind) == [.marker, .marker])
        #expect(turns[0].start == date(10))
        #expect(turns[0].end == date(60))
        #expect(turns[1].trigger == .queued)
    }

    @Test func automatedReviewThreadsAreSkipped() {
        let guardian = Codex.parse([
            Codex.header(id: "g", sessionID: "root", source: ["subagent": ["other": "guardian"]], threadSource: "guardian_review"),
            Codex.started("turn-1", at: 10, trigger: "guardian_review"),
            Codex.ended("turn-1", at: 20),
        ])
        #expect(guardian.meta.skip)
        #expect(guardian.events.isEmpty)
        #expect(Codex.parse([Codex.header(source: ["subagent": "review"])]).meta.skip)
    }

    @Test func spawnedThreadsBelongToTheirRoot() {
        let (_, meta, turns) = Codex.parse([
            Codex.header(id: "child", sessionID: "root", source: ["subagent": ["thread_spawn": ["parent_thread_id": "root"]]]),
            Codex.started("turn-c", at: 10, trigger: nil),
            Codex.item(at: 15),
            Codex.ended("turn-c", at: 20),
        ])
        #expect(!meta.skip)
        #expect(meta.isSubagent)
        #expect(meta.sessionID == "root")
        #expect(turns.count == 1)
    }

    @Test func aNestedTurnsEndDoesntEndTheOuterOne() {
        let (_, _, turns) = Codex.parse([
            Codex.header(),
            Codex.started("outer", at: 0),
            Codex.started("inner", at: 10, trigger: "subagent"),
            Codex.item(at: 15),
            Codex.ended("inner", at: 20),
            Codex.item(at: 50),
            Codex.ended("outer", at: 60),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].end == date(60))
    }

    @Test func oldRolloutsAreSkipped() {
        let (_, meta, _) = Codex.parse([#"{"id":"x","timestamp":"2025-09-01T00:00:00Z","instructions":""}"#, "{}"])
        #expect(meta.skip)
    }

    @Test func readingCanResumeWithoutTheHeader() {
        let lines = [
            Codex.header(),
            Codex.started("turn-1", at: 10),
            Codex.item(at: 20),
            Codex.ended("turn-1", at: 60),
        ]
        let offset = Fixture.offset(of: 1, in: lines)
        let tail = Data(Fixture.lines(lines).dropFirst(Int(offset)))
        let (_, meta, turns) = Codex.parse(lines, base: 0)
        let resumed = CodexLogParser.parse(tail, base: offset)
        #expect(!meta.skip)
        #expect(AgentTurnBuilder.turns(resumed.events) == turns)
        #expect(turns[0].offset == offset)
    }
}
