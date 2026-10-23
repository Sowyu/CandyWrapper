import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's subagent strip (after Capy's activity strip, docs/research/capy-subagents.md): a pill in the row above
/// the composer with the status glyph, the count and a chevron, which opens `SubagentStripPanelView` over the timeline.
public final class SubagentStripPillView: ComposerBannerView {
    public var onToggle: (() -> Void)?
    public var expanded = false { didSet { if expanded != oldValue { restyle() } } }
    public private(set) var strip = SubagentStrip()

    private let row = BannerRowButton()
    private var glyph: NSView = NSView()
    private var glyphStatus: SubagentStrip.Status?
    private let label = glassLabel("0", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let chevron = IconView(name: .chevronUp, size: 12, strokeColor: Themed.color(\.mutedForeground))

    public init() {
        super.init(variant: .neutral)
        placement = .floating
        row.addSubview(label)
        row.addSubview(chevron)
        row.action = { [weak self] in self?.onToggle?() }
        row.onHover = { [weak self] _ in self?.restyle() }
        addSubview(row)
        restyle()
    }

    public func configure(_ strip: SubagentStrip) {
        guard strip != self.strip else { return }
        let widthChanged = strip.pillText != self.strip.pillText
        self.strip = strip
        label.text = strip.pillText
        // The pill spins while anything runs; waiting or asking alone shows that glyph instead.
        let status: SubagentStrip.Status = strip.rows.contains { $0.status == .running } ? .running
            : strip.rows.first { !$0.finished }?.status ?? .running
        if status != glyphStatus {
            glyphStatus = status
            glyph.removeFromSuperview()
            glyph = SubagentStripGlyph.make(status)
            row.addSubview(glyph)
        }
        row.setAccessibilityLabel(strip.accessibilityLabel + (expanded ? ". Hide subagents." : ". Show subagents."))
        needsLayout = true
        if widthChanged { superview?.needsLayout = true }
    }

    /// 6 a side, the 24pt glyph column, the label, 4, the 12pt chevron and 6 after it.
    public var preferredWidth: CGFloat { 6 + 24 + ceil(label.textWidth) + 4 + 12 + 6 + 6 }

    private func restyle() {
        let strong = expanded || row.state.hovered
        Motion.transitioning(window == nil ? [] : .colors, duration: 0.2) {
            label.color = strong ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
            chevron.strokeColor = strong ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        }
        // Capy turns the chevron over while the list shows (`rotate-180`).
        chevron.layer?.setAffineTransform(expanded ? CGAffineTransform(rotationAngle: .pi) : .identity)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        row.frame = NSRect(x: 6, y: ((bounds.height - 24) / 2).rounded(), width: max(0, bounds.width - 12), height: 24)
        glyph.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
        label.frame = NSRect(x: 24, y: 4, width: ceil(label.textWidth), height: 16)
        let cx = label.frame.maxX + 4
        let chevronFrame = NSRect(x: cx, y: 6, width: 12, height: 12)
        if chevron.frame != chevronFrame {
            chevron.frame = chevronFrame
            // Rotation about the middle: AppKit resets the anchor when the frame moves.
            if let layer = chevron.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.position = CGPoint(x: chevronFrame.midX, y: chevronFrame.midY)
                layer.setAffineTransform(expanded ? CGAffineTransform(rotationAngle: .pi) : .identity)
            }
        }
    }
}

/// The open strip: one 32pt row per subagent, then a chevron that closes it. Scrolls past `maxHeight`.
public final class SubagentStripPanelView: ComposerBannerView {
    public struct Item: Equatable {
        public var row: SubagentStrip.Row
        public var modelName: String
        public var stopping: Bool
        public init(row: SubagentStrip.Row, modelName: String, stopping: Bool = false) {
            self.row = row; self.modelName = modelName; self.stopping = stopping
        }
    }

    public var items: [Item] = [] { didSet { if items != oldValue { rebuild() } } }
    public var onOpen: ((SubagentStrip.Row) -> Void)?
    public var onStop: ((SubagentStrip.Row) -> Void)?
    public var onCollapse: (() -> Void)?

    static let row: CGFloat = 32, pad: CGFloat = 4, footer: CGFloat = 22

