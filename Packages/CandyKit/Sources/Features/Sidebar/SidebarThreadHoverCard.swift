import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What the thread hover card shows (`SidebarThreadTooltip`, Sidebar.tsx:428-572).
public struct SidebarThreadHoverCardModel: Equatable {
    public var title: String
    public var projectLabel: String?
    public var projectIcon: ProjectIconSource?
    public var environmentLabel: String?
    public var environmentMachine: String
    public var branch: String?
    /// "You're currently checked out on another branch." (`branchMismatch`, Sidebar.tsx:1350-1355, 498-505).
    public var branchMismatch = false
    /// The provider glyph's driver and "<model> · <instance>" or the model alone.
    public var provider: (driver: String, label: String)?
    /// The instance's accent when it shows a badge: an 8pt dot on the glyph (Sidebar.tsx:508-520).
    public var providerAccent: String?
    /// "Handed off from <names>".
    public var handedOffFrom: [String] = []
    public var terminalProcessCount = 0
    /// `runtime.lastError`: true for a usage limit ("Usage limit reached"), false for "Error occurred".
    public var errorIsUsageLimit: Bool?
    /// The footer's pull request rows, on servers with several pull requests per thread.
    public var pullRequests: SidebarPullRequestBadge?

    public init(title: String) { self.title = title; environmentMachine = "server" }

    public static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.projectLabel == b.projectLabel && a.projectIcon == b.projectIcon && a.environmentLabel == b.environmentLabel
            && a.environmentMachine == b.environmentMachine && a.branch == b.branch && a.branchMismatch == b.branchMismatch && a.provider?.driver == b.provider?.driver
            && a.provider?.label == b.provider?.label && a.providerAccent == b.providerAccent && a.handedOffFrom == b.handedOffFrom && a.terminalProcessCount == b.terminalProcessCount
            && a.errorIsUsageLimit == b.errorIsUsageLimit && a.pullRequests == b.pullRequests
    }
}

/// `ThreadHoverCardPopup` with `ThreadHoverCard` (ThreadHoverCard.tsx): the glass tooltip (`max-w-80`,
/// viewport `px-2 py-1`), then `flex flex-col gap-2 px-1 py-2`: the title (`text-xs leading-tight
/// font-medium`), the detail rows (`grid gap-1.5 pl-0.5 text-xs text-muted-foreground`, each a 12px glyph,
/// `gap-2`, the text at 75% foreground) and the pull request footer.
public final class SidebarThreadHoverCardView: DSView, PopupContent {
    private struct Row { let glyph: NSView; let label: LabelView; let tone: NSColor?; let muted: Bool; var block: TextBlockView? = nil; var hidden = false }
    private let decoration = BoxDecorationLayer()
    private let title = LabelView()
    private var rows: [Row] = []
    private let footer: ThreadPullRequestsMiniListView?
    private let divider = CALayer()

