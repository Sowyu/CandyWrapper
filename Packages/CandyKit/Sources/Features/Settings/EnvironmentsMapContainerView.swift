import AppKit
import DesignSystem

/// The map's frame inside the Environments card: the toolbar (:885-1000), the canvas, and the footer with the
/// legend and the zoom group (:1056-1088). It is one row of the section's group.
@MainActor
public final class EnvironmentsMapView: DSView, SettingsGroupRow {
    public let canvas = EnvironmentsMapCanvasView()
    let search = InputGroupView(placeholder: "Find a machine", leading: .icon(.search))
    private let searchStatus = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let selectedCount = LabelView("", font: DSFont.ui(11), color: Themed.color(\.foreground))
    let clearButton = ButtonView("Clear", variant: .ghost, size: .micro)
    let linkSeveral = ButtonView("Link several…", variant: .outline, size: .micro)
    let help = ButtonView(nil, variant: .ghostMuted, size: .iconMicro)
    let zoomOut = ButtonView(nil, icon: .minus, variant: .ghost, size: .iconXs)
    let zoomIn = ButtonView(nil, icon: .plus, variant: .ghost, size: .iconXs)
    let fitButton = ButtonView(nil, icon: .maximize, variant: .ghost, size: .iconXs)
    private let zoomGroup = DSView()
    private let legend = FleetLegendView()
    private let toolbarRule = DSView()
    private let footerRule = DSView()
    private var helpPopup: OpenPopup?

    /// Opens the batch link flow with the ticked machines, from `sourceId` when one is chosen.
    public var onLinkSeveral: ((_ sourceId: String?, _ environmentIds: [String]) -> Void)?
    public var onHeightChange: (() -> Void)?

