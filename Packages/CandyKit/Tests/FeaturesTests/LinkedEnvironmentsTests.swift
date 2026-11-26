import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Connections > Linked environments and the Link dialog (LinkedEnvironmentsSettings.tsx at 3814).
/// With `CW_SNAP_DIR` set, the page and the dialog also render to PNGs there for an on-screen check.
@MainActor
struct LinkedEnvironmentsTests {
    static let box = LinkableMachine(environmentId: "b", label: "Sandbox B", connected: true, linked: false,
                                     urls: ["http://127.0.0.1:47399"], canMint: true)
    static let ssh = LinkableMachine(environmentId: "s", label: "SSH box", connected: true, linked: true, urls: [], canMint: false)

    @Test func noMachinesAsksForAnAddressAndACode() {
        let form = LinkEnvironmentFormView(machines: [])
        #expect(form.selected == LinkEnvironmentFormView.anotherAddress)
        #expect(form.needsAddress)
        #expect(!form.ready)
        form.addressInput.text = " https://box.example.ts.net "
        form.addressInput.onChange?(form.addressInput.text)
        #expect(!form.ready)
        form.codeInput.text = "code"
        #expect(form.ready)
        #expect(form.urls == ["https://box.example.ts.net"])
        #expect(form.access == "approval-required")
    }

    @Test func aMachineThisAppCanMintOnNeedsNoCode() {
        let form = LinkEnvironmentFormView(machines: [Self.box])
        #expect(form.selected == nil)
        #expect(!form.ready)
        form.preset(choice: "b", access: "read-only", lockMachine: false)
        #expect(form.mints)
        #expect(form.ready)
        #expect(form.urls == ["http://127.0.0.1:47399"])
        #expect(form.access == "read-only")
        // After a failed mint the form asks for a code instead.
        form.mintFailed = ["b"]
        #expect(!form.mints)
        #expect(!form.ready)
    }

    /// #40036: a machine known only through a host's full-access link that answers is offered, and linking it needs no
    /// address or code; minting with this app's own session comes first (LinkedEnvironmentsSettings.tsx:264-347 at 5258).
    @Test func aMachineReachedThroughAFullAccessLinkNeedsNoCode() throws {
        let T = EnvironmentsMapLogicTests.self
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z"))
        let routes = LinkThroughRoute.routes(source: "a", hosts: [
            (environmentId: "a", label: "Atlas", links: [T.link("x", access: "full-access")]),
            (environmentId: "v", label: "Vault", links: [T.link("a", access: "full-access"), T.link("c", access: "full-access"),
                                                         T.link("d", access: "auto"), T.link("e", access: "full-access", status: .unreachable),
                                                         T.link("b", access: "full-access")]),
            (environmentId: "w", label: "Work", links: [T.link("c", access: "full-access")]),
        ], now: now)
        #expect(routes.map(\.environmentId) == ["c", "b"])
        #expect(routes[0].viaEnvironmentId == "v" && routes[0].viaLabel == "Vault")

        let form = LinkEnvironmentFormView(machines: [Self.box], throughRoutes: routes)
        #expect(form.machines.map(\.environmentId) == ["b", "c"])
        #expect(form.title(source: "Atlas") == "Link Atlas to another machine")
        form.preset(choice: "c", access: nil, lockMachine: false)
        #expect(form.through?.environmentId == "c")
        #expect(form.ready)
        #expect(form.title(source: "Atlas") == "Link Atlas to c")
        form.preset(choice: "b", access: nil, lockMachine: false)
        #expect(form.mints && form.through == nil)
        form.mintFailed = ["b"]
        #expect(form.through?.environmentId == "b")
        form.throughFailed = ["b"]
        #expect(form.through == nil && !form.ready)
    }

    /// The map's drop on a machine known only through a link opens the dialog on that machine's address; typing another
    /// address drops the route (:306-311 at 5258).
    @Test func aPrefilledRouteHoldsOnlyForItsAddress() {
        let route = LinkThroughRoute(viaEnvironmentId: "v", viaLabel: "Vault", environmentId: "c", label: "Cedar", urls: [])
        let form = LinkEnvironmentFormView(machines: [Self.box])
        form.preset(choice: nil, access: nil, lockMachine: false, address: "http://cedar:3773", through: route)
        #expect(form.through == route)
        #expect(form.ready)
        #expect(form.title(source: "Atlas") == "Link Atlas to Cedar")
        form.addressInput.text = "http://other:3773"
        form.addressInput.onChange?(form.addressInput.text)
        #expect(form.through == nil)
        #expect(!form.ready)
    }

