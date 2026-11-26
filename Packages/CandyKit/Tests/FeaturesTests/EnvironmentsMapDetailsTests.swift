import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The map's details panel (EnvironmentsMapDetails.tsx): what each selection shows and what its controls do. With
/// `CW_SNAP_DIR` set it writes the map with the panel to PNGs, in the default theme and in Redesign.
@MainActor
struct EnvironmentsMapDetailsTests {
    static func make(_ name: String = "shared", select: FleetFocus? = nil) -> EnvironmentsMapView {
        let view = EnvironmentsMapViewTests.make(name)
        if let select { view.canvas.state.selection = select }
        view.details.frame = NSRect(x: 0, y: 0, width: 900, height: view.details.height(forWidth: 900))
        view.details.layoutSubtreeIfNeeded()
        return view
    }

    /// Every word the panel shows: labels, paragraphs, buttons and the rows it draws.
    static func texts(_ view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let l = v as? LabelView { out.append(l.text) }
            if let t = v as? TextBlockView { out.append(t.text) }
            if let b = v as? ButtonView { out.append(b.title ?? "") }
            if let c = v as? FleetRowControl { out.append(c.accessibilityText ?? "") }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    @Test func nothingSelectedSumsUpTheMap() {
        let view = Self.make()
        let words = Self.texts(view.details)
        #expect(words.contains("9 machines, 10 links"))
        #expect(view.details.height(forWidth: 900) >= 80)
    }

    @Test func anEnvironmentListsItsLinksBothWays() {
        let view = Self.make(select: .node(fleetEnvironmentNodeId("cups")))
        let words = Self.texts(view.details)
        #expect(words.contains("Links to 7 machines"))
        #expect(words.contains("Linked from 0 machines") == false)
        #expect(words.contains("No known machine links here"))
        #expect(words.contains("Link"))
        #expect(words.contains { $0.hasPrefix("nucbox, Auto, Expires ") })
    }

    @Test func aMachineWithUnreadableLinksSaysSo() {
        let view = Self.make(select: .node(fleetEnvironmentNodeId("mbp")))
        let words = Self.texts(view.details)
        #expect(words.contains("Not connected, so its links are not shown."))
        #expect(words.contains("Link") == false)
    }

    @Test func aLinkShowsItsFactsAndForget() throws {
        let graph = EnvironmentsMapViewTests.make("shared").canvas.graph
        let edge = try #require(graph.links.first { $0.from == fleetEnvironmentNodeId("nucbox") && $0.link?.environmentId == "fs-3" })
        let view = Self.make(select: .edge(edge.id))
        let words = Self.texts(view.details)
        for term in ["Access", "Status", "Expires", "Addresses", "Linked", "Read only", "Reachable", "Forget"] {
            #expect(words.contains(term), "missing \(term)")
        }
        #expect(words.contains("https://fs-3.example.ts.net"))
        var forgot: (String, String)?
        view.details.actions.forget = { forgot = ($0, $1) }
        view.details.rebuild()
        let forget = try #require(Self.buttons(view.details).first { $0.title == "Forget" })
        forget.action?()
        #expect(forgot?.0 == "nucbox" && forgot?.1 == "fs-3")
    }

    @Test func aTwoWayLinkShowsBothLinks() throws {
        let T = EnvironmentsMapLogicTests.self
        let view = EnvironmentsMapView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        view.set(EnvironmentsMapModel(clientLabel: "This device", environments: [T.environment("a", [T.link("b", access: "auto")]),
                                                                                  T.environment("b", [T.link("a", access: "auto")])],
                                      now: T.now))
        let id = try #require(fleetTwoWayLinks(view.canvas.graph).keys.first)
        view.canvas.state.selection = .edge(id)
        let words = Self.texts(view.details)
        #expect(words.contains("Two links, one each way."))
        #expect(words.filter { $0 == "Addresses" }.count == 2)
    }

    /// "Link several…" is a menu of "From {source}" items when several environments can link and none is selected
    /// (EnvironmentsMap.tsx:946-968); a selected one, or a lone one, opens the dialog straight away (:874-880).
    @Test func linkSeveralAsksWhichSourceWhenSeveralCanLink() throws {
        let T = EnvironmentsMapLogicTests.self
        let view = EnvironmentsMapView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        view.set(EnvironmentsMapModel(clientLabel: "This device", environments: [T.environment("a"), T.environment("b")], now: T.now))
        #expect(view.linkSeveralSource == nil)
        let items = view.linkSeveralMenuItems()
        #expect(items.map(\.title) == ["From a", "From b"])
        var opened: String?
        view.onLinkSeveral = { source, _ in opened = source }
        items[1].action?()
        #expect(opened == "b")
        view.canvas.state.selection = .node(fleetEnvironmentNodeId("a"))
        #expect(view.linkSeveralSource?.environmentId == "a")
        view.set(EnvironmentsMapModel(clientLabel: "This device", environments: [T.environment("a")], now: T.now))
        view.canvas.state.selection = nil
        #expect(view.linkSeveralSource?.environmentId == "a")
    }

    @Test func anEndpointSelectsItsMachineAndEscClears() throws {
        let graph = EnvironmentsMapViewTests.make("shared").canvas.graph
        let edge = try #require(graph.links.first { $0.from == fleetEnvironmentNodeId("nucbox") })
        let view = Self.make(select: .edge(edge.id))
        let endpoint = try #require(Self.all(view.details).compactMap { $0 as? FleetEndpointButton }.first)
        endpoint.performAction()
        #expect(view.canvas.state.selection == .node(fleetEnvironmentNodeId("nucbox")))
        view.details.cancelOperation(nil)
        #expect(view.canvas.state.selection == nil)
    }

    @Test func aStackListsItsMembersAndFilters() throws {
        let view = EnvironmentsMapViewTests.make("default")
        let stack = try #require(view.canvas.stacks.first { $0.memberIds.count > 9 || $0.kind == .targets })
        view.canvas.state.selection = .stack(stack.id)
        let words = Self.texts(view.details)
        #expect(words.contains(where: { $0.hasPrefix("fs-") && $0.contains(" … ") }))
        #expect(words.contains(stack.expanded ? "Collapse" : "Show on map"))
        let members = FleetStackMember.members(stack, view.canvas.graph, view.canvas.graph.links, statusText: [:])
        #expect(members.count == stack.memberIds.count)
        #expect(members.allSatisfy { $0.detail == "Full access" })
        var toggled: String?
        view.details.onToggleStack = { toggled = $0 }
        try #require(Self.buttons(view.details).first { $0.title == "Show on map" || $0.title == "Collapse" }).action?()
        #expect(toggled == stack.id)
    }

    @Test func aFilteredStackCountsWhatItShows() {
        let members = (1...12).map { FleetStackMember(id: "m\($0)", label: "vm-\($0)", detail: "", address: nil, worst: nil) }
        let list = FleetMemberListView(members: members, query: "", wide: false)
        #expect(list.height(forWidth: 600) == CGFloat(286), "\(list.height(forWidth: 600)) \(list.shown.count)")
        list.apply("vm-1")
        #expect(list.shown.count == 4)  // vm-1, vm-10, vm-11, vm-12
        #expect(list.height(forWidth: 600) == CGFloat(146), "\(list.height(forWidth: 600))")
    }

    @Test func searchSelectsTheFirstMatchOnEnter() {
        let view = EnvironmentsMapViewTests.make("shared")
        view.canvas.state.query = "mbp"
        view.goToFirstMatch()
        #expect(view.canvas.state.selection == .node(fleetEnvironmentNodeId("mbp")))
    }

    @Test func timestampsReadLikeIntl() {
        let text = FleetTimestamp.format("2027-01-01T00:00:00.000Z")
        #expect(!text.contains(" at "))
        #expect(text.contains("2026") || text.contains("2027"))
    }

    @Test func snapshots() throws {
        let graph = EnvironmentsMapViewTests.make("shared").canvas.graph
        let edge = graph.links.first { $0.from == fleetEnvironmentNodeId("nucbox") }!.id
        for (name, focus) in [("node", FleetFocus.node(fleetEnvironmentNodeId("cups"))), ("edge", .edge(edge))] {
            let view = Self.make(select: focus)
            let box = DSView(frame: NSRect(x: 0, y: 0, width: 900, height: view.details.height(forWidth: 900)))
            view.details.frame = box.bounds
            box.addSubview(view.details)
            for theme in ["light", "dark"] {
                for redesign in [false, true] {
                    try EnvironmentsMapViewTests.snap(box, "environments-map-details-\(name)-\(theme)\(redesign ? "-redesign" : "")",
                                                      dark: theme == "dark", redesign: redesign)
                }
            }
        }
    }

    static func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    static func buttons(_ v: NSView) -> [ButtonView] { all(v).compactMap { $0 as? ButtonView } }
}
