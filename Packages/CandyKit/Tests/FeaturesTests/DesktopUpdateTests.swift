import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// T3's update machine, button logic and release note shaping (updateMachine.test.ts,
/// desktopUpdate.logic.test.ts, releaseNotes.test.ts), and the pill's presentation.
@MainActor
struct DesktopUpdateTests {
    let at = Date(timeIntervalSince1970: 0)
    var base: DesktopUpdateState { DesktopUpdateState(currentVersion: "0.1.2", channel: .nightly, enabled: true) }

    @Test func machine() {
        let checking = base.onCheckStart(at)
        #expect(checking.status == .checking && checking.downloadPercent == nil)
        let available = checking.onUpdateAvailable("0.1.3", at: at)
        #expect(available.status == .available && available.availableVersion == "0.1.3")
        let failed = available.onDownloadStart().onDownloadFailure("bad signature")
        #expect(failed.status == .available && failed.errorContext == .download && failed.canRetry)
        #expect(base.onDownloadFailure("x").status == .error)
        let done = available.onDownloadStart().onDownloadProgress(42).onDownloadComplete("0.1.3")
        #expect(done.status == .downloaded && done.downloadedVersion == "0.1.3" && done.downloadPercent == 100)
        // A held download survives a failed check, a check that finds nothing and the same version again.
        #expect(done.onCheckStart(at).onCheckFailure("offline", at: at).status == .downloaded)
        #expect(done.onCheckStart(at).onNoUpdate(at: at).status == .downloaded)
        #expect(done.onUpdateAvailable("0.1.3", at: at).status == .downloaded)
        #expect(base.onCheckStart(at).onCheckFailure("offline", at: at).errorContext == .check)
        let up = available.onNoUpdate(at: at)
        #expect(up.status == .upToDate && up.availableVersion == nil)
        let install = done.onInstallFailure("no")
        #expect(install.status == .downloaded && install.errorContext == .install)
        // Progress goes out on 10 percent steps and at 100 (DesktopUpdates.ts:230-246).
        let at41 = available.onDownloadStart().onDownloadProgress(41)
        #expect(!at41.shouldBroadcastProgress(49) && at41.shouldBroadcastProgress(50) && at41.onDownloadProgress(99).shouldBroadcastProgress(100))
    }

