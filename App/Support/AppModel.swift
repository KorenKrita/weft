import AppKit
import Observation
import WeftKit
import SwiftData

enum Page: String, CaseIterable, Identifiable {
    case today, reports, review, categories, rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .reports: "Reports"
        case .review: "Review"
        case .categories: "Categories"
        case .rules: "Rules"
        }
    }

    var symbol: String {
        switch self {
        case .today: "clock"
        case .reports: "chart.bar.xaxis"
        case .review: "questionmark.bubble"
        case .categories: "square.grid.2x2"
        case .rules: "list.bullet.rectangle"
        }
    }
}

/// Owns every long-lived service and wires them together.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let preferences = Preferences()
    let ai: ModelRouter
    let classifier: ClassificationService
    let tracker: ActivityTracker
    let sessions: SessionEngine
    let distractionGuard: DistractionGuard
    let timeEntries: TimeEntryService

    var page: Page = .today
    /// The day the Today page shows; Reports sets it to drill into a day.
    var day = Calendar.current.startOfDay(for: .now)
    /// Set by a view that has access to `openWindow`.
    @ObservationIgnored var openDashboard: (() -> Void)?
    var accessibilityGranted = SystemProbe.isAccessibilityTrusted
    /// Nil until macOS has answered.
    var notificationPermission: NotificationPermission?

    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let breakReminder: BreakReminder
    @ObservationIgnored private let workHours: WorkHoursMonitor
    @ObservationIgnored private let overlays = OverlayController()

    init() {
        do {
            container = try WeftSchema.makeContainer()
        } catch {
            fatalError("Could not open the Weft database: \(error)")
        }
        let context = container.mainContext
        ai = ModelRouter(Self.chosenModel(preferences))
        classifier = ClassificationService(modelContext: context, ai: ai)
        Maintenance.run(modelContext: context, classifier: classifier)
        tracker = ActivityTracker(modelContext: context, classifier: classifier, preferences: preferences)
        sessions = SessionEngine(modelContext: context, classifier: classifier)
        distractionGuard = DistractionGuard(preferences: preferences, sessions: sessions, notifier: notifier)
        timeEntries = TimeEntryService(modelContext: context, ai: ai)
        breakReminder = BreakReminder(preferences: preferences, sessions: sessions, notifier: notifier, modelContext: context)
        workHours = WorkHoursMonitor(preferences: preferences, notifier: notifier, modelContext: context)

        wire()
        Task {
            await notifier.requestAuthorization()
            await refreshNotificationPermission()
        }
        tracker.start()
        classifier.retryPending()
        describeTimeEntriesPeriodically()
    }

    /// Describes finished time entries in the background so the timeline is ready when opened.
    private func describeTimeEntriesPeriodically() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.timeEntries.describeToday()
                try? await Task.sleep(for: .seconds(270))
            }
        }
    }

    private func wire() {
        tracker.addListener { [weak self] sample in
            guard let self else { return }
            breakReminder.handle(sample)
            workHours.handle(sample)
            distractionGuard.handle(sample)
            if !accessibilityGranted, SystemProbe.isAccessibilityTrusted { accessibilityGranted = true }
        }

        sessions.onStart = { [weak self] session in
            guard let self else { return }
            distractionGuard.sessionStarted()
            if session.kind == .breakTime, preferences.fullScreenBreak {
                overlays.showBreak(model: self)
            } else {
                overlays.hideBreak()
            }
        }

        sessions.onEnd = { [weak self] summary in
            guard let self else { return }
            overlays.hideBreak()
            guard summary.completed else { return }
            switch summary.kind {
            case .breakTime:
                notifier.post(.sessionEnded, title: "Break is over", body: "Ready to get back to it?")
            case .focus, .meeting:
                var body = "\(summary.kind.title) session complete."
                if let score = summary.score { body += " Focus Score \(score.value) – \(score.label)." }
                if summary.distractions > 0 { body += " \(summary.distractions) distraction(s)." }
                notifier.post(.sessionEnded, title: "Session complete", body: body)
            }
        }

        distractionGuard.requestRecheck = { [weak self] seconds in
            self?.tracker.requestSample(after: seconds)
        }

        distractionGuard.onIncidentChange = { [weak self] incident in
            guard let self else { return }
            if incident != nil { overlays.showBlocker(model: self) } else { overlays.hideBlocker() }
        }

        notifier.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .startBreak: startSession(.breakTime)
            case .snooze: breakReminder.snooze()
            case .backToWork: distractionGuard.backToWork()
            case .notADistraction: distractionGuard.notADistraction()
            }
        }
    }

    func startSession(_ kind: SessionKind, minutes: Int? = nil) {
        sessions.start(kind, minutes: minutes ?? preferences.defaultMinutes(for: kind))
    }

    static let apiKeyAccount = "remoteAPIKey"

    /// The model picked in Settings. The keychain is only read once a remote model is chosen.
    private static func chosenModel(_ preferences: Preferences) -> any AIClassifying {
        switch preferences.modelProvider {
        case .appleIntelligence:
            FoundationModelsClassifier()
        case .openAICompatible:
            OpenAICompatibleClassifier(config: RemoteModelConfig(
                baseURL: preferences.remoteBaseURL, model: preferences.remoteModel,
                apiKey: Keychain.string(for: apiKeyAccount) ?? ""
            ))
        }
    }

    /// "on device" or "with gpt-5-mini", for status text.
    var modelPlace: String {
        switch preferences.modelProvider {
        case .appleIntelligence: "on device"
        case .openAICompatible: "with \(preferences.remoteModel)"
        }
    }

    /// Switches to the model now chosen in Settings and gives it everything still waiting or guessed.
    func applyModelChoice() {
        ai.use(Self.chosenModel(preferences))
        classifier.retryPending()
    }

    func refreshPermissions() {
        accessibilityGranted = SystemProbe.isAccessibilityTrusted
        tracker.requestSample(after: 0)
        classifier.refreshAvailability()
        Task { await refreshNotificationPermission() }
    }

    private func refreshNotificationPermission() async {
        notificationPermission = await notifier.permission()
    }

    /// Asks for permission the first time; once the user has answered, only System Settings
    /// can change it.
    func enableNotifications() {
        guard notificationPermission == .notDetermined else {
            SystemSettings.openNotifications()
            return
        }
        Task {
            await notifier.requestAuthorization()
            await refreshNotificationPermission()
        }
    }
}

extension AppModel {
    /// Shows `date` on the Today page.
    func showDay(_ date: Date = .now) {
        day = Calendar.current.startOfDay(for: date)
        page = .today
    }
}
