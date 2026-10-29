import Foundation

/// A stream of work in one category, e.g. "Code, 9:10–10:55". Streams of different
/// categories may overlap, because people work on several things at once. Each gets a
/// one-sentence description from the on-device model.
public struct TimeEntry: Identifiable {
    public var categoryKey: String
    /// Segments in time order.
    public private(set) var segments: [ActivitySegment]
    public let start: Date
    /// `end` and `activeTime` are kept up as segments join instead of read from them again:
    /// reading a model's properties is slow, and the timeline asks for these many times per
    /// render. As of `TimeEntries.build`.
    public private(set) var end: Date
    public private(set) var activeTime: TimeInterval

    /// `start` and `end` are the segment's, read once by the caller.
    init(categoryKey: String, segment: ActivitySegment, start: Date, end: Date) {
        self.categoryKey = categoryKey
        segments = [segment]
        self.start = start
        self.end = end
        activeTime = end.timeIntervalSince(start)
    }

    mutating func append(_ segment: ActivitySegment, start: Date, end: Date) {
        segments.append(segment)
        self.end = max(self.end, end)
        activeTime += end.timeIntervalSince(start)
    }

    /// Stable as the stream grows, so descriptions can be cached by it.
    public var key: String { "\(categoryKey)-\(Int(start.timeIntervalSince1970))" }
    public var id: String { key }

    /// Apps and sites by time spent, most first.
    public var usage: [(name: String, bundleID: String, time: TimeInterval)] {
        var time: [String: (String, TimeInterval)] = [:]
        for segment in segments {
            let name = segment.domain ?? segment.appName
            time[name, default: (segment.bundleID, 0)].1 += segment.duration
        }
        return time.map { (name: $0.key, bundleID: $0.value.0, time: $0.value.1) }.sorted { $0.time > $1.time }
    }

    /// Cleaned window titles, the ones looked at longest first.
    public var titles: [String] {
        var time: [String: TimeInterval] = [:]
        for segment in segments {
            guard let title = segment.title.flatMap({ ActivityBlock.clean($0, appName: segment.appName) }) else { continue }
            time[title, default: 0] += segment.duration
        }
        return time.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Used when no model is available: "iTerm2, github.com and Xcode".
    public var fallbackDescription: String {
        let names = usage.prefix(3).map(\.name)
        switch names.count {
        case 0: return String(localized: "Activity", bundle: .module)
        case 1: return names[0]
        default:
            let head = names.dropLast().joined(separator: ", "), last = names[names.count - 1]
            return String(localized: "\(head) and \(last)", bundle: .module)
        }
    }

    /// A stream is finished once nothing could still join it.
    public func isComplete(now: Date, mergeGap: TimeInterval = TimeEntryConfig().mergeGap) -> Bool {
        now.timeIntervalSince(end) > mergeGap
    }

    /// What the model sees: apps, sites and the window titles looked at longest. Stays on
    /// the device.
    public var facts: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let apps = usage.prefix(6).map { "\($0.name) \(Int(($0.time / 60).rounded()))m" }
        let titles = titles.prefix(12).map { "- \($0.prefix(90))" }
        return """
            Time: \(formatter.string(from: start))–\(formatter.string(from: end)), \(Int((activeTime / 60).rounded())) minutes active
            Apps and websites: \(apps.joined(separator: ", "))
            Window titles, most time first:
            \(titles.isEmpty ? "(none)" : titles.joined(separator: "\n"))
            """
    }
}

public struct TimeEntryConfig: Sendable {
    /// Activity in the same category this close together belongs to one stream.
    public var mergeGap: TimeInterval = 30 * 60
    /// Streams are split once they would span longer than this.
    public var maxSpan: TimeInterval = 2 * 3600
    /// Streams with less activity than this are too small to show on the timeline.
    public var minActiveTime: TimeInterval = 10 * 60

    public init() {}
}

public enum TimeEntries {
    /// All streams of the day, including ones below `minActiveTime`; see `significant`.
    public static func build(_ segments: [ActivitySegment], config: TimeEntryConfig = TimeEntryConfig()) -> [TimeEntry] {
        var entries: [TimeEntry] = []
        // Each segment's properties are read once, as reading a model's is slow.
        let spans = segments.map { (segment: $0, start: $0.start, end: $0.end, categoryKey: $0.categoryKey) }
        for (category, members) in Dictionary(grouping: spans, by: \.categoryKey) {
            // The category's stream still taking segments, grown in place so its segments
            // aren't copied on every append.
            var open: Int?
            for member in members.sorted(by: { $0.start < $1.start }) {
                if let index = open,
                   member.start.timeIntervalSince(entries[index].end) <= config.mergeGap,
                   member.end.timeIntervalSince(entries[index].start) <= config.maxSpan {
                    entries[index].append(member.segment, start: member.start, end: member.end)
                } else {
                    entries.append(TimeEntry(categoryKey: category, segment: member.segment, start: member.start, end: member.end))
                    open = entries.count - 1
                }
            }
        }
        return entries.sorted { $0.start < $1.start }
    }

    /// The streams worth showing on the timeline.
    public static func significant(_ entries: [TimeEntry], config: TimeEntryConfig = TimeEntryConfig()) -> [TimeEntry] {
        entries.filter { $0.activeTime >= config.minActiveTime }
    }
}
