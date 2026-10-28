import Foundation
import SwiftData
import Testing
@testable import WeftKit

private struct NoAI: AIClassifying {
    func availability() -> AIAvailability { .unavailable("test") }
    func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        throw ClassificationError.unknownCategory("")
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

@MainActor
struct SessionEngineTests {
    let container: ModelContainer
    let engine: SessionEngine

    init() throws {
        container = try WeftSchema.makeContainer(inMemory: true)
        let classifier = ClassificationService(modelContext: container.mainContext, ai: NoAI())
        engine = SessionEngine(modelContext: container.mainContext, classifier: classifier)
    }

    private var records: [SessionRecord] { (try? container.mainContext.fetch(FetchDescriptor<SessionRecord>())) ?? [] }

    @Test func startAndExtend() {
        engine.start(.focus, minutes: 25)
        let session = try! #require(engine.active)
        #expect(session.kind == .focus)
        #expect(abs(session.plannedDuration - 25 * 60) < 1)
        engine.extend(minutes: 5)
        #expect(abs(engine.active!.plannedDuration - 30 * 60) < 1)
        engine.stop()
    }

    @Test func stoppingRightAwayIsDiscarded() {
        var ended: SessionSummary?
        engine.onEnd = { ended = $0 }
        engine.start(.focus, minutes: 25)
        engine.stop()
        #expect(engine.active == nil)
        #expect(engine.lastSummary == nil)
        #expect(records.isEmpty)
        // Listeners still hear about it, e.g. to take down the break screen.
        #expect(ended?.completed == false)
    }

    @Test func startingAnotherSessionEndsTheCurrentOne() {
        engine.start(.focus, minutes: 25)
        engine.start(.breakTime, minutes: 5)
        #expect(engine.active?.kind == .breakTime)
        engine.stop()
    }

    @Test func shortCompletedSessionIsKeptWithoutReview() async throws {
        engine.start(.focus, minutes: 0)
        for _ in 0..<30 where engine.active != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(engine.active == nil)
        #expect(records.count == 1)
        #expect(engine.lastSummary == nil)
    }
}
