import AppKit
import DesignSystem

/// A sidebar title that glimmers while the server regenerates it (T3 4928 SidebarThreadRow.tsx, #29383): the title
/// turns `text-muted-foreground` and an `ActivityShimmerOverlay` copy in `text-foreground` shows through the
/// `live-activity-focus` band as it sweeps. It lives inside the title label, so it follows the title's frame.
/// The band runs only while the row is on screen (`LoopingAnimation`), so an idle sidebar stays idle.
final class SidebarTitleGlimmer: DSView {
    private let bright = LabelView()
    private let band = CAGradientLayer()
    private var loop: LoopingAnimation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        addSubview(bright)
        bright.autoresizingMask = [.width, .height]
        bright.color = Themed.color(\.foreground, sidebar: true)
        ShineLabelView.makeFocusBand(band)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        bright.layer?.mask = band
        loop = LoopingAnimation(view: self, key: "glimmer", layer: { [weak self] in self?.band }) { [weak self] in
            ShineLabelView.sweep(to: (self?.bounds.width ?? 0) + 108, duration: 2.2)
        }
    }

    /// Shows the glimmer over `title`, copying its text and font, or removes it.
    static func sync(_ glimmer: inout SidebarTitleGlimmer?, over title: LabelView, active: Bool) {
        guard active else {
            glimmer?.removeFromSuperview()
            return
        }
        let view = glimmer ?? SidebarTitleGlimmer()
        glimmer = view
        if view.superview !== title {
            view.frame = title.bounds
            title.addSubview(view)
        }
        view.bright.font = title.font
        view.bright.lineHeight = title.lineHeight
        view.bright.text = title.text
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.frame = CGRect(x: -72, y: 0, width: 72, height: bounds.height)
        CATransaction.commit()
        band.removeAnimation(forKey: "glimmer")
        loop?.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { band.removeAnimation(forKey: "glimmer") }
        loop?.windowChanged()
    }
    override func viewDidHide() { super.viewDidHide(); loop?.update() }
    override func viewDidUnhide() { super.viewDidUnhide(); loop?.update() }
}
