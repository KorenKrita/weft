import Foundation
import SwiftData
import Testing
@testable import WeftKit

/// `hapi usage --json` output, with times in seconds after `Fixture.t0`.
enum HAPIFixture {
    static func ms(_ seconds: Double) -> Double { Fixture.date(seconds).timeIntervalSince1970 * 1000 }

    static func session(_ id: String, flavor: String = "codex", machine: String = "remote-machine", host: String = "build-box",
                        agentSessionID: String? = "thread-1", turns: [(Double, Double?)], waits: [(Double, Double?)] = []) -> [String: Any] {
        [
            "id": id, "flavor": flavor, "agentSessionId": agentSessionID as Any, "machineId": machine, "host": host,
            "machineName": host == "build-box" ? "Build box" : host, "path": "/srv/project", "title": "Port the runner",
            "turns": turns.map { ["start": ms($0.0), "end": $0.1.map(ms) as Any, "endReason": $0.1 == nil ? NSNull() : "idle", "startedBy": "hub_prompt"] },
            "waits": waits.map { ["start": ms($0.0), "end": $0.1.map(ms) as Any, "kind": "permission", "tool": "Bash"] },
        ]
    }

    static func report(_ sessions: [[String: Any]], localMachine: String? = "local-machine", schema: String = HAPIActivityReport.supportedSchema) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schema": schema, "generatedAt": ms(10_000), "hubUrl": "https://hub.example", "localMachineId": localMachine as Any,
            "since": ms(0), "until": ms(10_000), "sessions": sessions,
        ])
    }
}

struct HAPIImporterTests {
    let now = Fixture.date(10_000)

    func plan(_ data: Data, localFlavors: Set<String> = ["claude", "codex"], localHosts: Set<String> = ["my-mac.local"]) throws -> [HAPIImporter.Decision] {
        HAPIImporter.plan(try HAPIActivityReport.decode(data), localFlavors: localFlavors, localHosts: localHosts, now: now)
    }

    @Test func remoteTurnsBecomePiecesWithoutTheWaits() throws {
        let decisions = try plan(HAPIFixture.report([
            HAPIFixture.session("s1", turns: [(0, 600), (900, nil)], waits: [(100, 160), (200, 202)]),
        ]))
        guard case .record(let session) = decisions.first else { Issue.record("expected a record"); return }
        #expect(session.key == "hapi:s1")
        #expect(session.flavor == "codex")
        #expect(session.host == "Build box")
        #expect(session.isWorking)
        // The 2 s wait is a rule answering, not the user.
        #expect(session.pieces.map { $0.end.timeIntervalSince($0.start) } == [100, 440, 9100])
        #expect(session.pieces.map(\.isOpen) == [false, false, true])
        #expect(session.pieces.first?.waitedOnUser == 60)
        #expect(Set(session.pieces.map(\.turnID)).count == 2)
    }

    @Test func sessionsWeftReadsItselfAreOnlyLinked() throws {
        let decisions = try plan(HAPIFixture.report([
            HAPIFixture.session("local-claude", flavor: "claude", machine: "local-machine", agentSessionID: "abc", turns: [(0, 60)]),
            HAPIFixture.session("by-host", flavor: "codex", machine: "unknown", host: "my-mac.local", agentSessionID: "t2", turns: [(0, 60)]),
        ]))
        #expect(decisions == [.link(localKey: "claude:abc", hapiID: "local-claude"), .link(localKey: "codex:t2", hapiID: "by-host")])
    }

    @Test func localPiIsLinkedOnlyWhenEnabled() throws {
        let data = HAPIFixture.report([HAPIFixture.session("local-pi", flavor: "pi", machine: "local-machine", agentSessionID: "abc", turns: [(0, 60)])])
        #expect(try plan(data, localFlavors: ["pi"]) == [.link(localKey: "pi:abc", hapiID: "local-pi")])
        guard case .record = try plan(data, localFlavors: []).first else { Issue.record("expected record"); return }
        let remote = HAPIFixture.report([HAPIFixture.session("remote-pi", flavor: "pi", turns: [(0, 60)])])
        guard case .record = try plan(remote, localFlavors: ["pi"]).first else { Issue.record("expected remote record"); return }
    }