    @Test func aMachineWithoutAnAddressAsksForOne() {
        let form = LinkEnvironmentFormView(machines: [Self.box, Self.ssh])
        form.preset(choice: "s", access: nil, lockMachine: true)
        #expect(form.needsAddress)
        form.addressInput.text = "https://ssh.example.ts.net"
        form.codeInput.text = "code"
        #expect(form.ready)
        #expect(form.urls == ["https://ssh.example.ts.net"])
    }

    @Test func aMachineWithoutAnAddressSaysWhatToTurnOn() {
        let mac = LinkableMachine(environmentId: "m", label: "MacBook", connected: true, linked: false, urls: [], canMint: true,
                                  noAddressHint: "Turn on T3 Connect.")
        let form = LinkEnvironmentFormView(machines: [mac])
        form.preset(choice: "m", access: nil, lockMachine: false)
        #expect(form.needsAddress)
        #expect(!form.ready)
        #expect(form.addressHintText == "Turn on T3 Connect.")
    }

    /// A link request whose machine is linked already answers `use-existing`, asking for nothing else.
    @Test func aRequestForALinkedMachineUsesTheLink() {
        let form = LinkEnvironmentFormView(machines: [Self.box, Self.ssh])
        form.answersRequest = true
        form.preset(choice: "s", access: nil, lockMachine: true)
        #expect(form.usesExisting)
        #expect(form.ready)
        form.preset(choice: "b", access: nil, lockMachine: false)
        #expect(!form.usesExisting)
    }

    @Test func linkButtonKeepsItsWidthWhileLinking() {
        let (dialog, form, _, link) = LinkEnvironmentDialog.make(machines: [Self.box])
        form.preset(choice: "b", access: nil, lockMachine: false)
        dialog.frame = NSRect(x: 0, y: 0, width: 448, height: 400)
        dialog.layoutSubtreeIfNeeded()
        let idle = link.frame.width
        form.isBusy = true
        dialog.layoutSubtreeIfNeeded()
        #expect(link.title == "Linking…")
        #expect(link.frame.width == idle)
        #expect(link.intrinsicContentSize.width <= link.frame.width)
    }

    @Test func rowsShowAccessStatusAndDot() {
        let now = Date(timeIntervalSince1970: 1_793_188_800)
        let link = PeerLinkSummary(environmentId: "b", label: "Sandbox B", urls: ["http://127.0.0.1:47399"], access: "auto",
                                   linkedAt: "2026-10-28T10:00:00.000Z", expiresAt: "2026-10-30T12:00:00.000Z", status: .reachable)
        let row = ConnectionsPageModel.LinkedEnvironments.link(link, now: now, canForget: true, forgetting: false)
        #expect(row.line == "Auto · Expires in 2 days. Link it again to renew.")
        #expect(row.dot == .warning)
        var expired = link
        expired.status = .expired
        #expect(ConnectionsPageModel.LinkedEnvironments.link(expired, now: now, canForget: false, forgetting: false).dot == .destructive)
    }

    @Test func snapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CW_SNAP_DIR"] else { return }
        let now = Date(timeIntervalSince1970: 1_793_188_800)
        let link = PeerLinkSummary(environmentId: "b", label: "Sandbox B", urls: ["http://127.0.0.1:47399"], access: "approval-required",
                                   linkedAt: "2026-10-28T10:00:00.000Z", expiresAt: "2026-11-27T10:00:00.000Z", status: .reachable)
        for dark in [false, true] {
            let view = ConnectionsSettingsView()
            var model = ConnectionsPageModel(cloudEnabled: false)
            model.linkedEnvironments = [
                .init(hostId: "a", title: "Linked environments · miniko", canLink: true,
                      state: .links([ConnectionsPageModel.LinkedEnvironments.link(link, now: now, canForget: true, forgetting: false)])),
                .init(hostId: "c", title: "Linked environments · Studio", canLink: true, state: .links([])),
            ]
            view.set(model)
            let size = NSSize(width: 720, height: view.height(forWidth: 720))
            let page = Snapshot.image(of: view, size: size, scale: 2, dark: dark)
            try page.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/connections-\(dark ? "dark" : "light").png"))
            let (dialog, form, _, _) = LinkEnvironmentDialog.make(machines: [Self.box, Self.ssh])
            form.preset(choice: nil, access: nil, lockMachine: false)
            dialog.frame = NSRect(x: 0, y: 0, width: 448, height: 10)
            dialog.layoutSubtreeIfNeeded()
            dialog.frame.size.height = dialog.height(forWidth: 448)
            dialog.layoutSubtreeIfNeeded()
            let d = Snapshot.image(of: dialog, size: dialog.frame.size, scale: 2, dark: dark)
            try d.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/link-dialog-\(dark ? "dark" : "light").png"))
        }
    }
}
