import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `FeedCard` with its `CardHead` (WorkflowRunFeed.tsx:1371-1432): a mark, the name in `text-base leading-6
/// font-semibold`, actions at the end, a muted `text-xs` line under it `mt-0.5`, then the card's own blocks.
final class WorkflowCardView: DSView {
    enum Mark { case none, icon(IconName, NSColor, CGFloat), chip(String), dot }
    enum Block {
        /// `mt-3 text-sm` and `whitespace-pre-wrap`, or `mt-2 text-xs muted` when `small`.
        case text(String, top: CGFloat, small: Bool = false, color: NSColor? = nil)
        /// `Facts` (:1462-1479): a two-column list of names and values, `mt-3 gap-x-4 gap-y-1.5`.
        case facts([(label: String, value: String)])
        /// The agent's reply under a rule (`mt-3 border-t border-border/60 pt-3`), cut with Show more.
        case reply(String)
        /// "said" in a sentence with the choice in bold (:1561-1595).
        case said(String, bold: String, rest: String)
        /// A failure under a `CircleAlertIcon` (:1795-1801).
        case failure(String)
        /// One quick step: its name in bold and its result's lines (:1497-1509).
        case quick(String, [(label: String?, value: String)])
    }

    var onToggleMore: (() -> Void)?
    private var markIcon = IconView(name: .check, size: 14)
    private let chip = WorkflowChipView()
    private var mark: Mark = .none
    private let name = LabelView("", font: DSFont.ui(16, weight: .semibold), color: Themed.color(\.foreground))
    private let sub = TextBlockView()
    private var actions: [NSView] = []
    private var blocks: [(Block, [NSView])] = []
    private var ruleY: CGFloat?
    private var dotTone = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.lineHeight = 24
        sub.font = DSFont.ui(12)
        sub.lineHeight = 16
        sub.color = Themed.color(\.mutedForeground)
        for v in [markIcon, chip, name, sub] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    override var isFlipped: Bool { true }

    func set(mark: Mark, name text: String, sub subText: String?, actions: [NSView], blocks: [Block], label: String? = nil) {
        self.mark = mark
        markIcon.isHidden = true
        chip.isHidden = true
        switch mark {
        case .icon(let icon, let color, let size):
            markIcon.removeFromSuperview()
            markIcon = IconView(name: icon, size: size, strokeColor: color)
            addSubview(markIcon)
        case .chip(let n): chip.isHidden = false; chip.name = n
        default: break
        }
        name.text = text
        sub.text = subText ?? ""
        sub.isHidden = (subText ?? "").isEmpty
        self.actions.forEach { $0.removeFromSuperview() }
        self.actions = actions
        actions.forEach(addSubview)
        self.blocks.forEach { $0.1.forEach { $0.removeFromSuperview() } }
        self.blocks = blocks.map { b in (b, views(for: b)) }
        self.blocks.forEach { $0.1.forEach(addSubview) }
        setAccessibilityLabel(label ?? text)
        needsLayout = true
        needsDisplay = true
    }

    /// Changes only the line under the name, so a ticking time leaves the rest of the card alone.
    func setSub(_ text: String) { if sub.text != text { sub.text = text; sub.isHidden = text.isEmpty; needsLayout = true } }

