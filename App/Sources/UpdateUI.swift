import AppKit
import DesignSystem
import Features

/// The update UI around `UpdateController`: the sidebar pill (SidebarUpdatePill.tsx:176-289), the Settings
/// Version and Update track rows (SettingsPanels.tsx:280-391), the toasts (desktopUpdate.toast.tsx) and the
/// "Check for Updates..." menu item (DesktopApplicationMenu.ts:67-111).
@MainActor
final class UpdateUI {
    let updater: UpdateController
    private let runtime: RuntimeUpdateController
    private weak var window: NSWindow?
    private weak var pill: SidebarUpdatePillView?
    private weak var settings: SettingsController?
    private let toasts: () -> ToastViewport?
    private let showWindow: () -> Void
    private let footerCheck = SidebarUpdateCheck()
    var checkEnvironmentUpdates: @MainActor @Sendable () async -> Bool = { true }
    /// Dither holds CandyWrapper's runtime update while a thread runs on this Mac (`UpdateEverything.holdsServerUpdates`).
    var holdsServerUpdates: () -> Bool = { false }

    init(updater: UpdateController, runtime: RuntimeUpdateController, window: NSWindow, pill: SidebarUpdatePillView, settings: SettingsController,
         toasts: @escaping () -> ToastViewport?, showWindow: @escaping () -> Void) {
        self.updater = updater
        self.runtime = runtime
        self.window = window
        self.pill = pill
        self.settings = settings
        self.toasts = toasts
        self.showWindow = showWindow
        footerCheck.onChange = { [weak pill] state in pill?.isCheckingForUpdates = state == .checking }
        pill.onCheck = { [weak self] in self?.pillCheck() }
        pill.onDownload = { [weak self] in self?.pillDownload() }
        pill.onInstall = { [weak self] in self?.pillInstall() }
        pill.onOpenURL = { [weak self] url in self?.openReleaseNotes(url) }
        let c = settings.pageContext
        c.updateButton = { [weak self] in self?.settingsButton() }
        c.setUpdateTrack = { [weak self] channel in self?.setTrack(channel) }
        updater.observe { [weak self] in self?.refresh() }
        runtime.observe { [weak self] in self?.refresh() }
        c.runtimeUpdateButton = { [weak runtime] in runtime?.request() }
    }

    private var showsRuntime: Bool {
        if runtime.state.isRestarting || runtime.state.status == .downloading { return true }
        guard DesktopUpdateLogic.buttonAction(updater.state) == .none, updater.state.status != .downloading, !holdsServerUpdates() else { return false }
        return runtime.state.enabled && (DesktopUpdateLogic.buttonAction(runtime.state) != .none || runtime.state.status == .checking)
    }

    func refresh() {
        pill?.update = showsRuntime ? runtime.state : updater.state
        settings?.pageContext.update = updater.state
        settings?.pageContext.runtimeUpdate = runtime.state.enabled ? runtime.state : nil
        settings?.refreshPages()
    }

    private func setSettingsFlag(_ body: (SettingsPageContext) -> Void) {
        guard let settings else { return }
        body(settings.pageContext)
        settings.refreshPages()
    }

    private func toast(_ title: String, _ message: String?, _ kind: ToastQueue.Kind = .error) {
        toasts()?.show(ToastView(title: title, message: message, kind: kind))
    }

    /// `openDesktopUpdateReleaseNotes` (desktopUpdate.toast.tsx:12-22).
    private func openReleaseNotes(_ url: String) {
        if let u = URL(string: url), NSWorkspace.shared.open(u) { return }
        toast("Unable to open release notes", nil)
    }

    /// `showDesktopUpdateDownloadedToast` (desktopUpdate.toast.tsx:49-63).
    private func showDownloadedToast() {
        let view = ToastView(title: "Update downloaded", message: "Restart the app from the update button to install it.", kind: .success)
        if let url = DesktopUpdateLogic.releaseURL(DesktopUpdateLogic.downloadedVersion(updater.state)) {
            view.setMessageLink("Read more") { [weak self] in self?.openReleaseNotes(url) }
        }
        toasts()?.show(view)
    }

