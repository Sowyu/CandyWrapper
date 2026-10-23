import Foundation
import T3Protocol

// The relay to every machine (docs/orchestrator.md, "Every machine"). T3's thread tools reach only the server the
// Orchestrator runs on, so it writes `orchestrator-call` blocks and CandyWrapper runs them over its own connection to
// the machine each call names, then sends the results back as one "Result:" message.

/// One call from an `orchestrator-call` block: one JSON object per line.
public struct OrchestratorCall: Equatable, Sendable {
    public enum Tool: String, Sendable { case list, read, send, launch, archive }
    /// Nil when the line didn't parse or named no known tool; `raw` then says what came in.
    public var tool: Tool?
    public var raw: String
    public var machine: String?
    public var threadId: String?
    public var text: String?
    public var last: Int?
    public var projectId: String?
    public var title: String?
    /// A Models row label.
    public var model: String?
    /// A base ref; set, the thread gets its own worktree from it.
    public var worktree: String?
    public var confirmed = false

    public init(tool: Tool?, raw: String = "", machine: String? = nil, threadId: String? = nil, text: String? = nil, last: Int? = nil,
                projectId: String? = nil, title: String? = nil, model: String? = nil, worktree: String? = nil, confirmed: Bool = false) {
        self.tool = tool; self.raw = raw; self.machine = machine; self.threadId = threadId; self.text = text; self.last = last
        self.projectId = projectId; self.title = title; self.model = model; self.worktree = worktree; self.confirmed = confirmed
    }

    /// The calls in a block's body: a JSON object per line, or one object or array spread over several lines.
    public static func parse(_ body: String) -> [OrchestratorCall] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let whole = json(trimmed) {
            if case .array(let items) = whole { return items.map { call($0, raw: trimmed) } }
            if case .object = whole { return [call(whole, raw: trimmed)] }
        }
        return trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
            json(line).map { call($0, raw: line) } ?? OrchestratorCall(tool: nil, raw: line)
        }
    }

    private static func json(_ s: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    private static func call(_ v: JSONValue, raw: String) -> OrchestratorCall {
        func s(_ k: String) -> String? {
            switch v[k] {
            case .string(let x)?: x.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : x
            case .number(let n)?: String(Int(n))
            default: nil
            }
        }
        let last: Int? = if case .number(let n)? = v["last"] { Int(n) } else { s("last").flatMap(Int.init) }
        let confirmed = if case .bool(let b)? = v["confirmed"] { b } else { false }
        return OrchestratorCall(tool: s("tool").flatMap { Tool(rawValue: $0.lowercased().replacingOccurrences(of: "thread_", with: "")) },
                                raw: raw, machine: s("machine"), threadId: s("threadId"), text: s("text"), last: last,
                                projectId: s("projectId"), title: s("title"), model: s("model"), worktree: s("worktree"), confirmed: confirmed)
    }
}

/// A machine CandyWrapper connects to, as the brief and the relay name it.
public struct OrchestratorMachineRef: Equatable, Sendable {
    public var id: String
    public var label: String
    /// The machine the Orchestrator's own thread runs on.
    public var isHome: Bool
    public var connected: Bool

    public init(id: String, label: String, isHome: Bool, connected: Bool = true) {
        self.id = id; self.label = label; self.isHome = isHome; self.connected = connected
    }

