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

    @Test func outerEdgesArePaddedAndRounded() {
        // 9:10–10:40, padded by 5 min, becomes 9:05–10:45, then 9:00–10:45.
        let axis = TimelineAxis(covering: [span(at(9, 10), at(10, 40))], within: day, calendar: calendar)
        #expect(axis.sections == [.time(span(at(9), at(10, 45)))])
    }

    @Test func gapsHugTheActivityAroundThem() {
        let axis = TimelineAxis(covering: [span(at(14, 39), at(16, 30)), span(at(17, 31), at(18, 32))],
                                within: day, calendar: calendar)
        #expect(axis.sections == [
            .time(span(at(14, 30), at(16, 30))),
            .gap(span(at(16, 30), at(17, 31))),
            .time(span(at(17, 31), at(18, 45))),
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
            .time(span(at(9, 15), at(12))),
            .gap(span(at(12), at(14, 30))),
            .time(span(at(14, 30), at(15, 45))),
        ])
    }

    @Test func staysWithinTheDay() {
        let axis = TimelineAxis(covering: [span(at(-1), at(0, 30)), span(at(23, 40), at(25))],
                                within: day, calendar: calendar)
        #expect(axis.start == at(0))
        #expect(axis.end == at(24))
    }

    @Test func emptyWithoutIntervals() {
        #expect(TimelineAxis(covering: [], within: day, calendar: calendar).sections.isEmpty)
    }
}
