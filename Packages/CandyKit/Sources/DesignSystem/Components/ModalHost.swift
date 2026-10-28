import AppKit
import Accelerate
import QuartzCore

/// Hosts a `DialogView` as a modal overlay inside a window, like T3's dialog viewport:
/// a backdrop over the content and the popup centered (dialog, alert dialog) or on an edge (sheet).
/// Escape closes; an outside click closes dialogs and sheets but not alert dialogs (base-ui's
/// `AlertDialog` is not dismissible from outside). Tab stays inside the popup, and focus goes back
/// to the previous first responder on close.
public final class ModalHost: DSView {
    public var allowsUserDismissal = true
    public let panel: DialogView
    /// Called once the exit transition has finished and the host is gone.
    public var onDismiss: (@MainActor () -> Void)?

    private let tint = CALayer()
    private let blurred = CALayer()
    private weak var previousResponder: NSResponder?
    private(set) var isClosing = false
    /// The dialog that was open under this one: base-ui marks this popup `data-nested`.
    private weak var parentHost: ModalHost?
    /// `--nested-dialogs`: how many dialogs are open above this one.
    private var nestedDialogs = 0

    /// Presents `panel` over `window`'s content view and returns the host.
    @discardableResult
    public static func present(_ panel: DialogView, in window: NSWindow, blurBackdrop: Bool = true) -> ModalHost {
        let host = ModalHost(panel: panel)
        host.previousResponder = window.firstResponder
        if blurBackdrop, let content = window.contentView { host.blurred.contents = Self.blurredSnapshot(of: content) }
        let container = window.contentView!
        host.parentHost = container.subviews.last { ($0 as? ModalHost)?.isClosing == false } as? ModalHost
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        host.trapFocus()
        host.animate(entering: true)
        host.parentHost?.nestedDialogsChanged(by: 1)
        return host
    }

    /// True while a modal covers `window`. base-ui makes everything outside an open dialog inert, so views that
    /// focus themselves (the composer after a shell loads) check this instead of taking keys from the dialog.
    public static func isPresented(in window: NSWindow?) -> Bool {
        window?.contentView?.subviews.contains { ($0 as? ModalHost)?.isClosing == false } ?? false
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
        panel.onClose = { [weak self] in if self?.allowsUserDismissal == true { self?.close() } }
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
        // AppKit resets a view layer's transform when it syncs the frame.
        if nestedDialogs > 0, panel.layer?.animation(forKey: "transform") == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.layer?.transform = nestedTransform()
            CATransaction.commit()
        }
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

    /// `animated` false removes the dialog at once, as React does when a component swaps one dialog for
    /// another (AddProviderInstanceDialog.tsx:365-372).
    public func close(animated: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        parentHost?.nestedDialogsChanged(by: -1)
        if let previousResponder, let window { window.makeFirstResponder(previousResponder) }
        guard animated else {
            removeFromSuperview()
            onDismiss?()
            return
        }
        animate(entering: false) { [weak self] in
            self?.removeFromSuperview()
            self?.onDismiss?()
        }
    }

    public override func cancelOperation(_ sender: Any?) { if allowsUserDismissal { close() } }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { if allowsUserDismissal { close() } } else { super.keyDown(with: event) }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if allowsUserDismissal, !panel.frame.contains(point), panel.kind != .alertDialog { close() }
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
            // Scale about the popup's center: the view layer's anchor is its origin. A nested popup
            // also starts and ends 32px lower (`data-nested:data-starting-style:translate-y-8`).
            let f = panel.frame
            let drop: CGFloat = parentHost == nil ? 0 : 32
            var t = CATransform3DMakeTranslation(f.width / 2, f.height / 2 + drop, 0)
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

    // MARK: Nested dialogs

    /// T3's popup under an open nested dialog moves up 1.25rem, scales by 1 - .1n about its top edge and
    /// fades to 1 - .1n per nested dialog, over the popup's 200ms transition (`dialog-styles.ts:8`).
    private func nestedDialogsChanged(by delta: Int) {
        nestedDialogs = max(0, nestedDialogs + delta)
        parentHost?.nestedDialogsChanged(by: delta)
        // Sheets have their own popup classes without the nested offset.
        if case .sheet = panel.kind { return }
        guard let panelLayer = panel.layer else { return }
        let transform = nestedTransform(), opacity = Float(1 - 0.1 * CGFloat(nestedDialogs))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !Motion.reduced {
            Motion.animate(panelLayer, keyPath: "transform", to: NSValue(caTransform3D: transform), duration: 0.2)
            Motion.animate(panelLayer, keyPath: "opacity", to: opacity, duration: 0.2)
        }
        panelLayer.transform = transform
        panelLayer.opacity = opacity
        CATransaction.commit()
    }

