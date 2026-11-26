import CoreGraphics
import Foundation
import T3Protocol

// The Environments map's graph and layout engine, a line-by-line port of T3 5258
// apps/web/src/components/settings/environmentsMap.logic.ts. Line numbers below cite that file.
// It is pure and deterministic: the same graph always gives the same boxes and paths, and
// `EnvironmentsMapLogicTests` checks it against T3's own output for the setups in its tests.

/// A map that keeps insertion order, as JS's `Map` does. The layout iterates several maps and the
/// order decides which lane or row an item gets.
public struct FleetOrderedMap<Key: Hashable, Value> {
    public private(set) var keys: [Key] = []
    private var storage: [Key: Value] = [:]
    public init() {}
    public subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    public func has(_ key: Key) -> Bool { storage[key] != nil }
    public var count: Int { keys.count }
    public var values: [Value] { keys.map { storage[$0]! } }
    public var entries: [(key: Key, value: Value)] { keys.map { ($0, storage[$0]!) } }
    mutating func push<E>(_ key: Key, _ element: E) where Value == [E] {
        if storage[key] == nil { keys.append(key); storage[key] = [element] } else { storage[key]!.append(element) }
    }
}

public let fleetClientNodeId = "client"
public func fleetEnvironmentNodeId(_ environmentId: String) -> String { "env:\(environmentId)" }
public func fleetMoreNodeId(_ stackId: String) -> String { "more:\(stackId)" }

/// What this client knows of the links an environment holds to others (:18-25).
public enum FleetOutgoingLinks: Equatable, Sendable {
    case loaded([PeerLinkSummary])
    case loading
    case error(String)
    /// Connected, but linked environments is off or unsupported there.
    case off
    /// Not connected, or not allowed to read: it may hold links this client cannot see.
    case unknown

    public var state: String {
        switch self {
        case .loaded: "loaded"
        case .loading: "loading"
        case .error: "error"
        case .off: "off"
        case .unknown: "unknown"
        }
    }
}

public struct FleetRouteInput: Equatable, Sendable {
    public var id: String
    /// `ConnectionRouteKind`: relay, loopback, lan, tailnet, vpn, public or ssh.
    public var kind: String
    public var label: String?
    public init(id: String, kind: String, label: String? = nil) { self.id = id; self.kind = kind; self.label = label }
}

/// `EnvironmentConnectionPhase` (client-runtime/src/connection/presentation.ts:11-18).
public enum FleetPhase: String, Sendable, Equatable {
    case available, offline, connecting, reconnecting, connected, error, unsupported
}

public struct FleetEnvironmentInput: Equatable, Sendable {
    public var environmentId: String
    public var label: String
    public var machine: String?
    public var phase: FleetPhase
    /// Switched on in this client. A switched-off environment is saved but never dialled.
    public var enabled: Bool
    /// Saved routes, preferred first.
    public var routes: [FleetRouteInput]
    public var activeRouteId: String?
    public var refusedRouteIds: [String]
    public var outgoing: FleetOutgoingLinks
    public var offersLinks: Bool
    public var canWriteAccess: Bool
    public var hasLinkAddress: Bool

    public init(environmentId: String, label: String, machine: String? = "server", phase: FleetPhase = .connected,
                enabled: Bool = true, routes: [FleetRouteInput] = [], activeRouteId: String? = nil,
                refusedRouteIds: [String] = [], outgoing: FleetOutgoingLinks = .unknown, offersLinks: Bool = false,
                canWriteAccess: Bool = false, hasLinkAddress: Bool = false) {
        self.environmentId = environmentId; self.label = label; self.machine = machine; self.phase = phase
        self.enabled = enabled; self.routes = routes; self.activeRouteId = activeRouteId
        self.refusedRouteIds = refusedRouteIds; self.outgoing = outgoing; self.offersLinks = offersLinks
        self.canWriteAccess = canWriteAccess; self.hasLinkAddress = hasLinkAddress
    }
}

/// A machine on the user's T3 Connect account that this client has not saved (:56-61).
public struct FleetConnectMachineInput: Equatable, Sendable {
    public enum Availability: String, Sendable { case checking, online, offline, error }
    public var environmentId: String
    public var label: String
    public var machine: String?
    public var availability: Availability
    public init(environmentId: String, label: String, machine: String? = "server", availability: Availability) {
        self.environmentId = environmentId; self.label = label; self.machine = machine; self.availability = availability
    }
}

/// How a route is doing, from what the client knows (:67-78). It never probes a route.
public enum FleetRouteState: String, Sendable, Equatable {
    case inUse = "in-use", standby, trying, down, idle, refused, offered
}

/// Why an environment can or cannot be the source of a new link (:80).
public enum FleetLinking: String, Sendable, Equatable { case ready, disconnected, off, forbidden }

public struct FleetNode: Equatable, Sendable {
    public enum Kind: String, Sendable { case client, environment, connect, target }
    public var id: String
    public var kind: Kind
    public var label: String
    public var environmentId: String = ""
    public var machine: String?
    // environment
    public var phase: FleetPhase = .available
    public var enabled = false
    public var routeCount = 0
    public var outgoing = "unknown"
    public var outgoingError: String?
    public var linking: FleetLinking = .disconnected
    /// The client can mint a pairing code there itself, so linking to it asks for none.
    public var mintable = false
    public var canWriteAccess = false
    public var hasLinkAddress = false
    // connect
    public var availability: FleetConnectMachineInput.Availability?
    // target: where the first environment linking to it reaches it.
    public var address: String?
}

public struct FleetEdge: Equatable, Sendable {
    public enum Kind: String, Sendable { case route, link }
    public var id: String
    public var kind: Kind
    public var from: String
    public var to: String
    // route
    public var routeId = ""
    public var routeKind = ""
    public var routeLabel: String?
    public var state: FleetRouteState = .idle
    // link
    public var sourceEnvironmentId = ""
    public var link: PeerLinkSummary?
    public var health: PeerLinkHealth?

    var access: String { link?.access ?? "" }
}

public struct FleetGraph: Equatable, Sendable {
    public var nodes: [FleetNode]
    public var edges: [FleetEdge]
    public func node(_ id: String) -> FleetNode? { nodes.first { $0.id == id } }
    public var links: [FleetEdge] { edges.filter { $0.kind == .link } }
}

extension PeerLinkHealth {
    /// `health.kind` in T3: the case without its payload.
    public var kindName: String {
        switch self {
        case .reachable: "reachable"
        case .unreachable: "unreachable"
        case .failing: "failing"
        case .expired: "expired"
        }
    }
    var isReachable: Bool { if case .reachable = self { true } else { false } }
}

// MARK: - Graph (:152-280)

func fleetRouteState(_ environment: FleetEnvironmentInput, _ routeId: String) -> FleetRouteState {
    if environment.refusedRouteIds.contains(routeId) { return .refused }
    if !environment.enabled { return .idle }
    switch environment.phase {
    case .connected: return routeId == environment.activeRouteId ? .inUse : .standby
    case .connecting: return .trying
    case .unsupported, .available: return .idle
    case .reconnecting, .error, .offline: return .down
    }
}

func fleetLinking(_ environment: FleetEnvironmentInput) -> FleetLinking {
    if environment.phase != .connected { return .disconnected }
    if !environment.offersLinks { return .off }
    return environment.canWriteAccess ? .ready : .forbidden
}

/// One node per machine however often it is named; each saved route is its own edge (:181-280).
public func buildFleetGraph(clientLabel: String, environments input: [FleetEnvironmentInput],
                            connectMachines: [FleetConnectMachineInput] = [], now: Date) -> FleetGraph {
    var nodes = FleetOrderedMap<String, FleetNode>()
    nodes[fleetClientNodeId] = FleetNode(id: fleetClientNodeId, kind: .client, label: clientLabel)
    var edges = FleetOrderedMap<String, FleetEdge>()
    var seen = Set<String>()
    let environments = input.filter { seen.insert($0.environmentId).inserted }
    for environment in environments {
        let id = fleetEnvironmentNodeId(environment.environmentId)
        var node = FleetNode(id: id, kind: .environment, label: environment.label, environmentId: environment.environmentId,
                             machine: environment.machine)
        node.phase = environment.phase
        node.enabled = environment.enabled
        node.routeCount = environment.routes.count
        node.outgoing = environment.outgoing.state
        if case .error(let message) = environment.outgoing { node.outgoingError = message }
        node.linking = fleetLinking(environment)
        node.mintable = environment.phase == .connected && environment.canWriteAccess && environment.hasLinkAddress
        node.canWriteAccess = environment.canWriteAccess
        node.hasLinkAddress = environment.hasLinkAddress
        nodes[id] = node
        for route in environment.routes {
            let edgeId = "route:\(id):\(route.id)"
            if edges.has(edgeId) { continue }
            var edge = FleetEdge(id: edgeId, kind: .route, from: fleetClientNodeId, to: id)
            edge.routeId = route.id
            edge.routeKind = route.kind
            edge.routeLabel = route.label
            edge.state = fleetRouteState(environment, route.id)
            edges[edgeId] = edge
        }
    }
    for machine in connectMachines {
        let id = fleetEnvironmentNodeId(machine.environmentId)
        if nodes.has(id) { continue }
        var node = FleetNode(id: id, kind: .connect, label: machine.label, environmentId: machine.environmentId,
                             machine: machine.machine)
        node.availability = machine.availability
        nodes[id] = node
        var edge = FleetEdge(id: "route:\(id):offer", kind: .route, from: fleetClientNodeId, to: id)
        edge.routeId = "offer"
        edge.routeKind = "relay"
        edge.state = .offered
        edges[edge.id] = edge
    }
    for environment in environments {
        guard case .loaded(let links) = environment.outgoing else { continue }
        let from = fleetEnvironmentNodeId(environment.environmentId)
        for link in links {
            let to = fleetEnvironmentNodeId(link.environmentId)
            let id = "link:\(from)>\(to)"
            if to == from || edges.has(id) { continue }
            if !nodes.has(to) {
                var node = FleetNode(id: to, kind: .target, label: link.label, environmentId: link.environmentId)
                node.address = link.urls.first
                nodes[to] = node
            }
            var edge = FleetEdge(id: id, kind: .link, from: from, to: to)
            edge.sourceEnvironmentId = environment.environmentId
            edge.link = link
            edge.health = PeerLinkHealth(link, now: now)
            edges[id] = edge
        }
    }
    return FleetGraph(nodes: nodes.values, edges: edges.values)
}

