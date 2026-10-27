import Foundation

/// Decides how to react to a window-title change. Most apps change titles rarely and every
/// change is handled at once. Apps that change titles in rapid bursts — a terminal showing a
/// spinner, a progress counter — are handled at most once per `interval` until they calm down;
/// the deferred handling always reads the latest title, so the final state is never lost.
public struct TitleChangeThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Handle this change now.
        case handleNow
        /// Stop listening and handle the latest title at this time.
        case deferUntil(Date)
        /// A deferred handling is already scheduled.
        case ignore
    }

    /// More than `burstCount` changes within `burstWindow` mark an app as noisy.
    public var burstCount = 4
    public var burstWindow: TimeInterval = 2
    /// How often a noisy app's title is handled.
    public var interval: TimeInterval = 5
    /// An app stops being noisy after this long without a burst.
    public var calmAfter: TimeInterval = 30

    private var recent: [String: [Date]] = [:]
    private var noisyUntil: [String: Date] = [:]
    private var lastHandled: [String: Date] = [:]
    private var pending: Set<String> = []

    public init() {}

    public func isNoisy(_ app: String, at date: Date) -> Bool {
        (noisyUntil[app] ?? .distantPast) > date
    }

    public mutating func titleChanged(app: String, at date: Date) -> Decision {
        var times = (recent[app] ?? []).filter { date.timeIntervalSince($0) < burstWindow }
        times.append(date)
        recent[app] = times
        if times.count > burstCount { noisyUntil[app] = date.addingTimeInterval(calmAfter) }

        guard isNoisy(app, at: date) else {
            lastHandled[app] = date
            return .handleNow
        }
        if pending.contains(app) { return .ignore }
        let next = (lastHandled[app] ?? .distantPast).addingTimeInterval(interval)
        if next <= date {
            lastHandled[app] = date
            return .handleNow
        }
        pending.insert(app)
        return .deferUntil(next)
    }

    /// Call when a deferred handling runs.
    public mutating func deferredHandled(app: String, at date: Date) {
        pending.remove(app)
        lastHandled[app] = date
    }

    /// Call when the app loses focus; a pending deferral no longer applies.
    public mutating func cancelPending(app: String) {
        pending.remove(app)
    }
}
