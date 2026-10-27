import AppKit
import ApplicationServices

/// Pushes changes of the frontmost app, its focused window and that window's title, so the
/// tracker never has to poll. Uses `NSWorkspace` for app switches and an `AXObserver` on the
/// frontmost app for window and title changes (requires the Accessibility permission; without
/// it only app switches are reported).
@MainActor
final class WindowEventObserver {
    enum Event {
        case appActivated
        case windowChanged
        case titleChanged(bundleID: String)
    }

    var onEvent: ((Event) -> Void)?

    private var workspaceToken: NSObjectProtocol?
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var bundleID: String?
    private var titleMuted = false

    func start() {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.observeFrontmostApp()
                self?.onEvent?(.appActivated)
            }
        }
        observeFrontmostApp()
    }

    func stop() {
        if let workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken) }
        workspaceToken = nil
        detach()
    }

    /// Re-attaches to the frontmost app, e.g. once the Accessibility permission was granted.
    func refresh() {
        observeFrontmostApp()
    }

    /// Stops title notifications for the frontmost app; used while it changes titles in bursts.
    func muteTitle() {
        guard !titleMuted, let observer, let windowElement else { return }
        AXObserverRemoveNotification(observer, windowElement, kAXTitleChangedNotification as CFString)
        titleMuted = true
    }

    func unmuteTitle() {
        guard titleMuted else { return }
        titleMuted = false
        observeTitle(of: windowElement)
    }

    // MARK: Accessibility observation

    private func observeFrontmostApp() {
        detach()
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<WindowEventObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { observer.handle(name, element: element) }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(created, element, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        appElement = element
        bundleID = app.bundleIdentifier
        observeTitle(of: focusedWindow(of: element))
    }

    private func observeTitle(of window: AXUIElement?) {
        guard let observer else { return }
        if let windowElement, !titleMuted {
            AXObserverRemoveNotification(observer, windowElement, kAXTitleChangedNotification as CFString)
        }
        windowElement = window
        guard let window, !titleMuted else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
    }

    private func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            guard let appElement else { return }
            observeTitle(of: focusedWindow(of: appElement))
            onEvent?(.windowChanged)
        case kAXTitleChangedNotification:
            onEvent?(.titleChanged(bundleID: bundleID ?? ""))
        default:
            break
        }
    }

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        windowElement = nil
        bundleID = nil
        titleMuted = false
    }
}