/// Two machines linked to each other at the same access, drawn as one line (:286-309).
public struct FleetTwoWayLink: Equatable, Sendable {
    public let forward: FleetEdge
    public let back: FleetEdge
}

public func fleetTwoWayLinks(_ graph: FleetGraph) -> [String: FleetTwoWayLink] {
    var links = FleetOrderedMap<String, FleetEdge>()
    for edge in graph.links { links[edge.id] = edge }
    var pairs: [String: FleetTwoWayLink] = [:]
    for forward in links.values {
        guard let back = links["link:\(forward.to)>\(forward.from)"], back.access == forward.access,
              pairs[forward.id] == nil else { continue }
        let pair = FleetTwoWayLink(forward: forward, back: back)
        pairs[forward.id] = pair
        pairs[back.id] = pair
    }
    return pairs
}

/// The link whose line stands for `edgeId`: itself, or the other half of its two-way link (:311).
public func fleetDrawnLinkId(_ pairs: [String: FleetTwoWayLink], _ edgeId: String) -> String {
    pairs[edgeId]?.forward.id ?? edgeId
}

/// Worst first: expired, failing, not answering, expiring soon, fine (:315).
public func linkTroubleRank(_ health: PeerLinkHealth) -> Int {
    switch health {
    case .expired: 0
    case .failing: 1
    case .unreachable: 2
    case .reachable(let days): days == nil ? 4 : 3
    }
}

public func worseLinkHealth(_ left: PeerLinkHealth, _ right: PeerLinkHealth) -> PeerLinkHealth {
    linkTroubleRank(right) < linkTroubleRank(left) ? right : left
}

public func linkNeedsAttention(_ health: PeerLinkHealth) -> Bool {
    if case .reachable(nil) = health { return false }
    return true
}

/// `linkBackOffer` (client-runtime/src/linkBatch.ts:107-140), with only the outcome the map needs.
public enum LinkBackOffer: Equatable, Sendable {
    case offered
    case blocked(String)
    case hidden

    public struct Target { var connected: Bool; var offersLinks: Bool; var writable: Bool; var links: [PeerLinkSummary]? }
    public struct Source { var environmentId: String; var connected: Bool; var writable: Bool; var urls: [String] }

    public static func evaluate(target: Target?, source: Source) -> LinkBackOffer {
        guard let target, target.connected, source.connected else { return .hidden }
        if !target.offersLinks { return .blocked("target_links_off") }
        if !target.writable { return .blocked("target_no_access") }
        if !source.writable { return .blocked("source_no_access") }
        if source.urls.isEmpty { return .blocked("source_no_address") }
        guard let links = target.links,
              !links.contains(where: { $0.environmentId == source.environmentId && $0.status != .expired })
        else { return .hidden }
        return .offered
    }
}

/// Whether the map offers to link a one-way link's target back to its source (:334-363).
public func fleetLinkBackOffered(_ graph: FleetGraph, _ edge: FleetEdge) -> Bool {
    guard let source = graph.node(edge.from), source.kind == .environment,
          let target = graph.node(edge.to), target.kind == .environment else { return false }
    let offer = LinkBackOffer.evaluate(
        target: .init(connected: target.phase == .connected, offersLinks: target.linking != .off,
                      writable: target.canWriteAccess,
                      links: target.outgoing == "loaded"
                          ? graph.links.filter { $0.from == target.id }.compactMap(\.link) : nil),
        source: .init(environmentId: source.environmentId, connected: source.phase == .connected,
                      writable: source.canWriteAccess, urls: source.hasLinkAddress ? [""] : []))
    return offer == .offered
}

/// The setup in two numbers; `links` is nil when the total is not known (:365-384).
public func fleetSummary(_ graph: FleetGraph) -> (machines: Int, links: Int?, loading: Bool) {
    let connected = graph.nodes.filter { $0.kind == .environment && $0.phase == .connected }
    let loading = connected.contains { $0.outgoing == "loading" }
    let known = !loading && connected.contains { $0.outgoing == "loaded" } && !connected.contains { $0.outgoing == "error" }
    return (graph.nodes.count - 1, known ? graph.links.count : nil, loading)
}

// MARK: - Stacks (:389-543)

/// `AuthMcpClientAccess.literals` (contracts/src/auth.ts:270-276).
let fleetAccessOrder = ["read-only", "approval-required", "auto-accept-edits", "auto", "full-access"]
public let fleetLanePitch: Double = 12

/// `new Intl.Collator("en", { numeric: true, sensitivity: "base" })`.
func fleetLabelCompare(_ left: String, _ right: String) -> Int {
    switch left.compare(right, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                        range: nil, locale: Locale(identifier: "en")) {
    case .orderedAscending: -1
    case .orderedSame: 0
    case .orderedDescending: 1
    }
}

public enum FleetFoldGroup: String, Sendable { case offline, off, update, notAdded = "not-added" }

/// Machines drawn as a single node, each still listed in the details (:400-426).
public struct FleetStack: Equatable, Sendable {
    public enum Kind: String, Sendable { case targets, environments }
    public struct Source: Equatable, Sendable { public var sourceId: String; public var access: String }
    public var id: String
    public var kind: Kind
    public var sources: [Source]
    public var group: FleetFoldGroup?
    public var memberIds: [String]
    public var edgeIds: [String]
    public var reachable: Int
    public var firstLabel: String
    public var lastLabel: String
    public var expanded: Bool
    public var shownIds: [String]
}

let fleetStackMin = 5
public let fleetFoldEnvironmentsOver = 12
let fleetFoldMin = 3
public let fleetStackShownMax = 24

func fleetFoldGroup(_ node: FleetNode) -> FleetFoldGroup? {
    if node.kind == .connect { return .notAdded }
    if node.kind != .environment { return nil }
    if node.phase == .unsupported { return .update }
    if !node.enabled { return .off }
    // One still dialling stays a card: it is about to change, and the user is watching it.
    return node.phase == .offline || node.phase == .error || node.phase == .available ? .offline : nil
}

let fleetFoldOrder: [FleetFoldGroup] = [.offline, .off, .update, .notAdded]

public func fleetStacks(_ graph: FleetGraph, expanded: Set<String>) -> [FleetStack] {
    var byId: [String: FleetNode] = [:]
    var order: [String: Int] = [:]
    for (index, node) in graph.nodes.enumerated() { byId[node.id] = node; order[node.id] = index }
    func label(_ id: String) -> String { byId[id]?.label ?? "" }
    func byLabel(_ left: String, _ right: String) -> Double {
        let c = fleetLabelCompare(label(left), label(right))
        return Double(c != 0 ? c : (left < right ? -1 : 1))
    }
    let links = graph.links
    var incoming = FleetOrderedMap<String, [FleetEdge]>()
    for link in links where byId[link.to]?.kind == .target { incoming.push(link.to, link) }
    var groups = FleetOrderedMap<String, [(id: String, links: [FleetEdge])]>()
    for (id, unsorted) in incoming.entries {
        let into = jsSorted(unsorted) { Double(order[$0.from]! - order[$1.from]!) }
        let key = "stack:" + into.map { "\($0.from):\($0.access)" }.joined(separator: "|")
        groups.push(key, (id, into))
    }
    func make(_ id: String, _ kind: FleetStack.Kind, _ memberIds: [String], sources: [FleetStack.Source],
              group: FleetFoldGroup?, edgeIds: [String], reachable: Int) -> FleetStack {
        FleetStack(id: id, kind: kind, sources: sources, group: group, memberIds: memberIds, edgeIds: edgeIds,
                   reachable: reachable, firstLabel: label(memberIds[0]), lastLabel: label(memberIds.last!),
                   expanded: expanded.contains(id),
                   shownIds: memberIds.count > fleetStackShownMax ? Array(memberIds.prefix(fleetStackShownMax)) : memberIds)
    }
    var stacks: [FleetStack] = []
    for (id, unsorted) in groups.entries {
        if unsorted.count < fleetStackMin { continue }
        let members = jsSorted(unsorted) { byLabel($0.id, $1.id) }
        stacks.append(make(id, .targets, members.map(\.id),
                           sources: members[0].links.map { .init(sourceId: $0.from, access: $0.access) },
                           group: nil, edgeIds: members.flatMap { $0.links.map(\.id) },
                           reachable: members.filter { $0.links.allSatisfy { $0.health?.isReachable == true } }.count))
    }
    let hosts = graph.nodes.filter { $0.kind == .environment || $0.kind == .connect }
    if hosts.count <= fleetFoldEnvironmentsOver { return stacks }
    let linked = Set(links.flatMap { [$0.from, $0.to] })
    var routesOf = FleetOrderedMap<String, [String]>()
    for edge in graph.edges where edge.kind == .route { routesOf.push(edge.to, edge.id) }
    for group in fleetFoldOrder {
        let memberIds = jsSorted(hosts.filter { !linked.contains($0.id) && fleetFoldGroup($0) == group }.map(\.id), byLabel)
        if memberIds.count < fleetFoldMin { continue }
        stacks.append(make("fold:\(group.rawValue)", .environments, memberIds, sources: [], group: group,
                           edgeIds: memberIds.flatMap { routesOf[$0] ?? [] }, reachable: 0))
    }
    return stacks
}

