import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// A browser tab in the right panel (`PreviewView`, apps/web/src/components/preview/PreviewView.tsx):
/// the chrome row, then the server tab's viewer, with the empty state (discovered local servers
/// and recent URLs) or the unreachable page over it. The app fills it and runs the actions.
public final class BrowserPanelView: DSView {
    public let chrome = BrowserChromeRowView()
    public let viewer = ServerBrowserView()
    public let empty = BrowserEmptyStateView()
    public let unreachable = BrowserUnreachableView()
    /// Over the viewer while the server tab has a fixed viewport (PreviewView.tsx:1055-1069).
    public let deviceToolbar = BrowserDeviceToolbarView()

    public enum Body: Equatable {
        /// `shouldShowPreviewEmptyState`: no tab yet, or a tab that never navigated.
        case empty
        /// A server tab with a page.
        case page
        /// `navStatus` LoadFailed: the page could not load, or it was a file the browser saved.
        case unreachable
    }

    /// What shows under the chrome row. The viewer stays connected under the empty and
    /// unreachable states so a URL picked there reaches the page.
    public var body: Body = .empty { didSet { applyBody() } }
    /// Whether a server tab backs this surface (the viewer and its control bar show).
    public var hasServerTab = false { didSet { applyBody() } }
    /// The tab's viewport setting when it is not `fill`: the device toolbar shows and the viewer moves below it.
    public var fixedViewport: JSONValue? {
        didSet {
            if let fixedViewport { deviceToolbar.setting = fixedViewport }
            if (fixedViewport == nil) != (oldValue == nil) { applyBody() }
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        [viewer, empty, unreachable, deviceToolbar, chrome].forEach(addSubview)
        applyBody()
    }

    private func applyBody() {
        viewer.isHidden = !hasServerTab
        viewer.contentHidden = body != .page
        empty.isHidden = body != .empty
        unreachable.isHidden = body != .unreachable
        deviceToolbar.isHidden = !(hasServerTab && body == .page && fixedViewport != nil)
        if deviceToolbar.isHidden, fixedViewport == nil { deviceToolbar.aspectLocked = false }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        // Inline mode: a 28px row with 12px below and no border (`in-data-[preview-panel-mode=inline]`).
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: BrowserChromeRowView.height)
        let top = BrowserChromeRowView.height + 12
        let content = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let deviceTop = hasServerTab && fixedViewport != nil ? BrowserViewport.toolbarHeight : 0
        deviceToolbar.frame = NSRect(x: 0, y: top, width: bounds.width, height: BrowserViewport.toolbarHeight)
        viewer.frame = NSRect(x: 0, y: top + deviceTop, width: bounds.width, height: max(0, content.height - deviceTop))
        // The control bar overlays the top of the empty state (z-20); the unreachable page sits
        // under it too.
        let barH = hasServerTab ? (viewer.controlButton.isHidden ? 25 : ServerBrowserView.barHeight) : 0
        let below = NSRect(x: 0, y: top + deviceTop + barH, width: bounds.width, height: max(0, content.height - deviceTop - barH))
        empty.frame = hasServerTab ? below : content
        unreachable.frame = hasServerTab ? below : content
    }

    /// Glass Native: the address row, the control bar and the empty and unreachable states sit on the detail's
    /// frost; the page stays solid.
    public var nativeChrome = false {
        didSet {
            guard nativeChrome != oldValue else { return }
            unreachable.nativeChrome = nativeChrome
            viewer.nativeChrome = nativeChrome
            needsDisplay = true
        }
    }

    public override func updateLayer() {
        layer?.backgroundColor = NativePanelGround.color(nativeChrome).cgColor(in: self)
    }
}

/// `PreviewChromeRow` in the panel's inline mode: back, forward and refresh (`gap-0.5`), the
/// address bar (`InputGroup` ghost, `h-7`) with "Open in system browser" on hover, the floating
/// preview toggle and the more menu, `gap-1 px-2`, and the 2px loading bar along the bottom.
public final class BrowserChromeRowView: DSView {
    public static let height: CGFloat = 28

