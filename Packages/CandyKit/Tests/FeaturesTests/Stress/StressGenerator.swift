import Foundation
import T3Protocol
@testable import T3Store

/// A small, fast, seedable generator (SplitMix64), so every stress run replays from its seed.
struct StressRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }

    mutating func pick<T>(_ values: [T]) -> T { values[int(0...values.count - 1)] }
}

/// One thread's server-side history, written the way T3's server writes it: every event is a
/// `subscribeThread` item JSON object (orchestrationV2.ts:1640-1800, the `event` stream item), with
/// the item shapes of `OrchestrationV2TurnItem` (orchestrationV2.ts:1372-1584). Runs go through
/// the states the server moves them through (queued, preparing, running, waiting, completed,
/// failed, interrupted, cancelled); turns stream reasoning and answers as growing text, call tools
/// that succeed or fail, ask for approvals and answers, retry the provider, retry whole attempts,
/// compact the context, start subagents, take steers and queue the next prompt.
struct StressThreadScript {
    var threadId: String
    /// The `thread` object of the first snapshot.
    var thread: [String: Any]
    /// The `event` objects, in sequence order.
    var events: [[String: Any]]
    /// Prompts the user sends, by the index of the first event that confirms them. The client shows
    /// them as optimistic messages a few steps before.
    var sends: [Int: (id: String, text: String, intent: String?)]
    /// What the script exercised, for the coverage check.
    var features: Set<String>
    /// Rows a forked thread inherits from its parent, in the first snapshot.
    var inherited: [[String: Any]] = []
}

struct StressThreadGenerator {
    enum Mode: Sendable { case normal, providerSubagent, forked }

    var rng: StressRNG
    var threadId: String
    var mode: Mode
    /// Runs to generate.
    var runCount: Int
    /// Steps per run, at most.
    var maxSteps: Int

    private var clockMs: Int64 = 1_780_000_000_000
    private var events: [[String: Any]] = []
    private var inherited: [[String: Any]] = []
    private var sends: [Int: (id: String, text: String, intent: String?)] = [:]
    private var features = Set<String>()
    private var itemCounter = 0

    init(seed: UInt64, threadId: String = "thread-stress", mode: Mode = .normal, runCount: Int, maxSteps: Int = 8) {
        rng = StressRNG(seed: seed)
        self.threadId = threadId
        self.mode = mode
        self.runCount = runCount
        self.maxSteps = maxSteps
    }

    // MARK: Time and ids

