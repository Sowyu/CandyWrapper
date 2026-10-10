import Foundation

/// A parsed unified git patch, the `diff` string of `orchestration.getTurnDiff` and
/// `getFullThreadDiff` (git diff --patch --no-color --src-prefix=a/ --dst-prefix=b/, research note G 5.3).
/// Line text stays in the patch bytes; each line is 20 bytes of offsets and numbers, so a
/// 20,000-line patch costs its own size plus about 400 KB.
public struct UnifiedDiff: Sendable {
    public struct Line: Sendable, Equatable {
        public enum Kind: UInt8, Sendable { case context, addition, deletion }
        public var kind: Kind
        /// A `\ No newline at end of file` marker followed this line.
        public var noNewline: Bool
        /// 1-based line numbers; 0 on the side the line does not exist.
        public var oldNumber: Int32
        public var newNumber: Int32
        /// UTF-8 byte range of the text in `bytes`, without the prefix character and line end.
        var start: Int32
        var length: Int32
    }

    /// pierre's `FileDiffMetadata.type`, which picks the header icon and colors.
    public enum Change: String, Sendable {
        case new, deleted, change
        case renamePure = "rename-pure"
        case renameChanged = "rename-changed"
    }

    public struct Hunk: Sendable, Equatable {
        public var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        /// Text after the second `@@` (a function or section name), trimmed.
        public var context: String
        /// Indices into `UnifiedDiff.lines`.
        public var lines: Range<Int>
        /// Unchanged new-side lines hidden between the previous hunk (or the file start) and this one,
        /// pierre's `collapsedBefore`, shown as "N unmodified lines".
        public var collapsedBefore: Int
    }

    public struct File: Sendable, Equatable {
        public var oldPath: String?
        public var newPath: String?
        public var change: Change
        public var isBinary: Bool
        public var hunks: [Hunk]
        public var additions: Int
        public var deletions: Int

        /// `resolveFileDiffPath`: the new name, else the old one.
        public var path: String { newPath ?? oldPath ?? "" }

        /// Grammar id for `CodeHighlighter`, from the file name like pierre's `getFiletypeFromFileName`.
        public var language: String { UnifiedDiff.language(forPath: path) }
    }

    public internal(set) var files: [File] = []
    public internal(set) var lines: [Line] = []
    let bytes: [UInt8]

    public init(_ patch: String) {
        bytes = Array(patch.utf8)
        var parser = Parser(bytes: bytes)
        parser.run()
        files = parser.files
        lines = parser.lines
    }

