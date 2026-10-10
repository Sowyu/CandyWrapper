import Foundation

/// Terminal-style prompt recall (chat/composerPromptHistory.ts). ArrowUp on an empty composer walks
/// back through the open thread's sent prompts, ArrowDown walks forward and empties the composer
/// past the newest. Per thread, text only, rebuilt from the thread's user messages on each keypress.
public enum PromptHistory {
    public struct Message: Equatable, Sendable {
        public var id: String, isUser: Bool, text: String
        public init(id: String, isUser: Bool, text: String) { self.id = id; self.isUser = isUser; self.text = text }
    }

    public struct Entry: Equatable, Sendable {
        public var id: String, prompt: String
        public init(id: String, prompt: String) { self.id = id; self.prompt = prompt }
    }

    /// The active recall: the entry, and the text put in the composer. Once the composer no longer
    /// matches `recalled`, browsing is over.
    public struct Position: Equatable, Sendable {
        public var entryId: String, recalled: String
        public init(entryId: String, recalled: String) { self.entryId = entryId; self.recalled = recalled }
    }

    public struct Step: Equatable, Sendable {
        public var position: Position?
        public var prompt: String
    }

    public enum Direction: Sendable { case backward, forward }

    static let ultrathinkPrefix = "Ultrathink:\n"
    static let attachmentOnlyPrompt = "[User attached one or more files without additional text. Respond using the conversation context and the attached files.]"
    static let planPrefix = "PLEASE IMPLEMENT THIS PLAN:\n"

