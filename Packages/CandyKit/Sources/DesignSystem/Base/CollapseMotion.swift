import AppKit
import QuartzCore

/// T3's `CollapsiblePanel` with `animate` on (ui/collapsible.tsx:33): `transition-[height] duration-200` on
/// the default curve, `motion-reduce:transition-none`. CSS runs the panel's height, so the panel shows or
/// hides its content from its bottom edge and everything laid out after it rides along.
///
/// `run(in:)` does that for frame layout. It notes where every visible layer of the scroll document (or
/// the window) sits, runs the change, lays the window out, then slides each layer that moved back from
/// where it was. Layers that appear inside `container` are clipped below a line that runs with the
/// container's bottom edge. Layers the change hid show as an image taken before the change (a hidden
/// view's own drawing does not survive) until that line has passed them. Nothing is left running after
/// the 200 ms.
@MainActor
public enum CollapseMotion {
    public static let duration: CFTimeInterval = 0.2

    private struct Geometry { let layer: CALayer; let position: CGPoint; let bounds: CGRect; let drawnAndVisible: Bool }
    private final class Run {
        var masks: [(layer: CALayer, mask: CALayer)] = []
        var snapshot: CALayer?
        var restored: [(layer: CALayer, contents: CGImage)] = []
    }
    private static var runs: [ObjectIdentifier: Run] = [:]

