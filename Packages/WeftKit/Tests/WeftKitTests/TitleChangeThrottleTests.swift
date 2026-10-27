import Foundation
import Testing
@testable import WeftKit

struct TitleChangeThrottleTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func occasionalChangesAreHandledImmediately() {
        var throttle = TitleChangeThrottle()
        for second in stride(from: 0.0, to: 60, by: 3) {
            #expect(throttle.titleChanged(app: "xcode", at: t0 + second) == .handleNow)
        }
    }

    @Test func aBurstMakesTheAppNoisyAndDefersFurtherChanges() {
        var throttle = TitleChangeThrottle()
        // A spinner: ten changes a second.
        var decisions: [TitleChangeThrottle.Decision] = []
        for tick in 0..<10 { decisions.append(throttle.titleChanged(app: "iterm", at: t0 + Double(tick) / 10)) }
        // The fifth change within two seconds marks the app as noisy.
        #expect(decisions.prefix(4).allSatisfy { $0 == .handleNow })
        #expect(decisions[4] == .deferUntil(t0 + 0.3 + 5))
        #expect(decisions[5...].allSatisfy { $0 == .ignore })
        #expect(throttle.isNoisy("iterm", at: t0 + 1))
    }

    @Test func noisyAppIsHandledAtMostEveryInterval() {
        var throttle = TitleChangeThrottle()
        for tick in 0..<10 { _ = throttle.titleChanged(app: "iterm", at: t0 + Double(tick) / 10) }
        throttle.deferredHandled(app: "iterm", at: t0 + 5.3)
        #expect(throttle.titleChanged(app: "iterm", at: t0 + 6) == .deferUntil(t0 + 10.3))
        throttle.deferredHandled(app: "iterm", at: t0 + 10.3)
        #expect(throttle.titleChanged(app: "iterm", at: t0 + 16) == .handleNow)
    }

    @Test func noisyAppCalmsDown() {
        var throttle = TitleChangeThrottle()
        for tick in 0..<10 { _ = throttle.titleChanged(app: "iterm", at: t0 + Double(tick) / 10) }
        throttle.deferredHandled(app: "iterm", at: t0 + 5.3)
        #expect(!throttle.isNoisy("iterm", at: t0 + 31))
        #expect(throttle.titleChanged(app: "iterm", at: t0 + 31) == .handleNow)
        #expect(throttle.titleChanged(app: "iterm", at: t0 + 32) == .handleNow)
    }

    @Test func noiseIsTrackedPerApp() {
        var throttle = TitleChangeThrottle()
        for tick in 0..<10 { _ = throttle.titleChanged(app: "iterm", at: t0 + Double(tick) / 10) }
        #expect(throttle.titleChanged(app: "safari", at: t0 + 1) == .handleNow)
    }

    @Test func cancellingPendingAllowsANewDeferral() {
        var throttle = TitleChangeThrottle()
        for tick in 0..<10 { _ = throttle.titleChanged(app: "iterm", at: t0 + Double(tick) / 10) }
        throttle.cancelPending(app: "iterm")
        #expect(throttle.titleChanged(app: "iterm", at: t0 + 2) == .deferUntil(t0 + 5.3))
    }
}
