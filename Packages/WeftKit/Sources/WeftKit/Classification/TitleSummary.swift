import Foundation

/// The window or page titles that say the most about an app or site: the ones it spent the
/// most time under, leaving out placeholders like "New Tab" that show before a page loads.
/// Titles are kept as they are, browser and profile names included.
public enum TitleSummary {
    public static func mostUsed(_ samples: [(title: String?, duration: TimeInterval)], appName: String,
                                limit: Int) -> [String] {
        var time: [String: TimeInterval] = [:]
        for sample in samples {
            guard let title = sample.title, !isPlaceholder(title, appName: appName) else { continue }
            time[title, default: 0] += sample.duration
        }
        return time.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// "New Tab", or "New Tab - Google Chrome - Profile": nothing about the page yet.
    static func isPlaceholder(_ title: String, appName: String) -> Bool {
        let head = title.range(of: " - \(appName)").map { String(title[..<$0.lowerBound]) } ?? title
        let normalized = head.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized.isEmpty || placeholders.contains(normalized)
    }

    private static let placeholders: Set<String> = [
        "new tab", "untitled", "loading…", "loading...", "about:blank", "start page", "favorites",
        "新标签页", "无标题",
    ]
}
