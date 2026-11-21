import AppKit
import DesignSystem
import QuartzCore

/// Settings and Usage's route surface (3814 AppRouteModal.tsx:40-64). The underlying route stays mounted.
/// Redesign keeps its own chrome on the same behavior: the pill's solid fill, rim and shadow, no sidebar band, and a
/// plain scrim with no blur.
public final class AppRouteModalView: DSView {
    public let surface = DSView()
    private let popup = DSView()
    private let pill = DitherPillSurface()
    public var onDismiss: (() -> Void)?
    private let content: NSView
    private let navigation: NSView?
    private let blurred = CALayer()
    private let tint = CALayer()
    private let decoration = BoxDecorationLayer()
    private let divider = CALayer()
    private let navigationBackground = CALayer()
    /// Redesign with a nav (Settings): the page as one rounded card on the darker chrome, 8pt from the modal's
    /// edges and the nav, in place of the divider and the header bar (the user's option B, settings-panes-mock.html).
    let pageCard = DSView()
    private var keyMonitor: Any?
    private var backdropPressed = false
    public private(set) var isClosing = false
    /// Where focus goes back on close. Settings sets none, so the opener's focus ring stays off; the image gallery
    /// returns it to the view that had it.
    public weak var finalFocus: NSResponder?

    /// Static construction also serves offscreen fidelity renders. Presenting adds the blur and focus guard.
    public init(label: String, content: NSView, navigation: NSView? = nil) {
        self.content = content
        self.navigation = navigation
        super.init(frame: .zero)
        for l in [blurred, tint] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
        }
        blurred.contentsGravity = .resize
        decoration.host = popup
        decoration.outset = 80
        popup.layer?.addSublayer(decoration)
        addSubview(popup)
        pill.ground = true
        popup.addSubview(pill)
        popup.addSubview(surface)
        navigationBackground.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        surface.layer?.addSublayer(navigationBackground)
        surface.layer?.masksToBounds = true
        pageCard.layer?.masksToBounds = true
        pageCard.layer?.cornerCurve = .continuous
        surface.addSubview(pageCard)
        surface.addSubview(content)
        navigation.map(surface.addSubview)
        surface.layer?.addSublayer(divider)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityLabel(label)
    }

    @discardableResult
    public static func present(label: String, content: NSView, navigation: NSView? = nil, in window: NSWindow) -> AppRouteModalView {
        let host = AppRouteModalView(label: label, content: content, navigation: navigation)
        guard let container = window.contentView else { return host }
        // One route at a time: Settings opened over the image gallery replaces it, as Settings replaces Usage.
        for open in container.subviews.compactMap({ $0 as? AppRouteModalView }) where !open.isClosing { open.close(animated: false) }
        host.blurred.contents = ModalHost.blurredSnapshot(of: container)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        if let popups = container.subviews.first(where: { $0 is PopupHost }) { container.addSubview(popups, positioned: .above, relativeTo: host) }
        host.layoutSubtreeIfNeeded()
        // AppRouteModal focuses the surface rather than a control, leaving every focus ring off.
        window.makeFirstResponder(host)
        host.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak host] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated {
                guard let host, event.window === host.window, !host.isClosing,
                      !ModalHost.isPresented(in: host.window), !host.hasPopup else { return false }
                if event.keyCode == 53 {
                    if !event.isARepeat, !host.escapeTaken(), (host.navigation as? SettingsSidebarView)?.consumeSearchEscape() != true { host.close() }
                    return true
                }
                if event.keyCode == 48 {
                    host.moveFocus(backward: event.modifierFlags.contains(.shift))
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        host.animate(entering: true)
        return host
    }

    public static func isPresented(in window: NSWindow?) -> Bool {
        window?.contentView?.subviews.contains { ($0 as? AppRouteModalView)?.isClosing == false } ?? false
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Esc goes to the focused control first: a shortcut recorder cancels (#27151), the keybindings search clears
    /// (#35161) and the theme editor leaves inspection or closes (#25130), each without closing Settings.
    func escapeTaken() -> Bool {
        guard let window else { return false }
        if ThemeEditorController.shared.isInspecting { ThemeEditorController.shared.setInspecting(false); return true }
        var view = window.firstResponder as? NSView
        if let text = view as? NSTextView, text.isFieldEditor, let owner = text.delegate as? NSView { view = owner }
        while let v = view {
            if let handler = v as? RouteModalEscapeHandler, handler.takeRouteModalEscape() { return true }
            view = v.superview
        }
        return false
    }

    public static func surfaceFrame(in size: NSSize) -> NSRect {
        let inset: CGFloat = size.width >= 1024 ? 40 : size.width >= 640 ? 24 : 0
        let width = min(1280, max(0, size.width - 2 * inset))
        let height = min(960, max(0, size.height - 2 * inset))
        return NSRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    public override func layout() {
        super.layout()
        let frame = Self.surfaceFrame(in: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurred.frame = bounds
        tint.frame = bounds
        decoration.layout(boxSize: frame.size)
        popup.frame = frame
        surface.frame = NSRect(origin: .zero, size: frame.size)
        let radius = Self.radius(width: bounds.width, dither: isDither)
        surface.layer?.cornerRadius = radius
        pill.isHidden = !isDither
        pill.radius = radius
        pill.frame = surface.frame
        let navWidth: CGFloat = navigation == nil ? 0 : bounds.width >= 768 ? 240 : 56
        // Popup's border belongs to the surface; children start inside its padding box.
        let edge: CGFloat = bounds.width >= 640 ? 1 : 0
        navigationBackground.frame = NSRect(x: edge, y: edge, width: navWidth, height: max(0, frame.height - 2 * edge))
        navigation?.frame = navigationBackground.frame
        let carded = isDither && navigation != nil
        let page = NSRect(x: edge + navWidth, y: edge, width: max(0, frame.width - navWidth - 2 * edge), height: max(0, frame.height - 2 * edge))
        pageCard.isHidden = !carded
        (content as? SettingsPageView)?.inCard = carded
        if carded {
            navigationBackground.frame = surface.bounds
            pageCard.frame = Self.pageCardFrame(page: page, edgeToEdge: radius == 0)
            pageCard.layer?.cornerRadius = radius
            if content.superview !== pageCard { pageCard.addSubview(content) }
            content.frame = pageCard.bounds
        } else {
            if content.superview !== surface { surface.addSubview(content, positioned: .below, relativeTo: navigation) }
            content.frame = page
        }
        divider.frame = NSRect(x: edge + navWidth - 1, y: edge, width: navigation == nil || carded ? 0 : 1, height: max(0, frame.height - 2 * edge))
        CATransaction.commit()
    }

    /// The card's corner: T3's 16 (AppRouteModal.tsx `sm:rounded-2xl`) in the default themes, Redesign's one surface
    /// radius there, and square once the modal runs edge to edge under 640pt.
    static func radius(width: CGFloat, dither: Bool) -> CGFloat {
        width >= 640 ? (dither ? RedesignTokens.Radius.panel : 16) : 0
    }

    /// Redesign's page card: an even 8pt from the modal's top, right and bottom and from the nav, or the whole page
    /// when the modal itself runs edge to edge.
    static func pageCardFrame(page: NSRect, edgeToEdge: Bool) -> NSRect {
        guard !edgeToEdge else { return page }
        let gap = RedesignTokens.Space.s
        return NSRect(x: page.minX + gap, y: page.minY + gap, width: max(0, page.width - 2 * gap), height: max(0, page.height - 2 * gap))
    }

    private var isDither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }

    public override func updateLayer() {
        if isDither {
            blurred.isHidden = true
            tint.backgroundColor = Themed.color(\.background, effectiveAppearance.isDark ? 0.72 : 0.6).cgColor(in: self)
            decoration.boxStyle = BoxStyle()
            divider.backgroundColor = DitherChrome.rim(dark: effectiveAppearance.isDark).cgColor
            // The nav sits straight on the sidebar's chrome; the page card takes the content ground and the rim.
            navigationBackground.backgroundColor = navigation == nil ? nil : Themed.color(\.sidebar).cgColor(in: self)
            pageCard.layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
            pageCard.layer?.borderWidth = bounds.width >= 640 ? 1 : 0
            pageCard.layer?.borderColor = RedesignTokens.Surface.rim(dark: effectiveAppearance.isDark).cgColor
            return
        }
        blurred.isHidden = false
        tint.backgroundColor = Themed.color(\.background, effectiveAppearance.isDark ? 0.64 : 0.6).cgColor(in: self)
        var style = BoxStyle()
        style.radius = Self.radius(width: bounds.width, dither: false)
        style.fill = Themed.color(\.background)
        style.border = bounds.width >= 640 ? Themed.color(\.border) : nil
        style.shadows = bounds.width >= 640 ? [BoxShadow(y: 25, blur: 50, spread: -12, color: Themed.black(0.4))] : []
        decoration.boxStyle = style
        divider.backgroundColor = Themed.color(\.border).cgColor(in: self)
        navigationBackground.backgroundColor = Themed.color(\.sidebar).cgColor(in: self)
    }

    public func close(animated: Bool = true) {
        if isClosing {
            if !animated {
                removeFromSuperview()
                blurred.contents = nil
                let dismiss = onDismiss
                onDismiss = nil
                dismiss?()
            }
            return
        }
        isClosing = true
        // AppRouteModal.tsx (#25131): end editing first so a field that commits on blur keeps what was typed.
        if let focus = window?.firstResponder as? NSView, focus === self || focus.isDescendant(of: self)
            || ((focus as? NSTextView)?.delegate as? NSView)?.isDescendant(of: self) == true {
            window?.makeFirstResponder(self)
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let finalFocus, let window, (finalFocus as? NSView)?.window === window { window.makeFirstResponder(finalFocus) }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // No finalFocus: let the window receive keys without lighting the opener's focus ring.
            if let focus = self.window?.firstResponder as? NSView, focus === self || focus.isDescendant(of: self) {
                self.window?.makeFirstResponder(nil)
            }
            self.removeFromSuperview()
            self.blurred.contents = nil
            self.onDismiss?()
            self.onDismiss = nil
        }
        if animated { animate(entering: false, completion: finish) } else { finish() }
    }

    isolated deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    public override func cancelOperation(_ sender: Any?) { close() }
    public override func mouseDown(with event: NSEvent) {
        backdropPressed = !popup.frame.contains(convert(event.locationInWindow, from: nil))
    }
    public override func mouseUp(with event: NSEvent) {
        if backdropPressed, !popup.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
        backdropPressed = false
    }
    public override func scrollWheel(with event: NSEvent) {}

    /// A tooltip doesn't count: the one a clicked theme card shows kept Escape from closing Settings.
    private var hasPopup: Bool {
        window?.contentView?.subviews.compactMap { $0 as? PopupHost }.contains { $0.popups.contains { !$0.isPassive } } ?? false
    }

    private func moveFocus(backward: Bool) {
        func walk(_ view: NSView) -> [NSView] {
            guard !view.isHidden else { return [] }
            return (view.acceptsFirstResponder ? [view] : []) + view.subviews.flatMap(walk)
        }
        let views = walk(surface).filter { !($0 is SettingsPageView) && !($0 is UsagePageView) }.sorted {
            let a = $0.convert($0.bounds, to: surface), b = $1.convert($1.bounds, to: surface)
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }
        guard !views.isEmpty else { return }
        let current = views.firstIndex { $0 === window?.firstResponder || ($0 as? NSTextField)?.currentEditor() === window?.firstResponder }
        let next = current.map { ($0 + (backward ? views.count - 1 : 1)) % views.count } ?? (backward ? views.count - 1 : 0)
        window?.makeFirstResponder(views[next])
        func refreshMarkers(_ view: NSView) {
            (view as? InheritanceButton)?.refreshVisibility()
            view.subviews.forEach(refreshMarkers)
        }
        refreshMarkers(surface)
    }

    private func animate(entering: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard !Motion.reduced, let surfaceLayer = popup.layer else { completion?(); return }
        let scale = isDither ? RedesignTokens.Motion.scale : 0.985
        var hidden = CATransform3DMakeTranslation(surface.bounds.width / 2, surface.bounds.height / 2, 0)
        hidden = CATransform3DScale(hidden, scale, scale, 1)
        hidden = CATransform3DTranslate(hidden, -surface.bounds.width / 2, -surface.bounds.height / 2, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        for (target, key, from, to, duration) in [
            (tint, "opacity", 0 as Any, 1 as Any, 0.2),
            (blurred, "opacity", 0 as Any, 1 as Any, 0.2),
            (surfaceLayer, "opacity", 0 as Any, 1 as Any, 0.15),
            (surfaceLayer, "transform", hidden as Any, CATransform3DIdentity as Any, 0.15),
        ] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = entering ? from : to
            animation.toValue = entering ? to : from
            if isDither {
                // Redesign: the backdrop over `large`, the surface over `standard`, both out over `fast`.
                animation.duration = RedesignMotion.modal(backdrop: target !== surfaceLayer, entering: entering)
                animation.timingFunction = RedesignTokens.Motion.timing(entering: entering)
            } else {
                animation.duration = duration
                animation.timingFunction = key == "opacity" && duration == 0.2 ? Motion.easeInOut : CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
            }
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = entering
            target.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}

/// A view inside Settings, or floating over it, that takes Esc from its focused control before Settings closes.
@MainActor protocol RouteModalEscapeHandler: AnyObject {
    func takeRouteModalEscape() -> Bool
}
