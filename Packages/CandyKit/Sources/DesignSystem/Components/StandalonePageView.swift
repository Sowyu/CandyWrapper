import AppKit

/// T3's `StandalonePage` (`apps/web/src/components/ui/standalone-page.tsx`): an entry page outside the app
/// shell with a centered 576px card (eyebrow, title, text, then caller content).
/// T3's tone backdrops (radial emerald, red or blue glows) sit under an opaque 145deg overlay in the same
/// layer, so only the overlay shows; we paint that overlay at the layer's 80% opacity and nothing else.
/// Spec: docs/research/recovered/ui-components-b.md section 20.
public final class StandalonePageView: DSView {
    public enum Tone: String, Sendable { case pairing, error, brand }
    public let tone: Tone
    public let card = BoxView()
    /// Caller content below the paragraph.
    public var content: NSView? { didSet { oldValue?.removeFromSuperview(); content.map(card.addSubview); needsLayout = true } }

    private let eyebrow = LabelView()
    private let title = LabelView()
    private let text = TextBlockView()

    public init(tone: Tone, eyebrow: String, title: String, text: String) {
        self.tone = tone
        super.init(frame: .zero)
        self.eyebrow.text = eyebrow.uppercased()
        self.eyebrow.font = DSFont.ui(11, weight: .semibold)
        self.eyebrow.lineHeight = 16.5
        self.eyebrow.tracking = 11 * 0.18
        self.eyebrow.color = Themed.color(\.contrastMutedForeground)
        self.title.text = title
        self.title.font = DSFont.ui(30, weight: .semibold)
        self.title.lineHeight = 36
        self.title.tracking = -30 * 0.025
        self.title.color = Themed.color(\.contrastForeground)
        self.text.text = text
        self.text.font = DSFont.ui(14)
        self.text.lineHeight = 22.75
        self.text.color = Themed.color(\.contrastMutedForeground)
        var box = BoxStyle()
        box.radius = 18
        box.border = Themed.color(\.contrastBorder, 0.8)
        // ponytail: backdrop-blur-md is skipped, the card sits on a smooth gradient where a 12px blur changes nothing visible
        box.fill = Themed.color(\.card, tone == .brand ? 0.94 : 0.9)
        box.shadows = [BoxShadow(y: 25, blur: 50, spread: -12, color: Themed.black(0.2))]
        card.boxStyle = box
        card.decoration.outset = 80
        [self.eyebrow, self.title, self.text].forEach(card.addSubview)
        addSubview(card)
    }

    private func cardHeight(width: CGFloat) -> CGFloat {
        let inner = width - 66
        var h: CGFloat = 1 + 32 + 16.5 + 12 + 36 + 8 + text.height(forWidth: inner) + 32 + 1
        if let content { h += content.intrinsicContentSize.height }
        return h
    }

    public override func layout() {
        super.layout()
        let width = min(576, bounds.width - 48)
        let h = cardHeight(width: width)
        card.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - h) / 2), width: width, height: h)
        let inner = width - 66
        eyebrow.frame = NSRect(x: 33, y: 33, width: inner, height: 16.5)
        title.frame = NSRect(x: 33, y: eyebrow.frame.maxY + 12, width: inner, height: 36)
        let th = text.height(forWidth: inner)
        text.frame = NSRect(x: 33, y: title.frame.maxY + 8, width: inner, height: th)
        content?.frame = NSRect(x: 33, y: text.frame.maxY, width: inner, height: content?.intrinsicContentSize.height ?? 0)
    }

    public override var wantsUpdateLayer: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bg = Themed.color(\.background).cgColor(in: self)
        ctx.setFillColor(bg)
        ctx.fill(bounds)
        // linear-gradient(145deg, mix(background 90|94%, black) 0%, background 55|62%), at opacity .8.
        let darken: CGFloat = tone == .brand ? 0.06 : 0.1
        let stop: CGFloat = tone == .brand ? 0.62 : 0.55
        guard let c = NSColor(cgColor: bg)?.usingColorSpace(.sRGB) else { return }
        let dark = NSColor(srgbRed: c.redComponent * (1 - darken), green: c.greenComponent * (1 - darken),
                           blue: c.blueComponent * (1 - darken), alpha: 1)
        let start = dark.withAlphaComponent(0.8).cgColor, end = c.withAlphaComponent(0.8).cgColor
        let angle = 145 * CGFloat.pi / 180
        let dir = CGPoint(x: sin(angle), y: -cos(angle)) // CSS y is down; the view is flipped
        let length = abs(bounds.width * sin(angle)) + abs(bounds.height * cos(angle))
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let p0 = CGPoint(x: mid.x - dir.x * length / 2, y: mid.y - dir.y * length / 2)
        let p1 = CGPoint(x: mid.x + dir.x * length / 2, y: mid.y + dir.y * length / 2)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [start, end, end] as CFArray, locations: [0, stop, 1])!
        ctx.drawLinearGradient(gradient, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