    public let back = ButtonView(nil, icon: .arrowLeft, variant: .ghost, size: .iconXs)
    public let forward = ButtonView(nil, icon: .arrowRight, variant: .ghost, size: .iconXs)
    public let refresh = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconXs)
    public let address = InputGroupView(placeholder: "Search or enter URL", variant: .ghost)
    public let openExternal = ButtonView(nil, icon: .externalLink, variant: .ghost, size: .iconXs)
    /// Holds the reveal-on-hover opacity; the button keeps its own disabled opacity.
    private let externalHolder = DSView()
    public let pictureInPicture = ButtonView(nil, icon: .pictureInPicture2, variant: .ghost, size: .iconXs)
    public let more = ButtonView(nil, icon: .moreVertical, variant: .ghost, size: .iconXs).menuTrigger()
    private let progress = CALayer()

    public var onBack: (@MainActor () -> Void)?
    public var onForward: (@MainActor () -> Void)?
    public var onRefresh: (@MainActor () -> Void)?
    public var onSubmit: (@MainActor (String) -> Void)?
    public var onOpenExternal: (@MainActor () -> Void)? { didSet { needsLayout = true } }
    public var onPictureInPicture: (@MainActor () -> Void)? { didSet { pictureInPicture.isHidden = onPictureInPicture == nil; needsLayout = true } }
    /// The more menu, anchored on its button. Nil hides it (no tab yet).
    public var onMore: (@MainActor (NSView) -> Void)? { didSet { more.isHidden = onMore == nil; needsLayout = true } }

    public var url = "" { didSet { if !focused { address.input.text = url } } }
    public var loading = false { didSet { if loading != oldValue { loadingChanged() } } }
    public var canGoBack = false { didSet { back.isEnabled = canGoBack } }
    public var canGoForward = false { didSet { forward.isEnabled = canGoForward } }
    public var refreshDisabled = true { didSet { refresh.isEnabled = !refreshDisabled } }
    /// A server tab without control: the address bar and history are disabled.
    public var inputDisabled = false { didSet { address.input.isEnabled = !inputDisabled } }
    public var pictureInPictureActive = false {
        didSet {
            pictureInPicture.variant = pictureInPictureActive ? .secondary : .ghost
            pictureInPicture.iconColor = pictureInPictureActive ? Themed.color(\.primary) : nil
            let tip = pictureInPictureActive ? "Close floating preview" : "Float preview over chat"
            pictureInPicture.toolTip = tip
            pictureInPicture.setAccessibilityLabel(tip)
        }
    }
    public var pictureInPictureDisabled = false { didSet { pictureInPicture.isEnabled = !pictureInPictureDisabled } }

    private var focused = false
    private var hovered = false { didSet { if hovered != oldValue { needsLayout = true } } }
    private var tracking: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (button, label) in [(back, "Back"), (forward, "Forward"), (refresh, "Refresh"), (openExternal, "Open in system browser"), (more, "More")] {
            button.iconSize = 14
            button.toolTip = label
            button.setAccessibilityLabel(label == "More" ? "Preview menu" : label)
        }
        pictureInPicture.iconSize = 14
        back.action = { [weak self] in self?.onBack?() }
        forward.action = { [weak self] in self?.onForward?() }
        refresh.action = { [weak self] in self?.onRefresh?() }
        openExternal.action = { [weak self] in self?.onOpenExternal?() }
        pictureInPicture.action = { [weak self] in self?.onPictureInPicture?() }
        more.action = { [weak self] in guard let self else { return }; self.onMore?(self.more) }
        address.input.size = .sm
        address.input.onStateChange = { [weak self] state in self?.focusChanged(state.focused) }
        address.input.onCommand = { [weak self] selector in
            guard let self else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let next = self.address.input.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !next.isEmpty else { return true }
                self.onSubmit?(next)
                self.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                self.address.input.text = self.url
                self.window?.makeFirstResponder(nil)
                return true
            default: return false
            }
        }
        pictureInPicture.toolTip = "Float preview over chat"
        pictureInPicture.setAccessibilityLabel("Float preview over chat")
        pictureInPicture.isHidden = true
        more.isHidden = true
        // Observers do not run in the class's own initializer.
        [back, forward, refresh].forEach { $0.isEnabled = false }
        progress.anchorPoint = CGPoint(x: 0, y: 0.5)
        progress.cornerRadius = 1
        progress.opacity = 0
        progress.shadowOpacity = 1
        progress.shadowRadius = 3
        progress.shadowOffset = .zero
        layer?.addSublayer(progress)
        layer?.masksToBounds = false
        externalHolder.addSubview(openExternal)
        [back, forward, refresh, address, externalHolder, pictureInPicture, more].forEach(addSubview)
    }

    /// Bumps focus into the address bar and selects it (`preview.focusUrl`).
    public func focusAddress() {
        guard address.input.isEnabled else { return }
        window?.makeFirstResponder(address.input)
    }

    private func focusChanged(_ isFocused: Bool) {
        guard isFocused != focused else { return }
        focused = isFocused
        if isFocused {
            // `onFocus`: the draft starts from the current URL, all of it selected.
            address.input.text = url
            // After the click's own tracking loop, which would put the caret back.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        } else {
            address.input.text = url
        }
        needsLayout = true
    }

    /// `RefreshIcon refreshing`: the glyph spins while the page loads, and the bar grows from 4% to
    /// 90% over 5.3 s, then fades 220 ms after loading stops.
    private func loadingChanged() {
        refresh.toolTip = loading ? "Loading\u{2026}" : "Refresh"
        refresh.setAccessibilityLabel(loading ? "Stop" : "Refresh")
        guard !Motion.reduced else {
            progress.opacity = loading ? 1 : 0
            progress.transform = CATransform3DMakeScale(loading ? 0.9 : 1, 1, 1)
            return
        }
        progress.removeAllAnimations()
        if loading {
            progress.opacity = 1
            let grow = CABasicAnimation(keyPath: "transform.scale.x")
            grow.fromValue = 0.04
            grow.toValue = 0.9
            grow.duration = 5.3
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.5, 0.2, 1)
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            progress.add(grow, forKey: "grow")
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = Motion.loopFrameRate
            refreshIconLayer?.add(spin, forKey: "spin")
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            progress.transform = CATransform3DIdentity
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + 0.22
            fade.duration = 0.15
            fade.fillMode = .backwards
            progress.opacity = 0
            progress.add(fade, forKey: "fade")
            refreshIconLayer?.removeAnimation(forKey: "spin")
        }
    }

    private var refreshIconLayer: CALayer? {
        guard let icon = refresh.subviews.first(where: { $0 is IconView }), let l = icon.layer else { return nil }
        // Spin around the glyph's center.
        let f = l.frame
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.frame = f
        return l
    }

    private var showsOpenExternal: Bool { onOpenExternal != nil && !focused }

    public override func layout() {
        super.layout()
        let y = (bounds.height - 24) / 2
        var x: CGFloat = 8
        for b in [back, forward, refresh] {
            b.frame = NSRect(x: x, y: y, width: 24, height: 24)
            x += 24 + 2
        }
        x += 4 - 2
        var right = bounds.width - 8
        for b in [more, pictureInPicture] where !b.isHidden {
            b.frame = NSRect(x: right - 24, y: y, width: 24, height: 24)
            right -= 24 + 4
        }
        address.frame = NSRect(x: x, y: 0, width: max(0, right - x), height: 28)
        // The inline-end addon (`pe-[calc(--spacing(2.5)-1px)]`) is laid out even while invisible,
        // so it narrows the field; it fades in over 150 ms on hover (`transition-opacity group-hover/address`,
        // PreviewChromeRow.tsx:213).
        externalHolder.isHidden = !showsOpenExternal
        HoverReveal.fade([externalHolder], visible: hovered)
        externalHolder.frame = NSRect(x: address.frame.maxX - 1 - 9 - 24, y: y, width: 24, height: 24)
        openExternal.frame = externalHolder.bounds
        updateTrackingAreas()
        address.input.paddingOverride = (nil, showsOpenExternal ? 8 + 24 + 9 : nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: 2)
        progress.position = CGPoint(x: 0, y: bounds.height - 1)
        CATransaction.commit()
    }

    public override func updateLayer() {
        progress.backgroundColor = Themed.color(\.primary).cgColor(in: self)
        progress.shadowColor = Themed.color(\.ring).cgColor(in: self)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: address.frame, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { hovered = true }
    public override func mouseExited(with event: NSEvent) { hovered = false }
}

