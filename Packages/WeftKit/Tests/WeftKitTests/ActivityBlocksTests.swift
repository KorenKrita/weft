import Foundation
import Testing
@testable import WeftKit

struct ActivityBlocksTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func seg(_ startSecond: Double, _ seconds: Double, _ bundleID: String, title: String? = nil,
             domain: String? = nil, category: String = "code", appName: String? = nil) -> ActivitySegment {
        let context = ActivityContext(bundleID: bundleID, appName: appName ?? bundleID, title: title,
                                      url: domain.map { "https://\($0)/" })
        let segment = ActivitySegment(context: context, start: t0 + startSecond, categoryKey: category, source: .builtin)
        segment.end = t0 + startSecond + seconds
        return segment
    }

    @Test func titleChangesInOneAppAreOneBlock() {
        let blocks = ActivityBlocks.build([
            seg(0, 60, "term", title: "a"), seg(60, 60, "term", title: "b"), seg(125, 60, "term", title: "c"),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].duration == 180)
    }

    @Test func briefDetourIsFoldedIn() {
        let blocks = ActivityBlocks.build([
            seg(0, 300, "term"), seg(300, 10, "settings", category: "utility"), seg(310, 20, "chat", category: "messaging"),
            seg(330, 300, "term"),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].duration == 600)
        #expect(blocks[0].interruptions.count == 2)
        #expect(blocks[0].interruptionNames == ["settings", "chat"])
        #expect(blocks[0].end == t0 + 630)
    }

    @Test func manyShortDetoursCannotHideMostOfTheTime() {
        // 30 s in the terminal, then 60 s elsewhere, repeated: each detour is short, but
        // together they are most of the time and must stay visible.
        var segments: [ActivitySegment] = []
        for i in 0..<10 {
            let base = Double(i) * 90
            segments.append(seg(base, 30, "term"))
            segments.append(seg(base + 30, 60, "tv", category: "entertainment"))
        }
        let blocks = ActivityBlocks.build(segments)
        let hidden = blocks.flatMap(\.interruptions).reduce(0) { $0 + $1.duration }
        let own = blocks.reduce(0) { $0 + $1.duration }
        #expect(hidden <= own / 3)
        #expect(blocks.contains { $0.first.bundleID == "tv" })
    }

    @Test func foldedTimeIsCappedInLongBlocks() {
        // An hour in the terminal with a 50 s detour every 5 minutes: each detour is fine,
        // and the share stays small, but 10 minutes away shouldn't vanish into one row.
        var segments: [ActivitySegment] = []
        for i in 0..<12 {
            let base = Double(i) * 300
            segments.append(seg(base, 250, "term"))
            segments.append(seg(base + 250, 50, "chat", category: "messaging"))
        }
        let blocks = ActivityBlocks.build(segments)
        for block in blocks {
            #expect(block.interruptions.reduce(0) { $0 + $1.duration } <= 5 * 60)
        }
        #expect(blocks.filter { $0.first.bundleID == "term" }.count > 1)
    }

    @Test func busyBlocksStopFolding() {
        // Lots of tiny switches: within the time caps, but too many to call it one thing.
        var segments: [ActivitySegment] = []
        for i in 0..<30 {
            let base = Double(i) * 70
            segments.append(seg(base, 65, "term"))
            segments.append(seg(base + 65, 5, "chrome", domain: "news.com", category: "browsing"))
        }
        let blocks = ActivityBlocks.build(segments)
        #expect(blocks.allSatisfy { $0.interruptions.count <= 15 })
        #expect(blocks.contains { $0.first.bundleID == "chrome" })
    }

    @Test func longDetourStaysSeparate() {
        let blocks = ActivityBlocks.build([
            seg(0, 300, "term"), seg(300, 200, "tv", category: "entertainment"), seg(500, 300, "term"),
        ])
        #expect(blocks.map { $0.first.bundleID } == ["term", "tv", "term"])
    }

    @Test func differentSitesInOneBrowserAreSeparate() {
        let blocks = ActivityBlocks.build([
            seg(0, 120, "chrome", domain: "github.com"), seg(120, 120, "chrome", domain: "youtube.com", category: "entertainment"),
        ])
        #expect(blocks.count == 2)
    }

    @Test func idleGapSplitsBlocks() {
        let blocks = ActivityBlocks.build([seg(0, 60, "term"), seg(600, 60, "term")])
        #expect(blocks.count == 2)
    }

    @Test func titlesAreCleanedAndRankedByTime() {
        let blocks = ActivityBlocks.build([
            seg(0, 10, "chrome", title: "Short - Google Chrome - weishu", appName: "Google Chrome"),
            seg(10, 100, "chrome", title: "Long read - Google Chrome - weishu", appName: "Google Chrome"),
            seg(110, 50, "chrome", title: "68747470733a2f2f6769746875622e636f6d2f7469616e6e2f68617069", appName: "Google Chrome"),
        ])
        #expect(blocks[0].titles == ["Long read", "Short"])
    }

    @Test func terminalStatusPrefixesAreStripped() {
        #expect(ActivityBlock.stripStatusPrefix("1. ✳ openrize-macos-swiftui-app") == "openrize-macos-swiftui-app")
        #expect(ActivityBlock.stripStatusPrefix("1. ◐ openrize-macos-swiftui-app") == "openrize-macos-swiftui-app")
        #expect(ActivityBlock.stripStatusPrefix("⠋ building") == "building")
        #expect(ActivityBlock.stripStatusPrefix("3.14 release notes") == "3.14 release notes")
        #expect(ActivityBlock.stripStatusPrefix("Pull request #12") == "Pull request #12")
    }
}
