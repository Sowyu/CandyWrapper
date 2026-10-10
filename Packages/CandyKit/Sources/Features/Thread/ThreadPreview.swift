import Foundation
import T3Protocol
import T3Store

/// Thread data without a server: recorded `subscribeThread` streams replayed through the reducer.
/// The app's `--thread-preview` and the fidelity tests use it.
public enum ThreadPreview {
    /// The threads behind design/reference 03a-c and 03d.
    public static let markdownThread = "Reply with markdown only"
    public static let commandsThread = "Reply with markdown containing"

    /// Every thread recorded in a transcript (default 04-threads.jsonl), replayed to its last state.
    /// A thread subscribed more than once keeps its last recording.
    public static func projections(transcript: String = "04-threads.jsonl") throws -> [ThreadProjection] {
        let url = SidebarPreview.repo.appendingPathComponent("fixtures/transcripts/\(transcript)")
        var order: [String] = []
        var streams: [String: (ThreadId, [[ThreadStreamItem]])] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["kind"] as? String == "ws", let body = record["body"] as? [String: Any] else { continue }
            if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeThread",
               let id = body["id"] as? String, let payload = body["payload"] as? [String: Any], let threadId = payload["threadId"] as? String {
                order.append(id)
                streams[id] = (ThreadId(threadId), [])
            } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String, streams[id] != nil,
                      let values = body["values"] as? [Any] {
                streams[id]!.1.append(try values.map {
                    try JSONDecoder().decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: $0))
                })
            }
        }
        var byThread: [ThreadId: ThreadProjection] = [:]
        var threadOrder: [ThreadId] = []
        for id in order {
            guard let (threadId, chunks) = streams[id] else { continue }
            var reducer = ThreadReducer(threadId: threadId)
            for chunk in chunks { _ = reducer.apply(chunk) }
            guard let projection = reducer.projection else { continue }
            if byThread[threadId] == nil { threadOrder.append(threadId) }
            byThread[threadId] = projection
        }
        return threadOrder.compactMap { byThread[$0] }
    }

    /// The recorded thread whose title starts with `prefix`.
    public static func projection(titled prefix: String) throws -> ThreadProjection? {
        try projections().last { $0.thread.title.hasPrefix(prefix) }
    }
}