    @Test func localAgentsWeftCantReadAreRecordedAsThisMac() throws {
        let decisions = try plan(HAPIFixture.report([
            HAPIFixture.session("cursor", flavor: "cursor", machine: "local-machine", turns: [(0, 60)]),
            HAPIFixture.session("codex-off", flavor: "codex", machine: "local-machine", turns: [(0, 60)]),
        ]), localFlavors: ["claude"])
        let hosts = decisions.compactMap { decision -> String?? in
            if case .record(let session) = decision { return .some(session.host) }
            return nil
        }
        #expect(hosts == [nil, nil])
    }

    @Test func otherReportVersionsAreRefused() {
        #expect(throws: HAPIReportError.unsupportedSchema("hapi.activity.v2")) {
            try HAPIActivityReport.decode(HAPIFixture.report([], schema: "hapi.activity.v2"))
        }
        #expect(throws: HAPIReportError.unreadable) { try HAPIActivityReport.decode(Data("Agents worked 2h".utf8)) }
    }

    @Test func versionsCompareNumerically() {
        #expect(HAPISync.isAtLeast("0.31.3", "0.30.0"))
        #expect(HAPISync.isAtLeast("v0.30.0", "0.30.0"))
        #expect(HAPISync.isAtLeast("1.0", "0.30.0"))
        #expect(!HAPISync.isAtLeast("0.29.12", "0.30.0"))
        #expect(!HAPISync.isAtLeast("0.9.0", "0.30.0"))
    }
}

struct HAPIBinaryLocatorTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "weft-hapi-\(UUID().uuidString)")

    func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test func prefersTheNativeBinaryBehindBunsLauncher() throws {
        let packages = home.appending(path: ".bun/install/global/node_modules/@twsxtd")
        let launcher = packages.appending(path: "hapi/bin/hapi.cjs")
        let native = packages.appending(path: "hapi-darwin-\(HAPIBinaryLocator.architecture)/bin/hapi")
        try makeExecutable(launcher)
        try FileManager.default.createDirectory(at: home.appending(path: ".bun/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".bun/bin/hapi"), withDestinationURL: launcher)

        // Without the native package there's nothing Weft can run without Node.
        #expect(HAPIBinaryLocator(home: home).locate() == nil)
        try makeExecutable(native)
        #expect(HAPIBinaryLocator(home: home).locate()?.resolvingSymlinksInPath() == native.resolvingSymlinksInPath())
    }

    @Test func aChosenPathWins() throws {
        let custom = home.appending(path: "tools/hapi")
        try makeExecutable(custom)
        try makeExecutable(home.appending(path: ".local/bin/hapi"))
        #expect(HAPIBinaryLocator(home: home, override: custom.path(percentEncoded: false)).locate()?.lastPathComponent == "hapi")
        #expect(HAPIBinaryLocator(home: home, override: custom.path(percentEncoded: false)).locate()?.deletingLastPathComponent().lastPathComponent == "tools")
        #expect(HAPIBinaryLocator(home: home).locate()?.deletingLastPathComponent().lastPathComponent == "bin")
    }
}

struct ProcessRunnerTests {
    @Test func readsMoreThanAPipeHolds() async throws {
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo oops >&2; exit 3"])
        #expect(output.status == 3)
        #expect(output.stdout.count == 300_000)
        #expect(String(decoding: output.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func stopsWhatTakesTooLong() async {
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3)
        }
    }

    @Test func stopsWhatSaysTooMuch() async {
        await #expect(throws: ProcessRunnerError.outputTooLarge) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes"], maxOutput: 100_000)
        }
    }

    @Test func reportsWhatCantStart() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/hapi"), arguments: [])
        }
    }
}

