import AppKit
import DesignSystem
import T3Protocol

// The map's details panel (T3 5258 components/settings/EnvironmentsMapDetails.tsx): what is selected on the map,
// with the controls the list keeps on each row. Line numbers cite that file unless they name another one.
// Every block is a plain subview rebuilt when the selection or the graph changes, so the panel costs nothing idle.

/// What the panel needs beyond the graph: the app's words for each saved environment and the primary's row.
public struct EnvironmentsMapDetailsModel: Equatable {
    /// `savedBackendStatus(environment).text` per environment id, for Reconnect and the stack lists.
    public var statusText: [String: String] = [:]
    /// The primary environment's `EnvironmentRow` (:805-820): machine kind and `transport · status · version`.
    public struct PrimaryRow: Equatable {
        public var environmentId: String
        public var label: String
        public var machine: String
        public var subtitle: String
        public init(environmentId: String, label: String, machine: String, subtitle: String) {
            self.environmentId = environmentId; self.label = label; self.machine = machine; self.subtitle = subtitle
        }
    }
    public var primary: PrimaryRow?
    /// `connectProblem.message`: why the account's T3 Connect machines are missing.
    public var connectProblem: String?
    /// Links being forgotten, `<host environment id>/<linked environment id>`.
    public var forgetting: Set<String> = []
    public init() {}
}

/// What the panel's controls do. Node ids are the graph's (`env:<environmentId>`).
@MainActor
public struct EnvironmentsMapDetailsActions {
    /// The list's own row for a saved environment, or nil where the list has none (`renderSavedEnvironment`).
    public var savedRow: (String) -> (any SettingsGroupRow)? = { _ in nil }
    /// `CloudRemoteEnvironmentRows only={id}` (`renderConnectMachine`).
    public var connectRow: (String) -> (any SettingsGroupRow)? = { _ in nil }
    /// `onLinkFrom`: the link flow from an environment node with no target picked.
    public var linkFrom: (String) -> Void = { _ in }
    /// `onLinkBack`: one link from the edge's target back to its source (`requestOneLink(edge.to, edge.from)`).
    public var linkBack: (_ sourceNodeId: String, _ targetNodeId: String) -> Void = { _, _ in }
    /// "Forget": (host environment id, linked environment id).
    public var forget: (String, String) -> Void = { _, _ in }
    /// "Reconnect" (`environmentCatalog.retryNow`).
    public var reconnect: (String) -> Void = { _ in }
    /// "Add environment" with the address the link knows, if any.
    public var addEnvironment: (String?) -> Void = { _ in }
    /// The T3 Connect problem's "Try again".
    public var retryConnect: () -> Void = {}
    public init() {}
}

/// `formatAccessTimestamp` (ConnectionsSettings.logic.ts:175-186): `Intl.DateTimeFormat` medium date, short time.
enum FleetTimestamp {
    @MainActor static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @MainActor static func format(_ iso: String) -> String {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return iso }
        // ICU joins a medium date and a short time with ", " in en; Foundation's glue says " at ".
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)).replacingOccurrences(of: " at ", with: ", ")
    }
}

/// Words only the panel uses.
enum FleetDetailsText {
    static func plural(_ n: Int, _ one: String, _ other: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(other)" }

    /// `FleetSummary` (:239-273).
    static func summary(_ graph: FleetGraph) -> (title: String, detail: String?) {
        let s = fleetSummary(graph)
        let machines = plural(s.machines, "machine", "machines")
        let title = s.links.map { "\(machines), \($0 == 0 ? "no links" : plural($0, "link", "links"))" } ?? machines
        let attention = graph.links.filter { $0.health.map(linkNeedsAttention) ?? false }.count
        let detail = s.loading ? "Loading links…" : attention > 0 ? (attention == 1 ? "1 needs attention" : "\(attention) need attention") : nil
        return (title, detail)
    }

    /// `linksNote` (:629-651).
    static func linksNote(_ node: FleetNode) -> String? {
        if node.phase != .connected { return "Not connected, so its links are not shown." }
        switch node.outgoing {
        case "off": return "To link from \(node.label), turn on Linked environments in its Labs settings."
        case "unknown": return "This app may not read the links \(node.label) holds."
        case "error": return "Could not load the links \(node.label) holds: \(node.outgoingError ?? "")"
        case "loading": return "Loading linked environments…"
        default: return nil
        }
    }

    static func linksTo(_ n: Int) -> String { n == 0 ? "Links to no one" : n == 1 ? "Links to 1 machine" : "Links to \(n) machines" }
    static func linkedFrom(_ n: Int) -> String {
        n == 0 ? "No known machine links here" : n == 1 ? "Linked from 1 machine" : "Linked from \(n) machines"
    }
}

// MARK: - The panel

/// `FleetDetails` (:137-232): a `group` named "Details", `min-h-20 border-t border-border/60 text-xs`. Esc inside
/// it clears the selection without closing Settings.
@MainActor
public final class EnvironmentsMapDetailsView: DSView, SettingsGroupRow {
    public var actions = EnvironmentsMapDetailsActions()
    /// Selecting inside the panel; the map follows.
    public var onSelect: ((FleetFocus?) -> Void)?
    /// `onToggleStack`.
    public var onToggleStack: ((String) -> Void)?
    public var onHeightChange: (() -> Void)?

    private(set) var graph = FleetGraph(nodes: [], edges: [])
    private(set) var stacks: [FleetStack] = []
    private(set) var selection: FleetFocus?
    private var found: String?
    private var model = EnvironmentsMapDetailsModel()
    private var wide = false
    /// The blocks top to bottom; `ruled` draws `border-t border-border/60` above a block.
    private var blocks: [(view: any SettingsGroupRow, ruled: Bool)] = []
    private var rules: [CALayer] = []
    private var stackQuery = ""
    private var stackQueryFor: String?

    public override var acceptsFirstResponder: Bool { true }
    public override var focusRingType: NSFocusRingType { get { .none } set {} }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Details")
    }

