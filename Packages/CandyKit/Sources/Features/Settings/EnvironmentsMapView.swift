import AppKit
import DesignSystem
import T3Protocol

// Settings > Environments as a map (T3 5258 components/settings/EnvironmentsMap.tsx). The toolbar, the canvas and
// the footer with the legend and zoom. The canvas draws the whole scene in one `draw(_:)` from the layout
// `EnvironmentsMapLogic` computes, so it costs nothing while it sits still: no timer, no display link, no layer
// per machine. Line numbers cite EnvironmentsMap.tsx unless they name another file.

/// What the map shows. The app fills it from its saved environments, their peer link lists and T3 Connect.
public struct EnvironmentsMapModel: Equatable {
    public var clientLabel: String
    public var environments: [FleetEnvironmentInput]
    public var connectMachines: [FleetConnectMachineInput]
    /// Environments waiting for this device's approval on the host: "Waiting for approval" (:1155).
    public var awaitingApproval: Set<String>
    public var now: Date
    /// What the details panel shows beyond the graph.
    public var details = EnvironmentsMapDetailsModel()
    public init(clientLabel: String = "This app", environments: [FleetEnvironmentInput] = [],
                connectMachines: [FleetConnectMachineInput] = [], awaitingApproval: Set<String> = [], now: Date = Date()) {
        self.clientLabel = clientLabel; self.environments = environments; self.connectMachines = connectMachines
        self.awaitingApproval = awaitingApproval; self.now = now
    }
}

/// Words the map uses (:205-242, :1140-1350).
public enum EnvironmentsMapText {
    public static func routeKind(_ kind: String) -> String {
        switch kind {
        case "relay": "T3 Connect"
        // Redesign: the route beside the "This device" node said "This device" again (G5, round 2).
        case "loopback": RedesignCopy.word("This device", "Local")
        case "lan": "LAN"
        case "tailnet": "Tailscale"
        case "vpn": "VPN"
        case "ssh": "SSH"
        case "public": "Public"
        default: kind
        }
    }

    public static func routeState(_ state: FleetRouteState) -> String {
        switch state {
        case .inUse: "In use"
        case .standby: "Standby"
        case .trying: "Connecting"
        case .down: "Not connected"
        case .idle: "Not in use"
        case .refused: "Sign-in refused"
        case .offered: "Not added"
        }
    }

    public static func connectionState(_ node: FleetNode, awaitingApproval: Bool, refused: Bool) -> String {
        if !node.enabled && node.phase != .unsupported { return "Off" }
        if refused { return "Sign-in refused" }
        switch node.phase {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return awaitingApproval ? "Waiting for approval" : "Reconnecting…"
        case .unsupported: return "Client not supported"
        case .error: return "Connection failed"
        case .offline: return "Offline"
        case .available: return "Not connected"
        }
    }

    public static func environmentStatus(_ node: FleetNode, awaitingApproval: Bool, refused: Bool, linkCount: Int) -> String {
        if node.phase != .connected { return connectionState(node, awaitingApproval: awaitingApproval, refused: refused) }
        switch node.outgoing {
        case "loading": return "Loading links…"
        case "error": return "Links could not be loaded"
        // Redesign: short enough for the node's line, which cut T3's words to "Linked environments i..." (G5, round 2).
        case "off": return RedesignCopy.word("Linked environments is off", "Links off")
        case "unknown": return "Links not readable from here"
        default: return linkCount == 0 ? "No links out" : linkCount == 1 ? "1 link out" : "\(linkCount) links out"
        }
    }

    public static func connectAvailability(_ availability: FleetConnectMachineInput.Availability?) -> String {
        switch availability {
        case .online: "Relay online"
        case .offline: "Relay offline"
        case .checking: "Checking relay status…"
        case .error, nil: "Relay status unavailable"
        }
    }

    public static func foldGroup(_ group: FleetFoldGroup) -> String {
        switch group {
        case .offline: "Offline"
        case .off: "Switched off"
        case .update: "Need an update"
        case .notAdded: "Not added"
        }
    }

    public static func column(_ column: FleetColumn) -> String {
        switch column {
        case .client: "This app"
        case .environments: "Environments"
        case .targets: "Linked machines"
        }
    }

    /// `healthLabel` (EnvironmentsMapDetails.tsx:54-66).
    public static func health(_ health: PeerLinkHealth) -> String {
        switch health {
        case .expired: "Expired"
        case .failing: "Failing"
        case .unreachable: "Not answering"
        case .reachable(let days?): "Expires in \(days) \(days == 1 ? "day" : "days")"
        case .reachable(nil): "Reachable"
        }
    }

    public static func linkSummary(_ edge: FleetEdge) -> String {
        "\(LinkAccess.label(edge.access)), \(edge.health.map(health) ?? "")"
    }

    /// `linkName` (:1215-1244).
    public static func linkName(_ edge: FleetEdge, back: FleetEdge?, label: (String) -> String) -> String {
        let source = label(edge.from), target = label(edge.to)
        guard let back else { return "Link from \(source) to \(target): \(linkSummary(edge))" }
        return "Two-way link between \(source) and \(target), \(LinkAccess.label(edge.access)). "
            + "\(source) to \(target): \(edge.health.map(health) ?? ""). \(target) to \(source): \(back.health.map(health) ?? "")"
    }

    static func needsCode(_ count: Int) -> String {
        count == 1 ? "1 machine needs a pairing code" : "\(count) machines each need a pairing code"
    }

    /// `actionText` (:1300-1323), the drag hint over a drop target.
    public static func action(_ action: FleetLinkAction?, target: String) -> String {
        switch action {
        case nil: return "Cannot link to this"
        case .codeOnly(_, _, let ids)?: return needsCode(ids.count)
        case .batch(_, let ids)?: return ids.count == 1 ? "Link to 1 machine" : "Link to \(ids.count) machines"
        case .single(_, nil)?: return "Cannot link to this"
        case .single(_, let offer?)?:
            if offer.path == .pairingCode {
                return offer.renews ? "Renew link to \(target) with a pairing code" : "Link to \(target) with a pairing code"
            }
            return offer.renews ? "Renew link to \(target)" : "Link to \(target)"
        }
    }

    /// The search status beside the field (:916-917).
    public static func matches(_ count: Int) -> String {
        count == 0 ? "No machine by that name" : count == 1 ? "1 match" : "\(count) matches"
    }
}

/// The access scale a link's line is drawn on (:144-145): heavier and darker toward full access.
enum FleetAccessStroke {
    static let widths: [CGFloat] = [1.25, 1.75, 2.25, 2.75, 3.5]
    static let opacities: [CGFloat] = [0.4, 0.5, 0.62, 0.76, 0.9]
    static func level(_ access: String?) -> Int { access.flatMap { fleetAccessOrder.firstIndex(of: $0) } ?? 1 }
}

/// Icons T3's map imports that CW's generated set lacks (lucide 0.564.0 fold-vertical, unfold-vertical, circle-help,
/// app-window), drawn from the same paths.
enum EnvironmentsMapIcons {
    static let box = IconViewBox(x: 0, y: 0, width: 24, height: 24)
    static func paths(_ ds: [String]) -> IconDefinition { IconDefinition(viewBox: box, elements: ds.map { IconElement(.path(d: $0)) }) }
    static let rules = ["M12 22v-6", "M12 8V2", "M4 12H2", "M10 12H8", "M16 12h-2", "M22 12h-2"]
    static let fold = paths(rules + ["m15 19-3-3-3 3", "m15 5-3 3-3-3"])
    static let unfold = paths(rules + ["m15 19-3 3-3-3", "m15 5-3-3-3 3"])
    static let help = IconDefinition(viewBox: box, elements: [IconElement(.circle(cx: 12, cy: 12, r: 10)),
                                                              IconElement(.path(d: "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3")),
                                                              IconElement(.path(d: "M12 17h.01"))])
    /// lucide clock-alert, `HealthGlyph` for a link that expires within days.
    static let clockAlert = paths(["M12 6v6l4 2", "M20 12v5", "M20 21h.01", "M21.25 8.2A10 10 0 1 0 16 21.16"])
    static let appWindow = IconDefinition(viewBox: box, elements: [IconElement(.rect(x: 2, y: 4, w: 20, h: 16, rx: 2, ry: 2)),
                                                                   IconElement(.path(d: "M10 4v4")), IconElement(.path(d: "M2 8h20")),
                                                                   IconElement(.path(d: "M6 4v4"))])
}

