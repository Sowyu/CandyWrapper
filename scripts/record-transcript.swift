// Records a real T3 server session (HTTP pairing + WebSocket RPC) as JSONL.
//
// Usage: swift record.swift <baseURL> <tokenFile> <outFile> <scenario> [pairingToken]
//   tokenFile   bearer token cache for this (sandbox) server; created on first pairing.
//   scenario    basic | turn | turn2 | threads | composer | requests | queue
// Secrets (access token, ws ticket, pairing token) and the account email are
// redacted when the transcript is written.
import Foundation

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: record.swift <baseURL> <tokenFile> <outFile> <scenario> [pairingToken]\n".data(using: .utf8)!)
    exit(2)
}
let baseURL = URL(string: args[1])!
let tokenFile = args[2]
let outPath = args[3]
let scenario = args[4]
let pairingToken = args.count >= 6 ? args[5] : nil

let start = Date()
final class Log: @unchecked Sendable {
    var lines: [String] = []
    var secrets: [String] = []
    let lock = NSLock()
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func secret(_ s: String) { lock.lock(); secrets.append(s); lock.unlock() }
}
let log = Log()
if let pairingToken { log.secret(pairingToken) }

func record(_ dir: String, _ kind: String, _ body: Any) {
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let line: [String: Any] = ["t": ms, "dir": dir, "kind": kind, "body": body]
    let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
    log.add(String(data: data, encoding: .utf8)!)
}

func flush() {
    var text = log.lines.joined(separator: "\n") + "\n"
    for (i, secret) in log.secrets.enumerated() where !secret.isEmpty {
        text = text.replacingOccurrences(of: secret, with: "<secret-\(i)>")
    }
    // Scrub e-mail addresses (provider account info appears in server config).
    let emailRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    text = emailRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "user@example.com")
    // Paths as in the older fixtures: the sandbox folder becomes /Users/user/sandbox.
    let home = NSHomeDirectory()
    text = text.replacingOccurrences(of: home + "/CandyWrapper-research/sandbox", with: "/Users/user/sandbox")
    text = text.replacingOccurrences(of: home, with: "/Users/user")
    try! text.write(toFile: outPath, atomically: true, encoding: .utf8)
}

func jsonObject(_ data: Data) -> Any {
    (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? String(data: data, encoding: .utf8) ?? "<binary>"
}

func http(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil, contentType: String? = nil) async throws -> (Int, Any) {
    var req = URLRequest(url: baseURL.appendingPathComponent(path))
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    req.httpBody = body
    record("send", "http", ["method": method, "path": path, "headers": headers, "body": body.map { String(data: $0, encoding: .utf8) ?? "" } ?? NSNull()])
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as! HTTPURLResponse).statusCode
    record("recv", "http", ["status": status, "path": path, "body": jsonObject(data)])
    return (status, jsonObject(data))
}

func form(_ fields: [(String, String)]) -> Data {
    var comps = URLComponents()
    comps.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
    return comps.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)!
}

// Descriptor (public)
_ = try await http("GET", ".well-known/t3/environment")

