import Charts
import WeftKit
import SwiftData
import SwiftUI

struct DayView: View {
    @State private var day = Calendar.current.startOfDay(for: .now)

    var body: some View {
        DayContent(day: day)
            .id(day)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar {
                ToolbarItemGroup {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous day")
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Today") { day = Calendar.current.startOfDay(for: .now) }
                        .disabled(Calendar.current.isDateInToday(day))
                        .keyboardShortcut("t", modifiers: .command)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next day")
                        .disabled(Calendar.current.isDateInToday(day))
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                }
            }
    }

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }
}

enum DayTab: String, CaseIterable, Identifiable {
    case timeline, breakdown, log

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "Timeline"
        case .breakdown: "Categories & Apps"
        case .log: "Log"
        }
    }
}

private struct DayContent: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    @Query private var sessions: [SessionRecord]
    @AppStorage("todayTab") private var tab: DayTab = .timeline
    private let day: Date
    private let dayEnd: Date

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        dayEnd = end
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > day && $0.start < end }, sort: \.start)
        _sessions = Query(filter: #Predicate<SessionRecord> { $0.end > day && $0.start < end }, sort: \.start)
    }

    var body: some View {
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            sample.end = min(sample.end, dayEnd)
            return sample
        }
        let metrics = DayMetrics.compute(samples, categories: model.classifier.categoryLookup)
        let entries = TimeEntries.significant(TimeEntries.build(segments))

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if segments.isEmpty {
                    ContentUnavailableView("No activity", systemImage: "clock",
                                           description: Text("Nothing was tracked on this day."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    Overview(metrics: metrics, target: model.preferences.workHoursTarget * 3600)
                    DailyReview(day: day, metrics: metrics)
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("View", selection: $tab) {
                            ForEach(DayTab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        switch tab {
                        case .timeline:
                            DayTimeline(day: day, segments: segments, sessions: sessions)
                        case .breakdown:
                            HStack(alignment: .top, spacing: 16) {
                                Card("Categories") { CategoryBreakdown(metrics: metrics) }
                                Card("Apps & sites") { AppBreakdown(samples: samples, total: metrics.activeTime) }
                            }
                        case .log:
                            ActivityList(segments: segments)
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }
            }
            .padding(20)
        }
        // Describe finished entries of the day being viewed, including past days.
        .task(id: "\(entries.count)-\(entries.last?.key ?? "")") {
            model.timeEntries.describe(entries)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

// MARK: - Overview

/// The answer to "how did today go?": score, progress towards the target, and three
/// plain-language facts.
private struct Overview: View {
    let metrics: DayMetrics
    let target: TimeInterval
    @State private var showScoreDetails = false

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            Button { showScoreDetails = true } label: {
                ScoreRing(score: metrics.score, activeTime: metrics.activeTime, size: 112)
            }
            .buttonStyle(.plain)
            .help("How the Focus Score works")
            .popover(isPresented: $showScoreDetails) { ScoreExplanation(score: metrics.score).padding() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.duration(metrics.activeTime))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tracked of \(Format.duration(target))").foregroundStyle(.secondary)
                }
                GoalBar(metrics: metrics, target: target)
                HStack(spacing: 16) {
                    legend(GoalBar.focusColor, "Focus", metrics.focusTime)
                    legend(GoalBar.meetingColor, "Meetings", metrics.meetingTime)
                    legend(GoalBar.otherColor, "Other", max(0, metrics.activeTime - metrics.focusTime - metrics.meetingTime - metrics.distractingTime))
                    legend(GoalBar.distractedColor, "Distracted", metrics.distractingTime)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 100)

            VStack(alignment: .leading, spacing: 12) {
                Fact(symbol: "brain.head.profile", title: "Deep work",
                     value: Format.duration(metrics.deepWorkTime), detail: "in stretches of 25 min or more")
                Fact(symbol: "timer", title: "Longest focus",
                     value: Format.duration(metrics.longestFocusStretch), detail: "without a real break")
                Fact(symbol: "arrow.left.arrow.right", title: "Switching",
                     value: switching.0, detail: switching.1)
            }
            .frame(width: 230, alignment: .leading)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private var switching: (String, String) {
        guard metrics.activeTime >= 15 * 60 else { return ("\(metrics.contextSwitches) switches", "between apps and sites") }
        let perHour = metrics.switchesPerHour
        let label = perHour <= 12 ? "Steady" : perHour <= 25 ? "Some switching" : "Fragmented"
        return (label, "\(Int(perHour.rounded())) switches per hour")
    }

    private func legend(_ color: Color, _ title: String, _ value: TimeInterval) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(Format.duration(value)).monospacedDigit()
        }
        .font(.callout)
    }
}

private struct Fact: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).fontWeight(.medium).monospacedDigit()
                }
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }
}

private struct ScoreExplanation: View {
    let score: FocusScore?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How the Focus Score works").font(.headline)
            Text("100 × (½ deep-work share + ½ focus share) − switching penalty − distraction penalty. Meetings are left out.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let score {
                Divider()
                LabeledContent("Focus share", value: Format.percent(score.focusRatio))
                LabeledContent("Deep-work share (≥ 25 min stretches)", value: Format.percent(score.deepWorkRatio))
                LabeledContent("Switching penalty", value: String(format: "−%.0f", score.switchPenalty))
                LabeledContent("Distraction penalty", value: String(format: "−%.0f", score.distractionPenalty))
            } else {
                Text("Needs at least 15 minutes of tracked time.").font(.callout)
            }
        }
        .frame(width: 340)
    }
}

