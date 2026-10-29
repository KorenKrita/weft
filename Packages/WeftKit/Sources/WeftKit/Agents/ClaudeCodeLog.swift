import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/*/<session>.jsonl` and their
/// `subagents/agent-*.jsonl`) into events. Feed it lines in file order.
///
/// Only timestamps, kinds of lines and tool-call ids are kept. Prompt text is looked at just
/// enough to recognize interrupts and slash commands, and never leaves the parser.
struct ClaudeCodeLogParser {
    private(set) var events: [AgentLogEvent] = []
    private(set) var meta = AgentLogMeta()

    /// Subagent logs mark every line as a sidechain; in a main log those lines are a
    /// subagent's work inside the current turn (older versions wrote them inline).
    private let isSubagentLog: Bool
    private let decoder = JSONDecoder()
    private var toolCalls: [String: Date] = [:]
    /// When an external permission handler (a hook, such as HAPI's) got its answer.
    private var hookDecisions: [String: Date] = [:]
    private var customTitle: String?
    private var aiTitle: String?
    private var agentName: String?

    init(isSubagentLog: Bool = false) {
        self.isSubagentLog = isSubagentLog
        meta.isSubagent = isSubagentLog
    }

    mutating func consume(_ line: UnsafeRawBufferPointer, offset: Int64) {
        if JSONLines.hasPrefix(line, #"{"type":""#) {
            consumeMetadata(line)
            return
        }
        guard let decoded = try? decoder.decode(Line.self, from: Data(line)) else { return }
        if meta.sessionID == nil { meta.sessionID = decoded.sessionId }
        if meta.cwd == nil, decoded.type == "user" || decoded.type == "assistant" { meta.cwd = decoded.cwd }
        guard let at = decoded.timestamp.flatMap(Timestamp.parse) else { return }

        if decoded.isSidechain == true, !isSubagentLog {
            if decoded.type == "assistant" || decoded.type == "user" { events.append(.activity(at)) }
            return
        }

        switch decoded.type {
        case "assistant":
            events.append(.activity(at))
            for item in decoded.message?.content?.items ?? [] where item.type == "tool_use" {
                if let id = item.id { toolCalls[id] = at }
            }
        case "user":
            consumeUser(decoded, at: at, offset: offset)
        case "system":
            switch decoded.subtype {
            case "turn_duration": events.append(.end(at: at, id: nil))
            // Written while the user is away, or for the user's own commands: not agent work.
            case "away_summary", "local_command": break
            default: events.append(.progress(at))
            }
        case "attachment":
            if decoded.attachment?.type == "hook_permission_decision", let id = decoded.attachment?.toolUseID {
                hookDecisions[id] = at
            }
        default:
            break
        }
    }

    private mutating func consumeUser(_ line: Line, at: Date, offset: Int64) {
        let items = line.message?.content?.items ?? []
        let results = items.filter { $0.type == "tool_result" }
        if line.toolUseResult != nil || !results.isEmpty {
            for result in results {
                guard let id = result.toolUseID else { continue }
                if let called = toolCalls.removeValue(forKey: id), let source = line.permissionDecision?.source,
                   source.hasPrefix("user") || source == "hook" {
                    // The user answered a permission prompt or a question. For a hook the
                    // decision is logged separately, which leaves out the tool's own run time.
                    let answered = hookDecisions.removeValue(forKey: id) ?? at
                    if answered > called { events.append(.wait(DateInterval(start: called, end: answered))) }
                }
            }
            events.append(.activity(at))
            return
        }

        let text = line.message?.content?.firstText ?? ""
        if text.hasPrefix("[Request interrupted") {
            events.append(.end(at: at, id: nil))
            return
        }
        events.append(.prompt(id: line.uuid ?? "offset-\(offset)", at: at, trigger: Self.trigger(line, text: text), offset: offset))
    }

    /// Only prompts the user typed (or sent through an SDK) end a turn that's still open;
    /// everything else the agent gets while busy joins it.
    private static func trigger(_ line: Line, text: String) -> AgentTrigger {
        if line.isMeta == true { return .system }
        if let kind = line.origin?.kind {
            guard kind == "human" else { return .system }
            return line.promptSource == "queued" ? .queued : .user
        }
        switch line.promptSource {
        case "queued": return .queued
        case "system": return .system
        default: break
        }
        // Slash commands and their output are echoed as user lines.
        for prefix in ["<command-", "<local-command-", "<bash-", "<user-memory-"] where text.hasPrefix(prefix) {
            return .system
        }
        return .user
    }

    private mutating func consumeMetadata(_ line: UnsafeRawBufferPointer) {
        if JSONLines.hasPrefix(line, #"{"type":"api-request",""#) || JSONLines.hasPrefix(line, #"{"type":"api-request-shape""#) {
            // A request to the model is going out: the agent is thinking, maybe silently for a while.
            if let text = JSONLines.string(after: #""timestamp":""#, in: line, limit: 512), let at = Timestamp.parse(text) {
                events.append(.progress(at))
            }
        } else if JSONLines.hasPrefix(line, #"{"type":"ai-title""#) || JSONLines.hasPrefix(line, #"{"type":"custom-title""#)
                    || JSONLines.hasPrefix(line, #"{"type":"agent-name""#) {
            guard let title = try? decoder.decode(TitleLine.self, from: Data(line)) else { return }
            if let value = title.customTitle?.nonEmpty { customTitle = value }
            if let value = title.aiTitle?.nonEmpty { aiTitle = value }
            if let value = title.agentName?.nonEmpty { agentName = value }
            meta.title = customTitle ?? aiTitle ?? agentName
        }
    }

    /// Parses a whole buffer; for tests and small files.
    static func parse(_ data: Data, base: Int64 = 0, isSubagentLog: Bool = false) -> (events: [AgentLogEvent], meta: AgentLogMeta, consumed: Int) {
        var parser = ClaudeCodeLogParser(isSubagentLog: isSubagentLog)
        let consumed = JSONLines.forEachLine(in: data, base: base) { parser.consume($0, offset: $1) }
        return (parser.events, parser.meta, consumed)
    }
}

// MARK: - Line shapes

/// The few fields of a transcript line that matter here. Everything else, including tool
/// output, is skipped by the decoder.
private struct Line: Decodable {
    var type: String
    var subtype: String?
    var timestamp: String?
    var uuid: String?
    var cwd: String?
    var sessionId: String?
    var isMeta: Bool?
    var isSidechain: Bool?
    var promptSource: String?
    var origin: Origin?
    var toolUseResult: Present?
    var permissionDecision: Decision?
    var message: Message?
    var attachment: Attachment?

    struct Origin: Decodable { var kind: String? }
    struct Decision: Decodable { var source: String? }
    struct Message: Decodable { var content: Content? }
    struct Attachment: Decodable {
        var type: String?
        var toolUseID: String?
    }
}

private enum Content: Decodable {
    case text(String)
    case items([Item])

    struct Item: Decodable {
        var type: String?
        var id: String?
        var text: String?
        var toolUseID: String?

        enum CodingKeys: String, CodingKey {
            case type, id, text
            case toolUseID = "tool_use_id"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .items(try container.decode([Item].self))
        }
    }

    var items: [Item] {
        if case .items(let items) = self { items } else { [] }
    }

    var firstText: String? {
        switch self {
        case .text(let text): text
        case .items(let items): items.first { $0.type == "text" }?.text
        }
    }
}

/// Decodes to nothing: only whether the key is there matters.
private struct Present: Decodable {
    init(from decoder: any Decoder) throws {}
}

private struct TitleLine: Decodable {
    var aiTitle: String?
    var customTitle: String?
    var agentName: String?
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
