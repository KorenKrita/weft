import Foundation

/// Value snapshot of a category and the flags that drive metrics, idle detection and blocking.
public struct CategoryDefinition: Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var colorHex: String
    /// Counts towards focus time and the Focus Score.
    public var isFocusTime: Bool
    /// Counts as meeting time; idle detection is suspended while in a meeting.
    public var isMeeting: Bool
    /// Triggers the distraction blocker during focus sessions.
    public var blockInFocus: Bool
    /// Matching activity is not recorded at all.
    public var isDoNotTrack: Bool
    /// One-line hint for the classifier.
    public var hint: String

    public var id: String { key }

    public init(
        key: String, name: String, colorHex: String,
        isFocusTime: Bool = false, isMeeting: Bool = false,
        blockInFocus: Bool = false, isDoNotTrack: Bool = false, hint: String = ""
    ) {
        self.key = key
        self.name = name
        self.colorHex = colorHex
        self.isFocusTime = isFocusTime
        self.isMeeting = isMeeting
        self.blockInFocus = blockInFocus
        self.isDoNotTrack = isDoNotTrack
        self.hint = hint
    }

    /// The default description in the user's language while it is unchanged; edited ones stay as written.
    /// The stored English `hint` is what the model sees.
    public var displayHint: String {
        guard Self.defaults.contains(where: { $0.key == key && $0.hint == hint }) else { return hint }
        return String(localized: String.LocalizationValue(hint), bundle: .module)
    }

    /// Localize only unchanged defaults; user-supplied names must remain intact.
    public var displayName: String {
        guard Self.defaults.contains(where: { $0.key == key && $0.name == name }) else { return name }
        return switch key {
        case "code": String(localized: "Code", bundle: .module)
        case "design": String(localized: "Design", bundle: .module)
        case "writing": String(localized: "Writing", bundle: .module)
        case "documenting": String(localized: "Documenting", bundle: .module)
        case "research": String(localized: "Research", bundle: .module)
        case "learning": String(localized: "Learning", bundle: .module)
        case "product": String(localized: "Product", bundle: .module)
        case "productivity": String(localized: "Productivity", bundle: .module)
        case "admin": String(localized: "Admin", bundle: .module)
        case "finance": String(localized: "Finance", bundle: .module)
        case "marketing": String(localized: "Marketing", bundle: .module)
        case "sales": String(localized: "Sales", bundle: .module)
        case "customer_support": String(localized: "Customer Support", bundle: .module)
        case "email": String(localized: "Email", bundle: .module)
        case "messaging": String(localized: "Messaging", bundle: .module)
        case "meetings": String(localized: "Meetings", bundle: .module)
        case "video_conferencing": String(localized: "Video Conferencing", bundle: .module)
        case "browsing": String(localized: "Browsing", bundle: .module)
        case "utility": String(localized: "Utility", bundle: .module)
        case "entertainment": String(localized: "Entertainment", bundle: .module)
        case "gaming": String(localized: "Gaming", bundle: .module)
        case "shopping": String(localized: "Shopping", bundle: .module)
        case "social_media": String(localized: "Social Media", bundle: .module)
        case "personal": String(localized: "Personal", bundle: .module)
        case "miscellaneous": String(localized: "Miscellaneous", bundle: .module)
        case "uncategorized": String(localized: "Uncategorized", bundle: .module)
        default: name
        }
    }

    /// True for categories that should be avoided during focus — used for the distraction metric.
    public var isDistracting: Bool { blockInFocus }
}

public extension CategoryDefinition {
    static let uncategorizedKey = "uncategorized"

    /// Mirrors the category keys Rize uses so habits and mental models carry over.
    static let defaults: [CategoryDefinition] = [
        .init(key: "code", name: "Code", colorHex: "#4F7CFF", isFocusTime: true, hint: "IDEs, terminals, code review, developer docs"),
        .init(key: "design", name: "Design", colorHex: "#C356F0", isFocusTime: true, hint: "Figma, Sketch, image and video editing"),
        .init(key: "writing", name: "Writing", colorHex: "#2BB8A4", isFocusTime: true, hint: "Writing prose, notes, drafts"),
        .init(key: "documenting", name: "Documenting", colorHex: "#36A3D9", isFocusTime: true, hint: "Docs, wikis, specs"),
        .init(key: "research", name: "Research", colorHex: "#5FB760", isFocusTime: true, hint: "Searching, reading articles and papers for work"),
        .init(key: "learning", name: "Learning", colorHex: "#8DBF3E", isFocusTime: true, hint: "Courses, tutorials, studying"),
        .init(key: "product", name: "Product", colorHex: "#E58A2E", isFocusTime: true, hint: "Issue trackers, roadmaps, product management"),
        .init(key: "productivity", name: "Productivity", colorHex: "#E2B93B", isFocusTime: true, hint: "Calendars, todo lists, note apps, spreadsheets"),
        .init(key: "admin", name: "Admin", colorHex: "#9A8C7A", hint: "Account settings, HR, paperwork"),
        .init(key: "finance", name: "Finance", colorHex: "#3E9E73", hint: "Banking, accounting, invoices"),
        .init(key: "marketing", name: "Marketing", colorHex: "#EF6F8E", hint: "Ads, analytics, campaigns"),
        .init(key: "sales", name: "Sales", colorHex: "#D9534F", hint: "CRM, prospecting"),
        .init(key: "customer_support", name: "Customer Support", colorHex: "#E07B53", hint: "Help desks, support inboxes"),
        .init(key: "email", name: "Email", colorHex: "#5C6BC0", hint: "Mail clients and webmail"),
        .init(key: "messaging", name: "Messaging", colorHex: "#7E57C2", hint: "Chat apps for work and personal messaging"),
        .init(key: "meetings", name: "Meetings", colorHex: "#00ACC1", isMeeting: true, hint: "Calendar events in progress"),
        .init(key: "video_conferencing", name: "Video Conferencing", colorHex: "#0097A7", isMeeting: true, hint: "Zoom, Meet, Teams, FaceTime"),
        .init(key: "browsing", name: "Browsing", colorHex: "#90A4AE", hint: "General web browsing without a clear purpose"),
        .init(key: "utility", name: "Utility", colorHex: "#78909C", hint: "System settings, Finder, file managers, launchers"),
        .init(key: "entertainment", name: "Entertainment", colorHex: "#F44336", blockInFocus: true, hint: "Video streaming, music videos, news feeds for fun"),
        .init(key: "gaming", name: "Gaming", colorHex: "#E91E63", blockInFocus: true, hint: "Games and game launchers"),
        .init(key: "shopping", name: "Shopping", colorHex: "#FF7043", blockInFocus: true, hint: "Online stores"),
        .init(key: "social_media", name: "Social Media", colorHex: "#FF5252", blockInFocus: true, hint: "Twitter/X, Weibo, Reddit, Instagram, TikTok"),
        .init(key: "personal", name: "Personal", colorHex: "#BCAAA4", blockInFocus: true, hint: "Personal errands unrelated to work"),
        .init(key: "miscellaneous", name: "Miscellaneous", colorHex: "#B0BEC5", hint: "Anything that does not fit elsewhere"),
        .init(key: uncategorizedKey, name: "Uncategorized", colorHex: "#CFD8DC", hint: "Not classified yet"),
    ]
}
