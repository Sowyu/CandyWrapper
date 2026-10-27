import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// One thing the Orchestrator chat shows (docs/orchestrator.md, "The chat looks like iMessage").
public enum OrchestratorChatItem: Equatable, Sendable {
    /// A centred time label where more than 15 minutes pass between messages.
    case time(id: String, label: String)
    /// The brief, collapsed into a card.
    case brief(id: String, text: String, updated: Bool)
    /// A small centred line: an event, the tools a turn used, a scheduled check. Clicking it opens `threadId`.
    case line(id: String, text: String, threadId: String?)
    /// An image you sent, drawn on its own like a photo in Messages.
    case image(id: String, attachmentId: String, name: String)
    /// A page the Orchestrator published with `html_render`, shown above its reply as the thread view does.
    case html(id: String, page: HtmlRenderReference)
    /// A chat bubble; `first` and `last` place it in its sender's stack, and only the last gets a tail.
    case bubble(id: String, fromUser: Bool, text: String, first: Bool, last: Bool)
    case plan(id: String, steps: [OrchestratorReply.PlanStep])
    /// The notes a reply saved, with Undo.
    case memory(id: String, messageId: String, notes: [String])
    /// "Read" under your last message once the Orchestrator's turn started.
    case read(id: String)
    /// Three dots while its turn runs.
    case typing

    public var id: String {
        switch self {
        case .time(let id, _), .brief(let id, _, _), .line(let id, _, _), .bubble(let id, _, _, _, _), .plan(let id, _),
             .memory(let id, _, _), .read(let id), .image(let id, _, _), .html(let id, _): id
        case .typing: "typing"
        }
    }
}

public enum OrchestratorChat {
    static let timeGapMs: Int64 = 15 * 60_000
    static let scheduledPrefix = "Scheduled check:"