    public func set(graph: FleetGraph, stacks: [FleetStack], selection: FleetFocus?, found: String?,
                    model: EnvironmentsMapDetailsModel, wide: Bool) {
        let changed = graph != self.graph || stacks != self.stacks || selection != self.selection || found != self.found
            || model != self.model || wide != self.wide
        if selection != self.selection || found != self.found {
            // `key={`${stack.id}:${found}`}`: a new stack or a new find starts the filter over, narrowed to the find.
            stackQuery = found.flatMap { graph.node($0)?.label } ?? ""
            stackQueryFor = nil
        }
        self.graph = graph; self.stacks = stacks; self.selection = selection; self.found = found; self.model = model; self.wide = wide
        if changed { rebuild() }
    }

    func labelOf(_ id: String) -> String { graph.node(id)?.label ?? "" }

    func rebuild() {
        blocks.forEach { $0.view.removeFromSuperview() }
        blocks = []
        let links = graph.links
        var list: [(any SettingsGroupRow, Bool)] = []
        if let problem = model.connectProblem {
            list.append((FleetConnectProblemView(message: problem, retry: actions.retryConnect), false))
        }
        let pairs = fleetTwoWayLinks(graph)
        switch selection {
        case .edge(let id)?:
            if let pair = pairs[id] {
                let section = FleetSectionView()
                section.add(FleetTextBlock("Two links, one each way.", muted: true), gap: 0)
                for (i, link) in [pair.forward, pair.back].enumerated() { section.add(linkDetails(link), gap: i == 0 ? 12 : 16) }
                list.append((section, false))
            } else if let edge = links.first(where: { $0.id == id }) {
                let section = FleetSectionView()
                section.add(linkDetails(edge), gap: 0)
                list.append((section, false))
            } else { list.append(summarySection()) }
        case .stack(let id)?:
            if let stack = stacks.first(where: { $0.id == id }) { list.append((stackSection(stack, links), false)) } else { list.append(summarySection()) }
        case .node(let id)?:
            if let node = graph.node(id) { list += nodeBlocks(node, links) } else { list.append(summarySection()) }
        case nil:
            list.append(summarySection())
        }
        blocks = list.map { (view: $0.0, ruled: $0.1) }
        blocks.forEach { addSubview($0.view) }
        needsLayout = true
        onHeightChange?()
    }

    private func summarySection() -> (any SettingsGroupRow, Bool) {
        let section = FleetSectionView()
        let s = FleetDetailsText.summary(graph)
        section.add(FleetHeadingView(s.title, detail: s.detail), gap: 0)
        return (section, false)
    }

    private func select(_ focus: FleetFocus) {
        onSelect?(focus)
        // Choosing inside the panel replaces the control that was pressed, so focus stays on the panel.
        window?.makeFirstResponder(self)
    }

    // MARK: Nodes (:653-833)

    private func nodeBlocks(_ node: FleetNode, _ links: [FleetEdge]) -> [(any SettingsGroupRow, Bool)] {
        let incoming = links.filter { $0.to == node.id }
        let linkedFrom = { [unowned self] in
            FleetLinkListView(title: FleetDetailsText.linkedFrom(incoming.count), action: nil,
                              rows: incoming.map { self.linkRow($0, label: self.labelOf($0.from)) })
        }
        switch node.kind {
        case .client:
            let hosts = graph.nodes.filter { $0.kind == .environment }
            let section = FleetSectionView()
            section.add(FleetHeadingView(node.label, detail: "\(hosts.filter { $0.phase == .connected }.count) of \(hosts.count) connected"), gap: 0)
            section.add(FleetTextBlock("Each line from here is a saved route to an environment.", muted: true), gap: 0)
            return [(section, false)]
        case .connect:
            var out: [(any SettingsGroupRow, Bool)] = []
            if let row = actions.connectRow(node.environmentId) { out.append((row, false)) }
            let section = FleetSectionView()
            section.add(FleetTextBlock("Add \(node.label) to this app to connect to it.", muted: true), gap: 0)
            if !incoming.isEmpty { section.add(linkedFrom(), gap: 12) }
            out.append((section, !out.isEmpty))
            return out
        case .target:
            let section = FleetSectionView()
            let add = ButtonView("Add environment", icon: .plus, variant: .outline, size: .xs)
            add.iconSize = 12
            let address = node.address
            add.action = { [weak self] in self?.actions.addEnvironment(address) }
            section.add(FleetHeadingView(node.label, detail: "Known only through a link", buttons: [add]), gap: 0)
            // A machine known only through its links is its links, so each one is shown in full.
            for (i, edge) in incoming.enumerated() { section.add(linkDetails(edge), gap: i == 0 ? 0 : 16) }
            section.add(FleetTextBlock("Not connected, so its links are not shown.", muted: true), gap: 12)
            return [(section, false)]
        case .environment:
            var out: [(any SettingsGroupRow, Bool)] = []
            let saved = actions.savedRow(node.environmentId)
            if let saved { out.append((saved, false)) } else if let p = model.primary, p.environmentId == node.environmentId {
                out.append((FleetEnvironmentRowView(p), false))
            }
            let section = FleetSectionView()
            var gap: CGFloat = 0
            if saved != nil, node.enabled, node.phase != .connected, node.phase != .unsupported {
                section.add(FleetReconnectView(status: model.statusText[node.environmentId] ?? "", enabled: node.phase != .connecting) {
                    [weak self] in self?.actions.reconnect(node.environmentId)
                }, gap: 0)
                gap = 12
            }
            if let note = FleetDetailsText.linksNote(node) { section.add(FleetTextBlock(note, muted: true), gap: gap); gap = 12 }
            let out2 = links.filter { $0.from == node.id }
            var link: ButtonView?
            if node.linking == .ready {
                let b = ButtonView("Link", icon: .plus, variant: .default, size: .xs)
                b.iconSize = 12
                let id = node.id
                b.action = { [weak self] in self?.actions.linkFrom(id) }
                link = b
            }
            section.add(FleetLinkListView(title: node.outgoing == "loaded" ? FleetDetailsText.linksTo(out2.count) : nil, action: link,
                                          rows: out2.map { linkRow($0, label: labelOf($0.to)) }), gap: gap)
            section.add(linkedFrom(), gap: 12)
            out.append((section, !out.isEmpty))
            return out
        }
    }

