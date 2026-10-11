import AppKit
import QuartzCore
import DesignSystem

/// T3's `SidebarUpdateReleaseNotes` (sidebar/SidebarUpdateReleaseNotes.tsx:46-120) on a `PopoverPopup
/// tooltipStyle` (popover.tsx:89-107): the glass surface at `rounded-md`, `shadow-md/5`, `py-1 px-2`.
/// A header, then one section per release (newest first) with its bullets and a GitHub link.
public final class SidebarUpdateReleaseNotesView: DSView, PopupContent {
    var onOpenURL: ((String) -> Void)?
    /// The pointer is over the popup: the pill keeps it open.
    var onPointerInside: ((Bool) -> Void)?

    private let decoration = BoxDecorationLayer()
    private let body = DSView()
    private lazy var scroll = ScrollAreaView(documentView: body)
    /// Wraps like T3's header `div`: a long status line ("Update 0.1.3 downloaded. Click to...") takes two lines.
    private let title = TextBlockView()
    private let version = LabelView("", font: DSFont.ui(12), color: Themed.color(\.contrastMutedForeground))
    private var blocks: [Block] = []
    private var model: (state: DesktopUpdateState, tooltip: String)?

    private enum Block {
        case heading(LabelView)
        case bullet(TextBlockView, CALayer)
        case link(ReleaseLinkView)
        case separator(SeparatorView)
    }

    /// `max-w-[min(24rem,100vw-2rem)]` for the content, inside the viewport's 8px sides.
    static let maxContentWidth: CGFloat = 384
    /// `max-h-[min(28rem,100vh-6rem)]` for the scrolling body.
    static let maxBodyHeight: CGFloat = 448

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        decoration.outset = 16
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        var box = PopupSurface.glass.box(radius: 8, beforeLine: true)
        // `tooltipStyle`: `shadow-md/5` in place of the popover's deep drop shadow.
        box.shadows = [BoxShadow(y: 4, blur: 6, spread: -1, color: Themed.black(0.05)),
                       BoxShadow(y: 2, blur: 4, spread: -2, color: Themed.black(0.05))]
        decoration.boxStyle = box
        title.font = DSFont.ui(14, weight: .medium)
        title.color = Themed.color(\.contrastPopoverForeground)
        title.lineHeight = 20
        version.lineHeight = 16
        addSubview(title)
        addSubview(version)
        scroll.hideScrollbars = false
        addSubview(scroll)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Nightly update release notes")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ state: DesktopUpdateState, tooltip: String) {
        guard model?.state != state || model?.tooltip != tooltip else { return }
        model = (state, tooltip)
        if state.status == .available {
            title.text = "Update ready to download"
            version.text = state.availableVersion ?? ""
        } else {
            title.text = tooltip
            version.text = ""
        }
        version.isHidden = version.text.isEmpty
        for b in blocks {
            switch b {
            case .heading(let v): v.removeFromSuperview()
            case .bullet(let v, let d): v.removeFromSuperview(); d.removeFromSuperlayer()
            case .link(let v): v.removeFromSuperview()
            case .separator(let v): v.removeFromSuperview()
            }
        }
        blocks = []
        func add(_ b: Block) {
            switch b {
            case .heading(let v): body.addSubview(v)
            case .bullet(let v, let d): body.addSubview(v); body.layer?.addSublayer(d)
            case .link(let v): body.addSubview(v)
            case .separator(let v): body.addSubview(v)
            }
            blocks.append(b)
        }
        for (index, note) in state.releaseNotes.enumerated() {
            if index > 0 { add(.separator(SeparatorView())) }
            let h = LabelView(index == 0 ? "What's changed" : "Changes in \(note.version)", font: DSFont.ui(12, weight: .semibold),
                              color: Themed.color(\.contrastForeground))
            h.lineHeight = 16
            add(.heading(h))
            for item in note.items {
                let t = TextBlockView()
                t.text = item
                t.font = DSFont.ui(12)
                t.lineHeight = 20
                t.color = Themed.color(\.contrastPopoverForeground, 0.9)
                let disc = CALayer()
                disc.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
                disc.backgroundColor = Themed.color(\.contrastPopoverForeground, 0.9).cgColor(in: self)
                add(.bullet(t, disc))
            }
            if let url = DesktopUpdateLogic.releaseURL(note.version) {
                let omitted = max(0, note.totalItems - note.items.count)
                let label = omitted == 0 ? "View release on GitHub" : "\(omitted) more \(omitted == 1 ? "change" : "changes") on GitHub"
                add(.link(makeLink(label, url)))
            }
        }
        if state.omittedReleaseCount > 0 {
            let n = state.omittedReleaseCount
            add(.separator(SeparatorView()))
            add(.link(makeLink("\(n) older \(n == 1 ? "release" : "releases") on GitHub", DesktopUpdateLogic.releaseHistoryURL)))
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func makeLink(_ label: String, _ url: String) -> ReleaseLinkView {
        let link = ReleaseLinkView(label)
        link.action = { [weak self] in self?.onOpenURL?(url) }
        return link
    }

    // MARK: Size and layout

    /// `w-fit`: as wide as the widest line, up to the cap.
    private var contentWidth: CGFloat {
        var w = max(title.naturalWidth, version.textWidth)
        for b in blocks {
            switch b {
            case .heading(let v): w = max(w, v.textWidth)
            case .bullet(let t, _): w = max(w, 16 + t.naturalWidth)
            case .link(let l): w = max(w, l.intrinsicContentSize.width)
            case .separator: break
            }
        }
        // `px-1` on the header and the body.
        return min(Self.maxContentWidth, ceil(w) + 8)
    }

    private func bodyHeight(width: CGFloat) -> CGFloat {
        var y: CGFloat = 16 // pt-4
        layoutBody(width: width) { y = $0 }
        return y + 4 // pb-1
    }

    /// Lays the body out at `width` (its own `px-1` inside) and reports the bottom.
    private func layoutBody(width: CGFloat, place: ((CGFloat) -> Void)? = nil) {
        let inner = width - 8
        var y: CGFloat = 16
        var previous: Block?
        for b in blocks {
            switch b {
            case .separator(let s):
                y += 12; s.frame = NSRect(x: 4, y: y, width: inner, height: 1); y += 1 + 12
            case .heading(let h):
                h.frame = NSRect(x: 4, y: y, width: inner, height: 16); y += 16
            case .bullet(let t, let disc):
                // `mt-2` before the list, `space-y-1.5` between items.
                if case .heading? = previous { y += 8 } else { y += 6 }
                let th = t.height(forWidth: inner - 16)
                t.frame = NSRect(x: 4 + 16, y: y, width: inner - 16, height: th)
                // The `list-disc` marker sits outside the text box, centered on the first line.
                disc.frame = CGRect(x: 4 + 16 - 10, y: y + 10 - 2, width: 4, height: 4)
                disc.cornerRadius = 2
                y += th
            case .link(let l):
                // `mt-2 inline-flex`.
                y += 8
                let s = l.intrinsicContentSize
                l.frame = NSRect(x: 4, y: y, width: min(s.width, inner), height: 20); y += 20
            }
            previous = b
        }
        place?(y)
    }

    private func headerHeight(_ cw: CGFloat) -> CGFloat {
        let th = max(20, title.height(forWidth: cw - 8))
        return version.isHidden ? th : th + 2 + 16
    }

    public var popupSize: CGSize {
        let cw = contentWidth
        let header = headerHeight(cw)
        let bodyH = min(Self.maxBodyHeight, bodyHeight(width: cw))
        // Viewport `py-1 px-2` plus the 1px border.
        return CGSize(width: cw + 16 + 2, height: header + bodyH + 8 + 2)
    }

    public override var intrinsicContentSize: NSSize { popupSize }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let cw = bounds.width - 18
        let th = max(20, title.height(forWidth: cw - 8))
        title.frame = NSRect(x: 9 + 4, y: 5, width: cw - 8, height: th)
        version.frame = NSRect(x: 9 + 4, y: 5 + th + 2, width: cw - 8, height: 16)
        let top: CGFloat = 5 + headerHeight(cw)
        let fullBody = bodyHeight(width: cw)
        scroll.frame = NSRect(x: 9, y: top, width: cw, height: max(0, bounds.height - top - 5))
        body.frame = NSRect(x: 0, y: 0, width: cw, height: fullBody)
        layoutBody(width: cw)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        for case .bullet(_, let disc) in blocks { disc.backgroundColor = Themed.color(\.contrastPopoverForeground, 0.9).cgColor(in: self) }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }
    public override func mouseExited(with event: NSEvent) { onPointerInside?(false) }

