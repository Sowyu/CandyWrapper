import AppKit
import DesignSystem

/// composer-markdown-source.ts at 4928 (#30421): styled text the selection touches shows as its Markdown, which
/// edits as text, and parses back once the selection leaves. Shown source carries `key`, whose value is the
/// `Origin` it came from, so source left as it was restores exactly. ComposerEditor decides when to run these
/// and keeps the undo history on the parsed shape.
@MainActor
enum ComposerMarkdownSource {
    static let key = NSAttributedString.Key("ComposerMarkdownSource")

    /// What a reveal replaced: the styled text, the Markdown it showed and where each styled unit sits in it.
    final class Origin: NSObject {
        let original: NSAttributedString
        let source: String
        let content: [Int]
        init(original: NSAttributedString, source: String, content: [Int]) {
            self.original = original; self.source = source; self.content = content
        }
    }

    /// Markers a reveal put in at a position of the text before it, for mapping the selection.
    struct Insertion: Equatable { var at: Int; var length: Int; var closing: Bool }

    /// `touches` (composer-markdown-source.ts:131): a caret on either edge counts.
    static func touches(_ selection: NSRange, _ range: NSRange) -> Bool {
        selection.length == 0
            ? selection.location >= range.location && selection.location <= NSMaxRange(range)
            : selection.location < NSMaxRange(range) && NSMaxRange(selection) > range.location
    }

    private static func isDelimiter(_ c: unichar) -> Bool { c == 42 || c == 95 || c == 126 || c == 96 }

    /// Text with no style, no shown source and no atom.
    private static func plain(_ s: NSAttributedString, _ i: Int) -> Bool {
        let attrs = s.attributes(at: i, effectiveRange: nil)
        return attrs[key] == nil && attrs[.attachment] == nil && ComposerRichTextStyler.marks(attrs[.composerMarks]).isEmpty
    }

    /// Runs of styled text (`collectStyledRanges`), outside code blocks and shown source. Newlines carry no marks,
    /// so a run never crosses a line.
    /// A run ends where every style closes, so `code` right before **bold** is two runs. `within` limits the scan,
    /// to the selection's lines on the typing path.
    static func styledRanges(_ s: NSAttributedString, within: NSRange? = nil) -> [NSRange] {
        var ranges: [NSRange] = []
        var last: Set<ComposerRichText.Mark> = []
        s.enumerateAttributes(in: within ?? NSRange(location: 0, length: s.length)) { attrs, sub, _ in
            let marks = Set(ComposerRichTextStyler.marks(attrs[.composerMarks]))
            let styled = !marks.isEmpty && attrs[key] == nil && attrs[.composerCodeBlock] == nil && !(attrs[.attachment] is ComposerBlockAttachment)
            defer { last = styled ? marks : [] }
            guard styled else { return }
            if let end = ranges.last.map(NSMaxRange), end == sub.location, !last.isDisjoint(with: marks) { ranges[ranges.count - 1].length += sub.length }
            else { ranges.append(sub) }
        }
        return ranges
    }

    /// The Markdown `range` shows as and the index in it of each of its units, or nil when that Markdown would not
    /// parse back to the same styles (`revealsFaithfully`): an escaping backslash or a delimiter beside it, or
    /// text such as a bold `path\` or `2*3`.
    static func source(of range: NSRange, in s: NSAttributedString) -> (text: String, content: [Int])? {
        let text = s.string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        if range.location > 0 {
            if isDelimiter(text.character(at: range.location - 1)), plain(s, range.location - 1) { return nil }
            var slashes = 0, i = range.location - 1
            while i >= 0, text.character(at: i) == 92, plain(s, i) { slashes += 1; i -= 1 }
            if slashes % 2 == 1 { return nil }
        }
        if NSMaxRange(range) < text.length, isDelimiter(text.character(at: NSMaxRange(range))), plain(s, NSMaxRange(range)) { return nil }
        var spans: [ComposerRichText.Span] = [], expected: [Set<ComposerRichText.Mark>] = []
        s.enumerateAttributes(in: range) { attrs, sub, _ in
            let marks = ComposerRichTextStyler.marks(attrs[.composerMarks])
            spans.append(.init(text: text.substring(with: sub), marks: marks, atomic: attrs[.attachment] != nil))
            expected += Array(repeating: Set(marks), count: sub.length)
        }
        let value = ComposerRichText.serialize(spans)
        let units = ComposerRichText.unitMarks(value)
        let content = units.indices.filter { units[$0] != nil }
        guard content.count == range.length else { return nil }
        let v = Array(value.utf16), d = Array(text.substring(with: range).utf16)
        for (k, i) in content.enumerated() where v[i] != d[k] || Set(units[i]!) != expected[k] { return nil }
        return (value, content)
    }