// MARK: - Daily review

private struct DailyReview: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let metrics: DayMetrics
    @State private var text: String?
    @State private var error: String?
    @State private var isGenerating = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.title3).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 8) {
                if let text {
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if case .unavailable(let reason) = model.classifier.aiAvailability {
                    Text("Daily reviews need Apple Intelligence. \(reason)").foregroundStyle(.secondary)
                } else {
                    Text("Get a short review of this day and a suggestion for tomorrow, written on device.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Spacer()
            if model.classifier.aiAvailability == .available {
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Button(text == nil ? "Review My Day" : "Regenerate", action: generate)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.purple.opacity(0.08)))
    }

    private func generate() {
        isGenerating = true
        error = nil
        let facts = facts()
        Task {
            do {
                text = try await model.ai.summarize(facts)
            } catch {
                self.error = "Could not generate a review: \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    /// Aggregates only — window titles and URLs never go into the prompt.
    private func facts() -> String {
        let categories = metrics.byCategory.sorted { $0.value > $1.value }.prefix(6)
            .map { "\(model.classifier.category($0.key).name) \(Format.duration($0.value))" }
        let apps = metrics.byApp.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(Format.duration($0.value))" }
        let sites = metrics.byDomain.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(Format.duration($0.value))" }
        let busiest = metrics.byHour.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):00" }
        let language = Locale.current.localizedString(forLanguageCode: Locale.preferredLanguages.first ?? "en") ?? "English"
        return """
            Respond in \(language).
            Day: \(day.formatted(date: .complete, time: .omitted))
            Tracked time: \(Format.duration(metrics.activeTime)) (target \(Format.duration(model.preferences.workHoursTarget * 3600)))
            Focus time: \(Format.duration(metrics.focusTime)); deep work (25+ minute stretches): \(Format.duration(metrics.deepWorkTime)); longest focus stretch: \(Format.duration(metrics.longestFocusStretch))
            Meetings: \(Format.duration(metrics.meetingTime)); distracting: \(Format.duration(metrics.distractingTime))
            Context switches: \(metrics.contextSwitches) (\(String(format: "%.0f", metrics.switchesPerHour)) per hour)
            Focus Score: \(metrics.score.map { "\($0.value)/100 (\($0.label))" } ?? "n/a")
            Top categories: \(categories.joined(separator: ", "))
            Top apps: \(apps.joined(separator: ", "))
            Top sites: \(sites.joined(separator: ", "))
            Busiest hours: \(busiest.joined(separator: ", "))
            """
    }
}

// MARK: - Breakdowns

private struct CategoryBreakdown: View {
    @Environment(AppModel.self) private var model
    let metrics: DayMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(metrics.byCategory.sorted { $0.value > $1.value }, id: \.key) { key, value in
                let category = model.classifier.category(key)
                BarRow(label: category.name, value: value, total: metrics.activeTime, color: category.color,
                       detail: Format.percent(value / max(metrics.activeTime, 1)))
            }
        }
    }
}

/// Time per app, with each browser's sites nested under it so nothing is counted twice.
private struct AppBreakdown: View {
    let samples: [SegmentSample]
    let total: TimeInterval
    @State private var expanded: Set<String> = []

    private struct Usage {
        var bundleID: String
        var name: String
        var time: TimeInterval = 0
        var sites: [String: TimeInterval] = [:]
    }

    var body: some View {
        let apps = usage()
        VStack(alignment: .leading, spacing: 10) {
            ForEach(apps.prefix(10), id: \.bundleID) { app in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppIcons.icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                        BarRow(label: app.name, value: app.time, total: total, color: .accentColor,
                               detail: Format.percent(app.time / max(total, 1)))
                        // Every row reserves the same slot so the bars line up.
                        Group {
                            if !app.sites.isEmpty {
                                Button {
                                    if expanded.contains(app.bundleID) { expanded.remove(app.bundleID) } else { expanded.insert(app.bundleID) }
                                } label: {
                                    Image(systemName: expanded.contains(app.bundleID) ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .help("\(app.sites.count) site\(app.sites.count == 1 ? "" : "s")")
                            }
                        }
                        .frame(width: 16)
                    }
                    if expanded.contains(app.bundleID) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(app.sites.sorted { $0.value > $1.value }.prefix(10), id: \.key) { site, time in
                                HStack {
                                    Image(systemName: "globe").foregroundStyle(.tertiary)
                                    Text(site)
                                    Spacer()
                                    Text(Format.duration(time)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.leading, 26)
                    }
                }
            }
        }
    }

    private func usage() -> [Usage] {
        var apps: [String: Usage] = [:]
        for sample in samples {
            var app = apps[sample.bundleID] ?? Usage(bundleID: sample.bundleID, name: sample.appName.isEmpty ? sample.bundleID : sample.appName)
            app.time += sample.duration
            if let domain = sample.domain { app.sites[domain, default: 0] += sample.duration }
            apps[sample.bundleID] = app
        }
        return apps.values.sorted { $0.time > $1.time }
    }
}

struct BarRow: View {
    let label: String
    let value: TimeInterval
    let total: TimeInterval
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail).monospacedDigit().foregroundStyle(.tertiary)
                }
                Text(Format.duration(value)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { proxy in
                Capsule().fill(color.gradient)
                    .frame(width: max(3, proxy.size.width * value / max(total, 1)))
            }
            .frame(height: 5)
        }
    }
}