// Bearer token: reuse cache or pair.
var accessToken = (try? String(contentsOfFile: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
if accessToken.isEmpty {
    guard let pairingToken else { print("no cached token and no pairing token"); exit(1) }
    let (status, body) = try await http("POST", "oauth/token", body: form([
        ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
        ("subject_token", pairingToken),
        ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
        ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
        ("client_label", "CandyWrapper protocol recorder"),
        ("client_device_type", "desktop"),
        ("client_os", "macOS"),
    ]), contentType: "application/x-www-form-urlencoded")
    guard status == 200, let tok = body as? [String: Any], let t = tok["access_token"] as? String else {
        flush(); print("token exchange failed: \(status)"); exit(1)
    }
    accessToken = t
    FileManager.default.createFile(atPath: tokenFile, contents: t.data(using: .utf8), attributes: [.posixPermissions: 0o600])
}
log.secret(accessToken)
let auth = ["Authorization": "Bearer \(accessToken)", "x-t3-orchestration-protocol": "2"]
_ = try await http("GET", "api/auth/session", headers: auth)
let (_, ticketBody) = try await http("POST", "api/auth/websocket-ticket", headers: auth)
let ticket = (ticketBody as! [String: Any])["ticket"] as! String
log.secret(ticket)

var comps = URLComponents(url: baseURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
comps.queryItems = [
    URLQueryItem(name: "orchestrationProtocol", value: "2"),
    URLQueryItem(name: "wsTicket", value: ticket),
    URLQueryItem(name: "clientSurface", value: "desktop"),
    URLQueryItem(name: "clientAppVersion", value: "0.0.0-recorder"),
    URLQueryItem(name: "clientOs", value: "macOS"),
    URLQueryItem(name: "clientDeviceType", value: "desktop"),
    URLQueryItem(name: "connectionMethod", value: "direct"),
]
record("send", "ws-open", ["url": comps.url!.absoluteString])
let ws = URLSession.shared.webSocketTask(with: comps.url!)
ws.maximumMessageSize = 64 * 1024 * 1024
ws.resume()

actor State {
    var nextId = 1
    var events: [[String: Any]] = []        // every thread-stream item, in order
    var exits: [String: [String: Any]] = [:] // requestId -> Exit message
    func id() -> String { defer { nextId += 1 }; return String(nextId) }
    func addItem(_ item: [String: Any]) { events.append(item) }
    func addExit(_ rid: String, _ m: [String: Any]) { exits[rid] = m }
    func snapshot() -> [[String: Any]] { events }
    func exit(_ rid: String) -> [String: Any]? { exits[rid] }
}
let state = State()

func send(_ obj: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    record("send", "ws", obj)
    try await ws.send(.string(String(data: data, encoding: .utf8)!))
}

@discardableResult
func request(_ tag: String, _ payload: [String: Any] = [:]) async throws -> String {
    let id = await state.id()
    try await send(["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]])
    return id
}

let receiver = Task {
    while true {
        let msg = try await ws.receive()
        let text: String
        switch msg {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? "<binary \(d.count) bytes>"
        @unknown default: text = "<unknown>"
        }
        let obj = jsonObject(text.data(using: .utf8)!)
        record("recv", "ws", obj)
        let messages: [[String: Any]] = (obj as? [[String: Any]]) ?? ((obj as? [String: Any]).map { [$0] } ?? [])
        for m in messages {
            switch m["_tag"] as? String {
            case "Chunk":
                for v in (m["values"] as? [[String: Any]]) ?? [] { await state.addItem(v) }
                if let rid = m["requestId"] { try await send(["_tag": "Ack", "requestId": rid]) }
            case "Exit":
                if let rid = m["requestId"] as? String { await state.addExit(rid, m) }
            default: break
            }
        }
    }
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func uuid() -> String { UUID().uuidString.lowercased() }

/// Waits until `predicate` matches a thread-stream event, returning it.
func mark() async -> Int { await state.snapshot().count }

func waitFor(_ label: String, after: Int = 0, timeout: Double, _ predicate: @escaping ([String: Any]) -> Bool) async -> [String: Any]? {
    let deadline = Date().addingTimeInterval(timeout)
    var seen = after
    while Date() < deadline {
        let items = await state.snapshot()
        while seen < items.count {
            let item = items[seen]; seen += 1
            if let event = item["event"] as? [String: Any], predicate(event) { return event }
        }
        await pause(0.2)
    }
    print("timeout waiting for \(label)")
    return nil
}

func payload(_ e: [String: Any]) -> [String: Any] { (e["payload"] as? [String: Any]) ?? [:] }

switch scenario {
case "basic":
    try await request("server.getConfig")
    try await request("subscribeServerConfig")
    try await request("subscribeServerLifecycle")
    try await request("orchestration.subscribeShell", ["requestCompletionMarker": true])
    try await request("server.getSettings")
    try await request("projects.list") // listed in WS_METHODS but not served: expect Die
    await pause(4)
    try await send(["_tag": "Ping"])
    await pause(1)

case "turn":
    let repo = ProcessInfo.processInfo.environment["DEMO_REPO"]!
    try await request("orchestration.subscribeShell", ["requestCompletionMarker": true])
    await pause(0.5)
    let projectId = uuid()
    try await request("projects.mutate", ["type": "project.create", "commandId": uuid(), "projectId": projectId,
                                         "title": "demo-repo", "workspaceRoot": repo])
    await pause(1)
    let threadId = uuid()
    try await request("orchestration.dispatchCommand", [
        "type": "thread.create", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "projectId": projectId, "title": "New thread",
        "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"],
        "runtimeMode": "approval-required", "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(),
    ])
    await pause(0.5)
    try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                        "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
    await pause(0.5)

    // Turn 1: needs a command approval, then completes.
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(),
        "text": "Use your shell tool to run `ls -1 | wc -l` in the current directory, then reply with just the number.",
        "attachments": [] as [Any], "titleSeed": "Count files", "dispatchMode": ["type": "start_immediately"],
    ])
    if let req = await waitFor("approval request", timeout: 120, { e in
        (e["type"] as? String) == "runtime-request.updated" && (payload(e)["status"] as? String) == "pending"
    }) {
        await pause(1)
        try await request("orchestration.dispatchCommand", [
            "type": "runtime-request.respond", "commandId": uuid(), "threadId": threadId,
            "requestId": payload(req)["id"]!, "decision": "accept",
        ])
    }
    _ = await waitFor("turn 1 completion", timeout: 180, { e in
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted"].contains(payload(e)["status"] as? String ?? "")
    })
    await pause(3)

    // Turn 2: long streaming answer, interrupted mid-stream.
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(),
        "text": "Without using any tools, write the numbers from 1 to 300 as English words, one per line.",
        "attachments": [] as [Any], "dispatchMode": ["type": "start_immediately"],
    ])
    if let running = await waitFor("turn 2 streaming", timeout: 120, { e in
        (e["type"] as? String) == "message.updated" && (payload(e)["role"] as? String) == "assistant"
    }) {
        _ = running
        // Queue a follow-up while the run is active, then cancel it.
        try await request("orchestration.dispatchCommand", [
            "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
            "threadId": threadId, "messageId": uuid(), "text": "Then say done.",
            "attachments": [] as [Any], "dispatchMode": ["type": "queue_after_active"],
        ])
        if let queued = await waitFor("queued run", timeout: 30, { e in
            (e["type"] as? String) == "run.created" && (payload(e)["status"] as? String) == "queued"
        }) {
            await pause(1)
            try await request("orchestration.dispatchCommand", [
                "type": "queued-run.cancel", "commandId": uuid(), "threadId": threadId, "runId": payload(queued)["id"]!,
            ])
        }
        await pause(1.5)
        let items = await state.snapshot()
        let activeRun = items.compactMap { $0["event"] as? [String: Any] }
            .last { ($0["type"] as? String)?.hasPrefix("run.") == true && ["running", "starting", "waiting"].contains(payload($0)["status"] as? String ?? "") }
        if let activeRun {
            try await request("orchestration.dispatchCommand", [
                "type": "run.interrupt", "commandId": uuid(), "threadId": threadId,
                "runId": payload(activeRun)["id"]!, "holdQueue": true,
            ])
        }
    }
    _ = await waitFor("turn 2 end", timeout: 60, { e in
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted"].contains(payload(e)["status"] as? String ?? "")
    })
    await pause(4)
    // History over HTTP for the same thread (bounded snapshot + page).
    _ = try await http("GET", "api/orchestration/threads/\(threadId)/bounded", headers: auth)
    _ = try await http("GET", "api/orchestration/shell", headers: auth)
    print("threadId \(threadId) projectId \(projectId)")

case "turn2":
    let repo = ProcessInfo.processInfo.environment["DEMO_REPO"]!
    let projectId = ProcessInfo.processInfo.environment["PROJECT_ID"]!
    try await request("orchestration.subscribeShell", ["requestCompletionMarker": true])
    await pause(0.5)
    _ = repo
    let threadId = uuid()
    try await request("orchestration.dispatchCommand", [
        "type": "thread.create", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "projectId": projectId, "title": "New thread",
        "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"],
        "runtimeMode": "approval-required", "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(),
    ])
    await pause(0.5)
    try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                        "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
    await pause(0.5)

    // Turn 1: file write that needs approval.
    var m = await mark()
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(),
        "text": "Create a file named notes.md containing a three-item markdown checklist about testing, then add a one-line docstring to the greet function in hello.py. Reply with a short summary.",
        "attachments": [] as [Any], "titleSeed": "Add notes and docstring", "dispatchMode": ["type": "start_immediately"],
    ])
    for _ in 0..<4 {
        guard let req = await waitFor("approval request", after: m, timeout: 90, { e in
            ((e["type"] as? String) == "runtime-request.updated" && (payload(e)["status"] as? String) == "pending")
            || ((e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted"].contains(payload(e)["status"] as? String ?? ""))
        }) else { break }
        if (req["type"] as? String) == "run.updated" { break }
        m = await mark()
        await pause(1.5)
        try await request("orchestration.dispatchCommand", [
            "type": "runtime-request.respond", "commandId": uuid(), "threadId": threadId,
            "requestId": payload(req)["id"]!, "decision": "accept",
        ])
    }
    _ = await waitFor("turn 1 completion", after: 0, timeout: 120, { e in
        (e["type"] as? String) == "run.updated" && (payload(e)["id"] as? String ?? "").hasSuffix(":ordinal:1") && ["completed", "failed", "interrupted"].contains(payload(e)["status"] as? String ?? "")
    })
    await pause(2)

    // Turn 2: long markdown answer, streamed to completion.
    m = await mark()
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(),
        "text": "Without using tools, explain in about 250 words how git worktrees work. Use a heading, a bullet list, a small table and one fenced bash code block.",
        "attachments": [] as [Any], "dispatchMode": ["type": "start_immediately"],
    ])
    _ = await waitFor("turn 2 completion", after: m, timeout: 180, { e in
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted"].contains(payload(e)["status"] as? String ?? "")
    })
    await pause(2)

    // Turn 3: interrupt after streaming starts.
    m = await mark()
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(),
        "text": "Without using tools, write a 600-word short story about a lighthouse keeper.",
        "attachments": [] as [Any], "dispatchMode": ["type": "start_immediately"],
    ])
    if let ev = await waitFor("turn 3 assistant text", after: m, timeout: 120, { e in
        let t = e["type"] as? String
        return (t == "message.updated" && (payload(e)["role"] as? String) == "assistant") || (t == "turn-item.updated" && (payload(e)["type"] as? String) == "assistant_message")
    }) {
        _ = ev
        await pause(1.0)
        let runId = await state.snapshot().compactMap { $0["event"] as? [String: Any] }
            .last { ($0["type"] as? String) == "run.updated" || ($0["type"] as? String) == "run.created" }
            .map { payload($0)["id"]! }
        if let runId {
            try await request("orchestration.dispatchCommand", [
                "type": "run.interrupt", "commandId": uuid(), "threadId": threadId, "runId": runId, "holdQueue": true,
            ])
        }
    }
    _ = await waitFor("turn 3 end", after: m, timeout: 60, { e in
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted"].contains(payload(e)["status"] as? String ?? "")
    })
    await pause(3)

    // Resume: a second subscription that catches up from a known sequence.
    try await request("orchestration.subscribeThread", ["threadId": threadId, "afterSequence": 5, "requestCompletionMarker": true,
                                                        "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
    await pause(2)
    try await request("orchestration.getTurnDiff", ["threadId": threadId, "fromTurnCount": 0, "toTurnCount": 1])
    try await request("orchestration.getFullThreadDiff", ["threadId": threadId, "toTurnCount": 1])
    try await request("vcs.refreshStatus", ["cwd": repo])
    await pause(2)
    _ = try await http("GET", "api/orchestration/shell", headers: auth)
    _ = try await http("GET", "api/orchestration/threads/\(threadId)/bounded", headers: auth)
    _ = try await http("GET", "api/orchestration/threads/\(threadId)", headers: auth)
    print("threadId \(threadId)")

case "threads":
    // The subscribeThread snapshot of every thread on the server: timeline fixtures.
    let (_, shell) = try await http("GET", "api/orchestration/shell", headers: auth)
    let root = (shell as? [String: Any]) ?? [:]
    let threads = (root["threads"] as? [[String: Any]]) ?? ((root["snapshot"] as? [String: Any])?["threads"] as? [[String: Any]]) ?? []
    for thread in threads {
        guard let id = thread["id"] as? String else { continue }
        try await request("orchestration.subscribeThread", ["threadId": id, "requestCompletionMarker": true,
                                                            "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
        await pause(1)
    }
    await pause(2)
    print("threads \(threads.count)")

case "composer":
    // The composer flows I-composer-flow.md 9.10 lists as unrecorded: launchThread for a draft's
    // first send, a follow-up with deliveryIntent auto, a queued message, run.interrupt with
    // holdQueue, then resume (continuation plus queue.resume). Four tiny haiku turns.
    let projectId = ProcessInfo.processInfo.environment["PROJECT_ID"]!
    let haiku: [String: Any] = ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"]
    func isEnd(_ e: [String: Any]) -> Bool {
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted", "cancelled"].contains(payload(e)["status"] as? String ?? "")
    }
    try await request("orchestration.subscribeShell", ["requestCompletionMarker": true])
    await pause(1)
    let threadId = uuid()
    let launch = try await request("orchestration.launchThread", [
        "commandId": uuid(), "creationSource": "web", "threadId": threadId, "projectId": projectId,
        "title": "Reply with one word: hi", "generateTitle": true, "modelSelection": haiku,
        "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": ["type": "root"],
        "initialMessage": ["messageId": uuid(), "text": "Reply with one word: hi", "attachments": [] as [Any]],
    ])
    // The thread exists only once the launch returns; subscribing earlier fails with
    // OrchestrationV2GetThreadProjectionError (recorded on the first attempt).
    for _ in 0..<150 where await state.exit(launch) == nil { await pause(0.1) }
    try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                        "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
    _ = await waitFor("turn 1 end", timeout: 120, isEnd)
    await pause(2)

    // Follow-up the way the composer sends it on an idle thread: start_immediately plus deliveryIntent auto.
    var m = await mark()
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(), "text": "Without tools, write the numbers 1 to 400 as words, one per line.",
        "attachments": [] as [Any], "titleSeed": "Without tools, write the numbers 1 to 400 as words...",
        "modelSelection": haiku, "dispatchMode": ["type": "start_immediately"], "deliveryIntent": "auto",
    ])
    if let running = await waitFor("turn 2 running", after: m, timeout: 60, { e in
        (e["type"] as? String) == "run.updated" && (payload(e)["status"] as? String) == "running"
    }) {
        // UI mode queue: queue_after_active, no deliveryIntent.
        try await request("orchestration.dispatchCommand", [
            "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
            "threadId": threadId, "messageId": uuid(), "text": "Reply with one word: ok",
            "attachments": [] as [Any], "modelSelection": haiku, "dispatchMode": ["type": "queue_after_active"],
        ])
        _ = await waitFor("queued run", after: m, timeout: 20, { e in
            (e["type"] as? String) == "run.created" && (payload(e)["status"] as? String) == "queued"
        })
        try await request("orchestration.dispatchCommand", [
            "type": "run.interrupt", "commandId": uuid(), "threadId": threadId, "runId": payload(running)["id"]!, "holdQueue": true,
        ])
    }
    guard let interrupted = await waitFor("turn 2 end", after: m, timeout: 60, isEnd) else { break }
    await pause(3)

    // Resume: the continuation message, then queue.resume for the held run.
    m = await mark()
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(), "text": "Continue where you left off.",
        "attachments": [] as [Any], "modelSelection": haiku, "dispatchMode": ["type": "start_immediately"],
        "manualContinuationOfRunId": payload(interrupted)["id"]!,
    ])
    await pause(1)
    try await request("orchestration.dispatchCommand", ["type": "queue.resume", "commandId": uuid(), "threadId": threadId])
    // The continuation, then the released queued run.
    let continuation = await waitFor("continuation end", after: m, timeout: 120, isEnd).map { payload($0)["id"] as? String }
    _ = await waitFor("queued run end", after: m, timeout: 120, { e in isEnd(e) && payload(e)["id"] as? String != continuation })
    await pause(3)
    print("threadId \(threadId)")