    private func text(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> TextBlockView {
        let t = TextBlockView()
        t.text = s
        t.font = DSFont.ui(size, weight: weight)
        t.lineHeight = size == 12 ? 16 : 20
        t.color = color
        return t
    }

    private func views(for b: Block) -> [NSView] {
        let fg = Themed.color(\.foreground), muted = Themed.color(\.mutedForeground)
        switch b {
        case .text(let s, _, let small, let color): return [text(s, size: small ? 12 : 14, color: color ?? (small ? muted : fg))]
        case .facts(let facts):
            return facts.flatMap { f -> [NSView] in
                let l = LabelView(f.label, font: DSFont.ui(14), color: muted); l.lineHeight = 20
                return [l, text(f.value, size: 14, color: fg)]
            }
        case .reply(let s):
            let m = MarkdownView(frame: .zero)
            m.setMarkdown(s)
            var v: [NSView] = [m]
            if onToggleMore != nil {
                let more = WorkflowTextButton("")
                more.underlined = true
                more.action = { [weak self] in self?.onToggleMore?() }
                v.append(more)
            }
            return v
        case .said(let lead, let bold, let rest):
            // The choice in `font-semibold`, through Markdown with the words escaped.
            func esc(_ s: String) -> String { s.replacingOccurrences(of: #"([\\`*_\[\]#<>!|~])"#, with: #"\\$1"#, options: .regularExpression) }
            let m = MarkdownView(frame: .zero)
            m.setMarkdown(esc(lead) + "**" + esc(bold) + "**" + esc(rest))
            return [m]
        case .failure(let s):
            let icon = IconView(name: .circleAlert, size: 14)
            icon.strokeColor = Themed.color(\.destructive)
            return [icon, text(s, size: 14, color: Themed.color(\.destructive))]
        case .quick(let n, let lines):
            var v: [NSView] = [text(n, size: 14, color: fg, weight: .semibold)]
            if lines.allSatisfy({ $0.label == nil }) {
                v += lines.map { text($0.value, size: 14, color: fg) }
            } else {
                v += lines.flatMap { l -> [NSView] in
                    let k = LabelView(l.label ?? "", font: DSFont.ui(14), color: muted); k.lineHeight = 20
                    return [k, text(l.value, size: 14, color: fg)]
                }
            }
            return v
        }
    }

    /// The "Show more" or "Show less" under a cut reply.
    func setMoreTitle(_ title: String) {
        for (b, v) in blocks { if case .reply = b, let more = v.last as? WorkflowTextButton { more.title = title } }
    }

    func height(forWidth w: CGFloat) -> CGFloat { place(width: w, apply: false) }
    override func layout() { super.layout(); _ = place(width: bounds.width, apply: true) }

    private func place(width w: CGFloat, apply: Bool) -> CGFloat {
        func set(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        // Head: `flex items-center gap-2`, the mark in an `h-6` box.
        var x: CGFloat = 0
        switch mark {
        case .icon(_, _, let size): set(markIcon, NSRect(x: 0, y: (24 - size) / 2, width: size, height: size)); x = size + 8
        case .chip: set(chip, NSRect(x: 0, y: 4, width: 16, height: 16)); x = 24
        case .dot: x = 6 + 8
        case .none: break
        }
        var right = w
        for a in actions.reversed() {
            let aw = a.fittingSize.width
            set(a, NSRect(x: right - aw, y: (24 - a.fittingSize.height) / 2, width: aw, height: a.fittingSize.height))
            right -= aw + 8
        }
        set(name, NSRect(x: x, y: 0, width: max(0, right - x), height: 24))
        // A card with no head, such as the quick steps', starts with its blocks.
        let headless = name.text.isEmpty && actions.isEmpty
        name.isHidden = headless
        var y: CGFloat = headless ? 0 : 24
        if !sub.isHidden {
            let h = sub.height(forWidth: w)
            set(sub, NSRect(x: 0, y: y + 2, width: w, height: h))
            y += 2 + h
        }
        var rule: CGFloat?
        for (b, vs) in blocks {
            switch b {
            case .text(_, let top, _, _):
                let t = vs[0] as! TextBlockView
                y += top
                let h = t.height(forWidth: w)
                set(t, NSRect(x: 0, y: y, width: w, height: h)); y += h
            case .said:
                let t = vs[0] as! MarkdownView
                y += 12
                let h = t.height(forWidth: w)
                set(t, NSRect(x: 0, y: y, width: w, height: h)); y += h
            case .failure:
                y += 12
                let t = vs[1] as! TextBlockView
                set(vs[0], NSRect(x: 0, y: y + 3, width: 14, height: 14))
                let h = t.height(forWidth: w - 20)
                set(t, NSRect(x: 20, y: y, width: w - 20, height: h)); y += h
            case .facts:
                y += 12
                // `grid-cols-[minmax(0,max-content)_minmax(0,1fr)]`.
                let labels = stride(from: 0, to: vs.count, by: 2).map { vs[$0] as! LabelView }
                let lw = min(w / 2, labels.map { ceil($0.textWidth) + 1 }.max() ?? 0)
                for i in stride(from: 0, to: vs.count, by: 2) {
                    if i > 0 { y += 6 }
                    let v = vs[i + 1] as! TextBlockView
                    let h = max(20, v.height(forWidth: w - lw - 16))
                    set(vs[i], NSRect(x: 0, y: y, width: lw, height: 20))
                    set(v, NSRect(x: lw + 16, y: y, width: max(0, w - lw - 16), height: h))
                    y += h
                }
            case .reply:
                y += 12
                rule = y
                y += 1 + 12
                let m = vs[0] as! MarkdownView
                let h = m.height(forWidth: w)
                set(m, NSRect(x: 0, y: y, width: w, height: h)); y += h
                if vs.count > 1, let more = vs[1] as? WorkflowTextButton {
                    y += 4
                    set(more, NSRect(x: 0, y: y, width: more.preferredWidth, height: 16)); y += 16
                }
            case .quick:
                if y > 0 { y += 6 }
                let t = vs[0] as! TextBlockView
                let h = t.height(forWidth: w)
                set(t, NSRect(x: 0, y: y, width: w, height: h)); y += h
                let rest = Array(vs.dropFirst())
                if rest.first is LabelView {
                    y += 12
                    let labels = stride(from: 0, to: rest.count, by: 2).map { rest[$0] as! LabelView }
                    let lw = min(w / 2, labels.map { ceil($0.textWidth) + 1 }.max() ?? 0)
                    for i in stride(from: 0, to: rest.count, by: 2) {
                        if i > 0 { y += 6 }
                        let v = rest[i + 1] as! TextBlockView
                        let vh = max(20, v.height(forWidth: w - lw - 16))
                        set(rest[i], NSRect(x: 0, y: y, width: lw, height: 20))
                        set(v, NSRect(x: lw + 16, y: y, width: max(0, w - lw - 16), height: vh))
                        y += vh
                    }
                } else if !rest.isEmpty {
                    y += 12
                    for (i, v) in rest.enumerated() {
                        if i > 0 { y += 4 }
                        let t = v as! TextBlockView
                        let vh = t.height(forWidth: w)
                        set(t, NSRect(x: 0, y: y, width: w, height: vh)); y += vh
                    }
                }
            }
        }
        if apply { ruleY = rule; needsDisplay = true }
        return y
    }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if case .dot = mark {
            Themed.color(\.info).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 9, width: 6, height: 6)).fill()
        }
        if let ruleY {
            Themed.color(\.border, 0.6).setFill()
            NSRect(x: 0, y: ruleY, width: bounds.width, height: 1).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
