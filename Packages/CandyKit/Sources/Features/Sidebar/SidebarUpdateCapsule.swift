import AppKit
import QuartzCore
import DesignSystem

/// T3's `SidebarUpdateCapsule` (5258 sidebar/SidebarUpdateCapsule.tsx:80-243): while an update pass runs, the update
/// button becomes a capsule that names its progress. In a narrow footer it stays the 32pt round icon; from a 5rem
/// container (12rem while the restart countdown shows) it takes the row's free width with the label at its left and
/// Later, Retry or Dismiss at its right, over a 200ms width transition. A click opens a popover with a line per machine.
/// The app fills `Capsule` from its run; the pill keeps drawing the icon, so its download ring and badges carry over.
public struct SidebarUpdateCapsule: Equatable, Sendable {
    public typealias Action = UpdateEverythingLogic.CapsuleView.Action
    public var view: UpdateEverythingLogic.CapsuleView
    /// `restartSeconds`: the countdown replaces the icon with "{n}s".
    public var countdown: Int?
    public var popover: Popover

    /// The popover's lines (SidebarUpdateCapsule.tsx:186-240).
    public struct Popover: Equatable, Sendable {
        public enum Local: Equatable, Sendable { case status(String), restartToUpdate }
        public struct Row: Equatable, Sendable {
            public var label: String, status: String, failed: Bool, failure: String?
            public init(label: String, status: String, failed: Bool, failure: String?) {
                self.label = label; self.status = status; self.failed = failed; self.failure = failure
            }
        }
        /// "This app": its status while it installs last, or a Restart to update button once it waits.
        public var local: Local?
        public var rows: [Row]
        /// The ghost Dismiss beside Retry or Later when every machine settled and one failed.
        public var showsDismiss: Bool
        public init(local: Local?, rows: [Row], showsDismiss: Bool) { self.local = local; self.rows = rows; self.showsDismiss = showsDismiss }
    }

    public init(view: UpdateEverythingLogic.CapsuleView, countdown: Int?, popover: Popover) {
        self.view = view; self.countdown = countdown; self.popover = popover
    }

    /// `aria-label`: the label, with the slow machine's status and time.
    public var accessibilityLabel: String { view.slow.map { "\(view.label) \($0.status) \($0.elapsed)" } ?? view.label }
}