    private func linkRow(_ edge: FleetEdge, label: String) -> FleetLinkRowButton {
        let row = FleetLinkRowButton(edge: edge, label: label, wide: wide)
        let id = edge.id
        row.action = { [weak self] in self?.select(.edge(id)) }
        return row
    }

    private func linkDetails(_ edge: FleetEdge) -> FleetLinkDetailsView {
        let key = "\(edge.sourceEnvironmentId)/\(edge.link?.environmentId ?? "")"
        let canUnlink = graph.node(edge.from)?.canWriteAccess == true
        let view = FleetLinkDetailsView(edge: edge, source: labelOf(edge.from), target: labelOf(edge.to),
                                        linkBack: fleetLinkBackOffered(graph, edge), canForget: canUnlink,
                                        forgetting: model.forgetting.contains(key))
        view.onEndpoint = { [weak self] id in self?.select(.node(id)) }
        view.onLinkBack = { [weak self] in self?.actions.linkBack(edge.to, edge.from) }
        let host = edge.sourceEnvironmentId, peer = edge.link?.environmentId ?? ""
        view.onForget = { [weak self] in self?.actions.forget(host, peer) }
        return view
    }

    // MARK: Stacks (:289-479)

    private func stackSection(_ stack: FleetStack, _ links: [FleetEdge]) -> FleetSectionView {
        let section = FleetSectionView()
        let members = FleetStackMember.members(stack, graph, links, statusText: model.statusText)
        let range = stack.firstLabel == stack.lastLabel ? stack.firstLabel : "\(stack.firstLabel) … \(stack.lastLabel)"
        var detail: [String]
        if stack.kind == .environments {
            detail = [FleetDetailsText.plural(members.count, "environment", "environments"), "No links"]
        } else {
            detail = [FleetDetailsText.plural(members.count, "machine", "machines"), stack.sources.map { labelOf($0.sourceId) }.joined(separator: ", ")]
            if stack.sources.count == 1, let only = stack.sources.first { detail.append(LinkAccess.label(only.access)) }
            detail.append(stack.reachable == 0 ? "None reachable" : "\(stack.reachable) reachable")
        }
        let toggle = ButtonView(stack.expanded ? "Collapse" : "Show on map", variant: .outline, size: .xs)
        let id = stack.id
        toggle.action = { [weak self] in self?.onToggleStack?(id) }
        section.add(FleetHeadingView(range, detail: detail.joined(separator: " · "), buttons: [toggle]), gap: 0)
        let list = FleetMemberListView(members: members, query: stackQuery, wide: wide)
        list.onSelect = { [weak self] id in self?.select(.node(id)) }
        list.onQuery = { [weak self, weak list] q in
            self?.stackQuery = q
            list?.needsLayout = true
            self?.needsLayout = true
            self?.onHeightChange?()
        }
        section.add(list, gap: 0)
        return section
    }

    // MARK: Layout

    public func height(forWidth width: CGFloat) -> CGFloat {
        max(80, blocks.reduce(0) { $0 + $1.view.height(forWidth: width) + ($1.ruled ? 1 : 0) })
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        var used = 0
        for block in blocks {
            if block.ruled {
                if used == rules.count { let l = CALayer(); layer?.addSublayer(l); rules.append(l) }
                rules[used].frame = CGRect(x: 0, y: y, width: bounds.width, height: 1)
                used += 1
                y += 1
            }
            let h = block.view.height(forWidth: bounds.width)
            block.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
        while rules.count > used { rules.removeLast().removeFromSuperlayer() }
        updateLayer()
    }

    public override func updateLayer() {
        let color = (RedesignMapPaint.isOn ? RedesignTokens.Card.border : Themed.color(\.border, 0.6)).cgColor(in: self)
        rules.forEach { $0.backgroundColor = color }
    }

    public override func keyDown(with event: NSEvent) {
        // Base UI's dialog closes on a document Esc listener; the panel's own Esc only clears the selection.
        if event.keyCode == 53, selection != nil { onSelect?(nil); return }
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        if selection != nil { onSelect?(nil) } else { super.cancelOperation(sender) }
    }
}

// MARK: - Blocks

/// `SECTION`, `px-3 py-3 sm:px-4`: children stacked with the gap each asks for.
@MainActor
final class FleetSectionView: DSView, SettingsGroupRow {
    private var items: [(view: any SettingsGroupRow, gap: CGFloat)] = []
    static let inset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

    func add(_ view: any SettingsGroupRow, gap: CGFloat) {
        items.append((view, gap))
        addSubview(view)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - Self.inset.left - Self.inset.right
        return Self.inset.top + Self.inset.bottom + items.reduce(0) { $0 + $1.gap + $1.view.height(forWidth: inner) }
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - Self.inset.left - Self.inset.right
        var y = Self.inset.top
        for item in items {
            y += item.gap
            let h = item.view.height(forWidth: inner)
            item.view.frame = NSRect(x: Self.inset.left, y: y, width: inner, height: h)
            y += h
        }
    }
}

/// A paragraph in `text-xs`, `max-w-2xl`.
@MainActor
final class FleetTextBlock: DSView, SettingsGroupRow {
    let text: TextBlockView
    init(_ string: String, muted: Bool, font: NSFont = DSFont.ui(12), lineHeight: CGFloat = 16) {
        text = TextBlockView(string, font: font, lineHeight: lineHeight, color: Themed.color(muted ? \.mutedForeground : \.foreground))
        super.init(frame: .zero)
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: min(width, 672)) }
    override func layout() { super.layout(); text.frame = NSRect(x: 0, y: 0, width: min(bounds.width, 672), height: bounds.height) }
}

