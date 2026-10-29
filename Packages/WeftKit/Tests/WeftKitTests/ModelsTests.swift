import Foundation
import Observation
import Synchronization
import Testing
@testable import WeftKit

struct ModelsTests {
    func segment(_ startMinute: Double, _ bundleID: String) -> ActivitySegment {
        ActivitySegment(context: ActivityContext(bundleID: bundleID, appName: bundleID, title: "Title"),
                        start: Date(timeIntervalSince1970: 1_700_000_000 + startMinute * 60), categoryKey: "code", source: .builtin)
    }

    @Test func segmentsSortByStart() {
        let segments = [segment(20, "a"), segment(0, "b"), segment(10, "c")]
        #expect(segments.sortedByStart().map(\.bundleID) == ["b", "c", "a"])
    }

    @Test func updateLeavesAnUnchangedValueAlone() {
        let segment = segment(0, "a")
        let changes = Mutex(0)
        withObservationTracking { _ = segment.title } onChange: { changes.withLock { $0 += 1 } }

        segment.update(\.title, to: "Title")
        #expect(changes.withLock { $0 } == 0)
        segment.update(\.title, to: "Other")
        #expect(changes.withLock { $0 } == 1)
        #expect(segment.title == "Other")
    }
}
