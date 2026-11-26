import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The map view: drawing, keys, zoom and VoiceOver. With `CW_SNAP_DIR` set it also writes the map to PNGs there,
/// in the default theme and in Redesign, for an on-screen check.
@MainActor
struct EnvironmentsMapViewTests {
    static func model(_ name: String) -> EnvironmentsMapModel {
        return EnvironmentsMapModel(clientLabel: "This device", environments: Self.inputs(name), now: EnvironmentsMapLogicTests.now)
    }

    /// The fixture setups' inputs, rebuilt through the same helpers.
    static func inputs(_ name: String) -> [FleetEnvironmentInput] {
        let T = EnvironmentsMapLogicTests.self
        switch name {
        case "shared":
            return [T.environment("nucbox", [T.link("fs-1", access: "full-access"), T.link("fs-2", access: "auto"), T.link("fs-3", access: "read-only")]),
                    T.environment("mbp", outgoing: .unknown, phase: .reconnecting),
                    T.environment("cups", [T.link("fs-1", access: "full-access"), T.link("fs-2", access: "full-access"), T.link("fs-3", access: "auto"),
                                           T.link("fs-4", access: "auto-accept-edits"), T.link("fs-5"), T.link("fs-6", access: "read-only"),
                                           T.link("nucbox", access: "auto")])]
        default:
            return [T.environment("cups"), T.environment("nucbox", T.vms(8, "fs", access: "full-access") + [T.link("cups"), T.link("ci", status: .unreachable)],
                                                          routes: [.init(id: "tailnet", kind: "tailnet"), .init(id: "relay", kind: "relay")]),
                    T.environment("old", outgoing: .unknown, phase: .available, enabled: false)]
        }
    }

    static func make(_ name: String, width: CGFloat = 900) -> EnvironmentsMapView {
        let view = EnvironmentsMapView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        view.set(model(name))
        view.frame.size.height = view.height(forWidth: width)
        view.layoutSubtreeIfNeeded()
        view.canvas.relayout()
        return view
    }

    /// The sidebar's server update notice opens Connections on the list, where the outdated row shows.
    @Test func theServerUpdateNoticeOpensTheList() {
        let page = ConnectionsSettingsView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        var model = ConnectionsPageModel()
        model.map = Self.model("shared")
        page.set(model)
        #expect(page.mapView.superview != nil)
        page.showList()
        #expect(page.mapView.superview == nil)
        #expect(page.viewSwitch.selectedIndex == 1)
    }

    @Test func drawsEveryMachineAndLink() throws {
        let view = Self.make("shared")
        let layout = view.canvas.fleetLayout
        #expect(layout.nodes.count == 10)
        #expect(view.canvas.accessibilityChildren()?.count ?? 0 >= 10)
        let height = view.height(forWidth: 900)
        #expect(height >= 41 + 180 + 38 && height <= 41 + 840 + 38)
        for theme in ["light", "dark"] {
            for redesign in [false, true] {
                try Self.snap(view, "environments-map-\(theme)\(redesign ? "-redesign" : "")", dark: theme == "dark", redesign: redesign)
            }
        }
    }

    /// A plain scroll leaves the view where it is, so the page scrolls (:706-716), and the scene never draws past the
    /// canvas (`overflow-clip`, :1010).
    @Test func plainScrollLeavesTheMapAndTheCanvasClips() throws {
        let view = Self.make("shared")
        #expect(view.canvas.clipsToBounds)
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -150, wheel2: 0, wheel3: 0))
        view.canvas.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        #expect(view.canvas.state.held == nil)
    }

    @Test func arrowKeysRoveAndSpaceTicks() {
        let view = Self.make("shared")
        let canvas = view.canvas
        canvas.keyDown(with: Self.key(124))
        #expect(canvas.state.roving.hasPrefix("env:"))
        let first = canvas.state.roving
        canvas.keyDown(with: Self.key(49, " "))
        #expect(canvas.state.ticked == [first])
        canvas.keyDown(with: Self.key(36, "\r"))
        #expect(canvas.state.selection == .node(first))
        canvas.keyDown(with: Self.key(53, "\u{1b}"))
        #expect(canvas.state.selection == nil)
    }

    @Test func zoomHoldsTheViewAndZeroFits() {
        let canvas = Self.make("shared").canvas
        let fit = canvas.view
        canvas.keyDown(with: Self.key(24, "="))
        #expect(canvas.view.scale > fit.scale)
        #expect(canvas.state.held != nil)
        canvas.keyDown(with: Self.key(29, "0"))
        #expect(canvas.state.held == nil)
    }

    @Test func voiceOverNamesMachines() {
        let canvas = Self.make("shared").canvas
        let labels = (canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains { $0.hasPrefix("nucbox, 3 links out") })
        #expect(labels.contains { $0.hasPrefix("mbp, Reconnecting…. Links unknown") })
        #expect(labels.contains("Link nucbox to another machine"))
    }

    @Test func searchCountsMatches() {
        let view = Self.make("shared")
        view.canvas.state.query = "fs"
        #expect(view.canvas.matches?.count == 6)
        #expect(EnvironmentsMapText.matches(6) == "6 matches")
    }

    static func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static func snap(_ view: NSView, _ name: String, dark: Bool, redesign: Bool) throws {
        guard let dir = ProcessInfo.processInfo.environment["CW_SNAP_DIR"] else { return }
        let before = ThemeRuntime.input
        defer { ThemeRuntime.apply(before) }
        if redesign {
            var input = ThemeRuntimeInput(
                light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
            input.ditherLight = true; input.ditherDark = true
            ThemeRuntime.apply(input)
        }
        // On the page's ground, as Settings draws it.
        let ground = SnapGround(frame: view.bounds)
        ground.addSubview(view)
        defer { view.removeFromSuperview() }
        ground.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = ground.appearance
        ground.layoutSubtreeIfNeeded()
        for v in [ground, view] + view.subviews { v.needsDisplay = true }
        let rep = ground.bitmapImageRepForCachingDisplay(in: ground.bounds)!
        ground.cacheDisplay(in: ground.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}

final class SnapGround: DSView {
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
}
