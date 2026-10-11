import AppKit

/// Base for every custom-drawn component. Layer-backed, top-left origin like the web
/// layout it copies, and it only redraws when a property it owns changes.
open class DSView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    open override var isFlipped: Bool { true }

    /// Frame-based layout: any size change re-runs `layout()`.
    open override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        needsLayout = true
        // Drawn content depends on the size (truncation, centering), and the redraw policy is
        // onSetNeedsDisplay: without this a label that grew kept its old truncated image.
        if !wantsUpdateLayer, redrawsOnResize { needsDisplay = true }
    }

    /// False for views that redraw the parts a resize changes themselves (a streaming message grows
    /// at its bottom; redrawing all of it per delta is what the spec forbids).
    open var redrawsOnResize: Bool { true }

    /// Subclasses that only set layer properties override `updateLayer` and keep this true.
    /// Subclasses that draw text or paths return false and override `draw(_:)`.
    open override var wantsUpdateLayer: Bool { true }

    /// Re-resolve dynamic colors stored on layers (CGColor does not follow appearance).
    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeGeneration = ThemeRuntime.generation
        needsDisplay = true
    }

    /// Detached and recycled views catch up when they return to a window.
    private var fontGeneration = FontRuntime.generation
    open func fontRuntimeDidChange() {
        fontGeneration = FontRuntime.generation
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private var themeGeneration = ThemeRuntime.generation

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { HoverSync.install(in: window) }
        if window != nil, fontGeneration != FontRuntime.generation { fontRuntimeDidChange() }
        if window != nil, themeGeneration != ThemeRuntime.generation { viewDidChangeEffectiveAppearance() }
    }

    // A view that leaves, hides or shows changes what lies under the pointer; HoverSync re-checks.
    open override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { HoverSync.setNeedsSync(window) }
    }

    open override func viewDidHide() {
        super.viewDidHide()
        HoverSync.setNeedsSync(window)
    }

    open override func viewDidUnhide() {
        super.viewDidUnhide()
        HoverSync.setNeedsSync(window)
    }


    /// Runs `body` with the view's appearance current so dynamic NSColors resolve for it.
    public func resolving<T>(_ body: () -> T) -> T {
        var result: T?
        effectiveAppearance.performAsCurrentDrawingAppearance { result = body() }
        return result!
    }
}

public extension NSColor {
    /// The CGColor for this color under the given view's appearance.
    @MainActor
    func cgColor(in view: NSView) -> CGColor {
        var color = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}