    /// Runs `change`, which opens or closes a panel inside `container`, and animates the result. Layers
    /// under `root` (the enclosing scroll document, else the window) slide. Snaps under Reduce Motion,
    /// outside a window or with `animated` false. `showsClosingContent` false is T3's `{open ? … : null}`
    /// panel body: the content goes at once and only the gap closes.
    public static func run(in container: NSView, root rootView: NSView? = nil, animated: Bool = true,
                           showsClosingContent: Bool = true, _ change: () -> Void) {
        let key = ObjectIdentifier(container)
        if let previous = runs.removeValue(forKey: key) { finish(previous) }
        guard animated, !Motion.reduced, let window = container.window, let content = window.contentView,
              let box = container.layer,
              let root = (rootView ?? container.enclosingScrollView?.documentView ?? content).layer else {
            change()
            return
        }
        var before: [ObjectIdentifier: Geometry] = [:]
        visitVisible(root) { layer in
            let now = layer.presentation() ?? layer
            let drawn = (layer.delegate as? NSView).map { !$0.wantsUpdateLayer && $0.visibleRect.size == $0.bounds.size } ?? false
            before[ObjectIdentifier(layer)] = Geometry(layer: layer, position: now.position, bounds: now.bounds, drawnAndVisible: drawn)
            return true
        }
        let scale = window.backingScaleFactor
        let image = showsClosingContent ? render(box, scale: scale) : nil
        let scroller = container.enclosingScrollView?.contentView.layer
        let scrollBefore = scroller.map { ($0.presentation() ?? $0).bounds }
        change()
        content.layoutSubtreeIfNeeded()
        // AppKit moves view layers to their new frames during display, not in layout.
        window.displayIfNeeded()

        // What the change showed inside the container (top-most layers only) and what it hid.
        var revealed: [CALayer] = []
        visitVisible(box) { layer in
            guard layer !== box, before[ObjectIdentifier(layer)] == nil else { return true }
            revealed.append(layer)
            return false
        }
        let hidden = before.values.map(\.layer).filter { $0.isHidden && $0 !== box && isLayer($0, under: box) }

        let run = Run()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard runs[key] === run else { return }
                runs[key] = nil
                finish(run)
            }
        }
        // The clip line is the panel's bottom edge: it runs between the top and the bottom of what the
        // panel shows, with the same timing as the layers after it.
        if !revealed.isEmpty {
            let frames = revealed.map { box.convert($0.bounds, from: $0) }
            if let top = frames.map(\.minY).min(), let end = frames.map(\.maxY).max() {
                clip(revealed, in: box, from: top, to: end, run: run)
            }
        }
        if !hidden.isEmpty, showsClosingContent, let image {
            let frames = hidden.map { box.convert($0.bounds, from: $0) }
            let top = frames.map(\.minY).min() ?? 0, start = frames.map(\.maxY).max() ?? 0
            let margin: CGFloat = 12
            let rect = CGRect(x: -margin, y: top, width: box.bounds.width + 2 * margin, height: start - top)
            let pixels = CGRect(x: 0, y: (top + margin) * scale, width: rect.width * scale, height: rect.height * scale).integral
            if rect.height > 0, let piece = image.cropping(to: pixels) {
                let snapshot = CALayer()
                snapshot.contents = piece
                snapshot.contentsScale = scale
                snapshot.frame = rect
                box.addSublayer(snapshot)
                run.snapshot = snapshot
                clip([snapshot], in: box, from: start, to: top, run: run)
            }
        }
        for g in before.values where g.layer !== root && !g.layer.isHidden && isLayer(g.layer, under: root) {
            let layer = g.layer
            // AppKit draws a view's backing only where it is visible, so a view that lands below the
            // scroll view's visible rect would slide in blank: give it a full image until the run ends.
            if g.drawnAndVisible, let view = layer.delegate as? NSView, view.visibleRect.size != view.bounds.size, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let image = rep.cgImage {
                    layer.contents = image
                    run.restored.append((layer, image))
                }
            }
            if layer.position != g.position {
                add(layer, "position", from: NSValue(point: g.position), to: NSValue(point: layer.position))
            }
            // A drawn layer would stretch its old image; box decorations 9-slice, so they may.
            if layer.bounds != g.bounds, layer.contents == nil || layer is BoxDecorationLayer {
                add(layer, "bounds", from: NSValue(rect: g.bounds), to: NSValue(rect: layer.bounds))
            }
        }
        // A document that shrinks under a view scrolled to its end clamps the scroll offset. A browser
        // clamps it frame by frame as the height runs, so the page glides down instead of jumping.
        if let scroller, let scrollBefore, scroller.bounds.origin != scrollBefore.origin {
            add(scroller, "bounds", from: NSValue(rect: scrollBefore), to: NSValue(rect: scroller.bounds))
        }
        runs[key] = run
        CATransaction.commit()
    }

    /// Hides what of `layers` lies below a line in `box`'s coordinates that moves from `from` to `to`, as
    /// a CSS `overflow-hidden` track whose height runs. The masks go when the animation ends.
    public static func clipBelow(_ layers: [CALayer], in box: CALayer, from: CGFloat, to: CGFloat,
                                 duration: CFTimeInterval = duration, timing: CAMediaTimingFunction = Motion.easeInOut) {
        let run = Run()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish(run) } }
        clip(layers, in: box, from: from, to: to, run: run, duration: duration, timing: timing)
        CATransaction.commit()
    }

    /// Masks each layer below a line that moves from `from` to `to`, in the container's coordinates.
    private static func clip(_ layers: [CALayer], in box: CALayer, from: CGFloat, to: CGFloat, run: Run,
                             duration: CFTimeInterval = duration, timing: CAMediaTimingFunction = Motion.easeInOut) {
        for layer in layers where layer.mask == nil {
            let frame = box.convert(layer.bounds, from: layer)
            let top = layer.bounds.minY - frame.minY
            let mask = CALayer()
            mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            // Wide and tall enough for shadows and focus rings; only its bottom edge moves.
            mask.bounds = CGRect(x: 0, y: 0, width: layer.bounds.width + 2000, height: 100_000)
            mask.anchorPoint = CGPoint(x: 0, y: 1)
            mask.position = CGPoint(x: layer.bounds.minX - 1000, y: top + to)
            layer.mask = mask
            add(mask, "position.y", from: top + from, to: top + to, duration: duration, timing: timing)
            run.masks.append((layer, mask))
        }
    }

    private static func add(_ layer: CALayer, _ keyPath: String, from: Any, to: Any,
                            duration: CFTimeInterval = duration, timing: CAMediaTimingFunction = Motion.easeInOut) {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = timing
        layer.add(a, forKey: "collapse.\(keyPath)")
    }

    private static func finish(_ run: Run) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, mask) in run.masks where layer.mask === mask { layer.mask = nil }
        run.snapshot?.removeFromSuperlayer()
        for (layer, contents) in run.restored where (layer.contents as AnyObject?) === contents {
            (layer.delegate as? NSView)?.needsDisplay = true
        }
        CATransaction.commit()
    }

    /// The container as it is on screen now, `margin` wider on each side for shadows, one row of
    /// pixels per scaled point from its top. Rendered only when the container is small enough to be cheap.
    private static func render(_ box: CALayer, scale: CGFloat, margin: CGFloat = 12) -> CGImage? {
        let size = CGSize(width: (box.bounds.width + 2 * margin) * scale, height: (box.bounds.height + margin) * scale)
        // ponytail: one image of the whole container per toggle, cap at 16 megapixels; render only the panel if a big one shows up
        guard size.width > 0, size.height > 0, size.width * size.height < 16_000_000,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Image rows run top down; the container's y runs down too (flipped views), so flip once.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: margin - box.bounds.minX, y: margin - box.bounds.minY)
        box.render(in: ctx)
        return ctx.makeImage()
    }

    /// Visits `layer` and its visible sublayers depth first; `body` returns false to skip a subtree.
    private static func visitVisible(_ layer: CALayer, _ body: (CALayer) -> Bool) {
        guard !layer.isHidden, body(layer) else { return }
        for sub in layer.sublayers ?? [] { visitVisible(sub, body) }
    }

    private static func isLayer(_ layer: CALayer, under ancestor: CALayer) -> Bool {
        var l: CALayer? = layer
        while let current = l {
            if current === ancestor { return true }
            l = current.superlayer
        }
        return false
    }
}