/// Calls to a fake `hapi`, and what it answers.
private final class FakeHAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var answers: [String: ProcessOutput] = [:]

    func answer(_ command: String, status: Int32 = 0, stdout: Data = Data(), stderr: String = "") {
        lock.withLock { answers[command] = ProcessOutput(status: status, stdout: stdout, stderr: Data(stderr.utf8)) }
    }

    var commands: [String] { lock.withLock { calls.map { $0.first ?? "" } } }

    func run(_ arguments: [String]) -> ProcessOutput {
        lock.withLock {
            calls.append(arguments)
            return answers[arguments.first ?? ""] ?? ProcessOutput(status: 1, stdout: Data(), stderr: Data("no answer".utf8))
        }
    }
}

@MainActor
struct HAPISyncTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "weft-hapi-sync-\(UUID().uuidString)")
    let container: ModelContainer
    let preferences: Preferences
    let agents: AgentActivityService
    private let fake = FakeHAPI()
    let sync: HAPISync

    init() throws {
        let binary = home.appending(path: ".local/bin/hapi")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path(percentEncoded: false))
        container = try WeftSchema.makeContainer(inMemory: true)
        preferences = Preferences(defaults: UserDefaults(suiteName: "weft-hapi-\(UUID().uuidString)")!)
        agents = AgentActivityService(modelContext: container.mainContext, preferences: preferences, roots: AgentLogRoots(home: home))
        let fake = fake
        sync = HAPISync(modelContext: container.mainContext, preferences: preferences, agents: agents, home: home,
                        runner: { _, arguments in fake.run(arguments) })
        let sync = sync
        agents.onScan = { [weak sync] in sync?.reconcileLocalHistory() }
        fake.answer("--version", stdout: Data("hapi version: 0.32.0\n".utf8))
    }

    private var spans: [AgentSpan] {
        (try? container.mainContext.fetch(FetchDescriptor<AgentSpan>(sortBy: [SortDescriptor(\.start)]))) ?? []
    }

    private var sessions: [AgentSession] { (try? container.mainContext.fetch(FetchDescriptor<AgentSession>())) ?? [] }

    @Test func importsRemoteWorkAndUpdatesItInPlace() async throws {
        fake.answer("usage", stdout: HAPIFixture.report([HAPIFixture.session("s1", turns: [(0, 600), (900, nil)])]))
        await sync.sync(now: Fixture.date(1_000))
        #expect(sync.status == .synced(Fixture.date(1_000)))
        #expect(spans.count == 2)
        #expect(spans.last?.isOpen == true)
        #expect(agents.liveSessions == ["hapi:s1"])
        let session = try #require(sessions.first)
        #expect(session.key == "hapi:s1")
        #expect(session.source == .hapi)
        #expect(session.host == "Build box")
        #expect(session.title == "Port the runner")

        // The open turn ended; nothing is added twice.
        fake.answer("usage", stdout: HAPIFixture.report([HAPIFixture.session("s1", turns: [(900, 1_500)])]))
        await sync.sync(now: Fixture.date(2_000))
        #expect(spans.count == 2)
        #expect(spans.last?.end == Fixture.date(1_500))
        #expect(spans.last?.isOpen == false)
        #expect(agents.liveSessions.isEmpty)
        // The version is only checked once.
        #expect(fake.commands == ["--version", "usage", "usage"])
    }

    @Test func linksSessionsWeftReadsItself() async throws {
        container.mainContext.insert(AgentSession(key: "claude:abc", source: .claudeCode, flavor: "claude", agentSessionID: "abc", lastActivity: .now))
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "claude", machine: "local-machine", agentSessionID: "abc", turns: [(0, 60)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        #expect(spans.isEmpty)
        #expect(sessions.first?.hapiSessionID == "h1")
    }

    @Test func linkingDropsWhatHAPIImportedBeforeTheLocalLogWasRead() async throws {
        // Before the upgrade, HAPI recorded this Mac's pi sessions itself.
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 300), (1_000, 1_600)]),
            HAPIFixture.session("h2", flavor: "pi", machine: "local-machine", agentSessionID: "p2", turns: [(2_000, 2_100)]),
        ]))
        await sync.sync(now: Fixture.date(3_000))
        #expect(Set(spans.map(\.sessionKey)) == ["hapi:h1", "hapi:h2"])

        // Then Weft reads the logs: p1's no longer has the first turn, p2's has everything.
        preferences.agentPiEnabled = true
        for (key, start, end) in [("p1", 1_000.0, 1_600.0), ("p2", 2_000.0, 2_100.0)] {
            container.mainContext.insert(AgentSession(key: "pi:\(key)", source: .pi, flavor: "pi", agentSessionID: key, lastActivity: Fixture.date(end)))
            container.mainContext.insert(AgentSpan(key: "\(key)/t#0", sessionKey: "pi:\(key)", turnID: "\(key)/t", fileKey: "/\(key)",
                                                   turnStart: Fixture.date(start), start: Fixture.date(start), end: Fixture.date(end),
                                                   isOpen: false, trigger: .user, isSubagent: false, waitedOnUser: 0))
        }
        await sync.sync(now: Fixture.date(3_100))
        let imported = spans.filter { $0.sessionKey.hasPrefix("hapi:") }
        #expect(imported.map(\.sessionKey) == ["hapi:h1"])
        #expect(imported.map(\.end) == [Fixture.date(300)])
        #expect(spans.filter { $0.sessionKey.hasPrefix("pi:") }.count == 2)
        #expect(Set(sessions.map(\.key)) == ["hapi:h1", "pi:p1", "pi:p2"])
        #expect(sessions.first { $0.key == "pi:p2" }?.hapiSessionID == "h2")
    }

    @Test func saysWhatNeedsUpdating() async {
        fake.answer("usage", status: 1, stderr: "Unknown command: usage\nRun hapi to choose an agent.")
        await sync.sync()
        #expect(sync.status == .cliTooOld(version: "0.32.0"))

        fake.answer("usage", status: 4, stderr: "hapi usage: the hub doesn't report agent activity yet; update it")
        await sync.sync()
        #expect(sync.status == .hubTooOld)

        fake.answer("usage", status: 3, stderr: "hapi usage: CLI_API_TOKEN is required")
        await sync.sync()
        #expect(sync.status == .notSignedIn)
    }

    @Test func neverRunsAHapiThatMightStartAnAgent() async {
        fake.answer("--version", stdout: Data("hapi version: 0.29.4\n".utf8))
        await sync.sync()
        #expect(sync.status == .cliTooOld(version: "0.29.4"))
        #expect(!fake.commands.contains("usage"))
    }

    @Test func doesNothingWhenTurnedOff() async {
        preferences.agentHAPIEnabled = false
        await sync.sync()
        #expect(fake.commands.isEmpty)
    }
}

