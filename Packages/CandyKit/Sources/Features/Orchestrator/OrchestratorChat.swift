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
             .memory(let id, _, _), .read(let id): id
        case .typing: "typing"
        }
    }
}

public enum OrchestratorChat {
    static let timeGapMs: Int64 = 15 * 60_000
    static let scheduledPrefix = "Scheduled check:"

    /// The chat for the Orchestrator thread's messages. `running` is whether its turn runs now.
    public static func items(messages: [ConversationMessage], turnItems: [TurnItem], running: Bool, now: Date = Date()) -> [OrchestratorChatItem] {
        var out: [OrchestratorChatItem] = []
        var lastMs: Int64?
        var toolLinesShown = Set<String>()
        let tools = toolSummaries(turnItems)
        let sorted = messages.sorted { ($0.createdAt.epochMs ?? 0, $0.id.rawValue) < ($1.createdAt.epochMs ?? 0, $1.id.rawValue) }
        var lastUser: (index: Int, ms: Int64)?
        var lastAssistantMs: Int64?
        for m in sorted {
            let ms = m.createdAt.epochMs ?? 0
            if lastMs.map({ ms - $0 > timeGapMs }) ?? true { out.append(.time(id: "time-\(m.id.rawValue)", label: timeLabel(ms, now: now))) }
            lastMs = ms
            let mid = m.id.rawValue
            switch m.role {
            case "user":
                let parts = OrchestratorBrief.split(m.text)
                if let brief = parts.brief { out.append(.brief(id: "brief-\(mid)", text: brief, updated: parts.updated)) }
                let text = parts.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if OrchestratorEventBatch.isEventMessage(text) {
                    for (i, line) in text.split(separator: "\n").enumerated() {
                        let e = eventLine(String(line))
                        out.append(.line(id: "event-\(mid)-\(i)", text: e.text, threadId: e.threadId))
                    }
                } else if text.hasPrefix(scheduledPrefix) {
                    out.append(.line(id: "scheduled-\(mid)", text: "Scheduled check while CandyWrapper was closed", threadId: nil))
                } else {
                    out.append(.bubble(id: mid, fromUser: true, text: text, first: true, last: true))
                    lastUser = (out.count - 1, ms)
                }
            case "assistant":
                lastAssistantMs = ms
                if let run = m.runId?.rawValue, let summary = tools[run], toolLinesShown.insert(run).inserted {
                    out.append(.line(id: "tools-\(run)", text: summary, threadId: nil))
                }
                let reply = OrchestratorReply.parse(m.text)
                if !reply.text.isEmpty { out.append(.bubble(id: mid, fromUser: false, text: reply.text, first: true, last: true)) }
                if let plan = reply.plan, !plan.isEmpty { out.append(.plan(id: "plan-\(mid)", steps: plan)) }
                if !reply.memories.isEmpty { out.append(.memory(id: "memory-\(mid)", messageId: mid, notes: reply.memories.map(\.note))) }
                if reply.digest != nil { out.append(.line(id: "digest-\(mid)", text: "Digest updated", threadId: nil)) }
            default:
                continue
            }
        }
        // A running turn that used tools before it wrote anything.
        for (run, summary) in tools where !toolLinesShown.contains(run) && running {
            out.append(.line(id: "tools-\(run)", text: summary, threadId: nil))
        }
        if let lastUser, running || (lastAssistantMs ?? 0) >= lastUser.ms {
            out.insert(.read(id: "read"), at: lastUser.index + 1)
        }
        if running { out.append(.typing) }
        return stacked(out)
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
            }
        }
        for b in MarkdownDocument(parsing: markdown).blocks { block(b) }
        return out
    }
}