    /// The chat for the Orchestrator thread's messages. `running` is whether its turn runs now. The activity lines (events,
    /// relay results, the tools a turn used, scheduled checks, digest updates) show only with `activity`, and replies
    /// that only say nothing is new never show: its harness makes it write something every turn.
    ///
    /// Runs that failed in a row on the same provider error show as one quiet line instead of an error reply each
    /// (`failureGroups`). `waiting` is how many events the app holds back while the provider is limited, and `provider`
    /// names it, like "Claude".
    public static func items(messages: [ConversationMessage], turnItems: [TurnItem], running: Bool, activity: Bool = false,
                             waiting: Int = 0, provider: String? = nil, now: Date = Date()) -> [OrchestratorChatItem] {
        var out: [OrchestratorChatItem] = []
        var lastMs: Int64?
        var toolLinesShown = Set<String>()
        let tools = toolSummaries(turnItems)
        let images = sentImages(turnItems)
        let pages = htmlPages(turnItems)
        var pagesShown = Set<String>()
        let sorted = messages.sorted { ($0.createdAt.epochMs ?? 0, $0.id.rawValue) < ($1.createdAt.epochMs ?? 0, $1.id.rawValue) }
        var lastUser: (index: Int, ms: Int64)?
        var lastAssistantMs: Int64?
        let failures = failureGroups(sorted, turnItems: turnItems, waiting: waiting, provider: provider, now: now)
        for m in sorted {
            let ms = m.createdAt.epochMs ?? 0
            let mid = m.id.rawValue
            // This message's items, and where your own bubble or image sits among them.
            var mine: [OrchestratorChatItem] = []
            var yours: Int?
            func line(_ id: String, _ text: String, _ thread: String?) { if activity { mine.append(.line(id: id, text: text, threadId: thread)) } }
            switch m.role {
            case _ where failures.quiet.contains(mid):
                if m.role == "assistant" { lastAssistantMs = ms }
            case "user":
                let parts = OrchestratorBrief.split(m.text)
                if let brief = parts.brief { mine.append(.brief(id: "brief-\(mid)", text: brief, updated: parts.updated)) }
                var text = parts.message.trimmingCharacters(in: .whitespacesAndNewlines)
                let sent = images[mid] ?? []
                for (i, image) in sent.enumerated() { mine.append(.image(id: "image-\(mid)-\(i)", attachmentId: image.id, name: image.name)) }
                // T3's stand-in text for a message of images only stays out of the chat.
                if !sent.isEmpty, text == ComposerAttachmentRules.attachmentOnlyPrompt { text = "" }
                if text.isEmpty, !sent.isEmpty { yours = mine.count - 1 }
                guard !text.isEmpty else { break }
                if OrchestratorEventBatch.isEventMessage(text) {
                    for (i, l) in text.split(separator: "\n").enumerated() {
                        let e = eventLine(String(l))
                        line("event-\(mid)-\(i)", e.text, e.threadId)
                    }
                } else if OrchestratorRelay.isResultMessage(text) {
                    // What the relay ran on other machines (docs/orchestrator.md, "Every machine").
                    for (i, summary) in OrchestratorRelay.summaries(text).enumerated() {
                        line("result-\(mid)-\(i)", summary.prefix(1).uppercased() + summary.dropFirst(), nil)
                    }
                } else if text.hasPrefix(scheduledPrefix) {
                    line("scheduled-\(mid)", "Scheduled check while CandyWrapper was closed", nil)
                } else if m.scheduledTaskId != nil {
                    // Any scheduled task bound to its thread, like one it set up itself: the schedule's, not yours.
                    line("scheduled-\(mid)", scheduledLine(text), nil)
                } else if let lines = automaticLines(m, text: text) {
                    // T3's own deliveries, like a delegated task's result, come as user messages but aren't yours.
                    for (i, l) in lines.enumerated() { line("automatic-\(mid)-\(i)", l, nil) }
                } else {
                    mine.append(.bubble(id: mid, fromUser: true, text: text, first: true, last: true))
                    yours = mine.count - 1
                }
            case "assistant":
                lastAssistantMs = ms
                if let run = m.runId?.rawValue, let summary = tools[run], toolLinesShown.insert(run).inserted {
                    line("tools-\(run)", summary, nil)
                }
                // The turn's pages sit above its reply (`HtmlRenderTimelineRow`).
                if let run = m.runId?.rawValue, pagesShown.insert(run).inserted {
                    for (i, page) in (pages[run] ?? []).enumerated() { mine.append(.html(id: "html-\(run)-\(i)", page: page)) }
                }
                let reply = OrchestratorReply.parse(m.text)
                if !reply.text.isEmpty, !OrchestratorReply.isNoop(reply.text) {
                    mine.append(.bubble(id: mid, fromUser: false, text: reply.text, first: true, last: true))
                }
                if let plan = reply.plan, !plan.isEmpty { mine.append(.plan(id: "plan-\(mid)", steps: plan)) }
                if !reply.memories.isEmpty { mine.append(.memory(id: "memory-\(mid)", messageId: mid, notes: reply.memories.map(\.note))) }
                if reply.digest != nil { line("digest-\(mid)", "Digest updated", nil) }
            default:
                break
            }
            // The failure line sits after the group's latest failed run, so it moves down as the group grows.
            if let row = failures.rows[mid] { mine.append(.line(id: row.id, text: row.text, threadId: nil)) }
            // Time labels go between what shows, so hidden activity leaves none behind.
            guard !mine.isEmpty else { continue }
            if lastMs.map({ ms - $0 > timeGapMs }) ?? true { out.append(.time(id: "time-\(mid)", label: timeLabel(ms, now: now))) }
            lastMs = ms
            if let yours { lastUser = (out.count + yours, ms) }
            out += mine
        }
        // A running turn that used tools or published a page before it wrote anything.
        if activity {
            for (run, summary) in tools where !toolLinesShown.contains(run) && running {
                out.append(.line(id: "tools-\(run)", text: summary, threadId: nil))
            }
        }
        for (run, list) in pages where !pagesShown.contains(run) {
            for (i, page) in list.enumerated() { out.append(.html(id: "html-\(run)-\(i)", page: page)) }
        }
        if let lastUser, running || (lastAssistantMs ?? 0) >= lastUser.ms {
            out.insert(.read(id: "read"), at: lastUser.index + 1)
        }
        if running { out.append(.typing) }
        return stacked(out)
    }

