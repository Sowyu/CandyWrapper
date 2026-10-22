import AppKit

/// The Dither theme's tab strip (after Capy's): the window's top band over the content panel, one 28pt tab per open
/// thread and a + for a new thread. The selected tab is a raised pill; the others are plain text that brighten on
/// hover. A tab's close button shows on hover or selection. A press selects a tab, as in a browser; dragging it
/// sideways reorders the strip.
public final class DitherTabStripView: TopbarDragView {
    public struct Tab: Equatable, Sendable {
        public var id: String
        public var title: String
        public var icon: IconName
        /// The thread's run, as the sidebar shows it: working, or waiting on the user. Either shows the dot grid.
        public var activity: Activity?
        public enum Activity: Sendable { case working, waiting }
        public init(id: String, title: String, icon: IconName, activity: Activity? = nil) {
            self.id = id; self.title = title; self.icon = icon; self.activity = activity
        }
    }

    public var tabs: [Tab] = [] { didSet { if tabs != oldValue { if drag != nil, tabs.map(\.id) != oldValue.map(\.id) { endDrag(commit: false) }; rebuild() } } }
    public var selected: String? { didSet { if selected != oldValue { for v in views { v.isSelected = v.tab.id == selected } } } }
    public var onSelect: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onNew: (() -> Void)?
    /// A tab was dragged to a new index in strip order.
    public var onMove: ((String, Int) -> Void)?

