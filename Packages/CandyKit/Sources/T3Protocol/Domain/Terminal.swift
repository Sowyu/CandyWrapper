import Foundation

// Terminal sessions (docs/protocol.md 9.1, packages/contracts/src/terminal.ts). The server owns the
// PTYs; a client opens one with `terminal.open`, then streams it with `terminal.attach` (a snapshot
// with the retained history, then live events) and drives it with `terminal.write` and
// `terminal.resize`. Thread ids on the wire are the environment's local ids.

public enum TerminalSessionStatus: String, Codable, Sendable {
    case starting, running, exited, error
}

/// `TerminalSessionSnapshot` (terminal.ts:103-117). `history` is the retained output with terminal
/// queries and replies stripped, so replaying it provokes no answers.
public struct TerminalSessionSnapshot: Codable, Sendable, Equatable {
    public var threadId: String
    public var terminalId: String
    public var cwd: String
    public var worktreePath: String?
    public var status: TerminalSessionStatus
    public var pid: Int?
    public var history: String
    public var exitCode: Int?
    public var exitSignal: Int?
    public var label: String
    public var updatedAt: String
    public var sequence: Int?

    public init(threadId: String, terminalId: String, cwd: String, worktreePath: String? = nil, status: TerminalSessionStatus,
                pid: Int? = nil, history: String, exitCode: Int? = nil, exitSignal: Int? = nil, label: String, updatedAt: String,
                sequence: Int? = nil) {
        self.threadId = threadId; self.terminalId = terminalId; self.cwd = cwd; self.worktreePath = worktreePath
        self.status = status; self.pid = pid; self.history = history; self.exitCode = exitCode; self.exitSignal = exitSignal
        self.label = label; self.updatedAt = updatedAt; self.sequence = sequence
    }
}

/// `TerminalSummary`: the snapshot without history, plus whether a subprocess runs under the shell.
public struct TerminalSummary: Codable, Sendable, Equatable {
    public var threadId: String
    public var terminalId: String
    public var cwd: String
    public var worktreePath: String?
    public var status: TerminalSessionStatus
    public var pid: Int?
    public var exitCode: Int?
    public var exitSignal: Int?
    public var hasRunningSubprocess: Bool
    public var label: String
    public var updatedAt: String

    public init(threadId: String, terminalId: String, cwd: String, worktreePath: String? = nil, status: TerminalSessionStatus,
                pid: Int? = nil, exitCode: Int? = nil, exitSignal: Int? = nil, hasRunningSubprocess: Bool, label: String, updatedAt: String) {
        self.threadId = threadId; self.terminalId = terminalId; self.cwd = cwd; self.worktreePath = worktreePath
        self.status = status; self.pid = pid; self.exitCode = exitCode; self.exitSignal = exitSignal
        self.hasRunningSubprocess = hasRunningSubprocess; self.label = label; self.updatedAt = updatedAt
    }
}

/// One `terminal.attach` (or `terminal.observe`) stream value, `TerminalAttachStreamEvent`.
public enum TerminalAttachEvent: Sendable, Equatable {
    case snapshot(TerminalSessionSnapshot)
    case output(String)
    case exited(code: Int?, signal: Int?)
    case closed
    case error(String)
    case cleared
    case restarted(TerminalSessionSnapshot)
    case activity(hasRunningSubprocess: Bool, label: String)
    /// A kind this build does not know; skipped.
    case unknown(String)

    /// Decodes from the stream's JSON. Output, the hot path, reads its string without a decoder.
    public init?(json: JSONValue) {
        guard let type = json["type"]?.stringValue else { return nil }
        switch type {
        case "output":
            guard let data = json["data"]?.stringValue else { return nil }
            self = .output(data)
        case "snapshot", "restarted":
            guard let value = json["snapshot"], let snapshot = try? value.decode(as: TerminalSessionSnapshot.self) else { return nil }
            self = type == "snapshot" ? .snapshot(snapshot) : .restarted(snapshot)
        case "exited":
            self = .exited(code: json["exitCode"]?.intValue, signal: json["exitSignal"]?.intValue)
        case "closed": self = .closed
        case "cleared": self = .cleared
        case "error": self = .error(json["message"]?.stringValue ?? "Terminal error")
        case "activity":
            guard case .bool(let running)? = json["hasRunningSubprocess"] else { return nil }
            self = .activity(hasRunningSubprocess: running, label: json["label"]?.stringValue ?? "")
        default: self = .unknown(type)
        }
    }
}

/// `subscribeTerminalMetadata` values: every terminal on the environment, then changes.
public enum TerminalMetadataEvent: Sendable, Equatable {
    case snapshot([TerminalSummary])
    case upsert(TerminalSummary)
    case remove(threadId: String, terminalId: String)

    public init?(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "snapshot":
            guard let list = json["terminals"], let terminals = try? list.decode(as: [TerminalSummary].self) else { return nil }
            self = .snapshot(terminals)
        case "upsert":
            guard let value = json["terminal"], let terminal = try? value.decode(as: TerminalSummary.self) else { return nil }
            self = .upsert(terminal)
        case "remove":
            guard let thread = json["threadId"]?.stringValue, let terminal = json["terminalId"]?.stringValue else { return nil }
            self = .remove(threadId: thread, terminalId: terminal)
        default: return nil
        }
    }
}

