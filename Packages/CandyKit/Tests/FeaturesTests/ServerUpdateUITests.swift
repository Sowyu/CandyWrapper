import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The server update's wording, stage labels, confirm dialog and controls
/// (ServerUpdateAction.tsx, ComposerServerUpdateStatus.tsx, versionSkew.ts:122-138, ChatView.tsx:3143-3222).
@MainActor
struct ServerUpdateUITests {
    @Test func stageLabelsFoldTheHandoffIntoTheDownload() {
        #expect(ServerUpdateCopy.stageLabel(.downloading) == "Downloading…")
        #expect(ServerUpdateCopy.stageLabel(.installing) == "Downloading…")
        #expect(ServerUpdateCopy.stageLabel(.resuming) == "Restarting…")
    }

    @Test func composerNoticeStates() {
        let available = ComposerServerUpdateNotice(serverLabel: "box server", status: .available(serverVersion: "1.0.0", clientVersion: "2.0.0"),
                                                   guidance: "Update to stay in sync", action: "Update")
        #expect(available.title == "Server update available")
        #expect(available.content.titleTooltip == "box server 1.0.0 → 2.0.0")
        #expect(available.content.description == "Update to stay in sync")
        #expect(available.content.actions == ["Update"] && available.content.dismissLabel == "Dismiss update notice")
        #expect(available.content.priority == .notice && !available.content.spinner)

        let running = ComposerServerUpdateNotice(status: .running(.resuming), dismissible: true)
        #expect(running.title == "Updating server" && running.detail == "Restarting…")
        #expect(!running.content.spinner && running.content.priority == .urgent) // 3814 uses a static download glyph.
        #expect(!running.content.dismissible && running.content.actions.isEmpty)

        let failed = ComposerServerUpdateNotice(status: .failed("The server did not resume on t3@2.0.0."), action: "Retry")
        #expect(failed.title == "Could not update server")
        #expect(failed.content.variant == .error && failed.content.iconIsError && failed.content.actions == ["Retry"])
        #expect(failed.content.description == "The server did not resume on t3@2.0.0.")
    }

    @Test func offersFollowTheCapabilities() {
        #expect(ServerUpdateOffer(ServerUpdateCapabilities(selfUpdate: .bootService), targetVersion: "2.0.0", serverLabel: "box server") == .update(confirm: nil))
        #expect(ServerUpdateOffer(ServerUpdateCapabilities(selfUpdate: .desktopManaged), targetVersion: "2.0.0", serverLabel: "box server") == .desktopManual)
        let desktop = ServerUpdateOffer(ServerUpdateCapabilities(selfUpdate: .desktopManaged, desktopAppUpdate: true), targetVersion: "2.0.0", serverLabel: "box server")
        #expect(desktop == .update(confirm: "Update the T3 Code desktop app that runs the box server? It will close and relaunch on that machine."))

        let npm = ServerUpdateOffer(ServerUpdateCapabilities(installation: .object(["kind": .string("npm-global"), "prefix": .string("/opt/it's")])),
                                    targetVersion: "2.0.0", serverLabel: "box server")
        guard case .manual(let manual) = npm else { Issue.record("expected the manual path"); return }
        #expect(manual.label == "Copy update command" && manual.toastTitle == "Update command copied")
        #expect(manual.command == "npm install --global --prefix '/opt/it'\\''s' t3@2.0.0")
        #expect(manual.toastDescription == "Run `\(manual.command)` on box server, then restart t3 with your usual options.")

        guard case .manual(let relaunch) = ServerUpdateOffer(ServerUpdateCapabilities(installation: .object(["kind": .string("bunx")])),
                                                             targetVersion: "2.0.0", serverLabel: "box server") else { Issue.record("expected relaunch"); return }
        #expect(relaunch.label == "Copy relaunch command" && relaunch.command == "bunx t3@2.0.0")
        #expect(ServerUpdateCopy.guidance(.desktopManaged) == "Update the desktop app" && ServerUpdateCopy.guidance(.bootService) == "Update to stay in sync")
    }

    @Test func desktopConfirmDialog() throws {
        let question = ServerUpdateCopy.desktopConfirm(serverLabel: "Studio server")
        let copy = ConfirmCopy.resolve(question)
        #expect(copy.title == "Update the T3 Code desktop app that runs the Studio server?")
        #expect(copy.description == "It will close and relaunch on that machine.")
        #expect(ConfirmCopy.resolve(ServerUpdateCopy.desktopConfirmAll(labels: ["Studio", "Attic"])).title
                == "Update the T3 Code desktop apps on Studio, Attic?")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = DSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var answer: Bool?
        let host = ConfirmCopy.present(question, destructive: false, in: window) { answer = $0 }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let views = all(window.contentView!)
        let dialog = try #require(views.compactMap { $0 as? DialogView }.first)
        #expect(dialog.title == copy.title && dialog.message == copy.description)
        let buttons = dialog.footerButtons.compactMap { $0 as? ButtonView }
        #expect(buttons.map(\.title) == ["Cancel", "Confirm"])
        if let dir = ProcessInfo.processInfo.environment["SERVER_UPDATE_PEEK"] {
            let size = NSSize(width: 640, height: 400)
            let rep = Snapshot.image(of: window.contentView!, size: size, scale: 2, dark: true)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "server-update-confirm.png"))
        }
        buttons.last?.action?()
        #expect(answer == true)
        host.close(animated: false)
    }

    @Test func savedMachineRowOffersTheUpdateAndShowsProgress() {
        let row = EnvironmentRowView(frame: NSRect(x: 0, y: 0, width: 640, height: 56))
        var env = ConnectionsPageModel.Environment(id: "e", label: "Studio", machine: "server", enabled: true,
                                                  subtitle: "192.168.1.2:3773 · Connected · 1.0.0", statusIsError: false,
                                                  tooltip: "Connected\nUpdate available: 1.0.0 → 2.0.0", routes: [])
        row.configure(env)
        let resting = row.height(forWidth: 640)
        env.updateAction = .update("Update", enabled: true)
        row.configure(env)
        row.frame.size.height = row.height(forWidth: 640)
        row.layoutSubtreeIfNeeded()
        var clicked = false
        row.onUpdate = { clicked = true }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let button = all(row).compactMap { $0 as? ButtonView }.first { $0.accessibilityLabel() == "Update for Studio server" }
        #expect(button != nil && button?.isEnabled == true)
        button?.action?()
        #expect(clicked)

        env.updateAction = nil
        env.updateProgress = .running(stage: .downloading, fromVersion: "1.0.0", targetVersion: "2.0.0")
        row.configure(env)
        #expect(row.height(forWidth: 640) == resting + 20)
        let progress = all(row).compactMap { $0 as? ServerUpdateProgressView }.first
        #expect(progress?.accessibilityLabel() == "Downloading…")
        env.updateProgress = .idle
        row.configure(env)
        #expect(row.height(forWidth: 640) == resting)
    }
}
