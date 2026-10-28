import AppKit
import Foundation

/// A rough category for an app or site no rule knows, for when no model can answer. Apps go
/// by the App Store category they declare, sites by words in their domain. It's often wrong,
/// so guesses wait in Review and a model replaces them once one is available.
public enum CategoryGuess {
    public static func category(for context: ActivityContext, appStoreCategory: String?) -> String {
        if let domain = context.domain { return category(forDomain: domain) }
        guard let appStoreCategory else { return "miscellaneous" }
        if appStoreCategory.hasSuffix("games") { return "gaming" }
        return appCategories[appStoreCategory] ?? "miscellaneous"
    }

    /// `public.app-category.developer-tools` → `developer-tools`, from the app's Info.plist.
    public static func appStoreCategory(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let type = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
              type.hasPrefix("public.app-category.") else { return nil }
        return String(type.dropFirst("public.app-category.".count))
    }

    static func category(forDomain domain: String) -> String {
        if domain.hasSuffix(".edu") || domain.contains(".edu.") { return "learning" }
        // The top-level domain says little: `.dev` and `.io` sites are anything.
        var labels = domain.split(separator: ".")
        if labels.count > 1 { labels.removeLast() }
        let words = Set(labels.flatMap { $0.split(separator: "-") }.map(String.init))
        for (category, keywords) in domainKeywords where !words.isDisjoint(with: keywords) {
            return category
        }
        return "browsing"
    }

    private static let appCategories: [String: String] = [
        "business": "productivity",
        "developer-tools": "code",
        "education": "learning",
        "entertainment": "entertainment",
        "finance": "finance",
        "graphics-design": "design",
        "healthcare-fitness": "personal",
        "lifestyle": "personal",
        "medical": "personal",
        "music": "entertainment",
        "news": "entertainment",
        "photography": "design",
        "productivity": "productivity",
        "reference": "research",
        "social-networking": "social_media",
        "sports": "entertainment",
        "travel": "personal",
        "utilities": "utility",
        "video": "entertainment",
        "weather": "utility",
    ]

    /// Checked in order; the first category with a matching word wins.
    private static let domainKeywords: [(String, Set<String>)] = [
        ("email", ["mail", "webmail", "inbox"]),
        ("video_conferencing", ["meet", "meeting", "zoom", "webex"]),
        ("messaging", ["chat", "messenger"]),
        ("code", ["git", "gitlab", "dev", "developer", "developers", "api", "console", "localhost"]),
        ("documenting", ["docs", "doc", "wiki", "documentation", "manual", "handbook"]),
        ("learning", ["learn", "course", "courses", "academy", "school", "tutorial", "edu", "university", "study"]),
        ("research", ["search", "scholar", "paper", "papers", "journal", "dictionary", "translate"]),
        ("finance", ["bank", "banking", "pay", "invest", "stock", "stocks", "finance", "tax", "wallet"]),
        ("shopping", ["shop", "store", "mall", "buy", "deals", "cart", "outlet"]),
        ("gaming", ["game", "games", "gaming"]),
        ("entertainment", ["tv", "video", "videos", "movie", "movies", "film", "anime", "manga", "comic", "music",
                           "radio", "live", "stream", "news"]),
        ("social_media", ["social", "forum", "bbs", "community"]),
        ("admin", ["account", "accounts", "login", "signin", "sso", "auth", "admin"]),
    ]
}
