import Foundation
import Testing
@testable import WeftKit

struct AgentMetricsTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })

    func interval(_ start: Double, _ minutes: Double) -> DateInterval {
        DateInterval(start: t0 + start * 60, duration: minutes * 60)
    }

    func agent(_ start: Double, _ minutes: Double, session: String = "claude:a", turn: String = "t", subagent: Bool = false) -> AgentSample {
        AgentSample(sessionKey: session, turnID: turn, start: t0 + start * 60, end: t0 + (start + minutes) * 60, isSubagent: subagent)
    }

    func user(_ start: Double, _ minutes: Double, _ category: String = "code") -> SegmentSample {
        SegmentSample(start: t0 + start * 60, end: t0 + (start + minutes) * 60, categoryKey: category, bundleID: "app", appName: "app")
    }

    // MARK: Interval algebra

    @Test func unionMergesOverlapsAndTouches() {
        let merged = AgentMetrics.union([interval(10, 5), interval(0, 5), interval(5, 5), interval(12, 1), interval(30, 1)])
        #expect(merged == [interval(0, 15), interval(30, 1)])
        #expect(AgentMetrics.union([interval(0, 5), interval(6, 1)]).count == 2)
    }

    @Test func intersectKeepsSharedTime() {
        let shared = AgentMetrics.intersect([interval(0, 10), interval(20, 10)], [interval(5, 20)])
        #expect(shared == [interval(5, 5), interval(20, 5)])
    }

    @Test func subtractLeavesTheRest() {
        let rest = AgentMetrics.subtract([interval(2, 1), interval(5, 10)], from: interval(0, 10))
        #expect(rest == [interval(0, 2), interval(3, 2)])
        #expect(AgentMetrics.subtract([], from: interval(0, 10)) == [interval(0, 10)])
    }

    // MARK: Agent time

    @Test func wallTimeCountsParallelAgentsOnce() {
        let samples = [agent(0, 60, session: "a"), agent(30, 60, session: "b")]
        #expect(AgentMetrics.wallTime(samples) == 90 * 60)
        #expect(AgentMetrics.agentHours(samples) == 120 * 60)
        #expect(AgentMetrics.maxConcurrency(samples) == 2)
    }

    @Test func subagentsDontAddToTheirSession() {
        let samples = [agent(0, 60), agent(10, 20, subagent: true), agent(70, 10, subagent: true)]
        #expect(AgentMetrics.agentHours(samples) == 70 * 60)
        #expect(AgentMetrics.maxConcurrency(samples) == 1)
    }

    @Test func backToBackSessionsArentParallel() {
        #expect(AgentMetrics.maxConcurrency([agent(0, 10, session: "a"), agent(10, 10, session: "b")]) == 1)
    }

    // MARK: Waiting

    @Test func awayWhileAnAgentWorksIsWaitingUpToTheCap() {
        // Worked until 0:30, left; the agent ran from 0:20 to 2:00.
        let waiting = AgentMetrics.waiting(user: [user(0, 30)], agents: [agent(20, 100)], categories: categories,
                                           config: AgentWaitingConfig(idleCap: 60 * 60))
        #expect(waiting == [WaitingInterval(interval(30, 60), kind: .idle)])
    }

    @Test func comingBackEndsTheWait() {
        let waiting = AgentMetrics.waiting(user: [user(0, 30), user(40, 20)], agents: [agent(20, 100)], categories: categories)
        #expect(waiting.filter { $0.kind == .idle }.map(\.interval) == [interval(30, 10), interval(60, 60)])
    }

    @Test func distractionWhileAnAgentWorksIsWaiting() {
        let waiting = AgentMetrics.waiting(user: [user(0, 10, "code"), user(10, 20, "entertainment")],
                                           agents: [agent(5, 15)], categories: categories)
        #expect(waiting.contains(WaitingInterval(interval(10, 10), kind: .distracting)))
        // Coding alongside the agent is just work.
        #expect(!waiting.contains { $0.kind == .distracting && $0.interval.start < t0 + 600 })
    }

    @Test func noWaitingWithoutEarlierActivity() {
        // An agent running overnight before the user showed up.
        let waiting = AgentMetrics.waiting(user: [user(120, 30)], agents: [agent(0, 100)], categories: categories)
        #expect(waiting.isEmpty)
    }

    @Test func noAgentsNoWaiting() {
        #expect(AgentMetrics.waiting(user: [user(0, 30)], agents: [], categories: categories).isEmpty)
    }

    @Test func overlapSaysWhatTheUserDid() {
        let overlap = AgentMetrics.overlap(user: [user(0, 10, "code"), user(20, 10, "entertainment")], with: [interval(5, 20)])
        #expect(overlap.byCategory == ["code": 300, "entertainment": 300])
        #expect(overlap.away == 600)
    }

    // MARK: Day metrics

    @Test func trackedTimeAddsIdleWaitingButTheScoreStaysTheUsers() {
        let samples = [user(0, 60, "code"), user(60, 30, "entertainment")]
        let waiting = AgentMetrics.waiting(user: samples, agents: [agent(50, 70)], categories: categories)
        let plain = DayMetrics.compute(samples, categories: categories)
        let withAgents = DayMetrics.compute(samples, waiting: waiting, categories: categories)
        #expect(withAgents.activeTime == plain.activeTime)
        #expect(withAgents.distractingWhileWaiting == 30 * 60)
        #expect(withAgents.agentWaitingIdle == 30 * 60)
        #expect(withAgents.trackedTime == plain.activeTime + 30 * 60)
        #expect(withAgents.agentWaitingTime == 60 * 60)
        #expect(withAgents.score == plain.score)
    }

    @Test func dailyCutsWaitingAtMidnight() {
        let day0 = DateInterval(start: t0, duration: 86400)
        let day1 = DateInterval(start: t0 + 86400, duration: 86400)
        let waiting = [WaitingInterval(DateInterval(start: t0 + 86400 - 600, duration: 1200), kind: .idle)]
        let days = DayMetrics.daily([user(0, 10)], waiting: waiting, days: [day0, day1], categories: categories)
        #expect(days.map(\.agentWaitingIdle) == [600, 600])
        #expect(PeriodSummary(days).total.agentWaitingIdle == 600)
    }

    // MARK: Blocks and layout

    @Test func blocksJoinASessionsPiecesAcrossShortPauses() {
        let blocks = AgentBlocks.build([
            agent(0, 10, turn: "t1"), agent(15, 10, turn: "t2"), agent(60, 5, turn: "t3"),
            agent(5, 30, session: "claude:b"),
        ])
        #expect(blocks.count == 3)
        let first = blocks[0]
        #expect(first.sessionKey == "claude:a")
        #expect(first.pieces == [interval(0, 10), interval(15, 10)])
        #expect(first.turnCount == 2)
        #expect(first.activeTime == 20 * 60)
        #expect(blocks[1].sessionKey == "claude:b")
    }

    @Test func columnsSplitOnlyWhereThingsOverlap() {
        let placements = ColumnLayout.place([interval(0, 30), interval(10, 30), interval(50, 10), interval(20, 5)])
        #expect(placements[0] == ColumnLayout.Placement(column: 0, columns: 3))
        #expect(placements[1] == ColumnLayout.Placement(column: 1, columns: 3))
        #expect(placements[3] == ColumnLayout.Placement(column: 2, columns: 3))
        #expect(placements[2] == ColumnLayout.Placement(column: 0, columns: 1))
    }
}
