import Foundation
import T3Protocol

/// Redesign's Context popover legend: what fills the window, estimated on the client. T3 reports only the total
/// (`tokenUsage.usedTokens`), so this measures the thread's own items since the last compaction and attributes
/// the rest.
///
/// The wire strips tool output and diffs (`projectTurnItemForWire`, WireProjection.ts:94-137), so tool output
/// can't be measured from text. Instead every provider turn's report gives one reading of
/// `used - measured conversation so far`; the smallest of those is the fixed part, the system prompt and tools.
/// What the measured items don't cover beyond that is tool output.
public struct ThreadContextEstimate: Equatable, Sendable {
    public var system: Double = 0, messages: Double = 0, replies: Double = 0, tools: Double = 0, images: Double = 0

    // ponytail: 4 UTF-8 bytes per token, off by about 30% on prose with non-ASCII or dense code; use a real
    // tokenizer if the legend needs to be exact.
    static let bytesPerToken = 4.0
    // ponytail: one flat figure per image, Claude's cost of a ~1.15 megapixel image; read the image's size
    // if screenshots dominate threads.
    static let imageTokens = 1_600.0
    /// A non-pasted file attachment reaches the provider as its path only (chatAttachment.ts:170-172).
    static let fileTokens = 30.0

    public var categories: [(name: String, value: Double)] {
        [("System prompt and tools", system), ("Your messages", messages), ("Replies", replies),
         ("Tool calls and output", tools), ("Images and files", images)]
    }

    /// Splits `used` across the categories. Nil without a projection.
    public static func estimate(_ projection: ThreadProjection?, used: Double) -> Self? {
        guard let projection else { return nil }
        func date(_ s: String?) -> Date { s.flatMap { T3Timestamp($0).date } ?? .distantPast }
        func date(_ item: TurnItem) -> Date { (item.startedAt ?? item.updatedAt).date ?? .distantPast }
        var items = projection.visibleTurnItems.map(\.item)
        // Only what is still in context: everything after the last finished compaction, plus its summary.
        // A failed, stopped or running compaction leaves the earlier history in context.
        var since = Date.distantPast
        if let last = items.lastIndex(where: { $0.type == .compaction && $0.status == .completed }) {
            since = date(items[last])
            items = Array(items[last...])
        }
        let at = items.map { date($0) }
        // Each provider turn's report since the compaction, oldest first.
        let reports = projection.providerTurns.compactMap { turn -> (at: Date, used: Double)? in
            guard let usage = turn["tokenUsage"], let used = usage["usedTokens"]?.doubleValue else { return nil }
            let when = date(usage["updatedAt"]?.stringValue)
            return since == .distantPast || when > since ? (when, used) : nil
        }.sorted { $0.at < $1.at }

        // One pass in timeline order, reading the fixed part off each report as the timeline passes it.
        var parts = Self(), base = Double.infinity, next = 0
        var reasoning = 0.0, lastUser = -1
        func readReports(before cut: Date) {
            while next < reports.count, reports[next].at < cut {
                base = min(base, reports[next].used - parts.measured - reasoning)
                next += 1
            }
        }
        for (i, item) in items.enumerated() {
            readReports(before: at[i])
            let n = tokens(item, into: &parts)
            if item.type == .userMessage { lastUser = i; reasoning = 0 }
            // ponytail: reasoning counts only since the latest message of yours, as Claude drops earlier thinking;
            // count all of it if a provider keeps reasoning across turns.
            if item.type == .reasoning, i > lastUser { reasoning += n }
        }
        readReports(before: .distantFuture)
        parts.replies += reasoning

        let measured = parts.measured
        if measured >= used {
            // The estimate overshoots the report: scale the measured parts down so the legend still adds up.
            let k = measured > 0 ? used / measured : 0
            parts.messages *= k; parts.replies *= k; parts.tools *= k; parts.images *= k
            return parts
        }
        parts.system = min(max(0, base.isFinite ? base : used - measured), used - measured)
        parts.tools += used - measured - parts.system
        return parts
    }

    var measured: Double { messages + replies + tools + images }

    /// Adds one item to its category and returns its tokens; reasoning is returned, not added.
    @discardableResult
    static func tokens(_ item: TurnItem, into parts: inout Self) -> Double {
        let skip: Set<String> = ["id", "threadId", "type", "runId", "nodeId", "providerTurnId", "parentItemId", "ordinal",
                                 "status", "startedAt", "completedAt", "updatedAt", "createdAt", "messageId", "requestId",
                                 "subagentId", "childThreadId", "providerInstanceId", "driver", "origin", "inputIntent", "attachments"]
        func text(_ s: String?) -> Double { Double(s?.utf8.count ?? 0) / bytesPerToken }
        func leaves(_ v: JSONValue?) -> Double {
            switch v {
            case .string(let s): return text(s)
            case .number: return 1
            case .array(let a): return a.reduce(0) { $0 + leaves($1) }
            case .object(let o): return o.reduce(0) { $0 + (skip.contains($1.key) ? 0 : text($1.key) + leaves($1.value)) }
            default: return 0
            }
        }
        func attachments() {
            for a in item["attachments"]?.arrayValue ?? [] {
                if a["type"]?.stringValue == "image" {
                    parts.images += imageTokens
                } else if a["source"]?["_tag"]?.stringValue == "pasted-text" {
                    parts.messages += (a["sizeBytes"]?.doubleValue ?? 0) / bytesPerToken
                } else {
                    parts.images += fileTokens
                }
            }
        }
        switch item.type {
        case .userMessage:
            parts.messages += text(item.text) + leaves(item["context"])
            attachments()
        case .assistantMessage:
            parts.replies += text(item.text)
            attachments()
        case .proposedPlan:
            parts.replies += leaves(item.raw)
        case .compaction, .handoff:
            parts.replies += text(item.string("summary"))
        case .reasoning:
            return text(item.text)
        case .commandExecution, .fileChange, .fileSearch, .webSearch, .dynamicTool, .subagent, .todoList,
             .userInputRequest, .approvalRequest:
            parts.tools += leaves(item.raw)
            if item.string("viewedImagePath") != nil { parts.images += imageTokens }
        default:
            break
        }
        return 0
    }
}
