import Foundation
import T3Protocol
@testable import T3Store

/// One recorded `orchestration.subscribeThread` call: its input and every Chunk, decoded, one
/// array per Chunk so replays keep the server's batching.
struct RecordedThreadStream {
    var threadId: ThreadId
    var input: [String: Any]
    var chunks: [[ThreadStreamItem]]
}

func recordedThreadStreams(_ name: String) throws -> [RecordedThreadStream] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("fixtures/transcripts/\(name)")
    var order: [String] = []
    var streams: [String: RecordedThreadStream] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            record["kind"] as? String == "ws", let body = record["body"] as? [String: Any]
        else { continue }
        if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeThread",
            let id = body["id"] as? String, let payload = body["payload"] as? [String: Any],
            let threadId = payload["threadId"] as? String
        {
            order.append(id)
            streams[id] = RecordedThreadStream(threadId: ThreadId(threadId), input: payload, chunks: [])
        } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String,
            streams[id] != nil, let values = body["values"] as? [Any]
        {
            streams[id]!.chunks.append(try values.map {
                try JSONDecoder().decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: $0))
            })
        }
    }
    return order.compactMap { streams[$0] }
}

/// Replays a recorded stream through a reducer.
func replay(_ stream: RecordedThreadStream) -> ThreadReducer {
    var reducer = ThreadReducer(threadId: stream.threadId)
    for chunk in stream.chunks { reducer.apply(chunk) }
    return reducer
}

/// Builds a turn item from the fields a test cares about; the base fields get defaults.
func turnItem(_ json: String) -> TurnItem {
    var fields = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let defaults: [String: Any] = [
        "threadId": "thread-1", "runId": NSNull(), "nodeId": NSNull(), "providerThreadId": NSNull(),
        "providerTurnId": NSNull(), "nativeItemRef": NSNull(), "parentItemId": NSNull(), "ordinal": 0,
        "status": "completed", "title": NSNull(), "startedAt": NSNull(), "completedAt": NSNull(),
        "updatedAt": "2026-01-01T00:00:00Z",
    ]
    for (key, value) in defaults where fields[key] == nil { fields[key] = value }
    return try! JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: fields))
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A one-line description of a row for sequence assertions: `kind:id`.
func describe(_ row: TimelineRow) -> String {
    let kind = switch row.kind {
    case .message(let m, _, _, _, _, _): m.role == .user ? "user" : "assistant"
    case .assistantMeta: "assistant-meta"
    case .work(_, true, _): "work-details"
    case .work: "work"
    case .workLive: "work-live"
    case .working: "working"
    case .thinking: "thinking"
    case .workToggle: "work-toggle"
    case .turnFold: "turn-fold"
    case .attemptFold: "attempt-fold"
    case .contextCompaction: "context-compaction"
    case .event(let p, _, _): "event(\(p.item.type.rawValue))"
    case .proposedPlan: "proposed-plan"
    case .htmlRender: "html-render"
    case .mcpApp: "mcp-app"
    }
    return kind
}