    /// A provider error a run ended with: T3's root `error` item (`latestRootProviderFailure`, orchestrationV2ThreadError.ts:8-32).
    struct RunFailure {
        var errorClass: String
        var message: String
        var resetAt: Date?
        var at: Date?
    }

    /// Each failed run's provider error, by run id.
    static func runFailures(_ items: [TurnItem]) -> [String: RunFailure] {
        var out: [String: RunFailure] = [:]
        for item in items where item.type == .error && item.status == .failed && item.parentItemId == nil {
            guard let run = item.runId?.rawValue, let failure = item["failure"] else { continue }
            out[run] = RunFailure(errorClass: failure["class"]?.stringValue ?? "unknown", message: failure["message"]?.stringValue ?? "",
                                  resetAt: failure["resetAt"]?.stringValue.flatMap { T3Timestamp($0).date }, at: item.updatedAt.date)
        }
        return out
    }

    /// Runs that failed in a row on the same error collapse into one line, "Claude limit reached · resets 8pm · 12 updates
    /// waiting". The events, checks and results that woke those runs and the error replies stay out of the chat (`quiet`);
    /// your own messages still show. The line keeps the id of the group's first run, so it updates in place, and sits
    /// after the group's latest message (`rows`). A real reply or a different error starts over.
    static func failureGroups(_ sorted: [ConversationMessage], turnItems: [TurnItem], waiting: Int, provider: String?,
                              now: Date) -> (quiet: Set<String>, rows: [String: (id: String, text: String)]) {
        let failures = runFailures(turnItems)
        guard !failures.isEmpty else { return ([], [:]) }
        var quiet = Set<String>()
        var rows: [String: (id: String, text: String)] = [:]
        var group: (id: String, key: String, failure: RunFailure, runs: Set<String>, updates: Int, last: String)?
        func close(waiting: Int = 0) {
            guard let g = group else { return }
            rows[g.last] = (g.id, failureLine(g.failure, runs: g.runs.count, updates: g.updates + waiting, provider: provider, now: now))
            group = nil
        }
        for m in sorted {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let run = m.runId?.rawValue, let failure = failures[run] else {
                // A reply from a run that didn't fail ends the group.
                if m.role == "assistant", !text.isEmpty, !OrchestratorReply.isNoop(OrchestratorReply.parse(text).text) { close() }
                continue
            }
            let key = failure.errorClass + "|" + failure.message
            if m.role == "assistant" {
                // Text the run wrote before it failed is a real reply; the provider's error text isn't.
                let isError = text.isEmpty || text == failure.message || failure.message.contains(text) || text.contains(failure.message)
                    || (failure.errorClass == "usage_limit" && OrchestratorLimit.isLimit(nil, message: text))
                guard isError else { close(); continue }
                quiet.insert(m.id.rawValue)
            } else if m.role != "user" {
                continue
            }
            if group?.key != key { close(); group = ("failure-\(run)", key, failure, [], 0, m.id.rawValue) }
            group?.runs.insert(run)
            group?.failure = failure
            group?.last = m.id.rawValue
            if m.role == "user", let updates = wakeUps(m, text: text) {
                quiet.insert(m.id.rawValue)
                group?.updates += updates
            }
        }
        close(waiting: waiting)
        return (quiet, rows)
    }

