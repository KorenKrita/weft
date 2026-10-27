import Foundation
import Testing
@testable import WeftKit

struct TimelineAxisTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Midnight UTC.
    let midnight = Date(timeIntervalSince1970: 1_700_006_400)
    var day: DateInterval { DateInterval(start: midnight, duration: 86400) }

    func at(_ hour: Double, _ minute: Double = 0) -> Date { midnight + hour * 3600 + minute * 60 }
    func span(_ from: Date, _ to: Date) -> DateInterval { DateInterval(start: from, end: to) }

    @Test func roundsOutToQuarterHoursWithPadding() {
        // 9:10–10:40, padded by 10 min, becomes 9:00–10:50, then 9:00–11:00.
        let axis = TimelineAxis(covering: [span(at(9, 10), at(10, 40))], within: day, calendar: calendar)
        #expect(axis.sections == [.time(span(at(9), at(11)))])
    }

    @Test func idleHourBecomesAGap() {
        let axis = TimelineAxis(covering: [span(at(14, 39), at(16, 30)), span(at(17, 31), at(18, 32))],
                                within: day, calendar: calendar)
        #expect(axis.sections == [
            .time(span(at(14, 15), at(16, 45))),
            .gap(span(at(16, 45), at(17, 15)), idle: 61 * 60),
            .time(span(at(17, 15), at(18, 45))),
        ])
    }

    @Test func idleIsJudgedBeforeRounding() {
        // 57 idle minutes, though only a quarter hour is left between the rounded edges.
        let axis = TimelineAxis(covering: [span(at(17, 31), at(18, 37)), span(at(19, 34), at(20))],
                                within: day, calendar: calendar)
        #expect(axis.sections == [
            .time(span(at(17, 15), at(19))),
            .gap(span(at(19), at(19, 15)), idle: 57 * 60),
            .time(span(at(19, 15), at(20, 15))),
        ])
    }

    @Test func roundingNeverClosesAGap() {
        // 10:16 rounds up and 10:41 rounds down to 10:30; keep the exact edges instead.
        let axis = TimelineAxis(covering: [span(at(9), at(10, 6)), span(at(10, 51), at(11, 30))],
                                within: day, calendar: calendar)
        #expect(axis.sections == [
            .time(span(at(8, 45), at(10, 16))),
            .gap(span(at(10, 16), at(10, 41)), idle: 45 * 60),
            .time(span(at(10, 41), at(11, 45))),
        ])
    }

    @Test func shortIdleStretchStaysToScale() {
        let axis = TimelineAxis(covering: [span(at(9, 30), at(10, 30)), span(at(10, 55), at(11, 30))],
                                within: day, calendar: calendar)
        #expect(axis.sections == [.time(span(at(9, 15), at(11, 45)))])
    }

    @Test func overlappingIntervalsMerge() {
        let axis = TimelineAxis(covering: [span(at(14, 30), at(15, 30)), span(at(9, 30), at(12)), span(at(10), at(11))],
                                within: day, calendar: calendar)
        #expect(axis.sections == [
            .time(span(at(9, 15), at(12, 15))),
            .gap(span(at(12, 15), at(14, 15)), idle: 150 * 60),
            .time(span(at(14, 15), at(15, 45))),
        ])
    }

    @Test func staysWithinTheDay() {
        let axis = TimelineAxis(covering: [span(at(0, 5), at(0, 30)), span(at(23, 40), at(23, 55))],
                                within: day, calendar: calendar)
        #expect(axis.start == at(0))
        #expect(axis.end == at(24))
    }

    @Test func emptyWithoutIntervals() {
        #expect(TimelineAxis(covering: [], within: day, calendar: calendar).sections.isEmpty)
    }
}
