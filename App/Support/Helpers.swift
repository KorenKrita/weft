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
        minutes < 60 ? String(localized: "\(minutes) min") : (minutes % 60 == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(minutes % 60) min"))
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

/// Weft's own language, kept apart from the system's. macOS reads `AppleLanguages` from the
/// app's defaults at launch, so a change applies after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: Self { self }

    /// Language names stay in their own language, so anyone can find theirs.
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static var current: AppLanguage {
        // Only this app's domain: the global one always holds the system's languages.
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        let first = (domain?["AppleLanguages"] as? [String])?.first
        // System Settings writes regional variants such as "zh-Hans-CN" for a per-app language.
        guard let first else { return .system }
        return allCases.first { $0 != .system && (first == $0.rawValue || first.hasPrefix($0.rawValue + "-")) } ?? .system
    }

    /// The language this process runs in; reading it first is enough, since it only changes at launch.
    static let atLaunch = current

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Quits, then opens Weft again once this instance is gone, so two never share the store.
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        guard (try? task.run()) != nil else { return }
        NSApp.terminate(nil)
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

/// Renders its content only while on screen. A closed SwiftUI window keeps its view tree
/// alive, and a `@Query` inside keeps re-evaluating on every store change; dropping the
/// tree when hidden stops that work entirely.
struct OnlyWhileVisible<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.clear
            if isVisible { content() }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}
