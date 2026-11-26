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

    /// The recorded thread whose title starts with `prefix`, or the math thread for `mathThread`.
    public static func projection(titled prefix: String) throws -> ThreadProjection? {
        if mathThread.hasPrefix(prefix), prefix.count >= 4 { return try mathProjection() }
        return try projections().last { $0.thread.title.hasPrefix(prefix) }
    }

    /// A thread of formulas for looking at math on screen: the markdown thread with its title and texts replaced.
    /// Render math must be on (`mathRenderingEnabled`).
    public static let mathThread = "Math preview"
    static let mathPrompt = "Show some math."
    static let mathReply = """
    Inline: $\\frac{a+b}{c}$, $x_i^2$, $\\sqrt{x^2+1}$, $\\sqrt[3]{8}$, $\\sum_{i=1}^{n} x_i$, $\\int_0^\\infty e^{-x}\\,dx$, \
    $\\alpha + \\beta = \\gamma$, $\\hat{x} + \\vec{v} + \\bar{y}$ and $\\mathbb{R}^n$ in one line of text.

    $$\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2} \\qquad \\int_a^b f(x)\\,dx$$

    $$\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix} \\qquad f(x) = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}$$

    Bad TeX: $x + \\foo{y}$ and $\\frac{a}{$ here.

    Wide: $a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13} + a_{14} + a_{15} + a_{16} + a_{17} + a_{18} + a_{19} + a_{20} + a_{21} + a_{22} + a_{23} + a_{24}$ ends.
    """

    static func mathProjection() throws -> ThreadProjection? {
        guard let base = try projection(titled: markdownThread),
              let reply = base.messages.last(where: { $0.role == "assistant" })?.text,
              let prompt = base.messages.first(where: { $0.role == "user" })?.text else { return nil }
        let encoder = JSONEncoder()
        func quoted(_ s: String) throws -> String { String(decoding: try encoder.encode(s), as: UTF8.self) }
        var json = String(decoding: try encoder.encode(base), as: UTF8.self)
        for (old, new) in [(reply, mathReply), (prompt, mathPrompt), (base.thread.title, mathThread)] {
            json = json.replacingOccurrences(of: try quoted(old), with: try quoted(new))
        }
        return try JSONDecoder().decode(ThreadProjection.self, from: Data(json.utf8))
    }
}
