import CoreGraphics
import Foundation
import Testing
import T3Protocol
@testable import Features

/// The Environments map's layout engine against T3 5258's own output. `scripts/gen-environments-map-golden`
/// runs T3's environmentsMap.logic.ts on the setups below (copied from environmentsMap.logic.test.ts:42-177)
/// and writes fixtures/environments-map/5258-layouts.json; every box and path here must match it exactly.
struct EnvironmentsMapLogicTests {
    static let now = Date(timeIntervalSince1970: 1_795_608_000) // 2026-11-19T12:00:00Z
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func link(_ target: String, access: String = "approval-required", status: PeerLinkSummary.Status = .reachable,
                     lastError: String? = nil, expiresAt: String = "2027-01-01T00:00:00.000Z") -> PeerLinkSummary {
        PeerLinkSummary(environmentId: target, label: target, urls: ["https://\(target).example.ts.net"], access: access,
                        linkedAt: "2026-11-01T00:00:00.000Z", expiresAt: expiresAt, lastError: lastError, status: status)
    }

    static func environment(_ name: String, _ links: [PeerLinkSummary] = [], outgoing: FleetOutgoingLinks? = nil,
                            phase: FleetPhase = .connected, enabled: Bool = true,
                            routes: [FleetRouteInput] = [FleetRouteInput(id: "tailnet", kind: "tailnet")],
                            activeRouteId: String = "tailnet", canWriteAccess: Bool = true) -> FleetEnvironmentInput {
        FleetEnvironmentInput(environmentId: name, label: name, phase: phase, enabled: enabled, routes: routes,
                              activeRouteId: activeRouteId, outgoing: outgoing ?? .loaded(links), offersLinks: true,
                              canWriteAccess: canWriteAccess, hasLinkAddress: true)
    }

    static func vms(_ count: Int, _ prefix: String = "vm", access: String = "approval-required",
                    status: PeerLinkSummary.Status = .reachable) -> [PeerLinkSummary] {
        (1...count).map { link("\(prefix)-\($0)", access: access, status: status) }
    }

    static func build(_ environments: [FleetEnvironmentInput], _ connect: [FleetConnectMachineInput] = []) -> FleetGraph {
        buildFleetGraph(clientLabel: "This browser", environments: environments, connectMachines: connect, now: now)
    }

    nonisolated(unsafe) static let setups: [String: () -> FleetGraph] = [
        "one": { build([environment("cups")]) },
        "large": {
            build([
                environment("nucbox", vms(40, "fs", access: "full-access") + [link("ci"), link("cups", access: "auto")],
                            routes: [.init(id: "tailnet", kind: "tailnet"), .init(id: "lan", kind: "lan"), .init(id: "relay", kind: "relay")]),
                environment("cups", [link("nucbox"), link("staging", access: "read-only"), link("ci")]),
                environment("mbp", outgoing: .unknown, phase: .offline),
                environment("win", outgoing: .unknown, phase: .error),
                environment("vps", [link("db-1"), link("db-2"), link("db-3"), link("ci", access: "read-only"),
                                    link("staging", access: "auto"), link("cups", access: "full-access")]),
                environment("old", outgoing: .unknown, phase: .available, enabled: false),
            ], [FleetConnectMachineInput(environmentId: "gpu", label: "gpu", availability: .online)])
        },
        "shared": {
            build([
                environment("nucbox", [link("fs-1", access: "full-access"), link("fs-2", access: "auto"), link("fs-3", access: "read-only")]),
                environment("mbp", outgoing: .unknown, phase: .reconnecting),
                environment("cups", [link("fs-1", access: "full-access"), link("fs-2", access: "full-access"), link("fs-3", access: "auto"),
                                     link("fs-4", access: "auto-accept-edits"), link("fs-5"), link("fs-6", access: "read-only"),
                                     link("nucbox", access: "auto")]),
            ])
        },
        "huge": {
            build([
                environment("nucbox", vms(1000, access: "full-access") + [link("cups")]),
                environment("cups", vms(1000, access: "full-access")),
                environment("mbp", [link("nucbox", access: "auto")]),
            ] + (1...5).map { environment("gpu-\($0)") }
              + (1...6).map { environment("lab-\($0)", outgoing: .unknown, phase: .offline) }
              + (1...4).map { environment("old-\($0)", outgoing: .unknown, phase: .available, enabled: false) }
              + (1...2).map { environment("legacy-\($0)", outgoing: .unknown, phase: .unsupported) })
        },
        "twoWay": { build([environment("a", [link("b")]), environment("b", [link("a")])]) },
        "twoApart": { build([environment("a", [link("b")]), environment("b", [link("a", access: "auto")])]) },
        "mesh": {
            let names = ["a", "b", "c", "d", "e"]
            return build(names.map { name in environment(name, names.filter { $0 != name }.map { link($0) }) })
        },
        "legible": {
            func routes(_ kinds: String...) -> [FleetRouteInput] { kinds.enumerated().map { .init(id: "\($1)-\($0)", kind: $1) } }
            return build([
                environment("cups", outgoing: .unknown, phase: .offline, routes: routes("tailnet", "tailnet", "relay")),
                environment("nucbox-1", [link("Julius's MacBook Pro", access: "full-access")] + vms(7, "fs", access: "full-access")
                                + vms(37, "gs", access: "full-access", status: .unreachable),
                            routes: routes("lan", "tailnet", "tailnet", "relay"), activeRouteId: "lan-0"),
                environment("Julius's MacBook Pro"),
            ])
        },
        "health": {
            build([
                environment("a", [link("b", status: .expired), link("c", lastError: "401"), link("d", status: .unreachable),
                                  link("e", expiresAt: "2026-11-21T00:00:00.000Z")]),
                environment("b", outgoing: .loading),
                environment("c", outgoing: .off, canWriteAccess: false),
            ])
        },
    ]