/// `PreviewMoreMenu`: hard reload, the device toolbar toggle, the Appearance submenu, the zoom
/// row (- 100% + reset, the menu stays open), and the profile's clear actions.
@MainActor
public enum BrowserMoreMenu {
    public struct Actions {
        public var hardReload: @MainActor () -> Void
        public var setColorScheme: @MainActor (String) -> Void
        public var zoom: @MainActor (Int) -> Void
        public var clearCookies: @MainActor () -> Void
        public var clearCache: @MainActor () -> Void
        public var toggleDeviceToolbar: (@MainActor () -> Void)?
        public init(hardReload: @escaping @MainActor () -> Void, setColorScheme: @escaping @MainActor (String) -> Void,
                    zoom: @escaping @MainActor (Int) -> Void, clearCookies: @escaping @MainActor () -> Void,
                    clearCache: @escaping @MainActor () -> Void, toggleDeviceToolbar: (@MainActor () -> Void)? = nil) {
            self.hardReload = hardReload; self.setColorScheme = setColorScheme; self.zoom = zoom
            self.clearCookies = clearCookies; self.clearCache = clearCache; self.toggleDeviceToolbar = toggleDeviceToolbar
        }
    }

    public static func items(enabled: Bool, zoomFactor: Double, colorScheme: String, deviceToolbarVisible: Bool,
                             profileName: String?, actions: Actions, zoomLabel: ZoomCluster? = nil) -> [MenuItem] {
        var items: [MenuItem] = []
        var hard = MenuItem("Hard reload", disabled: !enabled); hard.action = actions.hardReload
        items.append(hard)
        var device = MenuItem(deviceToolbarVisible ? "Hide device toolbar" : "Show device toolbar", disabled: !enabled || actions.toggleDeviceToolbar == nil)
        device.action = actions.toggleDeviceToolbar
        items.append(device)
        let schemes = [("system", "System"), ("light", "Light"), ("dark", "Dark")].map { value, label in
            var item = MenuItem.radio(label, checked: colorScheme == value) { _ in actions.setColorScheme(value) }
            item.closesOnClick = false
            return item
        }
        var appearance = MenuItem.submenu("Appearance", schemes)
        appearance.isDisabled = !enabled
        items.append(appearance)
        items.append(.separator)
        var zoom = MenuItem("Zoom", disabled: !enabled)
        zoom.keepsOpen = true
        let cluster = zoomLabel ?? ZoomCluster()
        cluster.zoomFactor = zoomFactor
        cluster.isEnabled = enabled
        cluster.onStep = actions.zoom
        zoom.accessory = { cluster }
        zoom.accessoryWidth = ZoomCluster.width
        items.append(zoom)
        items.append(.separator)
        if let profileName { items.append(.label("Profile: \(profileName)")) }
        var cookies = MenuItem("Clear cookies"); cookies.action = actions.clearCookies
        var cache = MenuItem("Clear cache"); cache.action = actions.clearCache
        items += [cookies, cache]
        return items
    }

