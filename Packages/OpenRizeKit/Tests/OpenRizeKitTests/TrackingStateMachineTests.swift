import Foundation
import Testing
@testable import OpenRizeKit

struct TrackingStateMachineTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode", title: "App.swift")
    let safari = ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", url: "https://github.com/a")

    @Test func opensThenExtendsSameContext() {
        var machine = TrackingStateMachine()
        #expect(machine.tick(now: t0, context: xcode, idleSeconds: 0) == [.open(xcode, t0)])
        #expect(machine.tick(now: t0 + 2, context: xcode, idleSeconds: 1) == [.extend(t0 + 2)])
    }

    @Test func switchingContextClosesAndOpens() {
        var machine = TrackingStateMachine()
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 0)
        #expect(machine.tick(now: t0 + 2, context: safari, idleSeconds: 0) == [.close(t0 + 2), .open(safari, t0 + 2)])
    }

    @Test func titleChangeIsANewContext() {
        var machine = TrackingStateMachine()
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 0)
        var other = xcode
        other.title = "Other.swift"
        #expect(machine.tick(now: t0 + 2, context: other, idleSeconds: 0) == [.close(t0 + 2), .open(other, t0 + 2)])
    }

    @Test func idleCutsSegmentAtLastInput() {
        var machine = TrackingStateMachine(idleThreshold: 300)
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 0)
        _ = machine.tick(now: t0 + 100, context: xcode, idleSeconds: 0)
        #expect(machine.tick(now: t0 + 420, context: xcode, idleSeconds: 320) == [.close(t0 + 100)])
        // Still idle: nothing happens.
        #expect(machine.tick(now: t0 + 422, context: xcode, idleSeconds: 322).isEmpty)
        // Input resumes: a fresh segment starts.
        #expect(machine.tick(now: t0 + 500, context: xcode, idleSeconds: 0) == [.open(xcode, t0 + 500)])
    }

    @Test func idleExemptKeepsMeetingsRunning() {
        var machine = TrackingStateMachine(idleThreshold: 300)
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 0)
        for second in stride(from: 2.0, through: 600, by: 2) {
            #expect(machine.tick(now: t0 + second, context: xcode, idleSeconds: second, idleExempt: true) == [.extend(t0 + second)])
        }
    }

    @Test func idleNeverClosesBeforeSegmentStart() {
        var machine = TrackingStateMachine(idleThreshold: 300)
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 200)
        #expect(machine.tick(now: t0 + 150, context: xcode, idleSeconds: 350) == [.close(t0)])
    }

    @Test func longTickGapSplitsSegment() {
        var machine = TrackingStateMachine(maxTickGap: 60)
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 0)
        _ = machine.tick(now: t0 + 2, context: xcode, idleSeconds: 0)
        #expect(machine.tick(now: t0 + 600, context: xcode, idleSeconds: 0) == [.close(t0 + 2), .open(xcode, t0 + 600)])
    }

    @Test func nilContextAndSuspendClose() {
        var machine = TrackingStateMachine()
        _ = machine.tick(now: t0, context: xcode, idleSeconds: 0)
        #expect(machine.tick(now: t0 + 2, context: nil, idleSeconds: 0) == [.close(t0 + 2)])
        _ = machine.tick(now: t0 + 4, context: xcode, idleSeconds: 0)
        #expect(machine.suspend(at: t0 + 6) == [.close(t0 + 6)])
        #expect(machine.suspend(at: t0 + 8).isEmpty)
    }
}