public enum FleetFocus: Equatable, Hashable, Sendable {
    case node(String), edge(String), stack(String)
    public var id: String { switch self { case .node(let id), .edge(let id), .stack(let id): id } }
}

/// What a node reaches and what reaches it, one hop only, plus how this client gets there (:560-597).
public func fleetNeighborhood(_ graph: FleetGraph, _ stacks: [FleetStack], _ focus: FleetFocus)
    -> (nodes: Set<String>, edges: Set<String>) {
    var nodes = Set<String>()
    var edges = Set<String>()
    var sources = Set<String>()
    var stackEdges = Set<String>()
    if case .stack(let id) = focus, let stack = stacks.first(where: { $0.id == id }) { stackEdges = Set(stack.edgeIds) }
    var pair: FleetTwoWayLink?
    if case .edge(let id) = focus { pair = fleetTwoWayLinks(graph)[id] }
    for edge in graph.edges {
        let touches: Bool
        switch focus {
        case .stack: touches = stackEdges.contains(edge.id)
        case .edge(let id): touches = edge.id == id || edge.id == pair?.forward.id || edge.id == pair?.back.id
        case .node(let id): touches = edge.from == id || edge.to == id
        }
        if !touches { continue }
        edges.insert(edge.id)
        nodes.insert(edge.from); nodes.insert(edge.to)
        if edge.kind == .link {
            if case .node(let id) = focus { if edge.to == id { sources.insert(edge.from) } } else { sources.insert(edge.from) }
        }
    }
    for edge in graph.edges where edge.kind == .route && sources.contains(edge.to) {
        edges.insert(edge.id)
        nodes.insert(edge.from)
    }
    if case .node(let id) = focus, graph.nodes.contains(where: { $0.id == id }) { nodes.insert(id) }
    return (nodes, edges)
}

/// What linking `sourceId` to `targetId` would take, or why the map does not offer it (:599-633).
public enum FleetLinkOffer: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case notAnEnvironment = "not-an-environment", sameMachine = "same-machine"
        case sourceDisconnected = "source-disconnected", sourceOff = "source-off", sourceForbidden = "source-forbidden"
    }
    public enum Path: String, Sendable { case codeLess = "code-less", pairingCode = "pairing-code", throughLink = "through-link" }
    public struct Through: Equatable, Sendable { public var viaEnvironmentId: String; public var environmentId: String; public var label: String }
    public enum Target: Equatable, Sendable {
        case machine(environmentId: String)
        case address(String?, through: Through?)
    }
    public struct Link: Equatable, Sendable {
        public var sourceEnvironmentId: String
        public var path: Path
        public var renews: Bool
        public var target: Target
    }
    case unavailable(Reason)
    case link(Link)
}

public func fleetLinkOffer(_ graph: FleetGraph, _ sourceId: String, _ targetId: String) -> FleetLinkOffer {
    guard let source = graph.node(sourceId), source.kind == .environment,
          let target = graph.node(targetId), target.kind != .client else { return .unavailable(.notAnEnvironment) }
    if source.id == target.id { return .unavailable(.sameMachine) }
    switch source.linking {
    case .ready: break
    case .disconnected: return .unavailable(.sourceDisconnected)
    case .off: return .unavailable(.sourceOff)
    case .forbidden: return .unavailable(.sourceForbidden)
    }
    let renews = graph.edges.contains {
        $0.kind == .link && $0.from == source.id && $0.to == target.id && $0.health != .expired
    }
    if target.kind == .target {
        // Only a full-access link may mint a code there, and only a session that manages access on
        // the machine holding that link may ask it to.
        let via = graph.edges.first { edge in
            edge.kind == .link && edge.to == target.id && edge.from != source.id && edge.access == "full-access"
                && edge.health?.isReachable == true
                && graph.nodes.contains { $0.id == edge.from && $0.kind == .environment && $0.phase == .connected && $0.canWriteAccess }
        }
        return .link(.init(sourceEnvironmentId: source.environmentId, path: via == nil ? .pairingCode : .throughLink,
                           renews: renews,
                           target: .address(target.address, through: via.map {
                               .init(viaEnvironmentId: $0.sourceEnvironmentId, environmentId: target.environmentId, label: target.label)
                           })))
    }
    return .link(.init(sourceEnvironmentId: source.environmentId,
                       path: target.kind == .environment && target.mintable ? .codeLess : .pairingCode,
                       renews: renews, target: .machine(environmentId: target.environmentId)))
}

/// Some of a stack's linked machines do not answer: its card grows a line to say how many do (:701).
public func fleetStackPartial(_ stack: FleetStack) -> Bool {
    stack.kind == .targets && stack.reachable < stack.memberIds.count
}

/// Changes exactly when the layout would (:705-717).
public func fleetShapeKey(_ graph: FleetGraph, _ stacks: [FleetStack]) -> String {
    (graph.nodes.map { "\($0.kind.rawValue)\u{0}\($0.id)\u{0}\($0.label)" }
        + graph.edges.map { $0.kind == .link ? "\($0.id)\u{0}\($0.access)" : $0.id }
        + stacks.map {
            "\($0.id)\u{0}\($0.expanded)\u{0}\(fleetStackPartial($0))\u{0}\($0.kind == .environments ? $0.memberIds.joined(separator: ",") : "")"
        }).joined(separator: "\n")
}

// MARK: - Geometry types (:719-801)

public struct FleetRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    func intersects(_ b: FleetRect) -> Bool { x < b.x + b.width && b.x < x + width && y < b.y + b.height && b.y < y + height }
}

public struct FleetPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct FleetRouteGeometry: Equatable, Sendable {
    public var d: String
    /// Where the route's kind is named, on the wire just before the environment.
    public var pill: FleetRect
}

/// Room for a link's access in words; `onDemand` is shown only while its link is in focus.
public struct FleetLinkBadge: Equatable, Sendable {
    public var rect: FleetRect
    public var side: Int
    public var onDemand: Bool
}

public struct FleetArrow: Equatable, Sendable {
    public var x: Double, y: Double, dir: Int
}

public struct FleetLinkGeometry: Equatable, Sendable {
    public struct TwoWay: Equatable, Sendable { public var backArrow: FleetArrow; public var forward: String; public var back: String }
    public var d: String
    public var arrow: FleetArrow
    public var twoWay: TwoWay?
    public var badge: FleetLinkBadge?
}

public struct FleetStackLine: Equatable, Sendable {
    public var sourceId: String?
    public var access: String?
    public var d: String
    public var arrow: FleetPoint?
}

public struct FleetStackGeometry: Equatable, Sendable {
    public var rect: FleetRect
    public var face: FleetRect
    public var lines: [FleetStackLine]
    public var tray: FleetRect?
    public var more: FleetRect?
}

public enum FleetColumn: String, Sendable { case client, environments, targets }

public struct FleetLayout {
    public var nodes: FleetOrderedMap<String, FleetRect>
    public var stacks: FleetOrderedMap<String, FleetStackGeometry>
    public var routes: FleetOrderedMap<String, FleetRouteGeometry>
    public var links: FleetOrderedMap<String, FleetLinkGeometry>
    public var handles: FleetOrderedMap<String, FleetPoint>
    public var columns: [(id: FleetColumn, x: Double)]
    public var width: Double
    public var height: Double
}

// MARK: - Measures (:803-918)

let fleetHeader: Double = 28
let fleetClientHeight: Double = 44
let fleetPillHeight: Double = 18
public let fleetRoutePitch: Double = 22
let fleetPillOverhang: Double = 9
let fleetCard = (height: 56.0, twoLines: 68.0, nameLine: 13)
let fleetRouteEntry = (pitch: 4.0, spread: 10.0)
let fleetOfferHeight: Double = 44
let fleetTargetHeight: Double = 44
let fleetStackSize = (height: 50.0, partial: 20.0, lift: 8.0)

struct FleetMetrics: Equatable {
    var app: Double, wire: Double, pill: Double, pillGap: Double, card: Double, target: Double
    var linkRun: Double, laneFirst: Double, betweenFirst: Double, betweenLast: Double

