import Charts
import OpenRizeKit
import SwiftData
import SwiftUI

struct ReportsView: View {
    /// Last day shown; the report covers the seven days ending here.
    @State private var endDay = Calendar.current.startOfDay(for: .now)

    var body: some View {
        WeekReport(endDay: endDay)
            .id(endDay)
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItemGroup {
                    Button { shift(-7) } label: { Image(systemName: "chevron.left") }
                    Button("This Week") { endDay = Calendar.current.startOfDay(for: .now) }
                        .disabled(Calendar.current.isDateInToday(endDay))
                    Button { shift(7) } label: { Image(systemName: "chevron.right") }
                        .disabled(Calendar.current.isDateInToday(endDay))
                }
            }
    }

    private func shift(_ days: Int) {
        let today = Calendar.current.startOfDay(for: .now)
        let next = Calendar.current.date(byAdding: .day, value: days, to: endDay) ?? endDay
        endDay = min(next, today)
    }
}

private struct DayStat: Identifiable {
    var day: Date
    var metrics: DayMetrics
    var id: Date { day }
}

private struct DayCategory: Identifiable {
    var day: Date
    var category: String
    var hours: Double
    var id: String { "\(day.timeIntervalSince1970)-\(category)" }
}

private struct WeekReport: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    private let days: [Date]

    init(endDay: Date) {
        let calendar = Calendar.current
        days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: endDay) }
        let start = days.first ?? endDay
        let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > start && $0.start < end }, sort: \.start)
    }

    var body: some View {
        let stats = dailyStats()
        let total = stats.reduce(DayMetrics()) { partial, stat in
            var merged = partial
            merged.activeTime += stat.metrics.activeTime
            merged.focusTime += stat.metrics.focusTime
            merged.deepWorkTime += stat.metrics.deepWorkTime
            merged.meetingTime += stat.metrics.meetingTime
            merged.distractingTime += stat.metrics.distractingTime
            for (key, value) in stat.metrics.byCategory { merged.byCategory[key, default: 0] += value }
            return merged
        }
        let scores = stats.compactMap { $0.metrics.score?.value }
        let tracked = stats.filter { $0.metrics.activeTime > 0 }.count

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    summaryTile("Tracked", Format.duration(total.activeTime),
                                "\(Format.duration(total.activeTime / Double(max(tracked, 1)))) per active day")
                    summaryTile("Focus", Format.duration(total.focusTime), "\(Format.duration(total.deepWorkTime)) deep work")
                    summaryTile("Meetings", Format.duration(total.meetingTime), " ")
                    summaryTile("Distracted", Format.duration(total.distractingTime), " ")
                    summaryTile("Avg. Focus Score", scores.isEmpty ? "–" : "\(scores.reduce(0, +) / scores.count)",
                                scores.isEmpty ? "No Score" : FocusScore.label(for: scores.reduce(0, +) / scores.count))
                }
                Card("Time by category") { categoryChart(stats) }
                Card("Focus Score") { scoreChart(stats) }
                Card("Categories this week") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(total.byCategory.sorted { $0.value > $1.value }, id: \.key) { key, value in
                            let category = model.classifier.category(key)
                            BarRow(label: category.name, value: value, total: total.activeTime, color: category.color)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func dailyStats() -> [DayStat] {
        let calendar = Calendar.current
        let lookup = model.classifier.categoryLookup
        return days.map { day in
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let samples = segments.filter { $0.end > day && $0.start < end }.map { segment -> SegmentSample in
                var sample = SegmentSample(segment)
                sample.start = max(sample.start, day)
                sample.end = min(sample.end, end)
                return sample
            }
            return DayStat(day: day, metrics: DayMetrics.compute(samples, categories: lookup))
        }
    }

    private func categoryChart(_ stats: [DayStat]) -> some View {
        let rows = stats.flatMap { stat in
            stat.metrics.byCategory.map { DayCategory(day: stat.day, category: $0.key, hours: $0.value / 3600) }
        }
        let keys = Array(Set(rows.map(\.category))).sorted()
        return Chart(rows) { row in
            BarMark(x: .value("Day", row.day, unit: .day), y: .value("Hours", row.hours))
                .foregroundStyle(by: .value("Category", model.classifier.category(row.category).name))
        }
        .chartForegroundStyleScale(domain: keys.map { model.classifier.category($0).name },
                                   range: keys.map { model.classifier.category($0).color })
        .chartXScale(domain: weekDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day()) }
        }
        .chartYAxisLabel("hours")
        .frame(height: 240)
    }

    private func scoreChart(_ stats: [DayStat]) -> some View {
        Chart(stats.filter { $0.metrics.score != nil }) { stat in
            LineMark(x: .value("Day", stat.day, unit: .day), y: .value("Score", stat.metrics.score?.value ?? 0))
            PointMark(x: .value("Day", stat.day, unit: .day), y: .value("Score", stat.metrics.score?.value ?? 0))
                .annotation(position: .top) { Text("\(stat.metrics.score?.value ?? 0)").font(.caption2) }
        }
        .chartXScale(domain: weekDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day()) }
        }
        .chartYScale(domain: 0...100)
        .frame(height: 160)
    }

    /// Always show all seven days, even when only one has data.
    private var weekDomain: ClosedRange<Date> {
        let start = days.first ?? .now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: days.last ?? start) ?? start
        return start...end
    }

    private func summaryTile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}