    /// The machine `name` means: its id, else its label ignoring case. An unknown or ambiguous label is nil.
    public static func resolve(_ name: String, in machines: [Self]) -> Self? {
        if let m = machines.first(where: { $0.id == name }) { return m }
        let matches = machines.filter { $0.label.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The brief's machine list.
    public static func briefList(_ machines: [Self]) -> String {
        guard !machines.isEmpty else { return "- (none)" }
        return machines.map { m in
            "- \(m.label) (machine \(m.id))" + (m.isHome ? ": you run here" : "") + (m.connected ? "" : ", offline right now")
        }.joined(separator: "\n")
    }
}

/// What CandyWrapper needs from the app to run calls. Every call goes to `request` with the machine it names.
@MainActor
public struct OrchestratorRelayHost {
    public var machines: () -> [OrchestratorMachineRef]
    public var snapshot: (String) -> ShellSnapshot?
    public var request: (_ machine: String, _ method: String, _ payload: JSONValue) async throws -> JSONValue
    public var config: () -> OrchestratorConfig
    public var update: ((inout OrchestratorConfig) -> Void) -> Void
    /// The Models rows the machine's catalog offers.
    public var rows: (String) -> [OrchestratorModelRow]
    public var runtimeMode: (String) -> String
    /// `message.dispatch` for a local thread id.
    public var message: (_ threadId: String, _ text: String, _ selection: ModelSelection, _ queue: Bool) -> JSONValue
    /// `orchestration.launchThread`'s input.
    public var launch: (_ threadId: String, _ projectId: String, _ title: String, _ text: String, _ selection: ModelSelection,
                        _ runtimeMode: String, _ workspace: JSONValue) -> JSONValue
    /// The Orchestrator's own thread, scoped.
    public var orchestrator: () -> ThreadId?
    public var now: () -> Date

    public init(machines: @escaping () -> [OrchestratorMachineRef], snapshot: @escaping (String) -> ShellSnapshot?,
                request: @escaping (String, String, JSONValue) async throws -> JSONValue, config: @escaping () -> OrchestratorConfig,
                update: @escaping ((inout OrchestratorConfig) -> Void) -> Void, rows: @escaping (String) -> [OrchestratorModelRow],
                runtimeMode: @escaping (String) -> String, message: @escaping (String, String, ModelSelection, Bool) -> JSONValue,
                launch: @escaping (String, String, String, String, ModelSelection, String, JSONValue) -> JSONValue,
                orchestrator: @escaping () -> ThreadId?, now: @escaping () -> Date = Date.init) {
        self.machines = machines; self.snapshot = snapshot; self.request = request; self.config = config; self.update = update
        self.rows = rows; self.runtimeMode = runtimeMode; self.message = message; self.launch = launch
        self.orchestrator = orchestrator; self.now = now
    }
}

/// Runs a turn's calls and writes the "Result:" message.
@MainActor
public struct OrchestratorRelay {
    nonisolated public static let resultPrefix = "Result: "
    // ponytail: 10 calls a turn and 40 threads a machine in a list; raise them if the Orchestrator asks for more often
    nonisolated public static let maxCalls = 10
    nonisolated static let listLimit = 40
    nonisolated static let messageLimit = 1500

    public let host: OrchestratorRelayHost
    public init(host: OrchestratorRelayHost) { self.host = host }

    /// Whether a message is a result message the app sent.
    nonisolated public static func isResultMessage(_ text: String) -> Bool { text.hasPrefix(resultPrefix) }

    /// The one-line summaries of a result message, for the chat.
    nonisolated public static func summaries(_ text: String) -> [String] {
        text.split(separator: "\n").filter { $0.hasPrefix(resultPrefix) }.map { String($0.dropFirst(resultPrefix.count)) }
    }

    /// Runs `calls` in order and returns the message for the Orchestrator, or nil when there were none.
    public func run(_ calls: [OrchestratorCall]) async -> String? {
        guard !calls.isEmpty else { return nil }
        var parts: [String] = []
        for (i, call) in calls.enumerated() {
            guard i < Self.maxCalls else {
                parts.append("\(Self.resultPrefix)skipped \(calls.count - Self.maxCalls) more calls. At most \(Self.maxCalls) run in one turn.")
                break
            }
            parts.append(await run(call))
        }
        return parts.joined(separator: "\n\n")
    }

    func run(_ call: OrchestratorCall) async -> String {
        // Two machines can share a label, like two servers on one Mac: then the text names the id too.
        let named = host.machines()
        let machines = named.map { m in
            var m = m
            if named.contains(where: { $0.id != m.id && $0.label.compare(m.label, options: .caseInsensitive) == .orderedSame }) { m.label += " (machine \(m.id))" }
            return m
        }
        guard let tool = call.tool else {
            return refusal("couldn't read the call `\(call.raw.prefix(200))`. Write one JSON object per line with a \"tool\" of list, read, send, launch or archive.")
        }
        if tool == .list {
            // The list's headers carry every id already.
            if let name = call.machine {
                guard let m = OrchestratorMachineRef.resolve(name, in: named) else { return unknownMachine(name, named) }
                return list([m], title: call.title)
            }
            return list(named, title: call.title)
        }
        guard let name = call.machine else {
            let hint = call.threadId.flatMap { id in named.first { host.snapshot($0.id)?.threads.contains { $0.id.rawValue == id } == true } }
            return refusal("\(tool.rawValue) needs a \"machine\"." + (hint.map { " Thread \(call.threadId ?? "") is on \($0.label) (machine \($0.id))." } ?? ""))
        }
        // Resolve against the real labels, then speak with the clear ones.
        guard let target = OrchestratorMachineRef.resolve(name, in: named), let machine = machines.first(where: { $0.id == target.id }) else {
            return unknownMachine(name, named)
        }
        guard machine.connected, let snapshot = host.snapshot(machine.id) else { return refusal("\(machine.label) isn't connected right now.") }
        if tool == .launch { return await launch(call, on: machine, snapshot) }
        guard let id = call.threadId else { return refusal("\(tool.rawValue) needs a \"threadId\".") }
        guard let thread = snapshot.threads.first(where: { $0.id.rawValue == id && $0.deletedAt == nil && $0.archivedAt == nil }) else {
            return refusal("there is no thread \(id) on \(machine.label). Call list to see its threads.")
        }
        switch tool {
        case .read: return await read(thread, on: machine, last: call.last)
        case .send: return await send(call, to: thread, on: machine)
        case .archive: return await archive(thread, on: machine)
        case .list, .launch: return ""
        }
    }

    // MARK: Tools

    /// `title` keeps the threads whose title contains it, past the list's cap.
    func list(_ machines: [OrchestratorMachineRef], title: String? = nil) -> String {
        var body: [String] = []
        var total = 0
        let config = host.config()
        let now = host.now()
        for m in machines {
            var head = "## \(m.label) (machine \(m.id))" + (m.isHome ? ", where you run" : "")
            guard m.connected, let snapshot = host.snapshot(m.id) else {
                head += ": offline"
                body.append(head)
                continue
            }
            body.append(head)
            let projects = Dictionary(snapshot.projects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            body.append("Projects: " + (snapshot.projects.isEmpty ? "none" : snapshot.projects.map { "\($0.title) (projectId \($0.id.rawValue))" }.joined(separator: ", ")))
            let own = host.orchestrator()
            let threads = snapshot.threads
                .filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil && $0.id.scoped(to: m.id) != own }
                .filter { t in title.map { t.title.localizedCaseInsensitiveContains($0) } ?? true }
                .sorted { ($0.updatedAt.epochMs ?? 0) > ($1.updatedAt.epochMs ?? 0) }
            total += threads.count
            for t in threads.prefix(Self.listLimit) {
                let scoped = t.id.scoped(to: m.id)
                let permission = OrchestratorPermission.of(t, handsOff: config.isHandsOff(scoped), windowMinutes: config.askFirstMinutes,
                                                           now: now, relayedAtMs: config.relayedAt[scoped.rawValue])
                var line = "- “\(t.title)” (threadId \(t.id.rawValue), project \(projects[t.projectId] ?? t.projectId.rawValue)): \(Self.state(t))"
                if config.relayWorkers.contains(scoped.rawValue) { line += ", your worker" }
                if let note = permission.note { line += ". \(note.prefix(1).uppercased())\(note.dropFirst())" }
                body.append(line)
            }
            if threads.count > Self.listLimit { body.append("- …and \(threads.count - Self.listLimit) older threads. Add \"title\" to find one.") }
            if threads.isEmpty { body.append("- (no threads)") }
        }
        let summary = "listed \(total) thread\(total == 1 ? "" : "s") on \(machines.count) machine\(machines.count == 1 ? "" : "s")"
        return Self.resultPrefix + summary + "\n" + body.joined(separator: "\n")
    }

    func read(_ thread: ThreadShell, on machine: OrchestratorMachineRef, last: Int?) async -> String {
        let count = min(max(last ?? 5, 1), 20)
        let projection: ThreadProjection
        do {
            let json = try await host.request(machine.id, "orchestration.getThreadProjection", .object(["threadId": .string(thread.id.rawValue)]))
            projection = try json.decode(as: ThreadProjection.self)
        } catch {
            return refusal("couldn't read “\(thread.title)” on \(machine.label): \(Self.describe(error))")
        }
        let messages = projection.messages
            .filter { ($0.role == "user" || $0.role == "assistant") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.workflowScript != true }
            .sorted { ($0.createdAt.epochMs ?? 0, $0.id.rawValue) < ($1.createdAt.epochMs ?? 0, $1.id.rawValue) }
            .suffix(count)
        var lines = ["\(Self.resultPrefix)read “\(thread.title)” on \(machine.label)",
                     "Thread \(thread.id.rawValue) on \(machine.label) (machine \(machine.id)): \(Self.state(thread))"]
        for m in messages {
            var text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > Self.messageLimit { text = String(text.prefix(Self.messageLimit)) + " …(cut)" }
            lines.append("[\(m.role)] \(text)")
        }
        if messages.isEmpty { lines.append("(no messages yet)") }
        return lines.joined(separator: "\n")
    }

    func send(_ call: OrchestratorCall, to thread: ThreadShell, on machine: OrchestratorMachineRef) async -> String {
        guard let text = call.text else { return refusal("send needs a \"text\".") }
        let config = host.config()
        let scoped = thread.id.scoped(to: machine.id)
        let permission = OrchestratorPermission.of(thread, handsOff: config.isHandsOff(scoped), windowMinutes: config.askFirstMinutes,
                                                   now: host.now(), relayedAtMs: config.relayedAt[scoped.rawValue])
        switch permission {
        case .handsOff: return refusal("“\(thread.title)” on \(machine.label) is Hands off. Report on it, never prompt it.")
        case .askFirst(let m) where !call.confirmed:
            return refusal("the user wrote in “\(thread.title)” on \(machine.label) \(m == 0 ? "just now" : "\(m) min ago"). Ask the user first, then send again with \"confirmed\":true.")
        default: break
        }
        let queue = OrchestratorEvent.running.contains(thread.status)
        do {
            _ = try await host.request(machine.id, "orchestration.dispatchCommand", host.message(thread.id.rawValue, text, thread.modelSelection, queue))
        } catch {
            return refusal("couldn't send to “\(thread.title)” on \(machine.label): \(Self.describe(error))")
        }
        noteRelayed(scoped)
        return Self.resultPrefix + (queue ? "queued for “\(thread.title)” on \(machine.label) behind its running turn" : "sent to “\(thread.title)” on \(machine.label)")
    }

    func launch(_ call: OrchestratorCall, on machine: OrchestratorMachineRef, _ snapshot: ShellSnapshot) async -> String {
        guard let text = call.text else { return refusal("launch needs a \"text\", the first prompt.") }
        guard let projectId = call.projectId, let project = snapshot.projects.first(where: { $0.id.rawValue == projectId }) else {
            let ids = snapshot.projects.map { "\($0.title) (projectId \($0.id.rawValue))" }.joined(separator: ", ")
            return refusal("launch needs a \"projectId\" from \(machine.label): \(ids.isEmpty ? "it has no projects" : ids).")
        }
        let config = host.config()
        let running = runningWorkers()
        guard running < config.crewLimit else {
            return refusal("\(running) workers are running and the limit is \(config.crewLimit). Wait for one to finish.")
        }
        let rows = host.rows(machine.id)
        let selection: ModelSelection
        if let label = call.model {
            guard let row = rows.first(where: { $0.label.compare(label, options: .caseInsensitive) == .orderedSame }) else {
                return refusal("no Models row “\(label)” is available on \(machine.label). Rows there: \(rows.map(\.label).joined(separator: ", ")).")
            }
            selection = row.selection
        } else if let row = rows.first(where: \.isDefault) ?? rows.first {
            selection = row.selection
        } else if let fallback = project.defaultModelSelection {
            selection = fallback
        } else {
            return refusal("no model from the Models list is available on \(machine.label).")
        }
        let workspace: JSONValue = call.worktree.map { .object(["type": .string("worktree"), "baseRef": .string($0)]) } ?? .object(["type": .string("root")])
        let local = UUID().uuidString.lowercased()
        let title = call.title ?? "Worker"
        do {
            _ = try await host.request(machine.id, "orchestration.launchThread",
                                       host.launch(local, project.id.rawValue, title, text, selection, host.runtimeMode(machine.id), workspace))
        } catch {
            return refusal("couldn't launch “\(title)” on \(machine.label): \(Self.describe(error))")
        }
        let scoped = ThreadId(local).scoped(to: machine.id)
        host.update { c in
            c.relayWorkers.insert(scoped.rawValue)
            if c.relayWorkers.count > 200 { c.relayWorkers = Set(c.relayWorkers.sorted().suffix(200)) }
        }
        noteRelayed(scoped)
        return Self.resultPrefix + "launched “\(title)” on \(machine.label) (machine \(machine.id), threadId \(local), project \(project.title))"
    }

    func archive(_ thread: ThreadShell, on machine: OrchestratorMachineRef) async -> String {
        let scoped = thread.id.scoped(to: machine.id)
        if host.config().isHandsOff(scoped) { return refusal("“\(thread.title)” on \(machine.label) is Hands off, so it stays.") }
        if OrchestratorEvent.running.contains(thread.status) { return refusal("“\(thread.title)” on \(machine.label) is still running.") }
        let command: JSONValue = .object(["type": .string("thread.archive"), "commandId": .string(UUID().uuidString.lowercased()),
                                          "threadId": .string(thread.id.rawValue)])
        do { _ = try await host.request(machine.id, "orchestration.dispatchCommand", command) } catch {
            return refusal("couldn't archive “\(thread.title)” on \(machine.label): \(Self.describe(error))")
        }
        host.update { $0.relayWorkers.remove(scoped.rawValue) }
        return Self.resultPrefix + "archived “\(thread.title)” on \(machine.label)"
    }

    // MARK: Limits

    /// Running workers on every machine: threads the relay launched, plus the Orchestrator thread's own children.
    // ponytail: top-level threads its own t3_thread_launch starts carry no parent, so they don't count; tag them if the cap slips
    func runningWorkers() -> Int {
        let config = host.config()
        let own = host.orchestrator()
        var count = 0
        for m in host.machines() {
            for t in host.snapshot(m.id)?.threads ?? [] where OrchestratorEvent.running.contains(t.status) && t.archivedAt == nil {
                let scoped = t.id.scoped(to: m.id)
                let child = own.map { t.lineage.parentThreadId?.scoped(to: m.id) == $0 } ?? false
                if child || config.relayWorkers.contains(scoped.rawValue) { count += 1 }
            }
        }
        return count
    }

    /// The server records a relayed message as the user's (`createdBy: "user"`, ws.ts:1830), so the relay notes its
    /// own send for the ask-first rule. Entries older than a day go.
    private func noteRelayed(_ scoped: ThreadId) {
        let ms = Int64(host.now().timeIntervalSince1970 * 1000)
        host.update { c in
            c.relayedAt[scoped.rawValue] = ms
            c.relayedAt = c.relayedAt.filter { ms - $0.value < 86_400_000 }
        }
    }

    // MARK: Text

    private func refusal(_ why: String) -> String { Self.resultPrefix + "refused: " + why }

    private func unknownMachine(_ name: String, _ machines: [OrchestratorMachineRef]) -> String {
        refusal("no machine “\(name)”. Machines: " + machines.map { "\($0.label) (machine \($0.id))" }.joined(separator: ", ") + ".")
    }

    static func state(_ t: ThreadShell) -> String {
        if let r = t.pendingRuntimeRequest { return r.kind == .userInput ? "has a question for the user" : "waiting on an approval" }
        if OrchestratorEvent.running.contains(t.status) { return "working" }
        if t.status == .failed { return "failed" + (t.lastError.map { ": \($0.prefix(160))" } ?? "") }
        return t.latestRunCompletedAt.value != nil ? "finished" : "idle"
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }
}