    // MARK: Pill

    private func pillCheck() {
        Task {
            await footerCheck.run(checks: [
                { [updater] in
                    let result = await updater.check(background: true)
                    return result.checked && result.state.errorContext != .check
                },
                checkEnvironmentUpdates
            ], hasUpdates: { [updater, runtime] in
                DesktopUpdateLogic.buttonAction(updater.state) != .none ||
                    DesktopUpdateLogic.buttonAction(runtime.state) != .none || pill?.hasServerUpdates == true
            })
            switch footerCheck.state {
            case .upToDate: toast("Up to date", nil, .success)
            case .failed: toast("Could not check all updates", "Try again when all update sources are available.")
            default: break
            }
        }
    }

    private func pillDownload() {
        if showsRuntime { runtime.request(); return }
        pill?.isActionPending = true
        Task {
            let result = await updater.download()
            if result.completed { showDownloadedToast() }
            if let error = DesktopUpdateLogic.actionError(accepted: result.accepted, completed: result.completed, state: updater.state) {
                toast("Could not download update", error)
            }
            pill?.isActionPending = false
        }
    }

    private func pillInstall() {
        if showsRuntime { runtime.request(); return }
        pill?.isActionPending = true
        confirmInstall(onCancel: { [weak self] in self?.pill?.isActionPending = false }) { [weak self] in
            guard let self else { return }
            Task {
                let result = await self.updater.install()
                if let error = DesktopUpdateLogic.actionError(accepted: result.accepted, completed: result.completed, state: self.updater.state) {
                    self.toast("Could not install update", error)
                }
                self.pill?.isActionPending = false
            }
        }
    }

    /// `dialogs.confirm` as `ConfirmDialogHost` draws it in the main window: the question is the title.
    private func confirmInstall(onCancel: @escaping () -> Void, then install: @escaping () -> Void) {
        guard let window else { return onCancel() }
        let copy = ConfirmCopy.resolve(DesktopUpdateLogic.installConfirmationMessage(updater.state))
        let dialog = DialogView(kind: .alertDialog, title: copy.title, message: copy.description ?? "")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: .default)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        var decided = false
        host.onDismiss = { if !decided { onCancel() } }
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host] in decided = true; host?.close(); install() }
    }

    // MARK: Settings

    private func settingsButton() {
        switch DesktopUpdateLogic.buttonAction(updater.state) {
        case .download:
            // The Settings button reports only a thrown error, never the result (SettingsPanels.tsx:328-339).
            Task { _ = await updater.download() }
        case .install:
            guard settings?.pageContext.updateActionPending != true else { return }
            setSettingsFlag { $0.updateActionPending = true }
            confirmInstall(onCancel: { [weak self] in self?.setSettingsFlag { $0.updateActionPending = false } }) { [weak self] in
                guard let self else { return }
                Task {
                    _ = await self.updater.install()
                    self.setSettingsFlag { $0.updateActionPending = false }
                }
            }
        case .none:
            Task {
                let result = await updater.check()
                if !result.checked {
                    toast("Could not check for updates", result.state.message ?? "Automatic updates are not available in this build.")
                }
            }
        }
    }

    private func setTrack(_ channel: DesktopUpdateState.Channel) {
        setSettingsFlag { $0.changingUpdateTrack = true }
        do { _ = try updater.setChannel(channel) } catch {
            toast("Could not change update track", error.localizedDescription)
        }
        setSettingsFlag { $0.changingUpdateTrack = false }
    }

    // MARK: Menu

    /// `handleCheckForUpdatesMenuClick` (DesktopApplicationMenu.ts:67-111). Electron's message box on macOS
    /// shows `message` as the alert text and `detail` under it; the title does not show.
    func menuCheck() {
        if let reason = updater.disabledReason {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Automatic updates are not available right now."
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        showWindow()
        Task {
            let s = await updater.check().state
            if s.status == .upToDate {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "CandyWrapper \(s.currentVersion) is currently the newest version available."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else if s.status == .error {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not check for updates."
                alert.informativeText = s.message ?? "An unknown error occurred. Please try again later."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
