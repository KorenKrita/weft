import Foundation
import SwiftData
import Testing
@testable import WeftKit

/// The pre-reconciliation cursor, using its original entity name and stored properties.
/// Other existing models are unchanged by this migration.
private enum LegacyAgentStorage {
    @Model
    final class AgentLogCursor {
        @Attribute(.unique) var path: String
        var kindRaw: String
        /// The file's inode; a new one means the file was replaced and is read again from the start.
        var fileID: Int64
        /// The size when last read; an unchanged size means nothing new.
        var size: Int64
        /// Always the start of a line: the first turn not finished yet, or the end of the file.
        var resumeOffset: Int64
        /// Codex says which session a thread belongs to only on its first line.
        var sessionKey: String?
        /// Nothing in the file counts (an automated review, an old format).
        var skipped: Bool
        var scannedAt: Date

        init(path: String, kind: AgentLogKind) {
            self.path = path
            kindRaw = kind.rawValue
            fileID = 0
            size = 0
            resumeOffset = 0
            skipped = false
            scannedAt = .now
        }
    }

    static var models: [any PersistentModel.Type] {
        let changed = Set([ObjectIdentifier(WeftKit.AgentLogCursor.self), ObjectIdentifier(AgentTurnCoverage.self),
                           ObjectIdentifier(HAPISessionLink.self)])
        return WeftSchema.models.filter { !changed.contains(ObjectIdentifier($0)) } + [AgentLogCursor.self]
    }
}

@MainActor
struct AgentStorageMigrationTests {
    @Test func migratesOldCursorsAndReconcilesWithoutTouchingForegroundTime() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "weft-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appending(path: ".claude/projects/-project/session-1.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.lines([Claude.prompt(at: 0, uuid: "p"), Claude.assistant(at: 10, toolUse: "t"),
                           Claude.toolResult(at: 600, id: "t", source: "user_temporary"), Claude.turnDuration(at: 600)]).write(to: log)
        let file = try #require(AgentLogScanner(roots: AgentLogRoots(home: home)).file(at: log.path))
        let url = home.appending(path: "Legacy.store")
        try seedLegacyStore(at: url, file: file)
        try await migrateAndReconcile(at: url, home: home)

        // Reopen once more: both full turn coverage and the confirmed association survive.
        let schema = Schema(WeftSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let coverage = try #require(context.fetch(FetchDescriptor<AgentTurnCoverage>()).first)
        #expect(coverage.start == Fixture.date(0))
        #expect(coverage.end == Fixture.date(600))
        let link = try #require(context.fetch(FetchDescriptor<HAPISessionLink>()).first)
        #expect(link.hapiID == "h1")
        #expect(link.localKey == "claude:session-1")
        #expect(try context.fetchCount(FetchDescriptor<AgentSpan>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ActivitySegment>()) == 1)
    }

    private func seedLegacyStore(at url: URL, file: AgentLogFile) throws {
        let schema = Schema(LegacyAgentStorage.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let cursor = LegacyAgentStorage.AgentLogCursor(path: file.path, kind: .claudeMain)
        cursor.fileID = file.fileID
        cursor.size = file.size
        cursor.resumeOffset = file.size
        cursor.sessionKey = "claude:session-1"
        context.insert(cursor)
        let native = AgentSession(key: "claude:session-1", source: .claudeCode, flavor: "claude", agentSessionID: "session-1", lastActivity: Fixture.date(600))
        native.hapiSessionID = "h1"
        context.insert(native)
        context.insert(AgentSpan(key: "p#0", sessionKey: native.key, turnID: "p", fileKey: file.path,
            turnStart: Fixture.date(0), start: Fixture.date(0), end: Fixture.date(10), isOpen: false,
            trigger: .user, isSubagent: false, waitedOnUser: 590))
        context.insert(AgentSession(key: "hapi:h1", source: .hapi, flavor: "claude", agentSessionID: "session-1", lastActivity: Fixture.date(600)))
        context.insert(AgentSpan(key: "hapi:h1@0#0", sessionKey: "hapi:h1", turnID: "hapi:h1@0", fileKey: "hapi:h1",
            turnStart: Fixture.date(0), start: Fixture.date(0), end: Fixture.date(600), isOpen: false,
            trigger: .user, isSubagent: false, waitedOnUser: 0))
        let segment = ActivitySegment(context: ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal"),
                                      start: Fixture.date(0), categoryKey: "code", source: .builtin)
        segment.end = Fixture.date(42)
        context.insert(segment)
        try context.save()
    }

    private func migrateAndReconcile(at url: URL, home: URL) async throws {
        let schema = Schema(WeftSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let cursor = try #require(context.fetch(FetchDescriptor<WeftKit.AgentLogCursor>()).first)
        #expect(cursor.coverageVersion == nil)
        #expect(cursor.sessionKey == "claude:session-1")
        #expect(try context.fetchCount(FetchDescriptor<AgentSpan>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<AgentTurnCoverage>()) == 0)
        let preferences = Preferences(defaults: UserDefaults(suiteName: "weft-migration-\(UUID().uuidString)")!)
        let service = AgentActivityService(modelContext: context, preferences: preferences, roots: AgentLogRoots(home: home))
        defer { service.stop() }
        let sync = HAPISync(modelContext: context, preferences: preferences, agents: service, home: home,
                            runner: { _, _ in throw ProcessRunnerError.launchFailed("must not contact HAPI") })
        service.onScan = { [weak sync] in sync?.reconcileLocalHistory() }
        await service.refresh()
        #expect(cursor.coverageVersion == 1)
        let spans = try context.fetch(FetchDescriptor<AgentSpan>())
        #expect(spans.map(\.sessionKey) == ["claude:session-1"])
        #expect(AgentMetrics.agentHours(service.samples(spans)) == 10)
        let foreground = try #require(context.fetch(FetchDescriptor<ActivitySegment>()).first)
        #expect(foreground.end == Fixture.date(42))
        #expect(foreground.categoryKey == "code")
    }
}