/// `Heading` (:234-242): `mb-2 flex flex-wrap items-baseline gap-x-2 gap-y-0.5`, an `h3 text-sm font-medium` and the
/// detail in `text-muted-foreground`; with buttons, `flex flex-wrap items-start justify-between gap-2` around it.
@MainActor
final class FleetHeadingView: DSView, SettingsGroupRow {
    let title: LabelView
    let detail: TextBlockView?
    let buttons: [ButtonView]

    init(_ title: String, detail: String?, buttons: [ButtonView] = []) {
        self.title = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        self.title.lineHeight = 20
        self.detail = detail.map { TextBlockView($0, font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground)) }
        self.buttons = buttons
        super.init(frame: .zero)
        self.title.setAccessibilityRole(.staticText)
        self.title.setAccessibilityLabel(title)
        addSubview(self.title)
        if let d = self.detail { addSubview(d) }
        buttons.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var buttonsWidth: CGFloat { buttons.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(0, buttons.count - 1)) * 8 }

    /// The heading's frames at `width`, `mb-2` included.
    func frames(_ width: CGFloat) -> (title: NSRect, detail: NSRect?, height: CGFloat) {
        let room = buttons.isEmpty ? width : max(0, width - buttonsWidth - 8)
        let titleWidth = min(room, ceil(title.textWidth))
        let titleRect = NSRect(x: 0, y: 0, width: titleWidth, height: 20)
        var detailRect: NSRect?
        var h: CGFloat = 20
        if let d = detail {
            let natural = ceil(d.naturalWidth)
            if titleWidth + 8 + natural <= room {
                // Baselines line up: 14/20 puts it 15 down, 12/16 puts it 12 down.
                detailRect = NSRect(x: titleWidth + 8, y: 3, width: natural, height: 16)
            } else {
                let dh = d.height(forWidth: room)
                detailRect = NSRect(x: 0, y: 22, width: room, height: dh)
                h = 22 + dh
            }
        }
        let buttonHeight = buttons.map(\.intrinsicContentSize.height).max() ?? 0
        return (titleRect, detailRect, max(h, buttonHeight) + 8)
    }

    func height(forWidth width: CGFloat) -> CGFloat { frames(width).height }

    override func layout() {
        super.layout()
        let f = frames(bounds.width)
        title.frame = f.title
        if let d = detail, let r = f.detail { d.frame = r }
        var x = bounds.width
        for b in buttons.reversed() {
            let s = b.intrinsicContentSize
            x -= s.width
            b.frame = NSRect(x: x, y: 0, width: s.width, height: s.height)
            x -= 8
        }
    }
}

/// The primary's `EnvironmentRow` (EnvironmentRow.tsx:75-115): `grid grid-cols-[auto_minmax(0,1fr)_auto] gap-x-3
/// px-3 py-2.5 sm:px-4`, a `size-4` muted machine glyph, the label in `text-sm font-medium`, the subtitle in `text-xs`.
@MainActor
final class FleetEnvironmentRowView: DSView, SettingsGroupRow {
    private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let subtitle = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))

    init(_ row: EnvironmentsMapDetailsModel.PrimaryRow) {
        super.init(frame: .zero)
        glyph.kind = row.machine
        glyph.color = Themed.color(\.mutedForeground)
        label.text = row.label
        label.lineHeight = 20
        subtitle.text = row.subtitle
        subtitle.lineHeight = 16
        [glyph, label, subtitle].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 10 + 20 + 16 + 10 }
    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 44, y: 10, width: max(0, bounds.width - 60), height: 20)
        subtitle.frame = NSRect(x: 44, y: 30, width: max(0, bounds.width - 60), height: 16)
    }
}

/// `Reconnect` (:604-627): the status in muted text and an outline `Reconnect`, `flex flex-wrap items-center gap-2`.
@MainActor
final class FleetReconnectView: DSView, SettingsGroupRow {
    let status: LabelView
    let button = ButtonView("Reconnect", variant: .outline, size: .xs)
    private let handler: () -> Void
    init(status: String, enabled: Bool, action: @escaping () -> Void) {
        self.status = LabelView(status, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        handler = action
        super.init(frame: .zero)
        button.isEnabled = enabled
        button.action = { [weak self] in self?.handler() }
        addSubview(self.status)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 24 }
    override func layout() {
        super.layout()
        let w = min(ceil(status.textWidth), max(0, bounds.width - button.intrinsicContentSize.width - 8))
        status.frame = NSRect(x: 0, y: 4, width: w, height: 16)
        button.frame = NSRect(x: status.text.isEmpty ? 0 : w + 8, y: 0, width: button.intrinsicContentSize.width, height: 24)
    }
}

/// The T3 Connect problem (:162-174): `flex flex-wrap items-center gap-x-3 border-b border-border/60 px-3 py-2
/// sm:px-4`, "Could not load T3 Connect environments" in `font-medium text-destructive`, the message, "Try again".
@MainActor
final class FleetConnectProblemView: DSView, SettingsGroupRow {
    let text: TextBlockView
    let retry = ButtonView("Try again", variant: .outline, size: .xs)
    private let rule = CALayer()
    private let handler: () -> Void
    init(message: String, retry action: @escaping () -> Void) {
        handler = action
        text = TextBlockView("Could not load T3 Connect environments \(message)", font: DSFont.ui(12), lineHeight: 16,
                             color: Themed.color(\.mutedForeground))
        text.boldPrefix = "Could not load T3 Connect environments"
        text.boldColor = Themed.color(\.destructive)
        super.init(frame: .zero)
        retry.action = { [weak self] in self?.handler() }
        addSubview(text)
        addSubview(retry)
        wantsLayer = true
        layer?.addSublayer(rule)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat {
        let room = width - 32 - retry.intrinsicContentSize.width - 12
        return max(24, text.height(forWidth: room)) + 16 + 1
    }
    override func layout() {
        super.layout()
        let bw = retry.intrinsicContentSize.width
        let room = bounds.width - 32 - bw - 12
        let th = text.height(forWidth: room)
        let h = bounds.height - 1
        text.frame = NSRect(x: 16, y: (h - th) / 2, width: room, height: th)
        retry.frame = NSRect(x: bounds.width - 16 - bw, y: (h - 24) / 2, width: bw, height: 24)
        rule.frame = CGRect(x: 0, y: h, width: bounds.width, height: 1)
        rule.backgroundColor = (RedesignMapPaint.isOn ? RedesignTokens.Card.border : Themed.color(\.border, 0.6)).cgColor(in: self)
    }
}

// MARK: - Glyphs

/// `AccessMeter` (:73-96) and `HealthGlyph` (:98-114), drawn the way the map draws them.
@MainActor
enum FleetGlyphs {
    static func accessMeter(_ access: String, at origin: CGPoint, color: CGColor, in cg: CGContext) {
        let level = FleetAccessStroke.level(access)
        for index in 0..<5 {
            let r = CGRect(x: origin.x + CGFloat(index) * 4, y: origin.y + 8 - CGFloat(index) * 2, width: 3, height: 4 + CGFloat(index) * 2)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
            cg.setFillColor(color.copy(alpha: color.alpha * (index <= level ? 1 : 0.22)) ?? color)
            cg.fillPath()
        }
    }

