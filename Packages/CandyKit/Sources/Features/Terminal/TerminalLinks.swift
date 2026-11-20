import Foundation

/// `extractTerminalLinks` (apps/web/src/terminal-links.ts): the URLs and file paths in one logical terminal
/// line. Paths keep Unicode letters and marks (9ac1355e01), and a logged request route such as
/// `GET /api/x?a=1` is no path (10b86829e8). Offsets are UTF-16, as in T3. Runs only when the pointer
/// moves over the terminal or clicks it.
public enum TerminalLinks {
    public enum Kind: Sendable, Equatable { case url, path }

    public struct Match: Sendable, Equatable {
        public var kind: Kind
        public var text: String
        public var start: Int
        public var end: Int
    }

    // The patterns as T3 writes them. Bare paths start only at a segment boundary.
    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s"'`<>]+"#, options: [.caseInsensitive])
    // 4928 (#30603, #37071, #36174, #37201): `$`, `+` and `@` in names, `[id]` and `(group)/` route segments, a bare
    // `name.ext` before `:line:col` or a TypeScript location, and `(line,col)` before `: error TS…:`.
    private static let filePath = try! NSRegularExpression(pattern:
        #"(?:~[\\/]|\.{1,2}[\\/]|/|[A-Za-z]:[\\/]|\\\\)[^\s"'`<>]+|(?<![\p{L}\p{M}\p{N}._$+@-])[\p{L}\p{M}\p{N}._$+@-]+(?:(?:[\\/](?:[\p{L}\p{M}\p{N}._$+@-]|\[{1,2}[\p{L}\p{M}\p{N}._-]+\]{1,2}|\([\p{L}\p{M}\p{N}._-]+\)(?=[\\/]))+)+|\.\p{L}[\p{L}\p{M}\p{N}_-]*(?=:\d+:\d|\(\d+,\d+\):\s+(?:error|warning) TS\d+:))(?:(?::\d+){1,2}|\(\d+,\d+\)(?=:\s+(?:error|warning) TS\d+:))?"#)
    /// The default PowerShell prompt delimits its unquoted path with `PS ` and `>`.
    private static let powerShellPrompt = try! NSRegularExpression(pattern: #"^PS ((?:[A-Za-z]:[\\/]|\\\\|/)[^>\r\n]*)>"#)
    /// The tail of `redis://host/0` or `file:///a.mjs` is not a path (#28189).
    private static let schemeURL = try! NSRegularExpression(pattern: #"(?<![A-Za-z\d+.-])[+-]?[A-Za-z][A-Za-z\d+.-]+://[^\s"'`<>]+"#)
    /// Nor is the tail of an SCP-style Git remote such as `git@github.com:acme/widgets.git` (#35404).
    private static let scpRemote = try! NSRegularExpression(pattern: #"(?<![\w.@-])[\w.-]+@[\w.-]+:[^\s"'`<>]+"#)
    private static let typeScriptLocation = try! NSRegularExpression(pattern: #"^:\s+(?:error|warning) TS\d+:"#)
    private static let quotedFilePath = try! NSRegularExpression(pattern:
        #"(["'`])(?<path>(?:~[\\/]|\.{1,2}[\\/]|/|[A-Za-z]:[\\/]|\\\\|[\p{L}\p{M}\p{N}._ -]+[\\/])[^\r\n]*?|[\p{L}\p{M}\p{N}._ -]+\.[\p{L}\p{M}\p{N}_-]+(?::\d+){0,2})\1(?<position>(?::\d+){0,2})"#)
    private static let trailingPunctuation = try! NSRegularExpression(pattern: #"[.,;!?]+$"#)
    /// Paths also drop a trailing colon: compilers end `file:line:col:` with one.
    private static let trailingPathPunctuation = try! NSRegularExpression(pattern: #"[.,;:!?]+$"#)
    /// A question mark is legal in filenames; only request targets with a query are excluded.
    private static let requestRoute = try! NSRegularExpression(pattern:
        #"(?:^|[\s"'`])(?:GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|CONNECT|TRACE|proxying)\s+["'`]?(?:/|[A-Za-z0-9_-]+/)[^\s?]*\?\S*"#)

    /// `extractTerminalLinks` (4928 terminal-links.ts:126-160).
    public static func extract(_ line: String) -> [Match] {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        var prompt: [Match] = []
        if let m = powerShellPrompt.firstMatch(in: line, range: all), m.range(at: 1).location != NSNotFound {
            let text = ns.substring(with: m.range(at: 1))
            prompt = [Match(kind: .path, text: text, start: 3, end: 3 + (text as NSString).length)]
        }
        let nonPath = (requestRoute.matches(in: line, range: all) + schemeURL.matches(in: line, range: all)).map { $0.range.location..<NSMaxRange($0.range) }
        let remoteTails = scpRemote.matches(in: line, range: all).map { m -> Range<Int> in
            let colon = (ns.substring(with: m.range) as NSString).range(of: ":").location
            return (m.range.location + colon + 1)..<NSMaxRange(m.range)
        }
        let urls = collect(line, .url, url, existing: prompt)
        let quoted = collect(line, .path, quotedFilePath, existing: prompt + urls)
        let paths = collect(line, .path, filePath, existing: prompt + urls + quoted)
        return (prompt + urls + quoted + paths)
            .filter { m in
                m.kind == .url || (!nonPath.contains { $0.overlaps(m.start..<m.end) }
                    && !remoteTails.contains { m.start >= $0.lowerBound && m.end <= $0.upperBound })
            }
            .sorted { $0.start < $1.start }
    }

    public static func isURL(_ value: String) -> Bool {
        value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func collect(_ line: String, _ kind: Kind, _ pattern: NSRegularExpression, existing: [Match]) -> [Match] {
        let ns = line as NSString
        var found: [Match] = []
        for m in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let quotedPath = pattern === quotedFilePath ? m.range(withName: "path") : NSRange(location: NSNotFound, length: 0)
            let positionRange = pattern === quotedFilePath ? m.range(withName: "position") : NSRange(location: NSNotFound, length: 0)
            let position = positionRange.location == NSNotFound ? "" : ns.substring(with: positionRange)
            let isQuoted = quotedPath.location != NSNotFound
            let raw = isQuoted ? ns.substring(with: quotedPath) + position : ns.substring(with: m.range)
            let start = m.range.location + (isQuoted ? 1 : 0)
            guard !raw.isEmpty else { continue }
            let trimmed = isQuoted ? raw : trimClosingDelimiters(raw, kind)
            guard !trimmed.isEmpty, !(kind == .path && isURL(trimmed)) else { continue }
            // `file(12,5): error TS…:` opens at 12:5 (#36174).
            let after = ns.substring(from: min(ns.length, start + (trimmed as NSString).length))
            let text = kind == .path && typeScriptLocation.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) != nil
                ? trimmed.replacingOccurrences(of: #"\((\d+),(\d+)\)$"#, with: ":$1:$2", options: .regularExpression) : trimmed
            // A position outside the quotes spans the closing quote in the terminal.
            let candidate = Match(kind: kind, text: text, start: start, end: start + (trimmed as NSString).length + (position.isEmpty ? 0 : 1))
            if (existing + found).contains(where: { candidate.start < $0.end && $0.start < candidate.end }) { continue }
            found.append(candidate)
        }
        return found
    }

    /// `trimClosingDelimiters`: trailing punctuation, then closing brackets that have no opening one.
    static func trimClosingDelimiters(_ value: String, _ kind: Kind) -> String {
        let pattern = kind == .path ? trailingPathPunctuation : trailingPunctuation
        var output = pattern.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: "")
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while output.hasSuffix(close),
                  output.components(separatedBy: open).count < output.components(separatedBy: close).count {
                output.removeLast()
            }
        }
        return output
    }

    /// The span and text SwiftTerm's hover lookup takes (`Terminal.implicitLinkDetector`).
    public static func detector(_ line: String) -> [(range: Range<Int>, text: String)] {
        extract(line).map { ($0.start..<$0.end, $0.text) }
    }
}
