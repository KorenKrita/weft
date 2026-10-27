import Foundation

/// The vertical axis of the day timeline: the time around activity, rounded to quarter
/// hours, with idle stretches between them folded into gaps so they don't take up the screen.
public struct TimelineAxis: Equatable {
    public enum Section: Equatable {
        /// Drawn to scale.
        case time(DateInterval)
        /// Drawn as a thin band, whatever its length. `idle` is how long nothing happened,
        /// which is longer than the band's interval because of the padding around activity.
        case gap(DateInterval, idle: TimeInterval)

        public var interval: DateInterval {
            switch self {
            case .time(let interval), .gap(let interval, _): interval
            }
        }
    }

    public var sections: [Section]

    /// - Parameters:
    ///   - intervals: what must be visible (streams, sessions, the current time).
    ///   - day: the axis never leaves this.
    ///   - padding: room kept before and after activity.
    ///   - step: section edges are rounded out to multiples of this within the hour, unless
    ///     that would close a gap.
    ///   - minimumIdle: shorter idle stretches stay to scale.
    public init(covering intervals: [DateInterval], within day: DateInterval,
                padding: TimeInterval = 10 * 60, step: TimeInterval = 15 * 60,
                minimumIdle: TimeInterval = 45 * 60, calendar: Calendar = .current) {
        func floor(_ date: Date) -> Date {
            guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return date }
            return hour.addingTimeInterval((date.timeIntervalSince(hour) / step).rounded(.down) * step)
        }
        func ceil(_ date: Date) -> Date {
            let down = floor(date)
            return down == date ? date : down.addingTimeInterval(step)
        }

        // Activity with less idle time between it than `minimumIdle` stays together.
        var clusters: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = clusters.last, interval.start.timeIntervalSince(last.end) < minimumIdle {
                clusters[clusters.count - 1].end = max(last.end, interval.end)
            } else {
                clusters.append(interval)
            }
        }

        var bounds = clusters.map {
            DateInterval(start: max(day.start, floor($0.start.addingTimeInterval(-padding))),
                         end: min(day.end, ceil($0.end.addingTimeInterval(padding))))
        }
        for index in bounds.indices.dropFirst() where bounds[index].start <= bounds[index - 1].end {
            // Rounding closed the gap; keep the exact padded edges instead. (Setting a
            // DateInterval's start moves its end too, so build new ones.)
            bounds[index - 1] = DateInterval(start: bounds[index - 1].start,
                                             end: clusters[index - 1].end.addingTimeInterval(padding))
            bounds[index] = DateInterval(start: clusters[index].start.addingTimeInterval(-padding),
                                         end: bounds[index].end)
        }

        sections = []
        for index in bounds.indices {
            if index > 0 {
                sections.append(.gap(DateInterval(start: bounds[index - 1].end, end: bounds[index].start),
                                     idle: clusters[index].start.timeIntervalSince(clusters[index - 1].end)))
            }
            sections.append(.time(bounds[index]))
        }
    }

    public var start: Date? { sections.first?.interval.start }
    public var end: Date? { sections.last?.interval.end }
}
