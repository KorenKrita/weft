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
