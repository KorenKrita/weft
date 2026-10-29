import Foundation
import Testing
@testable import WeftKit

struct ClaudeCodeLogTests {
    func date(_ seconds: Double) -> Date { Fixture.date(seconds) }

    @Test func promptToolUseAndEndMakeOneTurn() {
        let (_, meta, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5, toolUse: "t1"),
            Claude.toolResult(at: 7, id: "t1"),
            Claude.assistant(at: 20),
            Claude.turnDuration(at: 20.5),
        ])
        #expect(turns.count == 1)
        let turn = turns[0]
        #expect(turn.id == "p1")
        #expect(turn.start == date(0))
        #expect(turn.end == date(20.5))
        #expect(turn.endKind == .marker)
        #expect(turn.trigger == .user)
        #expect(turn.waits.isEmpty)
        #expect(AgentTurnBuilder.pieces(turn) == [DateInterval(start: date(0), end: date(20.5))])
        #expect(meta.sessionID == "session-1")
        #expect(meta.cwd == "/Users/me/project")
    }

    @Test func answeringAPermissionPromptIsCutOut() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 130, id: "t1", source: "user_temporary"),
            Claude.assistant(at: 140),
            Claude.turnDuration(at: 141),
        ])
        let turn = turns[0]
        #expect(turn.waits == [DateInterval(start: date(10), end: date(130))])
        #expect(turn.waitedOnUser == 120)
        #expect(AgentTurnBuilder.pieces(turn) == [DateInterval(start: date(0), end: date(10)),
                                                  DateInterval(start: date(130), end: date(141))])
    }

    @Test func aHookDecisionEndsTheWaitBeforeTheToolRuns() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.hookDecision(at: 70, id: "t1"),
            // The tool itself ran for five minutes after the answer.
            Claude.toolResult(at: 370, id: "t1", source: "hook"),
            Claude.turnDuration(at: 371),
        ])
        #expect(turns[0].waits == [DateInterval(start: date(10), end: date(70))])
    }

    @Test func automaticApprovalsAreNotWaits() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 200, id: "t1", source: "config"),
            Claude.assistant(at: 201, toolUse: "t2"),
            // A hook that answers at once isn't the user.
            Claude.hookDecision(at: 201.5, id: "t2"),
            Claude.toolResult(at: 202, id: "t2", source: "hook"),
            Claude.turnDuration(at: 203),
        ])
        #expect(turns[0].waits.isEmpty)
    }

    @Test func aQueuedPromptJoinsTheTurnInProgress() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5, toolUse: "t1"),
            Claude.prompt("also this", at: 10, uuid: "p2", promptSource: "queued"),
            Claude.toolResult(at: 12, id: "t1"),
            Claude.assistant(at: 20),
            Claude.turnDuration(at: 21),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].end == date(21))
    }

    @Test func aQueuedPromptAfterTheEndStartsATurn() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
            Claude.prompt("one more", at: 100, uuid: "p2", promptSource: "queued"),
            Claude.assistant(at: 110),
            Claude.turnDuration(at: 111),
        ])
        #expect(turns.map(\.id) == ["p1", "p2"])
        #expect(turns[1].trigger == .queued)
    }

    @Test func aFinishedBackgroundTaskStartsATurnOfItsOwn() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
            Claude.prompt("<task-notification>", at: 300, uuid: "p2", origin: "task-notification", promptSource: "system"),
            Claude.assistant(at: 302),
            Claude.turnDuration(at: 303),
        ])
        #expect(turns.map(\.trigger) == [.user, .system])
        #expect(turns[1].start == date(300))
    }

    @Test func anAutomaticContinuationStartsATurn() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt("Continue", at: 0, uuid: "p1", origin: "auto-continuation", promptSource: "system", isMeta: true),
            Claude.assistant(at: 4),
            Claude.turnDuration(at: 5),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].hasActivity)
        #expect(turns[0].trigger == .system)
    }

    @Test func anInterruptEndsTheTurn() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.prompt("[Request interrupted by user]", at: 60, uuid: "x", origin: nil, promptSource: nil),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].endKind == .marker)
        #expect(turns[0].end == date(60))
    }

    @Test func sdkPromptsWithoutAnOriginCount() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1", origin: nil, promptSource: "sdk"),
            Claude.assistant(at: 30),
            Claude.turnDuration(at: 31),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].trigger == .user)
    }

    @Test func aPromptWithoutAReplyIsNoWork() {
        // HAPI checks Claude works by sending "hello" through the SDK; nothing ever answers.
        let (_, _, turns) = Claude.parse([
            Claude.prompt("hello", at: 0, uuid: "p1", origin: nil, promptSource: "sdk"),
            Claude.apiRequest(at: 1),
        ])
        #expect(turns.count == 1)
        #expect(!turns[0].hasActivity)
    }

    @Test func slashCommandsDontEndATurn() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5, toolUse: "t1"),
            Claude.prompt("<command-name>/model</command-name>", at: 10, uuid: "c1", origin: nil, promptSource: nil),
            Claude.toolResult(at: 12, id: "t1"),
            Claude.turnDuration(at: 13),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].end == date(13))
    }

    @Test func aNewPromptEndsAnUnfinishedTurnAtItsLastActivity() {
        // Claude was killed mid-turn and resumed the next day.
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 30, toolUse: "t1"),
            Claude.prompt(at: 86_400, uuid: "p2"),
            Claude.assistant(at: 86_410),
            Claude.turnDuration(at: 86_411),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].endKind == .inferred)
        #expect(turns[0].end == date(30))
    }

    @Test func anUnfinishedTurnStaysOpenAndIsWhereReadingResumes() {
        let lines = [
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
            Claude.prompt(at: 100, uuid: "p2"),
            Claude.assistant(at: 110, toolUse: "t1"),
        ]
        let parsed = ClaudeCodeLogParser.parse(Fixture.lines(lines))
        let turns = AgentTurnBuilder.turns(parsed.events)
        #expect(turns.last?.endKind == .open)
        #expect(turns.last?.end == date(110))
        let resume = AgentTurnBuilder.resumeOffset(turns, consumedTo: Int64(parsed.consumed))
        #expect(resume == Fixture.offset(of: 3, in: lines))
    }

    @Test func resumingGivesTheSameTurnsAsReadingEverything() {
        let first = [
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
            Claude.prompt(at: 100, uuid: "p2"),
            Claude.assistant(at: 110, toolUse: "t1"),
        ]
        let rest = [
            Claude.toolResult(at: 400, id: "t1", source: "user_permanent"),
            Claude.assistant(at: 410),
            Claude.turnDuration(at: 411),
        ]
        let whole = AgentTurnBuilder.turns(ClaudeCodeLogParser.parse(Fixture.lines(first + rest)).events)

        let start = ClaudeCodeLogParser.parse(Fixture.lines(first))
        let offset = AgentTurnBuilder.resumeOffset(AgentTurnBuilder.turns(start.events), consumedTo: Int64(start.consumed))
        let tail = Fixture.lines(first + rest).dropFirst(Int(offset))
        let resumed = AgentTurnBuilder.turns(ClaudeCodeLogParser.parse(Data(tail), base: offset).events)

        #expect(resumed.count == 1)
        #expect(resumed[0] == whole[1])
        #expect(resumed[0].waits == [DateInterval(start: date(110), end: date(400))])
    }

    @Test func aHalfWrittenLastLineIsLeftForLater() {
        let complete = Claude.prompt(at: 0, uuid: "p1")
        let data = Data((complete + "\n" + #"{"parentUuid":null,"type":"assi"#).utf8)
        let parsed = ClaudeCodeLogParser.parse(data)
        #expect(parsed.consumed == complete.utf8.count + 1)
        #expect(parsed.events.count == 1)
    }

    @Test func titlesPreferExplicitNamesAndTakeTheLatest() {
        #expect(Claude.parse([Claude.aiTitle("First"), Claude.aiTitle("Second")]).meta.title == "Second")
        #expect(Claude.parse([Claude.customTitle("Mine"), Claude.aiTitle("Generated")]).meta.title == "Mine")
    }

    @Test func linesOutOfOrderDontLookLikeSilence() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 1000),
            Claude.assistant(at: 978),
            Claude.assistant(at: 1500),
            Claude.turnDuration(at: 1501),
        ])
        #expect(turns[0].silences.isEmpty)
    }

    @Test func longSilenceInsideATurnIsCutOut() {
        let long = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 10 + 31 * 60, id: "t1"),
            Claude.turnDuration(at: 11 + 31 * 60),
        ]).turns[0]
        #expect(AgentTurnBuilder.pieces(long).count == 2)

        let short = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 10 + 29 * 60, id: "t1"),
            Claude.turnDuration(at: 11 + 29 * 60),
        ]).turns[0]
        #expect(AgentTurnBuilder.pieces(short).count == 1)
    }

    @Test func modelRequestsKeepTimeMovingWithoutCountingAsReplies() {
        let (events, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.apiRequest(at: 1000),
            Claude.assistant(at: 2000),
            Claude.turnDuration(at: 2001),
        ])
        #expect(events.contains(.progress(date(1000))))
        // Over 30 minutes between prompt and reply, but a request went out in between.
        #expect(turns[0].silences.isEmpty)
        #expect(Claude.parse([Claude.prompt(at: 0, uuid: "p1"), Claude.apiRequest(at: 1)]).turns[0].hasActivity == false)
    }

    @Test func awaySummariesArentWork() {
        let (events, _, _) = Claude.parse([Claude.system("away_summary", at: 5)])
        #expect(events.isEmpty)
    }

    @Test func inlineSidechainLinesDontStartTurns() {
        let (_, _, turns) = Claude.parse([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5, toolUse: "task"),
            Claude.assistant(at: 50, sidechain: true),
            Claude.toolResult(at: 60, id: "task"),
            Claude.turnDuration(at: 61),
        ])
        #expect(turns.count == 1)
    }

    @Test func subagentLogsAreParsedOnTheirOwn() {
        let (_, meta, turns) = Claude.parse([
            Claude.prompt("Explore the code", at: 0, uuid: "s1", origin: nil, promptSource: nil),
            Claude.assistant(at: 30, sidechain: true),
        ], subagent: true)
        #expect(meta.isSubagent)
        #expect(turns.count == 1)
        #expect(turns[0].hasActivity)
    }
}
