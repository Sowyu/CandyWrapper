import Foundation

/// Inline grammar from composer-rich-text.ts:18-152. Offsets use UTF-16 like T3.
enum ComposerRichText {
    enum Mark: String, CaseIterable { case strike, bold, italic, code
        var delimiter: String { switch self { case .strike: "~~"; case .bold: "**"; case .italic: "*"; case .code: "`" } }
    }
    struct Span: Equatable {
        var text: String
        var marks: [Mark]
        var atomic = false
    }
    private struct Frame { var delimiter: String; var mark: Mark; var spans: [Span] = [] }

    /// `typing` false reads a whole draft, as `buildTiptapContent` does, where `_x_` is italic. Typing
    /// and pasting keep a single `_` literal: the composer's italic rules only take `*`, so names like
    /// `node_modules` or `_build_` stay as typed (composer-rich-text-doc.ts:136-148, bb76f1233c).
    static func parse(_ text: String, typing: Bool = false) -> [Span] {
        let units = Array(text.utf16)
        var root: [Span] = [], stack: [Frame] = []
        func slice(_ a: Int, _ b: Int) -> String { String(decoding: units[a..<min(b, units.count)], as: UTF16.self) }
        func push(_ text: String, _ marks: [Mark]) {
            guard !text.isEmpty else { return }
            if stack.isEmpty {
                if root.last?.marks == marks { root[root.count - 1].text += text }
                else { root.append(Span(text: text, marks: marks)) }
            } else {
                let n = stack.count - 1
                if stack[n].spans.last?.marks == marks { stack[n].spans[stack[n].spans.count - 1].text += text }
                else { stack[n].spans.append(Span(text: text, marks: marks)) }
            }
        }
        func whitespace(_ i: Int) -> Bool {
            i >= 0 && i < units.count && UnicodeScalar(units[i]).map { CharacterSet.whitespacesAndNewlines.contains($0) } == true
        }
        func word(_ i: Int) -> Bool {
            guard i >= 0, i < units.count else { return false }
            let c = units[i]
            return (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95
        }
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == 92 {
                let count = i + 2 < units.count && (0xD800...0xDBFF).contains(units[i + 1]) ? 3 : 2
                push(slice(i, i + count), []); i += min(count, units.count - i); continue
            }
            if c == 96 {
                var end = i + 1
                while end < units.count, units[end] == c { end += 1 }
                let run = slice(i, end)
                let rest = text as NSString
                let close = rest.range(of: run, range: NSRange(location: end, length: units.count - end))
                if end == i + 1, close.location != NSNotFound, close.location > end,
                   !slice(i, close.location).contains("\n"),
                   close.location + 1 == units.count || units[close.location + 1] != 96 {
                    push(slice(end, close.location), [.code]); i = close.location + 1
                } else { push(run, []); i = end }
                continue
            }
            if c != 42 && c != 95 && c != 126 {
                // Keep surrogate pairs together when appending literal text.
                var end = i + 1
                while end < units.count, ![92, 96, 42, 95, 126].contains(units[end]) { end += 1 }
                push(slice(i, end), []); i = end; continue
            }
            var end = i
            while end < units.count, units[end] == c { end += 1 }
            let canClose = i > 0 && !whitespace(i - 1) && (c != 95 || !word(end))
            let canOpen = end < units.count && !whitespace(end) && (c != 95 || !word(i - 1))
            while i < end {
                let top = stack.last
                let nestedBold = top?.mark == .italic && end - i == 2 && canOpen && (c == 42 || c == 95) && !stack.contains { $0.mark == .bold }
                if !nestedBold, canClose, let top,
                   slice(i, min(end, i + top.delimiter.utf16.count)) == top.delimiter {
                    stack.removeLast()
                    for span in top.spans { push(span.text, [top.mark] + span.marks) }
                    i += top.delimiter.utf16.count
                } else if canOpen && (c != 126 || end - i >= 2) {
                    let length = c == 126 || end - i >= 2 ? 2 : 1
                    if typing, c == 95, length == 1 { push(slice(i, end), []); i = end; continue }
                    let mark: Mark = c == 126 ? .strike : length == 2 ? .bold : .italic
                    if stack.contains(where: { $0.mark == mark }) { push(slice(i, end), []); i = end; continue }
                    stack.append(Frame(delimiter: slice(i, i + length), mark: mark)); i += length
                } else { push(slice(i, end), []); i = end }
            }
        }
        while let frame = stack.popLast() {
            push(frame.delimiter, [])
            for span in frame.spans { push(span.text, span.marks) }
        }
        return root
    }

