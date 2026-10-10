import AppKit
import CoreImage
import QuartzCore

/// Hosts a `DialogView` as a modal overlay inside a window, like T3's dialog viewport:
/// a backdrop over the content and the popup centered (dialog, alert dialog) or on an edge (sheet).
/// Escape closes; an outside click closes dialogs and sheets but not alert dialogs (base-ui's
/// `AlertDialog` is not dismissible from outside). Tab stays inside the popup, and focus goes back
/// to the previous first responder on close.
public final class ModalHost: DSView {
    public let panel: DialogView
    /// Called once the exit transition has finished and the host is gone.
    public var onDismiss: (@MainActor () -> Void)?

    private let tint = CALayer()
    private let blurred = CALayer()
    private weak var previousResponder: NSResponder?
    private(set) var isClosing = false

    /// Presents `panel` over `window`'s content view and returns the host.
    @discardableResult
    public static func present(_ panel: DialogView, in window: NSWindow, blurBackdrop: Bool = true) -> ModalHost {
        let host = ModalHost(panel: panel)
        host.previousResponder = window.firstResponder
        if blurBackdrop, let content = window.contentView { host.blurred.contents = Self.blurredSnapshot(of: content) }
        let container = window.contentView!
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        host.trapFocus()
        host.animate(entering: true)
        return host
    }

    /// For the gallery and tests: the host statically open, without a window or motion.
    public init(panel: DialogView) {
        self.panel = panel
        super.init(frame: .zero)
        layer?.addSublayer(blurred)
        layer?.addSublayer(tint)
        for l in [tint, blurred] { l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()] }
        blurred.contentsGravity = .resize
        addSubview(panel)
        panel.onClose = { [weak self] in self?.close() }
        setAccessibilityRole(.group)
    }

    public override var acceptsFirstResponder: Bool { true }

    private var isSheet: Bool { if case .sheet = panel.kind { true } else { false } }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        blurred.frame = bounds
        CATransaction.commit()
        panel.frame = Self.panelFrame(for: panel, in: bounds.size)
    }

    /// T3's viewport placement at desktop widths.
    static func panelFrame(for panel: DialogView, in size: CGSize) -> CGRect {
        let width = panel.preferredWidth(in: size)
        switch panel.kind {
        case .dialog, .alertDialog:
            // `grid-rows-[1fr_auto_1fr] p-4`: centered, at most the viewport height minus padding.
            let h = min(panel.height(forWidth: width), size.height - 32)
            return CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: width, height: h)
        case .sheet(let side):
            let inset: CGFloat = panel.isInset ? 16 : 0
            let content = size.height - 2 * inset
            switch side {
            case .right: return CGRect(x: size.width - inset - width, y: inset, width: width, height: content)
            case .left: return CGRect(x: inset, y: inset, width: width, height: content)
            case .top: return CGRect(x: inset, y: inset, width: width, height: min(panel.height(forWidth: width), content - 48))
            case .bottom:
                let h = min(panel.height(forWidth: width), content - 48)
                return CGRect(x: inset, y: size.height - inset - h, width: width, height: h)
            }
        }
    }

    public override func updateLayer() {
        // `dialog-backdrop`: background at 60% (light) or 64% (dark); the sheet uses 60% in both.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha = isSheet || !dark ? 0.6 : 0.64
        tint.backgroundColor = Themed.color(\.background, alpha).cgColor(in: self)
    }

    // MARK: Dismissal

    public func close() {
        guard !isClosing else { return }
        isClosing = true
        if let previousResponder, let window { window.makeFirstResponder(previousResponder) }
        animate(entering: false) { [weak self] in
            self?.removeFromSuperview()
            self?.onDismiss?()
        }
    }

    public override func cancelOperation(_ sender: Any?) { close() }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point), panel.kind != .alertDialog { close() }
    }

    /// Swallows clicks and scrolls everywhere so nothing under the backdrop reacts.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    public override func scrollWheel(with event: NSEvent) {}

    // MARK: Focus

    /// Focusable views inside the popup in reading order.
    var focusableViews: [NSView] {
        func walk(_ v: NSView) -> [NSView] {
            (v.acceptsFirstResponder && !v.isHidden && v !== panel ? [v] : []) + v.subviews.flatMap(walk)
        }
        return walk(panel).sorted { a, b in
            let fa = a.convert(a.bounds, to: panel), fb = b.convert(b.bounds, to: panel)
            return fa.minY != fb.minY ? fa.minY < fb.minY : fa.minX < fb.minX
        }
    }

    /// Links the popup's focusable views into a closed key-view loop and focuses the first one
    /// (base-ui's initial focus), or the host itself when the popup has none.
    func trapFocus() {
        let views = focusableViews
        for (i, v) in views.enumerated() { v.nextKeyView = views[(i + 1) % views.count] }
        // ponytail: initial focus goes to the first focusable view in reading order (often the close button); T3 can name a target with `initialFocus`, add that when a dialog sets it
        window?.makeFirstResponder(views.first ?? self)
    }

    // MARK: Motion

    /// Backdrop fades over 200ms; the dialog popup scales from .98 and fades, a sheet slides 32px
    /// toward its edge and fades, both 200ms `cubic-bezier(.4,0,.2,1)`. Reduce Motion skips the motion.
    func animate(entering: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let layer, let panelLayer = panel.layer, !Motion.reduced else { completion?(); return }
        let hidden = hiddenTransform()
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        for (target, key, from, to) in [
            (layer, "opacity", entering ? 0 : 1, entering ? 1 : 0) as (CALayer, String, Any, Any),
            (panelLayer, "transform", entering ? hidden : CATransform3DIdentity, entering ? CATransform3DIdentity : hidden),
        ] {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.2
            a.timingFunction = Motion.easeInOut
            a.fillMode = .forwards
            a.isRemovedOnCompletion = entering
            target.add(a, forKey: key)
        }
        CATransaction.commit()
    }

    private func hiddenTransform() -> CATransform3D {
        guard case .sheet(let side) = panel.kind else {
            // Scale about the popup's center: the view layer's anchor is its origin.
            let f = panel.frame
            var t = CATransform3DMakeTranslation(f.width / 2, f.height / 2, 0)
            t = CATransform3DScale(t, 0.98, 0.98, 1)
            return CATransform3DTranslate(t, -f.width / 2, -f.height / 2, 0)
        }
        switch side {
        case .right: return CATransform3DMakeTranslation(32, 0, 0)
        case .left: return CATransform3DMakeTranslation(-32, 0, 0)
        case .top: return CATransform3DMakeTranslation(0, -32, 0)
        case .bottom: return CATransform3DMakeTranslation(0, 32, 0)
        }
    }

    // MARK: Backdrop blur

    /// One blurred snapshot of the window content for `backdrop-filter: blur(4px)`: drawn at a quarter
    /// of the point size and blurred with sigma 1, which is 4pt at full size. Taken once, when the dialog opens.
    // ponytail: frozen snapshot, content under the backdrop stops updating while the dialog is open; live blur (NSVisualEffectView) if that ever shows
    public static func blurredSnapshot(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage.flatMap { blurred($0, pointSize: view.bounds.size) }
    }

    /// `image` drawn at a quarter of `pointSize` and blurred with sigma 1.
    static func blurred(_ full: CGImage, pointSize: CGSize) -> CGImage? {
        let w = max(1, Int(pointSize.width / 4)), h = max(1, Int(pointSize.height / 4))
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        small.interpolationQuality = .medium
        small.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let downscaled = small.makeImage() else { return nil }
        let input = CIImage(cgImage: downscaled)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: input.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }
}
