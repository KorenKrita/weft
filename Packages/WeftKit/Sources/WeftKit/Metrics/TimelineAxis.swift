import Foundation

/// The vertical axis of the day timeline: the time around activity, with idle stretches
/// folded into thin gaps so they don't take up the screen.
public struct TimelineAxis: Equatable {
    public enum Section: Equatable {
        /// Drawn to scale.
        case time(DateInterval)
        /// Nothing happened; drawn as a thin band, whatever its length.
        case gap(DateInterval)

        public var interval: DateInterval {
            switch self {
            case .time(let interval), .gap(let interval): interval
            }
        }
    }

    public var sections: [Section]

    /// - Parameters:
    ///   - intervals: what must be visible (streams, sessions, the current time).
    ///   - day: the axis never leaves this.
    ///   - minimumIdle: shorter idle stretches stay to scale. Longer ones become gaps that
    ///     start and end exactly where activity does, so no blank time is left around them.
    ///   - padding: room before the first and after the last activity, which are then rounded
    ///     out to multiples of `step` within the hour.
    public init(covering intervals: [DateInterval], within day: DateInterval,
                minimumIdle: TimeInterval = 30 * 60,
                padding: TimeInterval = 5 * 60, step: TimeInterval = 15 * 60,
                calendar: Calendar = .current) {
        var clusters: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            let start = min(max(interval.start, day.start), day.end)
            let end = min(max(interval.end, start), day.end)
            if let last = clusters.last, start.timeIntervalSince(last.end) < minimumIdle {
                clusters[clusters.count - 1] = DateInterval(start: last.start, end: max(last.end, end))
            } else {
                clusters.append(DateInterval(start: start, end: end))
            }
        }

        func floor(_ date: Date) -> Date {
            guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return date }
            return hour.addingTimeInterval((date.timeIntervalSince(hour) / step).rounded(.down) * step)
        }
        func ceil(_ date: Date) -> Date {
            let down = floor(date)
            return down == date ? date : down.addingTimeInterval(step)
        }

        sections = []
        for (index, cluster) in clusters.enumerated() {
            let start = index == 0 ? max(day.start, floor(cluster.start.addingTimeInterval(-padding))) : cluster.start
            let end = index == clusters.count - 1 ? min(day.end, ceil(cluster.end.addingTimeInterval(padding))) : cluster.end
            if index > 0 { sections.append(.gap(DateInterval(start: clusters[index - 1].end, end: cluster.start))) }
            sections.append(.time(DateInterval(start: start, end: end)))
        }
    }

    public var start: Date? { sections.first?.interval.start }
    public var end: Date? { sections.last?.interval.end }
}
