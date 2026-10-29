import WeftKit
import SwiftUI

/// A calendar-style day of work streams: the user's own and their coding agents'. Streams
/// can overlap, so they're laid out side by side like concurrent calendar events; sessions
/// get a lane of their own.
struct DayTimeline: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let segments: [ActivitySegment]
    let sessions: [SessionRecord]
    var agents: [AgentBlock] = []
    var agentSessions: [String: AgentSession] = [:]
    /// The user's own time, to say what they did while an agent worked.
    var userSamples: [SegmentSample] = []
    /// Switches to the log, where the short streams are.
    var showLog: () -> Void = {}

    /// Hours with activity are scaled so a full day fits about this height.
    private let targetHeight: CGFloat = 600
    private let pointsPerHourRange: ClosedRange<CGFloat> = 48...120
    /// Folded idle stretches.
    private let gapHeight: CGFloat = 24
    /// Short streams still get room for a line of text.
    private let minimumHeight: CGFloat = 30
    private let timeColumn: CGFloat = 44
    private let sessionColumn: CGFloat = 104
    private let spacing: CGFloat = 12
    /// Between streams side by side.
    private let gutter: CGFloat = 6

    var body: some View {
        if Calendar.current.isDateInToday(day) {
            // Keeps the now line and the live stream moving between store changes.
            TimelineView(.periodic(from: .now, by: 60)) { context in content(now: context.date) }
        } else {
            content(now: .now)
        }
    }

    private func content(now: Date) -> some View {
        let all = TimeEntries.build(segments)
        let entries = TimeEntries.significant(all)
        let shownAgents = AgentBlocks.significant(agents)
        let hidden = all.count - entries.count
        let hiddenAgents = agents.count - shownAgents.count
        let live = liveEntry(entries, now: now)
        let items = entries.map { Item.stream($0, isLive: $0.id == live?.id) }
            + shownAgents.map { Item.agent($0, isLive: isLive($0, now: now)) }
        let scale = makeScale(items, now: now)
        let height = scale.height
        let placed = layout(items, scale: scale, now: now)

        return VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                ContentUnavailableView("No work streams yet", systemImage: "calendar.day.timeline.left",
                                       description: Text("Streams appear once you've spent 10 minutes or more on something."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ZStack(alignment: .topLeading) {
                    grid(scale)
                    HStack(alignment: .top, spacing: spacing) {
                        Color.clear.frame(width: timeColumn, height: height)
                        GeometryReader { proxy in
                            ZStack(alignment: .topLeading) {
                                ForEach(placed, id: \.item.id) { placed in
                                    let column = (proxy.size.width - CGFloat(placed.columns - 1) * gutter) / CGFloat(placed.columns)
                                    let top = scale.y(placed.item.start)
                                    itemView(placed.item, scale: scale, top: top)
                                        .frame(width: column * CGFloat(placed.span) + gutter * CGFloat(placed.span - 1),
                                               height: max(minimumHeight, scale.y(placed.item.drawnEnd(now: now)) - top - 3))
                                        .offset(x: CGFloat(placed.column) * (column + gutter), y: top)
                                }
                            }
                        }
                        .frame(height: height)
                        if !sessions.isEmpty {
                            ZStack(alignment: .topLeading) {
                                ForEach(sessions) { session in
                                    SessionBlockView(session: session)
                                        .frame(width: sessionColumn, height: max(4, scale.y(session.end) - scale.y(session.start) - 2))
                                        .offset(y: scale.y(session.start))
                                }
                            }
                            .frame(width: sessionColumn, height: height, alignment: .topLeading)
                        }
                    }
                }
                .frame(height: height, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if Calendar.current.isDateInToday(day), scale.contains(now) {
                        nowLine.offset(y: scale.y(now) - 4)
                    }
                }
            }
            if hidden > 0 || hiddenAgents > 0 {
                HStack(spacing: 4) {
                    Text(hiddenText(streams: hidden, agents: hiddenAgents))
                    if hidden > 0 {
                        Button("Show in Log", action: showLog).buttonStyle(.link)
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.leading, timeColumn + spacing)
            }
        }
    }

    // MARK: Geometry

    /// Maps times to y: active hours to scale, idle stretches folded to a thin band.
    private struct Scale {
        var axis: TimelineAxis
        var pointsPerHour: CGFloat
        var gapHeight: CGFloat

        func height(of section: TimelineAxis.Section) -> CGFloat {
            switch section {
            case .time(let interval): CGFloat(interval.duration / 3600) * pointsPerHour
            case .gap: gapHeight
            }
        }

        var height: CGFloat { axis.sections.reduce(0) { $0 + height(of: $1) } }

        func contains(_ date: Date) -> Bool {
            axis.sections.contains { if case .time(let interval) = $0 { interval.contains(date) } else { false } }
        }

        /// Where `section` starts.
        func top(_ index: Int) -> CGFloat {
            axis.sections.prefix(index).reduce(0) { $0 + height(of: $1) }
        }

        func y(_ date: Date) -> CGFloat {
            var offset: CGFloat = 0
            for section in axis.sections {
                let interval = section.interval
                if date < interval.end || section == axis.sections.last {
                    switch section {
                    case .time:
                        return offset + CGFloat(max(0, date.timeIntervalSince(interval.start)) / 3600) * pointsPerHour
                    case .gap:
                        return offset + (date <= interval.start ? 0 : gapHeight)
                    }
                }
                offset += height(of: section)
            }
            return offset
        }
    }

    /// The time around the streams, sessions and (today) now, with idle stretches folded;
    /// scaled down on long days so the timeline stays about one screen tall.
    private func makeScale(_ items: [Item], now: Date) -> Scale {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let isToday = calendar.isDateInToday(day)

        func scale(minimumSpan: TimeInterval) -> Scale {
            // Short streams are drawn taller than their time; cover that so they can't run
            // into a gap.
            var intervals = items.map { DateInterval(start: $0.start, end: max($0.drawnEnd(now: now), $0.start.addingTimeInterval(minimumSpan))) }
            intervals += sessions.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            if isToday { intervals.append(DateInterval(start: now, duration: 0)) }
            let axis = TimelineAxis(covering: intervals, within: DateInterval(start: dayStart, end: dayEnd))
            let hours = axis.sections.reduce(0.0) { total, section in
                if case .time(let interval) = section { total + interval.duration / 3600 } else { total }
            }
            let fitted = targetHeight / CGFloat(max(hours, 1))
            let pointsPerHour = min(max(fitted, pointsPerHourRange.lowerBound), pointsPerHourRange.upperBound)
            return Scale(axis: axis, pointsPerHour: pointsPerHour, gapHeight: gapHeight)
        }

        // The minimum height depends on the scale, which depends on the axis: one pass to find
        // the scale, a second with room for it (a little extra, as the scale can shrink).
        let rough = scale(minimumSpan: 0)
        return scale(minimumSpan: TimeInterval(minimumHeight / rough.pointsPerHour * 3600) * 1.15)
    }

    /// The stream the user is in right now: the tracker's current category, still being
    /// extended. Segments are extended at least once a minute while active.
    private func liveEntry(_ entries: [TimeEntry], now: Date) -> TimeEntry? {
        guard Calendar.current.isDateInToday(day), let key = model.tracker.currentCategory?.key else { return nil }
        return entries.last { $0.categoryKey == key && now.timeIntervalSince($0.end) < 3 * 60 }
    }

    /// A stream of the user's own work or an agent's: both are laid out together.
    private enum Item {
        case stream(TimeEntry, isLive: Bool)
        case agent(AgentBlock, isLive: Bool)

        var id: String {
            switch self {
            case .stream(let entry, _): "stream-\(entry.id)"
            case .agent(let block, _): "agent-\(block.id)"
            }
        }

        var start: Date {
            switch self {
            case .stream(let entry, _): entry.start
            case .agent(let block, _): block.start
            }
        }

        /// Live streams run up to now.
        func drawnEnd(now: Date) -> Date {
            switch self {
            case .stream(let entry, let isLive): isLive ? max(entry.end, now) : entry.end
            case .agent(let block, let isLive): isLive ? max(block.end, now) : block.end
            }
        }
    }

    private struct Placed {
        var item: Item
        var column: Int
        var columns: Int
        var span: Int
    }

    /// Calendar-style layout: overlapping streams share the width in columns, and each
    /// widens into columns nothing beside it needs.
    private func layout(_ items: [Item], scale: Scale, now: Date) -> [Placed] {
        // Use the drawn extent, including the minimum height, so text never overlaps.
        let minimumSpan = TimeInterval(minimumHeight / scale.pointsPerHour * 3600)
        let extents = items.map { DateInterval(start: $0.start, end: max($0.drawnEnd(now: now), $0.start.addingTimeInterval(minimumSpan))) }
        return zip(items, ColumnLayout.place(extents)).map { Placed(item: $0, column: $1.column, columns: $1.columns, span: $1.span) }
    }

    @ViewBuilder
    private func itemView(_ item: Item, scale: Scale, top: CGFloat) -> some View {
        switch item {
        case .stream(let entry, let isLive):
            StreamView(entry: entry, isLive: isLive)
        case .agent(let block, let isLive):
            AgentBlockView(block: block, session: agentSessions[block.sessionKey], isLive: isLive,
                           pieces: block.pieces.map { (scale.y($0.start) - top)...(scale.y($0.end) - top) },
                           userSamples: userSamples)
        }
    }

    private func hiddenText(streams: Int, agents: Int) -> String {
        var parts: [String] = []
        if streams > 0 { parts.append(streams == 1 ? String(localized: "1 short stream") : String(localized: "\(streams) short streams")) }
        if agents > 0 { parts.append(agents == 1 ? String(localized: "1 short agent run") : String(localized: "\(agents) short agent runs")) }
        return parts.joined(separator: String(localized: " and ")) + String(localized: " under 10 minutes not shown.")
    }

    /// The agent is working now, so its block runs up to the present. Like streams, a block
    /// ends where its log last moved until the store catches up.
    private func isLive(_ block: AgentBlock, now: Date) -> Bool {
        Calendar.current.isDateInToday(day) && model.agents.liveSessions.contains(block.sessionKey)
            && now.timeIntervalSince(block.end) < 3 * 60
    }

    private func grid(_ scale: Scale) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(scale.axis.sections.enumerated()), id: \.offset) { index, section in
                switch section {
                case .time(let interval):
                    ForEach(marks(in: interval, isLast: index == scale.axis.sections.count - 1, scale: scale), id: \.self) { date in
                        hourLine(date).offset(y: scale.y(date) - 6)
                    }
                case .gap(let interval):
                    Text("No activity · \(Format.duration(interval.duration))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: scale.gapHeight)
                        .padding(.leading, timeColumn + 8)
                        .offset(y: scale.top(index))
                }
            }
        }
    }

    /// The section's start, the whole hours inside it, and the end of the last one. Hours
    /// right next to a boundary are left out so labels don't collide; the end of a section
    /// before a gap is left to the gap.
    private func marks(in interval: DateInterval, isLast: Bool, scale: Scale) -> [Date] {
        let calendar = Calendar.current
        let clearance = TimeInterval(16 / scale.pointsPerHour * 3600)
        var marks = [interval.start]
        var hour = calendar.dateInterval(of: .hour, for: interval.start)?.end ?? interval.end
        while hour < interval.end {
            if hour.timeIntervalSince(interval.start) >= clearance, interval.end.timeIntervalSince(hour) >= clearance {
                marks.append(hour)
            }
            hour = calendar.date(byAdding: .hour, value: 1, to: hour) ?? interval.end
        }
        if isLast { marks.append(interval.end) }
        return marks
    }

    private func hourLine(_ date: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: timeColumn, alignment: .trailing)
            Rectangle().fill(.quaternary).frame(height: 1)
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
    let isLive: Bool
    @State private var isHovering = false
    @State private var showDetail = false

    var body: some View {
        let category = model.classifier.category(entry.categoryKey)
        let text = description
        GeometryReader { proxy in
            let height = proxy.size.height
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(category.color).frame(width: 4)
                Group {
                    if height < 44 {
                        // One line: there's no room for the description underneath.
                        HStack(spacing: 6) {
                            Text(category.displayName).fontWeight(.semibold).foregroundStyle(category.color)
                            Text(text.body).foregroundStyle(text.isPlaceholder ? .secondary : .primary)
                            Spacer(minLength: 4)
                            Text(timeLabel).foregroundStyle(.secondary).layoutPriority(1)
                        }
                        .font(.caption)
                        .lineLimit(1)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(category.displayName).fontWeight(.semibold).foregroundStyle(category.color)
                                Text(timeLabel).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .lineLimit(1)
                            Text(text.body)
                                .font(.callout)
                                .foregroundStyle(text.isPlaceholder ? .secondary : .primary)
                                .lineLimit(height >= 80 ? 2 : 1)
                            // Fill tall blocks with what the time went to.
                            let rows = Int((height - (height >= 80 ? 74 : 56)) / 18)
                            if rows > 0 {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(entry.usage.prefix(min(rows, 5)), id: \.name) { item in
                                        HStack(spacing: 5) {
                                            Image(nsImage: AppIcons.icon(for: item.bundleID)).resizable().frame(width: 12, height: 12)
                                            Text(item.name).lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(Format.duration(item.time)).monospacedDigit()
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(height: 16)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
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

    private var timeLabel: String {
        let end = isLive ? String(localized: "now") : entry.end.formatted(date: .omitted, time: .shortened)
        return "\(entry.start.formatted(date: .omitted, time: .shortened))–\(end) · \(Format.duration(entry.activeTime))"
    }

    private var description: (body: String, isPlaceholder: Bool) {
        if let text = model.timeEntries.description(for: entry) { return (text, false) }
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
                // Fixes this stream only; rules for an app or site live in the log.
                Menu {
                    ForEach(model.classifier.categories.filter { $0.key != CategoryDefinition.uncategorizedKey }) { option in
                        Button(option.displayName) {
                            for segment in entry.segments { model.classifier.setManualCategory(option.key, for: segment) }
                        }
                    }
                } label: {
                    CategoryChip(category: category)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change the category of this stream")
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
