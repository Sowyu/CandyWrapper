import AppKit

/// anchoredCopyToast.ts:4-19: passive tooltip, above its button, alive for one second.
@MainActor
public enum AnchoredCopyToast {
    public static func show(from view: NSView, success: Bool = true) {
        guard let host = view.popupHost else { return }
        let tip = AnchoredCopyToastView(success ? "Copied!" : "Failed to copy")
        let popup = host.open(tip, trigger: view, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4), motion: .tooltip,
                              pressesTrigger: false, returnsFocus: false, passive: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak host, weak popup] in
            guard let popup else { return }
            host?.close(popup, returnFocus: false)
        }
    }
}

/// toast.tsx:731-740: dropdown glass, rounded-md, text-xs, px-2 py-1.
public final class AnchoredCopyToastView: DSView, PopupContent {
    private let label: LabelView
    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()
    public var frostRadius: CGFloat { 6 }
    public init(_ text: String = "Copied!") {
        label = LabelView(text, font: DSFont.ui(12), color: PopupSurface.text)
        label.lineHeight = 16
        super.init(frame: .zero)
        decoration.host = self; dropShadow.host = self
        layer?.masksToBounds = false
        let surface = PopupSurface.tooltipGlass.split(radius: 6)
        decoration.boxStyle = surface.box
        dropShadow.radius = 6; dropShadow.shadows = surface.shadows
        layer?.addSublayer(dropShadow); layer?.addSublayer(decoration)
        addSubview(label)
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: label.textWidth + 18, height: 26) }
    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        dropShadow.update(boxSize: bounds.size)
        label.frame = bounds.insetBy(dx: 9, dy: 5)
    }
}
