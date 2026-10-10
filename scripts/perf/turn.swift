// Drives one streaming turn on the sandbox server for scripts/perf-review, so the app under test
// only watches. Same RPC as scripts/record-transcript.swift.
//
// Usage:
//   turn <baseURL> <tokenFile> create <title>          new claude-haiku-5-5 thread in the first project; prints its id
//   turn <baseURL> <tokenFile> send <threadId> <text>  sends the text, waits for the run to end; prints JSON timing
// Build: swiftc -O scripts/perf/turn.swift -o /tmp/cw-perf/bin/turn
import Foundation

let args = CommandLine.arguments
guard args.count >= 5, let baseURL = URL(string: args[1]) else {
    print("usage: turn <baseURL> <tokenFile> create <title> | send <threadId> <text>"); exit(2)
}
let token = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let auth = ["Authorization": "Bearer \(token)", "x-t3-orchestration-protocol": "2"]

func http(_ method: String, _ path: String) async throws -> Any {
    var req = URLRequest(url: baseURL.appending(path: path))
    req.httpMethod = method
    for (k, v) in auth { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as! HTTPURLResponse).statusCode == 200 else { throw NSError(domain: "http \(path)", code: (resp as! HTTPURLResponse).statusCode) }
    return try JSONSerialization.jsonObject(with: data)
}

let ticket = ((try await http("POST", "api/auth/websocket-ticket")) as! [String: Any])["ticket"] as! String
var comps = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)!
comps.scheme = "ws"
comps.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2"), URLQueryItem(name: "wsTicket", value: ticket),
                    URLQueryItem(name: "clientSurface", value: "desktop"), URLQueryItem(name: "clientAppVersion", value: "0.0.0-perf"),
                    URLQueryItem(name: "clientOs", value: "macOS"), URLQueryItem(name: "clientDeviceType", value: "desktop"),
                    URLQueryItem(name: "connectionMethod", value: "direct")]
let ws = URLSession.shared.webSocketTask(with: comps.url!)
ws.maximumMessageSize = 64 * 1024 * 1024
ws.resume()

actor Events {
    var items: [[String: Any]] = []
    func add(_ e: [String: Any]) { items.append(e) }
    func all() -> [[String: Any]] { items }
}
let events = Events()
var nextId = 1

func send(_ obj: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: obj)
    try await ws.send(.string(String(decoding: data, as: UTF8.self)))
}

func request(_ tag: String, _ payload: [String: Any]) async throws {
    defer { nextId += 1 }
    try await send(["_tag": "Request", "id": String(nextId), "tag": tag, "payload": payload, "headers": [] as [Any]])
}

_ = Task {
    while true {
        guard case .string(let text) = try await ws.receive() else { continue }
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
        for m in (obj as? [[String: Any]]) ?? [(obj as? [String: Any]) ?? [:]] where m["_tag"] as? String == "Chunk" {
            for v in (m["values"] as? [[String: Any]]) ?? [] { if let e = v["event"] as? [String: Any] { await events.add(e) } }
            if let rid = m["requestId"] { try await send(["_tag": "Ack", "requestId": rid]) }
        }
    }
}

func uuid() -> String { UUID().uuidString.lowercased() }
func payload(_ e: [String: Any]) -> [String: Any] { (e["payload"] as? [String: Any]) ?? [:] }

switch args[3] {
case "create":
    let shell = try await http("GET", "api/orchestration/shell") as! [String: Any]
    guard let project = (shell["projects"] as? [[String: Any]])?.first, let projectId = project["id"] as? String else {
        print("no project"); exit(1)
    }
    let threadId = uuid()
    try await request("orchestration.dispatchCommand", [
        "type": "thread.create", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "projectId": projectId, "title": args[4],
        "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"],
        "runtimeMode": "approval-required", "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(),
    ])
    try await Task.sleep(for: .seconds(1))
    print(threadId)
case "send":
    guard args.count >= 6 else { exit(2) }
    let threadId = args[4]
    try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                        "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
    try await Task.sleep(for: .seconds(1))
    let skip = await events.all().count
    let start = Date()
    try await request("orchestration.dispatchCommand", [
        "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
        "threadId": threadId, "messageId": uuid(), "text": args[5],
        "attachments": [] as [Any], "dispatchMode": ["type": "start_immediately"],
    ])
    var firstText: Double?
    let deadline = Date().addingTimeInterval(240)
    while Date() < deadline {
        let fresh = await events.all().dropFirst(skip)
        if firstText == nil, fresh.contains(where: { ($0["type"] as? String) == "message.updated" && (payload($0)["role"] as? String) == "assistant" }) {
            firstText = Date().timeIntervalSince(start)
        }
        if let end = fresh.first(where: {
            ($0["type"] as? String) == "run.updated" && ["completed", "failed", "interrupted"].contains(payload($0)["status"] as? String ?? "")
        }) {
            let out: [String: Any] = ["status": payload(end)["status"] ?? "", "seconds": Date().timeIntervalSince(start),
                                      "first_text_seconds": firstText ?? -1]
            print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
            exit(0)
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    print("{\"status\":\"timeout\"}")
    exit(1)
default:
    exit(2)
}