    static let toolbarHeight: CGFloat = 41
    static let footerHeight: CGFloat = 38

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        search.input.size = .sm
        search.input.setAccessibilityLabel("Find a machine on the map")
        search.input.onChange = { [weak self] text in self?.find(text) }
        search.input.onCommand = { [weak self] selector in
            guard let self, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if !self.search.input.text.isEmpty { self.search.input.text = ""; self.find(""); return true }
            return false
        }
        searchStatus.setAccessibilityRole(.staticText)
        clearButton.action = { [weak self] in self?.canvas.state.ticked = [] }
        linkSeveral.action = { [weak self] in self?.startLinkSeveral() }
        help.iconDefinition = EnvironmentsMapIcons.help
        help.setAccessibilityLabel("How to use the map")
        help.action = { [weak self] in self?.showHelp() }
        TooltipController.attach(to: linkSeveral, text: "Shift-click or Shift-drag to select several")
        for (button, label) in [(zoomOut, "Zoom out"), (zoomIn, "Zoom in"), (fitButton, "Fit the map to view")] {
            button.setAccessibilityLabel(label)
            TooltipController.attach(to: button, text: label)
        }
        zoomOut.action = { [weak self] in self?.canvas.zoom(0.8) }
        zoomIn.action = { [weak self] in self?.canvas.zoom(1.25) }
        fitButton.action = { [weak self] in self?.canvas.fitView() }
        for v in [zoomOut, zoomIn, fitButton] { zoomGroup.addSubview(v) }
        zoomGroup.wantsLayer = true
        for v in [toolbarRule, footerRule, search, searchStatus, selectedCount, clearButton, linkSeveral, help, canvas, legend, zoomGroup] as [NSView] {
            addSubview(v)
        }
        canvas.onStateChange = { [weak self] in self?.syncToolbar() }
        syncToolbar()
    }

    public func set(_ model: EnvironmentsMapModel) {
        canvas.set(model)
        legend.twoWay = !fleetTwoWayLinks(canvas.graph).isEmpty
        syncToolbar()
        needsLayout = true
    }

    /// Search lights the machines it names and centres the first at a legible scale (:157, :896-918).
    func find(_ text: String) {
        canvas.state.query = text
        let found = fleetSearch(canvas.graph, text)
        if let first = found.first {
            let rects = fleetFocusRects(canvas.fleetLayout)
            let stack = canvas.stacks.first { $0.memberIds.contains(first) && canvas.fleetLayout.nodes[first] == nil }
            if let rect = rects[first] ?? stack.flatMap({ rects[$0.id] }) { canvas.reveal(rect, legible: true) }
        }
        syncToolbar()
    }

    func syncToolbar() {
        let query = canvas.state.query.trimmingCharacters(in: .whitespaces)
        searchStatus.text = query.isEmpty ? "" : EnvironmentsMapText.matches(fleetSearch(canvas.graph, query).count)
        let ticked = canvas.state.ticked.count
        selectedCount.text = "\(ticked) selected"
        selectedCount.isHidden = ticked == 0
        clearButton.isHidden = ticked == 0
        let sources = canvas.graph.nodes.filter { $0.kind == .environment && $0.linking == .ready }
        linkSeveral.isHidden = sources.isEmpty
        fitButton.isEnabled = canvas.state.held != nil
        needsLayout = true
    }

    /// "Link several…": the batch dialog from the environment in the details, or the only one that can link (:870-882).
    func startLinkSeveral() {
        let sources = canvas.graph.nodes.filter { $0.kind == .environment && $0.linking == .ready }
        var source = sources.first { canvas.state.selection == .node($0.id) }
        if source == nil, sources.count == 1 { source = sources[0] }
        let ids = canvas.state.ticked.compactMap { canvas.graph.node($0)?.environmentId }.filter { $0 != source?.environmentId }
        onLinkSeveral?(source?.environmentId, ids)
    }

    func showHelp() {
        let text = LabelView("• Select a machine to manage it.\n• Drag a plus onto a machine to link them.\n• A link reaches one machine and stops there.",
                             font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        text.lineHeight = 20
        text.frame = NSRect(x: 0, y: 0, width: 260, height: 64)
        let box = DSView(frame: text.frame)
        box.addSubview(text)
        helpPopup = PopoverView(content: box).show(from: help)
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        Self.toolbarHeight + canvas.wantedHeight(width) + Self.footerHeight
    }

    public override func updateLayer() {
        toolbarRule.layer?.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        footerRule.layer?.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        let redesign = RedesignMapPaint.isOn
        zoomGroup.layer?.cornerRadius = redesign ? RedesignTokens.Radius.card : 8
        zoomGroup.layer?.borderWidth = 1
        zoomGroup.layer?.borderColor = (redesign ? RedesignTokens.Card.border : Themed.color(\.border, 0.6)).cgColor(in: self)
        zoomGroup.layer?.backgroundColor = (redesign ? RedesignTokens.Card.fill : Themed.color(\.popover, 0.9)).cgColor(in: self)
        layer?.backgroundColor = (redesign ? NSColor.clear : Themed.color(\.background, 0.5)).cgColor(in: self)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        toolbarRule.frame = NSRect(x: 0, y: Self.toolbarHeight - 1, width: w, height: 1)
        // `flex flex-wrap items-center gap-x-3 px-3 py-1.5`, the field `w-48`.
        let fieldHeight: CGFloat = 28
        search.frame = NSRect(x: 12, y: (Self.toolbarHeight - 1 - fieldHeight) / 2, width: 192, height: fieldHeight)
        var right = w - 12
        for v in [help, linkSeveral, clearButton] as [NSView] where !v.isHidden {
            let s = v.intrinsicContentSize
            v.frame = NSRect(x: right - s.width, y: (Self.toolbarHeight - 1 - s.height) / 2, width: s.width, height: s.height)
            right = v.frame.minX - 8
        }
        if !selectedCount.isHidden {
            let sw = selectedCount.intrinsicContentSize.width
            selectedCount.frame = NSRect(x: right - sw, y: (Self.toolbarHeight - 1 - 16) / 2, width: sw, height: 16)
            right = selectedCount.frame.minX - 8
        }
        searchStatus.frame = NSRect(x: search.frame.maxX + 12, y: (Self.toolbarHeight - 1 - 16) / 2, width: max(0, right - search.frame.maxX - 12), height: 16)
        let canvasHeight = max(180, bounds.height - Self.toolbarHeight - Self.footerHeight)
        canvas.frame = NSRect(x: 0, y: Self.toolbarHeight, width: w, height: canvasHeight)
        let footerY = Self.toolbarHeight + canvasHeight
        footerRule.frame = NSRect(x: 0, y: footerY, width: w, height: 1)
        // `rounded-lg border p-0.5` around three `size-6` buttons with `gap-1`.
        let groupWidth: CGFloat = 2 + 2 + 24 * 3 + 4 * 2 + 2 + 2
        zoomGroup.frame = NSRect(x: w - 12 - groupWidth, y: footerY + (Self.footerHeight - 30) / 2, width: groupWidth, height: 30)
        for (i, b) in [zoomOut, zoomIn, fitButton].enumerated() { b.frame = NSRect(x: 3 + CGFloat(i) * 28, y: 3, width: 24, height: 24) }
        legend.frame = NSRect(x: 12, y: footerY + (Self.footerHeight - 16) / 2, width: max(0, zoomGroup.frame.minX - 24), height: 16)
    }
}