    /// `healthTone`: trouble in its color, a healthy link neutral.
    static func tone(_ health: PeerLinkHealth) -> NSColor {
        switch health {
        case .expired, .failing: Themed.color(\.destructive)
        case .unreachable: Themed.color(\.mutedForeground)
        case .reachable(nil): Themed.color(\.foreground, 0.7)
        case .reachable: Themed.color(\.warning)
        }
    }

    /// A `size-3` glyph centred on `center`.
    static func health(_ health: PeerLinkHealth, center: CGPoint, in cg: CGContext, view: NSView) {
        let icon = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        let tone = Self.tone(health).cgColor(in: view)
        switch health {
        case .expired: fleetDrawIcon(IconName.x.definition, in: icon, color: tone, context: cg)
        case .failing: fleetDrawIcon(IconName.triangleAlert.definition, in: icon, color: tone, context: cg)
        case .unreachable:
            cg.setStrokeColor(Themed.color(\.mutedForeground).cgColor(in: view)); cg.setLineWidth(1)
            cg.strokeEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        case .reachable(nil):
            cg.setFillColor(Themed.color(\.success).cgColor(in: view)); cg.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        case .reachable: fleetDrawIcon(EnvironmentsMapIcons.clockAlert, in: icon, color: tone, context: cg)
        }
    }
}

/// A row the panel draws itself: hover `bg-accent rounded-md`, `focus-visible:ring-2 ring-inset`, Redesign's hover
/// fill and control corner under Redesign.
@MainActor
class FleetRowControl: ControlView {
    override var wantsUpdateLayer: Bool { false }
    var redesign: Bool { RedesignMapPaint.isOn }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    func drawBackground(_ cg: CGContext) {
        let radius = redesign ? RedesignTokens.Radius.control : 6
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if state.hovered || state.active {
            let fill = redesign ? Themed.color(\.foreground, Double(state.active ? RedesignTokens.State.pressed : RedesignTokens.State.hover))
                : Themed.color(\.accent)
            cg.addPath(path); cg.setFillColor(fill.cgColor(in: self)); cg.fillPath()
        }
        if state.focusVisible {
            let inset = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil)
            cg.addPath(inset); cg.setLineWidth(2); cg.setStrokeColor(Themed.color(\.ring).cgColor(in: self)); cg.strokePath()
        }
    }