    static let regular = FleetMetrics(app: 136, wire: 72, pill: 82, pillGap: 20, card: 164, target: 188,
                                      linkRun: 92, laneFirst: 24, betweenFirst: 16, betweenLast: 6)
    static let compact = FleetMetrics(app: 124, wire: 28, pill: 72, pillGap: 14, card: 148, target: 146,
                                      linkRun: 36, laneFirst: 18, betweenFirst: 14, betweenLast: 4)
    static let roomy = FleetMetrics(app: 148, wire: 112, pill: 88, pillGap: 26, card: 180, target: 220,
                                    linkRun: 132, laneFirst: 24, betweenFirst: 16, betweenLast: 6)

    static func mix(_ from: FleetMetrics, _ to: FleetMetrics, _ t: Double) -> FleetMetrics {
        func at(_ key: KeyPath<FleetMetrics, Double>) -> Double { (from[keyPath: key] + (to[keyPath: key] - from[keyPath: key]) * t).rounded(.down) }
        return FleetMetrics(app: at(\.app), wire: at(\.wire), pill: at(\.pill), pillGap: at(\.pillGap), card: at(\.card),
                            target: at(\.target), linkRun: at(\.linkRun), laneFirst: at(\.laneFirst),
                            betweenFirst: at(\.betweenFirst), betweenLast: at(\.betweenLast))
    }
}

let fleetChip = (width: 124.0, height: 26.0)
let fleetChipGap: Double = 6
let fleetFramePad: Double = 8
let fleetTrayGap: Double = 4
let fleetChipMinWidth: Double = 60
let fleetGroupGap: Double = 28
let fleetBayGap: Double = 12
let fleetLaneStep: Double = 14
let fleetLaneClearance: Double = 10
let fleetArrowLength: Double = 6
let fleetLinkRunMin: Double = 20
let fleetEntryPitch: Double = 14
let fleetBetweenStep: Double = 14
let fleetLinkPort = (first: 10.0, pitch: fleetLanePitch, margin: 4.0)
let fleetCorner: Double = 8
let fleetBadge = (width: 120.0, height: 20.0, overhang: 5.0, gap: 4.0)

// MARK: - Paths (:921-958)

/// A number as JS's `String(n)` writes it, so paths match T3's byte for byte.
func js(_ value: Double) -> String {
    if value == 0 { return "0" }
    if value == value.rounded(), abs(value) < 1e21 { return String(Int64(value)) }
    return "\(value)"
}

func jsSign(_ value: Double) -> Double { value > 0 ? 1 : value < 0 ? -1 : 0 }

/// Horizontal, a vertical run at `viaX`, then horizontal again, with rounded turns (:921-937).
func fleetElbowPath(_ x0: Double, _ y0: Double, _ viaX: Double, _ x1: Double, _ y1: Double) -> String {
    let dy = y1 - y0
    if abs(dy) < 1 { return "M\(js(x0)) \(js(y0))H\(js(x1))" }
    let r = min(fleetCorner, abs(dy) / 2, abs(viaX - x0), abs(x1 - viaX))
    let sy = jsSign(dy), inX = jsSign(viaX - x0), outX = jsSign(x1 - viaX)
    return "M\(js(x0)) \(js(y0))H\(js(viaX - inX * r))Q\(js(viaX)) \(js(y0)) \(js(viaX)) \(js(y0 + sy * r))"
        + "V\(js(y1 - sy * r))Q\(js(viaX)) \(js(y1)) \(js(viaX + outX * r)) \(js(y1))H\(js(x1))"
}

/// `elbowPath` cut halfway along its vertical run (:939-951).
func fleetElbowHalves(_ x0: Double, _ y0: Double, _ viaX: Double, _ x1: Double, _ y1: Double) -> (String, String) {
    let dy = y1 - y0
    let mid = (y0 + y1) / 2
    let r = min(fleetCorner, abs(dy) / 2, abs(viaX - x0), abs(x1 - viaX))
    let sy = jsSign(dy), inX = jsSign(viaX - x0), outX = jsSign(x1 - viaX)
    return ("M\(js(x0)) \(js(y0))H\(js(viaX - inX * r))Q\(js(viaX)) \(js(y0)) \(js(viaX)) \(js(y0 + sy * r))V\(js(mid))",
            "M\(js(viaX)) \(js(mid))V\(js(y1 - sy * r))Q\(js(viaX)) \(js(y1)) \(js(viaX + outX * r)) \(js(y1))H\(js(x1))")
}

/// Straight to `fanX`, then a curve (:953-958).
func fleetSCurve(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ fanX: Double? = nil) -> String {
    let fanX = fanX ?? x0
    let reach = max(min(24, (x1 - fanX) * 0.6), (x1 - fanX) / 2)
    let lead = fanX > x0 ? "H\(js(fanX))" : ""
    return "M\(js(x0)) \(js(y0))\(lead)C\(js(fanX + reach)) \(js(y0)) \(js(x1 - reach)) \(js(y1)) \(js(x1)) \(js(y1))"
}

/// Reads the absolute M, H, V, Q and C paths the layout writes into a `CGPath`.
public func fleetCGPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var numbers: [Double] = []
    var command: Character?
    var current = CGPoint.zero
    func flush() {
        guard let command else { return }
        let n = numbers.map { CGFloat($0) }
        switch command {
        case "M" where n.count >= 2: current = CGPoint(x: n[0], y: n[1]); path.move(to: current)
        case "H" where n.count >= 1: current = CGPoint(x: n[0], y: current.y); path.addLine(to: current)
        case "V" where n.count >= 1: current = CGPoint(x: current.x, y: n[0]); path.addLine(to: current)
        case "Q" where n.count >= 4:
            current = CGPoint(x: n[2], y: n[3]); path.addQuadCurve(to: current, control: CGPoint(x: n[0], y: n[1]))
        case "C" where n.count >= 6:
            current = CGPoint(x: n[4], y: n[5])
            path.addCurve(to: current, control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]))
        default: break
        }
        numbers = []
    }
    var token = ""
    func endToken() { if let v = Double(token) { numbers.append(v) }; token = "" }
    for ch in d {
        if "MHVQC".contains(ch) { endToken(); flush(); command = ch }
        else if ch == " " || ch == "," { endToken() }
        else { token.append(ch) }
    }
    endToken(); flush()
    return path
}

// MARK: - Sorting

/// `Array.prototype.toSorted` as V8 runs it. Below 64 items V8's TimSort is one run made by binary
/// insertion, which this copies exactly, so comparators that are not a total order (the lane
/// order's crossing count) give T3's result.
/// ponytail: larger arrays use a plain stable sort, which matches only for consistent comparators. Port
/// TimSort's merges if a map ever puts 64 lanes into one sort.
func jsSorted<T>(_ items: [T], _ compare: (T, T) -> Double) -> [T] {
    var a = items
    let n = a.count
    if n < 2 { return a }
    if n >= 64 {
        return a.enumerated().sorted { l, r in
            let c = compare(l.element, r.element)
            return c != 0 ? c < 0 : l.offset < r.offset
        }.map(\.element)
    }
    // CountAndMakeRun
    var run = 2
    let descending = compare(a[1], a[0]) < 0
    var previous = a[1]
    var index = 2
    while index < n {
        let order = compare(a[index], previous)
        if descending ? order >= 0 : order < 0 { break }
        previous = a[index]; run += 1; index += 1
    }
    if descending { a[0..<run].reverse() }
    // BinaryInsertionSort(0, run, n)
    var start = run
    while start < n {
        let pivot = a[start]
        var left = 0, right = start
        while left < right {
            let mid = left + ((right - left) >> 1)
            if compare(pivot, a[mid]) < 0 { right = mid } else { left = mid + 1 }
        }
        var p = start
        while p > left { a[p] = a[p - 1]; p -= 1 }
        a[left] = pivot
        start += 1
    }
    return a
}

// MARK: - Layout (:960-1703)

func fleetFrameColumns(_ count: Int) -> Int { max(2, min(4, Int(ceil((Double(count) / 2.2).squareRoot())))) }
func fleetFrameCells(_ stack: FleetStack) -> Int { stack.shownIds.count + (stack.memberIds.count > stack.shownIds.count ? 1 : 0) }
func fleetTrayWidth(_ columns: Int) -> Double { fleetFramePad * 2 + Double(columns) * (fleetChip.width + fleetChipGap) - fleetChipGap }
func fleetTrayHeight(_ stack: FleetStack, _ columns: Int) -> Double {
    fleetTrayGap + fleetFramePad * 2 + ceil(Double(fleetFrameCells(stack)) / Double(columns)) * (fleetChip.height + fleetChipGap) - fleetChipGap
}

struct FleetTrayRoom { var width: Double = .infinity; var bayX: Double? }

func fleetFitPadding(_ canvasWidth: Double) -> Double { canvasWidth < 720 ? 16 : 28 }
let fleetMinScale = 0.3
let fleetMaxScale = 2.0
let fleetFitMaxScale = 1.15
public let fleetFitLegibleScale = 0.85

/// The map at the width it is given (:1044-1062). With no width it is laid out at its regular measures.
public func layoutFleetGraph(_ graph: FleetGraph, _ stacks: [FleetStack] = [], canvasWidth: Double? = nil) -> FleetLayout {
    // The measures follow the map with every stack closed, so opening one moves no column.
    let anyOpen = stacks.contains { $0.expanded }
    let closed = anyOpen ? stacks.map { var s = $0; s.expanded = false; return s } : stacks
    let (metrics, layout) = fitFleetMetrics(graph, closed, canvasWidth)
    if !anyOpen { return layout }
    let bayX = layout.columns.first { $0.id == .targets }?.x
    guard let canvasWidth else { return layoutFleetGraphAt(graph, stacks, metrics, FleetTrayRoom(bayX: bayX)) }
    let room = canvasWidth - fleetFitPadding(canvasWidth) * 2
    let shown = room / min(fleetFitMaxScale, room / layout.width)
    return layoutFleetGraphAt(graph, stacks, metrics, FleetTrayRoom(width: shown - (bayX ?? 0), bayX: bayX))
}

