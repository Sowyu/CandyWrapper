import AppKit
import DesignSystem

/// The map's frame inside the Environments card: the toolbar (:885-1000), the canvas, and the footer with the
/// legend and the zoom group (:1056-1088). It is one row of the section's group.
@MainActor
public final class EnvironmentsMapView: DSView, SettingsGroupRow {
    public let canvas = EnvironmentsMapCanvasView()
    /// `FleetDetails`, the group's next row: the selection's facts and actions.
    public let details = EnvironmentsMapDetailsView()
    private var detailsModel = EnvironmentsMapDetailsModel()
    /// T3's `lg` breakpoint, where the panel's rows show addresses.
    public var wide = false
    let search = InputGroupView(placeholder: "Find a machine", leading: .icon(.search))
    private let searchStatus = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let selectedCount = LabelView("", font: DSFont.ui(11), color: Themed.color(\.foreground))
    let clearButton = ButtonView("Clear", variant: .ghostMuted, size: .xs)
    let linkSeveral = ButtonView("Link several…", variant: .outline, size: .xs)
    let help = ButtonView(nil, variant: .ghost, size: .iconXs)
    let zoomOut = ButtonView(nil, icon: .minus, variant: .ghost, size: .iconXs)
    let zoomIn = ButtonView(nil, icon: .plus, variant: .ghost, size: .iconXs)
    let fitButton = ButtonView(nil, icon: .maximize, variant: .ghost, size: .iconXs)
    private let zoomGroup = DSView()
    private let legend = FleetLegendView()
    private let toolbarRule = DSView()
    private let footerRule = DSView()
    private var helpPopup: OpenPopup?

    /// `CodeOnlyNotice` (:1246-1290): a drop on machines this app can only link with a pairing code each.
    let codeOnly = FleetCodeOnlyNoticeView()
    private(set) var dropped: (sourceId: String, machineIds: [String])?
    /// A gesture that links: the handle pressed (target nil) or dropped, with the ticked machines.
    public var onLink: ((_ sourceId: String, _ targetId: String?, _ ticked: [String]) -> Void)?
    /// `onLinkOne` from the notice's menu: one link from the source to the machine picked.
    public var onLinkOne: ((_ sourceId: String, _ targetId: String) -> Void)?
    /// Opens the batch link flow with the ticked machines, from `sourceId` when one is chosen.
    public var onLinkSeveral: ((_ sourceId: String?, _ environmentIds: [String]) -> Void)?
    public var onHeightChange: (() -> Void)?