    /// How many updates a message that woke the Orchestrator carried, or nil for one you wrote: each event line, a relay
    /// result, a scheduled check or one of T3's own deliveries.
    static func wakeUps(_ m: ConversationMessage, text: String) -> Int? {
        if OrchestratorEventBatch.isEventMessage(text) { return text.split(separator: "\n", omittingEmptySubsequences: true).count }
        if OrchestratorRelay.isResultMessage(text) || text.hasPrefix(scheduledPrefix) || m.scheduledTaskId != nil { return 1 }
        return automaticLines(m, text: text)?.count
    }

    /// "Claude limit reached · resets 8pm · 12 updates waiting", or "Claude error: overloaded · 3 runs".
    static func failureLine(_ f: RunFailure, runs: Int, updates: Int, provider: String?, now: Date) -> String {
        var parts: [String]
        if f.errorClass == "usage_limit" || OrchestratorLimit.isLimit(nil, message: f.message) {
            parts = ["\(provider ?? "Usage") limit reached"]
            if let reset = f.resetAt ?? OrchestratorLimit.resetTime(in: f.message, after: f.at ?? now) {
                parts.append("resets " + OrchestratorLimit.shortTime(reset, now: now))
            }
        } else {
            let first = f.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let cut = first.count > 80 ? String(first.prefix(80)) + "…" : first
            parts = ["\(provider ?? "Provider") error" + (cut.isEmpty ? "" : ": " + cut)]
            if runs > 1 { parts.append("\(runs) runs") }
        }
        if updates > 0 { parts.append(updates == 1 ? "1 update waiting" : "\(updates) updates waiting") }
        return parts.joined(separator: " · ")
    }

    /// The Orchestrator thread's conversation by message id. T3's snapshot holds only the messages of its last 75 rows
    /// (threadHistoryPaging.ts:13-17, 407-445), so on its own a fresh snapshot, after a reconnect or reopening the pane,
    /// drops everything older. This merges, newest source first: the snapshot's messages, the message rows of older
    /// history pages (their items carry the text, as the thread view reads them), and what this session showed before.
    // ponytail: kept messages outlive a thread rollback that removed them; drop `kept` on a rollback if that ever matters
    public static func conversation(_ projection: ThreadProjection, kept: [String: ConversationMessage]) -> [String: ConversationMessage] {
        var out = kept
        for item in projection.turnItems where item.type == .userMessage || item.type == .assistantMessage {
            guard let id = item.messageId else { continue }
            let at = item.startedAt ?? item.updatedAt
            out[id.rawValue] = ConversationMessage(id: id, threadId: item.threadId, runId: item.runId,
                                                   role: item.type == .userMessage ? "user" : "assistant", text: item.text,
                                                   streaming: item.type == .assistantMessage && item.streaming, createdAt: at,
                                                   updatedAt: item.updatedAt, scheduledTaskId: item.string("scheduledTaskId"))
        }
        for m in projection.messages { out[m.id.rawValue] = m }
        return out
    }