    /// The zoom row's controls: outline minus, the percentage (`min-w-12`, tabular), outline plus,
    /// ghost reset, `gap-1`.
    public final class ZoomCluster: DSView {
        static let width: CGFloat = 24 + 4 + 48 + 4 + 24 + 4 + 24
        let minus = ButtonView(nil, icon: .minus, variant: .outline, size: .iconXs)
        let plus = ButtonView(nil, icon: .plus, variant: .outline, size: .iconXs)
        let reset = ButtonView(nil, icon: .rotateCcw, variant: .ghost, size: .iconXs)
        let label = LabelView("100%", font: DSFont.ui(12))
        var onStep: (@MainActor (Int) -> Void)?
        public var zoomFactor: Double = 1 { didSet { label.text = "\(Int((zoomFactor * 100).rounded()))%" } }
        var isEnabled = true { didSet { [minus, plus, reset].forEach { $0.isEnabled = isEnabled } } }

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.alignment = .center
            label.lineHeight = 16
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            for (b, l, d) in [(minus, "Zoom out", -1), (plus, "Zoom in", 1), (reset, "Reset zoom", 0)] {
                b.setAccessibilityLabel(l)
                b.action = { [weak self] in self?.onStep?(d) }
            }
            [minus, label, plus, reset].forEach(addSubview)
        }

        public override func layout() {
            super.layout()
            minus.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
            label.frame = NSRect(x: 28, y: 4, width: 48, height: 16)
            plus.frame = NSRect(x: 80, y: 0, width: 24, height: 24)
            reset.frame = NSRect(x: 108, y: 0, width: 24, height: 24)
        }

