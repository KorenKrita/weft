import Foundation
import SwiftData

/// Reminds the user to take a break after a stretch of *actual* activity, rather than on a
/// wall-clock timer. Only a real break, `minimumBreak` or more away from the Mac, starts a new
/// stretch; a screen that blanks for a moment or a quick lock doesn't. A stretch already under
/// way when Weft launches is picked up from the stored activity, so relaunching doesn't reset it.
@MainActor
public final class BreakReminder {
    /// Time away that counts as a break.
    public static let minimumBreak: TimeInterval = 5 * 60

    private let preferences: Preferences
    private let sessions: SessionEngine
    private let notifier: any NotificationPosting
    private var streakStart: Date?
    private var awaySince: Date?
    private var nextReminder: Date?

    public init(preferences: Preferences, sessions: SessionEngine, notifier: any NotificationPosting,
                modelContext: ModelContext? = nil, now: Date = .now) {
        self.preferences = preferences
        self.sessions = sessions
        self.notifier = notifier
        if let modelContext {
            let since = now.addingTimeInterval(-12 * 3600)
            let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.end > since }))) ?? []
            streakStart = Self.stretchStart(segments.map { ($0.start, $0.end) }, now: now)
        }
    }

    public func handle(_ sample: TrackerSample) {
        if sessions.active?.kind == .breakTime {
            streakStart = nil
            awaySince = nil
            nextReminder = nil
            return
        }
        if sample.isAway {
            // Idle time began at the last input, not when Weft noticed it.
            if awaySince == nil { awaySince = sample.date.addingTimeInterval(-sample.idleSeconds) }
            return
        }
        if let awaySince {
            self.awaySince = nil
            if sample.date.timeIntervalSince(awaySince) >= Self.minimumBreak {
                streakStart = nil
                nextReminder = nil
            }
        }
        let streakStart = streakStart ?? sample.date
        self.streakStart = streakStart
        guard preferences.breakRemindersEnabled else { return }

        let due = nextReminder ?? streakStart.addingTimeInterval(TimeInterval(preferences.breakReminderMinutes * 60))
        guard sample.date >= due else { return }
        let minutes = Int(sample.date.timeIntervalSince(streakStart) / 60)
        notifier.post(.breakReminder, title: "Time for a break",
                      body: "You've been working for \(minutes) minutes without a pause.")
        snooze(from: sample.date)
    }

    public func snooze(from date: Date = .now) {
        nextReminder = date.addingTimeInterval(TimeInterval(preferences.snoozeMinutes * 60))
    }

    /// When the current stretch of work began: the start of the latest run of activity with no
    /// gap of `minimumBreak` or more, if that run is still going at `now`.
    static func stretchStart(_ segments: [(start: Date, end: Date)], now: Date) -> Date? {
        let latestFirst = segments.sorted { $0.end > $1.end }
        guard let last = latestFirst.first, now.timeIntervalSince(last.end) < minimumBreak else { return nil }
        var start = last.start
        for segment in latestFirst.dropFirst() {
            guard start.timeIntervalSince(segment.end) < minimumBreak else { break }
            start = min(start, segment.start)
        }
        return start
    }
}

/// Notifies once when today's tracked time reaches the work-hours target, and once more an
/// hour later as an overworking warning. Remembers what it sent, so relaunching Weft neither
/// repeats a notification nor swallows one that's due.
@MainActor
public final class WorkHoursMonitor {
    private let preferences: Preferences
    private let notifier: any NotificationPosting
    private var day: Date
    private var worked: TimeInterval
    private var lastSample: Date?
    private var notifiedTarget = false
    private var notifiedOvertime = false

    public init(preferences: Preferences, notifier: any NotificationPosting, modelContext: ModelContext, now: Date = .now) {
        self.preferences = preferences
        self.notifier = notifier
        let today = Calendar.current.startOfDay(for: now)
        day = today
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.end > today }))) ?? []
        worked = segments.reduce(0) { $0 + $1.end.timeIntervalSince(max($1.start, today)) }
        let calendar = Calendar.current
        notifiedTarget = preferences.workHoursTargetNotifiedAt.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        notifiedOvertime = preferences.overtimeNotifiedAt.map { calendar.isDate($0, inSameDayAs: today) } ?? false
    }

    public func handle(_ sample: TrackerSample) {
        let today = Calendar.current.startOfDay(for: sample.date)
        if today != day {
            day = today
            worked = 0
            notifiedTarget = false
            notifiedOvertime = false
        }
        defer { lastSample = sample.date }
        guard !sample.isAway, let lastSample else { return }
        // Samples arrive on events and a one-minute heartbeat; away time never counts.
        worked += min(sample.date.timeIntervalSince(lastSample), 90)

        guard preferences.workHoursNotifications else { return }
        let target = preferences.workHoursTarget * 3600
        if !notifiedTarget, worked >= target {
            notifiedTarget = true
            preferences.workHoursTargetNotifiedAt = sample.date
            notifier.post(.workHours, title: "Work hours target reached",
                          body: "You've tracked \(Self.format(worked)) today. Consider wrapping up.")
        } else if !notifiedOvertime, worked >= target + 3600 {
            notifiedOvertime = true
            preferences.overtimeNotifiedAt = sample.date
            notifier.post(.workHours, title: "You're overworking",
                          body: "\(Self.format(worked)) tracked today — an hour past your target.")
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
