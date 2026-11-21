import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// The Stable/Nightly switch for every machine (T3 PR #26288 and #27484; settings/UpdateTrackSwitchDialog.tsx:43-227 at
/// 4928). Picking a track asks the primary server for that track's newest release (`server.getNpmRelease`), then shows
/// which machines move and which stay with the reason. Confirming saves this app's Sparkle channel and runs each server's
/// update with the target track and checked database migration.
///
/// This app's own build follows Sparkle, which only installs newer builds: Stable to Nightly takes the next Nightly
/// build, and Nightly to Stable keeps this build until a Stable release passes it. No downgrade override is added.
@MainActor
final class UpdateTrackSwitch {
    private typealias L = UpdateTrackSwitchLogic
    private let updater: UpdateController
    private let environments: Environments
    private let serverUpdates: ServerUpdates
    private weak var window: NSWindow?
    private let toasts: () -> ToastViewport?
    private var modal: ModalHost?
    private var running = false

    init(updater: UpdateController, environments: Environments, serverUpdates: ServerUpdates, window: NSWindow,
         toasts: @escaping () -> ToastViewport?) {
        self.updater = updater
        self.environments = environments
        self.serverUpdates = serverUpdates
        self.window = window
        self.toasts = toasts
    }

    /// The switch needs `server.getNpmRelease` on the primary server; a 3824 server lacks it, and the track only saves.
    var available: Bool {
        guard let id = environments.primaryId, environments.state(id)?.status == .connected else { return false }
        return serverUpdates.capabilities(id).npmReleaseLookup
    }

    private func machines() -> [L.Machine] {
        environments.environmentIds.map { id in
            let d = serverUpdates.descriptor(id)
            return L.Machine(environmentId: id, label: environments.label(id) ?? id, serverVersion: d?.serverVersion,
                             connected: environments.state(id)?.status == .connected, canMaintain: serverUpdates.canUpdate(id),
                             updating: serverUpdates.state(id).isRunning, capabilities: serverUpdates.capabilities(id),
                             desktopAppChannelSwitch: d?.capability("desktopAppChannelSwitch") ?? false, platformOS: d?.platform?.os,
                             databaseMigration: d?.databaseMigration,
                             ownServer: serverUpdates.isOwnServer(id) || serverUpdates.ownRuntimeState(id) != nil)
        }
    }

    /// Connected machines still on the other track that a switch can move (SettingsPanels.tsx:198-215).
    func unswitched(selected: DesktopUpdateState.Channel) -> Int {
        machines().filter { $0.connected && $0.canMaintain && L.awaitsSwitch($0, channel: selected.rawValue) }.count
    }

    // MARK: Dialog

    func present(_ channel: DesktopUpdateState.Channel) {
        guard modal == nil, !running, let window, let primary = environments.primaryId else { return }
        let label = L.label(channel.rawValue)
        let checking = DialogView(kind: .alertDialog, title: "Switch to \(label)", message: "Checking releases…")
        let cancel = ButtonView("Cancel", variant: .outline)
        checking.footerButtons = [cancel]
        let host = ModalHost.present(checking, in: window)
        modal = host
        host.onDismiss = { [weak self] in self?.modal = nil }
        cancel.action = { [weak host] in host?.close() }
        guard let input = ServerNpmRelease.input(spec: ServerNpmRelease.spec(channel: channel.rawValue)) else { return }
        Task { [weak self, weak host] in
            do {
                let reply = try await self?.environments.request(primary, ServerNpmRelease.method, input)
                guard let self, let host, self.modal === host else { return }
                guard let reply, reply != .null, let found = try? JSONValueDecoder().decode(ServerNpmRelease.self, from: reply) else {
                    checking.message = "Could not find the latest \(label) release in this environment's npm registry."
                    return
                }
                host.close(animated: false)
                self.presentPlan(L.Release(channel: channel.rawValue, version: found.version, databaseMigration: found.databaseMigration))
            } catch {
                guard let self, let host, self.modal === host else { return }
                checking.message = "Could not check \(label) releases: \(error.localizedDescription)"
            }
        }
    }