    @Test func logic() {
        let available = base.onUpdateAvailable("0.1.3", at: at)
        #expect(DesktopUpdateLogic.buttonAction(available) == .download)
        #expect(DesktopUpdateLogic.buttonTooltip(available) == "Update 0.1.3 ready to download")
        let downloading = available.onDownloadStart().onDownloadProgress(42.7)
        #expect(DesktopUpdateLogic.buttonTooltip(downloading) == "Downloading update (42%)")
        #expect(DesktopUpdateLogic.isButtonDisabled(downloading))
        let done = downloading.onDownloadComplete("0.1.3")
        #expect(DesktopUpdateLogic.buttonAction(done) == .install)
        #expect(DesktopUpdateLogic.buttonTooltip(done) == "Update 0.1.3 downloaded. Click to restart and install.")
        #expect(DesktopUpdateLogic.installConfirmationMessage(done)
                == "Install update 0.1.3 and restart CandyWrapper?\n\nAny running tasks will be interrupted. Make sure you're ready before continuing.")
        #expect(DesktopUpdateLogic.releaseURL("0.1.3") == "https://github.com/Sowyu/CandyWrapper/releases/tag/v0.1.3")
        #expect(DesktopUpdateLogic.settingsButton(base.onCheckStart(at).onNoUpdate(at: at)).label == "Up to Date")
        #expect(DesktopUpdateLogic.settingsButton(available).description == "Update available.")
        #expect(!DesktopUpdateLogic.canCheck(DesktopUpdateState(currentVersion: "1", channel: .latest, enabled: false)))
        #expect(DesktopUpdateLogic.actionError(accepted: true, completed: false, state: available.onDownloadFailure(" bad ")) == "bad")
    }

    @Test func releaseNotes() {
        let body = """
        ## What's Changed
        * Fix [the pill](https://x) by @a in https://github.com/o/r/pull/1
        * **Bold** item
        <ul><li>Html &amp; item</li></ul>

        ## New Contributors
        * someone
        """
        let (notes, omitted) = DesktopUpdateReleaseNotes.normalize([("0.1.3", body), ("0.1.2", nil)])
        #expect(omitted == 0 && notes.count == 1)
        #expect(notes[0].items == ["Html & item", "Bold item", "Fix the pill by @a in https://github.com/o/r/pull/1"])
        let many = (1...12).map { "- item \($0)" }.joined(separator: "\n")
        let shaped = DesktopUpdateReleaseNotes.normalize((1...7).map { ("0.1.\($0)", many) })
        #expect(shaped.notes.count == 6 && shaped.omitted == 1)
        #expect(shaped.notes[0].items.count == 8 && shaped.notes[0].items.first == "item 12" && shaped.notes[0].totalItems == 12)
        let long = DesktopUpdateReleaseNotes.truncate(String(repeating: "a", count: 300))
        #expect(long.utf16.count == 220 && long.hasSuffix("..."))
    }

    @Test func pillPresentation() {
        let pill = SidebarUpdatePillView()
        #expect(pill.tooltipText == "Check for updates" && pill.isInteractionDisabled)
        pill.update = base
        #expect(!pill.isInteractionDisabled && pill.iconStatus == .idle)
        pill.update = base.onNoUpdate(at: at)
        #expect(pill.iconStatus == .idle && !pill.isInteractionDisabled && !pill.isHidden)
        #expect(pill.tooltipText == "Check for updates")
        pill.update = base.onCheckStart(at)
        #expect(pill.iconStatus == .checking && pill.isInteractionDisabled && pill.tooltipText == "Checking for updates…")
        pill.update = base.onUpdateAvailable("0.1.3", at: at, releaseNotes: [.init(version: "0.1.3", items: ["a"], totalItems: 1)])
        // Completing the check restores the update glyph.
        #expect(pill.iconStatus == .available && pill.showsReleaseNotes)
        pill.update = pill.update?.onDownloadStart()
        #expect(pill.iconStatus == .downloading && pill.isInteractionDisabled)
        pill.update = pill.update?.onDownloadComplete("0.1.3")
        #expect(pill.iconStatus == .downloaded && pill.buttonAction == .install)
        var stable = pill.update!
        stable.channel = .latest
        pill.update = stable
        #expect(!pill.showsReleaseNotes && pill.tooltipText == "Update 0.1.3 downloaded. Click to restart and install.")
    }

    @Test func manualServerBannerAlsoLightsTheFooter() {
        let target = ServerVersionSkewLogic.clientVersion
        let capabilities = ServerUpdateCapabilities([:])
        let manual = UpdateEverythingLogic.Machine(environmentId: "sandbox", label: "Sandbox",
            serverVersion: "0.1.1-nightly.20261017.3234", connected: true, canMaintain: true,
            updating: false, capabilities: capabilities)
        let plan = UpdateEverythingLogic.serverTargets([manual], target: target)
        #expect(plan.targets.isEmpty && plan.skipped.first?.reason == "needs a manual update")
        if case .manual(let offer) = ServerUpdateOffer(capabilities, targetVersion: target, serverLabel: "Sandbox") {
            #expect(offer.label == "Copy relaunch command")
        } else { Issue.record("The same server must offer the banner's manual relaunch action") }
        let notice = UpdateEverythingLogic.serverUpdateNotice([manual], target: target)
        #expect(notice == "Server update available")
        let pill = SidebarUpdatePillView()
        pill.update = base
        let pending = UpdateEverythingLogic.Pending(servers: plan.targets.count, providers: 2)
        pill.setEverything(summary: "Update 2 providers", pending: pending, serverNotice: notice)
        var guidance = 0, automatic = 0, appDownloads = 0
        pill.onShowServerUpdates = { guidance += 1 }
        pill.onEverything = { automatic += 1 }
        pill.onDownload = { appDownloads += 1 }
        #expect(!pill.isHidden && pill.iconStatus == .everything && pill.hasServerUpdates)
        #expect(pill.tooltipText == "Server update available" && !pill.isInteractionDisabled)
        #expect(pending.count == 2) // Manual servers do not become automatic Update all targets.
        pill.performAction()
        #expect(guidance == 1 && automatic == 0)
        pill.update = base.onUpdateAvailable("0.1.3", at: at)
        #expect(pill.iconStatus == .available)
        pill.performAction()
        #expect(appDownloads == 1 && guidance == 1)
        pill.update = base
        pill.setEverything(summary: "Update a server", pending: .init(servers: 1), serverNotice: notice)
        pill.performAction()
        #expect(automatic == 1)
        // A held automatic pass still offers the non-mutating guidance.
        pill.setEverything(summary: nil, pending: .init(servers: 1), serverNotice: notice)
        pill.performAction()
        #expect(guidance == 2 && automatic == 1)
        pill.setEverything(summary: "Update 2 providers", pending: .init(providers: 2))
        #expect(pill.iconStatus == .idle && !pill.hasServerUpdates)
    }

    @Test func serverNoticeTracksVersionsSeparatelyFromUpdatePermission() {
        let target = ServerVersionSkewLogic.clientVersion
        var server = UpdateEverythingLogic.Machine(environmentId: "sandbox", label: "Sandbox",
            serverVersion: "0.1.1-nightly.20261017.3234", connected: true, canMaintain: false,
            updating: false, capabilities: ServerUpdateCapabilities([:]))
        #expect(UpdateEverythingLogic.serverTargets([server], target: target).targets.isEmpty)
        #expect(UpdateEverythingLogic.serverUpdateNotice([server], target: target) != nil)
        server.serverVersion = target
        #expect(UpdateEverythingLogic.serverUpdateNotice([server], target: target) == nil)
        server.serverVersion = nil
        #expect(UpdateEverythingLogic.serverUpdateNotice([server], target: target) == nil)
        server.serverVersion = "0.1.1-nightly.20261017.3234"
        server.connected = false
        #expect(UpdateEverythingLogic.serverUpdateNotice([server], target: target) == nil)
        server.connected = true
        server.ownServer = true
        #expect(UpdateEverythingLogic.serverUpdateNotice([server], target: target) == nil)
    }

    @Test func footerUpdateScope() {
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        for redesign in [false, true] {
            var theme = ThemeRuntimeInput()
            theme.ditherDark = redesign
            theme.ditherLight = redesign
            ThemeRuntime.apply(theme)
            for dark in [false, true] {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let pill = SidebarUpdatePillView()
                host.addSubview(pill)
                let account = SidebarAccountRowView()
                host.addSubview(account)
                let cases: [(UpdateEverythingLogic.Pending, Bool, SidebarUpdatePillView.IconStatus)] = [
                    (.init(providers: 1), false, .idle),
                    (.init(app: true), false, .available),
                    (.init(servers: 1), false, .everything),
                    (.init(app: true, servers: 1), false, .everything),
                    (.init(runtime: true), false, .available),
                    (.init(app: true, runtime: true, servers: 2, providers: 3), false, .everything),
                    (.init(), false, .idle),
                ]
                for (pending, hidden, icon) in cases {
                    pill.update = pending.app || pending.runtime ? base.onUpdateAvailable("0.1.3", at: at) : base
                    pill.setEverything(summary: "Update everything", pending: pending)
                    account.updateAllCount = pending.count
                    #expect(pill.isHidden == hidden)
                    #expect(pill.iconStatus == icon)
                    let titles = account.menuItems.map(\.title)
                    #expect(titles.prefix(3) == ["Settings", "Usage", "Appearance"])
                    #expect(titles.dropFirst(3) == (pending.count > 0 ? ["Update all (\(pending.count))"] : []))
                }
            }
        }
    }

    @Test func refreshButtonKeepsAccountRowVisible() throws {
        var theme = ThemeRuntimeInput()
        theme.ditherDark = true
        theme.ditherLight = true
        ThemeRuntime.apply(theme)
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        for dark in [false, true] {
            let container = SidebarContainerView()
            let sidebar = SidebarContentView()
            container.content = sidebar
            let image = Snapshot.image(of: container, size: NSSize(width: 256, height: 780), dark: dark)
            #expect(!sidebar.updatePill.isHidden)
            #expect(!sidebar.accountRow.isHidden)
            // The avatar must actually reach the bitmap, rather than sit behind the sidebar surface.
            let avatar = try #require(image.colorAt(x: 36, y: 1500)?.usingColorSpace(.sRGB))
            let outside = try #require(image.colorAt(x: 4, y: 1500)?.usingColorSpace(.sRGB))
            #expect(abs(avatar.redComponent - outside.redComponent) > 0.02)
        }
    }
}
