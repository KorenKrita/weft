import Charts
import OpenRizeKit
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
                    Button("Today") { day = Calendar.current.startOfDay(for: .now) }
                        .disabled(Calendar.current.isDateInToday(day))
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next day")
                        .disabled(Calendar.current.isDateInToday(day))
                }
            }
    }

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }
}

private struct DayContent: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    private let day: Date
    private let dayEnd: Date

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        dayEnd = end
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > day && $0.start < end }, sort: \.start)
    }

    var body: some View {
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            sample.end = min(sample.end, dayEnd)
            return sample
        }
        let metrics = DayMetrics.compute(samples, categories: model.classifier.categoryLookup)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if segments.isEmpty {
                    ContentUnavailableView("No activity", systemImage: "clock",
                                           description: Text("Nothing was tracked on this day."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    StatTiles(metrics: metrics, target: model.preferences.workHoursTarget * 3600)
                    Card("Timeline") { TimelineChart(samples: samples) }
                    Card("By hour") { HourlyChart(samples: samples) }
                    HStack(alignment: .top, spacing: 16) {
                        Card("Categories") { CategoryBreakdown(metrics: metrics) }
                        Card("Apps & sites") { TopList(metrics: metrics) }
                    }
                    Card("Daily review") { DailySummary(day: day, metrics: metrics) }
                    Card("Activity") { ActivityList(segments: segments) }
                }
            }
            .padding(20)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

private struct StatTiles: View {
    let metrics: DayMetrics
    let target: TimeInterval
    @State private var showScoreDetails = false

    var body: some View {
        HStack(spacing: 12) {
            tile("Tracked", Format.duration(metrics.activeTime), detail: "of \(Format.duration(target))")
            tile("Focus", Format.duration(metrics.focusTime), detail: "\(Format.duration(metrics.deepWorkTime)) deep work")
            tile("Meetings", Format.duration(metrics.meetingTime))
            tile("Distracted", Format.duration(metrics.distractingTime))
            if metrics.activeTime >= 15 * 60 {
                tile("Switches", String(format: "%.0f/h", metrics.switchesPerHour), detail: "\(metrics.contextSwitches) total")
            } else {
                tile("Switches", "\(metrics.contextSwitches)", detail: "total")
            }
            Button { showScoreDetails = true } label: {
                tile("Focus Score", metrics.score.map { "\($0.value)" } ?? "–", detail: metrics.score?.label ?? "Not enough data")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showScoreDetails) { ScoreExplanation(score: metrics.score).padding() }
        }
    }

    private func tile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
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

private struct TimelineChart: View {
    @Environment(AppModel.self) private var model
    let samples: [SegmentSample]

    var body: some View {
        let start = samples.map(\.start).min() ?? .now
        let end = samples.map(\.end).max() ?? .now
        let lower = Calendar.current.dateInterval(of: .hour, for: start)?.start ?? start
        let upper = Calendar.current.dateInterval(of: .hour, for: end)?.end ?? end

        Chart(Array(samples.enumerated()), id: \.offset) { _, sample in
            RectangleMark(
                xStart: .value("Start", sample.start),
                xEnd: .value("End", sample.end),
                yStart: .value("Lane", 0),
                yEnd: .value("Lane", 1)
            )
            .foregroundStyle(model.classifier.category(sample.categoryKey).color)
        }
        .chartXScale(domain: lower...upper)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 70)
    }
}

private struct HourSlice: Identifiable {
    var hour: Int
    var category: String
    var minutes: Double
    var id: String { "\(hour)-\(category)" }
}

private struct HourlyChart: View {
    @Environment(AppModel.self) private var model
    let samples: [SegmentSample]

    var body: some View {
        let slices = Self.slices(samples)
        let categories = Array(Set(slices.map(\.category))).sorted()
        let names = categories.map { model.classifier.category($0).name }
        let colors = categories.map { model.classifier.category($0).color }

        Chart(slices) { slice in
            BarMark(x: .value("Hour", slice.hour), y: .value("Minutes", slice.minutes))
                .foregroundStyle(by: .value("Category", model.classifier.category(slice.category).name))
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartXScale(domain: 0...24)
        .chartXAxis { AxisMarks(values: Array(stride(from: 0, through: 24, by: 3))) }
        .chartYScale(domain: 0...60)
        .chartYAxisLabel("min")
        .frame(height: 180)
    }

    static func slices(_ samples: [SegmentSample]) -> [HourSlice] {
        let calendar = Calendar.current
        var totals: [String: HourSlice] = [:]
        for sample in samples {
            var cursor = sample.start
            while cursor < sample.end {
                let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end ?? sample.end
                let sliceEnd = min(hourEnd, sample.end)
                let hour = calendar.component(.hour, from: cursor)
                let key = "\(hour)-\(sample.categoryKey)"
                totals[key, default: HourSlice(hour: hour, category: sample.categoryKey, minutes: 0)].minutes
                    += sliceEnd.timeIntervalSince(cursor) / 60
                cursor = sliceEnd
            }
        }
        return Array(totals.values)
    }
}

private struct CategoryBreakdown: View {
    @Environment(AppModel.self) private var model
    let metrics: DayMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(metrics.byCategory.sorted { $0.value > $1.value }, id: \.key) { key, value in
                let category = model.classifier.category(key)
                BarRow(label: category.name, value: value, total: metrics.activeTime, color: category.color)
            }
        }
    }
}

private struct TopList: View {
    let metrics: DayMetrics

    var body: some View {
        let apps = metrics.byApp.map { (name: $0.key, value: $0.value) }
        let sites = metrics.byDomain.map { (name: $0.key, value: $0.value) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach((apps + sites).sorted { $0.value > $1.value }.prefix(12), id: \.name) { item in
                BarRow(label: item.name, value: item.value, total: metrics.activeTime, color: .accentColor)
            }
        }
    }
}

struct BarRow: View {
    let label: String
    let value: TimeInterval
    let total: TimeInterval
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Text(Format.duration(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { proxy in
                Capsule().fill(color)
                    .frame(width: max(2, proxy.size.width * value / max(total, 1)))
            }
            .frame(height: 5)
        }
    }
}

private struct DailySummary: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let metrics: DayMetrics
    @State private var text: String?
    @State private var error: String?
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text {
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            switch model.classifier.aiAvailability {
            case .available:
                Button(text == nil ? "Summarize this day" : "Regenerate") { generate() }
                    .disabled(isGenerating)
                if isGenerating { ProgressView().controlSize(.small) }
            case .unavailable(let reason):
                Text("On-device summaries need Apple Intelligence. \(reason)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        isGenerating = true
        error = nil
        let facts = facts()
        Task {
            do {
                text = try await model.ai.summarize(facts)
            } catch {
                self.error = "Could not generate a summary: \(error.localizedDescription)"
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
            Focus time: \(Format.duration(metrics.focusTime)); deep work (25+ minute stretches): \(Format.duration(metrics.deepWorkTime))
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