/// Draws an icon definition into the current context, stroked like lucide.
@MainActor func fleetDrawIcon(_ definition: IconDefinition, in rect: CGRect, color: CGColor, lineWidth: CGFloat = 2, context cg: CGContext) {
    let scale = rect.width / CGFloat(definition.viewBox.width)
    cg.saveGState()
    cg.translateBy(x: rect.minX, y: rect.minY)
    cg.scaleBy(x: scale, y: scale)
    cg.setLineWidth(lineWidth)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.setStrokeColor(color)
    cg.setFillColor(color)
    for element in definition.elements {
        guard let path = try? element.cgPath() else { continue }
        cg.addPath(path)
        if element.paint.fill != nil, element.paint.stroke == nil { cg.fillPath() } else { cg.strokePath() }
    }
    cg.restoreGState()
}

/// The colors and corners the map draws with: T3's in its default themes, Redesign's own in Redesign.
struct FleetPaint {
    var canvas: NSColor
    var dots: NSColor
    var card: NSColor
    var cardBorder: NSColor
    var dimBorder: NSColor
    var pill: NSColor
    var pillBorder: NSColor
    var foreground: NSColor
    var muted: NSColor
    var success: NSColor
    var warning: NSColor
    var destructive: NSColor
    var primary: NSColor
    var primaryForeground: NSColor
    var mutedFill: NSColor
    var inUse: NSColor
    var cardRadius: CGFloat
    var smallRadius: CGFloat
    var trayRadius: CGFloat
    var shadow: Bool

    /// T3's classes: cards `rounded-lg border bg-card shadow-sm/5`, the canvas `bg-background/50` with a dot grid in
    /// `--border` (:1010-1022), lines in `currentColor` of each state's text color.
    static let stock = FleetPaint(
        canvas: Themed.color(\.background, 0.5), dots: Themed.color(\.border), card: Themed.color(\.card),
        cardBorder: Themed.color(\.foreground, 0.2), dimBorder: Themed.color(\.foreground, 0.25),
        pill: Themed.color(\.background), pillBorder: Themed.color(\.border), foreground: Themed.color(\.foreground),
        muted: Themed.color(\.mutedForeground), success: Themed.color(\.success), warning: Themed.color(\.warning),
        destructive: Themed.color(\.destructive), primary: Themed.color(\.primary),
        primaryForeground: Themed.color(\.primaryForeground), mutedFill: Themed.color(\.muted),
        inUse: Themed.color(\.success), cardRadius: 8, smallRadius: 6, trayRadius: 12, shadow: true)

    @MainActor static var current: FleetPaint { RedesignMapPaint.isOn ? RedesignMapPaint.paint : stock }
}

/// Redesign's map: cards are Redesign cards on the ground (the inset fill and the rim, no shadow), one corner for
/// every surface and the control corner inside them, the accent for the route in use and for selection, and no
/// dot grid, so the map sits on the ground like the rest of Redesign's Settings.
enum RedesignMapPaint {
    @MainActor static var isOn: Bool { ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true) }
    static let paint = FleetPaint(
        canvas: .clear, dots: .clear, card: RedesignTokens.Card.fill, cardBorder: RedesignTokens.Card.border,
        dimBorder: RedesignTokens.Card.border, pill: Themed.color(\.background), pillBorder: RedesignTokens.Card.border,
        foreground: Themed.color(\.foreground), muted: Themed.color(\.mutedForeground), success: Themed.color(\.success),
        warning: Themed.color(\.warning), destructive: Themed.color(\.destructive), primary: Themed.color(\.primary),
        primaryForeground: Themed.color(\.primaryForeground), mutedFill: Themed.color(\.muted), inUse: Themed.color(\.primary),
        cardRadius: RedesignTokens.Radius.card, smallRadius: RedesignTokens.Radius.control, trayRadius: RedesignTokens.Radius.card,
        shadow: false)
}

/// The map's interaction state, apart from drawing so tests can drive it.
public struct EnvironmentsMapState: Equatable {
    public var selection: FleetFocus?
    /// Machines ticked for linking several at once, in the order ticked.
    public var ticked: [String] = []
    public var expanded: Set<String> = []
    public var query = ""
    /// The canvas height a stack's anchoring chose, with `held`.
    public var heldHeight: Double?
    /// The machine a search landed on inside the selected stack (`found`).
    public var found: String?
    /// The view set by hand; nil follows the fit.
    public var held: FleetViewTransform?
    public var roving = fleetClientNodeId
    public init() {}

    public mutating func tick(_ ids: [String], toggle: Bool) {
        for id in ids {
            if let index = ticked.firstIndex(of: id) { if toggle { ticked.remove(at: index) } } else { ticked.append(id) }
        }
    }
}

// MARK: - The canvas

@MainActor
public final class EnvironmentsMapCanvasView: DSView {
    public private(set) var graph = FleetGraph(nodes: [], edges: [])
    public private(set) var stacks: [FleetStack] = []
    public private(set) var fleetLayout = layoutFleetGraph(FleetGraph(nodes: [FleetNode(id: fleetClientNodeId, kind: .client, label: "")], edges: []))
    public var state = EnvironmentsMapState() { didSet { if state != oldValue { stateChanged(oldValue) } } }
    var model = EnvironmentsMapModel()
    private var layoutKey = ""
    private var layoutWidth: Double = -1
    private var hover: FleetFocus?
    private var drag: Drag?
    private var tracking: NSTrackingArea?
    private var axElements: [String: FleetAccessibilityElement] = [:]

    /// The node or stack the details should show, or nil.
    public var onSelect: ((FleetFocus?) -> Void)?
    /// A press of an environment's link handle (target nil) or a drop of it on a machine.
    public var onLink: ((_ sourceId: String, _ targetId: String?) -> Void)?
    /// The ticked set or the view changed: the toolbar and the zoom buttons follow.
    public var onStateChange: (() -> Void)?

    enum Drag {
        case pan(start: NSPoint, view: FleetViewTransform)
        case box(start: NSPoint, current: NSPoint)
        case link(sourceId: String, start: NSPoint, at: NSPoint, moved: Bool)
    }