    private var views: [TabView] = []
    private let plus = ButtonView(nil, icon: .plus, variant: .ghost, size: .iconSm)
    static let tabWidth: CGFloat = 200, tabHeight: CGFloat = 28, gap: CGFloat = 4

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        plus.setAccessibilityLabel("New thread")
        plus.action = { [weak self] in self?.onNew?() }
        addSubview(plus)
        // A tab group, as VoiceOver knows NSTabView's: the tabs are its radio buttons.
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Thread tabs")
    }

    public override func accessibilityTabs() -> [Any]? { views }
    public override func accessibilityChildren() -> [Any]? { views + [plus] }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the views of tabs that stay, so a rebuild during a click (the sidebar refreshes often) never drops it.
    private func rebuild() {
        var kept: [String: TabView] = [:]
        for v in views { kept[v.tab.id] = v }
        views = tabs.map { tab in
            if let v = kept.removeValue(forKey: tab.id) { v.tab = tab; return v }
            let id = tab.id
            let v = TabView(tab: tab)
            v.action = { [weak self] in self?.onSelect?(id) }
            v.onClose = { [weak self] in self?.onClose?(id) }
            v.onDrag = { [weak self] phase in self?.dragTab(id, phase) }
            addSubview(v)
            return v
        }
        for v in kept.values { v.removeFromSuperview() }
        for v in views { v.isSelected = v.tab.id == selected }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let y = (bounds.height - Self.tabHeight) / 2
        let room = max(0, bounds.width - contentStart - 40)
        let width = views.isEmpty ? 0 : min(Self.tabWidth, (room - Self.gap * CGFloat(views.count - 1)) / CGFloat(views.count))
        var x = contentStart - 12
        for v in views {
            v.frame = NSRect(x: x, y: y, width: max(60, width), height: Self.tabHeight)
            x += max(60, width) + Self.gap
        }
        plus.frame = NSRect(x: x + 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
        if drag != nil {
            drag?.rest = views.map(\.frame)
            layoutDrag()
        }
    }

    // MARK: Reordering

    /// The dragged tab: its index, how far the pointer moved, the index it would drop at and where the tabs rest.
    private var drag: (index: Int, offset: CGFloat, over: Int, rest: [NSRect])?
    /// Capy's tab reorder: 150ms `cubic-bezier(0.23, 1, 0.32, 1)` (capy-design.md).
    private static let slide = (duration: 0.15, timing: CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))

    private func dragTab(_ id: String, _ phase: TabView.DragPhase) {
        guard let index = views.firstIndex(where: { $0.tab.id == id }) else { return }
        switch phase {
        case .began:
            guard views.count > 1 else { return }
            drag = (index, 0, index, views.map(\.frame))
            views[index].layer?.zPosition = 10
        case .moved(let dx):
            guard drag?.index == index else { return }
            drag?.offset = dx
            layoutDrag()
        case .ended:
            guard drag?.index == index else { return }
            endDrag(commit: true)
        }
    }

    /// The dragged tab follows the pointer inside the strip; the tabs it passes slide aside by its width and the gap.
    /// The drop target is the tab whose resting center is closest to the dragged tab's.
    private func layoutDrag() {
        guard let drag, drag.rest.count == views.count, views.indices.contains(drag.index) else { return }
        let rest = drag.rest, dragged = rest[drag.index]
        let x = min(max(dragged.minX + drag.offset, rest[0].minX), rest[rest.count - 1].maxX - dragged.width)
        let center = x + dragged.width / 2
        let over = rest.indices.min { abs(rest[$0].midX - center) < abs(rest[$1].midX - center) } ?? drag.index
        self.drag?.over = over
        views[drag.index].setFrameOrigin(NSPoint(x: x, y: dragged.minY))
        let shift = dragged.width + Self.gap
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, v) in views.enumerated() where i != drag.index {
            let target: CGFloat = i > drag.index && i <= over ? -shift : i < drag.index && i >= over ? shift : 0
            guard let layer = v.layer, layer.affineTransform().tx != target else { continue }
            let shown = (layer.presentation() ?? layer).affineTransform().tx
            layer.setAffineTransform(CGAffineTransform(translationX: target, y: 0))
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = shown
            slide.toValue = target
            slide.duration = Self.slide.duration
            slide.timingFunction = Self.slide.timing
            layer.add(slide, forKey: "tab-sort")
        }
        CATransaction.commit()
    }

    /// Puts every tab in its slot. A committed drop reorders the views and reports the move; the dropped tab
    /// eases from where it was let go into its slot.
    private func endDrag(commit: Bool) {
        guard let ended = drag else { return }
        drag = nil
        let dropped = views.indices.contains(ended.index) ? views[ended.index] : nil
        let releasedX = dropped?.frame.minX
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for v in views {
            v.layer?.removeAnimation(forKey: "tab-sort")
            v.layer?.setAffineTransform(.identity)
            v.layer?.zPosition = 0
        }
        CATransaction.commit()
        if commit, let dropped, ended.over != ended.index {
            views.remove(at: ended.index)
            views.insert(dropped, at: ended.over)
            tabs = views.map(\.tab)
            onMove?(dropped.tab.id, ended.over)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard let dropped, let releasedX, let layer = dropped.layer, releasedX != dropped.frame.minX else { return }
        let settle = CABasicAnimation(keyPath: "transform.translation.x")
        settle.fromValue = releasedX - dropped.frame.minX
        settle.toValue = 0
        settle.duration = Self.slide.duration
        settle.timingFunction = Self.slide.timing
        layer.add(settle, forKey: "tab-sort")
    }

    /// One tab: icon, title, and a close button.
    final class TabView: ControlView {
        var tab: Tab {
            didSet {
                guard tab != oldValue else { return }
                label.text = tab.title
                if tab.icon != oldValue.icon { icon.removeFromSuperview(); icon = IconView(name: tab.icon, size: 14); addSubview(icon) }
                setAccessibilityLabel(tab.title)
                if tab.activity != nil, grid == nil { let g = DotGridSpinnerView(); grid = g; addSubview(g) }
                refresh()
                needsLayout = true
            }
        }
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; refresh() } } }
        var onClose: (() -> Void)?
        enum DragPhase { case began, moved(CGFloat), ended }
        var onDrag: ((DragPhase) -> Void)?
        /// Where the press landed, and whether it became a drag (6pt sideways, dnd-kit's `distance: 6`).
        private var press: NSPoint?
        private var dragging = false
        private var icon: IconView
        private let label: LabelView
        private let close = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconMicro)
        /// The working grid in the close button's slot, made the first time the thread works.
        private var grid: DotGridSpinnerView?

        init(tab: Tab) {
            self.tab = tab
            icon = IconView(name: tab.icon, size: 14)
            label = LabelView(tab.title, font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
            super.init(frame: .zero)
            label.lineHeight = 18
            close.setAccessibilityLabel("Close tab")
            close.action = { [weak self] in self?.onClose?() }
            [icon, label, close].forEach(addSubview)
            if tab.activity != nil { let g = DotGridSpinnerView(); grid = g; addSubview(g) }
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(tab.title)
            // The close button only shows on hover or selection; VoiceOver and Switch Control close any tab here.
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close tab") { [weak self] in
                guard let onClose = self?.onClose else { return false }
                onClose()
                return true
            }])
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            refresh()
        }

        deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

        @objc private func displayOptionsChanged(_ note: Notification) { refresh() }

        /// An unselected tab's text and icon strength: Increase Contrast keeps them near full.
        static func restingAlpha(increaseContrast: Bool) -> (label: CGFloat, icon: CGFloat) {
            increaseContrast ? (0.9, 0.85) : (0.72, 0.6)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            press = event.locationInWindow
            dragging = false
            // A browser tab selects on press, so a drag starts from the tab it shows.
            if event.clickCount == 1 { performAction() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press else { return super.mouseDragged(with: event) }
            let dx = event.locationInWindow.x - press.x
            if !dragging, abs(dx) >= 6 {
                dragging = true
                onDrag?(.began)
            }
            if dragging { onDrag?(.moved(dx)) } else { super.mouseDragged(with: event) }
        }

        override func mouseUp(with event: NSEvent) {
            // The press already selected; the release only ends a drag.
            press = nil
            state.active = false
            if dragging {
                dragging = false
                onDrag?(.ended)
            }
        }

        /// A middle click closes the tab, as in a browser.
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?() } else { super.otherMouseUp(with: event) }
        }

        override func stateDidChange(from old: State) {
            super.stateDidChange(from: old)
            needsDisplay = true
            refresh()
        }

        private func refresh() {
            // Faded, never hidden: hiding it as the pointer moved onto it ended the tab's hover and lost the click.
            // A working tab shows the grid in the close button's slot until the pointer or focus reaches it, as the
            // sidebar's working rows do. Hidden, the grid stops its animation.
            let reached = state.hovered || close.state.hovered || state.focusVisible
            let activity = tab.activity
            close.alphaValue = reached || (isSelected && activity == nil) ? 1 : 0
            if let grid {
                let shown = activity != nil && !reached
                if grid.isHidden == shown { grid.isHidden = !shown }
                // The sidebar's colors: Working in its warning color, Waiting in the foreground.
                if let activity { grid.color = Themed.color(activity == .working ? \.warning : \.foreground, sidebar: true) }
            }
            let strong = isSelected || state.hovered || state.focusVisible
            let resting = Self.restingAlpha(increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            label.color = Themed.color(\.foreground, strong ? 1 : resting.label)
            icon.strokeColor = Themed.color(\.foreground, strong ? 0.9 : resting.icon)
            setAccessibilityValue(isSelected ? 1 : 0)
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
            let closeX = bounds.width - 6 - 16
            close.frame = NSRect(x: closeX, y: (bounds.height - 16) / 2, width: 16, height: 16)
            grid?.frame = close.frame
            label.frame = NSRect(x: 30, y: (bounds.height - 18) / 2, width: max(0, closeX - 4 - 30), height: 18)
        }

        override func updateLayer() {
            layer?.cornerRadius = DitherChrome.cardRadius
            // Keyboard focus shows T3's ring (`focus-visible:ring-2 ring-ring`); the tabs drew none before.
            layer?.borderWidth = state.focusVisible ? 2 : isSelected ? 0.5 : 0
            layer?.borderColor = state.focusVisible ? Themed.color(\.ring).cgColor(in: self)
                : Themed.color(\.contrastForeground, 0.1).cgColor(in: self)
            layer?.backgroundColor = isSelected ? Themed.color(\.surfaceRaised).cgColor(in: self)
                : state.hovered ? Themed.color(\.foreground, 0.04).cgColor(in: self) : nil
        }
    }
}
