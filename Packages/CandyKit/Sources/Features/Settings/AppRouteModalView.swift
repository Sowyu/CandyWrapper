import AppKit
import DesignSystem
import QuartzCore

/// Settings and Usage's route surface (3814 AppRouteModal.tsx:40-64). The underlying route stays mounted.
/// Redesign keeps its own chrome on the same behavior: the pill's frosted fill, rim and shadow, no sidebar band, and a
/// heavier scrim in place of the blur under Reduce Transparency.
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
    private var keyMonitor: Any?
    private var backdropPressed = false
    public private(set) var isClosing = false

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
        popup.addSubview(pill)
        popup.addSubview(surface)
        navigationBackground.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        surface.layer?.addSublayer(navigationBackground)
        surface.layer?.masksToBounds = true
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
                    if !event.isARepeat, (host.navigation as? SettingsSidebarView)?.consumeSearchEscape() != true { host.close() }
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
        let radius: CGFloat = bounds.width >= 640 ? 16 : 0
        surface.layer?.cornerRadius = radius
        pill.isHidden = !isDither
        pill.radius = radius
        pill.frame = surface.frame
        let navWidth: CGFloat = navigation == nil ? 0 : bounds.width >= 768 ? 240 : 56
        // Popup's border belongs to the surface; children start inside its padding box.
        let edge: CGFloat = bounds.width >= 640 ? 1 : 0
        navigationBackground.frame = NSRect(x: edge, y: edge, width: navWidth, height: max(0, frame.height - 2 * edge))
        navigation?.frame = navigationBackground.frame
        content.frame = NSRect(x: edge + navWidth, y: edge, width: max(0, frame.width - navWidth - 2 * edge), height: max(0, frame.height - 2 * edge))
        divider.frame = NSRect(x: edge + navWidth - 1, y: edge, width: navigation == nil ? 0 : 1, height: max(0, frame.height - 2 * edge))
        CATransaction.commit()
    }

    private var isDither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }

    public override func updateLayer() {
        if isDither {
            // Without the blur the route would read through the 62% tint, so it takes the art's heavy page scrim (DitherArt.pageScrim).
            let blurs = DitherPill.blurs
            blurred.isHidden = !blurs
            tint.backgroundColor = Themed.color(\.background, blurs ? (effectiveAppearance.isDark ? 0.64 : 0.6) : 0.92).cgColor(in: self)
            decoration.boxStyle = BoxStyle()
            divider.backgroundColor = DitherChrome.rim(dark: effectiveAppearance.isDark).cgColor
            navigationBackground.backgroundColor = nil
            return
        }
        blurred.isHidden = false
        tint.backgroundColor = Themed.color(\.background, effectiveAppearance.isDark ? 0.64 : 0.6).cgColor(in: self)
        var style = BoxStyle()
        style.radius = bounds.width >= 640 ? 16 : 0
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
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

    private var hasPopup: Bool {
        window?.contentView?.subviews.compactMap { $0 as? PopupHost }.contains { !$0.popups.isEmpty } ?? false
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
        var hidden = CATransform3DMakeTranslation(surface.bounds.width / 2, surface.bounds.height / 2, 0)
        hidden = CATransform3DScale(hidden, 0.985, 0.985, 1)
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
            animation.duration = duration
            animation.timingFunction = key == "opacity" && duration == 0.2 ? Motion.easeInOut : CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = entering
            target.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}