    private let list = FlippedDocument()
    private lazy var scroll = ScrollAreaView(documentView: list, scrollFade: true)
    private var rows: [SubagentStripRowView] = []
    private let collapse = BannerRowButton()
    private let chevron = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.mutedForeground))

    public init() {
        super.init(variant: .neutral)
        placement = .floating
        scroll.scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        collapse.addSubview(chevron)
        collapse.setAccessibilityLabel("Hide subagents")
        collapse.action = { [weak self] in self?.onCollapse?() }
        collapse.onHover = { [weak self] hovered in
            self?.chevron.strokeColor = hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        }
        addSubview(collapse)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Subagents")
    }

    public func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        let list = CGFloat(items.count) * Self.row
        return min(maxHeight, Self.pad * 2 + list + Self.footer)
    }

    private func rebuild() {
        // Rows keep their view while the subagent stays, so a hovered row keeps its Stop under the mouse.
        var old = Dictionary(rows.map { ($0.item?.row.id ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        rows = items.map { item in
            let view = old.removeValue(forKey: item.row.id) ?? SubagentStripRowView()
            view.item = item
            view.onOpen = { [weak self] in self?.onOpen?(item.row) }
            view.onStop = { [weak self] in self?.onStop?(item.row) }
            if view.superview !== list { list.addSubview(view) }
            return view
        }
        old.values.forEach { $0.removeFromSuperview() }
        needsLayout = true
        superview?.needsLayout = true
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, inner = max(0, w - 2 * Self.pad)
        let visible = max(0, bounds.height - Self.pad * 2 - Self.footer)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: visible)
        list.frame = NSRect(x: 0, y: 0, width: inner, height: CGFloat(rows.count) * Self.row)
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(i) * Self.row, width: inner, height: Self.row) }
        collapse.frame = NSRect(x: (w - 40) / 2, y: bounds.height - Self.pad - Self.footer, width: 40, height: Self.footer)
        chevron.frame = NSRect(x: 13, y: (Self.footer - 14) / 2, width: 14, height: 14)
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

/// One subagent: the status glyph, "Subagent N", its title fading out, then the provider mark and model at the right;
/// Stop (x) shows on hover when the task can stop. Finished rows are dimmed.
final class SubagentStripRowView: DSView {
    var item: SubagentStripPanelView.Item? { didSet { if item != oldValue { apply(old: oldValue) } } }
    var onOpen: (() -> Void)?
    var onStop: (() -> Void)?
    private(set) var hovered = false

    private var glyph = NSView()
    private var provider = NSView()
    private let name = glassLabel(font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground), lineHeight: 16)
    private let title = glassLabel(font: DSFont.ui(13), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let model = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    let stop = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        layer?.cornerRadius = DitherChrome.controlRadius - 2
        title.truncation = .end
        [name, title, model].forEach(addSubview)
        stop.iconSize = 14
        stop.smoothsFont = false
        stop.isHidden = true
        stop.action = { [weak self] in self?.onStop?() }
        addSubview(stop)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func apply(old: SubagentStripPanelView.Item?) {
        guard let item else { return }
        let r = item.row
        if old?.row.status != r.status {
            glyph.removeFromSuperview()
            glyph = SubagentStripGlyph.make(r.status)
            addSubview(glyph)
        }
        if old?.row.driver != r.driver {
            provider.removeFromSuperview()
            provider = ProviderIcon.make(driver: r.driver, displayName: item.modelName, size: 12, color: Themed.color(\.mutedForeground), model: true)
            addSubview(provider)
        }
        name.text = r.label
        title.text = r.title
        model.text = item.modelName
        alphaValue = r.finished ? 0.55 : 1
        stop.isEnabled = !item.stopping
        stop.setAccessibilityLabel("Stop \(r.label)")
        setAccessibilityLabel("\(r.label): \(r.title). \(SubagentStripGlyph.label(r.status)). Open subagent.")
        updateHover()
        needsLayout = true
    }

    private func updateHover() {
        stop.isHidden = !(hovered && item?.row.canStop == true)
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        layer?.backgroundColor = hovered ? Themed.color(\.foreground, 0.06).cgColor(in: self) : nil
    }

    override func layout() {
        super.layout()
        let h = bounds.height, mid = (h / 2).rounded()
        glyph.frame = NSRect(x: 8, y: mid - 6, width: 12, height: 12)
        var right = bounds.width - 6
        if !stop.isHidden {
            right -= 24
            stop.frame = NSRect(x: right, y: mid - 12, width: 24, height: 24)
            right -= 4
        }
        let mw = min(ceil(model.textWidth), 140)
        right -= mw
        model.frame = NSRect(x: right, y: mid - 8, width: mw, height: 16)
        right -= 4 + 12
        provider.frame = NSRect(x: right, y: mid - 6, width: 12, height: 12)
        let nw = ceil(name.textWidth)
        name.frame = NSRect(x: 28, y: mid - 8, width: nw, height: 16)
        let tx = name.frame.maxX + 6
        title.frame = NSRect(x: tx, y: mid - 8, width: max(0, right - 12 - tx), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ on: Bool) {
        guard on != hovered else { return }
        hovered = on
        updateHover()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum SubagentStripGlyph {
    /// Running spins (only while shown, `SpinnerView`); the rest are still icons.
    static func make(_ status: SubagentStrip.Status) -> NSView {
        let muted = Themed.color(\.mutedForeground)
        let v: NSView = switch status {
        case .running: SpinnerView(size: .xs, tone: .muted)
        case .waiting: IconView(name: .clock, size: 12, strokeColor: muted)
        case .needsInput: IconView(name: .messageCircleQuestion, size: 12, strokeColor: Themed.color(\.warning))
        case .done: IconView(name: .circleCheck, size: 12, strokeColor: muted)
        case .failed: IconView(name: .circleX, size: 12, strokeColor: Themed.color(\.error))
        }
        v.setAccessibilityElement(false)
        return v
    }

    static func label(_ status: SubagentStrip.Status) -> String {
        switch status {
        case .running: "Working"
        case .waiting: "Waiting"
        case .needsInput: "Needs input"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}
