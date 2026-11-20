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
        let literalRuns = literalUnderscoreRuns(text)
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
        // A word character in any script, `[\p{L}\p{M}\p{N}_]` (#37495): `at` reads the scalar that starts at a
        // unit, `before` the one that ends just before it, so a letter outside the BMP counts whole.
        func word(at i: Int) -> Bool {
            guard i >= 0, i < units.count else { return false }
            if (0xD800...0xDBFF).contains(units[i]), i + 1 < units.count { return Self.isWord(units[i], units[i + 1]) }
            return Self.isWord(units[i], nil)
        }
        func word(before i: Int) -> Bool {
            guard i > 0, i <= units.count else { return false }
            if (0xDC00...0xDFFF).contains(units[i - 1]), i >= 2 { return Self.isWord(units[i - 2], units[i - 1]) }
            return Self.isWord(units[i - 1], nil)
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
            // Underscores inside a URL, path or file name are text (#36363).
            if literalRuns.contains(i) { push(slice(i, end), []); i = end; continue }
            let canClose = i > 0 && !whitespace(i - 1) && (c != 95 || !word(at: end))
            let canOpen = end < units.count && !whitespace(end) && (c != 95 || !word(before: i))
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

    static func isWord(_ a: UInt16, _ b: UInt16?) -> Bool {
        if a == 95 { return true }
        let scalar: Unicode.Scalar? = if let b, (0xD800...0xDBFF).contains(a), (0xDC00...0xDFFF).contains(b) {
            Unicode.Scalar(0x10000 + ((UInt32(a) - 0xD800) << 10) + (UInt32(b) - 0xDC00))
        } else { Unicode.Scalar(a) }
        guard let scalar else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    // Brackets, quotes, commas and Markdown delimiters end a URL or path token; a lone `~` does not.
    nonisolated(unsafe) private static let pathToken = try! NSRegularExpression(pattern: #"(?:[\p{L}\p{N}_/.:@%+=&?#-]|(?<!~)~(?!~))+"#)
    nonisolated(unsafe) private static let fileExtension = try! NSRegularExpression(pattern: #"^\.[a-z][a-z0-9]*(?::\d+){0,2}$"#, options: .caseInsensitive)
    // `_yes_/_no_`: each side of a slash is its own emphasis span, so the word is not a path.
    nonisolated(unsafe) private static let emphasisAlternatives = try! NSRegularExpression(pattern: #"^_[^/]+_(?:/_[^/]+_)+$"#)
    nonisolated(unsafe) private static let pathStart = try! NSRegularExpression(pattern: #"^~?/|[.:]"#)

    /// `literalUnderscoreRuns` (composer-rich-text.ts:35-70 at 4928, #36363, #37495): UTF-16 starts of underscore runs
    /// that belong to a URL, path or file name, not to emphasis. A run ending the token stays a delimiter, so emphasis
    /// wrapped around the token still closes.
    static func literalUnderscoreRuns(_ text: String) -> Set<Int> {
        guard text.contains("_") else { return [] }
        var literal: Set<Int> = []
        let ns = text as NSString
        func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        for match in pathToken.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = Array(ns.substring(with: match.range).utf16)
            func string(_ a: Int, _ b: Int) -> String { String(decoding: token[a..<b], as: UTF16.self) }
            var bodyEnd = token.count
            while bodyEnd > 0, [46, 58, 63].contains(token[bodyEnd - 1]) { bodyEnd -= 1 }
            if matches(emphasisAlternatives, string(0, bodyEnd)) { continue }
            while bodyEnd > 0, token[bodyEnd - 1] == 95 { bodyEnd -= 1 }
            let body = Array(token[0..<bodyEnd])
            let bodyText = string(0, bodyEnd)
            // A slash alone is prose (`and/_or_`); a path also has a dot, a scheme or port, or a root.
            let isPath = body.contains(47) ? matches(pathStart, bodyText)
                : matches(fileExtension, String(decoding: body[(body.lastIndex(of: 46) ?? 0)...], as: UTF16.self))
            guard isPath else { continue }
            var closesInside = false
            var start = body.firstIndex(of: 95)
            while let s = start {
                var end = s
                while end < body.count, body[end] == 95 { end += 1 }
                if s > 0 {
                    literal.insert(match.range.location + s)
                    closesInside = closesInside || !isWord(end < body.count ? body[end] : 32, end + 1 < body.count ? body[end + 1] : nil)
                }
                start = body[end...].firstIndex(of: 95)
            }
            // A leading run could only pair with a run inside the name, as in `__init__.py`.
            if closesInside, body.first == 95 { literal.insert(match.range.location) }
        }
        return literal
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

/// composer-list-continuation.ts at 4928 (#17138, #27016): Enter continues, splits or lifts a list item,
/// Tab nests it at its parent's content column and Shift+Tab lifts it back out. Kept separate from rendering
/// so source mode and rich mode share one marker grammar, in UTF-16 Markdown offsets.
enum ComposerListContinuation {
    /// A replacement in the original text.
    struct Piece: Equatable { var range: NSRange; var text: String }
    /// The pieces, ascending and apart, and the caret in the edited text. T3 returns one replacement that
    /// copies the text between its changes; pieces leave that text, and any chip in it, untouched.
    struct Edit: Equatable {
        var pieces: [Piece]
        var cursorAfter: Int
        func applied(to text: String) -> String {
            let result = NSMutableString(string: text)
            for piece in pieces.reversed() { result.replaceCharacters(in: piece.range, with: piece.text) }
            return result as String
        }
    }

    enum Kind: Equatable { case ordered(number: String, delimiter: String), task, bullet(String) }
    struct Marker: Equatable { var kind: Kind; var indent: String; var space: String }
    struct Parsed { var marker: Marker; var markerEnd: Int; var contentColumn: Int }

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    nonisolated(unsafe) private static let indentPattern = regex(#"^[ \t]*"#)
    nonisolated(unsafe) private static let orderedPattern = regex(#"^(\d+)([.)])((?:[ \t]+)|\s*$)"#)
    nonisolated(unsafe) private static let taskPattern = regex(#"^-(\s)\[[ xX]\]((?:[ \t]+)|\s*$)"#)
    nonisolated(unsafe) private static let bulletPattern = regex(#"^([-*+])((?:[ \t]+)|\s*$)"#)

    /// `parseListMarker`.
    static func parse(_ line: String) -> Parsed? {
        let text = line as NSString
        let indentLength = indentPattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length))?.range.length ?? 0
        let indent = text.substring(to: indentLength)
        let rest = text.substring(from: indentLength)
        let full = NSRange(location: 0, length: (rest as NSString).length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
            m.range(at: i).location == NSNotFound ? "" : (rest as NSString).substring(with: m.range(at: i))
        }
        if let m = orderedPattern.firstMatch(in: rest, range: full) {
            let number = group(m, 1), space = group(m, 3)
            return Parsed(marker: Marker(kind: .ordered(number: number, delimiter: group(m, 2)), indent: indent, space: space),
                          markerEnd: indentLength + m.range.length,
                          contentColumn: contentColumn(indent, markerWidth: number.utf16.count + 1, padding: space))
        }
        // The checkbox is item content, so a task's content starts after "- ".
        if let m = taskPattern.firstMatch(in: rest, range: full) {
            return Parsed(marker: Marker(kind: .task, indent: indent, space: group(m, 2)), markerEnd: indentLength + m.range.length,
                          contentColumn: contentColumn(indent, markerWidth: 1, padding: group(m, 1)))
        }
        if let m = bulletPattern.firstMatch(in: rest, range: full) {
            let space = group(m, 2)
            return Parsed(marker: Marker(kind: .bullet(group(m, 1)), indent: indent, space: space), markerEnd: indentLength + m.range.length,
                          contentColumn: contentColumn(indent, markerWidth: 1, padding: space))
        }
        return nil
    }

    /// CommonMark content follows 1-4 columns of padding; wider padding is code, so the content column sits
    /// one column past the marker.
    private static func contentColumn(_ indent: String, markerWidth: Int, padding: String) -> Int {
        let markerEnd = indentWidth(indent) + markerWidth
        let space = indentWidth(padding, from: markerEnd)
        return markerEnd + (1...4 ~= space ? space : 1)
    }

    private static let maxSafe: UInt64 = 9_007_199_254_740_991

    static func nextOrderedMarker(_ marker: String) -> String {
        let digits = String(marker.dropLast())
        guard let n = UInt64(digits), n < maxSafe else { return marker }
        let next = String(n + 1)
        return String(repeating: "0", count: max(0, digits.count - next.count)) + next + marker.suffix(1)
    }

    private static func nextMarkerText(_ marker: Marker) -> String {
        switch marker.kind {
        case .ordered(let number, let delimiter): marker.indent + nextOrderedMarker(number + delimiter) + " "
        case .task: marker.indent + "- [ ] "
        case .bullet(let bullet): marker.indent + bullet + " "
        }
    }

    /// Markdown tabs advance to the next four-column stop.
    private static func indentWidth(_ line: String, from column: Int = 0) -> Int {
        var width = column
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width += 4 - width % 4 } else { break }
        }
        return width - column
    }

    /// `renumberFollowingItems`: the same-level ordered items after the line count on from `marker` + 2, until a
    /// blank line, a shallower line or another kind of item. Deeper lines are skipped; a newline inside a chip
    /// starts no item.
    private static func renumberFollowing(_ value: NSString, after lineEnd: Int, marker: Marker, tokens: [NSRange]) -> [Piece] {
        guard case .ordered(let number, let delimiter) = marker.kind, let current = UInt64(number), current <= maxSafe - 2 else { return [] }
        var expected = current + 2
        let base = indentWidth(marker.indent)
        var pieces: [Piece] = [], position = lineEnd
        while position < value.length, expected <= maxSafe {
            let lineStart = position + 1
            let next = value.range(of: "\n", range: NSRange(location: lineStart, length: value.length - lineStart))
            let end = next.location == NSNotFound ? value.length : next.location
            position = end
            if tokens.contains(where: { $0.location < lineStart && NSMaxRange($0) > lineStart }) { continue }
            let line = value.substring(with: NSRange(location: lineStart, length: end - lineStart))
            let width = indentWidth(line)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || width < base { break }
            if width > base { continue }
            guard let parsed = parse(line), case .ordered(let digits, let d) = parsed.marker.kind, d == delimiter else { break }
            let replacement = digits.hasPrefix("0")
                ? String(repeating: "0", count: max(0, digits.count - String(expected).count)) + String(expected) : String(expected)
            if replacement != digits {
                pieces.append(Piece(range: NSRange(location: lineStart + parsed.marker.indent.utf16.count, length: digits.utf16.count), text: replacement))
            }
            expected += 1
        }
        return pieces
    }

    private static func currentLine(_ value: NSString, _ cursor: Int) -> (start: Int, end: Int, text: String) {
        let before = value.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cursor))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let after = value.range(of: "\n", range: NSRange(location: cursor, length: value.length - cursor))
        let end = after.location == NSNotFound ? value.length : after.location
        return (start, end, value.substring(with: NSRange(location: start, length: end - start)))
    }

    /// `listMarkersAbove`: the list items above the line, nearest first, up to the first line that isn't one.
    private static func markersAbove(_ value: NSString, lineStart: Int, tokens: [NSRange]) -> [Parsed] {
        var result: [Parsed] = []
        var lineStart = lineStart, tokenIndex = tokens.count - 1
        func lineBegin(before index: Int) -> Int {
            let found = value.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: max(0, index)))
            return found.location == NSNotFound ? 0 : found.location + 1
        }
        while lineStart > 0 {
            let lineEnd = lineStart - 1
            lineStart = lineBegin(before: lineEnd)
            // A newline inside a chip does not start a list item.
            while tokenIndex >= 0 {
                let token = tokens[tokenIndex]
                if token.location >= lineStart { tokenIndex -= 1 }
                else if NSMaxRange(token) > lineStart { lineStart = lineBegin(before: token.location) }
                else { break }
            }
            guard let parsed = parse(value.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))) else { break }
            result.append(parsed)
        }
        return result
    }

    private static func parent(_ value: NSString, lineStart: Int, marker: Marker, tokens: [NSRange]) -> Marker? {
        let width = indentWidth(marker.indent)
        return markersAbove(value, lineStart: lineStart, tokens: tokens).first { indentWidth($0.marker.indent) < width }?.marker
    }

    /// `nestedNumber`: an ordered item continues its new siblings' numbering, else starts at 1.
    private static func nestedNumber(_ marker: Marker, previous: Marker?) -> (replaced: Int, text: String) {
        guard case .ordered(let number, let delimiter) = marker.kind else { return (0, "") }
        if case .ordered(let prev, let d)? = previous?.kind, d == delimiter {
            return (number.utf16.count, String(nextOrderedMarker(prev + delimiter).dropLast()))
        }
        return (number.utf16.count, "1")
    }

    private static func tokens(_ text: String) -> [NSRange] { ComposerInlineTokens.collect(text).map(\.range) }

    /// `listContinuationForEnter`.
    static func enter(_ text: String, cursor: Int) -> Edit? {
        let value = text as NSString
        guard cursor >= 0, cursor <= value.length else { return nil }
        let line = currentLine(value, cursor)
        // A bare "2." with no space after it is not an item yet: Return adds a line (bac96aa3b2).
        guard let parsed = parse(line.text), !parsed.marker.space.isEmpty else { return nil }
        let markerEnd = line.start + parsed.markerEnd
        guard cursor >= markerEnd else { return nil }
        let tokens = tokens(text)
        if tokens.contains(where: { cursor > $0.location && cursor < NSMaxRange($0) }) { return nil }
        if value.substring(with: NSRange(location: markerEnd, length: line.end - markerEnd)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An empty item lifts one level per press, then leaves the list.
            let parent = parent(value, lineStart: line.start, marker: parsed.marker, tokens: tokens)
            let replacement = parent.map(nextMarkerText) ?? ""
            let end = max(cursor, markerEnd)
            let renumbered = parent.map { renumberFollowing(value, after: line.end, marker: $0, tokens: tokens) } ?? []
            return Edit(pieces: [Piece(range: NSRange(location: line.start, length: end - line.start), text: replacement)] + renumbered,
                        cursorAfter: line.start + replacement.utf16.count)
        }
        let insertion = "\n" + nextMarkerText(parsed.marker)
        return Edit(pieces: [Piece(range: NSRange(location: cursor, length: 0), text: insertion)]
                        + renumberFollowing(value, after: line.end, marker: parsed.marker, tokens: tokens),
                    cursorAfter: cursor + insertion.utf16.count)
    }

    /// `listIndentForTab`: the item nests at its previous sibling's content column, numbered after any child
    /// that sibling already has; with no sibling above it moves two spaces in.
    static func indent(_ text: String, cursor start: Int) -> Edit? {
        let value = text as NSString
        guard start >= 0, start <= value.length else { return nil }
        let line = currentLine(value, start)
        guard let parsed = parse(line.text) else { return nil }
        let tokens = tokens(text)
        if tokens.contains(where: { start > $0.location && start < NSMaxRange($0) }) { return nil }
        let marker = parsed.marker, width = indentWidth(marker.indent)
        var previousChild: Marker?
        for above in markersAbove(value, lineStart: line.start, tokens: tokens) {
            let aboveWidth = indentWidth(above.marker.indent)
            if aboveWidth < width { break }
            if aboveWidth > width {
                if previousChild.map({ aboveWidth < indentWidth($0.indent) }) ?? true { previousChild = above.marker }
                continue
            }
            let indent = previousChild?.indent ?? above.marker.indent + String(repeating: " ", count: above.contentColumn - aboveWidth)
            let number = nestedNumber(marker, previous: previousChild)
            let replacedEnd = line.start + marker.indent.utf16.count + number.replaced
            let replacement = indent + number.text
            return Edit(pieces: [Piece(range: NSRange(location: line.start, length: replacedEnd - line.start), text: replacement)],
                        cursorAfter: start < replacedEnd ? line.start + indent.utf16.count : start - replacedEnd + line.start + replacement.utf16.count)
        }
        return Edit(pieces: [Piece(range: NSRange(location: line.start, length: 0), text: "  ")], cursorAfter: start + 2)
    }

    /// `listOutdentForTab`: a nested item moves to its parent's indent, continuing an ordered parent's list.
    static func outdent(_ text: String, cursor start: Int) -> Edit? {
        let value = text as NSString
        guard start >= 0, start <= value.length else { return nil }
        let line = currentLine(value, start)
        guard let parsed = parse(line.text), !parsed.marker.indent.isEmpty else { return nil }
        let tokens = tokens(text)
        if tokens.contains(where: { start > $0.location && start < NSMaxRange($0) }) { return nil }
        let marker = parsed.marker
        let parent = parent(value, lineStart: line.start, marker: marker, tokens: tokens)
        // With no parent above, undo one step of Tab's two-space fallback.
        let indent = parent?.indent ?? marker.indent.replacingOccurrences(of: #"^(?:\t| {1,2})"#, with: "", options: .regularExpression)
        var continues = false
        if case .ordered(_, let d)? = parent?.kind, case .ordered(_, let own) = marker.kind, d == own { continues = true }
        let number = continues ? nestedNumber(marker, previous: parent) : (replaced: 0, text: "")
        let replacedEnd = line.start + marker.indent.utf16.count + number.replaced
        let replacement = indent + number.text
        let renumbered = continues ? parent.map { renumberFollowing(value, after: line.end, marker: $0, tokens: tokens) } ?? [] : []
        return Edit(pieces: [Piece(range: NSRange(location: line.start, length: replacedEnd - line.start), text: replacement)] + renumbered,
                    cursorAfter: start < replacedEnd ? line.start + indent.utf16.count : start - replacedEnd + line.start + replacement.utf16.count)
    }
}