    static func iso(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let p = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!, Int(ms % 1000))
    }

    private mutating func tick(_ maxMs: Int = 1_500) -> String {
        clockMs += Int64(rng.int(1...maxMs))
        return Self.iso(clockMs)
    }

    private var now: String { Self.iso(clockMs) }

    private mutating func emit(_ type: String, _ payload: [String: Any], runId: String? = nil) {
        events.append([
            "id": "event:\(events.count)", "type": type, "threadId": threadId, "runId": runId ?? NSNull(),
            "occurredAt": tick(400), "payload": payload,
        ])
    }

    // MARK: Entities

    func threadObject(createdAt: String) -> [String: Any] {
        var lineage: [String: Any] = ["rootThreadId": threadId, "parentThreadId": NSNull(), "relationshipToParent": NSNull()]
        if mode == .forked {
            lineage = ["rootThreadId": "thread-parent", "parentThreadId": "thread-parent", "relationshipToParent": "fork"]
        }
        if mode == .providerSubagent {
            lineage = ["rootThreadId": "thread-parent", "parentThreadId": "thread-parent", "relationshipToParent": "subagent"]
        }
        return [
            "id": threadId, "projectId": "project-stress", "title": "Stress", "providerInstanceId": "claudeAgent",
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"], "runtimeMode": "full-access",
            "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(), "activeProviderThreadId": NSNull(),
            "lineage": lineage, "forkedFrom": NSNull(), "createdBy": mode == .providerSubagent ? "agent" : "user",
            "creationSource": mode == .providerSubagent ? "provider" : "web", "createdAt": createdAt, "updatedAt": createdAt,
            "archivedAt": NSNull(), "deletedAt": NSNull(), "settledOverride": NSNull(), "settledAt": NSNull(), "lastVisitedAt": NSNull(),
        ]
    }

    final class RunState {
        let ordinal: Int
        let id: String
        var attempt = 1
        var status = "queued"
        var requestedAt = ""
        var startedAt: String?
        var completedAt: String?
        var queued: Bool
        var userMessageId: String
        var nextItem = 1
        var providerTurn: String
        var queueHeld = false
        var openRequests: [([String: Any], String, String, Int, String, [String: Any])] = []
        var prompt = ("", "")

        init(ordinal: Int, queued: Bool) {
            self.ordinal = ordinal
            id = "run:stress:\(ordinal)"
            self.queued = queued
            userMessageId = "msg-u-\(ordinal)"
            providerTurn = "provider-turn:\(ordinal):1"
        }

        var attemptId: String { "run-attempt:\(id):\(attempt)" }
        var rootNode: String { "node:\(id):root:\(attempt)" }
    }

    private func runObject(_ run: RunState) -> [String: Any] {
        [
            "id": run.id, "threadId": threadId, "ordinal": run.ordinal, "rootNodeId": run.rootNode,
            "activeAttemptId": run.attemptId, "checkpointId": NSNull(), "userMessageId": run.userMessageId,
            "providerThreadId": "provider-thread:stress", "status": run.status,
            "queuePosition": run.status == "queued" ? 0 : NSNull(), "queueHeld": run.queueHeld,
            "requestedAt": run.requestedAt, "startedAt": run.startedAt ?? NSNull(), "completedAt": run.completedAt ?? NSNull(),
        ]
    }

    private mutating func runUpdated(_ run: RunState, _ status: String, created: Bool = false) {
        run.status = status
        if ["preparing", "starting", "running"].contains(status), run.startedAt == nil, status == "running" { run.startedAt = now }
        if ["completed", "failed", "interrupted", "cancelled"].contains(status) { run.completedAt = now }
        emit(created ? "run.created" : "run.updated", runObject(run), runId: run.id)
    }

    private mutating func attemptUpdated(_ run: RunState, _ status: String, created: Bool = false, attempt: Int? = nil) {
        let ordinal = attempt ?? run.attempt
        emit(created ? "run-attempt.created" : "run-attempt.updated", [
            "id": "run-attempt:\(run.id):\(ordinal)", "runId": run.id, "attemptOrdinal": ordinal,
            "rootNodeId": "node:\(run.id):root:\(ordinal)", "providerTurnId": "provider-turn:\(run.ordinal):\(ordinal)",
            "status": status, "reason": ordinal == 1 ? "initial" : "retry", "startedAt": now,
            "completedAt": ["completed", "failed", "interrupted", "superseded", "cancelled"].contains(status) ? now : NSNull(),
        ], runId: run.id)
    }

    private mutating func node(_ id: String, run: RunState?, parent: String?, root: String, kind: String, status: String) {
        emit("node.updated", [
            "id": id, "threadId": threadId, "runId": run?.id ?? NSNull(), "parentNodeId": parent ?? NSNull(),
            "rootNodeId": root, "kind": kind, "status": status, "startedAt": now,
            "completedAt": ["completed", "failed", "interrupted", "cancelled"].contains(status) ? now : NSNull(),
        ], runId: run?.id)
    }

    /// A turn item object with T3's base fields (orchestrationV2.ts:1316-1335).
    private func item(
        _ type: String, id: String, run: RunState?, node: String?, ordinal: Int, status: String, startedAt: String,
        completed: Bool, _ extra: [String: Any]
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "id": id, "threadId": threadId, "type": type, "runId": run?.id ?? NSNull(), "nodeId": node ?? NSNull(),
            "providerThreadId": NSNull(), "providerTurnId": run?.providerTurn ?? "provider-turn:runless",
            "nativeItemRef": NSNull(), "parentItemId": NSNull(), "ordinal": ordinal, "status": status, "title": NSNull(),
            "startedAt": startedAt, "completedAt": completed ? now : NSNull(), "updatedAt": now,
        ]
        for (k, v) in extra { fields[k] = v }
        return fields
    }

    private mutating func nextOrdinal(_ run: RunState?) -> Int {
        guard let run else { itemCounter += 1; return 1_000_000 + itemCounter }
        defer { run.nextItem += 1 }
        return run.ordinal * 1_000_000 + run.nextItem
    }

    // MARK: Text

    private static let words = ["the", "agent", "reads", "files", "and", "runs", "a", "command", "to", "check", "what", "changed",
                                "before", "writing", "an", "answer", "with", "`code`", "**bold**", "list:", "\n- item", "\n\n"]

    private mutating func sentence(_ count: Int) -> String {
        (0..<count).map { _ in rng.pick(Self.words) }.joined(separator: " ")
    }

    /// Growing cuts of a text, the way providers stream it.
    private mutating func cuts(_ text: String) -> [String] {
        let n = rng.int(1...5)
        var out: [String] = []
        for i in 1...n { out.append(String(text.prefix(text.count * i / (n + 1)))) }
        return out.filter { !$0.isEmpty }
    }

    // MARK: Steps

    /// A prompt: its message, then its turn item. A queued prompt gets its turn item only when its
    /// run starts (ChatView.tsx:1755-1757), so `item` is false for it.
    private mutating func userMessage(_ run: RunState, intent: String, text: String, messageId: String, item withItem: Bool = true) {
        let at = tick()
        sends[events.count] = (messageId, text, intent == "turn_start" ? nil : intent)
        emit("message.updated", [
            "id": messageId, "threadId": threadId, "runId": run.id, "nodeId": run.rootNode, "role": "user", "text": text,
            "streaming": false, "createdAt": at, "updatedAt": at, "attachments": [], "createdBy": "user", "creationSource": "web",
        ], runId: run.id)
        run.prompt = (text, at)
        if withItem { userItem(run, intent: intent, messageId: messageId) }
    }

    private mutating func userItem(_ run: RunState, intent: String, messageId: String) {
        let (text, at) = run.prompt
        emit("turn-item.updated", item("user_message", id: "turn-item:message:\(messageId)", run: run, node: run.rootNode,
                                       ordinal: nextOrdinal(run), status: "completed", startedAt: at, completed: true, [
                                           "messageId": messageId, "inputIntent": intent, "text": text, "attachments": [],
                                           "createdBy": "user", "creationSource": "web",
                                       ]), runId: run.id)
    }

    /// The prompt and the run it starts, queued or not.
    private mutating func prelude(_ run: RunState) {
        run.requestedAt = tick()
        let compact = rng.chance(0.06)
        if compact { features.insert("compact-command") }
        userMessage(run, intent: run.queued ? "queued_turn" : "turn_start",
                    text: compact ? "/compact" : "Prompt \(run.ordinal): " + sentence(rng.int(2...8)), messageId: run.userMessageId,
                    item: !run.queued)
        runUpdated(run, run.queued ? "queued" : "preparing", created: true)
        attemptUpdated(run, "pending", created: true)
        node(run.rootNode, run: run, parent: nil, root: run.rootNode, kind: "root_turn", status: "pending")
        if run.queued { features.insert("queued-run") }
    }

    private mutating func start(_ run: RunState) {
        if run.status == "queued" { runUpdated(run, "preparing") }
        if run.queued { userItem(run, intent: "queued_turn", messageId: run.userMessageId) }
        runUpdated(run, "running")
        attemptUpdated(run, "running")
        node(run.rootNode, run: run, parent: nil, root: run.rootNode, kind: "root_turn", status: "running")
    }

    private mutating func streamText(_ run: RunState?, type: String, finish: Bool = true) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        let text = sentence(rng.int(4...40))
        let isAnswer = type == "assistant_message"
        let base = isAnswer ? "a-\(run?.ordinal ?? 0)-\(ordinal)" : "r-\(run?.ordinal ?? 0)-\(ordinal)"
        let messageId = "message:\(base)"
        let itemId = "turn-item:\(base)"
        let node = run?.rootNode ?? "node:runless:root"
        func send(_ g: inout StressThreadGenerator, _ text: String, streaming: Bool) {
            let status = streaming ? "running" : "completed"
            if isAnswer {
                g.emit("message.updated", [
                    "id": messageId, "threadId": g.threadId, "runId": run?.id ?? NSNull(), "nodeId": node, "role": "assistant",
                    "text": text, "streaming": streaming, "createdAt": started, "updatedAt": g.now,
                ], runId: run?.id)
                g.emit("turn-item.updated", g.item("assistant_message", id: itemId, run: run, node: node, ordinal: ordinal, status: status,
                                                   startedAt: started, completed: !streaming,
                                                   ["messageId": messageId, "text": text, "streaming": streaming]), runId: run?.id)
            } else {
                g.emit("turn-item.updated", g.item("reasoning", id: itemId, run: run, node: node, ordinal: ordinal, status: status,
                                                   startedAt: started, completed: !streaming, ["text": text, "streaming": streaming]), runId: run?.id)
            }
        }
        for cut in cuts(text) { send(&self, cut, streaming: true) }
        if finish {
            send(&self, text, streaming: false)
        } else {
            features.insert("unfinished-\(type)")
        }
        features.insert(type)
    }

    private mutating func tool(_ run: RunState?) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        let id = "ti-tool-\(run?.ordinal ?? 0)-\(ordinal)"
        let child = "node:\(id)"
        let root = run?.rootNode ?? "node:runless:root"
        node(child, run: run, parent: root, root: root, kind: "tool", status: "running")
        let kind = rng.int(0...4)
        let fails = rng.chance(0.2)
        var type = "command_execution"
        var extra: [String: Any]
        switch kind {
        case 0:
            extra = ["input": rng.pick(["ls -la", "git status", "cat README.md", "swift build", "rg TODO"])]
        case 1:
            type = "file_change"
            extra = ["fileName": rng.pick(["Sources/A.swift", "README.md", "docs/b.md"]), "additions": rng.int(0...30), "deletions": rng.int(0...9)]
        case 2:
            type = "dynamic_tool"
            extra = ["toolName": rng.pick(["Read", "Grep", "mcp__browser__open"]), "input": ["file_path": "/repo/Sources/A.swift"]]
        case 3:
            type = "web_search"
            extra = ["patterns": ["swift actors"]]
        default:
            type = "file_search"
            extra = ["pattern": "*.swift"]
        }
        features.insert(type)
        emit("turn-item.updated", item(type, id: id, run: run, node: child, ordinal: ordinal, status: "running", startedAt: started,
                                       completed: false, extra), runId: run?.id)
        if type == "command_execution" {
            var output = ""
            for _ in 0..<rng.int(0...3) {
                output += sentence(rng.int(2...10)) + "\n"
                var growing = extra
                growing["output"] = output
                emit("turn-item.updated", item(type, id: id, run: run, node: child, ordinal: ordinal, status: "running", startedAt: started,
                                               completed: false, growing), runId: run?.id)
                features.insert("tool-output-growing")
            }
            extra["output"] = output
            extra["exitCode"] = fails ? 1 : 0
        }
        if fails {
            features.insert("tool-failed")
            if type != "command_execution" { extra["output"] = "error" }
        }
        let status = fails ? "failed" : "completed"
        emit("turn-item.updated", item(type, id: id, run: run, node: child, ordinal: ordinal, status: status, startedAt: started,
                                       completed: true, extra), runId: run?.id)
        node(child, run: run, parent: root, root: root, kind: "tool", status: status)
    }

    /// An approval or a question: the run waits until the user answers.
    private mutating func request(_ run: RunState, question: Bool) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        let requestId = "request-\(run.ordinal)-\(ordinal)"
        let id = "ti-request-\(run.ordinal)-\(ordinal)"
        var request: [String: Any] = [
            "id": requestId, "nodeId": run.rootNode, "providerTurnId": NSNull(), "nativeRequestRef": NSNull(),
            "kind": question ? "user_input" : "command", "status": "pending",
            "responseCapability": ["type": "live", "providerSessionId": "session"], "createdAt": started, "resolvedAt": NSNull(),
        ]
        let questions: [[String: Any]] = [[
            "id": "q1", "header": "Pick", "question": "Which one?",
            "options": [["label": "A", "description": "first"], ["label": "B", "description": "second"]],
        ]]
        var extra: [String: Any] = question
            ? ["requestId": requestId, "questions": questions]
            : ["requestId": requestId, "requestKind": "command", "prompt": "Run rm -rf build?"]
        emit("runtime-request.updated", request, runId: run.id)
        emit("turn-item.updated", item(question ? "user_input_request" : "approval_request", id: id, run: run, node: run.rootNode,
                                       ordinal: ordinal, status: "waiting", startedAt: started, completed: false, extra), runId: run.id)
        runUpdated(run, "waiting")
        features.insert(question ? "question" : "approval")
        // Answered, declined or left open until the run ends.
        if rng.chance(0.85) {
            request["status"] = "resolved"
            request["resolvedAt"] = tick(4_000)
            if question {
                request["answers"] = ["q1": rng.pick(["A", "B"])]
                // Older servers saved the answer on the request only; newer ones also on the item.
                if rng.chance(0.5) {
                    extra["questionAnswer"] = ["requestId": requestId, "answers": request["answers"]!, "attachmentsByQuestionId": [:] as [String: Any]]
                }
                features.insert("question-answered")
            } else {
                request["decision"] = rng.pick(["accept", "decline"])
            }
            emit("runtime-request.updated", request, runId: run.id)
            emit("turn-item.updated", item(question ? "user_input_request" : "approval_request", id: id, run: run, node: run.rootNode,
                                           ordinal: ordinal, status: "completed", startedAt: started, completed: true, extra), runId: run.id)
            runUpdated(run, "running")
        } else {
            // The server cancels it when the run ends.
            run.openRequests.append((request, question ? "user_input_request" : "approval_request", id, ordinal, started, extra))
            runUpdated(run, "running")
        }
    }

    private mutating func closeRequests(_ run: RunState) {
        for (request, type, id, ordinal, started, extra) in run.openRequests {
            var request = request
            request["status"] = "cancelled"
            request["resolvedAt"] = tick()
            emit("runtime-request.updated", request, runId: run.id)
            emit("turn-item.updated", item(type, id: id, run: run, node: run.rootNode, ordinal: ordinal, status: "cancelled",
                                           startedAt: started, completed: true, extra), runId: run.id)
            features.insert("request-cancelled")
        }
        run.openRequests = []
    }

    /// The provider fails and retries inside the attempt (`retry` on an `error` item).
    private mutating func providerRetry(_ run: RunState) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        let id = "ti-retry-\(run.ordinal)-\(ordinal)"
        let max = rng.int(2...4)
        let failure: [String: Any] = ["class": "provider_error", "message": "Overloaded", "code": "overloaded", "retryable": true]
        for attempt in 1...rng.int(1...max) {
            emit("turn-item.updated", item("error", id: id, run: run, node: run.rootNode, ordinal: ordinal, status: "running",
                                           startedAt: started, completed: false,
                                           ["failure": failure, "retry": ["attempt": attempt, "maxAttempts": max, "retryDelayMs": 2_000]]),
                 runId: run.id)
        }
        let recovered = rng.chance(0.7)
        emit("turn-item.updated", item("error", id: id, run: run, node: run.rootNode, ordinal: ordinal, status: recovered ? "completed" : "failed",
                                       startedAt: started, completed: true,
                                       ["failure": failure, "retry": ["attempt": max, "maxAttempts": max, "retryDelayMs": NSNull()]]),
             runId: run.id)
        features.insert(recovered ? "provider-retry-recovered" : "provider-retry-failed")
    }

    /// The whole attempt is retried: the old one is superseded and a new root node takes over.
    private mutating func supersede(_ run: RunState) {
        attemptUpdated(run, "superseded")
        node(run.rootNode, run: run, parent: nil, root: run.rootNode, kind: "root_turn", status: "cancelled")
        run.attempt += 1
        run.providerTurn = "provider-turn:\(run.ordinal):\(run.attempt)"
        attemptUpdated(run, "running", created: true)
        node(run.rootNode, run: run, parent: nil, root: run.rootNode, kind: "root_turn", status: "running")
        runUpdated(run, "running")
        features.insert("superseded-attempt")
    }

    private mutating func compaction(_ run: RunState?) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        let id = "ti-compaction-\(run?.ordinal ?? 0)-\(ordinal)"
        let node = run?.rootNode ?? "node:runless:root"
        emit("turn-item.updated", item("compaction", id: id, run: run, node: node, ordinal: ordinal, status: "running",
                                       startedAt: started, completed: false, ["driver": "claudeAgent"]), runId: run?.id)
        emit("turn-item.updated", item("compaction", id: id, run: run, node: node, ordinal: ordinal, status: "completed",
                                       startedAt: started, completed: true,
                                       ["driver": "claudeAgent", "beforeTokenCount": 120_000, "afterTokenCount": 9_000, "summary": "Summary"]),
             runId: run?.id)
        features.insert("compaction")
    }

    /// One to three subagents started together, reporting progress, then finishing.
    private mutating func subagents(_ run: RunState) {
        let count = rng.int(1...3)
        var ids: [(id: String, ordinal: Int, started: String)] = []
        for k in 0..<count {
            let ordinal = nextOrdinal(run)
            ids.append(("ti-subagent-\(run.ordinal)-\(ordinal)-\(k)", ordinal, tick()))
        }
        func subagent(_ g: inout StressThreadGenerator, _ s: (id: String, ordinal: Int, started: String), status: String, progress: String?) {
            var extra: [String: Any] = [
                "subagentId": "node:\(s.id)", "origin": "provider_native", "driver": "claudeAgent", "providerInstanceId": "claudeAgent",
                "childThreadId": "thread-child-\(s.id)", "prompt": "Look into it", "result": status == "completed" ? "Done" : NSNull(),
            ]
            if let progress { extra["progress"] = progress }
            g.emit("turn-item.updated", g.item("subagent", id: s.id, run: run, node: run.rootNode, ordinal: s.ordinal, status: status,
                                               startedAt: s.started, completed: status != "running", extra), runId: run.id)
            g.emit("subagent.updated", ["id": "node:\(s.id)", "status": status, "childThreadId": "thread-child-\(s.id)"], runId: run.id)
        }
        for s in ids { subagent(&self, s, status: "running", progress: nil) }
        for _ in 0..<rng.int(0...3) { subagent(&self, rng.pick(ids), status: "running", progress: sentence(3)) }
        for s in ids where rng.chance(0.9) { subagent(&self, s, status: rng.chance(0.85) ? "completed" : "failed", progress: nil) }
        features.insert(count > 1 ? "subagents-grouped" : "subagent")
    }

    private mutating func notice(_ run: RunState) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        if rng.chance(0.5) {
            emit("turn-item.updated", item("system_notice", id: "ti-notice-\(run.ordinal)-\(ordinal)", run: run, node: run.rootNode,
                                           ordinal: ordinal, status: "completed", startedAt: started, completed: true,
                                           ["message": "Model switched"]), runId: run.id)
            features.insert("system-notice")
        } else {
            emit("turn-item.updated", item("todo_list", id: "ti-todo-\(run.ordinal)-\(ordinal)", run: run, node: run.rootNode,
                                           ordinal: ordinal, status: "running", startedAt: started, completed: false,
                                           ["planId": "plan-todo-\(run.ordinal)", "steps": [["step": "one", "status": "in_progress"]]]),
                 runId: run.id)
            features.insert("todo-list")
        }
    }

    private mutating func plan(_ run: RunState) {
        let ordinal = nextOrdinal(run)
        let started = tick()
        let planId = "plan-\(run.ordinal)-\(ordinal)"
        let markdown = "# Plan\n\n- " + sentence(6)
        emit("plan.updated", ["id": planId, "threadId": threadId, "runId": run.id, "kind": "proposed_plan", "status": "active",
                              "markdown": markdown], runId: run.id)
        emit("turn-item.updated", item("proposed_plan", id: "ti-plan-\(run.ordinal)-\(ordinal)", run: run, node: run.rootNode,
                                       ordinal: ordinal, status: "completed", startedAt: started, completed: true,
                                       ["planId": planId, "markdown": markdown, "streaming": false]), runId: run.id)
        features.insert("proposed-plan")
    }

    private mutating func steer(_ run: RunState) {
        let messageId = "msg-steer-\(run.ordinal)-\(run.nextItem)"
        userMessage(run, intent: "steer", text: "Also " + sentence(3), messageId: messageId)
        features.insert("steer")
    }

    private mutating func checkpoint(_ run: RunState) {
        let ordinal = nextOrdinal(run)
        let checkpointId = "checkpoint-\(run.ordinal)"
        let files: [[String: Any]] = [["path": "Sources/A.swift", "kind": "modified", "additions": 3, "deletions": 1]]
        emit("checkpoint.captured", [
            "id": checkpointId, "threadId": threadId, "scopeId": "scope-root", "runId": run.id, "appRunOrdinal": run.ordinal,
            "ordinalWithinScope": run.ordinal, "ref": "refs/t3/\(run.ordinal)", "status": "ready", "files": files, "capturedAt": now,
        ], runId: run.id)
        emit("turn-item.updated", item("checkpoint", id: "ti-checkpoint-\(run.ordinal)", run: run, node: run.rootNode, ordinal: ordinal,
                                       status: "completed", startedAt: now, completed: true,
                                       ["checkpointId": checkpointId, "scopeId": "scope-root", "files": files]), runId: run.id)
    }

    // MARK: Endings

    private mutating func finish(_ run: RunState) {
        closeRequests(run)
        let roll = rng.int(0...99)
        if roll < 12 {
            // Stopped by the user: request, status, result (T3's interrupt pair).
            let ordinal = nextOrdinal(run)
            emit("turn-item.updated", item("run_interrupt_request", id: "ti-interrupt-req-\(run.ordinal)", run: run, node: run.rootNode,
                                           ordinal: ordinal, status: "completed", startedAt: tick(), completed: true,
                                           ["message": "Interrupt requested"]), runId: run.id)
            attemptUpdated(run, "interrupted")
            runUpdated(run, "interrupted")
            emit("turn-item.updated", item("run_interrupt_result", id: "ti-interrupt-res-\(run.ordinal)", run: run, node: run.rootNode,
                                           ordinal: nextOrdinal(run), status: "completed", startedAt: now, completed: true,
                                           ["message": "Interrupted"]), runId: run.id)
            features.insert("interrupted")
        } else if roll < 22 {
            emit("turn-item.updated", item("error", id: "ti-error-\(run.ordinal)", run: run, node: run.rootNode, ordinal: nextOrdinal(run),
                                           status: "failed", startedAt: tick(), completed: true,
                                           ["failure": ["class": "provider_error", "message": "Provider crashed", "code": NSNull(), "retryable": false]]),
                 runId: run.id)
            attemptUpdated(run, "failed")
            runUpdated(run, "failed")
            features.insert("failed")
        } else {
            streamText(run, type: "assistant_message")
            if rng.chance(0.4) { checkpoint(run) }
            attemptUpdated(run, "completed")
            node(run.rootNode, run: run, parent: nil, root: run.rootNode, kind: "root_turn", status: "completed")
            runUpdated(run, "completed")
            features.insert("completed")
            // The user rewinds: the run's rows leave the timeline (orchestrationV2Timeline.ts:42-112).
            if rng.chance(0.06) {
                emit("checkpoint.rollback-requested", ["runId": run.id], runId: run.id)
                runUpdated(run, "rolled_back")
                features.insert("rolled-back")
            }
        }
        // A newer server's event and item types: decoded as unknown, they still move the cursor.
        if rng.chance(0.05) {
            emit("future.event-type", ["anything": true], runId: run.id)
            emit("turn-item.updated", item("future_item", id: "ti-future-\(run.ordinal)", run: run, node: run.rootNode,
                                           ordinal: nextOrdinal(run), status: "completed", startedAt: now, completed: true, [:]),
                 runId: run.id)
            features.insert("unknown-events")
        }
    }

    /// A forked thread starts with the parent's rows, inherited (`visibility: "inherited"`), which
    /// come only in snapshots and history pages.
    mutating func inheritedRows() -> [[String: Any]] {
        guard mode == .forked else { return [] }
        var rows: [[String: Any]] = []
        let parent = "thread-parent"
        for k in 0..<rng.int(2...10) {
            let at = tick()
            let isUser = k % 3 == 0
            var fields: [String: Any] = [
                "id": "ti-parent-\(k)", "threadId": parent, "type": isUser ? "user_message" : "assistant_message",
                "runId": "run:parent:\(k / 3 + 1)", "nodeId": NSNull(), "providerThreadId": NSNull(), "providerTurnId": NSNull(),
                "nativeItemRef": NSNull(), "parentItemId": NSNull(), "ordinal": (k / 3 + 1) * 1_000_000 + k % 3 + 1,
                "status": "completed", "title": NSNull(), "startedAt": at, "completedAt": at, "updatedAt": at,
                "messageId": "message:parent:\(k)", "text": "Parent " + sentence(4), "streaming": false,
            ]
            if isUser {
                fields["inputIntent"] = "turn_start"
                fields["attachments"] = [Any]()
                fields["createdBy"] = "user"
            }
            rows.append(["position": k, "visibility": "inherited", "sourceThreadId": parent, "sourceItemId": "ti-parent-\(k)", "item": fields])
        }
        features.insert("inherited-rows")
        return rows
    }

    // MARK: Script

    mutating func generate() -> StressThreadScript {
        let created = Self.iso(clockMs)
        let thread = threadObject(createdAt: created)
        inherited = inheritedRows()
        if mode == .providerSubagent { return generateProviderSubagent(thread: thread) }
        var runs: [RunState] = []
        for ordinal in 1...runCount { runs.append(RunState(ordinal: ordinal, queued: ordinal > 1 && rng.chance(0.3))) }
        var preluded = Set<Int>()
        // A run's completion that waits until the next run already started.
        var deferred: RunState?
        for (index, run) in runs.enumerated() {
            if !preluded.contains(index) { prelude(run) }
            // A queued run may be cancelled before it starts.
            if run.queued, rng.chance(0.1) {
                runUpdated(run, "cancelled")
                attemptUpdated(run, "cancelled")
                features.insert("queued-cancelled")
                if let d = deferred { emitCompletion(d); deferred = nil }
                continue
            }
            start(run)
            if let d = deferred { emitCompletion(d); deferred = nil }
            let next = index + 1 < runs.count ? runs[index + 1] : nil
            let steps = rng.int(0...maxSteps)
            let queueAt = next?.queued == true ? rng.int(0...steps) : -1
            for step in 0..<steps {
                if step == queueAt, let next { prelude(next); preluded.insert(index + 1) }
                switch rng.int(0...99) {
                case 0..<18: streamText(run, type: "reasoning", finish: rng.chance(0.85))
                case 18..<30: streamText(run, type: "assistant_message")
                case 30..<55: tool(run)
                case 55..<61: request(run, question: false)
                case 61..<66: request(run, question: true)
                case 66..<71: providerRetry(run)
                case 71..<75: supersede(run)
                case 75..<79: compaction(run)
                case 79..<85: subagents(run)
                case 85..<89: notice(run)
                case 89..<92: plan(run)
                default: steer(run)
                }
            }
            if queueAt == steps, let next { prelude(next); preluded.insert(index + 1) }
            if next != nil, next?.queued == false || preluded.contains(index + 1), rng.chance(0.15) {
                // The next run starts before this one records its end.
                features.insert("overlapping-runs")
                emitEnding(run, completion: false)
                deferred = run
            } else {
                finish(run)
            }
        }
        if let d = deferred { emitCompletion(d) }
        return StressThreadScript(threadId: threadId, thread: thread, events: events, sends: sends, features: features, inherited: inherited)
    }

    /// The answer of a run whose completion comes later.
    private mutating func emitEnding(_ run: RunState, completion: Bool) {
        closeRequests(run)
        streamText(run, type: "assistant_message")
        if completion { emitCompletion(run) }
    }

    private mutating func emitCompletion(_ run: RunState) {
        attemptUpdated(run, "completed")
        runUpdated(run, "completed")
    }

    /// A provider-native subagent thread: no runs, a runless root turn that follows the child.
    private mutating func generateProviderSubagent(thread: [String: Any]) -> StressThreadScript {
        node("node:runless:root", run: nil, parent: nil, root: "node:runless:root", kind: "root_turn", status: "running")
        let steps = rng.int(2...maxSteps * runCount)
        for _ in 0..<steps {
            switch rng.int(0...9) {
            case 0...2: streamText(nil, type: "reasoning", finish: rng.chance(0.8))
            case 3...4: streamText(nil, type: "assistant_message")
            case 5: compaction(nil)
            default: tool(nil)
            }
        }
        node("node:runless:root", run: nil, parent: nil, root: "node:runless:root", kind: "root_turn",
             status: rng.chance(0.8) ? "completed" : "running")
        features.insert("provider-subagent-thread")
        return StressThreadScript(threadId: threadId, thread: thread, events: events, sends: sends, features: features, inherited: inherited)
    }
}
