import Foundation

/// What the user is looking at right now: the frontmost app, its focused window title and,
/// for browsers, the active tab URL.
public struct ActivityContext: Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String?
    public var url: String?
    public var domain: String?

    public init(bundleID: String, appName: String, title: String? = nil, url: String? = nil, domain: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.url = url
        self.domain = domain ?? url.flatMap(Self.domain(from:))
    }

    /// Key used to cache AI classifications. Browsers are classified per domain, every other
    /// app as a whole — titles change too often to be worth a model call each.
    public var classificationKey: String {
        if let domain { return "\(bundleID)|\(domain)" }
        return bundleID
    }

    /// Only http(s) pages have a meaningful site; `chrome://newtab`, `about:blank`,
    /// `file://` and the like are treated as plain browser time.
    public static func isWebURL(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Lowercased host without a leading `www.`, for http(s) URLs only.
    public static func domain(from url: String) -> String? {
        guard isWebURL(url), let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// `https://example.com/a/b?c` → `https://example.com`
    public static func hostOnly(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.host != nil else { return url }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? url
    }
}
