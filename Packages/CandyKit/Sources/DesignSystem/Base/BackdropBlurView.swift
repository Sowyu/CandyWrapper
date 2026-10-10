import AppKit

/// CSS `backdrop-filter: blur(r) saturate(s)` on screen: an `NSVisualEffectView` blending within
/// the window, with its material's tint layers hidden and its backdrop's blur and saturation set
/// to T3's glass values. Put it under the glass fill, same frame and corner radius.
///
/// Layer `backgroundFilters` do nothing in AppKit windows (the window server renders the tree),
/// so the only on-screen blur is the system backdrop. Offscreen snapshots (`layer.render(in:)`)
/// draw nothing for it, which matches T3 over a flat background.
// ponytail: relies on the effect view's private layer tree (a `CABackdropLayer` plus tint sublayers,
// macOS 26/27); when that changes the view hides itself and the glass is unblurred. Revisit on each new macOS.
public final class BackdropBlurView: NSVisualEffectView {
    public var radius: CGFloat = Tokens.LengthPx.glassBlur { didSet { tune() } }
    public var saturation: Double = Tokens.Number.glassSaturation { didSet { tune() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        material = .underWindowBackground
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true
        // `--no-blur`: the unblurred glass, for measuring what the blur costs.
        isHidden = CommandLine.arguments.contains("--no-blur")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // AppKit rebuilds the material layers on appearance, window and size changes; re-tune after each.
    public override func updateLayer() { super.updateLayer(); tune() }
    public override func layout() { super.layout(); tune() }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tune() }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.tune() }
    }

    /// Cheap when nothing changed: a walk over a handful of layers.
    private func tune() {
        guard let root = layer, let sublayers = root.sublayers, !sublayers.isEmpty else { return }
        var backdrop: CALayer?
        func walk(_ l: CALayer) {
            for s in l.sublayers ?? [] {
                if NSStringFromClass(type(of: s)).contains("Backdrop") { backdrop = s; continue }
                if s.sublayers?.isEmpty == false { walk(s) } else if !s.isHidden { s.isHidden = true }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        walk(root)
        if let backdrop, !matches(backdrop) { setFilters(on: backdrop) }
        CATransaction.commit()
        // No backdrop: the material alone would tint the glass, so show nothing.
        let alpha: CGFloat = backdrop == nil ? 0 : 1
        if alphaValue != alpha { alphaValue = alpha }
    }

    /// KVC on a key the object lacks raises an Objective-C exception, which Swift can't catch: ask first.
    private static func property(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func matches(_ backdrop: CALayer) -> Bool {
        let blur = backdrop.filters?.compactMap { $0 as? NSObject }.first { (Self.property($0, "type") as? String) == "gaussianBlur" }
        return (blur?.value(forKey: "inputRadius") as? NSNumber)?.doubleValue == Double(radius)
    }

    /// Fresh filter objects: mutating the attached ones never reaches the window server.
    private func setFilters(on backdrop: CALayer) {
        guard let filters = backdrop.filters, let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return }
        let make = NSSelectorFromString("filterWithType:")
        guard cls.responds(to: make) else { return }
        backdrop.filters = filters.map { filter -> Any in
            guard let old = filter as? NSObject, let type = Self.property(old, "type") as? String,
                  type == "gaussianBlur" || type == "colorSaturate",
                  let new = cls.perform(make, with: type)?.takeUnretainedValue() as? NSObject else { return filter }
            new.setValue(Self.property(old, "name"), forKey: "name")
            if type == "gaussianBlur" {
                new.setValue(radius, forKey: "inputRadius")
                if let edges = old.value(forKey: "inputNormalizeEdges") { new.setValue(edges, forKey: "inputNormalizeEdges") }
            } else {
                new.setValue(saturation, forKey: "inputAmount")
            }
            return new
        }
    }
}