    func drawText(_ s: String, in rect: CGRect, font: NSFont, color: NSColor) {
        guard rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let h = a.size().height
        a.draw(with: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// `LinkButton` (:276-321): `grid grid-cols-[auto_minmax(0,1fr)_minmax(0,1fr)_auto] gap-x-3 px-1.5 py-1`, at lg
/// `[auto_minmax(0,10rem)_minmax(0,10rem)_minmax(0,1fr)_auto]` with the first address in `font-mono text-2xs`.
@MainActor
final class FleetLinkRowButton: FleetRowControl, SettingsGroupRow {
    let edge: FleetEdge
    let label: String
    let wide: Bool

    init(edge: FleetEdge, label: String, wide: Bool) {
        self.edge = edge; self.label = label; self.wide = wide
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    var attention: Bool { edge.health.map(linkNeedsAttention) ?? false }
    var trailing: String {
        guard let health = edge.health else { return "" }
        if attention { return EnvironmentsMapText.health(health) }
        return "Expires \(FleetTimestamp.format(edge.link?.expiresAt ?? ""))"
    }
    override var accessibilityText: String? { "\(label), \(LinkAccess.label(edge.access)), \(trailing)" }

    func height(forWidth width: CGFloat) -> CGFloat { 24 }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(cg)
        let font = DSFont.ui(12)
        let trailingColor = attention ? edge.health.map(FleetGlyphs.tone) ?? Themed.color(\.mutedForeground) : Themed.color(\.mutedForeground)
        let trailingWidth = 12 + 6 + ceil((trailing as NSString).size(withAttributes: [.font: font]).width)
        let left: CGFloat = 6, right = bounds.width - 6
        FleetGlyphs.accessMeter(edge.access, at: CGPoint(x: left, y: bounds.midY - 6), color: Themed.color(\.foreground, 0.8).cgColor(in: self), in: cg)
        let x0 = left + 19 + 12
        let end = right - trailingWidth - 12
        if wide {
            let col = min(160, max(0, (end - x0 - 24) / 3))
            drawText(label, in: CGRect(x: x0, y: 0, width: col, height: bounds.height), font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
            drawText(LinkAccess.label(edge.access), in: CGRect(x: x0 + col + 12, y: 0, width: col, height: bounds.height), font: font,
                     color: Themed.color(\.foreground, 0.8))
            let ux = x0 + 2 * (col + 12)
            drawText(edge.link?.urls.first ?? "", in: CGRect(x: ux, y: 0, width: max(0, end - ux), height: bounds.height), font: DSFont.mono(11),
                     color: Themed.color(\.mutedForeground))
        } else {
            let col = max(0, (end - x0 - 12) / 2)
            drawText(label, in: CGRect(x: x0, y: 0, width: col, height: bounds.height), font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
            drawText(LinkAccess.label(edge.access), in: CGRect(x: x0 + col + 12, y: 0, width: col, height: bounds.height), font: font,
                     color: Themed.color(\.foreground, 0.8))
        }
        let tx = right - trailingWidth
        if let health = edge.health { FleetGlyphs.health(health, center: CGPoint(x: tx + 6, y: bounds.midY), in: cg, view: self) }
        drawText(trailing, in: CGRect(x: tx + 18, y: 0, width: trailingWidth - 18 + 1, height: bounds.height), font: font, color: trailingColor)
    }
}

/// `LinkList` (:653-682): `mb-1 flex min-h-6 items-center gap-3` with an `h4 font-medium` and the action, then the
/// rows in a `-mx-1.5 max-h-48 overflow-y-auto` list.
@MainActor
final class FleetLinkListView: DSView, SettingsGroupRow {
    let title: LabelView?
    let action: ButtonView?
    let rows: [FleetLinkRowButton]
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollbars: .native)

    init(title: String?, action: ButtonView?, rows: [FleetLinkRowButton]) {
        self.title = title.map { LabelView($0, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground)) }
        self.action = action
        self.rows = rows
        super.init(frame: .zero)
        if let t = self.title { t.setAccessibilityRole(.staticText); t.setAccessibilityLabel(title); addSubview(t) }
        if let action { addSubview(action) }
        rows.forEach { document.addSubview($0) }
        if !rows.isEmpty { addSubview(scroll) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var listHeight: CGFloat { min(192, CGFloat(rows.count) * 24) }
    /// The header row stays `min-h-6` even when the title and the action are both absent.
    func height(forWidth width: CGFloat) -> CGFloat { 24 + 4 + listHeight }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if let t = title {
            let w = min(ceil(t.textWidth), bounds.width)
            t.frame = NSRect(x: 0, y: 4, width: w, height: 16)
            x = w + 12
        }
        if let a = action {
            let s = a.intrinsicContentSize
            a.frame = NSRect(x: x, y: 0, width: s.width, height: 24)
        }
        let top: CGFloat = 28
        scroll.frame = NSRect(x: -6, y: top, width: bounds.width + 12, height: listHeight)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width + 12, height: CGFloat(rows.count) * 24)
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(i) * 24, width: bounds.width + 12, height: 24) }
    }
}

/// `LinkDetails` (:835-881): the two ends as buttons with an arrow, Link back… and Forget, then the facts.
@MainActor
final class FleetLinkDetailsView: DSView, SettingsGroupRow {
    let edge: FleetEdge
    let sourceButton: FleetEndpointButton
    let targetButton: FleetEndpointButton
    private let arrow = IconView(name: .arrowRight, size: 14, strokeColor: Themed.color(\.mutedForeground))
    var linkBackButton: ButtonView?
    var forgetButton: ButtonView?
    private var terms: [LabelView] = []
    private var values: [any SettingsGroupRow] = []
    var onEndpoint: ((String) -> Void)?
    var onLinkBack: (() -> Void)?
    var onForget: (() -> Void)?

