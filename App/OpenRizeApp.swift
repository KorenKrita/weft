import OpenRizeKit
import SwiftUI

@main
struct OpenRizeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .modelContainer(model.container)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("OpenRize", id: MainView.windowID) {
            MainView()
                .environment(model)
                .modelContainer(model.container)
        }
        .defaultSize(width: 1080, height: 760)
        .defaultLaunchBehavior(model.preferences.hasCompletedOnboarding ? .suppressed : .presented)
    }
}

private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let session = model.sessions.active {
                Image(systemName: symbol(for: session.kind))
                Text(Format.countdown(session.remaining(at: model.sessions.now)))
                    .monospacedDigit()
            } else {
                Image(systemName: model.preferences.trackingPaused ? "pause.circle" : "circle.circle")
            }
        }
        .task {
            // The label is always alive, unlike the popover, so it provides `openWindow`.
            model.openDashboard = {
                openWindow(id: MainView.windowID)
                NSApp.activate()
            }
        }
    }

    private func symbol(for kind: SessionKind) -> String {
        switch kind {
        case .focus: "scope"
        case .meeting: "person.2"
        case .breakTime: "cup.and.saucer"
        }
    }
}

/// Owns the model so `openrize://` URLs can reach it even when no window is open.
///
///     openrize://focus?minutes=50   openrize://meeting   openrize://break
///     openrize://stop               openrize://pause     openrize://resume
///     openrize://dashboard
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "openrize" {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "minutes" }?.value.flatMap(Int.init)
        switch url.host() {
        case "focus": model.startSession(.focus, minutes: minutes)
        case "meeting": model.startSession(.meeting, minutes: minutes)
        case "break": model.startSession(.breakTime, minutes: minutes)
        case "stop": model.sessions.stop()
        case "pause": model.preferences.trackingPaused = true
        case "resume": model.preferences.trackingPaused = false
        case "dashboard":
            model.page = .today
            model.openDashboard?()
        default: break
        }
    }
}
