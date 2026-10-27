import AppKit
import WeftKit
import SwiftUI

/// Borderless windows above everything else, on every Space, for the break screen and the
/// distraction blocker.
@MainActor
final class OverlayController {
    private var breakWindows: [NSWindow] = []
    private var blockerWindow: NSWindow?

    func showBreak(model: AppModel) {
        hideBreak()
        breakWindows = NSScreen.screens.map { screen in
            makeWindow(on: screen, content: BreakOverlayView().environment(model))
        }
    }

    func hideBreak() {
        breakWindows.forEach { $0.orderOut(nil) }
        breakWindows.removeAll()
    }

    func showBlocker(model: AppModel) {
        guard blockerWindow == nil, let screen = NSScreen.main else { return }
        blockerWindow = makeWindow(on: screen, content: BlockerOverlayView().environment(model))
    }

    func hideBlocker() {
        blockerWindow?.orderOut(nil)
        blockerWindow = nil
    }

    /// A non-activating panel can take keyboard focus without activating the app, which
    /// macOS no longer allows us to do on our own. It also keeps the tracker from seeing
    /// Weft as the frontmost app while an overlay is up.
    private func makeWindow(on screen: NSScreen, content: some View) -> NSWindow {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct BreakOverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Color.black.opacity(0.35)
            VStack(spacing: 20) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Take your break!")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Stand up, stretch, look at something far away.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let session = model.sessions.active {
                    Text(Format.countdown(session.remaining(at: model.sessions.now)))
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 16) {
                    Button("Extend 5 min") { model.sessions.extend(minutes: 5) }
                    Button("End Break") { model.sessions.stop() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.extraLarge)
                .font(.title3)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

struct BlockerOverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            if let incident = model.distractionGuard.incident {
                VStack(spacing: 16) {
                    Image(nsImage: AppIcons.icon(for: incident.context.bundleID))
                        .resizable().frame(width: 56, height: 56)
                    Text("Getting distracted?")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("**\(incident.displayName)** is categorized as **\(incident.category.name)**.")
                        .foregroundStyle(.secondary)
                    if let session = model.sessions.active {
                        Text("\(Format.countdown(session.remaining(at: model.sessions.now))) left in your focus session.")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Back to Work") { model.distractionGuard.backToWork() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    HStack(spacing: 16) {
                        Button("This is not a distraction") { model.distractionGuard.notADistraction() }
                        Button("Disable for this session") { model.distractionGuard.disableForSession() }
                        Button("Continue anyway") { model.distractionGuard.ignore() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                .padding(36)
                .frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            }
        }
        .ignoresSafeArea()
    }
}