        public override func updateLayer() { label.color = Themed.color(\.mutedForeground) }
    }
}

/// `PreviewEmptyState`: "No preview yet", or the recently used URLs and the local servers the
/// environment found, each in a `DiscoveryList`, `max-w-xl` centered, `px-5 py-8`.
public final class BrowserEmptyStateView: DSView {
    public struct Recent: Equatable {
        public var url: String
        public var title: String?
        public var visited: String
        public init(url: String, title: String?, visited: String) { self.url = url; self.title = title; self.visited = visited }
    }

    public var onOpen: (@MainActor (String) -> Void)?
    public var onRemoveRecent: (@MainActor (String) -> Void)?

    private let none = EmptyView(title: "No preview yet",
                                 message: "Type a URL above, or run a dev script. Browser-ready localhost servers will show up here automatically.",
                                 icon: .globe)
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document)
    private var sections: [(header: NSView, list: NSView, footnote: LabelView?)] = []
    private(set) var recents: [Recent] = []
    private(set) var servers: [PreviewableServer] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [none, scroll].forEach(addSubview)
        apply(recents: [], servers: [])
    }

    public func apply(recents: [Recent], servers: [PreviewableServer]) {
        guard recents != self.recents || servers != self.servers || sections.isEmpty && !(recents.isEmpty && servers.isEmpty) else { return }
        self.recents = recents
        self.servers = servers
        sections.forEach { $0.header.removeFromSuperview(); $0.list.removeFromSuperview(); $0.footnote?.removeFromSuperview() }
        sections = []
        none.isHidden = !(recents.isEmpty && servers.isEmpty)
        scroll.isHidden = !none.isHidden
        if !recents.isEmpty {
            let rows = recents.map { recent -> RecentRow in
                let row = RecentRow(recent)
                row.onOpen = { [weak self] in self?.onOpen?(recent.url) }
                row.onRemove = { [weak self] in self?.onRemoveRecent?(recent.url) }
                return row
            }
            sections.append((SectionHeader(icon: .history, title: "Recently used"), RowList(rows), nil))
        }
        if !servers.isEmpty {
            let rows = servers.map { server -> DiscoveryRowView in
                let row = DiscoveryRowView(iconView: BrowserMockupView(), iconSize: 28, title: server.title, detail: server.detail)
                row.action = { [weak self] in self?.onOpen?(server.requestedUrl) }
                return row
            }
            let note = LabelView("Select a live local server to open it in this browser tab.", font: DSFont.ui(12))
            note.lineHeight = 16
            sections.append((SectionHeader(icon: .radioTower, title: "Local servers"), DiscoveryListView(rows: rows), note))
        }
        for s in sections { document.addSubview(s.header); document.addSubview(s.list); s.footnote.map(document.addSubview) }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        none.frame = bounds
        scroll.frame = bounds
        // `scrollbar-gutter-both` (6px each side) plus `px-5`, `max-w-xl` centered, `py-8`, `gap-6`.
        let inner = max(0, bounds.width - 2 * (6 + 20))
        let w = min(576, inner)
        let x = ((bounds.width - w) / 2).rounded()
        var y: CGFloat = 32
        for (i, s) in sections.enumerated() {
            if i > 0 { y += 24 }
            s.header.frame = NSRect(x: x, y: y, width: w, height: 20)
            y += 20 + 12
            let h = s.list.intrinsicContentSize.height
            s.list.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h
            if let note = s.footnote {
                note.frame = NSRect(x: x + 4, y: y + 12, width: w - 8, height: 16)
                y += 12 + 16
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, y + 32))
    }

    public override func updateLayer() {
        for s in sections { s.footnote?.color = Themed.color(\.mutedForeground) }
    }

    /// `flex items-center gap-2 text-sm text-muted-foreground`, a 16px icon and a medium h2.
    final class SectionHeader: DSView {
        private let icon: IconView
        private let title: LabelView
        init(icon name: IconName, title text: String) {
            icon = IconView(name: name, size: 16)
            title = LabelView(text, font: DSFont.ui(14, weight: .medium))
            super.init(frame: .zero)
            title.lineHeight = 20
            [icon, title].forEach(addSubview)
        }
        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 0, y: 2, width: 16, height: 16)
            title.frame = NSRect(x: 24, y: 0, width: max(0, bounds.width - 24), height: 20)
        }
        override func updateLayer() {
            icon.strokeColor = Themed.color(\.mutedForeground)
            title.color = Themed.color(\.mutedForeground)
        }
    }

    /// The recents use `DiscoveryList`'s frame with their own rows.
    final class RowList: BoxView {
        let rows: [RecentRow]
        private let dividers: [CALayer]
        init(_ rows: [RecentRow]) {
            self.rows = rows
            dividers = rows.dropFirst().map { _ in CALayer() }
            super.init(frame: .zero)
            var box = BoxStyle()
            box.radius = 14
            box.border = Themed.color(\.contrastBorder, 0.7)
            box.fill = Themed.color(\.background)
            boxStyle = box
            rows.forEach(addSubview)
            dividers.forEach { layer?.addSublayer($0) }
            layer?.cornerRadius = 14
            layer?.masksToBounds = true
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 2 + CGFloat(rows.count) * 60 + CGFloat(max(0, rows.count - 1)))
        }
        override func layout() {
            super.layout()
            decoration.layout(boxSize: bounds.size)
            var y: CGFloat = 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, row) in rows.enumerated() {
                if i > 0 { dividers[i - 1].frame = CGRect(x: 1, y: y, width: bounds.width - 2, height: 1); y += 1 }
                row.frame = NSRect(x: 1, y: y, width: bounds.width - 2, height: 60)
                y += 60
            }
            CATransaction.commit()
        }
        override func updateLayer() {
            let c = Themed.color(\.contrastBorder, 0.6).cgColor(in: self)
            dividers.forEach { $0.backgroundColor = c }
        }
    }

    /// `PreviewRecentUrlCard`: the favicon, the title (or host and path) and `label · 5m ago`,
    /// with a remove button revealed on hover (`right-3 p-1`, a 14px X).
    final class RecentRow: DSView {
        private let icon = BrowserMockupView()
        private let title = LabelView("", font: DSFont.ui(14, weight: .medium))
        private let detail = LabelView("", font: DSFont.ui(12))
        private let remove = ButtonView(nil, icon: .x, variant: .ghost, size: .iconTiny)
        private var hovered = false { didSet { if hovered != oldValue { remove.alphaValue = hovered ? 1 : 0; needsDisplay = true } } }
        private var tracking: NSTrackingArea?
        var onOpen: (@MainActor () -> Void)?
        var onRemove: (@MainActor () -> Void)?

        init(_ recent: Recent) {
            super.init(frame: .zero)
            let label = BrowserHistory.label(recent.url)
            title.text = recent.title ?? label
            title.lineHeight = 20
            detail.text = (recent.title != nil ? "\(label) · " : "") + recent.visited
            detail.lineHeight = 16
            remove.iconSize = 14
            remove.alphaValue = 0
            remove.setAccessibilityLabel("Remove \(label) from history")
            remove.action = { [weak self] in self?.onRemove?() }
            [icon, title, detail, remove].forEach(addSubview)
            setAccessibilityRole(.button)
            setAccessibilityLabel(title.text)
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 12, y: (bounds.height - 28) / 2, width: 28, height: 28)
            let x: CGFloat = 12 + 28 + 12, w = max(0, bounds.width - x - 40)
            let top = (bounds.height - 36) / 2
            title.frame = NSRect(x: x, y: top, width: w, height: 20)
            detail.frame = NSRect(x: x, y: top + 20, width: w, height: 16)
            remove.frame = NSRect(x: bounds.width - 12 - 22, y: (bounds.height - 22) / 2, width: 22, height: 22)
        }

        override func updateLayer() {
            layer?.backgroundColor = hovered ? Themed.color(\.accent, 0.4).cgColor(in: self) : nil
            title.color = Themed.color(\.foreground)
            detail.color = Themed.color(\.mutedForeground)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if bounds.contains(p), !remove.frame.contains(p) { onOpen?() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// `BrowserMockup`: the 28px browser-window glyph that stands in for a favicon. A streamed tab
/// has no captured favicons, so the empty state always shows it.
public final class BrowserMockupView: DSView {
    private let box = BoxDecorationLayer()
    private let dots = [CALayer(), CALayer(), CALayer()]
    private let lines = [CALayer(), CALayer()]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.host = self
        layer?.addSublayer(box)
        layer?.masksToBounds = false
        for l in dots + lines {
            l.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(l)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        var style = BoxStyle()
        style.radius = 4
        style.border = Themed.color(\.border, 0.6)
        style.fill = Themed.color(\.card)
        style.shadows = [BoxShadow(y: 1, blur: 1, color: Themed.black(0.05))]
        box.boxStyle = style
        box.layout(boxSize: bounds.size)
        // `p-1` inside the 1px border: dots 3px `gap-0.5`, then `mt-[1px]` lines 2px tall.
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: 5 + CGFloat(i) * 5, y: 5, width: 3, height: 3)
            d.cornerRadius = 1.5
        }
        let w = bounds.width - 10
        lines[0].frame = CGRect(x: 5, y: 5 + 3 + 2 + 1, width: w, height: 2)
        lines[1].frame = CGRect(x: 5, y: 5 + 3 + 2 + 1 + 2 + 2, width: (w * 0.6).rounded(), height: 2)
        lines.forEach { $0.cornerRadius = 1 }
    }

    public override func updateLayer() {
        dots[0].backgroundColor = Themed.color(\.destructive, 0.8).cgColor(in: self)
        dots[1].backgroundColor = Themed.color(\.warning, 0.8).cgColor(in: self)
        dots[2].backgroundColor = Themed.color(\.success, 0.8).cgColor(in: self)
        lines[0].backgroundColor = Themed.color(\.mutedForeground, 0.3).cgColor(in: self)
        lines[1].backgroundColor = Themed.color(\.mutedForeground, 0.2).cgColor(in: self)
    }
}

