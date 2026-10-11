import AppKit
import Testing
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
        pill.update = base.onCheckStart(at)
        #expect(pill.iconStatus == .checking && pill.isInteractionDisabled && pill.tooltipText == "Checking for updates…")
        pill.update = base.onUpdateAvailable("0.1.3", at: at, releaseNotes: [.init(version: "0.1.3", items: ["a"], totalItems: 1)])
        // Off screen nothing spins, so the latch lets go at once.
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
}