    public override var wantsUpdateLayer: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override var focusRingType: NSFocusRingType { get { .none } set {} }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `overflow-clip` (:1010). AppKit stopped clipping a view's drawing to its bounds in macOS 14, so a panned scene
        // drew over the page heading.
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Map of your machines")
        setAccessibilityHelp("Arrow keys move between machines. Enter opens a machine's details, with its routes and links. "
            + "Space selects a machine for linking several at once. Tab from an environment reaches its link button. "
            + "Plus and minus zoom, zero fits the map.")
    }

    // MARK: Model

    func set(_ model: EnvironmentsMapModel) {
        self.model = model
        graph = buildFleetGraph(clientLabel: model.clientLabel, environments: model.environments,
                                connectMachines: model.connectMachines, now: model.now)
        relayout(force: true)
    }

    private func stateChanged(_ old: EnvironmentsMapState) {
        if state.expanded != old.expanded { relayout(force: true) }
        needsDisplay = true
        onStateChange?()
    }

    /// Lays the map out again when its shape or its width step changed (`fleetLayoutWidth`, :1857).
    func relayout(force: Bool = false) {
        let width = fleetLayoutWidth(Double(bounds.width))
        stacks = fleetStacks(graph, expanded: state.expanded)
        let key = fleetShapeKey(graph, stacks)
        guard force || key != layoutKey || width != layoutWidth else { return }
        layoutKey = key
        layoutWidth = width
        fleetLayout = layoutFleetGraph(graph, stacks, canvasWidth: width > 0 ? width : nil)
        rebuildAccessibility()
        needsDisplay = true
    }

    /// The height the canvas wants at `width` (:147, `fleetCanvasHeight`).
    func wantedHeight(_ width: CGFloat) -> CGFloat {
        let rest = restingHeight(width)
        // `data-glide:transition-[height]` (:1010): a glide eases the canvas from the height it had to the new one,
        // and its last frame is the resting height exactly.
        guard let from = glide?.fromHeight, from != rest else { return rest }
        return (from + (rest - from) * CGFloat(glideProgress)).rounded()
    }

    /// The height the canvas settles at.
    func restingHeight(_ width: CGFloat) -> CGFloat {
        // A view kept while a stack opened keeps the height it chose (:676-679).
        if let h = state.heldHeight, state.held != nil { return CGFloat(h) }
        let w = fleetLayoutWidth(Double(width))
        let l = w == layoutWidth ? fleetLayout : layoutFleetGraph(graph, stacks, canvasWidth: w > 0 ? w : nil)
        return CGFloat(fleetCanvasHeight(width: l.width, height: l.height, canvasWidth: Double(width), bounds: 180...840))
    }

    /// Called on each glide frame that moves the canvas height, and once when it settles, so the page lays out again.
    var onHeightGlide: (() -> Void)?

    var fit: FleetViewTransform { fitFleetLayout(width: fleetLayout.width, height: fleetLayout.height, viewport: bounds.size) }
    /// Where the view rests: set by hand, or the fit.
    public var view: FleetViewTransform { state.held ?? fit }

    // MARK: Glide (:1037 `transition-transform duration-200 ease-out`, :160 `APPEAR`)

    /// A glide in progress: the view it left, and a stack whose tray and lifted cards fade. Nil at rest, so the map
    /// runs no display link while it sits still, and the last frame draws the resting view exactly.
    struct Glide { var start: CFTimeInterval; var from: FleetViewTransform; var stack: String?; var fromHeight: CGFloat? = nil }
    private(set) var glide: Glide?
    private var glideLink: CADisplayLink?
    static let glideDuration: CFTimeInterval = 0.2
    /// `motion-reduce:transition-none`; replaceable, with the clock, in tests.
    var reducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// Tailwind's `ease-out`, `cubic-bezier(0, 0, 0.2, 1)`, at `t`: x(u) = 0.6u² + 0.4u³, y(u) = 3u² − 2u³.
    static func easeOut(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let u = (lo + hi) / 2
            if 0.6 * u * u + 0.4 * u * u * u < t { lo = u } else { hi = u }
        }
        let u = (lo + hi) / 2
        return 3 * u * u - 2 * u * u * u
    }

    /// How far the glide has run, eased: 1 at rest.
    var glideProgress: Double {
        guard let glide else { return 1 }
        return Self.easeOut((now() - glide.start) / Self.glideDuration)
    }

    /// The view drawn now: between where the glide started and where the view rests.
    var shown: FleetViewTransform {
        guard let glide else { return view }
        let p = glideProgress, to = view
        return FleetViewTransform(x: glide.from.x + (to.x - glide.from.x) * p, y: glide.from.y + (to.y - glide.from.y) * p,
                                  scale: glide.from.scale + (to.scale - glide.from.scale) * p)
    }

    /// Runs `change` and glides from the view on screen to the one it leaves, unless motion is reduced.
    func gliding(stack: String? = nil, _ change: () -> Void) {
        let from = shown
        let fromHeight = bounds.height > 0 ? bounds.height : nil
        change()
        let heightMoves = fromHeight.map { $0 != restingHeight(bounds.width) } ?? false
        guard !reducedMotion(), from != view || stack != nil || heightMoves else { return }
        glide = Glide(start: now(), from: from, stack: stack, fromHeight: heightMoves ? fromHeight : nil)
        if glideLink == nil {
            let link = displayLink(target: self, selector: #selector(glideFrame))
            link.add(to: .main, forMode: .common)
            glideLink = link
        }
        needsDisplay = true
    }

    @objc func glideFrame() {
        if glide == nil || now() - glide!.start >= Self.glideDuration { endGlide(); return }
        if glide?.fromHeight != nil { onHeightGlide?() }
        needsDisplay = true
    }

    func endGlide() {
        let movedHeight = glide?.fromHeight != nil
        glide = nil
        glideLink?.invalidate()
        glideLink = nil
        needsDisplay = true
        if movedHeight { onHeightGlide?() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endGlide() }
    }

    public override func layout() {
        super.layout()
        relayout()
    }

    // MARK: Zoom and pan (:860-870)

    public func zoom(_ factor: Double, at anchor: NSPoint? = nil) {
        if glide?.stack == nil { endGlide() }
        let point = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        state.held = zoomFleetView(view, factor, anchor: FleetPoint(x: Double(point.x), y: Double(point.y)), fitScale: fit.scale)
    }

    /// The zoom buttons and keys glide; a pinch or a Cmd-scroll follows the fingers (`zoom(…, eased)`, :689-702).
    public func zoomGliding(_ factor: Double) { gliding { zoom(factor) } }

    public func fitView() { gliding { state.held = nil; state.heldHeight = nil } }

    /// Pans so `rect` (scene space) is in view, at a legible scale when `legible` (search, :157).
    func reveal(_ rect: FleetRect, legible: Bool = false) { gliding { revealNow(rect, legible: legible) } }

    private func revealNow(_ rect: FleetRect, legible: Bool) {
        var v = view
        if legible, v.scale < fleetFitLegibleScale {
            v = FleetViewTransform(x: v.x, y: v.y, scale: fleetFitLegibleScale)
            v.x = Double(bounds.midX) - (rect.x + rect.width / 2) * v.scale
            v.y = Double(bounds.midY) - (rect.y + rect.height / 2) * v.scale
            state.held = v
            return
        }
        let pad = 16.0
        let left = rect.x * v.scale + v.x, right = (rect.x + rect.width) * v.scale + v.x
        let top = rect.y * v.scale + v.y, bottom = (rect.y + rect.height) * v.scale + v.y
        var dx = 0.0, dy = 0.0
        if left < pad { dx = pad - left } else if right > Double(bounds.width) - pad { dx = Double(bounds.width) - pad - right }
        if top < pad { dy = pad - top } else if bottom > Double(bounds.height) - pad { dy = Double(bounds.height) - pad - bottom }
        if dx != 0 || dy != 0 { state.held = FleetViewTransform(x: v.x + dx, y: v.y + dy, scale: v.scale) }
    }

    func toScene(_ p: NSPoint) -> CGPoint {
        let v = shown
        return CGPoint(x: (Double(p.x) - v.x) / v.scale, y: (Double(p.y) - v.y) / v.scale)
    }

    func toView(_ r: FleetRect) -> NSRect {
        let v = shown
        return NSRect(x: r.x * v.scale + v.x, y: r.y * v.scale + v.y, width: r.width * v.scale, height: r.height * v.scale)
    }

    // MARK: Focus and lighting (:1385-1460)

    var focus: FleetFocus? { drag.flatMap { if case .link = $0 { true } else { nil } } == nil ? (hover ?? state.selection) : nil }
    var lit: (nodes: Set<String>, edges: Set<String>)? { focus.map { fleetNeighborhood(graph, stacks, $0) } }
    var matches: Set<String>? {
        state.query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Set(fleetSearch(graph, state.query))
    }

    // MARK: Hit testing

    enum Hit: Equatable {
        case node(String), stack(String), toggle(String), more(String), handle(String), edge(String), background
    }

    func hit(_ viewPoint: NSPoint) -> Hit {
        let p = toScene(viewPoint)
        for (id, handle) in fleetLayout.handles.entries where graph.node(id)?.linking == .ready {
            if hypot(p.x - handle.x, p.y - handle.y) <= 9 { return .handle(id) }
        }
        for (id, geometry) in fleetLayout.stacks.entries {
            let face = geometry.face
            let partial = stacks.first { $0.id == id }.map(fleetStackPartial) == true ? 20.0 : 0
            let toggle = CGRect(x: face.x + face.width - 28, y: face.y + (face.height - partial) / 2 - 11, width: 22, height: 22)
            if toggle.contains(p) { return .toggle(id) }
            if let more = geometry.more, more.cgRect.contains(p) { return .more(id) }
            if face.cgRect.contains(p) { return .stack(id) }
        }
        for (id, rect) in fleetLayout.nodes.entries.reversed() where rect.cgRect.contains(p) { return .node(id) }
        for (id, geometry) in fleetLayout.links.entries {
            if let badge = geometry.badge, !badge.onDemand || focus?.id == id, badge.rect.cgRect.contains(p) { return .edge(id) }
            if fleetCGPath(geometry.d).copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p) {
                return .edge(id)
            }
        }
        return .background
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let next: FleetFocus? = switch hit(convert(event.locationInWindow, from: nil)) {
        case .node(let id): .node(id)
        case .stack(let id), .more(let id): .stack(id)
        case .edge(let id): .edge(id)
        default: nil
        }
        if next != hover { hover = next; needsDisplay = true }
    }

    public override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let tickKeys = shift || event.modifierFlags.contains(.command)
        switch hit(point) {
        case .handle(let id): drag = .link(sourceId: id, start: point, at: point, moved: false)
        case .node(let id):
            if tickKeys, id != fleetClientNodeId { state.tick([id], toggle: true) } else { select(.node(id)) }
            state.roving = id
        case .stack(let id): select(.stack(id)); state.roving = id
        case .more(let id): select(.stack(id)); state.roving = fleetMoreNodeId(id)
        case .toggle(let id): toggleStack(id)
        case .edge(let id): select(.edge(id))
        case .background:
            if !shift { endGlide() }
            drag = shift ? .box(start: point, current: point) : .pan(start: point, view: view)
            if !shift { NSCursor.closedHand.push() }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .pan(let start, let v)?:
            state.held = FleetViewTransform(x: v.x + Double(point.x - start.x), y: v.y + Double(point.y - start.y), scale: v.scale)
        case .box(let start, _)?:
            drag = .box(start: start, current: point)
            needsDisplay = true
        case .link(let id, let start, _, let moved)?:
            drag = .link(sourceId: id, start: start, at: point, moved: moved || hypot(point.x - start.x, point.y - start.y) >= 4)
            needsDisplay = true
        case nil: break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        switch drag {
        case .pan?: NSCursor.pop()
        case .box(let start, let current)?:
            let a = toScene(start), b = toScene(current)
            let box = FleetRect(x: Double(min(a.x, b.x)), y: Double(min(a.y, b.y)), width: Double(abs(a.x - b.x)), height: Double(abs(a.y - b.y)))
            state.tick(fleetNodesInBox(fleetLayout, box), toggle: false)
        case .link(let id, _, let at, let moved)?:
            if !moved { onLink?(id, nil); return }
            if let over = dropTarget(id, at) { onLink?(id, over) }
        case nil: break
        }
    }

    /// The machine under a dragged link handle that the drop could link to (:1497-1506).
    func dropTarget(_ sourceId: String, _ point: NSPoint) -> String? {
        let over: String? = switch hit(point) {
        case .node(let id), .stack(let id): id
        default: nil
        }
        guard let over, fleetLinkAction(graph, stacks, selected: state.ticked, sourceId: sourceId, targetId: over) != nil else { return nil }
        return over
    }

    /// Plain scrolling stays the page's; Ctrl or ⌘ with the wheel zooms the map (:706-716). A pinch arrives as `magnify`.
    public override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
            return super.scrollWheel(with: event)
        }
        zoom(exp(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)),
             at: convert(event.locationInWindow, from: nil))
    }

    public override func magnify(with event: NSEvent) {
        zoom(1 + Double(event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    func select(_ target: FleetFocus?) {
        state.selection = target == state.selection ? nil : target
        onSelect?(state.selection)
    }

    /// Opens or folds a stack. Its card stays where it is on screen and the rest makes room (`anchorFleetView`,
    /// :641-668); its tray fades in and its lifted cards fade over the same 200 ms.
    func toggleStack(_ id: String) {
        let fromView = shown, fromSize = bounds.size
        let fromFace = fleetLayout.stacks[id]?.face
        gliding(stack: id) {
            if state.expanded.contains(id) { state.expanded.remove(id) } else { state.expanded.insert(id) }
            guard let fromFace, let after = fleetLayout.stacks[id], fromSize.width > 0 else { return }
            let anchored = anchorFleetView(key: "", fromKey: "", fromHeld: nil, fromView: fromView, fromSize: fromSize,
                                           fromFace: FleetPoint(x: fromFace.x, y: fromFace.y), stack: after,
                                           layoutHeight: fleetLayout.height, bounds: 180...840)
            state.held = anchored.view
            state.heldHeight = anchored.height
        }
    }

    // MARK: Keys (:860-870, :1459-1476)

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { super.keyDown(with: event); return }
        let rects = fleetFocusRects(fleetLayout)
        let from = rects.has(state.roving) ? state.roving : fleetClientNodeId
        switch event.keyCode {
        case 123, 124, 125, 126:
            let direction: FleetDirection = [123: .left, 124: .right, 125: .down, 126: .up][event.keyCode]!
            if let next = nextFleetNode(rects, from: from, direction), let rect = rects[next] {
                state.roving = next
                reveal(rect)
                NSAccessibility.post(element: axElements[next] ?? self, notification: .focusedUIElementChanged)
            }
            return
        case 36, 76: activate(from); return
        case 49:
            if from != fleetClientNodeId, fleetLayout.nodes.has(from) { state.tick([from], toggle: true) }
            return
        case 53:
            if state.selection != nil { select(nil) } else { super.keyDown(with: event) }
            return
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomGliding(1.25)
        case "-": zoomGliding(0.8)
        case "0": fitView()
        default: super.keyDown(with: event)
        }
    }

    /// Enter on the roving item: a machine or stack opens its details; "and N more" opens its stack.
    func activate(_ id: String) {
        if fleetLayout.stacks.has(id) { select(.stack(id)) }
        else if id.hasPrefix("more:") { select(.stack(String(id.dropFirst(5)))) }
        else { select(.node(id)) }
    }

    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: Accessibility: one element per machine, stack and handle

    func label(_ id: String) -> String { graph.node(id)?.label ?? "" }

    func spokenLabel(_ id: String) -> String {
        if let stack = stacks.first(where: { $0.id == id }) { return stackSpoken(stack) }
        if id.hasPrefix("more:") { return "and \(hiddenCount(String(id.dropFirst(5)))) more" }
        guard let node = graph.node(id) else { return id }
        var text: String
        switch node.kind {
        case .client: text = node.label
        case .target:
            let incoming = graph.links.filter { $0.to == id }
            text = ([node.label, "known only through a link"]
                + incoming.map { "from \(label($0.from)): \(EnvironmentsMapText.linkSummary($0))" }).joined(separator: ", ")
        case .connect:
            text = "\(node.label), on your T3 Connect account, not added to this app. \(EnvironmentsMapText.connectAvailability(node.availability))"
        case .environment:
            let routes = graph.edges.filter { $0.kind == .route && $0.to == id }
            let status = statusText(node)
            let spoken = node.phase == .connected ? status : "\(status). Links unknown"
            text = ([node.label, spoken] + routes.map { "\($0.routeLabel ?? EnvironmentsMapText.routeKind($0.routeKind)): \(EnvironmentsMapText.routeState($0.state))" })
                .joined(separator: ", ")
        }
        return state.ticked.contains(id) ? "\(text), selected" : text
    }

    func statusText(_ node: FleetNode) -> String {
        let routes = graph.edges.filter { $0.kind == .route && $0.to == node.id }
        return EnvironmentsMapText.environmentStatus(node, awaitingApproval: model.awaitingApproval.contains(node.environmentId),
                                                     refused: !routes.isEmpty && routes.allSatisfy { $0.state == .refused },
                                                     linkCount: graph.links.filter { $0.from == node.id }.count)
    }

    func hiddenCount(_ stackId: String) -> Int {
        stacks.first { $0.id == stackId }.map { $0.memberIds.count - $0.shownIds.count } ?? 0
    }

    func stackRange(_ stack: FleetStack) -> String {
        stack.firstLabel == stack.lastLabel ? stack.firstLabel : "\(stack.firstLabel) … \(stack.lastLabel)"
    }

    func stackSummary(_ stack: FleetStack) -> String {
        if stack.group != nil { return stackRange(stack) }
        if stack.sources.count == 1 { return "\(LinkAccess.label(stack.sources[0].access)). \(stack.reachable) of \(stack.memberIds.count) reachable" }
        return "\(stack.reachable) of \(stack.memberIds.count) reachable, from \(stack.sources.count) environments"
    }

    /// The stack card's name (:1840-1851).
    func stackSpoken(_ stack: FleetStack) -> String {
        if let group = stack.group {
            return "\(EnvironmentsMapText.foldGroup(group)): \(stack.memberIds.count) environments with no links, \(stackRange(stack))"
        }
        return "\(stackRange(stack)), \(stack.memberIds.count) machines linked from \(stack.sources.map { label($0.sourceId) }.joined(separator: ", ")). \(stackSummary(stack))"
    }

    func rebuildAccessibility() {
        var next: [String: FleetAccessibilityElement] = [:]
        let rects = fleetFocusRects(fleetLayout)
        for id in rects.keys {
            let element = axElements[id] ?? FleetAccessibilityElement()
            element.canvas = self
            element.id = id
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            next[id] = element
            if let handle = fleetLayout.handles[id], graph.node(id)?.linking == .ready {
                let key = "handle:\(id)"
                let h = axElements[key] ?? FleetAccessibilityElement()
                h.canvas = self
                h.id = key
                h.setAccessibilityRole(.button)
                h.setAccessibilityParent(self)
                h.sceneRect = FleetRect(x: handle.x - 9, y: handle.y - 9, width: 18, height: 18)
                next[key] = h
            }
        }
        axElements = next
    }

    public override func accessibilityChildren() -> [Any]? {
        let rects = fleetFocusRects(fleetLayout)
        var out: [FleetAccessibilityElement] = []
        for (id, rect) in rects.entries {
            guard let element = axElements[id] else { continue }
            element.sceneRect = rect
            element.setAccessibilityLabel(spokenLabel(id))
            element.setAccessibilitySelected(state.selection?.id == id)
            out.append(element)
            if let handle = axElements["handle:\(id)"] {
                handle.setAccessibilityLabel("Link \(label(id)) to another machine")
                out.append(handle)
            }
        }
        return out
    }

    /// VoiceOver's press: the same as a click, or a press of the link handle.
    func press(_ id: String) {
        if id.hasPrefix("handle:") { onLink?(String(id.dropFirst(7)), nil); return }
        state.roving = id
        activate(id)
    }

    // MARK: Drawing (FleetScene, :1592-2276)

    public override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let paint = FleetPaint.current
        let v = shown
        cg.setFillColor(paint.canvas.cgColor(in: self))
        cg.fill(bounds)
        // `radial-gradient(circle, var(--border) 1px, transparent 1.5px)` every 24 scaled px (:1015-1019).
        if paint.dots.alphaComponent > 0 {
            let step = 24 * v.scale
            if step >= 6 {
                cg.setFillColor(paint.dots.cgColor(in: self))
                var x = v.x.truncatingRemainder(dividingBy: step) + step / 2 - step
                while x < Double(bounds.width) {
                    var y = v.y.truncatingRemainder(dividingBy: step) + step / 2 - step
                    while y < Double(bounds.height) {
                        cg.fillEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                        y += step
                    }
                    x += step
                }
            }
        }
        cg.saveGState()
        cg.translateBy(x: v.x, y: v.y)
        cg.scaleBy(x: v.scale, y: v.scale)
        FleetSceneRenderer(canvas: self, paint: paint, cg: cg).draw()
        cg.restoreGState()
        if case .box(let start, let current)? = drag {
            let r = NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
            let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
            cg.addPath(path)
            cg.setFillColor(paint.primary.withAlphaComponent(0.1).cgColor(in: self))
            cg.fillPath()
            cg.addPath(path)
            cg.setStrokeColor(paint.primary.cgColor(in: self))
            cg.setLineWidth(1)
            cg.strokePath()
        }
    }

    var dragState: Drag? { drag }
    var hoverFocus: FleetFocus? { hover }
}