func fitFleetMetrics(_ graph: FleetGraph, _ stacks: [FleetStack], _ canvasWidth: Double?) -> (FleetMetrics, FleetLayout) {
    let regular = layoutFleetGraphAt(graph, stacks, .regular)
    guard let canvasWidth else { return (.regular, regular) }
    let room = canvasWidth - fleetFitPadding(canvasWidth) * 2
    let narrow = room < regular.width
    let wanted = narrow ? room : room / fleetFitMaxScale
    if !narrow && wanted <= regular.width { return (.regular, regular) }
    let limit: FleetMetrics = narrow ? .compact : .roomy
    let end = layoutFleetGraphAt(graph, stacks, limit)
    if narrow ? end.width >= wanted : end.width <= wanted { return (limit, end) }
    let t = (wanted - regular.width) / (end.width - regular.width)
    let metrics = FleetMetrics.mix(.regular, limit, t)
    return (metrics, layoutFleetGraphAt(graph, stacks, metrics))
}

private struct BayEntry { let key: String; let from: String }

private struct BayItem {
    let isStack: Bool
    let targetId: String
    let stack: FleetStack?
    let label: String
    let access: String
    let entries: [BayEntry]
    var itemId: String { stack?.id ?? targetId }
}

private enum ColumnEntry {
    case host(FleetNode)
    case fold(FleetStack)
    var id: String { switch self { case .host(let n): n.id; case .fold(let s): s.id } }
}

private final class FleetRow {
    var entries: [ColumnEntry]
    let items: [BayItem]
    init(entries: [ColumnEntry], items: [BayItem]) { self.entries = entries; self.items = items }
}

private final class FleetLane {
    let id: String
    let from: Double
    let to: Double
    let branches: [Double]
    var index = 0
    init(id: String, from: Double, to: Double, branches: [Double]) { self.id = id; self.from = from; self.to = to; self.branches = branches }
}

private func stackLineKey(_ stackId: String, _ sourceId: String) -> String { "\(stackId)<\(sourceId)" }

