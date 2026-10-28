import Foundation

/// `maskMarkdownFrontmatter` (packages/shared/src/markdownFrontmatter.ts at 3814): blanks a leading YAML frontmatter
/// block so rendered file previews skip it instead of showing a rule and a setext heading. Masked characters become
/// spaces and line breaks stay, so source offsets (task checkbox edits) stay valid. Chat messages keep theirs.
public enum MarkdownFrontmatter {
    nonisolated(unsafe) private static let leading = try! NSRegularExpression(
        pattern: #"\A\x{FEFF}?---[ \t]*(?:\r\n|\r|\n)(?:[\s\S]*?(?:\r\n|\r|\n))?(?:---|\.\.\.)[ \t]*(?=\r\n|\r|\n|\z)"#)

    public static func mask(_ markdown: String) -> String {
        let ns = markdown as NSString
        guard let match = leading.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)) else { return markdown }
        let block = ns.substring(with: match.range)
        let blanked = String(block.map { $0 == "\n" || $0 == "\r" || $0 == "\r\n" ? $0 : " " })
        return ns.replacingCharacters(in: match.range, with: blanked)
    }
}
