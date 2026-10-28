import Testing
@testable import WeftKit

struct CategoryGuessTests {
    private func app(_ appStoreCategory: String?) -> String {
        CategoryGuess.category(for: ActivityContext(bundleID: "com.example.App", appName: "App"), appStoreCategory: appStoreCategory)
    }

    @Test func appsGoByTheirAppStoreCategory() {
        #expect(app("developer-tools") == "code")
        #expect(app("graphics-design") == "design")
        #expect(app("social-networking") == "social_media")
        #expect(app("puzzle-games") == "gaming")
        #expect(app("utilities") == "utility")
        #expect(app("something-new") == "miscellaneous")
        #expect(app(nil) == "miscellaneous")
    }

    private func site(_ url: String) -> String {
        CategoryGuess.category(for: ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: url),
                               appStoreCategory: "productivity")
    }

    @Test func sitesGoByWordsInTheirDomain() {
        #expect(site("https://mail.example.com/inbox") == "email")
        #expect(site("https://docs.example.dev/start") == "documenting")
        #expect(site("https://shop.example.com/cart") == "shopping")
        #expect(site("https://cs.stanford.edu/courses") == "learning")
        #expect(site("https://www.example-games.com") == "gaming")
        #expect(site("http://localhost:3000") == "code")
        // Not fooled by a keyword inside a longer word or the top-level domain, and never
        // the browser's own category.
        #expect(site("https://gamestop.com") == "browsing")
        #expect(site("https://example.tv") == "browsing")
        #expect(site("https://example.com") == "browsing")
    }
}