    /// The links, for tests.
    var linkTitles: [String] { blocks.compactMap { if case .link(let l) = $0 { l.title } else { nil } } }
}

/// `ReleaseLink` (SidebarUpdateReleaseNotes.tsx:22-44): 12px muted text with a dotted underline
/// (`underline-offset-4`) and a 12px external link glyph, `gap-1`; hover turns it foreground.
final class ReleaseLinkView: ControlView {
    let title: String
    private let label: LabelView
    private let icon = IconView(name: .externalLink, size: 12)
    private let underline = CAShapeLayer()

    init(_ title: String) {
        self.title = title
        label = LabelView(title, font: DSFont.ui(12))
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = .colors
        label.lineHeight = 20
        icon.strokeWidth = 2.25
        addSubview(label)
        addSubview(icon)
        underline.fillColor = nil
        underline.lineWidth = 1
        underline.lineDashPattern = [1, 1]
        underline.actions = ["path": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(underline)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 4 + 12, height: 20) }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let color = Themed.color(state.hovered || state.focusVisible ? \.contrastForeground : \.contrastMutedForeground)
        label.color = color
        icon.strokeColor = color
        underline.strokeColor = color.cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: 0, y: 0, width: w, height: 20)
        icon.frame = NSRect(x: w + 4, y: 4, width: 12, height: 12)
        // The decoration runs under the text only; the glyph is its own flex item.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 18.5)); path.addLine(to: CGPoint(x: w, y: 18.5))
        underline.frame = bounds
        underline.path = path
    }
}