extension HAPISyncTests {
    @Test func linkingKeepsImportedPrefixBeforeNativeCoverage() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)

        // The available native history starts halfway through the HAPI span.
        preferences.agentPiEnabled = true
        container.mainContext.insert(AgentSession(key: "pi:p1", source: .pi, flavor: "pi", agentSessionID: "p1", lastActivity: Fixture.date(600)))
        container.mainContext.insert(AgentSpan(key: "p1/t#0", sessionKey: "pi:p1", turnID: "p1/t", fileKey: "/p1",
            turnStart: Fixture.date(300), start: Fixture.date(300), end: Fixture.date(600),
            isOpen: false, trigger: .user, isSubagent: false, waitedOnUser: 0))
        await sync.sync(now: Fixture.date(1_100))
        let total = AgentMetrics.agentHours(agents.samples(spans))
        let imported = spans.filter { $0.sessionKey == "hapi:h1" }.map { DateInterval(start: $0.start, end: $0.end) }
        #expect(total == 600)
        #expect(imported == [DateInterval(start: Fixture.date(0), end: Fixture.date(300))])
    }

    @Test func linkingKeepsImportedWorkMissingFromStaleLocalHistory() async throws {
        // Native tracking previously read the first turn; later work was imported while disabled.
        container.mainContext.insert(AgentSession(key: "pi:p1", source: .pi, flavor: "pi", agentSessionID: "p1", lastActivity: Fixture.date(300)))
        container.mainContext.insert(AgentSpan(key: "p1/t#0", sessionKey: "pi:p1", turnID: "p1/t", fileKey: "/p1",
            turnStart: Fixture.date(0), start: Fixture.date(0), end: Fixture.date(300),
            isOpen: false, trigger: .user, isSubagent: false, waitedOnUser: 0))
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 300), (900, 1_200)]),
        ]))
        await sync.sync(now: Fixture.date(2_000))

        // Re-enable tracking, but its log is no longer available (or outside the backfill window).
        preferences.agentPiEnabled = true
        await agents.refresh()
        await sync.sync(now: Fixture.date(2_100))
        let total = AgentMetrics.agentHours(agents.samples(spans))
        let imported = spans.filter { $0.sessionKey == "hapi:h1" }.map { DateInterval(start: $0.start, end: $0.end) }
        #expect(total == 600)
        #expect(imported == [DateInterval(start: Fixture.date(900), end: Fixture.date(1_200))])
        agents.stop()
    }
}