    /// `py-1.5` around the `h-8` field, and the `border-b`.
    static let toolbarHeight: CGFloat = 45
    static let footerHeight: CGFloat = 38

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        search.input.size = .default
        search.input.setAccessibilityLabel("Find a machine on the map")
        // Typing lights the matches; Enter goes to the first (:893-910).
        search.input.onChange = { [weak self] text in self?.canvas.state.query = text }
        search.input.onCommand = { [weak self] selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) { self.goToFirstMatch(); return true }
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if !self.search.input.text.isEmpty { self.search.input.text = ""; self.canvas.state.query = ""; return true }
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
        zoomOut.action = { [weak self] in self?.canvas.zoomGliding(0.8) }
        zoomIn.action = { [weak self] in self?.canvas.zoomGliding(1.25) }
        fitButton.action = { [weak self] in self?.canvas.fitView() }
        for v in [zoomOut, zoomIn, fitButton] { zoomGroup.addSubview(v) }
        zoomGroup.wantsLayer = true
        for v in [toolbarRule, footerRule, search, searchStatus, selectedCount, clearButton, linkSeveral, help, canvas, legend, zoomGroup] as [NSView] {
            addSubview(v)
        }
        canvas.onStateChange = { [weak self] in self?.syncToolbar() }
        canvas.onLink = { [weak self] source, target in self?.requestLink(source, target) }
        codeOnly.isHidden = true
        codeOnly.onDismiss = { [weak self] in self?.setDropped(nil) }
        codeOnly.onPick = { [weak self] id in
            guard let self, let source = self.dropped?.sourceId else { return }
            self.setDropped(nil)
            self.onLinkOne?(source, id)
        }
        addSubview(codeOnly)
        details.onSelect = { [weak self] focus in
            guard let self else { return }
            self.canvas.state.selection = focus
            self.canvas.state.found = nil
            if focus == nil { self.window?.makeFirstResponder(self.canvas) }
        }
        details.onToggleStack = { [weak self] id in self?.canvas.toggleStack(id) }
        syncToolbar()
    }

    public func set(_ model: EnvironmentsMapModel) {
        detailsModel = model.details
        canvas.set(model)
        legend.twoWay = !fleetTwoWayLinks(canvas.graph).isEmpty
        syncToolbar()
        needsLayout = true
    }

    /// `goToFirstMatch` (:771-789): select the first machine the search names and centre it at a legible scale
    /// (:157), or, folded away, select its stack with the machine as the stack list's filter.
    func goToFirstMatch() {
        guard let first = fleetSearch(canvas.graph, canvas.state.query).first else { return }
        let rects = fleetFocusRects(canvas.fleetLayout)
        if canvas.fleetLayout.nodes[first] != nil, let rect = rects[first] {
            canvas.state.selection = .node(first)
            canvas.state.found = nil
            canvas.reveal(rect, legible: true)
            return
        }
        guard let stack = canvas.stacks.first(where: { $0.memberIds.contains(first) }), let face = rects[stack.id] else { return }
        canvas.state.selection = .stack(stack.id)
        canvas.state.found = first
        canvas.reveal(face, legible: true)
    }

    /// `requestLink` (:474-497): every gesture's way in. A code-only drop shows the notice instead of a dialog.
    func requestLink(_ sourceId: String, _ targetId: String?) {
        let ticked = canvas.state.ticked.filter { canvas.graph.node($0) != nil }
        if case .codeOnly(let source, _, let ids)? = fleetLinkAction(canvas.graph, canvas.stacks, selected: ticked, sourceId: sourceId, targetId: targetId) {
            setDropped((source, ids))
            return
        }
        setDropped(nil)
        onLink?(sourceId, targetId, ticked)
    }

    func setDropped(_ next: (sourceId: String, machineIds: [String])?) {
        dropped = next
        let machines = (next?.machineIds ?? []).compactMap { canvas.graph.node($0) }
        codeOnly.isHidden = next == nil || canvas.graph.node(next!.sourceId) == nil || machines.isEmpty
        codeOnly.machines = machines.map { ($0.id, $0.label) }
        needsLayout = true
        onHeightChange?()
    }

    var noticeHeight: CGFloat { codeOnly.isHidden ? 0 : FleetCodeOnlyNoticeView.height }

    func syncDetails() {
        details.set(graph: canvas.graph, stacks: canvas.stacks, selection: canvas.state.selection, found: canvas.state.found,
                    model: detailsModel, wide: wide)
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
        syncDetails()
        needsLayout = true
        // A stack's anchoring or a fit changes the canvas height: the page lays out again.
        let height = bounds.width > 0 ? self.height(forWidth: bounds.width) : 0
        if height != lastHeight { lastHeight = height; onHeightChange?() }
    }
    private var lastHeight: CGFloat = 0

    /// "Link several…": the batch dialog from the environment in the details, or the only one that can link (:874-880).
    /// With several and none selected it is a menu of "From {source}" items (:946-968).
    func startLinkSeveral() {
        if let source = linkSeveralSource { return linkSeveral(from: source) }
        MenuPopupView.show(linkSeveralMenuItems(), from: linkSeveral,
                           placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    private var linkSources: [FleetNode] { canvas.graph.nodes.filter { $0.kind == .environment && $0.linking == .ready } }

    /// The environment in the details is the one the user means; a lone one needs no asking (:877-880).
    var linkSeveralSource: FleetNode? {
        let sources = linkSources
        return sources.first { canvas.state.selection == .node($0.id) } ?? (sources.count == 1 ? sources[0] : nil)
    }

    func linkSeveralMenuItems() -> [MenuItem] {
        linkSources.map { node in MenuItem("From \(node.label)") { [weak self] in self?.linkSeveral(from: node) } }
    }

    private func linkSeveral(from source: FleetNode) {
        let ids = canvas.state.ticked.compactMap { canvas.graph.node($0)?.environmentId }.filter { $0 != source.environmentId }
        onLinkSeveral?(source.environmentId, ids)
    }

    func showHelp() {
        // The two linking lines show only where some environment can link (:985-992).
        let canLink = !linkSeveral.isHidden
        let lines = ["Select a machine to manage it."] + (canLink ? ["Drag a plus onto a machine to link them.", "Shift-click or Shift-drag to select several"] : [])
            + ["A link reaches one machine and stops there."]
        let text = LabelView(lines.map { "• " + $0 }.joined(separator: "\n"), font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        text.lineHeight = 20
        text.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(lines.count) * 20 + 4)
        let box = DSView(frame: text.frame)
        box.addSubview(text)
        helpPopup = PopoverView(content: box).show(from: help)
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        Self.toolbarHeight + noticeHeight + canvas.wantedHeight(width) + Self.footerHeight
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
        let fieldHeight: CGFloat = 32
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
        codeOnly.frame = NSRect(x: 0, y: Self.toolbarHeight, width: w, height: noticeHeight)
        let canvasTop = Self.toolbarHeight + noticeHeight
        let canvasHeight = max(180, bounds.height - canvasTop - Self.footerHeight)
        canvas.frame = NSRect(x: 0, y: canvasTop, width: w, height: canvasHeight)
        let footerY = canvasTop + canvasHeight
        footerRule.frame = NSRect(x: 0, y: footerY, width: w, height: 1)
        // `rounded-lg border p-0.5` around three `size-6` buttons with `gap-1`.
        let groupWidth: CGFloat = 1 + 2 + 24 * 3 + 4 * 2 + 2 + 1
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

/// `CodeOnlyNotice` (:1262-1290): `role="status"`, `flex items-center gap-x-3 border-b border-border/60 bg-background/50
/// px-3 py-2 text-xs`, the count in muted text, a "Link one with a code…" menu of the machines, and Dismiss.
@MainActor
final class FleetCodeOnlyNoticeView: DSView {
    static let height: CGFloat = 8 + 24 + 8 + 1
    private let text = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let linkOne = ButtonView("Link one with a code…", variant: .outline, size: .xs).menuTrigger()
    let dismiss = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private let rule = CALayer()
    var machines: [(id: String, label: String)] = [] {
        didSet { text.text = EnvironmentsMapText.needsCode(machines.count); setAccessibilityValue(text.text) }
    }
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        text.setAccessibilityRole(.staticText)
        dismiss.setAccessibilityLabel("Dismiss")
        dismiss.action = { [weak self] in self?.onDismiss?() }
        linkOne.action = { [weak self] in
            guard let self else { return }
            let items = self.machines.map { m in MenuItem(m.label, action: { [weak self] in self?.onPick?(m.id) }) }
            MenuPopupView.show(items, from: self.linkOne, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4))
        }
        [text, linkOne, dismiss].forEach { addSubview($0) }
        layer?.addSublayer(rule)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        let redesign = RedesignMapPaint.isOn
        layer?.backgroundColor = (redesign ? NSColor.clear : Themed.color(\.background, 0.5)).cgColor(in: self)
        rule.backgroundColor = (redesign ? RedesignTokens.Card.border : Themed.color(\.border, 0.6)).cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let h = bounds.height - 1
        dismiss.frame = NSRect(x: bounds.width - 12 - 24, y: (h - 24) / 2, width: 24, height: 24)
        let s = linkOne.intrinsicContentSize
        linkOne.frame = NSRect(x: dismiss.frame.minX - 12 - s.width, y: (h - 24) / 2, width: s.width, height: 24)
        text.frame = NSRect(x: 12, y: (h - 16) / 2, width: max(0, linkOne.frame.minX - 24), height: 16)
        rule.frame = CGRect(x: 0, y: h, width: bounds.width, height: 1)
    }
}
