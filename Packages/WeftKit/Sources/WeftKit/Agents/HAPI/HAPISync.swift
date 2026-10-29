import Foundation
import Observation
import SwiftData

/// Imports agent work from the user's HAPI hub through `hapi usage --json`: sessions on
/// other machines, and agents whose logs Weft can't read. Sessions on this Mac whose logs
/// Weft reads itself are only linked, never counted twice.
@MainActor
@Observable
public final class HAPISync {
    public enum Status: Equatable, Sendable {
        case off
        case notInstalled
        /// This `hapi` predates `hapi usage` (or is too old to run safely).
        case cliTooOld(version: String?)
        /// The hub doesn't have `/api/activity` yet.
        case hubTooOld
        case notSignedIn
        case syncing
        case synced(Date)
        case failed(String)
    }

    public private(set) var status: Status = .off
    public private(set) var binary: URL?
    public private(set) var hubURL: String?

    /// Runs a command; replaced in tests.
    public typealias Runner = @Sendable (URL, [String]) async throws -> ProcessOutput

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let agents: AgentActivityService
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var lastSuccess: Date?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var failures = 0
    /// Versions of the binaries already checked to be new enough to run.
    @ObservationIgnored private var checkedVersions: [String: String] = [:]

    /// HAPI stores turns only from the version that added them, and the hub answers at most 31 days.
    private let maximumWindow: TimeInterval = 31 * 86400 - 3600
    /// Read again before the last sync, in case a turn ended or was recorded late.
    private let overlap: TimeInterval = 15 * 60

    public init(modelContext: ModelContext, preferences: Preferences, agents: AgentActivityService,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                runner: @escaping Runner = { try await ProcessRunner.run($0, arguments: $1, timeout: 60) }) {
        self.modelContext = modelContext
        self.preferences = preferences
        self.agents = agents
        self.home = home
        self.runner = runner
    }

    public func start() {
        observeSettings()
        applySettings()
    }

    private var isEnabled: Bool { preferences.agentTrackingEnabled && preferences.agentHAPIEnabled }