/// One machine, stack card or link handle for VoiceOver.
@MainActor
final class FleetAccessibilityElement: NSAccessibilityElement {
    weak var canvas: EnvironmentsMapCanvasView?
    var id = ""
    var sceneRect = FleetRect(x: 0, y: 0, width: 0, height: 0)

    override func accessibilityFrame() -> NSRect {
        guard let canvas, let window = canvas.window else { return .zero }
        let local = canvas.toView(sceneRect).intersection(canvas.bounds)
        return window.convertToScreen(canvas.convert(local, to: nil))
    }

    override func isAccessibilityFocused() -> Bool {
        canvas?.state.roving == id && canvas?.window?.firstResponder === canvas
    }

    override func accessibilityPerformPress() -> Bool {
        canvas?.press(id)
        return true
    }
}

/// Draws one frame of the scene in scene coordinates.
@MainActor
struct FleetSceneRenderer {
    let canvas: EnvironmentsMapCanvasView
    let paint: FleetPaint
    let cg: CGContext

    var layout: FleetLayout { canvas.fleetLayout }
    var graph: FleetGraph { canvas.graph }

    func c(_ color: NSColor, _ alpha: CGFloat = 1) -> CGColor {
        (alpha == 1 ? color : color.withAlphaComponent(color.alphaComponent * alpha)).cgColor(in: canvas)
    }