/// The capsule's Later, Retry or Dismiss: `pr-3 pl-1.5 text-xs underline decoration-muted-foreground/60
/// underline-offset-3 hover:decoration-current`.
final class SidebarUpdateCapsuleLink: ControlView {
    let label = LabelView("", font: DSFont.ui(12))
    private let line = CALayer()
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        line.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
        setAccessibilityRole(.button)
        restyle()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.text }
        set { label.text = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }
    /// Text plus `pl-1.5` and `pr-3`.
    var preferredWidth: CGFloat { (label.textWidth).rounded(.up) + 6 + 12 }

    override func layout() {
        super.layout()
        let h: CGFloat = 16
        label.frame = NSRect(x: 6, y: (bounds.height - h) / 2, width: max(0, bounds.width - 18), height: h)
        // `underline-offset-3`: 3pt below the baseline, 1pt thick.
        let f = label.font
        let baseline = label.frame.minY + (h - (f.ascender - f.descender)) / 2 + f.ascender
        line.frame = CGRect(x: label.frame.minX, y: baseline + 3, width: label.frame.width, height: 1)
        restyle()
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let fg = Themed.color(\.sidebarForeground, sidebar: true)
        label.color = fg
        let decoration = state.hovered ? fg : Themed.color(\.mutedForeground, 0.6, sidebar: true)
        line.backgroundColor = decoration.cgColor(in: self)
    }

    override func performAction() { onPress?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The capsule's popover body: `flex flex-col gap-1 text-xs` in a compact `sm` popover.
final class SidebarUpdateCapsulePopoverView: DSView {
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onRestart: (() -> Void)?
    private var rows: [(NSView, CGFloat)] = []
    private let width: CGFloat = 256 - 24

    func configure(_ capsule: SidebarUpdateCapsule) {
        subviews.forEach { $0.removeFromSuperview() }
        rows = []
        let fg = Themed.color(\.contrastPopoverForeground)
        let muted = Themed.color(\.mutedForeground)
        func line(_ left: String, right: NSView) -> NSView {
            let row = DSView()
            let name = LabelView(left, font: DSFont.ui(12), color: fg)
            name.lineHeight = 16
            row.addSubview(name)
            row.addSubview(right)
            let rw = right is ButtonView ? right.fittingSize.width : ((right as? LabelView)?.textWidth ?? 0).rounded(.up)
            let rh: CGFloat = right is ButtonView ? right.fittingSize.height : 16
            let h = max(16, rh)
            right.frame = NSRect(x: width - rw, y: (h - rh) / 2, width: rw, height: rh)
            name.frame = NSRect(x: 0, y: (h - 16) / 2, width: max(0, width - rw - 12), height: 16)
            row.frame.size = NSSize(width: width, height: h)
            return row
        }
        func status(_ text: String, failed: Bool = false) -> LabelView {
            let l = LabelView(text, font: DSFont.ui(12).monospacedDigits, color: failed ? Themed.color(\.destructive) : muted)
            l.lineHeight = 16
            return l
        }
        switch capsule.popover.local {
        case .status(let text): add(line("This app", right: status(text)))
        case .restartToUpdate:
            let restart = ButtonView("Restart to update", variant: .outline, size: .xs)
            restart.action = { [weak self] in self?.onRestart?() }
            add(line("This app", right: restart))
        case nil: break
        }
        for r in capsule.popover.rows {
            add(line(r.label, right: status(r.status, failed: r.failed)))
            if let failure = r.failure {
                let text = TextBlockView(failure, font: DSFont.ui(12), lineHeight: 16, color: muted)
                text.frame.size = NSSize(width: width, height: text.layout(forWidth: width).height)
                add(text, gap: 0)
            }
        }
        if let action = capsule.view.action {
            let row = DSView()
            var buttons = [ButtonView(action.rawValue, variant: .outline, size: .xs)]
            buttons[0].action = { [weak self] in self?.onAction?() }
            if capsule.popover.showsDismiss {
                let dismiss = ButtonView("Dismiss", variant: .ghost, size: .xs)
                dismiss.action = { [weak self] in self?.onDismiss?() }
                buttons.append(dismiss)
            }
            var x = width
            var h: CGFloat = 0
            // `mt-1 flex justify-end gap-1`.
            for b in buttons.reversed() {
                let size = b.fittingSize
                x -= size.width
                b.frame = NSRect(x: x, y: 0, width: size.width, height: size.height)
                row.addSubview(b)
                x -= 4
                h = max(h, size.height)
            }
            row.frame.size = NSSize(width: width, height: h)
            add(row, gap: 4 + 4)
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func add(_ view: NSView, gap: CGFloat = 4) {
        addSubview(view)
        rows.append((view, rows.isEmpty ? 0 : gap))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: rows.reduce(0) { $0 + $1.1 + $1.0.frame.height })
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (view, gap) in rows {
            y += gap
            view.frame.origin = NSPoint(x: 0, y: y)
            y += view.frame.height
        }
    }

    /// The visible lines, for tests.
    var texts: [String] {
        func walk(_ v: NSView) -> [String] {
            if let l = v as? LabelView { return [l.text] }
            if let b = v as? ButtonView { return [b.title ?? ""] }
            return v.subviews.flatMap(walk)
        }
        return walk(self)
    }
}

// MARK: The pill as a capsule

extension SidebarUpdatePillView {
    private var dither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private var iconSide: CGFloat { min(bounds.width, bounds.height) }
    /// The capsule shows its label: wider than its round icon.
    var isCapsuleExpanded: Bool { capsule != nil && bounds.width > iconSide + 0.5 }

    /// The pill's width in a footer row `available` wide, `side` tall (SidebarUpdateCapsule.tsx:126-131). Redesign's
    /// capsule sits in the account row, so it grows only to its content and leaves the account's name the rest.
    public func capsuleWidth(available: CGFloat, side: CGFloat) -> CGFloat {
        guard let capsule, UpdateEverythingLogic.capsuleExpands(available: available, counting: capsule.countdown != nil) else { return side }
        guard dither else { return available }
        let end = capsule.view.action != nil ? capsuleLink.preferredWidth : side
        let natural = RedesignTokens.Space.s + capsuleLabel.textWidth.rounded(.up) + end
        return max(side, min(available, natural))
    }

    func capsuleChanged(from old: SidebarUpdateCapsule?) {
        if let capsule {
            let view = capsule.view
            capsuleLabel.text = view.label + (view.slow.map { " \($0.elapsed)" } ?? "")
            capsuleLink.text = view.action?.rawValue ?? ""
            countdownLabel.text = capsule.countdown.map { "\($0)s" } ?? ""
            if let open = capsulePopup, let body = (open.content as? PopoverView)?.content as? SidebarUpdateCapsulePopoverView {
                body.configure(capsule)
                window.map { PopupHost.host(for: $0).reposition(open) }
            }
        } else {
            closeCapsulePopover()
            drawnCapsuleWidth = nil
            labelShown = false
        }
        // The capsule's rule reads the countdown and the action, so the sidebar sizes it again.
        if old?.countdown == nil || capsule?.countdown == nil || old?.view.action != capsule?.view.action
            || old?.view.label != capsule?.view.label || (old == nil) != (capsule == nil) {
            onCapsuleLayoutChange?()
        }
        refresh()
        needsLayout = true
    }

    func layoutCapsule(iconArea: NSRect) {
        let shapes = [capsuleFill, capsuleHover, capsuleRing]
        guard let capsule else {
            shapes.forEach { $0.isHidden = true }
            countdownRing.isHidden = true
            for v in [capsuleLabel, capsuleLink, countdownLabel] as [NSView] { v.isHidden = true }
            iconBox.isHidden = false
            ringTrack.opacity = 1; ringArc.opacity = 1
            return
        }
        let expanded = isCapsuleExpanded
        let h = bounds.height
        let radius = dither ? RedesignTokens.Radius.control : h / 2
        func shape(_ width: CGFloat, inset: CGFloat = 0) -> CGPath {
            let r = CGRect(x: bounds.width - width, y: 0, width: width, height: h).insetBy(dx: inset, dy: inset)
            return CGPath(roundedRect: r, cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset), transform: nil)
        }
        let width = bounds.width
        let from = drawnCapsuleWidth
        for l in shapes {
            l.isHidden = false
            l.frame = bounds
            l.path = shape(width, inset: l === capsuleRing ? 0.5 : 0)
        }
        // `transition-[width] duration-200 ease-out`; Redesign moves on its own curve.
        if let from, from != width, window != nil, !Motion.reduced {
            for l in shapes {
                let a = CABasicAnimation(keyPath: "path")
                a.fromValue = shape(from, inset: l === capsuleRing ? 0.5 : 0)
                a.toValue = l.path
                if dither {
                    a.duration = RedesignTokens.Motion.standard
                    a.timingFunction = RedesignTokens.Motion.curve
                } else {
                    a.duration = 0.2
                    a.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
                }
                l.add(a, forKey: "width")
            }
        }
        drawnCapsuleWidth = width
        let action = capsule.view.action
        let hidesIcon = expanded && action != nil
        iconBox.isHidden = hidesIcon || capsule.countdown != nil
        ringTrack.opacity = iconBox.isHidden ? 0 : 1
        ringArc.opacity = iconBox.isHidden ? 0 : 1
        countdownLabel.isHidden = capsule.countdown == nil || hidesIcon
        countdownLabel.frame = NSRect(x: iconArea.minX, y: (h - 16) / 2, width: iconArea.width, height: 16)
        // `ring-1 ring-current/22 ring-inset` round the seconds. Redesign shows the digits alone.
        countdownRing.isHidden = countdownLabel.isHidden || dither
        countdownRing.frame = bounds
        countdownRing.path = CGPath(ellipseIn: iconArea.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        capsuleLink.isHidden = !(expanded && action != nil)
        let linkWidth = capsuleLink.isHidden ? 0 : min(capsuleLink.preferredWidth, bounds.width)
        capsuleLink.frame = NSRect(x: bounds.width - linkWidth, y: 0, width: linkWidth, height: h)
        let wasShown = labelShown
        capsuleLabel.isHidden = !expanded
        labelShown = expanded
        let lx: CGFloat = dither ? RedesignTokens.Space.s : 12 // `pl-3`
        let end = capsuleLink.isHidden ? iconArea.minX : capsuleLink.frame.minX
        capsuleLabel.frame = NSRect(x: lx, y: (h - 16) / 2, width: max(0, end - lx), height: 16)
        // `starting:opacity-0` with `transition-opacity duration-200 ease-out`: the label and link fade in as they show.
        if expanded, !wasShown, window != nil, !Motion.reduced {
            for v in [capsuleLabel, capsuleLink] where !v.isHidden {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0
                a.toValue = 1
                a.duration = dither ? RedesignTokens.Motion.standard : 0.2
                a.timingFunction = dither ? RedesignTokens.Motion.curve : CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
                v.layer?.add(a, forKey: "fade")
            }
        }
    }

    func restyleCapsule() {
        guard let capsule else { return }
        let dark = effectiveAppearance.isDark
        let fg = Themed.color(\.sidebarForeground, sidebar: true)
        let tone: NSColor? = switch capsule.view.tone {
        case .slow: Themed.color(\.warning, 0.4, sidebar: true)
        case .failed: Themed.color(\.destructive, 0.4, sidebar: true)
        case .default: nil
        }
        // Hover is the trigger's `hover:bg-sidebar-row-hover` over the surface.
        let hovered = state.hovered || capsulePopup != nil
        if dither {
            capsuleFill.fillColor = RedesignTokens.Card.fill.cgColor(in: self)
            capsuleHover.fillColor = RedesignTokens.State.fill(state, dark: dark)?.cgColor(in: self)
                ?? (capsulePopup != nil ? RedesignTokens.State.fill(RedesignTokens.State.pressed, dark: dark).cgColor(in: self) : nil)
            capsuleRing.strokeColor = (tone ?? RedesignTokens.Card.border).cgColor(in: self)
        } else {
            capsuleFill.fillColor = Themed.color(\.sidebarControlSurface, sidebar: true).cgColor(in: self)
            capsuleHover.fillColor = hovered ? Themed.color(\.sidebarRowHover, sidebar: true).cgColor(in: self) : nil
            capsuleRing.strokeColor = tone?.cgColor(in: self)
        }
        capsuleRing.isHidden = capsuleRing.strokeColor == nil
        let view = capsule.view
        if view.tone == .failed {
            capsuleLabel.color = Themed.color(\.destructive, sidebar: true)
            capsuleLabel.prefixColor = nil
        } else if view.slow != nil {
            // The machine in the foreground, its time in `text-warning`.
            capsuleLabel.color = Themed.color(\.warning, sidebar: true)
            capsuleLabel.prefixColor = (view.label.utf16.count, fg)
        } else {
            capsuleLabel.color = fg
            capsuleLabel.prefixColor = nil
        }
        countdownLabel.color = fg
        countdownRing.strokeColor = fg.cgColor(in: self).copy(alpha: fg.cgColor(in: self).alpha * 0.22)
        capsuleLink.needsDisplay = true
    }

    // MARK: Popover (`PopoverPopup side="top" align="end" padding="compact" width="sm"`)

    func toggleCapsulePopover() {
        if capsulePopup != nil { closeCapsulePopover(); return }
        guard let capsule, let host = popupHost else { return }
        let body = SidebarUpdateCapsulePopoverView()
        body.configure(capsule)
        body.onAction = { [weak self] in self?.runCapsuleAction() }
        body.onDismiss = { [weak self] in self?.onCapsuleDismiss?() }
        body.onRestart = { [weak self] in self?.onCapsuleRestart?() }
        let popover = PopoverView(content: body, padding: .compact, width: .sm)
        capsulePopup = host.open(popover, trigger: self, placement: PopupPlacement(side: .top, align: .end, sideOffset: 4), motion: .popover)
        capsulePopup?.onClose = { [weak self] in self?.capsulePopup = nil; self?.restyle() }
        restyle()
    }

    func closeCapsulePopover() {
        guard let open = capsulePopup else { return }
        capsulePopup = nil
        window.map { PopupHost.host(for: $0).close(open, returnFocus: false) }
    }

    func runCapsuleAction() {
        guard let action = capsule?.view.action else { return }
        onCapsuleAction?(action)
    }

    /// The open popover's lines, for tests.
    var capsulePopoverTexts: [String]? { ((capsulePopup?.content as? PopoverView)?.content as? SidebarUpdateCapsulePopoverView)?.texts }
}