    public func text(_ line: Line) -> String {
        let start = Int(line.start)
        return String(decoding: bytes[start..<start + Int(line.length)], as: UTF8.self)
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    static func language(forPath path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        switch name.lowercased() {
        case "dockerfile": return "docker"
        case "makefile": return "make"
        case ".gitignore", ".dockerignore", ".npmrc", ".editorconfig": return "ini"
        default: break
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "text" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

// MARK: - Parser

private struct Parser {
    let bytes: [UInt8]
    var files: [UnifiedDiff.File] = []
    var lines: [UnifiedDiff.Line] = []
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// The line at `i` as a byte range without its line end; advances `i` past it.
    mutating func nextLine() -> Range<Int> {
        let start = i
        while i < bytes.count, bytes[i] != 0x0a { i += 1 }
        var end = i
        if end > start, bytes[end - 1] == 0x0d { end -= 1 }
        if i < bytes.count { i += 1 }
        return start..<end
    }

    func peekLine() -> Range<Int> {
        var copy = self
        return copy.nextLine()
    }

    func has(_ r: Range<Int>, prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        return r.count >= p.count && bytes[r.lowerBound..<r.lowerBound + p.count].elementsEqual(p)
    }

    func string(_ r: Range<Int>, dropping n: Int = 0) -> String {
        String(decoding: bytes[min(r.upperBound, r.lowerBound + n)..<r.upperBound], as: UTF8.self)
    }

    mutating func run() {
        var file: UnifiedDiff.File?
        var markers = false // the current file already had its `---`/`+++` pair
        func finish(_ f: inout UnifiedDiff.File?) {
            guard var done = f else { return }
            if done.change == .change, done.oldPath != nil, done.newPath != nil, done.oldPath != done.newPath {
                done.change = done.hunks.isEmpty ? .renamePure : .renameChanged
            }
            files.append(done)
            f = nil
        }
        while i < bytes.count {
            let line = nextLine()
            if has(line, prefix: "diff --git ") {
                finish(&file)
                let (a, b) = Self.gitHeaderPaths(string(line, dropping: 11))
                markers = false
                file = UnifiedDiff.File(oldPath: a, newPath: b, change: .change, isBinary: false, hunks: [], additions: 0, deletions: 0)
            } else if has(line, prefix: "--- "), has(peekLine(), prefix: "+++ ") {
                // A plain unified diff (no `diff --git` line) starts each file here.
                if file == nil || markers { finish(&file) }
                if file == nil {
                    file = UnifiedDiff.File(oldPath: nil, newPath: nil, change: .change, isBinary: false, hunks: [], additions: 0, deletions: 0)
                }
                markers = true
                let old = Self.markerPath(string(line, dropping: 4))
                let new = Self.markerPath(string(nextLine(), dropping: 4))
                file!.oldPath = old
                file!.newPath = new
                if old == nil { file!.change = .new } else if new == nil { file!.change = .deleted }
            } else if has(line, prefix: "new file mode"), file != nil {
                file!.change = .new
                file!.oldPath = nil
            } else if has(line, prefix: "deleted file mode"), file != nil {
                file!.change = .deleted
                file!.newPath = nil
            } else if has(line, prefix: "rename from "), file != nil {
                file!.oldPath = string(line, dropping: 12)
            } else if has(line, prefix: "rename to "), file != nil {
                file!.newPath = string(line, dropping: 10)
            } else if (has(line, prefix: "Binary files ") || has(line, prefix: "GIT binary patch")), file != nil {
                file!.isBinary = true
            } else if has(line, prefix: "@@ "), file != nil {
                hunk(header: line, into: &file!)
            }
            // `index`, `old mode`, `similarity index` and anything unknown carry nothing we draw.
        }
        finish(&file)
    }

    /// Reads one hunk's lines, ending when both counts are used up. Counting (not prefix sniffing)
    /// keeps a deleted line that reads `-- x` from looking like a `---` header.
    mutating func hunk(header: Range<Int>, into file: inout UnifiedDiff.File) {
        guard let spec = Self.hunkSpec(string(header)) else { return }
        var oldLeft = spec.oldCount, newLeft = spec.newCount
        var oldNumber = spec.oldStart, newNumber = spec.newStart
        let first = lines.count
        while i < bytes.count {
            let peek = peekLine()
            let lead: UInt8 = peek.isEmpty ? 0x20 : bytes[peek.lowerBound]
            if lead == 0x5c { // `\ No newline at end of file` belongs to the line above
                _ = nextLine()
                if lines.count > first { lines[lines.count - 1].noNewline = true }
                continue
            }
            guard oldLeft > 0 || newLeft > 0 else { break }
            let kind: UnifiedDiff.Line.Kind
            switch lead {
            case 0x2b where newLeft > 0: kind = .addition
            case 0x2d where oldLeft > 0: kind = .deletion
            case 0x20 where oldLeft > 0 && newLeft > 0: kind = .context
            default: return finishHunk(spec, first: first, into: &file) // malformed: stop at what parsed
            }
            let r = nextLine()
            let textStart = r.isEmpty ? r.lowerBound : r.lowerBound + 1
            var line = UnifiedDiff.Line(kind: kind, noNewline: false, oldNumber: 0, newNumber: 0,
                                        start: Int32(textStart), length: Int32(r.upperBound - textStart))
            switch kind {
            case .context:
                line.oldNumber = Int32(oldNumber); line.newNumber = Int32(newNumber)
                oldNumber += 1; newNumber += 1; oldLeft -= 1; newLeft -= 1
            case .addition:
                line.newNumber = Int32(newNumber); newNumber += 1; newLeft -= 1; file.additions += 1
            case .deletion:
                line.oldNumber = Int32(oldNumber); oldNumber += 1; oldLeft -= 1; file.deletions += 1
            }
            lines.append(line)
        }
        finishHunk(spec, first: first, into: &file)
    }

    mutating func finishHunk(_ spec: HunkSpec, first: Int, into file: inout UnifiedDiff.File) {
        // pierre (processFile): hidden lines before a hunk = its first new line minus the previous
        // hunk's last new line. A zero-length side sits at `start`, not `start - 1`.
        let previousEnd = file.hunks.last.map { $0.newCount == 0 ? $0.newStart : $0.newStart + $0.newCount - 1 } ?? 0
        let before = (spec.newCount == 0 ? spec.newStart : spec.newStart - 1) - previousEnd
        file.hunks.append(UnifiedDiff.Hunk(oldStart: spec.oldStart, oldCount: spec.oldCount, newStart: spec.newStart,
                                           newCount: spec.newCount, context: spec.context, lines: first..<lines.count,
                                           collapsedBefore: max(0, before)))
    }

    struct HunkSpec { var oldStart, oldCount, newStart, newCount: Int; var context: String }

    /// `@@ -a[,b] +c[,d] @@ context`; a missing count means 1.
    static func hunkSpec(_ header: String) -> HunkSpec? {
        let parts = header.split(separator: "@@", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var old = (1, 1), new = (1, 1)
        for token in parts[1].split(separator: " ") {
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            let nums = token.dropFirst().split(separator: ",").map { Int($0) }
            guard let start = nums.first ?? nil else { return nil }
            let count = nums.count > 1 ? (nums[1] ?? 1) : 1
            if sign == "-" { old = (start, count) } else { new = (start, count) }
        }
        let context = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        return HunkSpec(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, context: context)
    }

    /// Paths from `a/x b/y`, either side possibly C-quoted (`"a/sp ace"`).
    static func gitHeaderPaths(_ rest: String) -> (String?, String?) {
        var tokens: [String] = []
        var s = Substring(rest)
        while !s.isEmpty, tokens.count < 2 {
            s = s.drop { $0 == " " }
            if s.first == "\"" {
                let (value, remainder) = unquote(s)
                tokens.append(value)
                s = remainder
            } else if tokens.isEmpty, let split = s.range(of: " b/") {
                // Unquoted paths may hold spaces: split at " b/", git's own prefix.
                tokens.append(String(s[..<split.lowerBound]))
                s = s[s.index(after: split.lowerBound)...]
            } else {
                tokens.append(String(s))
                s = ""
            }
        }
        func strip(_ t: String?) -> String? {
            guard let t else { return nil }
            return t.hasPrefix("a/") || t.hasPrefix("b/") ? String(t.dropFirst(2)) : t
        }
        return (strip(tokens.first), strip(tokens.count > 1 ? tokens[1] : nil))
    }

    /// The path on a `---` or `+++` line; nil for /dev/null. Drops a trailing tab and timestamp.
    static func markerPath(_ rest: String) -> String? {
        var value = rest
        if value.hasPrefix("\"") { value = unquote(Substring(value)).0 } else if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
        if value == "/dev/null" { return nil }
        return value.hasPrefix("a/") || value.hasPrefix("b/") ? String(value.dropFirst(2)) : value
    }

    /// Git's C quoting: `"..."` with `\"`, `\\`, `\t`, `\n` and octal byte escapes (UTF-8 bytes).
    static func unquote(_ s: Substring) -> (String, Substring) {
        var out: [UInt8] = []
        var it = s.utf8.dropFirst()
        while let c = it.first {
            it = it.dropFirst()
            if c == 0x22 { break }
            guard c == 0x5c, let e = it.first else { out.append(c); continue }
            it = it.dropFirst()
            switch e {
            case 0x6e: out.append(0x0a)
            case 0x74: out.append(0x09)
            case 0x30...0x37:
                var value = Int(e - 0x30)
                for _ in 0..<2 {
                    guard let d = it.first, (0x30...0x37).contains(d) else { break }
                    value = value * 8 + Int(d - 0x30)
                    it = it.dropFirst()
                }
                out.append(UInt8(value & 0xff))
            default: out.append(e)
            }
        }
        return (String(decoding: out, as: UTF8.self), Substring(String(decoding: Array(it), as: UTF8.self)))
    }
}
