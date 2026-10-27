import OpenRizeKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodaySummary(day: Calendar.current.startOfDay(for: .now))
                .id(Calendar.current.startOfDay(for: .now))
            Divider()
            CurrentActivityRow()
            SessionControls()
            if let summary = model.sessions.lastSummary, summary.kind != .breakTime {
                SessionSummaryCard(summary: summary)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var footer: some View {
        @Bindable var preferences = model.preferences
        return HStack {
            Toggle(isOn: $preferences.trackingPaused) {
                Label(preferences.trackingPaused ? "Paused" : "Tracking",
                      systemImage: preferences.trackingPaused ? "pause.fill" : "record.circle")
            }
            .toggleStyle(.button)
            .help(preferences.trackingPaused ? "Resume tracking" : "Pause tracking")

            Spacer()
            Button("Dashboard") { open(.today) }
            Button {
                open(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit OpenRize")
        }
        .buttonStyle(.borderless)
    }

    private func open(_ page: Page) {
        model.page = page
        openWindow(id: MainView.windowID)
        NSApp.activate()
    }
}

private struct TodaySummary: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]

    init(day: Date) {
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > day }, sort: \.start)
    }

    var body: some View {
        let day = Calendar.current.startOfDay(for: .now)
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            return sample
        }
        let metrics = DayMetrics.compute(samples, categories: model.classifier.categoryLookup)
        let target = model.preferences.workHoursTarget * 3600

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(Format.duration(metrics.activeTime))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("of \(Format.duration(target)) target").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ScoreBadge(score: metrics.score)
            }
            ProgressView(value: min(metrics.activeTime, target), total: max(target, 1))
            CategoryBar(metrics: metrics)
            HStack(spacing: 14) {
                StatLabel(title: "Focus", value: Format.duration(metrics.focusTime))
                StatLabel(title: "Meetings", value: Format.duration(metrics.meetingTime))
                StatLabel(title: "Distracted", value: Format.duration(metrics.distractingTime))
            }
        }
    }
}

struct ScoreBadge: View {
    let score: FocusScore?

    var body: some View {
        VStack(spacing: 0) {
            Text(score.map { "\($0.value)" } ?? "–")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(score?.label ?? "No Score").font(.caption2).foregroundStyle(.secondary)
        }
        .help("Focus Score")
    }

    private var color: Color {
        guard let value = score?.value else { return .secondary }
        return value >= 80 ? .green : value >= 50 ? .orange : .red
    }
}

struct StatLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

/// Horizontal stacked bar of time per category.
struct CategoryBar: View {
    @Environment(AppModel.self) private var model
    let metrics: DayMetrics

    var body: some View {
        let entries = metrics.byCategory.sorted { $0.value > $1.value }
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(entries, id: \.key) { key, value in
                    let category = model.classifier.category(key)
                    Rectangle()
                        .fill(category.color)
                        .frame(width: max(1, proxy.size.width * value / max(metrics.activeTime, 1)))
                        .help("\(category.name): \(Format.duration(value))")
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .background(Capsule().fill(.quaternary))
    }
}

private struct CurrentActivityRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let context = model.tracker.current, let category = model.tracker.currentCategory {
                Image(nsImage: AppIcons.icon(for: context.bundleID))
                    .resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.domain ?? context.appName).lineLimit(1)
                    if let title = context.title {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                CategoryChip(category: category)
            } else {
                Image(systemName: model.preferences.trackingPaused ? "pause.circle" : "moon.zzz")
                    .foregroundStyle(.secondary)
                Text(model.preferences.trackingPaused ? "Tracking paused" : "Away")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        if !model.accessibilityGranted {
            Button {
                model.page = .settings
                SystemProbe.requestAccessibility()
            } label: {
                Label("Grant Accessibility access to record window titles", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
    }
}

struct CategoryChip: View {
    let category: CategoryDefinition

    var body: some View {
        Text(category.name)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(category.color.opacity(0.2)))
            .foregroundStyle(category.color)
    }
}

private struct SessionControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.sessions.active {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.kind.title) session").font(.caption).foregroundStyle(.secondary)
                    Text(Format.countdown(session.remaining(at: model.sessions.now)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Button("+5 min") { model.sessions.extend(minutes: 5) }
                Button("Stop", role: .destructive) { model.sessions.stop() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            HStack {
                ForEach(SessionKind.allCases) { kind in
                    Menu {
                        ForEach(SessionEngine.presetMinutes, id: \.self) { minutes in
                            Button(Format.minutesLabel(minutes)) { model.startSession(kind, minutes: minutes) }
                        }
                    } label: {
                        Text(kind.title)
                    } primaryAction: {
                        model.startSession(kind)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Start a \(Format.minutesLabel(model.preferences.defaultMinutes(for: kind))) \(kind.title.lowercased()) session. Use the arrow for other durations.")
                }
            }
        }
    }
}

struct SessionSummaryCard: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    @State private var rating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(summary.kind.title) session · \(Format.duration(summary.end.timeIntervalSince(summary.start)))")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    model.sessions.dismissSummary()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 14) {
                StatLabel(title: "Score", value: summary.score.map { "\($0.value) · \($0.label)" } ?? "–")
                StatLabel(title: "Focus", value: summary.focusPercent.map(Format.percent) ?? "–")
                StatLabel(title: "Distractions", value: "\(summary.distractions)")
            }
            Text("How focused did you feel?").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...10, id: \.self) { value in
                    Button("\(value)") {
                        rating = value
                        model.sessions.rate(value, summary: summary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(rating == value ? .accentColor : nil)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