case "requests":
    // Every runtime-request.respond the composer panels send (I-composer-flow.md 3.2 to 3.4):
    // decline, cancel and acceptForSession on file approvals, then a two-question prompt answered
    // with a multi-select array and a free-text answer. Four tiny haiku turns.
    let projectId = ProcessInfo.processInfo.environment["PROJECT_ID"]!
    let haiku: [String: Any] = ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"]
    func isEnd(_ e: [String: Any]) -> Bool {
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted", "cancelled"].contains(payload(e)["status"] as? String ?? "")
    }
    func isPending(_ e: [String: Any]) -> Bool {
        (e["type"] as? String) == "runtime-request.updated" && (payload(e)["status"] as? String) == "pending"
    }
    func launch(_ text: String, mode: String) async throws -> String {
        let threadId = uuid()
        let rid = try await request("orchestration.launchThread", [
            "commandId": uuid(), "creationSource": "web", "threadId": threadId, "projectId": projectId,
            "title": text, "generateTitle": false, "modelSelection": haiku,
            "runtimeMode": mode, "interactionMode": "default", "workspaceStrategy": ["type": "root"],
            "initialMessage": ["messageId": uuid(), "text": text, "attachments": [] as [Any]],
        ])
        for _ in 0..<150 where await state.exit(rid) == nil { await pause(0.1) }
        try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                            "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
        return threadId
    }
    func follow(_ threadId: String, _ text: String) async throws {
        try await request("orchestration.dispatchCommand", [
            "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
            "threadId": threadId, "messageId": uuid(), "text": text, "attachments": [] as [Any],
            "modelSelection": haiku, "dispatchMode": ["type": "start_immediately"], "deliveryIntent": "auto",
        ])
    }
    /// Answers the run's first approval with `first`, any later one with `rest`, until the run ends.
    func answerApprovals(_ threadId: String, after: Int, first: String, rest: String) async throws {
        var m = after, decision = first
        for _ in 0..<4 {
            guard let e = await waitFor("approval or end", after: m, timeout: 120, { isPending($0) || isEnd($0) }), !isEnd(e) else { return }
            m = await mark()
            await pause(1)
            try await request("orchestration.dispatchCommand", [
                "type": "runtime-request.respond", "commandId": uuid(), "threadId": threadId,
                "requestId": payload(e)["id"]!, "decision": decision,
            ])
            decision = rest
        }
        _ = await waitFor("run end", after: m, timeout: 120, isEnd)
    }
    try await request("orchestration.subscribeShell", ["requestCompletionMarker": true])
    await pause(1)

    var m = await mark()
    let approvals = try await launch("Create a file named a.txt containing hi.", mode: "approval-required")
    try await answerApprovals(approvals, after: m, first: "decline", rest: "cancel")
    await pause(2)
    m = await mark()
    try await follow(approvals, "Try again: create a.txt containing hi.")
    try await answerApprovals(approvals, after: m, first: "cancel", rest: "cancel")
    await pause(2)
    m = await mark()
    try await follow(approvals, "Create a file named b.txt containing hi.")
    try await answerApprovals(approvals, after: m, first: "acceptForSession", rest: "accept")
    await pause(2)

    m = await mark()
    let questions = try await launch("Use AskUserQuestion once with two questions: a multi-select one with three options, then a single-select one with two options. Then reply ok.", mode: "full-access")
    if let req = await waitFor("question", after: m, timeout: 120, { isPending($0) || isEnd($0) }), !isEnd(req) {
        await pause(1)
        let requestId = payload(req)["id"] as! String
        let item = await state.snapshot().compactMap { $0["event"] as? [String: Any] }.last {
            ($0["type"] as? String) == "turn-item.updated" && (payload($0)["requestId"] as? String) == requestId
        }
        var answers: [String: Any] = [:]
        for (i, q) in ((item.map(payload)?["questions"] as? [[String: Any]]) ?? []).enumerated() {
            let options = ((q["options"] as? [[String: Any]]) ?? []).map { ($0["value"] as? String) ?? ($0["label"] as? String ?? "") }
            let id = q["id"] as? String ?? ""
            if (q["multiSelect"] as? Bool) == true { answers[id] = Array(options.prefix(2)) }
            else { answers[id] = i == 0 ? (options.first ?? "a") : "My own answer" }
        }
        m = await mark()
        try await request("orchestration.dispatchCommand", [
            "type": "runtime-request.respond", "commandId": uuid(), "threadId": questions,
            "requestId": requestId, "answers": answers,
        ])
        _ = await waitFor("question run end", after: m, timeout: 120, isEnd)
    }
    await pause(3)
    print("threads \(approvals) \(questions)")

