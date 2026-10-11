import Foundation

/// assistantTextSelection.ts:57-88. Positions and context use normalized UTF-16; the quote keeps whitespace.
public struct AssistantSelectionText: Equatable, Sendable {
    public let text: String
    public let start: Int
    public let end: Int
    public let prefix: String
    public let suffix: String

    public static func capture(_ text: String, range: NSRange) -> Self? {
        let source = text as NSString
        guard range.location >= 0, range.length > 0, range.upperBound <= source.length,
              Range(range, in: text) != nil else { return nil }
        func splitsSourcePair(_ offset: Int) -> Bool {
            offset > 0 && offset < source.length && (0xD800...0xDBFF).contains(source.character(at: offset - 1)) && (0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        guard !splitsSourcePair(range.location), !splitsSourcePair(range.upperBound) else { return nil }
        let quote = source.substring(with: range)
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func normalize(_ value: String) -> String { value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
        let normalized = normalize(text) as NSString
        var start = (normalize(source.substring(to: range.location)) as NSString).length
        if range.location > 0,
           normalize(source.substring(with: NSRange(location: range.location - 1, length: 1))) == " ",
           normalize(source.substring(with: NSRange(location: range.location, length: 1))) == " " { start -= 1 }
        let end = (normalize(source.substring(to: range.upperBound)) as NSString).length
        var prefixStart = max(0, start - 32), suffixEnd = min(normalized.length, end + 32)
        func splitsPair(_ offset: Int) -> Bool {
            offset > 0 && offset < normalized.length && (0xD800...0xDBFF).contains(normalized.character(at: offset - 1)) && (0xDC00...0xDFFF).contains(normalized.character(at: offset))
        }
        if splitsPair(prefixStart) { prefixStart += 1 }
        if splitsPair(suffixEnd) { suffixEnd -= 1 }
        return Self(text: quote, start: start, end: end,
                    prefix: normalized.substring(with: NSRange(location: prefixStart, length: start - prefixStart)),
                    suffix: normalized.substring(with: NSRange(location: end, length: suffixEnd - end)))
    }
}

extension ThreadAssistantCitation {
    public static func selection(environmentId: String, threadId: String, messageId: String, selection: AssistantSelectionText) -> Self {
        Self(environmentId: environmentId, threadId: threadId, messageId: messageId, text: selection.text,
             start: selection.start, end: selection.end, prefix: selection.prefix, suffix: selection.suffix)
    }
}