    nonisolated(unsafe) static let golden: [String: Any] = {
        let data = try! Data(contentsOf: repo.appendingPathComponent("fixtures/environments-map/5258-layouts.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    static func rect(_ r: FleetRect?) -> Any { r.map { [$0.x, $0.y, $0.width, $0.height] as [Any] } ?? NSNull() }
    static func opt(_ s: String?) -> Any { s ?? NSNull() }

    /// The same shape gen.ts writes, so the two compare as JSON values.
    static func dump(_ l: FleetLayout) -> [String: Any] {
        [
            "nodes": l.nodes.entries.map { [$0.key, rect($0.value)] as [Any] },
            "stacks": l.stacks.entries.map { key, v -> [Any] in
                [key, ["rect": rect(v.rect), "face": rect(v.face), "tray": rect(v.tray), "more": rect(v.more),
                       "lines": v.lines.map { [opt($0.sourceId), opt($0.access), $0.d, $0.arrow.map { [$0.x, $0.y] } ?? NSNull()] as [Any] }] as [String: Any]]
            },
            "routes": l.routes.entries.map { [$0.key, $0.value.d, rect($0.value.pill)] as [Any] },
            "links": l.links.entries.map { key, v -> [Any] in
                [key, v.d, [v.arrow.x, v.arrow.y, v.arrow.dir] as [Any],
                 v.twoWay.map { [$0.backArrow.x, $0.backArrow.y, $0.forward, $0.back] as [Any] } ?? NSNull(),
                 v.badge.map { [$0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height, $0.side, $0.onDemand] as [Any] } ?? NSNull()]
            },
            "handles": l.handles.entries.map { [$0.key, $0.value.x, $0.value.y] as [Any] },
            "columns": l.columns.map { [$0.id.rawValue, $0.x] as [Any] },
            "width": l.width, "height": l.height,
        ]
    }

    static func same(_ a: Any, _ b: Any, _ path: String, _ diffs: inout [String]) {
        if diffs.count > 5 { return }
        switch (a, b) {
        case let (a as [String: Any], b as [String: Any]):
            for key in Set(a.keys).union(b.keys) {
                guard let av = a[key], let bv = b[key] else { diffs.append("\(path).\(key) missing"); continue }
                same(av, bv, "\(path).\(key)", &diffs)
            }
        case let (a as [Any], b as [Any]):
            if a.count != b.count { diffs.append("\(path) count \(a.count) vs \(b.count)"); return }
            for (i, (x, y)) in zip(a, b).enumerated() { same(x, y, "\(path)[\(i)]", &diffs) }
        case let (a as String, b as String): if a != b { diffs.append("\(path): \(a) vs \(b)") }
        case let (a as NSNumber, b as NSNumber): if abs(a.doubleValue - b.doubleValue) > 1e-9 { diffs.append("\(path): \(a) vs \(b)") }
        case (is NSNull, is NSNull): break
        default: diffs.append("\(path): \(a) vs \(b)")
        }
    }

    @Test(arguments: ["one", "large", "shared", "huge", "twoWay", "twoApart", "mesh", "legible", "health"])
    func layoutMatchesT3(_ name: String) throws {
        let graph = Self.setups[name]!()
        let expected = Self.golden[name] as! [String: Any]
        let closed = fleetStacks(graph, expanded: [])
        let stackRows: [Any] = closed.map { [$0.id, $0.kind.rawValue, $0.memberIds.count, $0.reachable, $0.shownIds.count, $0.firstLabel, $0.lastLabel] as [Any] }
        var diffs: [String] = []
        Self.same(stackRows, expected["stacks"]!, "\(name).stacks", &diffs)
        let summary = fleetSummary(graph)
        let wantSummary = expected["summary"] as! [String: Any]
        #expect(summary.machines == wantSummary["machines"] as! Int)
        #expect(summary.links == wantSummary["links"] as? Int)
        #expect(summary.loading == wantSummary["loading"] as! Bool)
        #expect(fleetShapeKey(graph, closed).utf16.count == expected["shapeKeyLength"] as! Int)
        var variants: [(String, [FleetStack])] = [("closed", closed)]
        if !closed.isEmpty { variants.append(("open", fleetStacks(graph, expanded: Set(closed.map(\.id))))) }
        let layouts = expected["layouts"] as! [String: Any]
        for (variant, stacks) in variants {
            for width in [nil, 560.0, 900, 1400] {
                let key = "\(variant)@\(width.map { String(Int($0)) } ?? "regular")"
                let layout = layoutFleetGraph(graph, stacks, canvasWidth: width)
                let want = layouts[key] as! [String: Any]
                var got = Self.dump(layout)
                if let width {
                    let h = fleetCanvasHeight(width: layout.width, height: layout.height, canvasWidth: width, bounds: 180...840)
                    let fit = fitFleetLayout(width: layout.width, height: layout.height, viewport: CGSize(width: width, height: h))
                    got["canvasHeight"] = h
                    got["fit"] = ["x": fit.x, "y": fit.y, "scale": fit.scale]
                } else {
                    got["canvasHeight"] = NSNull(); got["fit"] = NSNull()
                }
                // Through JSON, so both sides hold the same Foundation types.
                let roundTrip = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: got))
                Self.same(roundTrip, want, "\(name).\(key)", &diffs)
            }
        }
        #expect(diffs.isEmpty, "\(diffs.joined(separator: "\n"))")
    }

    @Test func twoWayLinksMergeOnlyAtTheSameAccess() {
        #expect(fleetTwoWayLinks(Self.setups["twoWay"]!()).count == 2)
        #expect(fleetTwoWayLinks(Self.setups["twoApart"]!()).isEmpty)
    }

    /// environmentsMap.logic.test.ts:473-540.
    @Test func linkOffers() {
        let graph = Self.build([
            Self.environment("a", [Self.link("t", access: "full-access")]),
            Self.environment("b"),
            FleetEnvironmentInput(environmentId: "c", label: "c", phase: .connected, routes: [], outgoing: .loaded([]),
                                  offersLinks: true, canWriteAccess: true, hasLinkAddress: false),
            Self.environment("off", outgoing: .unknown, phase: .offline),
        ])
        func offer(_ s: String, _ t: String) -> FleetLinkOffer { fleetLinkOffer(graph, fleetEnvironmentNodeId(s), fleetEnvironmentNodeId(t)) }
        guard case .link(let codeLess) = offer("a", "b") else { Issue.record("no offer"); return }
        #expect(codeLess.path == .codeLess)
        guard case .link(let code) = offer("a", "c") else { Issue.record("no offer"); return }
        #expect(code.path == .pairingCode)
        guard case .link(let through) = offer("b", "t") else { Issue.record("no offer"); return }
        #expect(through.path == .throughLink)
        #expect(offer("a", "a") == .unavailable(.sameMachine))
        #expect(offer("off", "a") == .unavailable(.sourceDisconnected))
        #expect(fleetLinkOffer(graph, fleetEnvironmentNodeId("a"), fleetClientNodeId) == .unavailable(.notAnEnvironment))
    }

    /// environmentsMap.logic.test.ts:555-612.
    @Test func linkActions() {
        let graph = Self.build([Self.environment("a"), Self.environment("b"), Self.environment("c"),
                                Self.environment("h", [Self.link("x"), Self.link("y")])])
        let a = fleetEnvironmentNodeId("a"), b = fleetEnvironmentNodeId("b"), c = fleetEnvironmentNodeId("c")
        #expect(fleetLinkAction(graph, [], selected: [b, c], sourceId: a, targetId: b) == .batch(sourceEnvironmentId: "a", environmentIds: ["b", "c"]))
        #expect(fleetLinkAction(graph, [], selected: [b, c], sourceId: a, targetId: nil) == .batch(sourceEnvironmentId: "a", environmentIds: ["b", "c"]))
        if case .single(_, let offer?) = fleetLinkAction(graph, [], selected: [b], sourceId: a, targetId: c) {
            #expect(offer.target == .machine(environmentId: "c"))
        } else { Issue.record("expected one link") }
        #expect(fleetLinkAction(graph, [], selected: [], sourceId: a, targetId: nil) == .single(sourceEnvironmentId: "a", offer: nil))
        let x = fleetEnvironmentNodeId("x"), y = fleetEnvironmentNodeId("y")
        #expect(fleetLinkAction(graph, [], selected: [x, y], sourceId: a, targetId: nil)
            == .codeOnly(sourceId: a, sourceEnvironmentId: "a", machineIds: [x, y]))
    }