    init(edge: FleetEdge, source: String, target: String, linkBack: Bool, canForget: Bool, forgetting: Bool) {
        self.edge = edge
        sourceButton = FleetEndpointButton(source)
        targetButton = FleetEndpointButton(target)
        super.init(frame: .zero)
        sourceButton.action = { [weak self] in self.map { $0.onEndpoint?($0.edge.from) } }
        targetButton.action = { [weak self] in self.map { $0.onEndpoint?($0.edge.to) } }
        arrow.setAccessibilityElement(true)
        arrow.setAccessibilityRole(.image)
        arrow.setAccessibilityLabel("links to")
        [sourceButton, arrow, targetButton].forEach { addSubview($0) }
        if linkBack {
            let b = ButtonView("Link back…", variant: .outline, size: .xs)
            b.action = { [weak self] in self?.onLinkBack?() }
            linkBackButton = b
            addSubview(b)
        }
        if canForget {
            let b = ButtonView(forgetting ? "Forgetting…" : "Forget", variant: .destructiveOutline, size: .xs)
            b.isEnabled = !forgetting
            b.action = { [weak self] in self?.onForget?() }
            forgetButton = b
            addSubview(b)
        }
        let link = edge.link
        let health = edge.health ?? .reachable(expiresInDays: nil)
        func term(_ s: String) {
            let l = LabelView(s, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            l.lineHeight = 16
            terms.append(l); addSubview(l)
        }
        term("Access")
        values.append(FleetAccessValue(edge.access))
        term("Status")
        values.append(FleetStatusValue(health))
        term("Expires")
        values.append(FleetTextBlock(FleetTimestamp.format(link?.expiresAt ?? ""), muted: false))
        term("Addresses")
        values.append(FleetTextBlock((link?.urls ?? []).joined(separator: "\n"), muted: false, font: DSFont.mono(11)))
        term("Linked")
        values.append(FleetTextBlock(FleetTimestamp.format(link?.linkedAt ?? ""), muted: false))
        if let reached = link?.lastReachedAt {
            term("Last reached")
            values.append(FleetTextBlock(FleetTimestamp.format(reached), muted: false))
        }
        values.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var termWidth: CGFloat { terms.map { ceil($0.textWidth) }.max() ?? 0 }
    var buttons: [ButtonView] { [linkBackButton, forgetButton].compactMap { $0 } }

    func frames(_ width: CGFloat) -> (rows: [(term: NSRect, value: NSRect)], height: CGFloat) {
        let dl = min(width, 672)
        let valueX = termWidth + 16
        var y: CGFloat = 24 + 8
        var rows: [(NSRect, NSRect)] = []
        for (i, value) in values.enumerated() {
            let h = max(16, value.height(forWidth: max(0, dl - valueX)))
            rows.append((NSRect(x: 0, y: y, width: termWidth, height: 16), NSRect(x: valueX, y: y, width: max(0, dl - valueX), height: h)))
            y += h + (i == values.count - 1 ? 0 : 6)
        }
        return (rows, y)
    }

    func height(forWidth width: CGFloat) -> CGFloat { frames(width).height }

    override func layout() {
        super.layout()
        // `h3 flex items-center gap-1.5 text-sm`, the buttons `flex items-center gap-2` on the right.
        var x: CGFloat = 0
        for (i, v) in [sourceButton as NSView, arrow, targetButton].enumerated() {
            let w = i == 1 ? 14 : (v as! FleetEndpointButton).intrinsicContentSize.width
            v.frame = NSRect(x: x, y: i == 1 ? 5 : 2, width: w, height: i == 1 ? 14 : 20)
            x += w + 6
        }
        var right = bounds.width
        for b in buttons.reversed() {
            let s = b.intrinsicContentSize
            right -= s.width
            b.frame = NSRect(x: right, y: 0, width: s.width, height: 24)
            right -= 8
        }
        let f = frames(bounds.width)
        for (i, row) in f.rows.enumerated() {
            terms[i].frame = row.term
            values[i].frame = row.value
        }
    }
}

/// An end of a link: `rounded-sm font-medium text-foreground underline-offset-2 hover:underline`.
@MainActor
final class FleetEndpointButton: FleetRowControl {
    let text: String
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var accessibilityText: String? { text }
    var font: NSFont { DSFont.ui(14, weight: .medium) }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width), height: 20) }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Themed.color(\.foreground)]
        if state.hovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let a = NSAttributedString(string: text, attributes: attributes)
        a.draw(at: NSPoint(x: 0, y: (bounds.height - a.size().height) / 2))
        if state.focusVisible {
            cg.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 3, cornerHeight: 3, transform: nil))
            cg.setLineWidth(2); cg.setStrokeColor(Themed.color(\.ring).cgColor(in: self)); cg.strokePath()
        }
    }
}

/// The Access value (:852-859): the meter and the label in `font-medium`, then the description in muted text.
@MainActor
final class FleetAccessValue: DSView, SettingsGroupRow {
    let access: String
    private let label: LabelView
    private let blurb: TextBlockView
    init(_ access: String) {
        self.access = access
        label = LabelView(LinkAccess.label(access), font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
        blurb = TextBlockView(LinkAccess.all.first { $0.value == access }?.description ?? "", font: DSFont.ui(12), lineHeight: 16,
                                    color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        addSubview(label)
        addSubview(blurb)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { false }
    func height(forWidth width: CGFloat) -> CGFloat { 16 + blurb.height(forWidth: width) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 27, y: 0, width: max(0, bounds.width - 27), height: 16)
        blurb.frame = NSRect(x: 0, y: 16, width: bounds.width, height: blurb.height(forWidth: bounds.width))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        FleetGlyphs.accessMeter(access, at: CGPoint(x: 0, y: 2), color: Themed.color(\.foreground, 0.8).cgColor(in: self), in: cg)
    }
}

/// The Status value (:860-871): the glyph and `peerLinkStatusText`, in the health's tone when it needs attention.
@MainActor
final class FleetStatusValue: DSView, SettingsGroupRow {
    let health: PeerLinkHealth
    private let text: TextBlockView
    init(_ health: PeerLinkHealth) {
        self.health = health
        text = TextBlockView(health.text, font: DSFont.ui(12), lineHeight: 16,
                             color: linkNeedsAttention(health) ? FleetGlyphs.tone(health) : Themed.color(\.foreground))
        super.init(frame: .zero)
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { false }
    /// `gap-1.5` after the glyph: the dots are `size-2`, the icons `size-3`.
    var glyphWidth: CGFloat { switch health { case .reachable(nil), .unreachable: 8; default: 12 } }
    var textX: CGFloat { glyphWidth + 6 }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: max(0, width - textX)) }
    override func layout() { super.layout(); text.frame = NSRect(x: textX, y: 0, width: max(0, bounds.width - textX), height: bounds.height) }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        FleetGlyphs.health(health, center: CGPoint(x: glyphWidth / 2, y: min(bounds.midY, 8)), in: cg, view: self)
    }
}

// MARK: - Stack members (:289-516)

/// `StackMember`: what a stack's list says about one machine.
public struct FleetStackMember: Equatable {
    public var id: String
    public var label: String
    public var detail: String
    public var address: String?
    public var worst: FleetEdge?

    public static func members(_ stack: FleetStack, _ graph: FleetGraph, _ links: [FleetEdge], statusText: [String: String]) -> [FleetStackMember] {
        let ids = Set(stack.memberIds)
        var incoming: [String: [FleetEdge]] = [:]
        for edge in links where ids.contains(edge.to) { incoming[edge.to, default: []].append(edge) }
        return stack.memberIds.compactMap { id in
            guard let node = graph.node(id), node.kind != .client else { return nil }
            if node.kind == .target {
                let into = incoming[id] ?? []
                // `toSorted` is stable, so the first of equal trouble wins.
                let worst = into.enumerated().min { a, b in
                    let l = a.element.health.map(linkTroubleRank) ?? 4, r = b.element.health.map(linkTroubleRank) ?? 4
                    return l != r ? l < r : a.offset < b.offset
                }?.element
                let detail = into.count == 1 && worst != nil ? LinkAccess.label(worst!.access)
                    : into.count == 1 ? "1 link in" : "\(into.count) links in"
                return FleetStackMember(id: id, label: node.label, detail: detail, address: node.address, worst: worst)
            }
            return FleetStackMember(id: id, label: node.label, detail: statusText[node.environmentId] ?? "Not added", address: nil, worst: nil)
        }
    }
}