    private func nestedTransform() -> CATransform3D {
        guard nestedDialogs > 0 else { return CATransform3DIdentity }
        let n = CGFloat(nestedDialogs), w = panel.frame.width
        // `origin-top`: y grows downward here, so the top edge is y = 0.
        var t = CATransform3DMakeTranslation(w / 2, -20 * n, 0)
        t = CATransform3DScale(t, 1 - 0.1 * n, 1 - 0.1 * n, 1)
        return CATransform3DTranslate(t, -w / 2, 0, 0)
    }

    // MARK: Backdrop blur

    /// One blurred snapshot of the window content for `backdrop-filter: blur(4px)`: drawn at a quarter
    /// of the point size and blurred with sigma 1, which is 4pt at full size. Taken once, when the dialog opens.
    /// The view draws at half its point size and that is halved again: a backing-scale snapshot cost about
    /// 10 MB per dialog at 2x, and the allocator kept the freed buffers dirty. Drawing straight at a quarter
    /// moved thin text and borders by up to 10 levels under the tint; the half-size pass keeps them within 5.
    // ponytail: frozen snapshot, content under the backdrop stops updating while the dialog is open; live blur (NSVisualEffectView) if that ever shows
    /// True while `blurredSnapshot` draws the window. A view whose backing store relies on its layer's background
    /// (the terminal clears its cells to transparent) paints that background itself then.
    public private(set) static var isTakingSnapshot = false

    /// `excluding`: a subview left out, such as an open overlay taking a fresh backdrop. The other subviews draw one by
    /// one at their frames, so the overlay keeps the first responder and never leaves the screen.
    public static func blurredSnapshot(of view: NSView, excluding excluded: NSView? = nil) -> CGImage? {
        let size = view.bounds.size
        guard let half = context(Int(size.width / 2), Int(size.height / 2)) else { return nil }
        half.scaleBy(x: CGFloat(half.width) / max(1, size.width), y: CGFloat(half.height) / max(1, size.height))
        isTakingSnapshot = true
        defer { isTakingSnapshot = false }
        let context = NSGraphicsContext(cgContext: half, flipped: false)
        if let excluded {
            for sub in view.subviews where sub !== excluded && !sub.isHidden {
                let frame = sub.frame
                half.saveGState()
                half.translateBy(x: frame.minX, y: view.isFlipped ? size.height - frame.maxY : frame.minY)
                sub.displayIgnoringOpacity(sub.bounds, in: context)
                half.restoreGState()
            }
        } else {
            view.displayIgnoringOpacity(view.bounds, in: context)
        }
        return half.makeImage().flatMap { blurred($0, pointSize: size) }
    }

    /// `image` drawn at a quarter of `pointSize` and blurred with sigma 1.
    ///
    /// The blur runs on the CPU with vImage. It used Core Image before, and a fresh `CIContext` sets up a
    /// Metal context each time: the abuse test (docs/research/m10-abuse-2026-10-12.md) measured 120 to
    /// 255 ms main-thread stalls on every ⌘K. A 7x7 kernel over a quarter-size bitmap takes well under 1 ms.
    /// It blurs the sRGB-encoded values as Chromium does for `backdrop-filter`; Core Image blurred in linear light.
    static func blurred(_ image: CGImage, pointSize: CGSize) -> CGImage? {
        guard let small = context(Int(pointSize.width / 4), Int(pointSize.height / 4)) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        guard let out = context(small.width, small.height), let from = small.data, let to = out.data else { return nil }
        var src = vImage_Buffer(data: from, height: vImagePixelCount(small.height), width: vImagePixelCount(small.width), rowBytes: small.bytesPerRow)
        var dst = vImage_Buffer(data: to, height: vImagePixelCount(out.height), width: vImagePixelCount(out.width), rowBytes: out.bytesPerRow)
        // Core Image's sigma-1 Gaussian, measured from its response to one bright pixel (center, then
        // 1, 2 and 3 pixels out); it is a little wider than exp(-x^2 / 2). Edges extend, like
        // `clampedToExtent()`. Premultiplied channels blur correctly as they are.
        let half: [Float] = [0.14668, 0.09261, 0.02323, 0.00231]
        let taps = (-3...3).map { half[abs($0)] }
        let sum = taps.reduce(0, +)
        let kernel = taps.flatMap { a in taps.map { a * $0 / (sum * sum) } }
        let status = vImageConvolveFloatKernel_ARGB8888(&src, &dst, nil, 0, 0, kernel, 7, 7, 0, nil, vImage_Flags(kvImageEdgeExtend))
        return status == kvImageNoError ? out.makeImage() : nil
    }

    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
