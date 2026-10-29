import AppKit
import WeftKit
import Security
import ServiceManagement
import SwiftUI

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0x999999
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X",
                      Int(round(color.redComponent * 255)),
                      Int(round(color.greenComponent * 255)),
                      Int(round(color.blueComponent * 255)))
    }
}

extension CategoryDefinition {
    var color: Color { Color(hex: colorHex) }
}

enum Format {
    /// 3725 → "1h 2m", 125 → "2m", 20 → "20s"
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Countdown style: "24:59" or "1:02:03".
    static func countdown(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func minutesLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Weft: launch at login change failed: \(error)")
        }
    }
}

/// Secrets in the login keychain, as generic passwords for this app.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "me.weishu.Weft"

    static func string(for account: String) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value removes the item.
    static func set(_ value: String, for account: String) {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(item as CFDictionary)
        guard !value.isEmpty else { return }
        var added = item
        added[kSecValueData] = Data(value.utf8)
        let status = SecItemAdd(added as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Weft: saving to the keychain failed: \(status)") }
    }
}

enum SystemSettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openNotifications() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    }

    static func openAppleIntelligence() {
        open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Renders its content only while its window is open, and tells it how closely to follow
/// the store (`liveness`). A SwiftUI window keeps its view tree alive while closed, and a
/// `@Query` inside keeps re-evaluating on every store change, so a closed window's tree is
/// dropped. An open window keeps its tree, so it looks the same whenever it's looked at.
struct PausedWhileHidden<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isOpen = false
    @State private var isOnScreen = true
    @State private var isActive = NSApplication.shared.isActive
    @State private var catchUp = 0
    /// How often a window left visible behind another app catches up. Rarely: it catches up
    /// anyway as soon as it's used.
    private let backgroundInterval: Duration = .seconds(10 * 60)

    var body: some View {
        ZStack {
            Color.clear
            if isOpen {
                content().environment(\.liveness, Liveness(isLive: isOnScreen && isActive, catchUp: catchUp))
            }
        }
        .background(VisibilityReader { isOnScreen = $0 })
        .onAppear {
            isOpen = true
            isOnScreen = true
        }
        .onDisappear { isOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isActive = false
        }
        .task(id: isOnScreen && !isActive) {
            guard isOnScreen && !isActive else { return }
            while true {
                try? await Task.sleep(for: backgroundInterval)
                guard !Task.isCancelled else { return }
                catchUp += 1
            }
        }
    }
}

/// How closely views follow the store: live while the window is in use, now and then while
/// it's visible behind another app, and not at all while it's out of sight. Views that work
/// things out from the store show what they last worked out in between
/// (`Memo.value(_:_:)`).
struct Liveness: Equatable {
    var isLive = true
    /// Bumped to have views that aren't live catch up once.
    var catchUp = 0
}

extension EnvironmentValues {
    @Entry var liveness = Liveness()
}

/// A value kept between renders. Not state, so keeping a new one doesn't re-render.
@MainActor
final class Memo<Value> {
    private var value: Value?
    private var made = Date.distantPast
    private var catchUp = 0

    /// What `make` last returned, made again once it's `maxAge` old.
    func value(maxAge: TimeInterval, _ make: () -> Value) -> Value {
        if let value, Date.now.timeIntervalSince(made) < maxAge { return value }
        return keep(make())
    }

    /// `make()` while live, otherwise what it last returned until asked to catch up. A view
    /// that reads nothing from the store or the model meanwhile isn't asked to update.
    func value(_ liveness: Liveness, _ make: () -> Value) -> Value {
        if !liveness.isLive, liveness.catchUp == catchUp, let value { return value }
        catchUp = liveness.catchUp
        return keep(make())
    }

    private func keep(_ fresh: Value) -> Value {
        value = fresh
        made = .now
        return fresh
    }
}

/// Reports whether its window can be seen at all: not minimized, on another Space or covered
/// entirely by other windows.
private struct VisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var recheck: Task<Void, Never>?

        private var isWindowVisible: Bool {
            guard let window else { return false }
            return !window.isMiniaturized && window.occlusionState.contains(.visible)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            recheck?.cancel()
            guard let window else { return }
            // Minimizing doesn't always change the occlusion state, so it's watched as well.
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowChanged() }
                }
            }
        }

        private func windowChanged() {
            recheck?.cancel()
            let isVisible = isWindowVisible
            onChange?(isVisible)
            guard !isVisible else { return }
            // The state can lag behind the notifications, e.g. coming back from the Dock.
            recheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isWindowVisible else { return }
                self.onChange?(true)
            }
        }
    }
}
