import Foundation

public enum TrackerEffect: Equatable, Sendable {
    /// Start a new segment for `context` at the given time.
    case open(ActivityContext, Date)
    /// Move the end of the open segment forward.
    case extend(Date)
    /// Finish the open segment at the given time.
    case close(Date)
}

/// Pure state machine that turns periodic samples of the frontmost context into segment
/// open/extend/close effects. Kept free of AppKit and storage so it can be unit tested.
public struct TrackingStateMachine: Sendable {
    /// No input for this long counts as idle; the segment is cut at the last input.
    public var idleThreshold: TimeInterval
    /// A longer gap between ticks (e.g. the process was suspended) splits the segment.
    public var maxTickGap: TimeInterval

    public private(set) var current: ActivityContext?
    public private(set) var currentStart: Date?
    public private(set) var lastTick: Date?

    public init(idleThreshold: TimeInterval = 300, maxTickGap: TimeInterval = 60) {
        self.idleThreshold = idleThreshold
        self.maxTickGap = maxTickGap
    }

    /// - Parameters:
    ///   - context: frontmost context, or nil when nothing should be tracked.
    ///   - idleSeconds: seconds since the last keyboard/mouse input.
    ///   - idleExempt: true for meetings and video calls, where no input is expected.
    public mutating func tick(now: Date, context: ActivityContext?, idleSeconds: TimeInterval, idleExempt: Bool = false) -> [TrackerEffect] {
        defer { lastTick = now }
        var effects: [TrackerEffect] = []

        if let lastTick, current != nil, now.timeIntervalSince(lastTick) > maxTickGap {
            effects += finish(at: lastTick)
        }

        guard let context else {
            return effects + finish(at: now)
        }

        if !idleExempt && idleSeconds >= idleThreshold {
            let lastInput = now.addingTimeInterval(-idleSeconds)
            return effects + finish(at: max(lastInput, currentStart ?? lastInput))
        }

        if context == current {
            effects.append(.extend(now))
        } else {
            effects += finish(at: now)
            current = context
            currentStart = now
            effects.append(.open(context, now))
        }
        return effects
    }

    /// Close the open segment, e.g. on sleep, screen lock or when the user pauses tracking.
    public mutating func suspend(at date: Date) -> [TrackerEffect] {
        lastTick = date
        return finish(at: date)
    }

    private mutating func finish(at date: Date) -> [TrackerEffect] {
        guard current != nil else { return [] }
        let end = max(date, currentStart ?? date)
        current = nil
        currentStart = nil
        return [.close(end)]
    }
}
