import AppKit

/// T3's `InputGroup` with `InputGroupInput` and inline addons (`apps/web/src/components/ui/input-group.tsx`).
/// The group draws the frame; the input inside is unstyled. Block addons and the textarea form are not built yet.
/// Spec: docs/research/recovered/ui-components-a.md section 5.
public final class InputGroupView: DSView {
    public enum Variant: String, CaseIterable, Sendable { case `default`, popover, ghost }
    public enum Size: String, CaseIterable, Sendable { case `default`, lg }

    /// Addon content: an icon (80% opacity, 16px) or a Kbd.
    public enum Addon {
        case icon(IconName)
        case kbd(String)
    }

    public let input = InputView(multiline: false)
    public var variant: Variant = .default { didSet { restyle() } }
    public var size: Size = .default { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    public var leading: Addon? { didSet { rebuildAddons() } }
    public var trailing: Addon? { didSet { rebuildAddons() } }

    private let decoration = BoxDecorationLayer()
    private var leadingView: NSView?
    private var trailingView: NSView?
    private var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    private var trackingArea: NSTrackingArea?

    public convenience init(placeholder: String = "", variant: Variant = .default, size: Size = .default,
                            leading: Addon? = nil, trailing: Addon? = nil) {
        self.init(frame: .zero)
        input.placeholder = placeholder
        self.variant = variant
        self.size = size
        self.leading = leading
        self.trailing = trailing
        rebuildAddons()
        // Observers don't run for properties set in the class's own initializers, so the variant
        // set above would keep the default frame.
        restyle()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        decoration.transition = [.shadow, .border] // transition-shadow (input-group.tsx:10); the border swaps with the ring
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        input.unstyled = true
        input.onStateChange = { [weak self] _ in self?.restyle() }
        addSubview(input)
        restyle()
    }

    /// The group mirrors the input's focus, invalid and disabled state through `:has(input...)`.
    public var state: FieldView.State {
        var s = input.state
        s.hovered = hovered
        return s
    }

    /// Forces a state for the gallery and visual tests.
    public func previewState(_ state: FieldView.State) {
        var inner = state
        inner.hovered = false
        input.previewState(inner)
        hovered = state.hovered
        restyle()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: size == .lg ? 36 : 32)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let inputHeight = DesignGeometry.usesClassic(self) ? CGFloat(30) : input.intrinsicContentSize.height
        let y = (bounds.height - inputHeight) / 2
        // Addons: inline-start has padding-start 11px, svg -mx-0.5; a kbd last child pulls in by 5.6px.
        var x: CGFloat = 1
        if let view = leadingView {
            let w = addonWidth(view)
            let margin: CGFloat = isKbd(leading) ? -5.6 : 0
            x += margin + 11
            view.frame = frame(for: view, x: x, y: y, height: inputHeight)
            x += w
        }
        var right = bounds.width - 1
        if let view = trailingView {
            let w = addonWidth(view)
            let margin: CGFloat = isKbd(trailing) ? -5.6 : 0
            right -= margin + 11
            right -= w
            view.frame = frame(for: view, x: right, y: y, height: inputHeight)
        }
        input.paddingOverride = (leadingView != nil ? 8 : nil, trailingView != nil ? 8 : nil)
        input.frame = NSRect(x: x, y: y, width: max(0, right - x), height: inputHeight)
    }

    private func isKbd(_ addon: Addon?) -> Bool {
        if case .kbd = addon { return true }
        return false
    }

    /// Width the addon takes in the flex row (icons lose 4px to `-mx-0.5`).
    private func addonWidth(_ view: NSView) -> CGFloat {
        if view is IconView { return 16 - 4 }
        return view.intrinsicContentSize.width
    }

    private func frame(for view: NSView, x: CGFloat, y: CGFloat, height: CGFloat) -> NSRect {
        if view is IconView { return NSRect(x: x - 2, y: y + (height - 16) / 2, width: 16, height: 16) }
        let size = view.intrinsicContentSize
        return NSRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)
    }

    private func makeAddon(_ addon: Addon?) -> NSView? {
        switch addon {
        case .icon(let name)?:
            let icon = IconView(name: name, size: 16, strokeColor: Themed.color(\.contrastForeground))
            icon.alphaValue = 0.8  // `not-has-[button]:**:[svg]:opacity-80`
            return icon
        case .kbd(let keys)?:
            let kbd = KbdView(keys)
            kbd.radius = DesignGeometry.radius(5, in: self)  // `[&>kbd]:rounded-[calc(var(--radius)-5px)]`
            return kbd
        case nil:
            return nil
        }
    }

    private func rebuildAddons() {
        leadingView?.removeFromSuperview()
        trailingView?.removeFromSuperview()
        leadingView = makeAddon(leading)
        trailingView = makeAddon(trailing)
        [leadingView, trailingView].compactMap { $0 }.forEach { addSubview($0) }
        needsLayout = true
    }

    // MARK: Pointer

    public override func mouseDown(with event: NSEvent) {
        if input.state.enabled { window?.makeFirstResponder(input.editor) }
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { hovered = true }
    public override func mouseExited(with event: NSEvent) { hovered = false }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        restyle()
    }

    // MARK: Styling

    private func restyle() {
        let s = state
        alphaValue = s.enabled ? 1 : 0.64
        var box: BoxStyle
        switch variant {
        case .default:
            box = FieldStyles.frame(state: s, radius: DesignGeometry.radius(8, in: self))
        case .ghost:
            box = BoxStyle()
            box.radius = DesignGeometry.radius(8, in: self)
            box.border = s.focused ? (s.invalid ? Themed.color(\.destructive, 0.64) : Themed.color(\.ring))
                : (s.invalid ? Themed.color(\.destructive, 0.36) : .clear)
            if s.focused {
                box.fill = WindowGlass.paneFill
            } else if s.hovered {
                box.fill = Themed.color(\.muted, 0.4)
            }
            if s.focused {
                let ring = s.invalid ? Themed.color(light: \.destructive, 0.16, dark: \.destructive, 0.24) : Themed.color(\.ring, 0.24)
                box.shadows = [BoxShadow(spread: 3, color: ring)]
            }
        case .popover:
            // ponytail: dropdown-glass as a flat 83.6% popover fill without backdrop blur, same as Button glass
            box = BoxStyle()
            box.radius = 18
            box.fill = Themed.color(\.popover, Double(PopupSurface.dropdownGlassAlpha))
            box.border = s.focused ? Themed.color(\.contrastForeground, 0.18) : Themed.color(\.contrastForeground, 0.10)
        }
        decoration.boxStyle = box
    }
}