    private func observeSettings() {
        withObservationTracking {
            _ = preferences.agentTrackingEnabled
            _ = preferences.agentHAPIEnabled
            _ = preferences.agentHAPIPath
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }

    private func applySettings() {
        loop?.cancel()
        loop = nil
        guard isEnabled else {
            status = .off
            agents.setRemoteLive([])
            return
        }
        // Every 5 minutes; less often while it keeps failing.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await sync()
                let delay: TimeInterval = switch failures {
                case 0: 5 * 60
                case 1: 15 * 60
                default: 60 * 60
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Syncs now unless it did in the last minute; for views about to show agent work.
    public func requestSync() {
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < 60 { return }
        Task { await sync() }
    }

    public func sync(now: Date = .now) async {
        guard isEnabled, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        lastAttempt = now

        guard let binary = HAPIBinaryLocator(home: home, override: preferences.agentHAPIPath).locate() else {
            self.binary = nil
            status = .notInstalled
            agents.setRemoteLive([])
            return
        }
        self.binary = binary
        status = .syncing
        do {
            guard let version = try await checkedVersion(binary) else { return }
            let window = min(maximumWindow, TimeInterval(max(1, preferences.agentBackfillDays)) * 86400)
            let since = max(now.addingTimeInterval(-window), lastSuccess?.addingTimeInterval(-overlap) ?? .distantPast)
            let output = try await runner(binary, ["usage", "--json", "--since", Self.milliseconds(since), "--until", Self.milliseconds(now)])
            guard handleExit(output, version: version) else {
                failures += 1
                return
            }
            let report = try HAPIActivityReport.decode(output.stdout)
            hubURL = report.hubUrl
            apply(report, now: now)
            lastSuccess = now
            failures = 0
            status = .synced(now)
        } catch {
            failures += 1
            status = .failed(Self.describe(error))
        }
    }

    // MARK: Running hapi

    /// The binary's version if it's new enough to run. HAPI before 0.30 started Claude for
    /// any command it didn't know, so it never gets one it might not.
    private func checkedVersion(_ binary: URL) async throws -> String? {
        let path = binary.path(percentEncoded: false)
        if let version = checkedVersions[path] { return version }
        let output = try await runner(binary, ["--version"])
        let text = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        let version = text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
        guard output.status == 0, let version, Self.isAtLeast(version, "0.30.0") else {
            status = .cliTooOld(version: version)
            failures += 1
            return nil
        }
        checkedVersions[path] = version
        return version
    }

    /// Sets the status for a failed run; true when it succeeded.
    private func handleExit(_ output: ProcessOutput, version: String) -> Bool {
        let stderr = String(decoding: output.stderr, as: UTF8.self)
        switch output.status {
        case 0:
            return true
        case 3:
            status = .notSignedIn
        case 4:
            status = .hubTooOld
        default:
            if stderr.contains("Unknown command") {
                status = .cliTooOld(version: version)
            } else {
                let line = stderr.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                status = .failed(line.map { String($0).replacingOccurrences(of: "hapi usage: ", with: "") } ?? String(localized: "hapi exited with status \(Int(output.status))", bundle: .module))
            }
        }
        return false
    }

    nonisolated static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (a, b) = (parts(version), parts(minimum))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return true
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case ProcessRunnerError.timedOut: String(localized: "hapi didn't answer within a minute.", bundle: .module)
        case ProcessRunnerError.launchFailed(let reason): String(localized: "Couldn't run hapi: \(reason)", bundle: .module)
        case HAPIReportError.unsupportedSchema(let schema): String(localized: "This hapi reports \(schema), which Weft doesn't read yet.", bundle: .module)
        case HAPIReportError.unreadable: String(localized: "Couldn't read what hapi reported.", bundle: .module)
        default: error.localizedDescription
        }
    }

    // MARK: Storing

    private func apply(_ report: HAPIActivityReport, now: Date) {
        var localFlavors: Set<String> = []
        if preferences.agentClaudeEnabled { localFlavors.insert("claude") }
        if preferences.agentCodexEnabled { localFlavors.insert("codex") }
        let host = ProcessInfo.processInfo.hostName.lowercased()
        let localHosts: Set<String> = [host, host.hasSuffix(".local") ? String(host.dropLast(6)) : host + ".local"]
        let decisions = HAPIImporter.plan(report, localFlavors: localFlavors, localHosts: localHosts, now: now,
                                          config: AgentTurnConfig(silentGap: TimeInterval(max(1, preferences.agentSilentGapMinutes) * 60)))

        var working: Set<String> = []
        for decision in decisions {
            switch decision {
            case .link(let localKey, let hapiID):
                let session = (try? modelContext.fetch(FetchDescriptor<AgentSession>(predicate: #Predicate { $0.key == localKey })))?.first
                session?.hapiSessionID = hapiID
            case .record(let imported):
                store(imported)
                if imported.isWorking { working.insert(imported.key) }
            }
        }
        try? modelContext.save()
        agents.setRemoteLive(working)
        agents.spansChanged()
    }

    /// Replaces the spans of the turns HAPI reported; older turns stay as they were.
    private func store(_ imported: HAPIImporter.Session) {
        let fileKey = imported.key
        let ids = imported.turnIDs
        let existing = (try? modelContext.fetch(FetchDescriptor<AgentSpan>(
            predicate: #Predicate { $0.fileKey == fileKey && ids.contains($0.turnID) }))) ?? []
        var stale = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var indexByTurn: [String: Int] = [:]
        for piece in imported.pieces {
            let index = indexByTurn[piece.turnID, default: 0]
            indexByTurn[piece.turnID] = index + 1
            let key = "\(piece.turnID)#\(index)"
            if let span = stale.removeValue(forKey: key) {
                span.start = piece.start
                span.end = piece.end
                span.isOpen = piece.isOpen
                span.waitedOnUser = piece.waitedOnUser
            } else {
                modelContext.insert(AgentSpan(key: key, sessionKey: imported.key, turnID: piece.turnID, fileKey: fileKey,
                                              turnStart: piece.turnStart, start: piece.start, end: piece.end, isOpen: piece.isOpen,
                                              trigger: piece.trigger, isSubagent: false, waitedOnUser: piece.waitedOnUser))
            }
        }
        for span in stale.values { modelContext.delete(span) }

        let key = imported.key
        let last = imported.pieces.map(\.end).max()
        let session = (try? modelContext.fetch(FetchDescriptor<AgentSession>(predicate: #Predicate { $0.key == key })))?.first ?? {
            let session = AgentSession(key: key, source: .hapi, flavor: imported.flavor, agentSessionID: imported.agentSessionID,
                                       lastActivity: last ?? .distantPast)
            modelContext.insert(session)
            return session
        }()
        session.flavor = imported.flavor
        session.hapiSessionID = imported.hapiID
        session.title = imported.title ?? session.title
        session.projectPath = imported.projectPath ?? session.projectPath
        session.host = imported.host
        if let last { session.lastActivity = max(session.lastActivity, last) }
    }
}
