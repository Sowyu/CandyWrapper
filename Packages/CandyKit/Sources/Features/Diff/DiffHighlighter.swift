import Foundation

/// Token colors for diff lines through `CodeHighlighter`, the same pierre colors as chat code blocks.
/// Like pierre with a patch and no file contents, each file's old side (context and deletions) and
/// new side (context and additions) are tokenized as one text each, so block comments and strings
/// that span lines color correctly. Files tokenize on first draw and stay cached. A large file
/// tokenizes off the main thread and draws plain until `onReady` reports its spans.
// ponytail: keeps the most recent `capacity` files; a 20,000-line file costs about 1.5 MB of spans.
// Tokenize per hunk window if one huge file must stay cheaper.
@MainActor
final class DiffHighlighter {
    struct Span: Equatable, Sendable {
        /// UTF-16 offsets within the line.
        var start: Int32
        var length: Int32
        var kind: CodeTokenKind
    }

    private struct FileSpans: Sendable {
        var firstLine: Int
        /// `offsets[i] ..< offsets[i + 1]` are the spans of line `firstLine + i`.
        var offsets: [Int32]
        var spans: [Span]
    }

    typealias Tokenizer = @Sendable (_ code: String, _ language: String) -> [CodeToken]

    private(set) var diff: UnifiedDiff
    private let tokenize: Tokenizer
    private var cache: [Int: FileSpans] = [:]
    private var recent: [Int] = []
    private var pending: Set<Int> = []
    /// Bumped by `reset`; spans built for an older diff are dropped.
    private var generation = 0
    /// The latest off-main build, for tests to await.
    private(set) var inFlight: Task<Void, Never>?
    /// A file's spans arrived from off the main thread: redraw its rows.
    var onReady: (@MainActor (_ file: Int) -> Void)?
    static let capacity = 6
    /// Files with at most this many diff lines tokenize inline, so they never flash plain text.
    // ponytail: about a millisecond inline; lower it if expanding a mid-size file stutters.
    static let inlineLines = 1_000

    init(diff: UnifiedDiff, tokenize: @escaping Tokenizer = { CodeHighlighter.tokens($0, language: $1) }) {
        self.diff = diff
        self.tokenize = tokenize
    }

    /// Shows another diff: forgets every file's spans and ignores builds still running.
    func reset(_ diff: UnifiedDiff) {
        self.diff = diff
        cache = [:]; recent = []; pending = []
        generation += 1
    }

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
        guard !pending.contains(file), let first = info.hunks.first?.lines.lowerBound, let end = info.hunks.last?.lines.upperBound,
              CodeHighlighter.supports(info.language) else { return nil }
        if end - first <= Self.inlineLines {
            let built = Self.build(diff, first..<end, language: info.language, tokenize: tokenize)
            store(built, file)
            return built
        }
        pending.insert(file)
        let diff = diff, language = info.language, tokenize = tokenize, generation = generation
        inFlight = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(diff, first..<end, language: language, tokenize: tokenize)
            }.value
            guard let self, self.generation == generation else { return }
            self.pending.remove(file)
            self.store(built, file)
            self.onReady?(file)
        }
        return nil
    }

    private func store(_ built: FileSpans, _ file: Int) {
        cache[file] = built
        recent.append(file)
        if recent.count > Self.capacity { cache[recent.removeFirst()] = nil }
    }

    nonisolated private static func build(_ diff: UnifiedDiff, _ range: Range<Int>, language: String, tokenize: Tokenizer) -> FileSpans {
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
            let tokens = tokenize(text, language)
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