    /// Each turn's published pages, in order (`ThreadWebContent.htmlRender`, a completed `html_render` call).
    static func htmlPages(_ items: [TurnItem]) -> [String: [HtmlRenderReference]] {
        var out: [String: [HtmlRenderReference]] = [:]
        for item in items.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard let run = item.runId?.rawValue, let page = ThreadWebContent.htmlRender(item) else { continue }
            out[run, default: []].append(page)
        }
        return out
    }

    /// The images each of your messages carried, from its turn item (`attachments` of type image).
    static func sentImages(_ items: [TurnItem]) -> [String: [(id: String, name: String)]] {
        var out: [String: [(id: String, name: String)]] = [:]
        for item in items where item.type == .userMessage {
            guard let message = item.raw["messageId"]?.stringValue, let list = item.raw["attachments"]?.arrayValue else { continue }
            let images = list.compactMap { a -> (id: String, name: String)? in
                guard a["type"]?.stringValue == "image", let id = a["id"]?.stringValue else { return nil }
                return (id, a["name"]?.stringValue ?? "image")
            }
            if !images.isEmpty { out[message] = images }
        }
        return out
    }

    /// Sets each bubble's place in its stack: bubbles in a row from one sender form a stack.
    static func stacked(_ items: [OrchestratorChatItem]) -> [OrchestratorChatItem] {
        func sender(_ i: Int) -> Bool? {
            guard items.indices.contains(i), case .bubble(_, let user, _, _, _) = items[i] else { return nil }
            return user
        }
        return items.enumerated().map { i, item in
            guard case .bubble(let id, let user, let text, _, _) = item else { return item }
            return .bubble(id: id, fromUser: user, text: text, first: sender(i - 1) != user, last: sender(i + 1) != user)
        }
    }

    /// "Scheduled: Space build check" from a scheduled run's prompt: its first sentence, cut at 60 characters.
    static func scheduledLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let label = first.components(separatedBy: ":").first.flatMap { $0.count <= 60 && $0.count < first.count ? $0 : nil }
            ?? (first.count > 60 ? String(first.prefix(60)) + "…" : first)
        return "Scheduled: " + label.trimmingCharacters(in: .whitespaces)
    }

    /// The activity lines for a message T3 delivered on its own into the thread, like a delegated task's result
    /// ("Delegated task <id> (<title>) [completed]: …", Orchestrator.ts:614-633) or its question
    /// (DelegatedTaskQuestionReactor.ts:38-43), or nil for a message you wrote. T3 marks these with `delegatedCompletion`
    /// or `notification`; the text is the fallback.
    static func automaticLines(_ m: ConversationMessage, text: String) -> [String]? {
        let delegated = text.hasPrefix("Delegated task")
        guard m.delegatedCompletion != nil || m.notification != nil || delegated else { return nil }
        let parsed = text.components(separatedBy: "\n\n").compactMap(delegatedLine)
        if !parsed.isEmpty { return parsed }
        if let summary = m.notification?["summary"]?.stringValue, !summary.isEmpty { return [summary] }
        return ["Delegated task update"]
    }

    /// "“Fixer” finished" from one "Delegated task <id> (<title>) [<status>]…" paragraph.
    static func delegatedLine(_ paragraph: String) -> String? {
        guard let m = paragraph.firstMatch(of: /^Delegated tasks? \S+(?: \((?<title>[^\n]+?)\))?(?: \[(?<status>[a-z_]+)\]| (?<rest>[a-z][^.:\n]*))?/) else { return nil }
        let who = m.output.title.map { "“\($0)”" } ?? "A delegated task"
        let what: String
        switch m.output.status.map(String.init) {
        case "completed": what = "finished"
        case "failed": what = "failed"
        case "cancelled": what = "was cancelled"
        case "interrupted": what = "was interrupted"
        case let other?: what = other
        case nil:
            let rest = m.output.rest.map(String.init) ?? ""
            what = rest.contains("question") ? "has a question" : rest.hasPrefix("reached") ? "finished" : (rest.isEmpty ? "finished" : rest)
        }
        return "\(who) \(what)"
    }

    /// "“Release notes” finished a turn" and the thread it names, from an event line.
    static func eventLine(_ line: String) -> (text: String, threadId: String?) {
        var text = line.hasPrefix("Event: ") ? String(line.dropFirst(7)) : line
        var thread: String?
        // Thread ids may hold a colon: threads T3's tools launch are `mcp:<uuid>`.
        if let r = text.range(of: #" \(t3-thread://v1/([A-Za-z0-9_:.-]+)\)\.?"#, options: .regularExpression) {
            thread = String(text[r].drop { $0 != "/" }.dropFirst("//v1/".count).prefix { $0 != ")" })
            text = String(text[..<r.lowerBound])
        }
        return (text, thread)
    }

    /// Per run, "Used 3 tools: t3_thread_launch, t3_thread_send" for the work items between its messages.
    static func toolSummaries(_ items: [TurnItem]) -> [String: String] {
        let quiet: Set<TurnItemType> = [.userMessage, .assistantMessage, .reasoning, .checkpoint, .threadCreated, .systemNotice, .notification]
        var byRun: [String: [String]] = [:]
        for item in items where !quiet.contains(item.type) {
            guard let run = item.runId?.rawValue else { continue }
            byRun[run, default: []].append(item.title ?? item.type.rawValue.replacingOccurrences(of: "_", with: " "))
        }
        return byRun.mapValues { names in
            var unique: [String] = []
            for n in names where !unique.contains(n) { unique.append(n) }
            let shown = unique.prefix(2).joined(separator: ", ") + (unique.count > 2 ? "…" : "")
            return names.count == 1 ? "Used 1 tool: \(shown)" : "Used \(names.count) tools: \(shown)"
        }
    }

    static func timeLabel(_ ms: Int64, now: Date) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if Calendar.current.isDate(date, inSameDayAs: now) { f.dateFormat = "'Today' h:mm a" }
        else if Calendar.current.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) { f.dateFormat = "'Yesterday' h:mm a" }
        else { f.dateFormat = "EEE, MMM d 'at' h:mm a" }
        return f.string(from: date)
    }
}

