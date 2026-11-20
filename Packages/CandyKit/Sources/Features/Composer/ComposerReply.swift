import Foundation
import T3Protocol

/// Reply to an assistant response (#33124 at 4928): the `ResponseContextRecord` a reply sends, and the
/// "Replying to" banner's text. The record rides as context; the agent rereads the response by item id.
public enum ComposerReply {
    /// `RESPONSE_OPENING_LENGTH` (assistantTextSelection.ts:175 at 4928).
    static let openingLength = 300

    public struct Subagent: Equatable, Sendable {
        public var threadId: String
        public var environmentId: String?
        public var title: String
        public init(threadId: String, environmentId: String? = nil, title: String) {
            self.threadId = threadId; self.environmentId = environmentId; self.title = title
        }
    }

    /// `captureAssistantMessageOpening` (assistantTextSelection.ts:179-189 at 4928) over the message text, T3's
    /// fallback when the rendered response isn't on screen.
    // ponytail: offsets refer to the raw text, not the rendered Markdown T3 reads first; navigation lands on the message either way. Read MarkdownView's text if a reply's highlight matters
    public static func opening(_ text: String) -> AssistantSelectionText? {
        let ns = text as NSString
        let trimmedStart = text.drop(while: \.isWhitespace)
        let start = ns.length - (String(trimmedStart) as NSString).length
        let trimmedEnd = (String(text.reversed().drop(while: \.isWhitespace).reversed()) as NSString).length
        var end = min(trimmedEnd, start + openingLength)
        if end > 0, end < ns.length, (0xD800...0xDBFF).contains(ns.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        return AssistantSelectionText.capture(text, range: NSRange(location: start, length: end - start))
    }

    /// `responseContextRecord` (composerContextRecords.ts:181-207 at 4928): one record per response.
    public static func record(environmentId: String, threadId: String, messageId: String, text: String,
                              itemId: String, subagents: [Subagent]) -> JSONValue? {
        guard let opening = opening(text) else { return nil }
        let citation = ThreadAssistantCitation.selection(environmentId: environmentId, threadId: threadId, messageId: messageId, selection: opening)
        var fields: [String: JSONValue] = [
            "version": .number(1), "kind": .string("response"),
            "contextId": .string(ComposerContext.kindScopedId("response", messageId)),
            "label": .string(ComposerContext.sanitizeLabel(String(opening.text.prefix(64)), kind: "response")),
            "citation": .object([
                "version": .number(1), "environmentId": .string(environmentId), "threadId": .string(threadId),
                "messageId": .string(messageId), "text": .string(citation.text), "start": .number(Double(citation.start)),
                "end": .number(Double(citation.end)), "prefix": .string(citation.prefix), "suffix": .string(citation.suffix),
            ]),
            "itemId": .string(itemId),
        ]
        if !subagents.isEmpty {
            fields["subagents"] = .array(subagents.prefix(20).map { s in
                var o: [String: JSONValue] = ["threadId": .string(s.threadId), "title": .string(ComposerContext.sanitizeLabel(s.title, kind: "response"))]
                if let env = s.environmentId { o["environmentId"] = .string(env) }
                return .object(o)
            })
        }
        return .object(fields)
    }

    /// The record's citation, for the banner's link and its navigation.
    public static func citation(_ record: JSONValue) -> ThreadAssistantCitation? {
        guard let c = record["citation"], let env = c["environmentId"]?.stringValue, let thread = c["threadId"]?.stringValue,
              let message = c["messageId"]?.stringValue, let text = c["text"]?.stringValue else { return nil }
        return ThreadAssistantCitation(environmentId: env, threadId: thread, messageId: message, text: text,
                                       start: c["start"]?.intValue ?? 0, end: c["end"]?.intValue ?? 0,
                                       prefix: c["prefix"]?.stringValue ?? "", suffix: c["suffix"]?.stringValue ?? "")
    }

    /// The banner's title (ChatComposer.tsx `replyBannerItems` at 4928).
    public static func bannerTitle(_ record: JSONValue) -> String {
        let names = record["subagents"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        return names.isEmpty ? "Replying to" : "Replying to " + names.joined(separator: ", ")
    }

    /// The reference a reply leads its message with (useComposerSend.ts:785-792 at 4928).
    public static func reference(_ record: JSONValue) -> ComposerContext.Reference? {
        guard let id = record["contextId"]?.stringValue else { return nil }
        return ComposerContext.Reference(kind: "response", contextId: id, label: record["label"]?.stringValue ?? "response")
    }

    /// The prompt with the reply's reference in front, unless it already points at that response.
    public static func prompt(_ text: String, replyingTo record: JSONValue) -> String {
        guard let reference = reference(record), !ComposerContext.referencedIds(text).contains(reference.contextId) else { return text }
        return ComposerContext.reference(reference) + " " + text
    }

    /// What a failed send puts back (`draftText`, ChatView.logic.ts at 4928): the text without the reply's reference.
    public static func draftText(_ text: String, contextId: String) -> String {
        let ns = NSMutableString(string: text)
        for t in ComposerInlineTokens.collect(text).reversed() {
            if case .context(_, let id, _) = t.kind, id == contextId { ns.replaceCharacters(in: t.range, with: "") }
        }
        return String((ns as String).drop(while: \.isWhitespace))
    }

    /// `readResponseSubagents` (state/entities.ts:473-541 at 4928): the subagents whose results the response
    /// reported on, read from the inputs right before it. `shellTitle` names a child thread without its own title.
    public static func subagents(_ projection: ThreadProjection, itemId: TurnItemId,
                                 shellTitle: (_ environmentId: String?, _ threadId: String) -> String?) -> [Subagent] {
        let items = projection.visibleTurnItems
        func isInput(_ i: Int) -> Bool { let t = items[i].item.type.rawValue; return t == "user_message" || t == "notification" }
        guard var index = items.firstIndex(where: { $0.sourceItemId == itemId }) else { return [] }
        index -= 1
        while index >= 0 && !isInput(index) { index -= 1 }
        var byTask: [String: Subagent] = [:], local: [String: Subagent] = [:]
        func remember(_ taskId: String?, _ child: String?, _ remote: JSONValue?, _ title: String?) {
            guard let taskId else { return }
            if let child {
                let s = Subagent(threadId: child, title: title ?? "")
                byTask[taskId] = s; local[child] = s
            } else if let remote, let thread = remote["threadId"]?.stringValue {
                byTask[taskId] = Subagent(threadId: thread, environmentId: remote["environmentId"]?.stringValue,
                                          title: title ?? remote["title"]?.stringValue ?? "")
            }
        }
        for p in items where p.item.type.rawValue == "subagent" {
            remember(p.item.subagentId, p.item["childThreadId"]?.stringValue, p.item["remoteChild"], nil)
        }
        for s in projection.subagents {
            remember(s["id"]?.stringValue, s["childThreadId"]?.stringValue, s["remoteChild"], s["title"]?.stringValue)
        }
        var order: [String] = [], found: [String: Subagent] = [:]
        func add(_ s: Subagent?) {
            guard let s else { return }
            let key = (s.environmentId ?? "") + ":" + s.threadId
            if found[key] == nil { order.append(key) }
            found[key] = s
        }
        while index >= 0 && isInput(index) {
            let item = items[index].item
            if item.type.rawValue == "notification" {
                let source = item["source"]
                if let child = source?["childThreadId"]?.stringValue { add(local[child] ?? Subagent(threadId: child, title: "")) }
                for task in source?["taskIds"]?.arrayValue ?? [] { add(task.stringValue.flatMap { byTask[$0] }) }
            } else {
                let message = item.messageId.flatMap { id in projection.messages.first { $0.id == id } }
                for task in message?.delegatedCompletion?["taskIds"]?.arrayValue ?? [] { add(task.stringValue.flatMap { byTask[$0] }) }
                // A sender counts only as this thread's subagent: a child's first message comes from its parent.
                if let sender = item["senderThreadId"]?.stringValue { add(local[sender]) }
            }
            index -= 1
        }
        return order.compactMap { found[$0] }.map { s in
            var s = s
            let own = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            s.title = !own.isEmpty ? own : shellTitle(s.environmentId, s.threadId)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Agent"
            return s
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