    /// Replaces styled `range` with its Markdown (`revealStyledText`) and returns the markers it put in. Closing
    /// markers come before opening ones at a shared position.
    static func reveal(_ range: NSRange, _ source: (text: String, content: [Int]), in s: NSMutableAttributedString) -> [Insertion] {
        let original = s.attributedSubstring(from: range)
        let origin = Origin(original: original, source: source.text, content: source.content)
        let v = source.text as NSString
        let out = NSMutableAttributedString()
        var insertions: [Insertion] = []
        var i = 0, k = 0
        func marks(_ unit: Int) -> Set<ComposerRichText.Mark> {
            unit < 0 || unit >= original.length ? [] : Set(ComposerRichTextStyler.marks(original.attribute(.composerMarks, at: unit, effectiveRange: nil)))
        }
        while i < v.length {
            if k < source.content.count, source.content[k] == i {
                out.append(original.attributedSubstring(from: NSRange(location: k, length: 1)))
                k += 1; i += 1; continue
            }
            var j = i
            while j < v.length, !(k < source.content.count && source.content[k] == j) { j += 1 }
            let closed = marks(k - 1).subtracting(marks(k)).map(\.delimiter.utf16.count).reduce(0, +)
            let closing = min(j - i, k == 0 ? 0 : closed)
            if closing > 0 { insertions.append(Insertion(at: range.location + k, length: closing, closing: true)) }
            if j - i > closing { insertions.append(Insertion(at: range.location + k, length: j - i - closing, closing: false)) }
            out.append(NSAttributedString(string: v.substring(with: NSRange(location: i, length: j - i))))
            i = j
        }
        let all = NSRange(location: 0, length: out.length)
        out.removeAttribute(.composerMarks, range: all)
        out.addAttribute(key, value: origin, range: all)
        s.replaceCharacters(in: range, with: out)
        return insertions
    }

    /// Where a position before reveals lands after them. A caret arriving at a styled edge stays outside its
    /// markers; `inside` keeps it inside ones it just typed beside.
    static func map(_ position: Int, through insertions: [Insertion], inside: (Insertion) -> Bool) -> Int {
        var next = position
        for x in insertions where x.at < position || (x.at == position && x.closing != inside(x)) { next += x.length }
        return next
    }