    public init(_ model: SidebarThreadHoverCardModel) {
        footer = model.pullRequests.map { ThreadPullRequestsMiniListView(badge: $0, drawsSurface: false) }.flatMap { $0.isEmpty ? nil : $0 }
        super.init(frame: .zero)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        var box = BoxStyle()
        box.radius = 8
        box.fill = PopupSurface.glassFill
        box.border = Themed.color(\.contrastForeground, 0.1)
        box.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.25)), BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.25))]
        decoration.boxStyle = box
        decoration.outset = 32
        title.text = model.title
        title.font = DSFont.ui(12, weight: .medium)
        title.lineHeight = 15 // `leading-tight`
        addSubview(title)
        func add(_ glyph: NSView, _ text: String, tone: NSColor? = nil, muted: Bool = false) {
            let l = LabelView(text, font: DSFont.ui(12))
            l.lineHeight = 16
            addSubview(glyph)
            addSubview(l)
            rows.append(Row(glyph: glyph, label: l, tone: tone, muted: muted))
        }
        let muted = Themed.color(\.mutedForeground)
        if let project = model.projectLabel {
            let favicon = ProjectMonogramView()
            favicon.projectTitle = model.projectIcon?.title ?? project
            favicon.source = model.projectIcon
            favicon.scale = 12.0 / 16.0
            add(favicon, project)
        }
        if let env = model.environmentLabel {
            add(EnvironmentMachineIcon.view(model.environmentMachine, size: 12, color: muted), env)
        }
        // The branch is a `MiddleTruncate` in the grid's `text-muted-foreground`, not at 75% foreground.
        if let branch = model.branch { add(IconView(name: .gitBranch, size: 12, strokeColor: muted), branch, muted: true) }
        // `items-start gap-2 text-warning`, the glyph `mt-0.5`, the text `leading-5`. Built with every branch
        // row: the checkout's branch arrives after the card opens (`branchMismatch`).
        if model.branch != nil {
            let tone = Themed.color(\.warning)
            add(IconView(name: .circleAlert, size: 12, strokeColor: tone), "", tone: tone)
            let block = TextBlockView()
            block.text = "You're currently checked out on another branch."
            block.font = DSFont.ui(12)
            block.lineHeight = 20
            block.balanced = true // the popup's `text-balance`
            addSubview(block)
            rows[rows.count - 1].block = block
            mismatchRow = rows.count - 1
        }
        if let provider = model.provider {
            let glyph = IconView(name: provider.driver == "codex" ? .brandOpenAI : .brandClaudeAI, size: 12, strokeColor: Themed.color(\.foreground))
            glyph.alphaValue = 0.6 // `grayscale opacity-60`; the badge stays saturated
            if let accent = model.providerAccent {
                add(ProviderBadgedIconView(glyph: glyph, badge: ProviderBadge(initials: "", accent: accent, size: .dot, overhang: 0, ring: Themed.color(\.card))),
                    provider.label)
            } else {
                add(glyph, provider.label)
            }
        }
        if !model.handedOffFrom.isEmpty {
            add(IconView(name: .arrowRightLeft, size: 12, strokeColor: muted), "Handed off from \(model.handedOffFrom.joined(separator: ", "))")
        }
        if model.terminalProcessCount > 0 {
            let n = model.terminalProcessCount
            add(IconView(name: .terminal, size: 12, strokeColor: Themed.base("teal-600", dark: "teal-300", 0.9)),
                "\(n) terminal \(n == 1 ? "process" : "processes") running")
        }
        if let usageLimit = model.errorIsUsageLimit {
            let tone = usageLimit ? Themed.color(\.warning) : Themed.color(\.error)
            add(IconView(name: .circleAlert, size: 12, strokeColor: tone), usageLimit ? "Usage limit reached" : "Error occurred", tone: tone)
        }
        if let footer {
            divider.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(divider)
            addSubview(footer)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(model.title)
        branchMismatch = model.branchMismatch
        applyMismatch()
    }

    private var mismatchRow: Int?
    /// Shows or hides the mismatch line; the caller repositions the popup for the new size.
    public var branchMismatch = false { didSet { if branchMismatch != oldValue { applyMismatch() } } }
    private func applyMismatch() {
        guard let i = mismatchRow else { return }
        rows[i].hidden = !branchMismatch
        rows[i].glyph.isHidden = !branchMismatch
        rows[i].block?.isHidden = !branchMismatch
        needsLayout = true
    }
    private var shown: [Row] { rows.filter { !$0.hidden } }

    /// The text column: up to `max-w-80` less the viewport's `px-2`, the card's `px-1`, the rows' `pl-0.5`.
    private static let maxWidth: CGFloat = 320

    public var popupSize: CGSize {
        let rows = shown
        let rowWidths = rows.map { 2 + 12 + 8 + ceil($0.block?.naturalWidth ?? $0.label.textWidth) }
        let content = max(ceil(title.textWidth), rowWidths.max() ?? 0, footer == nil ? 0 : 300)
        let width = min(Self.maxWidth, content + 2 * (8 + 4) + 2)
        let rowHeights: [CGFloat] = rows.map { height(of: $0, cardWidth: width) }
        let rowsHeight: CGFloat = rows.isEmpty ? 0 : rowHeights.reduce(0, +) + CGFloat(rows.count - 1) * 6
        let rowsBlock: CGFloat = rows.isEmpty ? 0 : 8 + rowsHeight
        var total: CGFloat = 4 + 8 + 15 + rowsBlock + 8 + 4 + 2
        if let footer { total += 8 + 1 + 8 + footer.popupSize.height - 16 }
        return CGSize(width: width, height: total)
    }
    public override var intrinsicContentSize: NSSize { popupSize }

    /// 16, or the wrapped block's lines at `leading-5`.
    private func height(of row: Row, cardWidth: CGFloat) -> CGFloat {
        row.block.map { $0.height(forWidth: max(0, cardWidth - 2 * (1 + 8 + 4) - 22)) } ?? 16
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let left: CGFloat = 1 + 8 + 4, right = bounds.width - 1 - 8 - 4
        var y: CGFloat = 1 + 4 + 8
        title.frame = NSRect(x: left, y: y, width: max(0, right - left), height: 15)
        y += 15 + 8
        for r in shown {
            r.glyph.frame = NSRect(x: left + 2, y: y + 2, width: 12, height: 12)
            let h = height(of: r, cardWidth: bounds.width)
            r.label.frame = NSRect(x: left + 2 + 12 + 8, y: y, width: max(0, right - left - 22), height: 16)
            r.block?.frame = NSRect(x: left + 2 + 12 + 8, y: y, width: max(0, right - left - 22), height: h)
            y += h + 6
        }
        if let footer {
            y += 2
            divider.frame = CGRect(x: left, y: y, width: right - left, height: 1)
            footer.frame = NSRect(x: left - 8, y: y + 1, width: right - left + 16, height: footer.popupSize.height)
        }
    }

    public override func updateLayer() {
        // Redesign: a card, 12 like the popup blur under it; T3's 8 elsewhere.
        let radius: CGFloat = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? DitherChrome.cardRadius : 8
        if decoration.boxStyle.radius != radius { decoration.boxStyle.radius = radius }
        decoration.setNeedsDisplay()
        title.color = Themed.color(\.foreground)
        for r in rows {
            r.label.color = r.tone ?? (r.muted ? Themed.color(\.mutedForeground) : Themed.color(\.foreground, 0.75))
            r.block?.color = r.label.color
        }
        divider.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }
}