extension HAPIImporterTests {
    @Test func coverageSplitsPiecesWithoutDuplicatingMetadata() {
        let piece = HAPIImporter.Piece(turnID: "turn", turnStart: Fixture.date(0), start: Fixture.date(0),
                                       end: Fixture.date(600), isOpen: true, trigger: .system, waitedOnUser: 60)
        let coverage = [DateInterval(start: Fixture.date(300), end: Fixture.date(400)),
                        DateInterval(start: Fixture.date(100), end: Fixture.date(200))]
        let retained = HAPIImporter.excluding(coverage, from: [piece])
        #expect(retained.map(\.start) == [Fixture.date(0), Fixture.date(200), Fixture.date(400)])
        #expect(retained.map(\.end) == [Fixture.date(100), Fixture.date(300), Fixture.date(600)])
        #expect(retained.map(\.isOpen) == [false, false, true])
        #expect(retained.map(\.waitedOnUser) == [60, 0, 0])
        #expect(retained.allSatisfy { $0.turnID == piece.turnID && $0.turnStart == piece.turnStart && $0.trigger == .system })
        #expect(HAPIImporter.excluding(coverage, from: retained) == retained)
        #expect(HAPIImporter.excluding([], from: [piece]) == [piece])
        #expect(HAPIImporter.excluding([DateInterval(start: piece.start, end: piece.end)], from: [piece]).isEmpty)
        let prefix = HAPIImporter.excluding([DateInterval(start: Fixture.date(300), end: piece.end)], from: [piece])
        #expect(prefix.map(\.isOpen) == [false])
    }
}

extension HAPISyncTests {
    private func addLocalTurn(_ id: String, start: Double, end: Double) {
        container.mainContext.insert(AgentSpan(key: "p1/\(id)#0", sessionKey: "pi:p1", turnID: "p1/\(id)", fileKey: "/p1",
                                               turnStart: Fixture.date(start), start: Fixture.date(start), end: Fixture.date(end),
                                               isOpen: false, trigger: .user, isSubagent: false, waitedOnUser: 0))
    }

