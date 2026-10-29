import Foundation

/// One round of an agent working: from a prompt to the agent's answer.
public struct AgentTurn: Sendable, Equatable {
    public enum EndKind: String, Sendable {
        /// The log says the turn ended.
        case marker
        /// The next prompt came before an end marker (a crash, a kill); it ended at its last activity.
        case inferred
        /// No end yet: still running, or the log stopped mid-turn.
        case open
    }

    /// The prompt line's id (Claude) or the turn id (Codex).
    public var id: String
    public var start: Date
    public var end: Date
    public var endKind: EndKind
    public var trigger: AgentTrigger
    /// Where the turn's first line starts in the file; parsing resumes here while it's open.
    public var offset: Int64
    /// The agent waiting for the user's answer.
    public var waits: [DateInterval] = []
    /// Stretches with nothing in the log for longer than `AgentTurnConfig.silentGap`.
    public var silences: [DateInterval] = []
    /// The agent replied or used a tool. Turns without (a slash command, a probe) don't count.
    public var hasActivity = false
    public var lastActivity: Date

    public init(id: String, start: Date, end: Date, endKind: EndKind, trigger: AgentTrigger, offset: Int64,
                waits: [DateInterval] = [], silences: [DateInterval] = [], hasActivity: Bool = true, lastActivity: Date? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.endKind = endKind
        self.trigger = trigger
        self.offset = offset
        self.waits = waits
        self.silences = silences
        self.hasActivity = hasActivity
        self.lastActivity = lastActivity ?? end
    }

    /// Time spent waiting for the user, within the turn.
    public var waitedOnUser: TimeInterval {
        AgentMetrics.duration(AgentMetrics.intersect(AgentMetrics.union(waits), [DateInterval(start: start, end: end)]))
    }
}

public struct AgentTurnConfig: Sendable, Equatable {
    /// Silence in the log longer than this inside a turn is cut out: the agent is probably
    /// stuck or waiting on something the log doesn't show.
    public var silentGap: TimeInterval = 30 * 60
    /// Shorter waits are a hook or rule answering automatically, not the user.
    public var minimumWait: TimeInterval = 5
    /// Pieces shorter than this are dropped.
    public var minimumPiece: TimeInterval = 1

    public init(silentGap: TimeInterval = 30 * 60) {
        self.silentGap = silentGap
    }
}

/// Turns log events into turns, and turns into the stretches the agent was really working.
public enum AgentTurnBuilder {
    /// All turns in `events`, including ones without activity (the caller decides whether a
    /// trailing empty one still matters, e.g. as a place to resume from).
    public static func turns(_ events: [AgentLogEvent], config: AgentTurnConfig = AgentTurnConfig()) -> [AgentTurn] {
        var turns: [AgentTurn] = []
        var open: AgentTurn?
        /// Latest time seen in the open turn. Lines can be logged out of order by seconds.
        var latest = Date.distantPast

        func touch(_ date: Date, isWork: Bool) {
            guard var turn = open else { return }
            if date.timeIntervalSince(latest) > config.silentGap {
                turn.silences.append(DateInterval(start: latest, end: date))
            }
            latest = max(latest, date)
            if isWork {
                turn.hasActivity = true
                turn.lastActivity = max(turn.lastActivity, date)
            }
            open = turn
        }

        func close(_ kind: AgentTurn.EndKind, at date: Date? = nil) {
            guard var turn = open else { return }
            turn.endKind = kind
            turn.end = max(turn.start, date ?? turn.lastActivity)
            turns.append(turn)
            open = nil
        }

        for event in events {
            switch event {
            case .prompt(let id, let at, let trigger, let offset):
                if open != nil {
                    if trigger == .user {
                        close(.inferred)
                    } else {
                        touch(at, isWork: false)
                        continue
                    }
                }
                open = AgentTurn(id: id, start: at, end: at, endKind: .open, trigger: trigger, offset: offset,
                                 hasActivity: false, lastActivity: at)
                latest = at
            case .activity(let at):
                touch(at, isWork: true)
            case .progress(let at):
                touch(at, isWork: false)
            case .wait(let interval):
                guard open != nil, interval.duration >= config.minimumWait else { continue }
                open?.waits.append(interval)
                touch(interval.end, isWork: true)
            case .end(let at, let id):
                guard let turn = open else { continue }
                touch(at, isWork: false)
                // A nested turn ending (Codex) doesn't end the one around it.
                if id == nil || id == turn.id { close(.marker, at: at) }
            }
        }
        if var turn = open {
            turn.end = max(turn.start, turn.lastActivity)
            turns.append(turn)
        }
        return turns
    }

    /// The turn minus the user's answers and long silences: when the agent was working.
    public static func pieces(_ turn: AgentTurn, config: AgentTurnConfig = AgentTurnConfig()) -> [DateInterval] {
        guard turn.end > turn.start else { return [] }
        let removed = AgentMetrics.union(turn.waits + turn.silences)
        return AgentMetrics.subtract(removed, from: DateInterval(start: turn.start, end: turn.end))
            .filter { $0.duration >= config.minimumPiece }
    }

    /// Where to start reading next time: at an open turn, so it's rebuilt whole once it ends,
    /// or else after everything read so far.
    public static func resumeOffset(_ turns: [AgentTurn], consumedTo: Int64) -> Int64 {
        if let last = turns.last, last.endKind == .open { return min(last.offset, consumedTo) }
        return consumedTo
    }
}
