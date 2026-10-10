// Records a real T3 server session (HTTP pairing + WebSocket RPC) as JSONL.
//
// Usage: swift record.swift <baseURL> <tokenFile> <outFile> <scenario> [pairingToken]
//   tokenFile   bearer token cache for this (sandbox) server; created on first pairing.
//   scenario    basic | turn
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

default:
    print("unknown scenario"); exit(2)
}

receiver.cancel()
ws.cancel(with: .normalClosure, reason: nil)
record("send", "ws-close", [:])
flush()
print("recorded \(log.lines.count) lines to \(outPath)")
