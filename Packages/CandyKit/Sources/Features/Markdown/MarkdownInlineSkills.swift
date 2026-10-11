import Foundation
import T3Protocol

/// shared/inlineSkills.ts:30-44 and SkillInlineText.tsx:32-57. Code and links keep literal text.
public enum MarkdownInlineSkills {
    private static let token = try! NSRegularExpression(pattern: #"(^|\s)\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:\s|$))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=\s|$)"#)
    public static func runs(_ runs: [InlineRun], skills: [ServerProviderSkill]) -> [InlineRun] {
        runs.flatMap { run in
            guard !run.code, run.link == nil else { return [run] }
            let text = run.text as NSString
            var result: [InlineRun] = [], cursor = 0
            for match in token.matches(in: run.text, range: NSRange(location: 0, length: text.length)) {
                let name = text.substring(with: match.range(at: 2))
                guard let skill = skills.first(where: { $0.name == name }) else { continue }
                let start = match.range.location + match.range(at: 1).length
                if start > cursor { var plain = run; plain.text = text.substring(with: NSRange(location: cursor, length: start - cursor)); result.append(plain) }
                var chip = run; chip.text = "$" + name; chip.skillLabel = ProviderSkills.displayName(skill); result.append(chip)
                cursor = match.range.upperBound
            }
            guard cursor > 0 else { return [run] }
            if cursor < text.length { var tail = run; tail.text = text.substring(from: cursor); result.append(tail) }
            return result
        }
    }
    public static func document(_ document: MarkdownDocument, skills: [ServerProviderSkill]) -> MarkdownDocument {
        guard !skills.isEmpty else { return document }
        func block(_ b: MarkdownBlock) -> MarkdownBlock {
            switch b {
            case .paragraph(let r): return .paragraph(runs(r, skills: skills))
            case .heading(let level, let r): return .heading(level: level, runs(r, skills: skills))
            case .blockquote(let children): return .blockquote(children.map(block))
            case .alert(let kind, let children): return .alert(kind, children.map(block))
            case .list(var list): list.items = list.items.map { var item = $0; item.blocks = item.blocks.map(block); return item }; return .list(list)
            case .table(var table): table.header = table.header.map { runs($0, skills: skills) }; table.rows = table.rows.map { $0.map { runs($0, skills: skills) } }; return .table(table)
            default: return b
            }
        }
        return MarkdownDocument(blocks: document.blocks.map(block))
    }
}

public enum MarkdownShellCommand {
    /// commandLabel.ts:1375-1390. Newlines and tabs retain their layout; other controls become visible.
    public static func visible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { value in
            let c = value.value
            return (c <= 8 || c == 11 || c == 12 || (14...31).contains(c)) ? UnicodeScalar(0x2400 + c)! : c == 127 ? UnicodeScalar(0x2421)! : value
        }))
    }
}