case "queue":
    // The queue strip's commands and steer (I-composer-flow.md 4.3 to 4.6, 9.10 items 2 and 4):
    // three messages queued behind a slow turn, queued-run.edit, queued-run.reorder,
    // queued-run.cancel, queued-message.promote-to-steer, then a direct steer. Everything lands
    // in the one running turn, so it costs one haiku turn.
    let projectId = ProcessInfo.processInfo.environment["PROJECT_ID"]!
    let haiku: [String: Any] = ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"]
    func isEnd(_ e: [String: Any]) -> Bool {
        (e["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted", "cancelled"].contains(payload(e)["status"] as? String ?? "")
    }
    func command(_ type: String, _ fields: [String: Any]) async throws {
        try await request("orchestration.dispatchCommand", fields.merging(["type": type, "commandId": uuid()]) { a, _ in a })
    }
    try await request("orchestration.subscribeShell", ["requestCompletionMarker": true])
    await pause(1)
    let threadId = uuid()
    // A long tool-free reply keeps the run busy (a `sleep` gets moved to the background by Claude).
    let text = "Without tools, write the numbers 1 to 1000 as words, one per line."
    let launch = try await request("orchestration.launchThread", [
        "commandId": uuid(), "creationSource": "web", "threadId": threadId, "projectId": projectId,
        "title": "Numbers 1 to 1000 as words", "generateTitle": false, "modelSelection": haiku,
        "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": ["type": "root"],
        "initialMessage": ["messageId": uuid(), "text": text, "attachments": [] as [Any]],
    ])
    for _ in 0..<150 where await state.exit(launch) == nil { await pause(0.1) }
    try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                        "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
    // The run is already running in the launch reply's projection, so no event announces it.
    let activeRunId = "run:thread:\(threadId):ordinal:1"
    await pause(1)
    var runIds: [String] = []
    for word in ["alpha", "beta", "gamma"] {
        let m = await mark()
        let messageId = uuid()
        try await command("message.dispatch", [
            "createdBy": "user", "creationSource": "web", "threadId": threadId, "messageId": messageId,
            "text": "Reply with one word: \(word)", "attachments": [] as [Any], "modelSelection": haiku,
            "dispatchMode": ["type": "queue_after_active"],
        ])
        if let created = await waitFor("queued \(word)", after: m, timeout: 20, { e in
            (e["type"] as? String) == "run.created" && (payload(e)["userMessageId"] as? String) == messageId
        }) { runIds.append(payload(created)["id"] as! String) }
    }
    guard runIds.count == 3 else { break }
    try await command("queued-run.edit", ["threadId": threadId, "runId": runIds[0], "text": "Reply with one word: alpha2"])
    await pause(0.5)
    // gamma before alpha: positions become gamma, alpha, beta.
    try await command("queued-run.reorder", ["threadId": threadId, "runId": runIds[2], "beforeRunId": runIds[0]])
    await pause(0.5)
    try await command("queued-run.reorder", ["threadId": threadId, "runId": runIds[0], "beforeRunId": NSNull()])
    await pause(0.5)
    try await command("queued-run.cancel", ["threadId": threadId, "runId": runIds[1]])
    await pause(0.5)
    try await command("queued-run.cancel", ["threadId": threadId, "runId": runIds[0]])
    await pause(0.5)
    try await command("queued-message.promote-to-steer", ["threadId": threadId, "queuedRunId": runIds[2], "targetRunId": activeRunId])
    await pause(1)
    try await command("message.dispatch", [
        "createdBy": "user", "creationSource": "web", "threadId": threadId, "messageId": uuid(),
        "text": "Then also say: steered", "attachments": [] as [Any], "modelSelection": haiku,
        "dispatchMode": ["type": "start_immediately"], "deliveryIntent": "steer",
    ])
    _ = await waitFor("turn end", timeout: 120, { e in isEnd(e) && (payload(e)["id"] as? String) == activeRunId })
    await pause(3)
    print("threadId \(threadId)")

default:
    print("unknown scenario"); exit(2)
}

receiver.cancel()
ws.cancel(with: .normalClosure, reason: nil)
record("send", "ws-close", [:])
flush()
print("recorded \(log.lines.count) lines to \(outPath)")
