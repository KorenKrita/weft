import OpenRizeKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayCard(day: Calendar.current.startOfDay(for: .now))
                .id(Calendar.current.startOfDay(for: .now))
            CurrentActivityRow(openSettings: showSettings)
            SessionSection()
            if let summary = model.sessions.lastSummary, summary.kind != .breakTime {
                SessionSummaryCard(summary: summary)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
    }

    private var footer: some View {
        @Bindable var preferences = model.preferences
        return HStack(spacing: 12) {
            Toggle(isOn: $preferences.trackingPaused) {
                Label(preferences.trackingPaused ? "Paused" : "Tracking",
                      systemImage: preferences.trackingPaused ? "pause.circle.fill" : "record.circle")
            }
            .toggleStyle(.button)
            .help(preferences.trackingPaused ? "Resume tracking" : "Pause tracking")

            Spacer()
            Button("Open Dashboard") {
                model.page = .today
                openWindow(id: MainView.windowID)
                NSApp.activate()
            }
            Button(action: showSettings) { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit OpenRize")
        }
        .buttonStyle(.borderless)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

// MARK: - Today

private struct TodayCard: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    private let day: Date

    init(day: Date) {
        self.day = day
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > day }, sort: \.start)
    }

    var body: some View {
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            return sample
        }
        let metrics = DayMetrics.compute(samples, categories: model.classifier.categoryLookup)
        let target = model.preferences.workHoursTarget * 3600

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Format.duration(metrics.activeTime))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(Format.duration(target)) · \(Format.percent(metrics.activeTime / max(target, 1)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ScoreRing(score: metrics.score, activeTime: metrics.activeTime)
            }
            GoalBar(metrics: metrics, target: target)
            HStack(spacing: 14) {
                LegendItem(color: GoalBar.focusColor, title: "Focus", value: metrics.focusTime)
                LegendItem(color: GoalBar.meetingColor, title: "Meetings", value: metrics.meetingTime)
                LegendItem(color: GoalBar.distractedColor, title: "Distracted", value: metrics.distractingTime)
            }
        }
    }
}

/// A Focus Score gauge. Low scores are shown in a neutral color rather than red, and nothing
/// is judged until there's enough data.
struct ScoreRing: View {
    let score: FocusScore?
    var activeTime: TimeInterval = .infinity
    var size: CGFloat = 56

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: size * 0.11)
                if let score {
                    Circle()
                        .trim(from: 0, to: CGFloat(score.value) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(score.map { "\($0.value)" } ?? "–")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: size, height: size)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .help("Focus Score")
    }

    private var caption: String {
        guard let score else { return "Collecting data" }
        return activeTime < 3600 ? "Early estimate" : score.label
    }

    private var color: Color {
        guard let value = score?.value else { return .secondary }
        return value >= 80 ? .green : value >= 50 ? .orange : .indigo
    }
}

/// One bar for the day: its full width is the work-hours target and the filled part is
/// tracked time, split into focus, meetings, other and distracted.
struct GoalBar: View {
    let metrics: DayMetrics
    let target: TimeInterval

    static let focusColor = Color.blue
    static let meetingColor = Color.teal
    static let otherColor = Color.gray
    static let distractedColor = Color.red

    var body: some View {
        let scale = max(target, metrics.activeTime, 1)
        let other = max(0, metrics.activeTime - metrics.focusTime - metrics.meetingTime - metrics.distractingTime)
        let parts: [(String, TimeInterval, Color)] = [
            ("Focus", metrics.focusTime, Self.focusColor),
            ("Meetings", metrics.meetingTime, Self.meetingColor),
            ("Other", other, Self.otherColor),
            ("Distracted", metrics.distractingTime, Self.distractedColor),
        ].filter { $0.1 > 0 }
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(parts, id: \.0) { name, value, color in
                    Rectangle()
                        .fill(color.gradient)
                        .frame(width: max(2, proxy.size.width * value / scale))
                        .help("\(name): \(Format.duration(value))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Capsule().fill(.quaternary))
        .clipShape(Capsule())
        .help("Tracked time towards your \(Format.duration(target)) target")
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String
    let value: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Text(Format.duration(value)).monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - Now

private struct CurrentActivityRow: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let context = model.tracker.current, let category = model.tracker.currentCategory {
                    Image(nsImage: AppIcons.icon(for: context.bundleID))
                        .resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.domain ?? context.appName).font(.callout.weight(.medium)).lineLimit(1)
                        if let title = context.title {
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    CategoryChip(category: category)
                } else {
                    Image(systemName: model.preferences.trackingPaused ? "pause.circle" : "moon.zzz")
                        .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                    Text(model.preferences.trackingPaused ? "Tracking is paused" : "Away")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            if !model.accessibilityGranted {
                Button {
                    SystemProbe.requestAccessibility()
                    openSettings()
                } label: {
                    Label("Grant Accessibility access to record window titles", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
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

// MARK: - Sessions

private struct SessionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.sessions.active {
            ActiveSessionRow(session: session)
        } else {
            HStack(spacing: 8) {
                ForEach(SessionKind.allCases) { kind in
                    SessionButton(kind: kind)
                }
            }
        }
    }
}

/// A tile that starts a session with the default duration; the corner menu offers others.
private struct SessionButton: View {
    @Environment(AppModel.self) private var model
    let kind: SessionKind
    @State private var isHovering = false

    var body: some View {
        let minutes = model.preferences.defaultMinutes(for: kind)
        Button {
            model.startSession(kind)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.title3).frame(height: 22)
                Text(kind.title).font(.callout.weight(.medium))
                Text(Format.duration(TimeInterval(minutes * 60))).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(isHovering ? 0.9 : 0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Menu {
                Section("Start a \(kind.title.lowercased()) session") {
                    ForEach(SessionEngine.presetMinutes, id: \.self) { preset in
                        Button(Format.minutesLabel(preset)) { model.startSession(kind, minutes: preset) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(6)
            .help("Other durations")
        }
        .onHover { isHovering = $0 }
        .help("Start a \(Format.minutesLabel(minutes)) \(kind.title.lowercased()) session")
    }
}

private struct ActiveSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ActiveSession

    var body: some View {
        let remaining = session.remaining(at: model.sessions.now)
        let progress = 1 - remaining / max(session.plannedDuration, 1)
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: session.kind.symbol).font(.callout)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.kind.title) session").font(.caption).foregroundStyle(.secondary)
                Text(Format.countdown(remaining))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Button("+5 min") { model.sessions.extend(minutes: 5) }
            Button("Stop") { model.sessions.stop() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

extension SessionKind {
    var symbol: String {
        switch self {
        case .focus: "scope"
        case .meeting: "person.2"
        case .breakTime: "cup.and.saucer"
        }
    }
}

struct SessionSummaryCard: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    @State private var rating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(summary.kind.title) session · \(Format.duration(summary.end.timeIntervalSince(summary.start)))")
                    .font(.callout.weight(.medium))
                Spacer()
                Button { model.sessions.dismissSummary() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                ScoreRing(score: summary.score, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Focused \(summary.focusPercent.map(Format.percent) ?? "–") of the time")
                    Text(summary.distractions == 0 ? "No distractions" : "\(summary.distractions) distraction\(summary.distractions == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
