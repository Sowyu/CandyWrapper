import Foundation

/// GitHub's `:alias:` emoji (5258 client-runtime pullRequestMarkdown.ts:358-392, #39315). The table
/// is generated from T3's alias file by scripts/gen-github-emoji.py.
enum GitHubEmoji {
    private static let byAlias: [String: String] = {
        var out: [String: String] = [:]
        for line in GitHubEmojiTable.aliases.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            out[String(line[..<space])] = String(line[line.index(after: space)...])
        }
        return out
    }()
    private static let aliasPattern = try! NSRegularExpression(pattern: #":([a-z\d_+-]+)(?=:)"#)

    /// `expandGithubEmojiAliases`: a colon closes one alias only, so `:tada:tada:` has one.
    static func expand(_ text: String) -> String {
        guard text.contains(":") else { return text }
        let ns = text as NSString
        var out = "", start = 0, end = 0
        for m in aliasPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.location >= end, let emoji = byAlias[ns.substring(with: m.range(at: 1))] else { continue }
            out += ns.substring(with: NSRange(location: start, length: m.range.location - start)) + emoji
            start = m.range.location + m.range.length + 1
            end = start
        }
        return start == 0 ? text : out + ns.substring(from: start)
    }

    /// T3 expands only Markdown text nodes, so code keeps its aliases. This walks the source and
    /// leaves fenced blocks, indented code and inline code spans as written.
    // ponytail: source-level walk, not a Markdown tree; link destinations with `:alias:` would expand too. Move to a MarkdownView text hook if one shows up.
    static func expandMarkdown(_ markdown: String) -> String {
        guard markdown.contains(":") else { return markdown }
        var out: [Substring] = []
        var fence: Substring?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " })
            if let open = fence {
                out.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(while: { $0 == trimmed.first })
                out.append(line)
                continue
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { out.append(line); continue }
            out.append(Substring(expandOutsideCodeSpans(String(line))))
        }
        return out.joined(separator: "\n")
    }

    private static func expandOutsideCodeSpans(_ line: String) -> String {
        guard line.contains("`") else { return expand(line) }
        var result = "", rest = Substring(line)
        while let tick = rest.firstIndex(of: "`") {
            result += expand(String(rest[..<tick]))
            let run = rest[tick...].prefix(while: { $0 == "`" })
            let after = rest[run.endIndex...]
            guard let close = after.range(of: String(run)) else { result += rest[tick...]; return result }
            result += rest[tick..<close.upperBound]
            rest = after[close.upperBound...]
        }
        return result + expand(String(rest))
    }
}