/// The terminal RPCs' payloads (terminal.ts:40-100). Optional fields are left out when nil, as
/// T3's client spreads them in only when set.
public enum TerminalRPC {
    public static let open = "terminal.open"
    public static let attach = "terminal.attach"
    public static let write = "terminal.write"
    public static let resize = "terminal.resize"
    public static let close = "terminal.close"
    public static let metadata = "subscribeTerminalMetadata"
    /// `cols` 1 to 1000, `rows` 1 to 500 (terminal.ts:13-14).
    public static let colsRange = 1...1000
    public static let rowsRange = 1...500
    /// `terminal.write` takes at most 65,536 characters per call.
    public static let maxWriteLength = 65_536

    /// Where a terminal starts: the thread's checkout and T3's project script variables.
    public struct Launch: Sendable, Equatable {
        public var cwd: String
        public var worktreePath: String?
        public var env: [String: String]
        public init(cwd: String, worktreePath: String?, env: [String: String]) {
            self.cwd = cwd; self.worktreePath = worktreePath; self.env = env
        }

        /// `projectScriptRuntimeEnv` (packages/shared/src/projectScripts.ts:58-71) as the drawer
        /// calls it: the project root, plus the worktree when the thread has one. The cwd is the
        /// worktree when there is one, else the project root (ChatView.tsx `gitCwd`).
        public init(projectRoot: String, worktreePath: String?) {
            var env = ["T3CODE_PROJECT_ROOT": projectRoot]
            if let worktreePath { env["T3CODE_WORKTREE_PATH"] = worktreePath }
            self.init(cwd: worktreePath ?? projectRoot, worktreePath: worktreePath, env: env)
        }
    }

    public static func openInput(threadId: String, terminalId: String, launch: Launch) -> JSONValue {
        .object(sessionFields(threadId, terminalId).merging(launchFields(launch)) { $1 })
    }

    /// Attach carries the launch so a session that is gone (closed by the server, or lost in a
    /// restart) opens again.
    /// A resubscription after the first reply sends `resume`, so the server keeps a closed terminal closed
    /// (contracts/src/terminal.ts:56-57, client-runtime/src/state/terminal.ts:48-53).
    public static func attachInput(threadId: String, terminalId: String, launch: Launch, resume: Bool = false) -> JSONValue {
        let input = openInput(threadId: threadId, terminalId: terminalId, launch: launch)
        guard resume, case .object(var o) = input else { return input }
        o["resume"] = .bool(true)
        return .object(o)
    }

    public static func writeInput(threadId: String, terminalId: String, data: String) -> JSONValue {
        var o = sessionFields(threadId, terminalId)
        o["data"] = .string(data)
        return .object(o)
    }

    public static func resizeInput(threadId: String, terminalId: String, cols: Int, rows: Int) -> JSONValue {
        var o = sessionFields(threadId, terminalId)
        o["cols"] = .number(Double(cols.clamped(to: colsRange)))
        o["rows"] = .number(Double(rows.clamped(to: rowsRange)))
        return .object(o)
    }

    /// The drawer's close deletes the history (ChatView.tsx `closeTerminal`).
    public static func closeInput(threadId: String, terminalId: String?, deleteHistory: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["threadId": .string(threadId), "deleteHistory": .bool(deleteHistory)]
        if let terminalId { o["terminalId"] = .string(terminalId) }
        return .object(o)
    }

    /// Splits input into `terminal.write`-sized pieces without cutting a character in two.
    public static func writeChunks(_ data: String) -> [String] {
        guard data.count > maxWriteLength else { return data.isEmpty ? [] : [data] }
        var chunks: [String] = []
        var rest = Substring(data)
        while !rest.isEmpty {
            let end = rest.index(rest.startIndex, offsetBy: maxWriteLength, limitedBy: rest.endIndex) ?? rest.endIndex
            chunks.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return chunks
    }

    private static func sessionFields(_ threadId: String, _ terminalId: String) -> [String: JSONValue] {
        ["threadId": .string(threadId), "terminalId": .string(terminalId)]
    }

    private static func launchFields(_ launch: Launch) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["cwd": .string(launch.cwd)]
        if let worktreePath = launch.worktreePath { o["worktreePath"] = .string(worktreePath) }
        if !launch.env.isEmpty { o["env"] = .object(launch.env.mapValues { .string($0) }) }
        return o
    }
}

/// Terminal ids and labels (packages/shared/src/terminalLabels.ts).
public enum TerminalLabels {
    /// `term-N` gives "Terminal N"; any other id is its own label.
    public static func label(_ terminalId: String) -> String {
        number(terminalId).map { "Terminal \($0)" } ?? terminalId
    }

    /// The server's label when it has one (idle shell or the running command), else `label`.
    public static func label(_ terminalId: String, summary: TerminalSummary?) -> String {
        let server = summary?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return server.isEmpty ? label(terminalId) : server
    }

    /// The lowest unused `term-N`.
    public static func nextId(_ existing: [String]) -> String {
        let used = Set(existing.compactMap(number))
        var n = 1
        while used.contains(String(n)) { n += 1 }
        return "term-\(n)"
    }

    /// `terminalNumber`: `term-N` or `terminal-N`, optionally followed by `-<uuid>`.
    static func number(_ terminalId: String) -> String? {
        let pattern = #"^term(?:inal)?-(\d+)(?:-[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: terminalId, range: NSRange(terminalId.startIndex..., in: terminalId)),
              let range = Range(match.range(at: 1), in: terminalId) else { return nil }
        return String(terminalId[range])
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
