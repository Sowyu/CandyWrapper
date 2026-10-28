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

    @Test func aMachineWithoutAnAddressAsksForOne() {
        let form = LinkEnvironmentFormView(machines: [Self.box, Self.ssh])
        form.preset(choice: "s", access: nil, lockMachine: true)
        #expect(form.needsAddress)
        form.addressInput.text = "https://ssh.example.ts.net"
        form.codeInput.text = "code"
        #expect(form.ready)
        #expect(form.urls == ["https://ssh.example.ts.net"])
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