    /// Names and labels: T3's 600, which Redesign's chrome draws at 500 (`RedesignTokens.Weight`).
    var heavy: NSFont.Weight { RedesignTokens.Weight.chrome(.semibold, dark: canvas.effectiveAppearance.isDark) }

    func text(_ s: String, _ rect: CGRect, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor,
              align: NSTextAlignment = .left, lines: Int = 1) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        style.minimumLineHeight = 16
        style.maximumLineHeight = 16
        let font = DSFont.ui(size, weight: weight)
        let attributed = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = CGFloat(lines) * 16
        let r = CGRect(x: rect.minX, y: rect.midY - min(height, attributed.boundingRect(with: CGSize(width: rect.width, height: height),
                                                                                         options: [.usesLineFragmentOrigin]).height) / 2,
                       width: rect.width, height: height)
        attributed.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
    }

    func box(_ r: CGRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?, dash: [CGFloat] = [], width: CGFloat = 1,
             alpha: CGFloat = 1, shadow: Bool = false) {
        let path = rounded(r.insetBy(dx: width / 2, dy: width / 2), radius)
        if let fill {
            cg.saveGState()
            if shadow { cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: c(.black, 0.05)) }
            cg.addPath(path)
            cg.setFillColor(c(fill, alpha))
            cg.fillPath()
            cg.restoreGState()
        }
        if let stroke {
            cg.addPath(path)
            cg.setStrokeColor(c(stroke, alpha))
            cg.setLineWidth(width)
            cg.setLineDash(phase: 0, lengths: dash)
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
        }
    }

    func stroke(_ d: String, color: NSColor, width: CGFloat, dash: [CGFloat] = [], alpha: CGFloat = 1) {
        cg.addPath(fleetCGPath(d))
        cg.setStrokeColor(c(color, alpha))
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: dash)
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
    }

    func arrow(_ points: [CGPoint], color: NSColor, alpha: CGFloat) {
        cg.move(to: points[0])
        for p in points.dropFirst() { cg.addLine(to: p) }
        cg.closePath()
        cg.setFillColor(c(color, alpha))
        cg.fillPath()
    }

    /// `ROUTE_STYLES` (:183-203).
    func routeStyle(_ state: FleetRouteState) -> (color: NSColor, alpha: CGFloat, width: CGFloat, dash: [CGFloat]) {
        switch state {
        case .inUse: (paint.inUse, 1, 1.75, [])
        case .standby: (paint.muted, 0.6, 1, [])
        case .trying: (paint.warning, 1, 1, [1, 4])
        case .down: (paint.muted, 0.6, 1, [4, 4])
        case .idle: (paint.muted, 0.4, 1, [4, 4])
        case .refused: (paint.destructive, 0.8, 1, [4, 4])
        case .offered: (paint.muted, 0.5, 1, [1, 4])
        }
    }

    /// `healthDash` (:164-168).
    func healthDash(_ health: PeerLinkHealth?) -> [CGFloat] {
        switch health {
        case .expired?: [1, 5]
        case .failing?: [8, 3, 1, 3]
        case .unreachable?: [5, 4]
        default: []
        }
    }

    /// `healthTone` (EnvironmentsMapDetails.tsx:48-52).
    func healthTone(_ health: PeerLinkHealth?) -> (NSColor, CGFloat) {
        switch health {
        case .expired?, .failing?: (paint.destructive, 1)
        case .unreachable?: (paint.muted, 1)
        case .reachable(_?)?: (paint.warning, 1)
        default: (paint.foreground, 0.7)
        }
    }

    func phaseDot(_ node: FleetNode) -> NSColor {
        guard node.kind == .environment, node.enabled else { return paint.muted.withAlphaComponent(0.4) }
        switch node.phase {
        case .connected: return paint.success
        case .connecting, .reconnecting: return paint.warning
        case .error: return paint.destructive
        default: return paint.muted.withAlphaComponent(0.4)
        }
    }

    func accessMeter(_ access: String, at origin: CGPoint, color: NSColor, alpha: CGFloat = 1) {
        let level = FleetAccessStroke.level(access)
        for index in 0..<5 {
            let r = CGRect(x: origin.x + CGFloat(index) * 4, y: origin.y + 8 - CGFloat(index) * 2, width: 3, height: 4 + CGFloat(index) * 2)
            cg.addPath(rounded(r, 0.75))
            cg.setFillColor(c(color, alpha * (index <= level ? 1 : 0.22)))
            cg.fillPath()
        }
    }

    func draw() {
        let lit = canvas.lit
        let matches = canvas.matches
        let focus = canvas.focus
        let selection = canvas.state.selection
        let pairs = fleetTwoWayLinks(graph)
        let linkDrag: (sourceId: String, at: NSPoint)? = {
            if case .link(let id, _, let at, true)? = canvas.dragState { return (id, at) }
            return nil
        }()
        func isSelected(_ f: FleetFocus) -> Bool { selection == f }
        let fadeLine: CGFloat = 0.25, fadeNode: CGFloat = 0.4

        // Column titles (:1594-1601).
        for column in layout.columns {
            text(EnvironmentsMapText.column(column.id), CGRect(x: column.x, y: 0, width: 200, height: 16), weight: .medium, color: paint.muted)
        }

        // Routes, the lit ones painted last (:1606-1623).
        let routeEdges = graph.edges.filter { $0.kind == .route }
        func routeLit(_ e: FleetEdge) -> Bool { lit == nil || lit!.edges.contains(e.id) }
        for edge in lit == nil ? routeEdges : jsSorted(routeEdges, { Double((routeLit($0) ? 1 : 0) - (routeLit($1) ? 1 : 0)) }) {
            guard let g = layout.routes[edge.id] else { continue }
            let s = routeStyle(edge.state)
            stroke(g.d, color: s.color, width: s.width, dash: s.dash, alpha: s.alpha * (routeLit(edge) ? 1 : fadeLine))
        }

        // Stack lines (:1624-1665).
        for stack in canvas.stacks {
            guard let g = layout.stacks[stack.id] else { continue }
            let onPath = lit == nil || stack.edgeIds.contains { lit!.edges.contains($0) }
            for line in g.lines {
                guard let access = line.access else {
                    let s = routeStyle(.idle)
                    stroke(line.d, color: s.color, width: s.width, dash: s.dash, alpha: s.alpha * (lit != nil && !onPath ? fadeLine : 1))
                    continue
                }
                let level = FleetAccessStroke.level(access)
                let mine = lit == nil || lit!.nodes.contains(line.sourceId ?? "")
                let alpha = (lit != nil && onPath && mine ? 1 : FleetAccessStroke.opacities[level]) * (lit != nil && !(onPath && mine) ? fadeLine : 1)
                stroke(line.d, color: paint.foreground, width: FleetAccessStroke.widths[level], alpha: alpha)
                if let a = line.arrow {
                    arrow([CGPoint(x: a.x - 8, y: a.y - 4.5), CGPoint(x: a.x, y: a.y), CGPoint(x: a.x - 8, y: a.y + 4.5)], color: paint.foreground, alpha: alpha)
                }
            }
        }

        // Links one by one, lit ones last (:1666-1709).
        let links = graph.links
        func linkLit(_ e: FleetEdge) -> Bool { isSelected(.edge(e.id)) || (lit?.edges.contains(e.id) ?? false) }
        for edge in lit == nil ? links : jsSorted(links, { Double((linkLit($0) ? 1 : 0) - (linkLit($1) ? 1 : 0)) }) {
            guard let g = layout.links[edge.id] else { continue }
            let selected = isSelected(.edge(edge.id))
            let level = FleetAccessStroke.level(edge.access)
            let groupAlpha = (linkLit(edge) ? 1 : FleetAccessStroke.opacities[level]) * (lit != nil && !linkLit(edge) ? fadeLine : 1)
            var parts: [(String, FleetArrow, PeerLinkHealth?)] = [(g.d, g.arrow, edge.health)]
            if let two = g.twoWay, let back = pairs[edge.id]?.back {
                parts = [(two.forward, g.arrow, edge.health), (two.back, two.backArrow, back.health)]
            }
            for (d, a, health) in parts {
                let (tone, toneAlpha) = selected ? (paint.primary, 1) : health.map(linkNeedsAttention) == true ? healthTone(health) : (paint.foreground, 1)
                stroke(d, color: tone, width: FleetAccessStroke.widths[level] + (selected ? 1 : 0), dash: healthDash(health), alpha: groupAlpha * toneAlpha)
                let dir = Double(a.dir)
                arrow([CGPoint(x: a.x - dir * 7, y: a.y - 4), CGPoint(x: a.x, y: a.y), CGPoint(x: a.x - dir * 7, y: a.y + 4)],
                      color: tone, alpha: groupAlpha * toneAlpha)
            }
        }

        // The dragged link (:1734-1743).
        if let linkDrag, let source = layout.handles[linkDrag.sourceId] {
            let p = canvas.toScene(linkDrag.at)
            stroke("M\(js(source.x)) \(js(source.y))C\(js(source.x + 48)) \(js(source.y)) \(js(p.x - 48)) \(js(p.y)) \(js(p.x)) \(js(p.y))",
                   color: paint.primary, width: 1.75, dash: [5, 4])
        }

        // Route names (:1744-1763).
        for edge in routeEdges {
            guard let pill = layout.routes[edge.id]?.pill else { continue }
            let on = routeLit(edge)
            var border = paint.pillBorder, textColor = paint.muted, weight = NSFont.Weight.regular, dash: [CGFloat] = []
            if on {
                switch edge.state {
                case .inUse: border = paint.inUse.withAlphaComponent(0.7); textColor = paint.foreground; weight = .medium
                case .trying: border = paint.warning.withAlphaComponent(0.6)
                case .down, .idle: dash = [3, 2]
                case .refused: dash = [3, 2]; border = paint.destructive.withAlphaComponent(0.6); textColor = paint.destructive
                case .offered: dash = [1, 2]
                case .standby: break
                }
            } else {
                border = border.withAlphaComponent(0.5); textColor = paint.muted.withAlphaComponent(0.45)
            }
            let r = pill.cgRect
            box(r, radius: r.height / 2, fill: paint.pill, stroke: border, dash: dash)
            text(edge.routeLabel ?? EnvironmentsMapText.routeKind(edge.routeKind), r.insetBy(dx: 6, dy: 0), weight: weight,
                 color: textColor, align: .center)
        }

        // Access names on links between environments (:1764-1816).
        for edge in links {
            guard let badge = layout.links[edge.id]?.badge else { continue }
            if badge.onDemand, !isSelected(.edge(edge.id)), focus != .edge(edge.id) { continue }
            let back = pairs[edge.id]?.back
            let health = back.map { worseLinkHealth(edge.health!, $0.health!) } ?? edge.health
            let on = lit == nil || lit!.edges.contains(edge.id)
            let label = LinkAccess.label(edge.access)
            let width = min(badge.rect.width, (label as NSString).size(withAttributes: [.font: DSFont.ui(11)]).width + 12 + 19 + 6 + (back == nil ? 0 : 18))
            let x = badge.side == 1 ? badge.rect.x : badge.rect.x + badge.rect.width - width
            let r = CGRect(x: x, y: badge.rect.y, width: width, height: badge.rect.height)
            let selected = isSelected(.edge(edge.id))
            let (tone, toneAlpha) = on ? healthTone(health) : (paint.muted, 0.45)
            let toneColor = selected ? paint.primary : tone.withAlphaComponent(tone.alphaComponent * toneAlpha)
            box(r, radius: r.height / 2, fill: paint.card, stroke: selected ? paint.primary : on ? paint.pillBorder : paint.pillBorder.withAlphaComponent(0.5),
                shadow: badge.onDemand && paint.shadow)
            var cx = r.minX + 6
            if back != nil {
                fleetDrawIcon(IconName.arrowUpDown.definition, in: CGRect(x: cx, y: r.midY - 6, width: 12, height: 12), color: c(toneColor), context: cg)
                cx += 18
            }
            accessMeter(edge.access, at: CGPoint(x: cx, y: r.midY - 6), color: toneColor, alpha: on ? 1 : 0.45)
            cx += 25
            text(label, CGRect(x: cx, y: r.minY, width: r.maxX - cx - 6, height: r.height), color: toneColor)
        }

        // Stacks (:1817-1993).
        for stack in canvas.stacks {
            guard let g = layout.stacks[stack.id] else { continue }
            let stackLit = lit == nil || stack.edgeIds.contains { lit!.edges.contains($0) }
            let dimmed = linkDrag != nil ? false : !stackLit || (matches != nil && !stack.memberIds.contains { matches!.contains($0) })
            cg.saveGState()
            cg.setAlpha(dimmed ? fadeNode : 1)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            drawStack(stack, g)
            cg.endTransparencyLayer()
            cg.restoreGState()
        }

        // Machines (:1994-2253).
        for node in graph.nodes {
            guard let rect = layout.nodes[node.id] else { continue }
            let dimmed: Bool = {
                if let linkDrag { return node.id != linkDrag.sourceId && fleetLinkAction(graph, canvas.stacks, selected: canvas.state.ticked, sourceId: linkDrag.sourceId, targetId: node.id) == nil }
                return (lit != nil && !lit!.nodes.contains(node.id)) || (matches != nil && !matches!.contains(node.id))
            }()
            cg.saveGState()
            cg.setAlpha(dimmed ? fadeNode : 1)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            drawNode(node, rect.cgRect, lit: lit)
            cg.endTransparencyLayer()
            cg.restoreGState()
            // Selected (`aria-pressed:ring-2 ring-primary ring-inset`) and keyboard focus (`focus-visible:ring-2 ring-ring`).
            let focused = canvas.window?.firstResponder === canvas && canvas.state.roving == node.id
            if isSelected(.node(node.id)) || focused {
                let radius = node.kind == .client ? rect.height / 2 : rect.height < 32 ? paint.smallRadius : paint.cardRadius
                box(rect.cgRect.insetBy(dx: 1, dy: 1), radius: radius - 1, fill: nil, stroke: isSelected(.node(node.id)) ? paint.primary : Themed.color(\.ring), width: 2)
            }
        }

        // Link handles (:2229-2250).
        for (id, handle) in layout.handles.entries where graph.node(id)?.linking == .ready {
            let r = CGRect(x: handle.x - 9, y: handle.y - 9, width: 18, height: 18)
            cg.setFillColor(c(paint.primary))
            cg.fillEllipse(in: r)
            fleetDrawIcon(IconName.plus.definition, in: r.insetBy(dx: 3, dy: 3), color: c(paint.primaryForeground), lineWidth: 2.5, context: cg)
            if canvas.window?.firstResponder === canvas, canvas.state.roving == "handle:\(id)" {
                cg.setStrokeColor(c(paint.foreground)); cg.setLineWidth(2); cg.strokeEllipse(in: r.insetBy(dx: 1, dy: 1))
            }
        }

        // Ticked machines (:2254-2270).
        for id in canvas.state.ticked {
            guard let rect = layout.nodes[id] else { continue }
            let r = rect.cgRect.insetBy(dx: -3, dy: -3)
            box(r, radius: paint.trayRadius, fill: paint.primary.withAlphaComponent(0.06), stroke: paint.primary, width: 2)
            let check = CGRect(x: r.minX - 8, y: r.minY - 8, width: 16, height: 16)
            cg.setFillColor(c(paint.primary)); cg.fillEllipse(in: check)
            fleetDrawIcon(IconName.check.definition, in: check.insetBy(dx: 3, dy: 3), color: c(paint.primaryForeground), lineWidth: 3, context: cg)
        }

        // The drag hint (:2271-2290).
        if let linkDrag {
            let p = canvas.toScene(linkDrag.at)
            let over = canvas.dropTarget(linkDrag.sourceId, linkDrag.at)
            let hint = over.map { EnvironmentsMapText.action(fleetLinkAction(graph, canvas.stacks, selected: canvas.state.ticked, sourceId: linkDrag.sourceId, targetId: $0), target: canvas.label($0)) }
                ?? "Drop on a machine to link"
            let w = (hint as NSString).size(withAttributes: [.font: DSFont.ui(11)]).width + 16
            let r = CGRect(x: p.x + 14, y: p.y + 14, width: w, height: 24)
            box(r, radius: paint.smallRadius, fill: Themed.color(\.popover), stroke: Themed.color(\.border), shadow: paint.shadow)
            text(hint, r.insetBy(dx: 8, dy: 0), color: Themed.color(\.popoverForeground))
        }
    }

    func drawStack(_ stack: FleetStack, _ g: FleetStackGeometry) {
        let face = g.face.cgRect
        let dashed: [CGFloat] = stack.group != nil ? [3, 2] : []
        // The lifted cards fade out as the stack opens and back in as it folds; the tray fades in (:1861-1886).
        let fading = canvas.glide?.stack == stack.id ? CGFloat(canvas.glideProgress) : 1
        let lifts = stack.expanded ? 1 - fading : fading
        if lifts > 0 {
            cg.saveGState()
            cg.setAlpha(lifts)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            for lift in [8.0, 4.0] {
                box(CGRect(x: face.minX + lift, y: face.minY - lift, width: face.width, height: face.height), radius: paint.cardRadius,
                    fill: paint.card, stroke: Themed.color(\.border), dash: dashed)
            }
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        if let tray = g.tray {
            cg.saveGState()
            cg.setAlpha(fading)
            box(tray.cgRect, radius: paint.trayRadius, fill: paint.foreground.withAlphaComponent(0.03), stroke: Themed.color(\.border, 0.7))
            cg.restoreGState()
        }
        let partial = fleetStackPartial(stack)
        let band: CGFloat = partial ? 20 : 0
        let holds: Bool = {
            guard case .node(let id)? = canvas.state.selection else { return false }
            return !layout.nodes.has(id) && stack.memberIds.contains(id)
        }()
        let selected = canvas.state.selection == .stack(stack.id)
        box(face, radius: paint.cardRadius, fill: paint.card, stroke: partial ? paint.warning.withAlphaComponent(0.6) : paint.foreground.withAlphaComponent(0.25), dash: dashed)
        let textRect = CGRect(x: face.minX + 10, y: face.minY, width: face.width - 10 - 32, height: face.height - band)
        let range = canvas.stackRange(stack)
        if let group = stack.group {
            let title = EnvironmentsMapText.foldGroup(group)
            let tw = min(textRect.width - 30, (title as NSString).size(withAttributes: [.font: DSFont.ui(12, weight: heavy)]).width)
            text(title, CGRect(x: textRect.minX, y: textRect.midY - 16, width: tw, height: 16), size: 12, weight: heavy, color: paint.foreground)
            let count = "\(stack.memberIds.count)"
            let cw = (count as NSString).size(withAttributes: [.font: DSFont.ui(11)]).width + 12
            let chip = CGRect(x: textRect.minX + tw + 6, y: textRect.midY - 16, width: cw, height: 16)
            box(chip, radius: 8, fill: paint.mutedFill, stroke: nil)
            text(count, chip, color: paint.muted, align: .center)
            text(range, CGRect(x: textRect.minX, y: textRect.midY, width: textRect.width, height: 16), color: paint.muted)
        } else {
            text(range, CGRect(x: textRect.minX, y: textRect.midY - 16, width: textRect.width, height: 16), size: 12, weight: heavy, color: paint.foreground)
            var x = textRect.minX
            if stack.sources.count == 1 {
                accessMeter(stack.sources[0].access, at: CGPoint(x: x, y: textRect.midY + 2), color: paint.foreground.withAlphaComponent(0.7))
                x += 25
            }
            let count = stack.memberIds.count
            text(count == 1 ? "1 machine" : "\(count) machines", CGRect(x: x, y: textRect.midY, width: textRect.maxX - x, height: 16), color: paint.muted)
        }
        if partial {
            let r = CGRect(x: face.minX + 1, y: face.maxY - band, width: face.width - 2, height: band - 1)
            cg.saveGState()
            cg.addPath(rounded(face.insetBy(dx: 1, dy: 1), paint.cardRadius - 1)); cg.clip()
            cg.setFillColor(c(paint.warning, 0.16)); cg.fill(r)
            cg.setFillColor(c(paint.warning, 0.3)); cg.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1))
            cg.restoreGState()
            fleetDrawIcon(IconName.triangleAlert.definition, in: CGRect(x: r.minX + 9, y: r.midY - 6, width: 12, height: 12), color: c(paint.warning), context: cg)
            let label = stack.reachable == 0 ? "None reachable" : "\(stack.reachable) reachable"
            let lw = (label as NSString).size(withAttributes: [.font: DSFont.ui(11, weight: heavy)]).width
            text(label, CGRect(x: r.minX + 27, y: r.minY, width: lw + 1, height: r.height), weight: heavy, color: Themed.color(\.warningForeground))
            let bar = CGRect(x: r.minX + 27 + lw + 6, y: r.midY - 2, width: max(0, r.maxX - 10 - (r.minX + 27 + lw + 6)), height: 4)
            box(bar, radius: 2, fill: paint.warning.withAlphaComponent(0.25), stroke: nil)
            box(CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(stack.reachable) / CGFloat(max(1, stack.memberIds.count)), height: 4),
                radius: 2, fill: paint.warning, stroke: nil)
        }
        if holds || selected { box(face.insetBy(dx: 1, dy: 1), radius: paint.cardRadius - 1, fill: nil, stroke: paint.primary, width: 2) }
        let toggle = CGRect(x: face.minX + face.width - 28, y: face.minY + (face.height - band) / 2 - 11, width: 22, height: 22)
        fleetDrawIcon(stack.expanded ? EnvironmentsMapIcons.fold : EnvironmentsMapIcons.unfold, in: toggle.insetBy(dx: 4, dy: 4), color: c(paint.muted), context: cg)
        if let more = g.more {
            box(more.cgRect, radius: paint.smallRadius, fill: nil, stroke: paint.foreground.withAlphaComponent(0.3), dash: [3, 2])
            text("and \(canvas.hiddenCount(stack.id)) more", more.cgRect.insetBy(dx: 8, dy: 0), color: paint.muted)
        }
    }

    func drawNode(_ node: FleetNode, _ r: CGRect, lit: (nodes: Set<String>, edges: Set<String>)?) {
        switch node.kind {
        case .client:
            box(r, radius: r.height / 2, fill: paint.card, stroke: paint.foreground.withAlphaComponent(0.25))
            fleetDrawIcon(EnvironmentsMapIcons.appWindow, in: CGRect(x: r.minX + 14, y: r.midY - 8, width: 16, height: 16), color: c(paint.muted), context: cg)
            text(node.label, CGRect(x: r.minX + 38, y: r.minY, width: r.width - 38 - 14, height: r.height), size: 12, weight: heavy, color: paint.foreground)
        case .target:
            let incoming = graph.links.filter { $0.to == node.id }
            let focused = incoming.filter { lit?.edges.contains($0.id) == true }
            let shown = incoming.count == 1 ? incoming.first : focused.count == 1 ? focused.first : nil
            let first = shown ?? jsSorted(incoming) { Double(linkTroubleRank($0.health!) - linkTroubleRank($1.health!)) }.first
            let compact = r.height < 32
            let health = first?.health
            let (border, dash): (NSColor, [CGFloat]) = switch health {
            case .expired?: (paint.destructive.withAlphaComponent(0.7), [1, 2])
            case .failing?: (paint.destructive.withAlphaComponent(0.7), [])
            case .unreachable?: (paint.foreground.withAlphaComponent(0.35), [3, 2])
            case .reachable(_?)?: (paint.warning.withAlphaComponent(0.7), [])
            default: (Themed.color(\.border), [])
            }
            box(r, radius: compact ? paint.smallRadius : paint.cardRadius, fill: paint.card, stroke: border, dash: dash)
            let pad: CGFloat = compact ? 8 : 10
            drawHealthGlyph(health, center: CGPoint(x: r.minX + pad + 6, y: r.midY))
            let textX = r.minX + pad + 12 + 8
            let meter: CGFloat = compact || shown == nil ? 0 : 19 + 8
            if compact {
                text(node.label, CGRect(x: textX, y: r.minY, width: r.maxX - pad - textX, height: r.height), color: paint.foreground.withAlphaComponent(0.9))
                return
            }
            let w = r.maxX - pad - meter - textX
            text(node.label, CGRect(x: textX, y: r.midY - 16, width: w, height: 16), size: 12, weight: .medium, color: paint.foreground.withAlphaComponent(0.9))
            if let first, let h = first.health {
                let plain: Bool = { if case .reachable(nil) = h { return true }; return false }()
                let line = shown == nil ? (incoming.count == 1 ? "1 link in" : "\(incoming.count) links in")
                    : plain ? LinkAccess.label(first.access) : "\(LinkAccess.label(first.access)) · \(EnvironmentsMapText.health(h))"
                let (tone, a) = plain ? (paint.muted, CGFloat(1)) : healthTone(h)
                text(line, CGRect(x: textX, y: r.midY, width: w, height: 16), color: tone.withAlphaComponent(tone.alphaComponent * a))
            }
            if let shown { accessMeter(shown.access, at: CGPoint(x: r.maxX - pad - 19, y: r.midY - 6), color: paint.foreground.withAlphaComponent(0.7)) }
        case .connect where r.height >= 32:
            box(r, radius: paint.cardRadius, fill: paint.card.withAlphaComponent(0.6), stroke: paint.foreground.withAlphaComponent(0.3), dash: [3, 2])
            fleetDrawIcon(IconName.cloud.definition, in: CGRect(x: r.minX + 10, y: r.midY - 8, width: 16, height: 16), color: c(paint.muted), context: cg)
            text(node.label, CGRect(x: r.minX + 34, y: r.midY - 16, width: r.width - 44, height: 16), size: 12, weight: heavy, color: paint.foreground)
            text("Not added · \(EnvironmentsMapText.connectAvailability(node.availability))", CGRect(x: r.minX + 34, y: r.midY, width: r.width - 44, height: 16), color: paint.muted)
        default:
            if r.height < 32 {
                // Inside an open group of environments: its name and state (:2088-2117).
                box(r, radius: paint.smallRadius, fill: paint.card, stroke: paint.foreground.withAlphaComponent(0.25), dash: [3, 2])
                cg.setFillColor(c(phaseDot(node))); cg.fillEllipse(in: CGRect(x: r.minX + 8, y: r.midY - 4, width: 8, height: 8))
                text(node.label, CGRect(x: r.minX + 22, y: r.minY, width: r.width - 30, height: r.height), color: paint.foreground.withAlphaComponent(0.9))
                return
            }
            let dimmed = !node.enabled || node.phase == .unsupported
            let over: Bool = { if case .link(let src, _, let at, true)? = canvas.dragState { return src != node.id && canvas.dropTarget(src, at) == node.id }; return false }()
            box(r, radius: paint.cardRadius, fill: paint.card, stroke: over ? paint.primary : dimmed ? paint.dimBorder : paint.cardBorder,
                dash: dimmed ? [3, 2] : [], shadow: paint.shadow)
            let icon = CGRect(x: r.minX + 10, y: r.midY - 12, width: 24, height: 24)
            box(icon, radius: paint.smallRadius, fill: paint.mutedFill, stroke: nil, alpha: dimmed ? 0.6 : 1)
            fleetDrawIcon(EnvironmentMachineIcon.definition(node.machine ?? "server"), in: icon.insetBy(dx: 5, dy: 5),
                          color: c(paint.foreground, dimmed ? 0.48 : 0.8), context: cg)
            let dot = CGRect(x: icon.maxX - 6, y: icon.maxY - 6, width: 10, height: 10)
            cg.setFillColor(c(paint.card)); cg.fillEllipse(in: dot)
            cg.setFillColor(c(phaseDot(node))); cg.fillEllipse(in: dot.insetBy(dx: 2, dy: 2))
            let textX = icon.maxX + 8
            let w = r.maxX - 10 - 6 - textX
            let twoLines = node.label.utf16.count > fleetCard.nameLine
            let status = canvas.statusText(node)
            let statusColor = node.outgoing == "error" && node.phase == .connected ? paint.destructive : paint.muted
            let alpha: CGFloat = dimmed ? 0.7 : 1
            let nameHeight: CGFloat = twoLines ? 32 : 16
            let top = r.midY - (nameHeight + 16) / 2
            text(node.label, CGRect(x: textX, y: top, width: w, height: nameHeight), size: 12, weight: heavy,
                 color: Themed.color(\.cardForeground).withAlphaComponent(alpha), lines: twoLines ? 2 : 1)
            text(status, CGRect(x: textX, y: top + nameHeight, width: w, height: 16), color: statusColor.withAlphaComponent(alpha))
        }
    }

    /// `HealthGlyph` (EnvironmentsMapDetails.tsx:98-112).
    func drawHealthGlyph(_ health: PeerLinkHealth?, center: CGPoint) {
        guard let health else { return }
        let (tone, a) = healthTone(health)
        let icon = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        switch health {
        case .expired: fleetDrawIcon(IconName.x.definition, in: icon, color: c(tone, a), context: cg)
        case .failing: fleetDrawIcon(IconName.triangleAlert.definition, in: icon, color: c(tone, a), context: cg)
        case .unreachable:
            cg.setStrokeColor(c(paint.muted)); cg.setLineWidth(1); cg.strokeEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        case .reachable(nil):
            cg.setFillColor(c(paint.success)); cg.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        case .reachable:
            fleetDrawIcon(EnvironmentsMapIcons.clockAlert, in: icon, color: c(tone, a), context: cg)
        }
    }
}