    /// composer-rich-text-doc.ts:849-976: trim boundary whitespace and keep the
    /// longest shared marks outside shorter marks, including across context chips.
    static func serialize(_ input: [Span]) -> String { mapping(input).value }
    struct Mapping { var value: String; var offsets: [Int] }
    static func mapping(_ input: [Span]) -> Mapping {
        var spans: [Span] = []
        for span in input {
            if span.atomic || span.marks.contains(.code) { spans.append(span); continue }
            // Newlines always close inline marks.
            var current = "", whitespace: Bool?
            func flush() { if !current.isEmpty { spans.append(Span(text: current, marks: span.marks)); current = "" } }
            for c in span.text {
                if c == "\n" { flush(); spans.append(Span(text: "\n", marks: [])); whitespace = nil; continue }
                if whitespace != nil && whitespace != c.isWhitespace { flush() }
                whitespace = c.isWhitespace; current.append(c)
            }
            flush()
        }
        for mark in Mark.allCases where mark != .code {
            for reverse in [false, true] {
                var content = false
                let indices = reverse ? Array(spans.indices.reversed()) : Array(spans.indices)
                for i in indices {
                    if !spans[i].marks.contains(mark) { content = false }
                    else if !spans[i].marks.contains(.code) && spans[i].text.allSatisfy(\.isWhitespace) {
                        if !content { spans[i].marks.removeAll { $0 == mark } }
                    } else { content = true }
                }
            }
        }
        var ends: [Mark: Int] = [:], ordered = Array(repeating: [Mark](), count: spans.count)
        for i in spans.indices.reversed() {
            for mark in Mark.allCases {
                if !spans[i].marks.contains(mark) { ends[mark] = nil }
                else if ends[mark] == nil { ends[mark] = i }
            }
            ordered[i] = Mark.allCases.filter { spans[i].marks.contains($0) }.sorted {
                if ends[$0] != ends[$1] { return ends[$0]! > ends[$1]! }
                return Mark.allCases.firstIndex(of: $0)! < Mark.allCases.firstIndex(of: $1)!
            }
        }
        if ordered.count > 1 {
            for i in 1..<ordered.count {
                let kept = ordered[i - 1].prefix { ordered[i].contains($0) }
                ordered[i] = Array(kept) + ordered[i].filter { !kept.contains($0) }
            }
        }
        func common(_ a: [Mark], _ b: [Mark]) -> Int { zip(a, b).prefix { $0 == $1 }.count }
        var value = "", offsets = [0], sourceOffset = 0
        for i in spans.indices {
            let marks = ordered[i]
            let before = i == 0 ? [] : ordered[i - 1], after = i + 1 == spans.count ? [] : ordered[i + 1]
            let open = marks.dropFirst(common(marks, before)).map(\.delimiter).joined()
            let close = marks.dropFirst(common(marks, after)).reversed().map(\.delimiter).joined()
            value += open + spans[i].text + close
            sourceOffset += open.utf16.count
            // A run's start owns its edge, after its opening markers (`runOwnsOffset`):
            // the caret before `**bold**` lands inside the bold, the one after it past `**`.
            offsets[offsets.count - 1] = sourceOffset
            if spans[i].atomic {
                sourceOffset += spans[i].text.utf16.count
                offsets.append(sourceOffset)
            } else {
                for _ in spans[i].text.utf16 { sourceOffset += 1; offsets.append(sourceOffset) }
            }
            sourceOffset += close.utf16.count
            offsets[offsets.count - 1] = sourceOffset
        }
        return Mapping(value: value, offsets: offsets)
    }
}