    @Test func searchFindsByNameInNameOrder() {
        let graph = Self.setups["large"]!()
        #expect(fleetSearch(graph, "  FS-1 ").prefix(3) == ["env:fs-1", "env:fs-10", "env:fs-11"])
        #expect(fleetSearch(graph, " ").isEmpty)
    }

    @Test func neighborhoodIsOneHop() {
        let graph = Self.build([Self.environment("a", [Self.link("b")]), Self.environment("b", [Self.link("c")]), Self.environment("c")])
        let hood = fleetNeighborhood(graph, [], .node(fleetEnvironmentNodeId("a")))
        #expect(hood.nodes.contains(fleetEnvironmentNodeId("b")))
        #expect(!hood.nodes.contains(fleetEnvironmentNodeId("c")))
    }

    @Test func arrowKeysStepBetweenColumns() {
        let graph = Self.setups["shared"]!()
        let layout = layoutFleetGraph(graph, fleetStacks(graph, expanded: []))
        let rects = fleetFocusRects(layout)
        #expect(nextFleetNode(rects, from: fleetClientNodeId, .right)?.hasPrefix("env:") == true)
        #expect(nextFleetNode(rects, from: fleetClientNodeId, .left) == nil)
    }

    @Test func zoomKeepsTheAnchor() {
        let view = zoomFleetView(FleetViewTransform(x: 10, y: 20, scale: 1), 2, anchor: FleetPoint(x: 100, y: 100))
        #expect(view == FleetViewTransform(x: -80, y: -60, scale: 2))
        #expect(zoomFleetView(view, 10, anchor: FleetPoint(x: 0, y: 0)).scale == 2)
    }

    @Test func pathsParse() {
        let path = fleetCGPath("M0 0H10Q12 0 12 2V8C12 10 14 10 16 10")
        #expect(path.currentPoint == CGPoint(x: 16, y: 10))
        #expect(js(12.5) == "12.5" && js(-0.0) == "0" && js(100) == "100")
    }
}
