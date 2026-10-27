import OpenRizeKit
import SwiftUI

/// A calendar-style day of work streams. Streams in different categories can overlap, so
/// they're laid out side by side like concurrent calendar events; sessions get their own lane.
struct DayTimeline: View {
    let day: Date
    let segments: [ActivitySegment]
    let sessions: [SessionRecord]

    private let pointsPerHour: CGFloat = 120
    /// Short streams still get room for a line of text.
    private let minimumHeight: CGFloat = 30
    private let timeColumn: CGFloat = 44
    private let sessionColumn: CGFloat = 104
    private let spacing: CGFloat = 12

    var body: some View {
        let all = TimeEntries.build(segments)
        let entries = TimeEntries.significant(all)
        let hidden = all.count - entries.count
        let range = visibleRange(entries)
        let hours = Int((range.upperBound.timeIntervalSince(range.lowerBound) / 3600).rounded())
        let height = CGFloat(hours) * pointsPerHour
        let placed = layout(entries)

        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                ContentUnavailableView("No work streams yet", systemImage: "calendar.day.timeline.left",
                                       description: Text("Streams appear once you've spent 10 minutes or more on something."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ZStack(alignment: .topLeading) {
                    hourGrid(range: range, hours: hours)
                    HStack(alignment: .top, spacing: spacing) {
                        Color.clear.frame(width: timeColumn, height: height)
                        GeometryReader { proxy in
                            ZStack(alignment: .topLeading) {
                                ForEach(placed, id: \.entry.id) { item in
                                    let width = (proxy.size.width - CGFloat(item.columns - 1) * 6) / CGFloat(item.columns)
                                    StreamView(entry: item.entry)
                                        .frame(width: width, height: itemHeight(item.entry, range))
                                        .offset(x: CGFloat(item.column) * (width + 6), y: y(item.entry.start, range))
                                }
                            }
                        }
                        .frame(height: height)
                        ZStack(alignment: .topLeading) {
                            ForEach(sessions) { session in
                                SessionBlockView(session: session)
                                    .frame(width: sessionColumn, height: max(4, y(session.end, range) - y(session.start, range) - 2))
                                    .offset(y: y(session.start, range))
                            }
                        }
                        .frame(width: sessionColumn, height: height, alignment: .topLeading)
                    }
                }
                .frame(height: height, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if Calendar.current.isDateInToday(day), range.contains(.now) {
                        nowLine.offset(y: y(.now, range) - 4)
                    }
                }
            }
            if hidden > 0 {
                Text("\(hidden) short stream\(hidden == 1 ? "" : "s") under 10 minutes not shown — see Log.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.leading, timeColumn + spacing)
            }
        }
    }

    // MARK: Geometry

    private func y(_ date: Date, _ range: ClosedRange<Date>) -> CGFloat {
        CGFloat(date.timeIntervalSince(range.lowerBound) / 3600) * pointsPerHour
    }

    private func itemHeight(_ entry: TimeEntry, _ range: ClosedRange<Date>) -> CGFloat {
        max(minimumHeight, y(entry.end, range) - y(entry.start, range) - 3)
    }

    /// Whole hours covering the streams and sessions (and now, for today), with an hour of
    /// breathing room before and at least half an hour after, kept within the day.
    private func visibleRange(_ entries: [TimeEntry]) -> ClosedRange<Date> {
        let calendar = Calendar.current
        var first = entries.map(\.start).min() ?? .now
        var last = entries.map(\.end).max() ?? .now
        for session in sessions {
            first = min(first, session.start)
            last = max(last, session.end)
        }
        if calendar.isDateInToday(day) { last = max(last, .now) }
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let lower = max(dayStart, (calendar.dateInterval(of: .hour, for: first)?.start ?? first).addingTimeInterval(-3600))
        let padded = last.addingTimeInterval(30 * 60)
        let upper = min(dayEnd, calendar.dateInterval(of: .hour, for: padded)?.end ?? padded)
        return lower...max(upper, lower.addingTimeInterval(3600))
    }

    private struct Placed {
        var entry: TimeEntry
        var column: Int
        var columns: Int
    }

    /// Calendar-style layout: overlapping streams share the width in columns.
    private func layout(_ entries: [TimeEntry]) -> [Placed] {
        // Use the drawn extent, including the minimum height, so text never overlaps.
        let minimumSpan = TimeInterval(minimumHeight / pointsPerHour * 3600)
        func visualEnd(_ entry: TimeEntry) -> Date { max(entry.end, entry.start.addingTimeInterval(minimumSpan)) }

        var result: [Placed] = []
        var cluster: [Placed] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let count = max(1, columnEnds.count)
            result += cluster.map { Placed(entry: $0.entry, column: $0.column, columns: count) }
            cluster = []
            columnEnds = []
        }

        for entry in entries.sorted(by: { $0.start < $1.start }) {
            if entry.start >= clusterEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= entry.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(visualEnd(entry)) } else { columnEnds[column] = visualEnd(entry) }
            cluster.append(Placed(entry: entry, column: column, columns: 1))
            clusterEnd = max(clusterEnd, visualEnd(entry))
        }
        flush()
        return result
    }

    private func hourGrid(range: ClosedRange<Date>, hours: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...hours, id: \.self) { hour in
                let date = range.lowerBound.addingTimeInterval(TimeInterval(hour * 3600))
                HStack(alignment: .center, spacing: 8) {
                    Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: timeColumn, alignment: .trailing)
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
                .offset(y: CGFloat(hour) * pointsPerHour - 6)
            }
        }
    }

    private var nowLine: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColumn + spacing - 4)
            Circle().fill(.red).frame(width: 8, height: 8)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .frame(height: 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Streams

private struct StreamView: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    @State private var isHovering = false
    @State private var showDetail = false

    var body: some View {
        let category = model.classifier.category(entry.categoryKey)
        let text = description
        GeometryReader { proxy in
            let height = proxy.size.height
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(category.color).frame(width: 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(category.name).fontWeight(.semibold).foregroundStyle(category.color)
                        Text("\(entry.start.formatted(date: .omitted, time: .shortened))–\(entry.end.formatted(date: .omitted, time: .shortened)) · \(Format.duration(entry.activeTime))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .lineLimit(1)
                    if height >= 44 {
                        Text(text.body)
                            .font(.callout)
                            .foregroundStyle(text.isPlaceholder ? .secondary : .primary)
                            .lineLimit(max(1, Int((height - 30) / 17)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            .background(category.color.opacity(isHovering ? 0.24 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { showDetail = true }
        .help(text.body)
        .popover(isPresented: $showDetail) { StreamDetail(entry: entry, text: text.body) }
    }

    private var description: (body: String, isPlaceholder: Bool) {
        if let text = model.timeEntries.description(for: entry) { return (text, false) }
        if !entry.isComplete(now: .now) { return ("In progress · \(entry.fallbackDescription)", true) }
        return (entry.fallbackDescription, model.classifier.aiAvailability == .available)
    }
}

private struct StreamDetail: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    let text: String

    var body: some View {
        let category = model.classifier.category(entry.categoryKey)
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end.formatted(date: .omitted, time: .shortened)) · \(Format.duration(entry.activeTime)) active")
                    .foregroundStyle(.secondary)
                Spacer()
                CategoryChip(category: category)
            }
            .font(.callout)
            Divider()
            ForEach(entry.usage.prefix(8), id: \.name) { item in
                HStack {
                    Image(nsImage: AppIcons.icon(for: item.bundleID)).resizable().frame(width: 16, height: 16)
                    Text(item.name)
                    Spacer()
                    Text(Format.duration(item.time)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            let titles = entry.titles
            if !titles.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(titles.prefix(6), id: \.self) { title in
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Sessions

private struct SessionBlockView: View {
    let session: SessionRecord

    var body: some View {
        let color: Color = switch session.kind {
        case .focus: .cyan
        case .meeting: .teal
        case .breakTime: .indigo
        }
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.75))
                if proxy.size.height >= 18 {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(session.kind.title, systemImage: session.kind.symbol).font(.caption.weight(.semibold))
                        if proxy.size.height >= 34 {
                            Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(5)
                }
            }
        }
        .help("\(session.kind.title) session · \(Format.duration(session.end.timeIntervalSince(session.start)))")
    }
}
