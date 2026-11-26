// Puts a message with an image and a file in a sandbox thread's queue and holds it there,
// so a test app can open the queued message's edit with attachments (no clipboard or drag needed).
//
// Usage: [PROJECT_ID=<id>] swift scripts/queue-attachment.swift <baseURL> <tokenFile> <workspaceRoot> [image.png] [file]
//
// It sends what the composer sends: `attachments.createUploadUrl`, a POST of the bytes, then
// `message.dispatch` with `queue_after_active` while a run is going (docs/protocol.md 5.3 and 7.3).
// The running turn is interrupted with `holdQueue: true`, so the queued run stays held until you
// resume or edit it. One tiny claude-haiku-5-5 turn per call. Run it only against a sandbox server.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: queue-attachment.swift <baseURL> <tokenFile> <workspaceRoot> [image.png] [file]\n".data(using: .utf8)!)
    exit(2)
}
let baseURL = URL(string: args[1])!
let token = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let workspaceRoot = args[3]

func uuid() -> String { UUID().uuidString.lowercased() }
func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

/// A 640x400 test picture when no image is given.
func samplePNG() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 100, width: 200, height: 200)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let auth = ["Authorization": "Bearer \(token)", "x-t3-orchestration-protocol": "2"]
func post(_ path: String, body: Data? = nil, contentType: String? = nil) async throws -> (Int, Any?) {
    var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
    req.httpMethod = "POST"
    for (k, v) in auth { req.setValue(v, forHTTPHeaderField: k) }
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    req.httpBody = body
    let (data, resp) = try await URLSession.shared.data(for: req)
    return ((resp as! HTTPURLResponse).statusCode, try? JSONSerialization.jsonObject(with: data))
}