    private func presentPlan(_ release: L.Release) {
        guard let window else { return }
        let label = L.label(release.channel)
        let (targets, skipped) = L.targets(machines(), release: release)
        // Track-only hosts save a setting and restart nothing, so they are neither listed nor counted.
        let moving = targets.filter { !$0.trackOnly }
        let rows = moving.map { t in
            UpdateEverythingLogic.Machine(environmentId: t.machine.environmentId, label: t.machine.label, serverVersion: t.machine.serverVersion,
                                          connected: true, canMaintain: true, updating: false, capabilities: t.machine.capabilities)
        }
        let description = UpdateEverythingLogic.describe(localVersion: nil, servers: rows, target: release.version, providerMachines: [], skipped: skipped)
        let saved = updater.state.channel.rawValue
        let idle = L.nothingToMove(channel: release.channel, savedChannel: saved, switchesLocal: false, crossesLocal: false,
                                   rows: description.rows, hasTargets: !targets.isEmpty)
        var notes = [idle.note, L.appNote(channel: release.channel, savedChannel: saved, updatesEnabled: updater.state.enabled)].compactMap { $0 }
        let threads = moving.reduce(into: (stopped: 0, continuing: 0)) { acc, t in
            let n = environments.snapshot(t.machine.environmentId)?.threads.filter { ["preparing", "starting", "running"].contains($0.status.rawValue) }.count ?? 0
            if t.machine.capabilities.threadContinuation && serverUpdates.continueThreads(t.machine.environmentId) { acc.continuing += n } else { acc.stopped += n }
        }
        if let line = UpdateEverythingLogic.threadsLine(stopped: threads.stopped, continuing: threads.continuing) { notes.append(line) }
        if let reason = idle.disabledReason { notes.append(reason) }

        var title = "Switch to \(label)?", message = "Version \(release.version)"
        if ThemeRuntime.isDither(dark: window.effectiveAppearance.isDark) {
            // Redesign leads with what changes: the servers, the threads, and not this app (UpdateTrackSwitchLogic.redesignLead).
            let lead = L.redesignLead(moves: moving.map { L.Move(machine: $0.machine.label, from: $0.machine.serverVersion, to: $0.targetVersion) },
                                      stopped: threads.stopped, continuing: threads.continuing)
            title = "Switch T3 servers to \(label)?"
            message = lead[0]
            notes = Array(lead.dropFirst()) + [idle.note, idle.disabledReason].compactMap { $0 }
        }
        let dialog = DialogView(kind: .alertDialog, title: title, message: message)
        dialog.maxWidth = 576
        if !description.rows.isEmpty {
            let content = UpdateEverythingDialogContent(description)
            dialog.panelContent = [content]
            content.onHeightChange = { [weak dialog] in guard let dialog else { return }; dialog.panelContent = dialog.panelContent; dialog.superview?.needsLayout = true }
        }
        if !notes.isEmpty { dialog.headerContent = TrackSwitchNotes(notes) }
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Switch to \(label)")
        ok.isEnabled = idle.disabledReason == nil
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        modal = host
        host.onDismiss = { [weak self] in self?.modal = nil }
        window.makeFirstResponder(cancel)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in
            host?.close()
            self?.run(release, targets: targets)
        }
    }

    // MARK: Run

    private func run(_ release: L.Release, targets: [L.Target]) {
        guard !running, let channel = DesktopUpdateState.Channel(rawValue: release.channel) else { return }
        let label = L.label(release.channel)
        // The saved track is the user's intent and stays even when a server cannot move yet.
        do { _ = try updater.setChannel(channel) } catch {
            toast("Could not switch to \(label)", error.localizedDescription, failed: true)
            return
        }
        running = true
        Task { [weak self] in
            guard let self else { return }
            // Sparkle now reads the new channel; Stable to Nightly finds the next Nightly build.
            if channel == .nightly, self.updater.state.enabled { _ = await self.updater.check(background: true) }
            var failures: [String] = []
            await withTaskGroup(of: (String, ServerUpdates.QuietOutcome).self) { group in
                for t in targets {
                    let switchTarget = ServerUpdates.SwitchTarget(version: t.targetVersion, channel: t.channel, databaseMigration: t.targetDatabaseMigration)
                    group.addTask { [serverUpdates] in
                        (t.machine.label, await serverUpdates.updateQuietly(t.machine.environmentId, serverLabel: t.machine.label, switchTarget: switchTarget))
                    }
                }
                for await (machine, outcome) in group {
                    if case .failed(let why) = outcome { failures.append("\(machine): \(why)") }
                }
            }
            self.running = false
            let moved = targets.filter { !$0.trackOnly }.count
            if failures.isEmpty {
                self.toast("Switched to \(label)", moved == 0 ? "The update track is saved." : "\(moved) \(moved == 1 ? "machine" : "machines") moved to \(release.version).", failed: false)
            } else {
                self.toast("Could not switch every machine to \(label)", failures.joined(separator: "\n"), failed: true)
            }
        }
    }

    private func toast(_ title: String, _ message: String?, failed: Bool) {
        toasts()?.show(ToastView(title: title, message: message, kind: failed ? .error : .success))
    }

    /// `pt-2 text-sm` paragraphs under the description, as Update everything shows its notes.
    private final class TrackSwitchNotes: DSView {
        private let blocks: [TextBlockView]
        init(_ paragraphs: [String]) {
            blocks = paragraphs.map { TextBlockView($0, font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.foreground)) }
            super.init(frame: .zero)
            blocks.forEach(addSubview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize {
            let w = max(1, bounds.width)
            let text = blocks.reduce(0) { $0 + $1.layout(forWidth: w).height }
            return NSSize(width: NSView.noIntrinsicMetric, height: text + 8 + 16 * CGFloat(blocks.count - 1))
        }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize.width != frame.width
            super.setFrameSize(newSize)
            if changed { invalidateIntrinsicContentSize() }
        }
        override func layout() {
            super.layout()
            var y: CGFloat = 8
            for b in blocks {
                let h = b.layout(forWidth: bounds.width).height
                b.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
                y += h + 16
            }
        }
    }
}
