import Foundation
import Testing
@testable import WeftKit

struct DayMetricsTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })

    func sample(_ startMinute: Double, _ minutes: Double, _ category: String, app: String = "app") -> SegmentSample {
        SegmentSample(start: t0 + startMinute * 60, end: t0 + (startMinute + minutes) * 60,
                      categoryKey: category, bundleID: app, appName: app)
    }

    @Test func noScoreWithTooLittleData() {
        let metrics = DayMetrics.compute([sample(0, 10, "code")], categories: categories)
        #expect(metrics.score == nil)
        #expect(metrics.activeTime == 600)
    }

    @Test func uninterruptedCodingScoresHigh() {
        let metrics = DayMetrics.compute([sample(0, 120, "code")], categories: categories)
        #expect(metrics.deepWorkTime == 7200)
        #expect(metrics.score?.value == 100)
        #expect(metrics.score?.label == "Exceptional")
    }

    @Test func shortInterruptionsDoNotBreakDeepWork() {
        let samples = [
            sample(0, 15, "code", app: "xcode"),
            sample(15, 0.5, "messaging", app: "slack"),
            sample(15.5, 15, "code", app: "xcode"),
        ]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 30 * 60)
        #expect(metrics.longestFocusStretch == 30 * 60)
        #expect(metrics.contextSwitches == 2)
    }

    @Test func longInterruptionSplitsDeepWork() {
        let samples = [
            sample(0, 20, "code"),
            sample(20, 5, "social_media", app: "x"),
            sample(25, 20, "code"),
        ]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.longestFocusStretch == 20 * 60)
        #expect(metrics.distractingTime == 300)
        #expect(metrics.focusTime == 40 * 60)
    }

    @Test func idleGapEndsStretch() {
        let samples = [sample(0, 20, "code"), sample(30, 20, "code")]
        #expect(DayMetrics.compute(samples, categories: categories).deepWorkTime == 0)
    }

    @Test func detoursOfAFewMinutesKeepAStretch() {
        // Two minutes on chat, then a minute and a half away from the Mac.
        let samples = [sample(0, 20, "code"), sample(20, 2, "messaging", app: "slack"), sample(22, 20, "code"),
                       sample(43.5, 20, "code")]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 60 * 60)
        #expect(metrics.longestFocusStretch == 60 * 60)
    }

    @Test func movingBetweenFocusAppsIsNotSwitching() {
        // A terminal, the docs and GitHub in the browser, back and forth every minute or two.
        var samples: [SegmentSample] = []
        for i in 0..<40 {
            let start = Double(i) * 3
            samples.append(sample(start, 2, "code", app: "iterm"))
            samples.append(sample(start + 2, 1, i.isMultiple(of: 2) ? "code" : "research", app: "chrome"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.contextSwitches == 0)
        #expect(metrics.deepWorkTime == 120 * 60)
        #expect(metrics.score?.value == 100)
    }

    @Test func glancesAreNotSwitches() {
        var samples: [SegmentSample] = []
        for i in 0..<6 {
            samples.append(sample(Double(i) * 10, 9.75, "code", app: "xcode"))
            samples.append(sample(Double(i) * 10 + 9.75, 0.25, "messaging", app: "slack"))
        }
        #expect(DayMetrics.compute(samples, categories: categories).contextSwitches == 0)
    }

    @Test func constantDetoursAreNotDeepWork() {
        // Never away for long, but only half of it is focus work.
        var samples: [SegmentSample] = []
        for i in 0..<30 {
            samples.append(sample(Double(i) * 4, 2, "code", app: "xcode"))
            samples.append(sample(Double(i) * 4 + 2, 2, "messaging", app: "slack"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.contextSwitches == 59)
    }

    @Test func distractionAndSwitchingLowerScore() {
        var samples: [SegmentSample] = []
        for i in 0..<60 {
            let start = Double(i) * 2
            samples.append(sample(start, 1, "code", app: "xcode"))
            samples.append(sample(start + 1, 1, "social_media", app: "browser"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        let score = try! #require(metrics.score)
        #expect(score.value < 25)
        #expect(score.switchPenalty > 0)
        #expect(score.distractionPenalty > 0)
    }

    @Test func meetingsDoNotCountAgainstScore() {
        let samples = [sample(0, 60, "video_conferencing", app: "zoom"), sample(60, 60, "code", app: "xcode")]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.meetingTime == 3600)
        #expect(metrics.score?.value == 100)
    }

    @Test func hoursAreSplitAcrossBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 1_700_000_000 is 22:13:20 UTC.
        let metrics = DayMetrics.compute([sample(0, 60, "code")], categories: categories, calendar: calendar)
        #expect(abs(metrics.byHour[22, default: 0] - (46 * 60 + 40)) < 0.001)
        #expect(abs(metrics.byHour[23, default: 0] - (13 * 60 + 20)) < 0.001)
    }

    @Test func labels() {
        #expect(FocusScore.label(for: 97) == "Exceptional")
        #expect(FocusScore.label(for: 80) == "Good")
        #expect(FocusScore.label(for: 1) == "Very Poor")
        #expect(FocusScore.label(for: 0) == "No Score")
    }
}