let (_, ticketBody) = try await post("api/auth/websocket-ticket")
let ticket = (ticketBody as! [String: Any])["ticket"] as! String
var comps = URLComponents(url: baseURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
comps.queryItems = [
    .init(name: "orchestrationProtocol", value: "2"), .init(name: "wsTicket", value: ticket),
    .init(name: "clientSurface", value: "desktop"), .init(name: "clientAppVersion", value: "0.0.0-queue-attachment"),
    .init(name: "clientOs", value: "macOS"), .init(name: "clientDeviceType", value: "desktop"), .init(name: "connectionMethod", value: "direct"),
]
let ws = URLSession.shared.webSocketTask(with: comps.url!)
ws.maximumMessageSize = 64 * 1024 * 1024
ws.resume()

actor State {
    var nextId = 1
    var events: [[String: Any]] = []
    var exits: [String: [String: Any]] = [:]
    func id() -> String { defer { nextId += 1 }; return String(nextId) }
    func add(_ e: [String: Any]) { events.append(e) }
    func exit(_ rid: String, _ m: [String: Any]) { exits[rid] = m }
    func all() -> [[String: Any]] { events }
    func exitFor(_ rid: String) -> [String: Any]? { exits[rid] }
}
let state = State()

func send(_ obj: [String: Any]) async throws {
    try await ws.send(.string(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!))
}
@discardableResult
func request(_ tag: String, _ payload: [String: Any]) async throws -> String {
    let id = await state.id()
    try await send(["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]])
    return id
}
/// Waits for a unary call's success value; exits on a failure.
func call(_ tag: String, _ payload: [String: Any]) async throws -> Any? {
    let rid = try await request(tag, payload)
    for _ in 0..<300 {
        if let m = await state.exitFor(rid) {
            let exit = m["exit"] as? [String: Any]
            guard exit?["_tag"] as? String == "Success" else { print("\(tag) failed: \(m)"); Foundation.exit(1) }
            return exit?["value"]
        }
        await pause(0.1)
    }
    print("\(tag) timed out"); Foundation.exit(1)
}
func payload(_ e: [String: Any]) -> [String: Any] { (e["payload"] as? [String: Any]) ?? [:] }
func waitFor(_ label: String, timeout: Double, _ match: @escaping ([String: Any]) -> Bool) async -> [String: Any]? {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let e = await state.all().last(where: match) { return e }
        await pause(0.2)
    }
    print("timed out waiting for \(label)"); return nil
}

Task {
    while true {
        guard case .string(let text) = try await ws.receive(),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { continue }
        for m in (obj as? [[String: Any]]) ?? ((obj as? [String: Any]).map { [$0] } ?? []) {
            switch m["_tag"] as? String {
            case "Chunk":
                // 5258 wraps thread events as `{kind: "event", event}`; older servers sent the event itself.
                for v in (m["values"] as? [[String: Any]]) ?? [] { await state.add((v["event"] as? [String: Any]) ?? v) }
                if let rid = m["requestId"] { try await send(["_tag": "Ack", "requestId": rid]) }
            case "Exit":
                if let rid = m["requestId"] as? String { await state.exit(rid, m) }
            default: break
            }
        }
    }
}

/// Uploads bytes the way the composer does and returns the `ChatAttachment` for `message.dispatch`.
func upload(_ data: Data, name: String, mimeType: String, type: String) async throws -> [String: Any] {
    let result = try await call("attachments.createUploadUrl", ["type": type, "name": name, "mimeType": mimeType, "sizeBytes": data.count]) as! [String: Any]
    let (status, _) = try await post(result["relativeUrl"] as! String, body: data, contentType: mimeType)
    guard status == 204 else { print("upload of \(name) returned \(status)"); exit(1) }
    return ["type": type, "id": result["attachmentId"]!, "name": name, "mimeType": mimeType, "sizeBytes": data.count]
}

let haiku: [String: Any] = ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"]
// PROJECT_ID reuses a project; without it the script creates one at workspaceRoot.
let projectId = ProcessInfo.processInfo.environment["PROJECT_ID"] ?? uuid()
if ProcessInfo.processInfo.environment["PROJECT_ID"] == nil {
// Projects are created over HTTP since the orchestration commands dropped `project.create` (docs/protocol.md 5.2).
let (projectStatus, projectBody) = try await post("api/projects/mutate", body: try JSONSerialization.data(withJSONObject: [
    "type": "project.create", "commandId": uuid(), "projectId": projectId,
    "title": URL(fileURLWithPath: workspaceRoot).lastPathComponent, "workspaceRoot": workspaceRoot,
]), contentType: "application/json")
guard projectStatus == 200 else { print("project.create returned \(projectStatus): \(projectBody ?? ""). An existing project? Pass PROJECT_ID."); exit(1) }
}
let threadId = uuid()
_ = try await call("orchestration.launchThread", [
    "commandId": uuid(), "creationSource": "web", "threadId": threadId, "projectId": projectId,
    "title": "Queued attachments", "generateTitle": false, "modelSelection": haiku,
    "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": ["type": "root"],
    "initialMessage": ["messageId": uuid(), "text": "Without tools, write the numbers 1 to 300 as words, one per line.", "attachments": [] as [Any]],
])
try await request("orchestration.subscribeThread", ["threadId": threadId, "requestCompletionMarker": true,
                                                    "acceptBoundedSnapshot": true, "acceptCompactTurnItems": true])
// The run may already be running in the subscribe snapshot (`projection.runs`), or turn running later in a `run.updated`.
func runningRunId() async -> String? {
    for e in await state.all().reversed() {
        if (e["type"] as? String) == "run.updated", (payload(e)["status"] as? String) == "running" { return e["runId"] as? String ?? payload(e)["id"] as? String }
        if let runs = (e["projection"] as? [String: Any])?["runs"] as? [[String: Any]],
           let run = runs.first(where: { $0["status"] as? String == "running" }) { return run["id"] as? String }
    }
    return nil
}
var runId: String?
for _ in 0..<450 where runId == nil { runId = await runningRunId(); if runId == nil { await pause(0.2) } }
guard let runId else { print("timed out waiting for the run to start"); exit(1) }

let imageData = args.count > 4 ? try Data(contentsOf: URL(fileURLWithPath: args[4])) : samplePNG()
let imageName = args.count > 4 ? URL(fileURLWithPath: args[4]).lastPathComponent : "queued-sample.png"
let fileData = args.count > 5 ? try Data(contentsOf: URL(fileURLWithPath: args[5])) : Data("queued file\n".utf8)
let fileName = args.count > 5 ? URL(fileURLWithPath: args[5]).lastPathComponent : "a-rather-long-release-notes-file-name-for-the-queue.txt"
let attachments = [
    try await upload(imageData, name: imageName, mimeType: "image/png", type: "image"),
    try await upload(fileData, name: fileName, mimeType: "text/plain", type: "file"),
]
// The composer's queue mode: `queue_after_active` with no deliveryIntent.
_ = try await call("orchestration.dispatchCommand", [
    "type": "message.dispatch", "createdBy": "user", "creationSource": "web", "commandId": uuid(),
    "threadId": threadId, "messageId": uuid(), "text": "Describe the picture in one word.",
    "attachments": attachments, "modelSelection": haiku, "dispatchMode": ["type": "queue_after_active"],
])
_ = await waitFor("the queued run", timeout: 20, { e in
    (e["type"] as? String) == "run.created" && (payload(e)["status"] as? String) == "queued"
})
_ = try await call("orchestration.dispatchCommand", [
    "type": "run.interrupt", "commandId": uuid(), "threadId": threadId, "runId": runId, "holdQueue": true,
])
print("projectId \(projectId)")
print("threadId \(threadId)")
exit(0)