    /// Shown source line by line, each widened by delimiters typed beside it (`withAdjacentDelimiters`), so a
    /// closing `**` retyped after its text joins it.
    static func regions(_ s: NSAttributedString) -> [NSRange] {
        let text = s.string as NSString
        var raw: [NSRange] = []
        s.enumerateAttribute(key, in: NSRange(location: 0, length: s.length)) { value, sub, _ in
            guard value != nil else { return }
            if let last = raw.last, NSMaxRange(last) == sub.location { raw[raw.count - 1].length += sub.length } else { raw.append(sub) }
        }
        var regions: [NSRange] = []
        for region in raw {
            var from = region.location, to = NSMaxRange(region)
            var count = 0
            while from - count - 1 >= 0, isDelimiter(text.character(at: from - count - 1)), plain(s, from - count - 1) { count += 1 }
            var slashes = 0
            while from - count - slashes - 1 >= 0, text.character(at: from - count - slashes - 1) == 92 { slashes += 1 }
            if count > 0, slashes % 2 == 1 { count -= 1 }
            from -= count
            while to < text.length, isDelimiter(text.character(at: to)), plain(s, to) { to += 1 }
            if let last = regions.last, from <= NSMaxRange(last) {
                regions[regions.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), to) - last.location)
            } else { regions.append(NSRange(location: from, length: to - from)) }
        }
        return regions
    }

    /// Parses `region` back into styles in place (`collapseRegion`) and returns the units it dropped, in the
    /// region's own offsets.
    @discardableResult
    static func collapse(_ region: NSRange, in s: NSMutableAttributedString, lineBase: [NSAttributedString.Key: Any]) -> [Int] {
        let sub = s.attributedSubstring(from: region)
        var origin: Origin?, whole = true
        sub.enumerateAttribute(key, in: NSRange(location: 0, length: sub.length)) { value, _, stop in
            guard let o = value as? Origin, origin == nil || origin === o else { whole = false; stop.pointee = true; return }
            origin = o
        }
        if whole, let origin, sub.string == origin.source {
            let kept = Set(origin.content)
            s.replaceCharacters(in: region, with: origin.original)
            return (0..<sub.length).filter { !kept.contains($0) }
        }
        let units = ComposerRichText.unitMarks(sub.string)
        let out = NSMutableAttributedString()
        var dropped: [Int] = []
        var i = 0
        while i < sub.length {
            guard let marks = units[i] else { dropped.append(i); i += 1; continue }
            var j = i + 1
            while j < sub.length, let next = units[j], Set(next) == Set(marks), sub.attribute(.attachment, at: j, effectiveRange: nil) == nil,
                  sub.attribute(.attachment, at: i, effectiveRange: nil) == nil { j += 1 }
            let piece = NSRange(location: i, length: j - i)
            if sub.attribute(.attachment, at: i, effectiveRange: nil) != nil {
                let chip = NSMutableAttributedString(attributedString: sub.attributedSubstring(from: piece))
                chip.removeAttribute(key, range: NSRange(location: 0, length: chip.length))
                if marks.isEmpty { chip.removeAttribute(.composerMarks, range: NSRange(location: 0, length: chip.length)) }
                else { chip.addAttribute(.composerMarks, value: marks.map(\.rawValue), range: NSRange(location: 0, length: chip.length)) }
                out.append(chip)
            } else {
                out.append(NSAttributedString(string: (sub.string as NSString).substring(with: piece),
                                              attributes: ComposerRichTextStyler.attributes(marks, base: lineBase)))
            }
            i = j
        }
        s.replaceCharacters(in: region, with: out)
        return dropped
    }

    /// Styles shown source as it would parse (`previewDecorations`): its text in its styles and its markers
    /// muted (`.composer-rich-marker`, index.css:2514-2520), with a code span's backticks styled as code.
    static func restyle(_ region: NSRange, in s: NSMutableAttributedString, lineBase: [NSAttributedString.Key: Any]) {
        let text = s.attributedSubstring(from: region).string as NSString
        let units = ComposerRichText.unitMarks(text as String)
        var ticks = Set<Int>()
        for i in units.indices where units[i]?.contains(.code) == true {
            if i > 0, units[i - 1] == nil, text.character(at: i - 1) == 96 { ticks.insert(i - 1) }
            if i + 1 < units.count, units[i + 1] == nil, text.character(at: i + 1) == 96 { ticks.insert(i + 1) }
        }
        var marker = lineBase
        marker[.foregroundColor] = Themed.color(\.mutedForeground, 0.75)
        marker[.composerMarks] = nil
        var i = 0
        while i < units.count {
            func style(_ u: Int) -> [ComposerRichText.Mark]? { ticks.contains(u) ? [.code] : units[u] }
            let current = style(i)
            var j = i + 1
            while j < units.count, style(j).map(Set.init) == current.map(Set.init) { j += 1 }
            let at = region.location + i
            var attrs = current.map { ComposerRichTextStyler.attributes($0, base: lineBase) } ?? marker
            attrs[.composerMarks] = nil
            s.enumerateAttributes(in: NSRange(location: at, length: j - i)) { old, sub, _ in
                if old[.attachment] != nil { return }
                var a = attrs
                a[key] = old[key]
                s.setAttributes(a, range: sub)
            }
            i = j
        }
    }
}