    @Test func linkingSplitsHistoryIdempotentlyAsMoreTurnsAreRead() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 1_200)]),
        ]))
        await sync.sync(now: Fixture.date(2_000))
        preferences.agentPiEnabled = true
        container.mainContext.insert(AgentSession(key: "pi:p1", source: .pi, flavor: "pi", agentSessionID: "p1", lastActivity: Fixture.date(600)))
        addLocalTurn("first", start: 300, end: 600)
        await sync.sync(now: Fixture.date(2_100))
        var imported = spans.filter { $0.sessionKey == "hapi:h1" }
        #expect(imported.map(\.start) == [Fixture.date(0), Fixture.date(600)])
        #expect(imported.map(\.end) == [Fixture.date(300), Fixture.date(1_200)])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 1_200)
        #expect(AgentMetrics.maxConcurrency(agents.samples(spans)) == 1)
        let keys = imported.map(\.key)
        await sync.sync(now: Fixture.date(2_200))
        #expect(spans.filter { $0.sessionKey == "hapi:h1" }.map(\.key) == keys)

        addLocalTurn("next", start: 600, end: 900)
        await sync.sync(now: Fixture.date(2_300))
        imported = spans.filter { $0.sessionKey == "hapi:h1" }
        #expect(imported.map(\.start) == [Fixture.date(0), Fixture.date(900)])
        #expect(imported.map(\.end) == [Fixture.date(300), Fixture.date(1_200)])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 1_200)
        addLocalTurn("earlier", start: 0, end: 300)
        addLocalTurn("later", start: 900, end: 1_200)
        await sync.sync(now: Fixture.date(2_400))
        #expect(spans.allSatisfy { $0.sessionKey == "pi:p1" })
        #expect(sessions.map(\.key) == ["pi:p1"])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 1_200)
    }

    @Test func linkingKeepsGapsBetweenLocallyReadTurns() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 1_200)]),
        ]))
        await sync.sync(now: Fixture.date(2_000))
        preferences.agentPiEnabled = true
        container.mainContext.insert(AgentSession(key: "pi:p1", source: .pi, flavor: "pi", agentSessionID: "p1", lastActivity: Fixture.date(1_200)))
        addLocalTurn("first", start: 0, end: 300)
        addLocalTurn("last", start: 900, end: 1_200)
        await sync.sync(now: Fixture.date(2_100))
        let imported = spans.filter { $0.sessionKey == "hapi:h1" }
        #expect(imported.map(\.start) == [Fixture.date(300)])
        #expect(imported.map(\.end) == [Fixture.date(900)])
        #expect(sessions.first { $0.key == "hapi:h1" }?.lastActivity == Fixture.date(900))
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 1_200)
    }

    @Test func subagentWaitsDoNotEraseTheParentsImportedWork() async throws {
        preferences.agentClaudeEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "claude", machine: "local-machine", agentSessionID: "p1", turns: [(0, 400)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        preferences.agentClaudeEnabled = true
        container.mainContext.insert(AgentSession(key: "claude:p1", source: .claudeCode, flavor: "claude", agentSessionID: "p1", lastActivity: Fixture.date(300)))
        container.mainContext.insert(AgentSpan(key: "p1/child#0", sessionKey: "claude:p1", turnID: "p1/child", fileKey: "/child",
                                               turnStart: Fixture.date(100), start: Fixture.date(100), end: Fixture.date(150),
                                               isOpen: false, trigger: .user, isSubagent: true, waitedOnUser: 0))
        container.mainContext.insert(AgentSpan(key: "p1/child#1", sessionKey: "claude:p1", turnID: "p1/child", fileKey: "/child",
                                               turnStart: Fixture.date(100), start: Fixture.date(250), end: Fixture.date(300),
                                               isOpen: false, trigger: .user, isSubagent: true, waitedOnUser: 0))
        await sync.sync(now: Fixture.date(1_100))
        let imported = spans.filter { $0.sessionKey == "hapi:h1" }
        #expect(imported.map(\.start) == [Fixture.date(0), Fixture.date(150), Fixture.date(300)])
        #expect(imported.map(\.end) == [Fixture.date(100), Fixture.date(250), Fixture.date(400)])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 400)
    }
}