/// composer-list-continuation.ts:29-179. Kept separate from rendering so source mode
/// and rich mode use the same marker grammar and UTF-16 edit coordinates.
enum ComposerListContinuation {
    /// `renumber`: number replacements on the ordered items after the new one, in the original text.
    struct Edit: Equatable { var range: NSRange; var replacement: String; var renumber: [Renumber] = [] }
    struct Renumber: Equatable { var range: NSRange; var number: String }
    static func nextOrderedMarker(_ marker: String) -> String {
        let digits = String(marker.dropLast())
        guard let n = UInt64(digits), n <= 9_007_199_254_740_991 else { return marker }
        let next = String(n + 1)
        return String(repeating: "0", count: max(0, digits.count - next.count)) + next + marker.suffix(1)
    }
    /// A list item's marker, compiled once: `edit` runs on every Return and Tab in the composer.
    nonisolated(unsafe) private static let listMarker = try! NSRegularExpression(pattern: #"^([ \t]*)(-\s\[[ xX]\]|\d+[.)]|[-*+])([ \t]+|$)"#)

    static func edit(_ text: String, selection: NSRange, indent: Bool = false) -> Edit? {
        let value = text as NSString
        guard selection.length == 0, selection.location <= value.length else { return nil }
        let cursor = selection.location
        if ComposerInlineTokens.collect(text).contains(where: { cursor > $0.range.location && cursor < NSMaxRange($0.range) }) { return nil }
        let before = value.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cursor))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let after = value.range(of: "\n", range: NSRange(location: cursor, length: value.length - cursor))
        let end = after.location == NSNotFound ? value.length : after.location
        let line = value.substring(with: NSRange(location: start, length: end - start)) as NSString
        guard let match = listMarker.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return nil }
        if indent { return Edit(range: NSRange(location: start, length: 0), replacement: "  ") }
        // A bare "2." with no space after it is not an item yet: Return adds a line
        // (composer-list-continuation.ts:156, bac96aa3b2).
        guard match.range(at: 3).length > 0 else { return nil }
        guard cursor >= start + match.range.length else { return nil }
        if line.substring(from: match.range.length).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Edit(range: NSRange(location: start, length: cursor - start), replacement: "")
        }
        let prefix = line.substring(with: match.range(at: 1)), marker = line.substring(with: match.range(at: 2))
        let ordered = marker.last == "." || marker.last == ")"
        let next = marker.contains("[") ? "- [ ]" : ordered ? nextOrderedMarker(marker) : marker
        let renumber = ordered ? renumberFollowing(value, after: end, indent: prefix, marker: marker) : []
        return Edit(range: selection, replacement: "\n" + prefix + next + " ", renumber: renumber)
    }

    /// Markdown tabs advance to the next four-column stop.
    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width += 4 - width % 4 } else { break }
        }
        return width
    }

    /// `renumberFollowingItems` (composer-list-continuation.ts:79-122): the same-level ordered items
    /// after the split line count on from the inserted one, until a blank line, a shallower line or
    /// another kind of item. Deeper lines are skipped; a newline inside a chip starts no item.
    private static func renumberFollowing(_ value: NSString, after lineEnd: Int, indent: String, marker: String) -> [Renumber] {
        guard var expected = UInt64(marker.dropLast()).map({ $0 + 2 }) else { return [] }
        let delimiter = marker.suffix(1), base = indentWidth(indent)
        let tokens = ComposerInlineTokens.collect(value as String)
        var result: [Renumber] = [], position = lineEnd
        while position < value.length, expected <= 9_007_199_254_740_991 {
            let lineStart = position + 1
            let next = value.range(of: "\n", range: NSRange(location: lineStart, length: value.length - lineStart))
            let end = next.location == NSNotFound ? value.length : next.location
            position = end
            if tokens.contains(where: { $0.range.location < lineStart && NSMaxRange($0.range) > lineStart }) { continue }
            let line = value.substring(with: NSRange(location: lineStart, length: end - lineStart))
            let width = indentWidth(line)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || width < base { break }
            if width > base { continue }
            guard let m = listMarker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { break }
            let current = (line as NSString).substring(with: m.range(at: 2))
            guard current.last.map(String.init) == String(delimiter), current.dropLast().allSatisfy(\.isNumber) else { break }
            let digits = String(current.dropLast())
            let replacement = digits.hasPrefix("0")
                ? String(repeating: "0", count: max(0, digits.count - String(expected).count)) + String(expected) : String(expected)
            if replacement != digits {
                result.append(Renumber(range: NSRange(location: lineStart + m.range(at: 2).location, length: digits.utf16.count),
                                       number: replacement))
            }
            expected += 1
        }
        return result
    }
}