func layoutFleetGraphAt(_ graph: FleetGraph, _ stacks: [FleetStack], _ metrics: FleetMetrics,
                        _ room: FleetTrayRoom = FleetTrayRoom()) -> FleetLayout {
    var nodes = FleetOrderedMap<String, FleetRect>()
    var stackGeometry = FleetOrderedMap<String, FleetStackGeometry>()
    var routes = FleetOrderedMap<String, FleetRouteGeometry>()
    var linkGeometry = FleetOrderedMap<String, FleetLinkGeometry>()
    var handles = FleetOrderedMap<String, FleetPoint>()
    let links = graph.links
    var byId: [String: FleetNode] = [:]
    for node in graph.nodes { byId[node.id] = node }
    let folds = stacks.filter { $0.kind == .environments }
    let folded = Set(folds.flatMap(\.memberIds))
    let hosts = graph.nodes.filter { ($0.kind == .environment || $0.kind == .connect) && !folded.contains($0.id) }
    var hostIndex: [String: Int] = [:]
    for (index, host) in hosts.enumerated() { hostIndex[host.id] = index }
    func indexOf(_ id: String) -> Int { hostIndex[id] ?? 0 }
    var routesOf = FleetOrderedMap<String, [FleetEdge]>()
    for edge in graph.edges where edge.kind == .route { routesOf.push(edge.to, edge) }
    func accessRank(_ access: String) -> Int { -(fleetAccessOrder.firstIndex(of: access) ?? -1) }
    func labelOf(_ id: String) -> String { byId[id]?.label ?? "" }

    let stacked = Set(stacks.flatMap(\.edgeIds))
    var incomingOf = FleetOrderedMap<String, [FleetEdge]>()
    for link in links where byId[link.to]?.kind == .target && !stacked.contains(link.id) { incomingOf.push(link.to, link) }
    var items: [BayItem] = []
    for stack in stacks where stack.kind == .targets {
        items.append(BayItem(isStack: true, targetId: "", stack: stack, label: stack.firstLabel, access: stack.sources[0].access,
                             entries: stack.sources.map { BayEntry(key: stackLineKey(stack.id, $0.sourceId), from: $0.sourceId) }))
    }
    for (targetId, unsorted) in incomingOf.entries {
        let incoming = jsSorted(unsorted) { Double(indexOf($0.from) - indexOf($1.from)) }
        items.append(BayItem(isStack: false, targetId: targetId, stack: nil, label: labelOf(targetId), access: incoming[0].access,
                             entries: incoming.map { BayEntry(key: $0.id, from: $0.from) }))
    }
    func byName(_ left: BayItem, _ right: BayItem) -> Double {
        let c = fleetLabelCompare(left.label, right.label)
        return Double(c != 0 ? c : (left.itemId < right.itemId ? -1 : 1))
    }
    var bayOf = FleetOrderedMap<String, [BayItem]>()
    var bandOf = FleetOrderedMap<String, [BayItem]>()
    for item in jsSorted(items.filter { $0.entries.count == 1 }, { left, right in
        let s = Double((right.isStack ? 1 : 0) - (left.isStack ? 1 : 0))
        if s != 0 { return s }
        let a = Double(accessRank(left.access) - accessRank(right.access))
        return a != 0 ? a : byName(left, right)
    }) {
        bayOf.push(item.entries[0].from, item)
    }
    // Below the middle host of those linking to it: the shortest total reach, with ties going up.
    func meanSource(_ item: BayItem) -> Double {
        Double(item.entries.reduce(0) { $0 + indexOf($1.from) }) / Double(item.entries.count)
    }
    for item in jsSorted(items.filter { $0.entries.count > 1 }, { left, right in
        let m = meanSource(left) - meanSource(right)
        return m != 0 ? m : byName(left, right)
    }) {
        bandOf.push(item.entries[(item.entries.count - 1) / 2].from, item)
    }

    // A machine with no links rides beside a shared row instead of pushing the hosts further apart.
    let linked = Set(links.flatMap { [$0.from, $0.to] })
    var rows: [FleetRow] = []
    var shared: FleetRow?
    for host in hosts {
        let entry = ColumnEntry.host(host)
        if let shared, !linked.contains(host.id) { shared.entries.append(entry); continue }
        rows.append(FleetRow(entries: [entry], items: bayOf[host.id] ?? []))
        if let band = bandOf[host.id] {
            let row = FleetRow(entries: [], items: band)
            shared = row
            rows.append(row)
        } else {
            shared = nil
        }
    }
    for stack in folds {
        let entry = ColumnEntry.fold(stack)
        if let shared { shared.entries.append(entry) } else { rows.append(FleetRow(entries: [entry], items: [])) }
    }

    // Links between environments: shorter ones take the lanes nearer the cards.
    func reach(_ link: FleetEdge) -> Int { abs(indexOf(link.to) - indexOf(link.from)) }
    func low(_ link: FleetEdge) -> Int { min(indexOf(link.from), indexOf(link.to)) }
    func high(_ link: FleetEdge) -> Int { max(indexOf(link.from), indexOf(link.to)) }
    let pairs = fleetTwoWayLinks(graph)
    func twoWay(_ link: FleetEdge) -> Bool { pairs[link.id] != nil }
    let between = jsSorted(links.filter {
        hostIndex[$0.from] != nil && hostIndex[$0.to] != nil && fleetDrawnLinkId(pairs, $0.id) == $0.id
    }) { left, right in
        let r = Double(reach(left) - reach(right))
        return r != 0 ? r : (left.id < right.id ? -1 : 1)
    }
    var betweenLanes: [[FleetEdge]] = []
    var betweenLane: [String: Int] = [:]
    for link in between {
        var index = 0
        while index < betweenLanes.count,
              betweenLanes[index].contains(where: { max(low($0), low(link)) < min(high($0), high(link)) }) {
            index += 1
        }
        betweenLane[link.id] = index
        if index == betweenLanes.count { betweenLanes.append([]) }
        betweenLanes[index].append(link)
    }
    var leaves = Set<String>()
    var arrivalsOf = FleetOrderedMap<String, [FleetEdge]>()
    for link in between {
        let down = Int(jsSign(Double(indexOf(link.to) - indexOf(link.from))))
        if twoWay(link) { arrivalsOf.push("\(link.from):\(down)", link) } else { leaves.insert("\(link.from):\(down)") }
        arrivalsOf.push("\(link.to):\(-down)", link)
    }
    for key in arrivalsOf.keys {
        arrivalsOf[key] = jsSorted(arrivalsOf[key]!) { Double(betweenLane[$1.id]! - betweenLane[$0.id]!) }
    }
    func routesInto(_ hostId: String) -> Int { routesOf[hostId]?.count ?? 0 }
    func cardHeight(_ host: FleetNode) -> Double {
        host.kind == .connect ? fleetOfferHeight : host.label.utf16.count > fleetCard.nameLine ? fleetCard.twoLines : fleetCard.height
    }
    func routeEntryPitch(_ hostId: String) -> Double {
        routesInto(hostId) < 2 ? 0 : min(fleetRouteEntry.pitch, fleetRouteEntry.spread / Double(routesInto(hostId) - 1))
    }
    func routesExtent(_ hostId: String) -> Double { Double(max(1, routesInto(hostId)) - 1) * routeEntryPitch(hostId) * 0.5 }
    func linkPortPitch(_ host: FleetNode, _ side: Int) -> Double {
        let key = "\(host.id):\(side)"
        let ports = (leaves.contains(key) ? 1 : 0) + (arrivalsOf[key]?.count ?? 0)
        let room = cardHeight(host) / 2 - fleetLinkPort.margin - routesExtent(host.id) - fleetLinkPort.first
        return ports < 2 ? 0 : min(fleetLinkPort.pitch, room / Double(ports - 1))
    }
    func pillsHeight(_ hostId: String) -> Double { Double(max(1, routesInto(hostId)) - 1) * fleetRoutePitch + fleetPillHeight }
    let foldFace = (width: metrics.card - fleetStackSize.lift, height: fleetStackSize.height)
    let closedWidth = metrics.target + fleetStackSize.lift
    func trayShape(_ stack: FleetStack) -> (columns: Int, width: Double) {
        if stack.kind == .environments { return (1, metrics.card) }
        let wanted = fleetFrameColumns(fleetFrameCells(stack))
        let fitting = ((room.width - fleetFramePad * 2 + fleetChipGap) / (fleetChip.width + fleetChipGap)).rounded(.down)
        if fitting >= 2 {
            let columns = fitting.isFinite ? min(wanted, Int(fitting)) : wanted
            return (columns, max(closedWidth, fleetTrayWidth(columns)))
        }
        let width = max(closedWidth, min(room.width, fleetTrayWidth(2)))
        return ((width - fleetFramePad * 2 - fleetChipGap) / 2 < fleetChipMinWidth ? 1 : 2, width)
    }
    func entryHeight(_ entry: ColumnEntry, _ open: Bool) -> Double {
        switch entry {
        case .host(let host): return max(cardHeight(host), pillsHeight(host.id) - fleetPillOverhang * 2)
        case .fold(let stack):
            return fleetStackSize.height + fleetStackSize.lift
                + (open && stack.expanded ? fleetTrayHeight(stack, trayShape(stack).columns) : 0)
        }
    }
    func faceHeight(_ item: BayItem, _ least: Double) -> Double { max(least, 20 + Double(item.entries.count - 1) * fleetEntryPitch) }
    func itemSize(_ item: BayItem, _ open: Bool) -> (width: Double, height: Double) {
        guard let stack = item.stack else { return (metrics.target, faceHeight(item, fleetTargetHeight)) }
        let closed = (width: closedWidth,
                      height: faceHeight(item, fleetStackSize.height + (fleetStackPartial(stack) ? fleetStackSize.partial : 0)) + fleetStackSize.lift)
        if !open || !stack.expanded { return closed }
        let shape = trayShape(stack)
        return (shape.width, closed.height + fleetTrayHeight(stack, shape.columns))
    }
    func fillTray(_ stack: FleetStack, _ face: FleetRect) -> FleetRect? {
        let (columns, width) = trayShape(stack)
        let chipWidth = (width - fleetFramePad * 2 - Double(columns - 1) * fleetChipGap) / Double(columns)
        func cell(_ index: Int) -> FleetRect {
            FleetRect(x: face.x + fleetFramePad + Double(index % columns) * (chipWidth + fleetChipGap),
                      y: face.y + face.height + fleetTrayGap + fleetFramePad + Double(index / columns) * (fleetChip.height + fleetChipGap),
                      width: chipWidth, height: fleetChip.height)
        }
        for (index, memberId) in stack.shownIds.enumerated() { nodes[memberId] = cell(index) }
        return stack.memberIds.count > stack.shownIds.count ? cell(stack.shownIds.count) : nil
    }
    func openRects(_ stack: FleetStack, _ face: FleetRect) -> (rect: FleetRect, tray: FleetRect) {
        let (columns, width) = trayShape(stack)
        let height = fleetTrayHeight(stack, columns)
        return (FleetRect(x: face.x, y: face.y, width: width, height: face.height + height),
                FleetRect(x: face.x, y: face.y + face.height + fleetTrayGap, width: width, height: height - fleetTrayGap))
    }

    let pillX = metrics.app + metrics.wire
    let cardX = pillX + metrics.pill + metrics.pillGap
        + (betweenLanes.isEmpty ? 0 : metrics.betweenLast + Double(betweenLanes.count - 1) * fleetBetweenStep + metrics.betweenFirst)
    let cardRight = cardX + metrics.card

    struct Placed { let item: BayItem; let y: Double; let size: (width: Double, height: Double); let closedHeight: Double }
    var placed: [Placed] = []
    var column: [(entry: ColumnEntry, center: Double)] = []
    var restCenters: [Double] = []
    var anchors: [String: Double] = [:]
    var y = fleetHeader
    var cardFloor = -Double.infinity
    var bayFloor = -Double.infinity
    for row in rows {
        let heights = row.entries.map { entryHeight($0, false) }
        let cardsHeight = heights.reduce(-fleetGroupGap) { $0 + $1 + fleetGroupGap }
        let sizes = row.items.map { itemSize($0, false) }
        let bayHeight = sizes.reduce(-fleetBayGap) { $0 + $1.height + fleetBayGap }
        let rowHeight = max(cardsHeight, bayHeight)
        var restY = y + (rowHeight - cardsHeight) / 2
        for (index, entry) in row.entries.enumerated() {
            let rest = heights[index]
            let cardY = max(restY, cardFloor)
            switch entry {
            case .host(let host):
                let anchor = cardY + rest / 2
                let own = cardHeight(host)
                nodes[host.id] = FleetRect(x: cardX, y: anchor - own / 2, width: metrics.card, height: own)
                anchors[host.id] = anchor
                if host.kind == .environment { handles[host.id] = FleetPoint(x: cardRight, y: anchor) }
                column.append((entry, anchor))
                restCenters.append(restY + rest / 2)
            case .fold(let stack):
                let face = FleetRect(x: cardX, y: cardY + fleetStackSize.lift, width: foldFace.width, height: foldFace.height)
                let open = stack.expanded ? openRects(stack, face) : nil
                stackGeometry[stack.id] = FleetStackGeometry(
                    rect: open?.rect ?? FleetRect(x: cardX, y: cardY, width: metrics.card, height: rest), face: face, lines: [],
                    tray: open?.tray, more: stack.expanded ? fillTray(stack, face) : nil)
                column.append((entry, face.y + face.height / 2))
                restCenters.append(restY + fleetStackSize.lift + face.height / 2)
            }
            cardFloor = cardY + entryHeight(entry, true) + fleetGroupGap
            restY += rest + fleetGroupGap
        }
        var restItemY = y + (rowHeight - bayHeight) / 2
        for (index, item) in row.items.enumerated() {
            let itemY = max(restItemY, bayFloor)
            let size = itemSize(item, true)
            placed.append(Placed(item: item, y: itemY, size: size, closedHeight: sizes[index].height))
            bayFloor = itemY + size.height + fleetBayGap
            restItemY += sizes[index].height + fleetBayGap
        }
        y += rowHeight + fleetGroupGap
    }
    var height = max(fleetHeader + fleetClientHeight, y - fleetGroupGap, cardFloor - fleetGroupGap, bayFloor - fleetBayGap)

    func centerOf(_ id: String) -> Double { anchors[id]! }
    func faceOf(_ item: BayItem, _ itemY: Double, _ closedHeight: Double) -> (top: Double, height: Double) {
        item.isStack ? (itemY + fleetStackSize.lift, closedHeight - fleetStackSize.lift) : (itemY, closedHeight)
    }
    var entryY: [String: Double] = [:]
    for p in placed {
        let face = faceOf(p.item, p.y, p.closedHeight)
        for (index, entry) in p.item.entries.enumerated() {
            entryY[entry.key] = face.top + face.height / 2 + (Double(index) - Double(p.item.entries.count - 1) / 2) * fleetEntryPitch
        }
    }
    func portY(_ link: FleetEdge, _ hostId: String) -> Double {
        let side = Int(jsSign(Double(indexOf(link.from == hostId ? link.to : link.from) - indexOf(hostId))))
        let key = "\(hostId):\(side)"
        let port = link.from == hostId && !twoWay(link)
            ? 0 : (leaves.contains(key) ? 1 : 0) + (arrivalsOf[key]!.firstIndex { $0.id == link.id } ?? -1)
        return centerOf(hostId) + Double(side)
            * (routesExtent(hostId) + fleetLinkPort.first + Double(port) * linkPortPitch(byId[hostId]!, side))
    }

    // One lane per host for each shared row it reaches.
    var trunkOf: [String: FleetLane] = [:]
    var lanes: [FleetLane] = []
    for (anchor, band) in bandOf.entries {
        var byHost = FleetOrderedMap<String, [BayEntry]>()
        for item in band { for entry in item.entries { byHost.push(entry.from, entry) } }
        for (hostId, mine) in byHost.entries {
            let from = centerOf(hostId)
            let branches = mine.map { entryY[$0.key]! }
            let to = branches.dropFirst().reduce(branches[0]) { far, at in abs(at - from) > abs(far - from) ? at : far }
            let lane = FleetLane(id: "\(hostId)>\(anchor)", from: from, to: to, branches: branches)
            for entry in mine { trunkOf[entry.key] = lane }
            lanes.append(lane)
        }
    }
    func span(_ lane: FleetLane) -> Double { abs(lane.to - lane.from) }
    func passes(_ lane: FleetLane, _ at: Double) -> Bool { at > min(lane.from, lane.to) && at < max(lane.from, lane.to) }
    func crossings(_ inner: FleetLane, _ outer: FleetLane) -> Int {
        inner.branches.filter { passes(outer, $0) }.count + (passes(inner, outer.from) ? 1 : 0)
    }
    var taken: [[FleetLane]] = []
    let laneOrder = jsSorted(jsSorted(lanes) { $0.id < $1.id ? -1 : 1 }) { left, right in
        let c = Double(crossings(left, right) - crossings(right, left))
        return c != 0 ? c : span(left) - span(right)
    }
    for lane in laneOrder {
        let top = min(lane.from, lane.to) - fleetLaneClearance
        let bottom = max(lane.from, lane.to) + fleetLaneClearance
        var index = 0
        while index < taken.count,
              taken[index].contains(where: { min($0.from, $0.to) < bottom && top < max($0.from, $0.to) }) {
            index += 1
        }
        lane.index = index
        if index == taken.count { taken.append([]) }
        taken[index].append(lane)
    }
    func laneX(_ lane: FleetLane) -> Double { cardRight + metrics.laneFirst + Double(lane.index) * fleetLaneStep }
    let fanX = taken.isEmpty ? cardRight : cardRight + metrics.laneFirst + Double(taken.count) * fleetLaneStep
    let bayX = room.bayX.map { max($0, fanX + min(metrics.linkRun, fleetLinkRunMin)) } ?? fanX + metrics.linkRun
    let endX = bayX - fleetArrowLength
    func lineInto(_ entry: BayEntry) -> (d: String, arrow: FleetPoint) {
        let targetY = entryY[entry.key]!
        let d = trunkOf[entry.key].map { fleetElbowPath(cardRight, $0.from, laneX($0), endX, targetY) }
            ?? fleetSCurve(cardRight, centerOf(entry.from), endX, targetY, fanX)
        return (d, FleetPoint(x: bayX, y: targetY))
    }

    var width = fanX
    for p in placed {
        width = max(width, bayX + p.size.width)
        guard let stack = p.item.stack else {
            nodes[p.item.targetId] = FleetRect(x: bayX, y: p.y, width: p.size.width, height: p.size.height)
            for entry in p.item.entries {
                let line = lineInto(entry)
                linkGeometry[entry.key] = FleetLinkGeometry(d: line.d, arrow: FleetArrow(x: line.arrow.x, y: line.arrow.y, dir: 1),
                                                            twoWay: nil, badge: nil)
            }
            continue
        }
        let faceSpan = faceOf(p.item, p.y, p.closedHeight)
        let face = FleetRect(x: bayX, y: faceSpan.top, width: metrics.target, height: faceSpan.height)
        let open = stack.expanded ? openRects(stack, face) : nil
        stackGeometry[stack.id] = FleetStackGeometry(
            rect: open?.rect ?? FleetRect(x: bayX, y: p.y, width: p.size.width, height: p.size.height), face: face,
            lines: p.item.entries.enumerated().map { index, entry in
                let line = lineInto(entry)
                return FleetStackLine(sourceId: entry.from, access: stack.sources[index].access, d: line.d, arrow: line.arrow)
            },
            tray: open?.tray, more: stack.expanded ? fillTray(stack, face) : nil)
    }

    let clientCenterY = restCenters.isEmpty ? fleetHeader + fleetClientHeight / 2 : (restCenters[0] + restCenters.last!) / 2
    nodes[fleetClientNodeId] = FleetRect(x: 0, y: clientCenterY - fleetClientHeight / 2, width: metrics.app, height: fleetClientHeight)

    // Wires leave the client a little apart, in the order they arrive, so they never cross.
    struct Wire { let entry: ColumnEntry; let edge: FleetEdge?; let portY: Double; let entryY: Double }
    let wires: [Wire] = column.flatMap { entry, center -> [Wire] in
        if case .fold = entry { return [Wire(entry: entry, edge: nil, portY: center, entryY: center)] }
        let hostRoutes = routesOf[entry.id] ?? []
        return hostRoutes.enumerated().map { index, edge in
            let offset = Double(index) - Double(hostRoutes.count - 1) / 2
            return Wire(entry: entry, edge: edge, portY: center + offset * fleetRoutePitch,
                        entryY: center + offset * routeEntryPitch(entry.id))
        }
    }
    let pillRight = pillX + metrics.pill
    let closeX = pillRight + metrics.pillGap
    var pillColumns: [FleetRect] = []
    let fan = min(fleetClientHeight - 20, Double(wires.count - 1) * 4)
    for (index, wire) in wires.enumerated() {
        let startY = clientCenterY + (wires.count < 2 ? 0 : (Double(index) / Double(wires.count - 1) - 0.5) * fan)
        let close = wire.entryY == wire.portY ? ""
            : "H\(js(pillRight))C\(js(pillRight + metrics.pillGap / 2)) \(js(wire.portY)) \(js(closeX - metrics.pillGap / 2)) \(js(wire.entryY)) \(js(closeX)) \(js(wire.entryY))"
        let d = "\(fleetSCurve(metrics.app, startY, pillX, wire.portY))\(close)H\(js(cardX))"
        guard let edge = wire.edge else {
            stackGeometry[wire.entry.id]!.lines = [FleetStackLine(sourceId: nil, access: nil, d: d, arrow: nil)]
            continue
        }
        let pill = FleetRect(x: pillX, y: wire.portY - fleetPillHeight / 2, width: metrics.pill, height: fleetPillHeight)
        routes[edge.id] = FleetRouteGeometry(d: d, pill: pill)
        pillColumns.append(pill)
        height = max(height, pill.y + pill.height)
    }

    // A link between environments names its access on its own lane, in a gap between two cards.
    struct Run { let link: FleetEdge; let x: Double; let from: Double; let to: Double }
    let runs = between.map { link in
        Run(link: link, x: cardX - metrics.betweenFirst - Double(betweenLane[link.id]!) * fleetBetweenStep,
            from: portY(link, link.from), to: portY(link, link.to))
    }
    var badges: [FleetLinkBadge] = []
    for (runIndex, run) in runs.enumerated() {
        let link = run.link, x = run.x
        let down = indexOf(link.to) > indexOf(link.from)
        var gaps: [Double] = []
        var index = low(link)
        while index < high(link) {
            let above = nodes[hosts[index].id]!, below = nodes[hosts[index + 1].id]!
            gaps.append(above.y + above.height + fleetGroupGap / 2)
            gaps.append(below.y - fleetGroupGap / 2)
            index += 1
        }
        if !down { gaps.reverse() }
        func place(_ at: Double, _ side: Int) -> FleetLinkBadge {
            FleetLinkBadge(rect: FleetRect(x: side == 1 ? x - fleetBadge.overhang : x + fleetBadge.overhang - fleetBadge.width,
                                           y: at - fleetBadge.height / 2, width: fleetBadge.width, height: fleetBadge.height),
                           side: side, onDemand: false)
        }
        func clearOfLanes(_ badge: FleetLinkBadge) -> Bool {
            let b = badge.rect
            return !runs.enumerated().contains { otherIndex, other in
                otherIndex != runIndex && other.x > b.x && other.x < b.x + b.width
                    && min(other.from, other.to) < b.y + b.height && max(other.from, other.to) > b.y
            }
        }
        func clearOfNames(_ badge: FleetLinkBadge) -> Bool {
            let b = badge.rect
            return !badges.contains { o in
                let r = o.rect
                return r.x < b.x + b.width + fleetBadge.gap && b.x < r.x + r.width + fleetBadge.gap
                    && r.y < b.y + b.height + fleetBadge.gap && b.y < r.y + r.height + fleetBadge.gap
            }
        }
        func clearOfRoutes(_ badge: FleetLinkBadge) -> Bool { !pillColumns.contains { $0.intersects(badge.rect) } }
        let options = gaps.flatMap { [place($0, 1), place($0, -1)] }
        let clear = options.first { clearOfNames($0) && clearOfLanes($0) && clearOfRoutes($0) }
        if let clear { badges.append(clear) }
        let startX = twoWay(link) ? cardX - fleetArrowLength : cardX
        let (back, forward) = fleetElbowHalves(startX, run.from, x, cardX - fleetArrowLength, run.to)
        var onDemand = options.first
        onDemand?.onDemand = true
        linkGeometry[link.id] = FleetLinkGeometry(
            d: fleetElbowPath(startX, run.from, x, cardX - fleetArrowLength, run.to),
            arrow: FleetArrow(x: cardX, y: run.to, dir: 1),
            twoWay: twoWay(link) ? .init(backArrow: FleetArrow(x: cardX, y: run.from, dir: 1), forward: forward, back: back) : nil,
            badge: clear ?? onDemand)
    }

    var columns: [(id: FleetColumn, x: Double)] = [(.client, 0)]
    if !column.isEmpty { columns.append((.environments, cardX)) }
    if !placed.isEmpty { columns.append((.targets, bayX)) }
    return FleetLayout(nodes: nodes, stacks: stackGeometry, routes: routes, links: linkGeometry, handles: handles,
                       columns: columns, width: width, height: height)
}

