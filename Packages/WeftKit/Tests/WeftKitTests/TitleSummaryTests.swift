import Testing
@testable import WeftKit

struct TitleSummaryTests {
    @Test func mostTimeFirstWithoutPlaceholders() {
        let titles = TitleSummary.mostUsed([
            ("New Tab - Google Chrome - weishu", 600),
            ("Untitled", 300),
            (nil, 900),
            ("Docs - Google Chrome - weishu", 60),
            ("Dashboard - Google Chrome - weishu", 120),
            ("Docs - Google Chrome - weishu", 120),
        ], appName: "Google Chrome", limit: 5)
        // Kept exactly as they were seen, browser and profile included.
        #expect(titles == ["Docs - Google Chrome - weishu", "Dashboard - Google Chrome - weishu"])
    }

    @Test func limitKeepsTheMostUsed() {
        let samples: [(title: String?, duration: Double)] = (1...8).map { ("Page \($0)", Double($0)) }
        #expect(TitleSummary.mostUsed(samples, appName: "Safari", limit: 3) == ["Page 8", "Page 7", "Page 6"])
    }

    @Test func promptLeadsWithTheSiteAndListsTitles() {
        let tab = ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", title: "Positions",
                                  url: "https://ndcdyn.interactivebrokers.com/portal")
        let prompt = ModelPrompts.classifyPrompt(tab, titles: ["Positions - Google Chrome - weishu", "Login - Google Chrome - weishu"])
        #expect(prompt == """
            Website: ndcdyn.interactivebrokers.com (open in Google Chrome)
            Page titles, most used first:
            - Positions - Google Chrome - weishu
            - Login - Google Chrome - weishu
            """)
    }
}