/// `MemberButton` (:518-560): `MEMBER_ROW_HEIGHT` 28, `grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]`, at lg
/// `[minmax(0,12rem)_minmax(0,10rem)_minmax(0,1fr)_auto]`.
@MainActor
final class FleetMemberRowButton: FleetRowControl {
    let member: FleetStackMember
    let wide: Bool
    init(_ member: FleetStackMember, wide: Bool) {
        self.member = member; self.wide = wide
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    var healthText: String { member.worst?.health.map(EnvironmentsMapText.health) ?? "" }
    override var accessibilityText: String? { [member.label, member.detail, healthText].filter { !$0.isEmpty }.joined(separator: ", ") }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(cg)
        let font = DSFont.ui(12)
        let left: CGFloat = 6, right = bounds.width - 6
        var trailingWidth: CGFloat = 0
        if let health = member.worst?.health {
            trailingWidth = 18 + ceil((healthText as NSString).size(withAttributes: [.font: font]).width)
            let tx = right - trailingWidth
            let attention = linkNeedsAttention(health)
            FleetGlyphs.health(health, center: CGPoint(x: tx + 6, y: bounds.midY), in: cg, view: self)
            drawText(healthText, in: CGRect(x: tx + 18, y: 0, width: trailingWidth - 18 + 1, height: bounds.height), font: font,
                     color: attention ? FleetGlyphs.tone(health) : Themed.color(\.mutedForeground))
        }
        let end = right - trailingWidth - 12
        if wide {
            let first = min(192, max(0, (end - left - 24) * 0.4)), second = min(160, max(0, (end - left - 24) * 0.3))
            drawText(member.label, in: CGRect(x: left, y: 0, width: first, height: bounds.height), font: DSFont.ui(12, weight: .medium),
                     color: Themed.color(\.foreground))
            drawText(member.detail, in: CGRect(x: left + first + 12, y: 0, width: second, height: bounds.height), font: font,
                     color: Themed.color(\.foreground, 0.8))
            let ax = left + first + second + 24
            drawText(member.address ?? "", in: CGRect(x: ax, y: 0, width: max(0, end - ax), height: bounds.height), font: DSFont.mono(11),
                     color: Themed.color(\.mutedForeground))
        } else {
            let col = max(0, (end - left - 12) / 2)
            drawText(member.label, in: CGRect(x: left, y: 0, width: col, height: bounds.height), font: DSFont.ui(12, weight: .medium),
                     color: Themed.color(\.foreground))
            drawText(member.detail, in: CGRect(x: left + col + 12, y: 0, width: col, height: bounds.height), font: font,
                     color: Themed.color(\.foreground, 0.8))
        }
    }
}

/// The stack's list (:443-478): a `w-56` "Filter by name" field and "{shown} of {count}" past nine members, then at
/// most nine 28pt rows that scroll.
@MainActor
final class FleetMemberListView: DSView, SettingsGroupRow {
    static let rowHeight: CGFloat = 28
    static let visibleRows = 9
    let members: [FleetStackMember]
    let wide: Bool
    var query: String
    private let field = InputView(placeholder: "Filter by name", size: .compact)
    private let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollbars: .native)
    // ponytail: every shown row is a view; mount only the rows in view (LegendList) if stacks reach thousands
    private var rows: [FleetMemberRowButton] = []
    var onSelect: ((String) -> Void)?
    var onQuery: ((String) -> Void)?

    init(members: [FleetStackMember], query: String, wide: Bool) {
        self.members = members; self.query = query; self.wide = wide
        super.init(frame: .zero)
        if filters {
            field.text = query
            field.setAccessibilityLabel("Filter these machines by name")
            field.onChange = { [weak self] text in self?.apply(text) }
            count.setAccessibilityRole(.staticText)
            addSubview(field)
            addSubview(count)
        }
        addSubview(scroll)
        rebuildRows()
    }
    required init?(coder: NSCoder) { fatalError() }

    var filters: Bool { members.count > Self.visibleRows }
    var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    var shown: [FleetStackMember] { needle.isEmpty ? members : members.filter { $0.label.lowercased().contains(needle) } }

    func apply(_ text: String) {
        query = text
        rebuildRows()
        onQuery?(text)
    }

    func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = shown.map { member in
            let row = FleetMemberRowButton(member, wide: wide)
            row.action = { [weak self] in self?.onSelect?(member.id) }
            document.addSubview(row)
            return row
        }
        count.text = needle.isEmpty ? "" : "\(rows.count) of \(members.count)"
        needsLayout = true
    }

    var fieldHeight: CGFloat { filters ? 28 + 6 : 0 }
    func height(forWidth width: CGFloat) -> CGFloat { fieldHeight + CGFloat(min(shown.count, Self.visibleRows)) * Self.rowHeight }

    override func layout() {
        super.layout()
        if filters {
            field.frame = NSRect(x: 0, y: 0, width: min(224, bounds.width), height: 28)
            count.frame = NSRect(x: field.frame.maxX + 12, y: 6, width: max(0, bounds.width - field.frame.maxX - 12), height: 16)
        }
        let h = CGFloat(min(rows.count, Self.visibleRows)) * Self.rowHeight
        scroll.frame = NSRect(x: -6, y: fieldHeight, width: bounds.width + 12, height: h)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width + 12, height: CGFloat(rows.count) * Self.rowHeight)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width + 12, height: Self.rowHeight)
        }
    }
}