// MARK: - Interaction (:1705-1841)

/// What the arrow keys move between: every machine drawn, and each stack's controls (:1705).
public func fleetFocusRects(_ layout: FleetLayout) -> FleetOrderedMap<String, FleetRect> {
    var rects = layout.nodes
    for (id, geometry) in layout.stacks.entries {
        rects[id] = geometry.face
        if let more = geometry.more { rects[fleetMoreNodeId(id)] = more }
    }
    return rects
}

/// The machines drawn on their own that a selection box touches (:1715).
public func fleetNodesInBox(_ layout: FleetLayout, _ box: FleetRect) -> [String] {
    layout.nodes.entries.filter { $0.key != fleetClientNodeId && $0.value.intersects(box) }.map(\.key)
}

/// What pressing or dropping an environment's link handle starts (:1732-1758).
public enum FleetLinkAction: Equatable, Sendable {
    case batch(sourceEnvironmentId: String, environmentIds: [String])
    case codeOnly(sourceId: String, sourceEnvironmentId: String, machineIds: [String])
    case single(sourceEnvironmentId: String, offer: FleetLinkOffer.Link?)
}

public func fleetLinkAction(_ graph: FleetGraph, _ stacks: [FleetStack], selected: [String], sourceId: String,
                            targetId: String?) -> FleetLinkAction? {
    var byId: [String: FleetNode] = [:]
    for node in graph.nodes { byId[node.id] = node }
    guard let source = byId[sourceId], source.kind == .environment, source.linking == .ready else { return nil }
    let sourceEnvironmentId = source.environmentId
    func batch(_ picked: [String]) -> FleetLinkAction? {
        var environmentIds: [String] = []
        var machineIds: [String] = []
        var known = false
        for id in picked {
            guard let node = byId[id], node.kind != .client, node.id != source.id else { continue }
            if !environmentIds.contains(node.environmentId) {
                machineIds.append(node.id)
                environmentIds.append(node.environmentId)
            }
            known = known || node.kind != .target
        }
        if environmentIds.isEmpty { return nil }
        if known { return .batch(sourceEnvironmentId: sourceEnvironmentId, environmentIds: environmentIds) }
        if machineIds.count != 1 {
            return .codeOnly(sourceId: source.id, sourceEnvironmentId: sourceEnvironmentId, machineIds: machineIds)
        }
        // One such machine is the single flow's, which asks for its code.
        if case .link(let offer) = fleetLinkOffer(graph, sourceId, machineIds[0]) {
            return .single(sourceEnvironmentId: sourceEnvironmentId, offer: offer)
        }
        return nil
    }
    if let targetId, let stack = stacks.first(where: { $0.id == targetId }) { return batch(stack.memberIds) }
    if targetId == nil || selected.contains(targetId!) {
        if let picked = batch(selected) { return picked }
    }
    guard let targetId else { return .single(sourceEnvironmentId: sourceEnvironmentId, offer: nil) }
    if case .link(let offer) = fleetLinkOffer(graph, sourceId, targetId) {
        return .single(sourceEnvironmentId: sourceEnvironmentId, offer: offer)
    }
    return nil
}