extension HAPISyncTests {
    @Test func mainTurnCoverageAlsoRemovesItsWaitsFromImportedTime() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 100)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        preferences.agentPiEnabled = true
        container.mainContext.insert(AgentSession(key: "pi:p1", source: .pi, flavor: "pi", agentSessionID: "p1", lastActivity: Fixture.date(100)))
        for (index, start, end) in [(0, 0.0, 20.0), (1, 80.0, 100.0)] {
            container.mainContext.insert(AgentSpan(key: "p1/t#\(index)", sessionKey: "pi:p1", turnID: "p1/t", fileKey: "/p1",
                                                   turnStart: Fixture.date(0), start: Fixture.date(start), end: Fixture.date(end),
                                                   isOpen: false, trigger: .user, isSubagent: false, waitedOnUser: index == 0 ? 60 : 0))
        }
        await sync.sync(now: Fixture.date(1_100))
        #expect(spans.allSatisfy { $0.sessionKey == "pi:p1" })
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 40)
        #expect(spans.reduce(0) { $0 + $1.waitedOnUser } == 60)
    }

    @Test func linkingWithoutLocalSpansLeavesImportedHistoryAlone() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "p1", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        preferences.agentPiEnabled = true
        container.mainContext.insert(AgentSession(key: "pi:p1", source: .pi, flavor: "pi", agentSessionID: "p1", lastActivity: Fixture.date(600)))
        await sync.sync(now: Fixture.date(1_100))
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)
        #expect(Set(sessions.map(\.key)) == ["hapi:h1", "pi:p1"])
    }
}

extension HAPISyncTests {
    @Test func startupReconcilesHistoryReadAfterTheInitialHAPIReport() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("old-pi", flavor: "pi", machine: "local-machine", agentSessionID: "session-1", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(10_000))
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)

        // New process after upgrade: the first full HAPI query finishes before the native scan.
        let fake = fake
        let startup = HAPISync(modelContext: container.mainContext, preferences: preferences, agents: agents, home: home,
                               runner: { _, arguments in fake.run(arguments) })
        preferences.agentPiEnabled = true
        await startup.sync(now: Fixture.date(10_300))
        let folder = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Fixture.lines([Pi.header(), Pi.prompt(at: 0, id: "prompt"), Pi.assistant(at: 600, stop: "stop")])
            .write(to: folder.appending(path: "session.jsonl"))
        await agents.refresh()

        // Subsequent queries start at lastSuccess - 15 minutes, so the old session is absent.
        fake.answer("usage", stdout: HAPIFixture.report([]))
        await startup.sync(now: Fixture.date(10_600))
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)
        #expect(spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        agents.stop()
    }

    @Test func terminalLocalWaitIsNotKeptAsImportedWork() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "session-1", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        preferences.agentPiEnabled = true
        let folder = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Fixture.lines([
            Pi.header(), Pi.prompt(at: 0, id: "prompt"), Pi.assistant(at: 10, stop: "toolUse"),
            Pi.question(at: 600, duration: 590), Pi.assistant(at: 600, stop: "aborted"),
        ]).write(to: folder.appending(path: "session.jsonl"))
        await agents.refresh()
        let local = spans.filter { $0.sessionKey == "pi:session-1" }
        #expect(AgentMetrics.agentHours(agents.samples(local)) == 10)
        #expect(sessions.first { $0.key == "pi:session-1" }?.lastActivity == Fixture.date(600))
        await sync.sync(now: Fixture.date(1_100))
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 10)
        #expect(spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        agents.stop()
    }
}

