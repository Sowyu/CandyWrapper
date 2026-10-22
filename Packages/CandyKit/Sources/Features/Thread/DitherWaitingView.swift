import AppKit
import DesignSystem

/// Dither: the background work banner as Capy's quiet indicator under the composer, beside the context ring. A 3x3
/// dot grid (Capy's subagent mark, seen in Capy 2026-10-22) and a short label like "Waiting on subagent", on a
/// pill. A click opens a menu with the full title, Show or Open for each subagent, and Stop.
public final class DitherWaitingView: ControlView {
    public private(set) var title = ""
    /// The work holds the thread's completion: the dots ripple. Otherwise they sit still.
    public private(set) var waiting = false
    /// The menu's rows; the controller rebuilds them with each banner update.
    private var entries: [PickerMenuEntry] = []
    private var signature: [String] = []

    /// A menu row: Show, a subagent's title, or Stop.
    public struct Action {
        public var title: String
        public var enabled: Bool
        public var run: @MainActor () -> Void
        public init(_ title: String, enabled: Bool = true, run: @escaping @MainActor () -> Void) {
            self.title = title; self.enabled = enabled; self.run = run
        }
    }
    /// False at narrow widths: only the dots show.
    public var showsLabel = true { didSet { if showsLabel != oldValue { label.isHidden = !showsLabel; needsLayout = true } } }

    private let surface = DitherPillSurface()
    /// The faint hover fill over the pill, as on the footer chips.
    private let hoverFill = DSView()
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.contrastSecondaryLabel))
    private let dots: [CALayer] = (0..<9).map { _ in CALayer() }
    /// Holds the dots above the pill; AppKit orders a view's own sublayers under its subviews.
    private let grid = DSView()
    private weak var menuPopup: OpenPopup?

    static let dot: CGFloat = 2, pitch: CGFloat = 3.5, padding: CGFloat = 10, gap: CGFloat = 6
    private static var gridSize: CGFloat { 2 * pitch + dot }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.masksToBounds = false
        addSubview(surface)
        hoverFill.layer?.cornerRadius = DitherPill.radius
        hoverFill.isHidden = true
        addSubview(hoverFill)
        label.lineHeight = 16
        addSubview(label)
        addSubview(grid)
        for d in dots {
            d.cornerRadius = Self.dot / 2
            d.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            grid.layer?.addSublayer(d)
        }
        setAccessibilityRole(.popUpButton)
        action = { [weak self] in self?.toggleMenu() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Sets the label, the motion and the menu: `header` (the banner's full title), then `links`, then `stop`. An open
    /// menu takes the new rows.
    public func configure(title: String, waiting: Bool, header: String, links: [Action], stop: Action?) {
        var entries: [PickerMenuEntry] = [.label(header)]
        entries += links.map { a in .option(a.title, checked: false, disabled: !a.enabled, onPick: a.run) }
        if let stop {
            if !links.isEmpty { entries.append(.separator) }
            entries.append(.option(stop.title, checked: false, disabled: !stop.enabled, onPick: stop.run))
        }
        self.entries = entries
        let signature = entries.map { "\($0.kind)|\($0.title)|\($0.disabled)" }
        let changed = signature != self.signature
        self.signature = signature
        if title != self.title {
            self.title = title
            label.text = title
            setAccessibilityLabel(title)
            superview?.needsLayout = true
        }
        if waiting != self.waiting { self.waiting = waiting; updateMotion() }
        if changed, menuPopup != nil { closeMenu(); openMenu() }
    }

    public func width(showingLabel: Bool) -> CGFloat {
        showingLabel ? ceil(2 * Self.padding + Self.gridSize + Self.gap + label.textWidth) : DitherPill.height
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        let gx = showsLabel ? Self.padding : ((bounds.width - Self.gridSize) / 2).rounded()
        let gy = ((bounds.height - Self.gridSize) / 2).rounded()
        grid.frame = NSRect(x: gx, y: gy, width: Self.gridSize, height: Self.gridSize)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverFill.frame = bounds
        hoverFill.layer?.backgroundColor = Themed.color(\.foreground, 0.07).cgColor(in: self)
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: CGFloat(i % 3) * Self.pitch, y: CGFloat(i / 3) * Self.pitch, width: Self.dot, height: Self.dot)
        }
        CATransaction.commit()
        label.frame = NSRect(x: gx + Self.gridSize + Self.gap, y: ((bounds.height - 16) / 2).rounded(), width: max(0, bounds.width - gx - Self.gridSize - Self.gap - Self.padding), height: 16)
    }

    public override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = nil
        let dot = Themed.color(\.contrastForeground, 0.7).cgColor(in: self)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for d in dots { d.backgroundColor = dot }
        CATransaction.commit()
        label.color = state.hoverOrPressed ? Themed.color(\.contrastForeground) : Themed.color(\.contrastSecondaryLabel)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
        hoverFill.isHidden = !state.hoverOrPressed
    }


    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    // MARK: Motion

    /// A wave across the grid, one 1.2s loop, only while waiting, shown and on screen; hidden views run nothing.
    private func updateMotion() {
        let runs = waiting && window != nil && !isHiddenOrHasHiddenAncestor && !Motion.reduced
        for (i, d) in dots.enumerated() {
            guard runs else { d.removeAnimation(forKey: "wave"); d.opacity = waiting ? 1 : 0.6; continue }
            guard d.animation(forKey: "wave") == nil else { continue }
            d.opacity = 1
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.25, 1, 0.25]
            a.keyTimes = [0, 0.5, 1]
            a.duration = 1.2
            a.repeatCount = .infinity
            // Diagonal order, so the light runs from one corner to the other.
            a.beginTime = CACurrentMediaTime() + Double(i % 3 + i / 3) * 0.12
            a.fillMode = .backwards
            d.add(a, forKey: "wave")
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeMenu() }
        updateMotion()
    }
    public override func viewDidHide() { super.viewDidHide(); closeMenu(); updateMotion() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }

    // MARK: Menu

    private func toggleMenu() {
        if menuPopup != nil { closeMenu() } else { openMenu() }
    }

    private func openMenu() {
        guard !entries.isEmpty, let host = popupHost else { return }
        let list = PickerMenuView(entries: entries, style: .menu, minimumWidth: 200)
        let popup = host.open(PickerPopupView(list), trigger: self,
                              placement: PopupPlacement(side: .top, align: .end, sideOffset: 6, fallbackAxisSide: .none),
                              swallowsOutsideClick: true)
        list.onClose = { [weak self] in self?.closeMenu() }
        if NSApp.currentEvent?.type == .keyDown { list.highlightedIndex = list.selectable.first }
        menuPopup = popup
    }

    private func closeMenu() {
        guard let open = menuPopup else { return }
        menuPopup = nil
        popupHost?.close(open)
    }
}