/// `PreviewUnreachable` (Chromium's "This site can't be reached" in T3's styles) and
/// `PreviewFileNotShown` for an address the server's browser saved as a file.
public final class BrowserUnreachableView: DSView {
    /// Glass Native: on the detail's frost.
    public var nativeChrome = false { didSet { if nativeChrome != oldValue { needsDisplay = true } } }
    public enum Content: Equatable {
        case failed(url: String, code: Int, description: String)
        case fileNotShown(url: String, fileName: String)
    }

    public var content: Content = .failed(url: "", code: 0, description: "") { didSet { if content != oldValue { rebuild() } } }
    public var onReload: (@MainActor () -> Void)?
    public var onOpenExternal: (@MainActor () -> Void)?
    public var onDownload: (@MainActor () -> Void)?

    private let icon = ErrorGlyph()
    private let heading = LabelView("", font: DSFont.ui(24, weight: .semibold))
    private let paragraph = TextBlockView()
    private let detailsBox = DSView()
    private let detailsTitle = LabelView("Try:", font: DSFont.ui(14, weight: .medium))
    private var detailItems: [LabelView] = []
    private let code = LabelView("", font: DSFont.ui(12))
    private let details = ButtonView("Details", variant: .outline, size: .sm)
    private let primary = ButtonView("Reload", variant: .default, size: .sm)
    private let secondary = ButtonView("Open in browser", variant: .outline, size: .sm)
    private var showDetails = false { didSet { rebuild() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.lineHeight = 30
        paragraph.font = DSFont.ui(14)
        paragraph.lineHeight = 22.75
        code.lineHeight = 16
        code.tracking = 0.3
        detailsTitle.lineHeight = 20
        detailsBox.layer?.cornerRadius = 10
        detailsBox.layer?.borderWidth = 1
        detailsBox.addSubview(detailsTitle)
        details.action = { [weak self] in self?.showDetails.toggle() }
        primary.action = { [weak self] in
            guard let self else { return }
            if case .fileNotShown = self.content { self.onDownload?() } else { self.onReload?() }
        }
        secondary.action = { [weak self] in self?.onOpenExternal?() }
        [icon, heading, paragraph, detailsBox, code, details, secondary, primary].forEach(addSubview)
        rebuild()
    }

    private func rebuild() {
        detailItems.forEach { $0.removeFromSuperview() }
        detailItems = []
        switch content {
        case .failed(let url, let c, let description):
            let host = PreviewURL.host(of: url) ?? url
            heading.text = "This site can\u{2019}t be reached"
            paragraph.text = "\(host): \(PreviewURL.describeError(description))."
            paragraph.boldPrefix = host
            code.text = PreviewURL.errorLabel(code: c, description: description).uppercased()
            code.isHidden = false
            details.isHidden = false
            details.title = showDetails ? "Hide details" : "Details"
            secondary.isHidden = true
            primary.title = "Reload"
            primary.isHidden = false
            detailsBox.isHidden = !showDetails
            for text in ["Checking your connection", "Confirming the dev server is running", "Checking the proxy and the firewall"] {
                let l = LabelView("\u{2022}  " + text, font: DSFont.ui(14))
                l.lineHeight = 20
                detailsBox.addSubview(l)
                detailItems.append(l)
            }
        case .fileNotShown(let url, let fileName):
            let host = PreviewURL.host(of: url) ?? url
            heading.text = "This file can\u{2019}t be shown here"
            paragraph.text = "\(fileName) from \(host) was downloaded instead."
            paragraph.boldPrefix = fileName
            code.isHidden = true
            details.isHidden = true
            detailsBox.isHidden = true
            secondary.isHidden = false
            primary.title = "Download"
            primary.isHidden = onDownload == nil
        }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        // `max-w-xl mx-auto px-8 py-16`, icon 48 `mb-6`, h1 `mb-3`, details `mt-6 p-4`, code `mt-8`,
        // footer `mt-auto pt-8`.
        let w = min(576, bounds.width) - 64
        let x = ((bounds.width - min(576, bounds.width)) / 2).rounded() + 32
        var y: CGFloat = 64
        icon.frame = NSRect(x: x, y: y, width: 48, height: 48)
        y += 48 + 24
        heading.frame = NSRect(x: x, y: y, width: w, height: 30)
        y += 30 + 12
        let ph = paragraph.height(forWidth: w)
        paragraph.frame = NSRect(x: x, y: y, width: w, height: ph)
        y += ph
        if !detailsBox.isHidden {
            let h = 16 + 20 + 8 + CGFloat(detailItems.count) * 20 + CGFloat(max(0, detailItems.count - 1)) * 4 + 16 + 2
            detailsBox.frame = NSRect(x: x, y: y + 24, width: w, height: h)
            detailsTitle.frame = NSRect(x: 17, y: 17, width: w - 34, height: 20)
            var iy: CGFloat = 17 + 20 + 8
            for item in detailItems {
                item.frame = NSRect(x: 17 + 4, y: iy, width: w - 38, height: 20)
                iy += 24
            }
            y += 24 + h
        }
        if !code.isHidden {
            code.frame = NSRect(x: x, y: y + 32, width: w, height: 16)
            y += 32 + 16
        }
        let footerY = max(y + 32, bounds.height - 64 - 28)
        details.frame = NSRect(x: x, y: footerY, width: details.intrinsicContentSize.width, height: 28)
        var right = x + w
        for b in [primary, secondary] where !b.isHidden {
            let bw = b.intrinsicContentSize.width
            b.frame = NSRect(x: right - bw, y: footerY, width: bw, height: 28)
            right -= bw + 8
        }
    }

    public override func updateLayer() {
        layer?.backgroundColor = NativePanelGround.color(nativeChrome).cgColor(in: self)
        icon.color = Themed.color(\.mutedForeground, 0.7)
        heading.color = Themed.color(\.foreground)
        paragraph.color = Themed.color(\.mutedForeground)
        paragraph.boldColor = Themed.color(\.foreground)
        code.color = Themed.color(\.mutedForeground, 0.7)
        detailsBox.layer?.backgroundColor = Themed.color(\.muted, 0.4).cgColor(in: self)
        detailsBox.layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        detailsTitle.color = Themed.color(\.foreground)
        detailItems.forEach { $0.color = Themed.color(\.mutedForeground) }
    }

    /// The page's crossed-out document, stroke 2.5 in a 64 box.
    final class ErrorGlyph: DSView {
        var color: NSColor = .gray { didSet { needsDisplay = true } }
        override var wantsUpdateLayer: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let s = bounds.width / 64
            ctx.scaleBy(x: s, y: s)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.5)
            ctx.setLineCap(.round)
            ctx.stroke(CGRect(x: 16, y: 12, width: 32, height: 40))
            for (a, b) in [((22, 22), (42, 22)), ((22, 30), (36, 30)), ((22, 38), (40, 38)), ((52, 8), (12, 56))] {
                ctx.move(to: CGPoint(x: a.0, y: a.1)); ctx.addLine(to: CGPoint(x: b.0, y: b.1))
            }
            ctx.strokePath()
        }
    }
}
