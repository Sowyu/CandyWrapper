import Foundation

/// Token colors for diff lines through `CodeHighlighter`, the same pierre colors as chat code blocks.
/// Like pierre with a patch and no file contents, each file's old side (context and deletions) and
/// new side (context and additions) are tokenized as one text each, so block comments and strings
/// that span lines color correctly. Files tokenize on first draw and stay cached.
// ponytail: keeps the most recent `capacity` files; a 20,000-line file costs about 1.5 MB of spans.
// Tokenize per hunk window if one huge file must stay cheaper.
@MainActor
final class DiffHighlighter {
    struct Span: Equatable {
        /// UTF-16 offsets within the line.
        var start: Int32
        var length: Int32
        var kind: CodeTokenKind
    }

    private struct FileSpans {
        var firstLine: Int
        /// `offsets[i] ..< offsets[i + 1]` are the spans of line `firstLine + i`.
        var offsets: [Int32]
        var spans: [Span]
    }

    let diff: UnifiedDiff
    private var cache: [Int: FileSpans] = [:]
    private var recent: [Int] = []
    static let capacity = 6

    init(diff: UnifiedDiff) { self.diff = diff }

    func spans(file: Int, line: Int) -> ArraySlice<Span> {
        guard let entry = entry(file) else { return [] }
        let local = line - entry.firstLine
        guard local >= 0, local + 1 < entry.offsets.count else { return [] }
        return entry.spans[Int(entry.offsets[local])..<Int(entry.offsets[local + 1])]
    }

    private func entry(_ file: Int) -> FileSpans? {
        if let hit = cache[file] {
            if recent.last != file { recent.removeAll { $0 == file }; recent.append(file) }
            return hit
        }
        let info = diff.files[file]
        guard let first = info.hunks.first?.lines.lowerBound, let end = info.hunks.last?.lines.upperBound,
              CodeHighlighter.supports(info.language) else { return nil }
        let built = Self.build(diff, first..<end, language: info.language)
        cache[file] = built
        recent.append(file)
        if recent.count > Self.capacity { cache[recent.removeFirst()] = nil }
        return built
    }

    private static func build(_ diff: UnifiedDiff, _ range: Range<Int>, language: String) -> FileSpans {
        // Per line: its tokens from the new side (context, additions) or the old side (deletions).
        var perLine = [[Span]](repeating: [], count: range.count)
        for side in [UnifiedDiff.Line.Kind.deletion, .addition] {
            var text = ""
            var starts: [(line: Int, offset: Int, length: Int)] = []
            var offset = 0
            for i in range where diff.lines[i].kind == .context || diff.lines[i].kind == side {
                let s = diff.text(diff.lines[i])
                let length = s.utf16.count
                starts.append((i, offset, length))
                text += s
                text += "\n"
                offset += length + 1
            }
            guard !starts.isEmpty else { continue }
            let tokens = CodeHighlighter.tokens(text, language: language)
            var t = 0
            for entry in starts {
                // Context lines take the new side's colors only.
                if side == .deletion, diff.lines[entry.line].kind == .context { continue }
                while t < tokens.count, NSMaxRange(tokens[t].range) <= entry.offset { t += 1 }
                var k = t
                var spans: [Span] = []
                while k < tokens.count, tokens[k].range.location < entry.offset + entry.length {
                    let a = max(tokens[k].range.location, entry.offset)
                    let b = min(NSMaxRange(tokens[k].range), entry.offset + entry.length)
                    if b > a { spans.append(Span(start: Int32(a - entry.offset), length: Int32(b - a), kind: tokens[k].kind)) }
                    k += 1
                }
                perLine[entry.line - range.lowerBound] = spans
            }
        }
        var offsets: [Int32] = [0]
        offsets.reserveCapacity(range.count + 1)
        var spans: [Span] = []
        for list in perLine {
            spans.append(contentsOf: list)
            offsets.append(Int32(spans.count))
        }
        return FileSpans(firstLine: range.lowerBound, offsets: offsets, spans: spans)
    }
}
