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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        for v in views { v.removeFromSuperview() }
        views = tabs.map { tab in
            let v = TabView(tab: tab)
            v.isSelected = tab.id == selected
            v.action = { [weak self] in self?.onSelect?(tab.id) }
            v.onClose = { [weak self] in self?.onClose?(tab.id) }
            addSubview(v)
            return v
        }
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
        let tab: Tab
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; refresh() } } }
        var onClose: (() -> Void)?
        private let icon: IconView
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
            refresh()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func stateDidChange(from old: State) {
            super.stateDidChange(from: old)
            needsDisplay = true
            refresh()
        }

        private func refresh() {
            close.isHidden = !(isSelected || state.hovered)
            let strong = isSelected || state.hovered
            label.color = Themed.color(\.foreground, strong ? 1 : 0.66)
            icon.strokeColor = Themed.color(\.foreground, strong ? 0.9 : 0.55)
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
            layer?.borderWidth = isSelected ? 0.5 : 0
            layer?.borderColor = Themed.color(\.contrastForeground, 0.1).cgColor(in: self)
            layer?.backgroundColor = isSelected ? Themed.color(\.surfaceRaised).cgColor(in: self)
                : state.hovered ? Themed.color(\.foreground, 0.04).cgColor(in: self) : nil
        }
    }
}