/// Machines whose name holds the query, drawn or folded, in name order (:1804).
public func fleetSearch(_ graph: FleetGraph, _ query: String) -> [String] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if needle.isEmpty { return [] }
    return jsSorted(graph.nodes.filter { $0.kind != .client && $0.label.lowercased().contains(needle) }) {
        Double(fleetLabelCompare($0.label, $1.label))
    }.map(\.id)
}

public enum FleetDirection: Sendable { case up, down, left, right }

/// The nearest item in that direction, for arrow keys. Sideways distance counts double (:1816).
public func nextFleetNode(_ rects: FleetOrderedMap<String, FleetRect>, from fromId: String, _ direction: FleetDirection) -> String? {
    guard let from = rects[fromId] else { return nil }
    let horizontal = direction == .left || direction == .right
    let sign: Double = direction == .left || direction == .up ? -1 : 1
    let ox = from.x + from.width / 2, oy = from.y + from.height / 2
    var best: (id: String, score: Double)?
    for (id, rect) in rects.entries where id != fromId {
        let px = rect.x + rect.width / 2, py = rect.y + rect.height / 2
        let along = sign * (horizontal ? px - ox : py - oy)
        let across = abs(horizontal ? py - oy : px - ox)
        if along < 1 { continue }
        let score = along + across * 2
        if best == nil || score < best!.score { best = (id, score) }
    }
    return best?.id
}

// MARK: - View (:1843-1979)

public struct FleetViewTransform: Equatable, Sendable {
    public var x: Double, y: Double, scale: Double
    public init(x: Double, y: Double, scale: Double) { self.x = x; self.y = y; self.scale = scale }
}

/// The canvas width a layout is made for: steps, so dragging a window edge relays it rarely (:1857).
public func fleetLayoutWidth(_ canvasWidth: Double) -> Double { (canvasWidth / 16).rounded(.down) * 16 }

func fleetFitScale(_ available: Double, _ extent: Double, _ padding: Double) -> Double {
    max(0.01, (available - padding * 2) / max(1, extent))
}

/// Centers the whole map in the viewport at the largest scale that shows all of it (:1866).
public func fitFleetLayout(width: Double, height: Double, viewport: CGSize) -> FleetViewTransform {
    let vw = Double(viewport.width), vh = Double(viewport.height)
    let padding = fleetFitPadding(vw)
    let scale = min(fleetFitMaxScale, fleetFitScale(vw, width, padding), fleetFitScale(vh, height, padding))
    return FleetViewTransform(x: (vw - width * scale) / 2, y: (vh - height * scale) / 2, scale: scale)
}

/// How tall the canvas wants to be at this width (:1884).
public func fleetCanvasHeight(width layoutWidth: Double, height layoutHeight: Double, canvasWidth: Double,
                              bounds: ClosedRange<Double>) -> Double {
    let padding = fleetFitPadding(canvasWidth)
    let scale = min(fleetFitMaxScale, fleetFitScale(canvasWidth, layoutWidth, padding))
    let wanted = (layoutHeight * scale + padding * 2).rounded(.up)
    return max(bounds.lowerBound, min(bounds.upperBound, wanted))
}

/// Zooms by `factor`, keeping the map point under `anchor` where it is (:1896).
public func zoomFleetView(_ view: FleetViewTransform, _ factor: Double, anchor: FleetPoint, fitScale: Double? = nil) -> FleetViewTransform {
    let floor = min(fleetMinScale, fitScale ?? view.scale, view.scale)
    let scale = max(floor, min(fleetMaxScale, view.scale * factor))
    let ratio = scale / view.scale
    return FleetViewTransform(x: anchor.x - (anchor.x - view.x) * ratio, y: anchor.y - (anchor.y - view.y) * ratio, scale: scale)
}

/// A view that is not the fit: set by hand, or kept in place while a stack opened or closed (:1915).
public final class FleetHeldView: Equatable, @unchecked Sendable {
    public let key: String
    public let view: FleetViewTransform
    public let height: Double
    public let glide: Bool
    public let undo: (key: String, held: FleetHeldView?)?
    public init(key: String, view: FleetViewTransform, height: Double, glide: Bool, undo: (key: String, held: FleetHeldView?)?) {
        self.key = key; self.view = view; self.height = height; self.glide = glide; self.undo = undo
    }
    public static func == (l: FleetHeldView, r: FleetHeldView) -> Bool {
        l.key == r.key && l.view == r.view && l.height == r.height && l.glide == r.glide
            && l.undo?.key == r.undo?.key && l.undo?.held == r.undo?.held
    }
}

/// The view after a stack opened or closed: its card stays put on screen and the scale holds (:1932-1979).
public func anchorFleetView(key: String, fromKey: String, fromHeld: FleetHeldView?, fromView: FleetViewTransform,
                            fromSize: CGSize, fromFace: FleetPoint, stack: FleetStackGeometry,
                            layoutHeight: Double, bounds: ClosedRange<Double>) -> FleetHeldView {
    if let undo = fromHeld?.undo, undo.key == key {
        guard let held = undo.held else {
            return FleetHeldView(key: "", view: fromView, height: Double(fromSize.height), glide: true, undo: nil)
        }
        return FleetHeldView(key: held.key, view: held.view, height: held.height, glide: true, undo: held.undo)
    }
    let sw = Double(fromSize.width), sh = Double(fromSize.height)
    let padding = fleetFitPadding(sw)
    let top = fromFace.y * fromView.scale + fromView.y
    let scale = min(fromView.scale, fleetFitScale(sw, stack.rect.width, padding))
    let view = scale < fromView.scale
        ? FleetViewTransform(x: padding - stack.face.x * scale, y: top - stack.face.y * scale, scale: scale)
        : FleetViewTransform(x: fromView.x + (fromFace.x - stack.face.x) * scale,
                             y: fromView.y + (fromFace.y - stack.face.y) * scale, scale: scale)
    let wanted = (view.y + layoutHeight * scale + padding).rounded(.up)
    let opened = stack.tray != nil
    return FleetHeldView(key: key, view: view,
                         height: max(bounds.lowerBound, min(bounds.upperBound, opened ? max(sh, wanted) : min(sh, wanted))),
                         glide: true, undo: (fromKey, fromHeld))
}
