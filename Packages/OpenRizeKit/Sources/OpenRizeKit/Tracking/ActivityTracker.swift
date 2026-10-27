import AppKit
import Foundation
import Observation
import SwiftData

/// One observation of the tracker, broadcast to sessions, break reminders and the blocker.
public struct TrackerSample: Sendable {
    public var date: Date
    public var context: ActivityContext?
    public var category: CategoryDefinition?
    /// True when the user is away (idle past the threshold, asleep, locked or paused).
    public var isAway: Bool
    /// The user is looking at OpenRize itself. That time isn't recorded, but it isn't
    /// time away either.
    public var isOwnApp = false
}

/// Samples the frontmost app every couple of seconds and writes `ActivitySegment`s.
@MainActor
@Observable
public final class ActivityTracker {
    public private(set) var current: ActivityContext?
    public private(set) var currentCategory: CategoryDefinition?
    public private(set) var isSuspendedBySystem = false

    @ObservationIgnored public var interval: Duration = .seconds(2)
    @ObservationIgnored private var listeners: [(TrackerSample) -> Void] = []
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let classifier: ClassificationService
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let urlProvider: BrowserURLProvider
    @ObservationIgnored private var machine = TrackingStateMachine()
    @ObservationIgnored private var openSegment: ActivitySegment?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var browserCache: (bundleID: String, title: String?, fetchedAt: Date, result: BrowserURLResult)?

    public init(modelContext: ModelContext, classifier: ClassificationService, preferences: Preferences,
                urlProvider: BrowserURLProvider = BrowserURLProvider()) {
        self.modelContext = modelContext
        self.classifier = classifier
        self.preferences = preferences
        self.urlProvider = urlProvider
    }

    public func addListener(_ listener: @escaping (TrackerSample) -> Void) {
        listeners.append(listener)
    }

    public func start() {
        guard loop == nil else { return }
        observeSystemEvents()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        apply(machine.suspend(at: .now), category: nil)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    // MARK: Sampling

    private func tick() async {
        guard !preferences.trackingPaused, !isSuspendedBySystem else {
            suspend()
            return
        }
        let idleSeconds = SystemProbe.secondsSinceLastInput
        let isOwnApp = SystemProbe.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        var context = isOwnApp ? nil : await captureContext()
        // Pausing or sleeping may have happened while we were waiting on the browser.
        guard !preferences.trackingPaused, !isSuspendedBySystem else {
            suspend()
            return
        }

        var category: CategoryDefinition?
        var classification: (categoryKey: String, source: ClassificationSource)?
        if let captured = context {
            let result = classifier.classify(captured)
            let definition = classifier.category(result.categoryKey)
            if definition.isDoNotTrack {
                context = nil
            } else {
                classification = result
                category = definition
            }
        }

        let now = Date()
        machine.idleThreshold = TimeInterval(preferences.idleThresholdMinutes * 60)
        let effects = machine.tick(now: now, context: context, idleSeconds: idleSeconds,
                                   idleExempt: category?.isMeeting ?? false)
        apply(effects, category: classification)

        let isAway = isOwnApp ? idleSeconds >= machine.idleThreshold : machine.current == nil
        if isOwnApp {
            // Keep showing what the user was doing before opening OpenRize (e.g. the menu bar
            // popover), unless they've gone idle in the meantime.
            if isAway { current = nil; currentCategory = nil }
            broadcast(TrackerSample(date: now, context: nil, category: nil, isAway: isAway, isOwnApp: true))
        } else {
            current = machine.current == nil ? nil : context
            currentCategory = machine.current == nil ? nil : category
            broadcast(TrackerSample(date: now, context: current, category: currentCategory, isAway: isAway))
        }

        if now.timeIntervalSince(lastSave) > 30 {
            try? modelContext.save()
            lastSave = now
        }
    }

    private func suspend() {
        apply(machine.suspend(at: .now), category: nil)
        current = nil
        currentCategory = nil
        broadcast(TrackerSample(date: .now, context: nil, category: nil, isAway: true))
    }

    private func captureContext() async -> ActivityContext? {
        guard let app = SystemProbe.frontmostApplication, let bundleID = app.bundleIdentifier,
              bundleID != "com.apple.loginwindow", bundleID != "com.apple.ScreenSaver.Engine",
              !preferences.excludedBundleIDs.contains(bundleID) else { return nil }

        var title = SystemProbe.focusedWindowTitle(pid: app.processIdentifier)
        var url: String?

        if BrowserURLScripts.isSupported(bundleID) {
            switch await browserURL(bundleID: bundleID, title: title) {
            case .privateWindow: return nil
            case .url(let value): url = ActivityContext.isWebURL(value) ? value : nil
            case .unavailable: break
            }
        }

        let domain = url.flatMap(ActivityContext.domain(from:))
        if let domain, preferences.excludedDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return nil
        }
        if preferences.urlHostOnly { url = url.map(ActivityContext.hostOnly) }
        if preferences.stripTitles { title = nil }

        return ActivityContext(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                               title: title, url: url, domain: domain)
    }

    /// Asks the browser only when the app or tab title changed, or every 30 s as a fallback.
    private func browserURL(bundleID: String, title: String?) async -> BrowserURLResult {
        if let cache = browserCache, cache.bundleID == bundleID, cache.title == title,
           Date().timeIntervalSince(cache.fetchedAt) < 30 {
            return cache.result
        }
        let result = await urlProvider.currentURL(bundleID: bundleID)
        browserCache = (bundleID, title, Date(), result)
        return result
    }

    private func apply(_ effects: [TrackerEffect], category: (categoryKey: String, source: ClassificationSource)?) {
        for effect in effects {
            switch effect {
            case .open(let context, let date):
                let segment = ActivitySegment(
                    context: context, start: date,
                    categoryKey: category?.categoryKey ?? CategoryDefinition.uncategorizedKey,
                    source: category?.source ?? .pending
                )
                modelContext.insert(segment)
                openSegment = segment
            case .extend(let date):
                openSegment?.end = date
            case .close(let date):
                guard let segment = openSegment else { continue }
                segment.end = max(segment.start, date)
                // Drop sub-second blips from Cmd-Tab and the like.
                if segment.duration < 1 { modelContext.delete(segment) }
                openSegment = nil
                try? modelContext.save()
            }
        }
    }

    private func broadcast(_ sample: TrackerSample) {
        for listener in listeners { listener(sample) }
    }

    // MARK: Sleep, lock and session switching

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        let pauses: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        let resumes: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in pauses {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSuspendedBySystem = true
                    self?.suspend()
                }
            }
            observers.append((center, token))
        }
        for (center, name) in resumes {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isSuspendedBySystem = false }
            }
            observers.append((center, token))
        }
    }
}