    private static let reviewComment = try! NSRegularExpression(pattern: #"<review_comment\b[^>]*>[\s\S]*?</review_comment>"#)
    private static let trailingLegacyContext = try! NSRegularExpression(
        pattern: #"\n*<(terminal_context|element_context|preview_annotation)>\n([\s\S]*?)\n</\1>\s*$"#)
    private static let contextLink = try! NSRegularExpression(pattern: #"(!?)\[([^\]\n]{0,256})\]\((t3-context:[^\s)]{1,200})\)"#)

    /// `recallableComposerPrompt`: the text the user typed, without send-time appends.
    public static func recallable(_ messageText: String) -> String {
        var prompt = messageText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        if prompt.hasPrefix(ultrathinkPrefix) { prompt = prompt.substring(from: (ultrathinkPrefix as NSString).length) as NSString }

        while prompt.length > 0 {
            let withoutReviews = stripTrailingReviewComments(prompt)
            if withoutReviews != prompt { prompt = withoutReviews; continue }
            if let legacy = trailingLegacyContext.firstMatch(in: prompt as String, range: NSRange(location: 0, length: prompt.length)) {
                let tag = prompt.substring(with: legacy.range(at: 1)), body = prompt.substring(with: legacy.range(at: 2))
                if tag == "preview_annotation", matches(#"(?m)^<preview_annotation>\s*$"#, body),
                   !matches(#"(?m)^(?:Id|Page|Comment|Targets): "#, body) { break }
                let headers = captures(#"(?m)^- (.+):$"#, body)
                if tag != "preview_annotation", headers.isEmpty { break }
                prompt = trimEnd(prompt.substring(to: legacy.range.location))
                if tag == "terminal_context" { prompt = stripInlineTerminalLabels(prompt, headers) }
                continue
            }
            break
        }

        // Text only: canonical context links lose their chip, so drop them with one space beside.
        // ponytail: matches any t3-context link without parseComposerContextHref's validation; port it with mention chips
        for match in contextLink.matches(in: prompt as String, range: NSRange(location: 0, length: prompt.length)).reversed() {
            var start = match.range.location, end = NSMaxRange(match.range)
            if end < prompt.length, prompt.substring(with: NSRange(location: end, length: 1)) == " " { end += 1 }
            else if start > 0, prompt.substring(with: NSRange(location: start - 1, length: 1)) == " " { start -= 1 }
            prompt = (prompt.substring(to: start) + prompt.substring(from: end)) as NSString
        }

        let trimmed = (prompt as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == attachmentOnlyPrompt || trimmed.hasPrefix(planPrefix) { return "" }
        return trimmed
    }

    /// Cuts the run of review comment blocks at the very end, leaving earlier ones byte for byte.
    private static func stripTrailingReviewComments(_ prompt: NSString) -> NSString {
        var cut = prompt.length
        for match in reviewComment.matches(in: prompt as String, range: NSRange(location: 0, length: prompt.length)).reversed() {
            let blockEnd = NSMaxRange(match.range)
            let between = prompt.substring(with: NSRange(location: blockEnd, length: max(0, cut - blockEnd)))
            if !between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            cut = match.range.location
        }
        return cut == prompt.length ? prompt : trimEnd(prompt.substring(to: cut))
    }

    /// Each `Terminal 1 lines 12-13` header removes the first whole `@terminal-1:12-13` label and one space beside it.
    private static func stripInlineTerminalLabels(_ prompt: NSString, _ headers: [String]) -> NSString {
        var result = prompt
        for header in headers {
            guard let m = firstCaptures(#"^(.+?) lines? (\d+(?:-\d+)?)$"#, header) else { continue }
            let name = m[0].trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            let label = "@\(name):\(m[1])"
            let pattern = #"(?<![\w@.-])"# + NSRegularExpression.escapedPattern(for: label) + #"(?![\d-])"#
            guard let found = try? NSRegularExpression(pattern: pattern)
                .firstMatch(in: result as String, range: NSRange(location: 0, length: result.length)) else { continue }
            var start = found.range.location, end = NSMaxRange(found.range)
            if end < result.length, result.substring(with: NSRange(location: end, length: 1)) == " " { end += 1 }
            else if start > 0, result.substring(with: NSRange(location: start - 1, length: 1)) == " " { start -= 1 }
            result = (result.substring(to: start) + result.substring(from: end)) as NSString
        }
        return result
    }

    private static func trimEnd(_ s: String) -> NSString {
        var s = Substring(s)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s) as NSString
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func captures(_ pattern: String, _ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern), ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func firstCaptures(_ pattern: String, _ s: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern), ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    /// `buildComposerPromptHistoryEntries`: oldest first; consecutive duplicates collapse onto the newest id.
    public static func entries(_ messages: [Message]) -> [Entry] {
        var entries: [Entry] = []
        for message in messages where message.isUser {
            let prompt = recallable(message.text)
            if prompt.isEmpty { continue }
            if entries.last?.prompt == prompt { entries[entries.count - 1] = Entry(id: message.id, prompt: prompt); continue }
            entries.append(Entry(id: message.id, prompt: prompt))
        }
        return entries
    }

    /// `stepComposerPromptHistory`. Nil means the key falls through to caret movement. Backward
    /// starts only from an empty composer and stops at the oldest entry; forward past the newest
    /// empties the composer and ends browsing.
    public static func step(_ direction: Direction, entries: [Entry], position: Position?, currentPrompt: String) -> Step? {
        var active = -1
        if let position, position.recalled == currentPrompt {
            active = entries.firstIndex { $0.id == position.entryId }
                ?? entries.lastIndex { $0.prompt == position.recalled } ?? -1
        }
        switch direction {
        case .backward:
            if active < 0, !currentPrompt.isEmpty { return nil }
            let index = active < 0 ? entries.count - 1 : active - 1
            guard entries.indices.contains(index) else { return nil }
            let entry = entries[index]
            return Step(position: Position(entryId: entry.id, recalled: entry.prompt), prompt: entry.prompt)
        case .forward:
            guard active >= 0 else { return nil }
            guard entries.indices.contains(active + 1) else { return Step(position: nil, prompt: "") }
            let entry = entries[active + 1]
            return Step(position: Position(entryId: entry.id, recalled: entry.prompt), prompt: entry.prompt)
        }
    }
}
