import Foundation

/// One row of the activity list: a stretch of time in one app/site and category, with brief
/// detours to other apps folded in.
public struct ActivityBlock: Identifiable {
    /// Segments that belong to this app/site, in time order.
    public var segments: [ActivitySegment]
    /// Short visits to other apps/sites in the middle of this block.
    public var interruptions: [ActivitySegment] = []

    public var id: ObjectIdentifier { ObjectIdentifier(segments[0]) }
    public var first: ActivitySegment { segments[0] }
    public var start: Date { first.start }
    public var end: Date { max(segments[segments.count - 1].end, interruptions.map(\.end).max() ?? .distantPast) }
    /// Time spent in this block's own app/site, excluding interruptions.
    public var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    public var categoryKey: String { first.categoryKey }

    var key: String { Self.key(first) }

    static func key(_ segment: ActivitySegment) -> String {
        "\(segment.bundleID)|\(segment.domain ?? "")|\(segment.categoryKey)"
    }

    /// Distinct, cleaned-up window titles, the ones looked at longest first.
    public var titles: [String] {
        var time: [String: TimeInterval] = [:]
        var order: [String] = []
        for segment in segments {
            guard let title = segment.title.flatMap({ Self.clean($0, appName: segment.appName) }) else { continue }
            if time[title] == nil { order.append(title) }
            time[title, default: 0] += segment.duration
        }
        return order.sorted { time[$0, default: 0] > time[$1, default: 0] }
    }

    /// Distinct apps/sites visited briefly, for a tooltip.
    public var interruptionNames: [String] {
        var seen = Set<String>()
        return interruptions.map { $0.domain ?? $0.appName }.filter { seen.insert($0).inserted }
    }

    /// Drops browser suffixes ("… - Google Chrome - Profile") and titles that are just
    /// identifiers (hashes, encoded URLs) with nothing to read.
    static func clean(_ title: String, appName: String) -> String? {
        var title = title
        if let range = title.range(of: " - \(appName)", options: .backwards) {
            title = String(title[..<range.lowerBound])
        }
        title = stripStatusPrefix(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !title.isEmpty, title != appName else { return nil }
        let longestWord = title.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 0
        if longestWord > 40 { return nil }
        return title
    }
}

extension ActivityBlock {
    /// Terminals prefix titles with a tab number and an animated status glyph
    /// ("1. ✳ project", "1. ◐ project"); drop them so one window isn't many titles.
    static func stripStatusPrefix(_ title: String) -> String {
        var rest = Substring(title)
        if let dot = rest.firstIndex(of: "."), dot > rest.startIndex, rest[..<dot].allSatisfy(\.isNumber),
           rest.index(after: dot) < rest.endIndex, rest[rest.index(after: dot)] == " " {
            rest = rest[rest.index(after: dot)...]
        }
        while let first = rest.unicodeScalars.first,
              first.properties.isWhitespace
                || [.otherSymbol, .mathSymbol].contains(first.properties.generalCategory)
                || (0x2800...0x28FF).contains(first.value) {  // braille spinners
            rest = rest.dropFirst()
        }
        return rest.isEmpty ? title : String(rest)
    }
}

public enum ActivityBlocks {
    /// - Parameters:
    ///   - mergeGap: segments of the same app/site this close together form one run.
    ///   - maxInterruption: detours shorter than this, in total, are folded into the block
    ///     around them when the user returns to the same app/site.
    ///   - maxInterruptionShare: folded-in time may not exceed this share of the block's own
    ///     time, so many short detours in a row can't hide a large amount of other activity.
    public static func build(_ segments: [ActivitySegment], mergeGap: TimeInterval = 60,
                             maxInterruption: TimeInterval = 120,
                             maxInterruptionShare: Double = 1.0 / 3) -> [ActivityBlock] {
        var blocks: [ActivityBlock] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let key = ActivityBlock.key(segment)

            // Continue the latest block directly.
            if var last = blocks.last, last.key == key, segment.start.timeIntervalSince(last.end) <= mergeGap {
                last.segments.append(segment)
                blocks[blocks.count - 1] = last
                continue
            }

            // Return to an earlier block after only a brief detour.
            var detour: TimeInterval = 0
            var target: Int?
            for index in blocks.indices.reversed() {
                if blocks[index].key == key { target = index; break }
                detour += blocks[index].duration + blocks[index].interruptions.reduce(0) { $0 + $1.duration }
                if detour > maxInterruption { break }
            }
            if let target, detour <= maxInterruption,
               segment.start.timeIntervalSince(blocks[target].end) <= maxInterruption + mergeGap,
               blocks[target].interruptions.reduce(0, { $0 + $1.duration }) + detour
                   <= (blocks[target].duration + segment.duration) * maxInterruptionShare {
                let absorbed = blocks[(target + 1)...].flatMap { $0.segments + $0.interruptions }
                blocks.removeSubrange((target + 1)...)
                blocks[target].interruptions += absorbed
                blocks[target].segments.append(segment)
                continue
            }

            blocks.append(ActivityBlock(segments: [segment]))
        }
        return blocks
    }
}