/// `FleetLegend` (:1091-1137): how the lines read.
final class FleetLegendView: DSView {
    var twoWay = false { didSet { if twoWay != oldValue { needsDisplay = true; rebuildAccessibility() } } }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("How to read the lines")
        rebuildAccessibility()
    }

    var items: [String] { ["In use", "Standby", "Offline", "Link"] + (twoWay ? ["Two-way"] : []) }

    func rebuildAccessibility() {
        setAccessibilityChildren(items.map { item in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.staticText)
            e.setAccessibilityLabel(item)
            e.setAccessibilityParent(self)
            return e
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let paint = FleetPaint.current
        let font = DSFont.ui(11)
        let muted = paint.muted
        var x: CGFloat = 0
        let mid = bounds.midY
        func label(_ s: String) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: muted])
            let size = a.size()
            a.draw(at: NSPoint(x: x, y: mid - size.height / 2))
            x += size.width + 12
        }
        func sample(_ color: NSColor, _ width: CGFloat, _ dash: [CGFloat]) {
            cg.setStrokeColor(color.cgColor(in: self)); cg.setLineWidth(width + 0.25); cg.setLineDash(phase: 0, lengths: dash)
            cg.move(to: CGPoint(x: x, y: mid)); cg.addLine(to: CGPoint(x: x + 18, y: mid)); cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
            x += 18 + 6
        }
        sample(paint.inUse, 1.75, []); label("In use")
        sample(muted.withAlphaComponent(0.6), 1, []); label("Standby")
        sample(muted.withAlphaComponent(0.6), 1, [4, 4]); label("Offline")
        let ink = paint.foreground.withAlphaComponent(0.7).cgColor(in: self)
        cg.setFillColor(ink)
        // `M0 3L22 0.5V5.5Z` in a 22 by 6 box.
        cg.move(to: CGPoint(x: x, y: mid)); cg.addLine(to: CGPoint(x: x + 22, y: mid - 2.5)); cg.addLine(to: CGPoint(x: x + 22, y: mid + 2.5)); cg.closePath(); cg.fillPath()
        x += 22 + 6
        label("Link")
        if twoWay {
            cg.setStrokeColor(ink); cg.setLineWidth(1.75)
            cg.move(to: CGPoint(x: x + 5, y: mid)); cg.addLine(to: CGPoint(x: x + 17, y: mid)); cg.strokePath()
            cg.move(to: CGPoint(x: x, y: mid)); cg.addLine(to: CGPoint(x: x + 6, y: mid - 3.5)); cg.addLine(to: CGPoint(x: x + 6, y: mid + 3.5)); cg.closePath()
            cg.move(to: CGPoint(x: x + 22, y: mid)); cg.addLine(to: CGPoint(x: x + 16, y: mid - 3.5)); cg.addLine(to: CGPoint(x: x + 16, y: mid + 3.5)); cg.closePath()
            cg.fillPath()
            x += 22 + 6
            label("Two-way")
        }
    }
}