/// Markdown for chat bubbles: paragraphs, headings, lists, quotes, code and links as one attributed string.
@MainActor
enum OrchestratorChatText {
    static func attributed(_ markdown: String, color: NSColor, linkColor: NSColor, size: CGFloat = 14) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = DSFont.ui(size)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        para.paragraphSpacing = 6
        func runs(_ runs: [InlineRun], font base: NSFont) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for r in runs {
                var font = base
                if r.code { font = DSFont.mono(size - 1) }
                if r.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if r.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
                if let link = r.link { attrs[.link] = link; attrs[.foregroundColor] = linkColor; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if r.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                s.append(NSAttributedString(string: r.text, attributes: attrs))
            }
            return s
        }
        func newline() { if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: para])) } }
        func block(_ b: MarkdownBlock, indent: String = "") {
            switch b {
            case .paragraph(let r):
                newline()
                if !indent.isEmpty { out.append(NSAttributedString(string: indent, attributes: [.font: body, .foregroundColor: color])) }
                out.append(runs(r, font: body))
            case .heading(_, let r):
                newline()
                out.append(runs(r, font: DSFont.ui(size, weight: .semibold)))
            case .list(let list):
                for (i, item) in list.items.enumerated() {
                    let marker = list.ordered ? "\(list.start + i). " : "• "
                    for (j, inner) in item.blocks.enumerated() { block(inner, indent: indent + (j == 0 ? marker : "   ")) }
                }
            case .blockquote(let inner), .alert(_, let inner):
                for i in inner { block(i, indent: indent + "▎ ") }
            case .code(_, _, let code):
                newline()
                out.append(NSAttributedString(string: code, attributes: [.font: DSFont.mono(size - 1), .foregroundColor: color, .paragraphStyle: para]))
            case .table(let t):
                newline()
                let rows = [t.header] + t.rows
                out.append(NSAttributedString(string: rows.map { $0.map { $0.map(\.text).joined() }.joined(separator: "  ·  ") }.joined(separator: "\n"),
                                              attributes: [.font: body, .foregroundColor: color, .paragraphStyle: para]))
            case .rule:
                newline()
                out.append(NSAttributedString(string: "———", attributes: [.font: body, .foregroundColor: color.withAlphaComponent(0.5)]))
            case .image(let alt, _):
                newline()
                out.append(NSAttributedString(string: alt, attributes: [.font: body, .foregroundColor: color]))
            case .math(let math):
                newline()
                out.append(NSAttributedString(string: math.copySource, attributes: [.font: DSFont.mono(size - 1), .foregroundColor: color, .paragraphStyle: para]))
            }
        }
        for b in MarkdownDocument(parsing: markdown).blocks { block(b) }
        return out
    }
}
