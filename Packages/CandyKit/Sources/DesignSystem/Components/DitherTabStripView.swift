import AppKit

/// The Dither theme's tab strip (after Capy's): the window's top band over the content panel, one 28pt tab per open
/// thread and a + for a new thread. The selected tab is a raised pill; the others are plain text that brighten on
/// hover. A tab's close button shows on hover or selection.
public final class DitherTabStripView: TopbarDragView {
    public struct Tab: Equatable, Sendable {
        public var id: String
        public var title: String
        public var icon: IconName
        public init(id: String, title: String, icon: IconName) { self.id = id; self.title = title; self.icon = icon }
    }

    public var tabs: [Tab] = [] { didSet { if tabs != oldValue { rebuild() } } }
    public var selected: String? { didSet { if selected != oldValue { for v in views { v.isSelected = v.tab.id == selected } } } }
    public var onSelect: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onNew: (() -> Void)?

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
    }

    /// One tab: icon, title, and a close button.
    final class TabView: ControlView {
        var tab: Tab {
            didSet {
                guard tab != oldValue else { return }
                label.text = tab.title
                if tab.icon != oldValue.icon { icon.removeFromSuperview(); icon = IconView(name: tab.icon, size: 14); addSubview(icon) }
                setAccessibilityLabel(tab.title)
                refresh()
                needsLayout = true
            }
        }
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; refresh() } } }
        var onClose: (() -> Void)?
        private var icon: IconView
        private let label: LabelView
        private let close = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconMicro)

        init(tab: Tab) {
            self.tab = tab
            icon = IconView(name: tab.icon, size: 14)
            label = LabelView(tab.title, font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
            super.init(frame: .zero)
            label.lineHeight = 18
            close.setAccessibilityLabel("Close tab")
            close.action = { [weak self] in self?.onClose?() }
            [icon, label, close].forEach(addSubview)
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

        override func stateDidChange(from old: State) {
            super.stateDidChange(from: old)
            needsDisplay = true
            refresh()
        }

        private func refresh() {
            // Faded, never hidden: hiding it as the pointer moved onto it ended the tab's hover and lost the click.
            close.alphaValue = isSelected || state.hovered || close.state.hovered || state.focusVisible ? 1 : 0
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
