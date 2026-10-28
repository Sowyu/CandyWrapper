import AppKit
import DesignSystem
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
                var chip = run; chip.text = "$" + name; chip.skillLabel = ProviderSkills.displayName(skill); chip.skill = skill; result.append(chip)
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

/// Shared by message and composer chips (T3 3814 SkillInlineText.tsx:72-109).
public final class SkillDetailsView: DSView {
    private let title: LabelView
    private let detail: TextBlockView
    private let instructions = ButtonView("View instructions", variant: .outline, size: .sm)
    private let showsInstructions: Bool

    public static func description(_ skill: ServerProviderSkill) -> String {
        for value in [skill.description, skill.shortDescription] {
            if let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return "No description is available for this skill."
    }

    public init(skill: ServerProviderSkill, onViewInstructions: (@MainActor () -> Void)?) {
        title = LabelView(ProviderSkills.displayName(skill), font: DSFont.ui(14, weight: .medium))
        detail = TextBlockView(Self.description(skill), font: DSFont.ui(14), lineHeight: 20)
        showsInstructions = onViewInstructions != nil && !skill.path.isEmpty
        super.init(frame: .zero)
        [title, detail, instructions].forEach(addSubview)
        instructions.isHidden = !showsInstructions
        instructions.action = onViewInstructions
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 16 + 20 + 12 + detail.height(forWidth: 304) + (showsInstructions ? 44 : 0))
    }
    public override func layout() {
        super.layout()
        title.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 20)
        let h = detail.height(forWidth: bounds.width - 16)
        detail.frame = NSRect(x: 8, y: 40, width: bounds.width - 16, height: h)
        instructions.frame = NSRect(x: 8, y: 52 + h, width: instructions.intrinsicContentSize.width, height: 32)
    }
    public static func show(skill: ServerProviderSkill, from view: NSView, onViewInstructions: (@MainActor () -> Void)?) {
        PopoverView(content: SkillDetailsView(skill: skill, onViewInstructions: onViewInstructions), padding: .compact, width: .auto)
            .show(from: view, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4, fallbackAxisSide: .end))
    }
}