extension HAPISyncTests {
    @discardableResult
    private func writePi(_ lines: [String]) throws -> URL {
        let folder = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "session.jsonl")
        try Fixture.lines([Pi.header()] + lines).write(to: file)
        return file
    }

    private func importPi(through end: Double) async {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "session-1", turns: [(0, end)]),
        ]))
        await sync.sync(now: Fixture.date(end + 1_000))
        preferences.agentPiEnabled = true
        // The native session does not exist yet; its association must survive this report.
        await sync.sync(now: Fixture.date(end + 1_100))
    }

    @Test func nativeScanReconcilesWithoutAnotherHAPIRequest() async throws {
        await importPi(through: 600)
        preferences.agentHAPIEnabled = false
        fake.answer("usage", status: 1, stderr: "offline")
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 600, stop: "stop")])
        await agents.refresh()
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)
        #expect(spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        #expect(sessions.first?.hapiSessionID == "h1")
        #expect(fake.commands == ["--version", "usage", "usage"])
        agents.stop()
    }

    @Test func pendingLinkSurvivesANewSyncInstanceAndAnEmptyReport() async throws {
        await importPi(through: 600)
        agents.onScan = nil
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 600, stop: "stop")])
        await agents.refresh()
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 1_200)
        let fake = fake
        let restarted = HAPISync(modelContext: container.mainContext, preferences: preferences, agents: agents, home: home,
                                 runner: { _, arguments in fake.run(arguments) })
        fake.answer("usage", stdout: HAPIFixture.report([]))
        await restarted.sync(now: Fixture.date(10_000))
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)
        #expect(sessions.first?.hapiSessionID == "h1")
        agents.stop()
    }

    @Test func scansReconcileAdditionalCoverageOutsideTheReportWindow() async throws {
        await importPi(through: 1_200)
        let file = try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 300, stop: "stop")])
        await agents.refresh()
        #expect(spans.filter { $0.sessionKey == "hapi:h1" }.map(\.start) == [Fixture.date(300)])
        fake.answer("usage", stdout: HAPIFixture.report([]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines([Pi.prompt(at: 900, id: "q"), Pi.assistant(at: 1_200, stop: "stop")]))
        try handle.close()
        await agents.refresh()
        await sync.sync(now: Fixture.date(10_000))
        let imported = spans.filter { $0.sessionKey == "hapi:h1" }
        #expect(imported.map(\.start) == [Fixture.date(300)])
        #expect(imported.map(\.end) == [Fixture.date(900)])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 1_200)
        #expect(AgentMetrics.maxConcurrency(agents.samples(spans)) == 1)
        agents.stop()
    }

    @Test(arguments: [0.0, 0.5])
    func trailingWaitCoverageIncludesDiscardedFinalPieces(finalPiece: Double) async throws {
        await importPi(through: 600 + finalPiece)
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "toolUse"),
                     Pi.question(at: 600, duration: 590), Pi.assistant(at: 600 + finalPiece, stop: "aborted")])
        await agents.refresh()
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 10)
        #expect(spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        agents.stop()
    }

    @Test func aTurnWithOnlyWaitsStillSupersedesImportedWork() async throws {
        await importPi(through: 600)
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 0, stop: "toolUse"),
                     Pi.question(at: 600, duration: 600), Pi.assistant(at: 600, stop: "aborted")])
        await agents.refresh()
        #expect(spans.isEmpty)
        #expect(sessions.map(\.key) == ["pi:session-1"])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AgentTurnCoverage>()) == 1)
        agents.stop()
    }

    @Test func trailingSilenceIsCoveredButUnreadSuffixIsNot() async throws {
        await importPi(through: 4_000)
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "toolUse"),
                     Pi.assistant(at: 3_600, stop: "stop")])
        await agents.refresh()
        let imported = spans.filter { $0.sessionKey == "hapi:h1" }
        #expect(imported.map(\.start) == [Fixture.date(3_600)])
        #expect(imported.map(\.end) == [Fixture.date(4_000)])
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 410)
        agents.stop()
    }

    @Test func legacyNativeAssociationsDoNotNeedAnotherReport() async throws {
        preferences.agentPiEnabled = false
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "session-1", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        let local = AgentSession(key: "pi:session-1", source: .pi, flavor: "pi", agentSessionID: "session-1", lastActivity: Fixture.date(600))
        local.hapiSessionID = "h1"
        container.mainContext.insert(local)
        preferences.agentPiEnabled = true
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 600, stop: "stop")])
        await agents.refresh()
        #expect(spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        #expect(AgentMetrics.agentHours(agents.samples(spans)) == 600)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<HAPISessionLink>()) == 1)
        agents.stop()
    }
}
