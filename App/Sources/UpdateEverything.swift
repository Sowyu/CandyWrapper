import AppKit
import DesignSystem
import Features
import T3Protocol

/// "Update everything" behind the sidebar update button (T3 3105 d83929ad0, eeaac49a9: sidebar/useUpdateEverything.ts,
/// UpdateEverythingDialog.tsx, updateEverythingRun.tsx, SidebarUpdatePill.tsx:298-370). While other machines' servers
/// are behind, the button shows the circled arrow and one click asks to update them all: providers,
/// then servers, then this app last. Nothing here runs while nobody updates; it recomputes on the changes it observes.
@MainActor
final class UpdateEverything {
    typealias L = UpdateEverythingLogic
    private let updater: UpdateController
    private let environments: Environments
    private let serverUpdates: ServerUpdates
    private weak var pill: SidebarUpdatePillView?
    private weak var window: NSWindow?
    private let toasts: () -> ToastViewport?
    private let providers: (String) -> [ServerProvider]
    private var run: L.Run? { didSet { refresh() } }
    private var plan: Plan?
    /// Dither's account row: its menu's "Update all (N)" runs `updateAll`.
    weak var account: SidebarAccountRowView? {
        didSet { account?.onUpdateAll = { [weak self] in self?.updateAll() }; refresh() }
    }
    /// The hold flipped: `UpdateUI` re-reads whether the runtime update shows.
    var onHoldChange: (() -> Void)?
    private var held = false

    struct Plan {
        var summary: String
        var description: L.Description
        var servers: [L.Machine]
        var skipped: [L.Skipped]
        var providerMachines: [(environmentId: String, label: String, candidates: [ServerProvider])]
        var localVersion: String?
        var serverNotice: String?
        /// The environments the notice counts, so its click scrolls to the first one's row.
        var serverNoticeIds: [String] = []
    }

    /// The first environment the server update notice counts.
    var firstServerNoticeId: String? { plan?.serverNoticeIds.first }

    init(updater: UpdateController, environments: Environments, serverUpdates: ServerUpdates, pill: SidebarUpdatePillView, window: NSWindow,
         toasts: @escaping () -> ToastViewport?, providers: @escaping (String) -> [ServerProvider]) {
        self.updater = updater
        self.environments = environments
        self.serverUpdates = serverUpdates
        self.pill = pill
        self.window = window
        self.toasts = toasts
        self.providers = providers
        pill.onEverything = { [weak self] in self?.confirm() }
        pill.onCapsuleAction = { [weak self] in self?.capsuleAction($0) }
        pill.onCapsuleDismiss = { [weak self] in self?.dismissSettled() }
        pill.onCapsuleRestart = { [weak self] in self?.restartToUpdate() }
        environments.observe { [weak self] in self?.refresh() }
        serverUpdates.observe { [weak self] in self?.refresh() }
        updater.observe { [weak self] in self?.refresh() }
        // Turns starting and stopping on this Mac, and a switch to or from Dither, move the hold.
        environments.observeShell { [weak self] in self?.holdMayHaveChanged() }
        NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdMayHaveChanged() }
        }
        // A pass that ended with this app's relaunch reports once the app is back (`DesktopUpdateLaunchNotice`).
        DispatchQueue.main.async { [weak self] in self?.showSavedResult() }
        #if DEBUG
        // Shows the capsule in one state without a real pass: progress, slow, failed, failures, countdown or installing.
        // `restored` and `restored-failed` save a pass as an app update would, which the launch above restores.
        if let mode = ProcessInfo.processInfo.environment["CANDY_DEBUG_UPDATE_CAPSULE"] {
            if mode.hasPrefix("restored") { Self.saveDebugPass(failed: mode == "restored-failed", appVersion: updater.currentVersion) }
            else { run = Self.debugRun(mode) }
        }
        #endif
    }

    /// A provider list changed somewhere (the composer's config observers).
    func providersChanged() { refresh() }

    /// T3 3669 ws.ts:2310-2380: refreshModels invalidates the latest-version cache before discovery.
    /// One outcome per machine that failed, by its name, else `.checked`.
    func check() async -> [SidebarUpdateCheck.Outcome] {
        async let servers = serverUpdates.check()
        async let runtime = serverUpdates.runtimeUpdater?.check() ?? true
        let runtimeId = serverUpdates.runtimeUpdater?.environmentId
        let providers = await withTaskGroup(of: String?.self) { group in
            for id in environments.environmentIds where environments.state(id)?.status == .connected {
                group.addTask { [weak self] in await self?.checkProviders(id) ?? false ? nil : id }
            }
            var failed: [String] = []
            for await id in group { if let id { failed.append(id) } }
            return failed
        }
        let (serverFailed, runtimeResult) = await (servers, runtime)
        refresh()
        var failed = serverFailed + providers
        if !runtimeResult, let runtimeId { failed.append(runtimeId) }
        var outcomes: [SidebarUpdateCheck.Outcome] = []
        for id in environments.environmentIds where failed.contains(id) { outcomes.append(.machineFailed(environments.label(id) ?? id)) }
        if !runtimeResult, runtimeId == nil { outcomes.append(.machineFailed("This Mac")) }
        return outcomes.isEmpty ? [.checked] : outcomes
    }

    private func checkProviders(_ id: String) async -> Bool {
        do {
            _ = try await environments.request(id, "server.refreshProviders",
                .object(["refreshModels": .bool(true)]), timeout: .seconds(60))
            return true
        } catch { return false }
    }

    private var action: DesktopUpdateLogic.ButtonAction { DesktopUpdateLogic.buttonAction(updater.state) }

    /// A thread runs on this Mac: in the local environment, the one CandyWrapper starts or was pointed at first.
    private var runningOnThisMac: Bool {
        guard let id = environments.primaryId else { return false }
        return environments.snapshot(id)?.threads.contains { RunningThreadKeepAlive.isRunning($0.status) } ?? false
    }

    // ponytail: the hold reads the window's appearance only when the shell or theme changes; a light/dark flip with Dither in one
    // appearance alone waits for the next turn event, observe effectiveAppearance if that shows
    /// Dither holds server, runtime and provider updates while a thread runs on this Mac (`UpdateEverythingLogic.offered`).
    var holdsServerUpdates: Bool {
        ThemeRuntime.isDither(dark: window?.effectiveAppearance.isDark ?? false) && runningOnThisMac
    }

    private func holdMayHaveChanged() {
        let now = holdsServerUpdates
        guard now != held else { return }
        held = now
        refresh()
        onHoldChange?()
    }

    private var runtimeHasUpdate: Bool {
        guard let r = serverUpdates.runtimeUpdater?.state, r.enabled else { return false }
        return DesktopUpdateLogic.buttonAction(r) != .none
    }

    private func machines() -> [L.Machine] {
        environments.environmentIds.filter { serverUpdates.ownRuntimeState($0) == nil && !serverUpdates.isOwnServer($0) }.map { id in
            let caps = serverUpdates.capabilities(id)
            return L.Machine(environmentId: id, label: environments.label(id) ?? id, serverVersion: serverUpdates.descriptor(id)?.serverVersion,
                             connected: environments.state(id)?.status == .connected, canMaintain: serverUpdates.canUpdate(id),
                             updating: serverUpdates.state(id).isRunning, capabilities: caps, ownServer: serverUpdates.isOwnServer(id),
                             continuesThreads: caps.threadContinuation && serverUpdates.continueThreads(id),
                             turnedOff: environments.saved.first { $0.environmentId == id }?.enabled == false,
                             connectionError: environments.state(id)?.status == .connected ? nil : environments.state(id)?.lastFailure,
                             primary: id == environments.primaryId)
        }
    }

    // ponytail: no npm check before a CLI server updates (`useNpmReleasePublished`); the target is the pinned T3 release, already on npm
    private func makePlan() -> Plan {
        let target = ServerVersionSkewLogic.clientVersion
        let machineSnapshot = machines()
        let (servers, skipped) = L.serverTargets(machineSnapshot, target: target)
        let providerMachines = environments.environmentIds.compactMap { id -> (environmentId: String, label: String, candidates: [ServerProvider])? in
            // ProviderUpdatesAction.tsx (#23183): only machines whose session may manage providers.
            guard environments.state(id)?.status == .connected,
                  environments.authSession(id).map({ $0.grants(AuthScopes.providersManage) }) ?? true else { return nil }
            let all = providers(id)
            let candidates = ProviderUpdateCandidates.candidates(all).filter { ProviderUpdateCandidates.canOneClick($0, among: all) }
            return candidates.isEmpty ? nil : (id, environments.label(id) ?? id, candidates)
        }
        let local = action != .none ? DesktopUpdateLogic.downloadedVersion(updater.state) : nil
        let d = L.describe(localVersion: local, servers: servers, target: target,
                           providerMachines: providerMachines.map { ($0.environmentId, $0.label, $0.candidates.map { SidebarProviderUpdatePillModel.displayName($0.driver) }) },
                           localMachines: environments.environmentIds.filter { serverUpdates.isOwnServer($0) }.map { ($0, environments.label($0) ?? $0) }, skipped: skipped)
        return Plan(summary: d.summary, description: d, servers: servers, skipped: skipped, providerMachines: providerMachines, localVersion: local,
                    serverNotice: L.serverUpdateNotice(machineSnapshot, target: target),
                    serverNoticeIds: L.serverUpdateNoticeMachines(machineSnapshot, target: target).map(\.environmentId))
    }

    private func refresh() {
        let next = makePlan()
        plan = next
        // The independently downloaded runtime keeps its Download / Restart buttons. Providers
        // and service-managed servers retain their own update actions while it waits.
        let runtime = serverUpdates.runtimeUpdater?.state
        let runtimeOffer = runtime.map { $0.enabled && (DesktopUpdateLogic.buttonAction($0) != .none || $0.status == .downloading || $0.isRestarting) } ?? false
        held = holdsServerUpdates
        var pending = L.Pending(app: action != .none, runtime: runtimeHasUpdate, servers: next.servers.count,
                                providers: next.providerMachines.reduce(0) { $0 + $1.candidates.count })
        var summary = next.summary
        #if DEBUG
        // Pretend providers wait, to check "Update all (N)" without lighting the update button.
        if let fake = ProcessInfo.processInfo.environment["CANDY_DEBUG_PENDING_PROVIDERS"].flatMap(Int.init), fake > 0 {
            pending.providers += fake
            summary = "Update \(fake) providers"
        }
        #endif
        pill?.setEverything(summary: held || runtimeOffer ? nil : summary, pending: pending, serverNotice: next.serverNotice)
        account?.updateAllCount = L.offered(pending, runningOnThisMac: runningOnThisMac).count
        pill?.run = run.map { ("", $0.localVersion != nil) }
        pill?.capsule = run.map(capsule)
        scheduleTick()
        if !followed.isEmpty { checkFollowed() }
    }

    // MARK: The capsule (SidebarUpdateCapsule.tsx at 5258)

    #if DEBUG
    private static func debugRun(_ mode: String) -> L.Run {
        let now = Date().timeIntervalSince1970
        func m(_ id: String, server: Bool = true, at: Double = now, failed: Bool? = nil, failure: String? = nil) -> L.RunMachine {
            L.RunMachine(environmentId: "debug-\(id)", label: id, updatesProviders: !server, updatesServer: server, startedAt: at,
                         failed: failed, failure: failure)
        }
        switch mode {
        case "slow": return L.Run(localVersion: nil, phase: .providers, machines: [m("studio", server: false, at: now - 245), m("alvin", failed: false)])
        case "failed": return L.Run(localVersion: nil, phase: .servers, machines: [m("studio", failed: true, failure: "Connection lost"), m("alvin", failed: false)])
        case "failures": return L.Run(localVersion: nil, phase: .servers, machines: [m("studio", server: false, failed: true, failure: "Codex: offline"),
                                                                                   m("alvin", server: false, failed: true, failure: "Claude: offline")])
        case "countdown": return L.Run(localVersion: "0.0.99", phase: .countdown, restartAt: now + 9, machines: [m("alvin", failed: false)])
        case "installing": return L.Run(localVersion: "0.0.99", phase: .installing, machines: [m("alvin", failed: false)])
        default: return L.Run(localVersion: "0.0.99", phase: .servers, machines: [m("studio"), m("alvin", failed: false)])
        }
    }

    /// A saved pass with machines that never connect here: `restored` shows them restarting until the 32-minute deadline,
    /// `restored-failed` starts them past it, so they fail at once and offer Dismiss, as a machine that is gone does.
    private static func saveDebugPass(failed: Bool, appVersion: String) {
        let now = Date().timeIntervalSince1970
        let startedAt = failed ? now - L.handoffTimeout - 60 : now - 90
        let servers = ["studio", "alvin"].map { L.HandedOffServer(environmentId: "debug-\($0)", label: $0, targetVersion: "9.9.9", startedAt: startedAt) }
        let pass = L.SavedPass(savedAt: now, result: L.Result(localVersion: appVersion, updatedServers: 0, updatedProviders: 0, failures: []),
                               handedOff: servers)
        if let data = try? JSONEncoder().encode(pass) { UserDefaults.standard.set(data, forKey: savedKey) }
    }
    #endif

    private func statuses(_ run: L.Run) -> [L.MachineStatus] {
        run.machines.map { L.status($0, phase: run.phase, server: serverUpdates.state($0.environmentId)) }
    }

    /// The capsule for a pass: this app is CandyWrapper's own Sparkle update, the rows are other machines' servers and
    /// providers. CandyWrapper's runtime never joins a pass, so it has no row.
    private func capsule(_ run: L.Run) -> SidebarUpdateCapsule {
        let now = Date().timeIntervalSince1970
        let statuses = statuses(run)
        let s = updater.state
        let local: L.LocalState? = run.localVersion == nil ? nil : s.status == .downloading ? .downloading(percent: s.downloadPercent) : .waiting
        let current = run.machines.contains { $0.handedOffVersion != nil && $0.failed == true } ? machines() : []
        let view = L.describeCapsule(run, statuses: statuses, local: local, now: now,
                                     restored: run.machines.map { L.restoredRetry($0, current: current) })
        let rows = zip(run.machines, statuses).map { m, status in
            SidebarUpdateCapsule.Popover.Row(label: m.label,
                status: status.rawValue + (status.isActive && status != .waiting ? " \(L.elapsed(now - m.startedAt))" : ""),
                failed: status == .failed, failure: m.failure)
        }
        let localLine: SidebarUpdateCapsule.Popover.Local? = run.localVersion != nil
            ? .status(L.localStatus(run, local: local, now: now)) : action == .install ? .restartToUpdate : nil
        let settled = !statuses.contains { $0.isActive && $0 != .waiting } && run.localVersion == nil
        return SidebarUpdateCapsule(view: view, countdown: run.restartSeconds(now: now),
            popover: .init(local: localLine, rows: rows, showsDismiss: settled && statuses.contains(.failed) && view.action != .dismiss))
    }

    private var tick: DispatchWorkItem?

    /// `useNow`: a new `now` each second of the countdown and every 30 seconds while a machine works; nothing otherwise.
    private func scheduleTick() {
        tick?.cancel()
        tick = nil
        guard let run, let interval = L.tickInterval(run, statuses: statuses(run)) else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        tick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func capsuleAction(_ action: SidebarUpdateCapsule.Action) {
        switch action {
        case .later: decideRestart?(false)
        case .retry: retryFailedServers()
        case .dismiss: dismissSettled()
        }
    }

    /// `dismissSettledUpdateRunMachines`: settled rows leave; the pass closes when nothing else shows.
    private func dismissSettled() {
        guard var r = run else { return }
        r.machines.removeAll { $0.failed != nil }
        run = L.closeFinished(r)
    }

    /// `retryFailedUpdateRunServers` (updateEverythingRun.tsx:66-126): failed servers update again; one already on
    /// the target only settles.
    private func retryFailedServers() {
        guard var r = run else { return }
        let target = ServerVersionSkewLogic.clientVersion
        var retried: [L.RunMachine] = []
        let now = Date().timeIntervalSince1970
        // A row restored after this app relaunched retries from the server as it is now (#41964, updateEverythingRun.tsx:84-126).
        let current = machines()
        for i in r.machines.indices where r.machines[i].failed == true && !r.machines[i].updatesServer {
            switch L.restoredRetry(r.machines[i], current: current) {
            case .current?:
                r.machines[i].failure = r.machines[i].providerFailure
                r.machines[i].failed = r.machines[i].providerFailure != nil
            case .update?:
                r.machines[i].updatesServer = true
                r.machines[i].handedOffVersion = nil
            case nil: break
            }
        }
        for i in r.machines.indices where r.machines[i].failed == true && r.machines[i].updatesServer {
            let id = r.machines[i].environmentId
            if let v = serverUpdates.descriptor(id)?.serverVersion, !ServerVersionSkewLogic.serverIsBehind(v, client: target) {
                r.machines[i].updatesServer = false
                r.machines[i].failure = r.machines[i].providerFailure
                r.machines[i].failed = r.machines[i].providerFailure != nil
                continue
            }
            r.machines[i].failed = nil
            r.machines[i].failure = nil
            r.machines[i].startedAt = now
            retried.append(r.machines[i])
        }
        run = L.closeFinished(r)
        for m in retried {
            Task { [weak self, serverUpdates] in
                let outcome = await serverUpdates.updateQuietly(m.environmentId, serverLabel: m.label)
                let failure: String? = switch outcome {
                case .updated: m.providerFailure
                case .failed(let why): why
                case .skipped: "Could not start the update"
                }
                self?.settle(m.environmentId, failure: failure, serverUpdated: outcome == .updated)
            }
        }
    }

    /// The popover's Restart to update once this app's download waits (SidebarUpdatePill.tsx:451-464).
    private func restartToUpdate() {
        guard run?.localVersion == nil, action == .install, let version = DesktopUpdateLogic.downloadedVersion(updater.state) else { return }
        save(L.Result(localVersion: version, updatedServers: 0, updatedProviders: 0, failures: []))
        Task { [weak self, updater] in
            let installed = await updater.install()
            if !(installed.accepted && DesktopUpdateLogic.actionError(accepted: installed.accepted, completed: installed.completed, state: updater.state) == nil) {
                Self.clearSaved()
            }
            self?.refresh()
        }
    }

    private var decideRestart: ((Bool) -> Void)?

    /// `waitForUpdateRestart`: the capsule counts down, Later answers false, the end of the count true.
    private func waitForRestart() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.decideRestart?(true) } }
            decideRestart = { [weak self] restart in
                timer.cancel()
                self?.decideRestart = nil
                done.resume(returning: restart)
            }
            if var r = run { r.phase = .countdown; r.restartAt = Date().timeIntervalSince1970 + L.restartDelay; run = r }
            DispatchQueue.main.asyncAfter(deadline: .now() + L.restartDelay, execute: timer)
        }
    }

    /// Dither's "Update all (N)": the Update everything pass when servers or providers wait (the runtime asks after it),
    /// else what the update button does now, which is the runtime's or this app's own update.
    private func updateAll() {
        let plan = makePlan()
        if !holdsServerUpdates, !(plan.servers.isEmpty && plan.providerMachines.isEmpty) {
            confirm(runtimeAfter: runtimeHasUpdate)
        } else {
            pill?.performAction()
        }
    }

    // MARK: Confirmation (UpdateEverythingDialog.tsx)

    /// Running threads on the servers that restart; `continuing` counts those that can resume after.
    private func runningThreads(_ servers: [L.Machine]) -> (stopped: Int, continuing: Int) {
        var stopped = 0, continuing = 0
        for s in servers {
            let n = environments.snapshot(s.environmentId)?.threads.filter { ["preparing", "starting", "running"].contains($0.status.rawValue) }.count ?? 0
            if s.continuesThreads { continuing += n } else { stopped += n }
        }
        return (stopped, continuing)
    }

    /// `runtimeAfter`: CandyWrapper's runtime asks to update once the pass ends ("Update all").
    private func confirm(runtimeAfter: Bool = false) {
        let plan = makePlan()
        guard run == nil, let window, !(plan.servers.isEmpty && plan.providerMachines.isEmpty) else { return }
        let count = plan.description.updatingRows.count
        let version = plan.description.version.map { "Version \($0)" }
        let providers = plan.description.providerCount
        let details = [version, providers > 0 ? "\(providers) provider \(providers == 1 ? "update" : "updates")" : nil].compactMap { $0 }.joined(separator: " · ")
        let dialog = DialogView(kind: .alertDialog, title: "Update \(count) \(count == 1 ? "machine" : "machines")?", message: details)
        dialog.maxWidth = 576
        let running = Dictionary(uniqueKeysWithValues: plan.servers.map { server in
            (server.environmentId, environments.snapshot(server.environmentId)?.threads.filter { ["preparing", "starting", "running"].contains($0.status.rawValue) }.count ?? 0)
        })
        let content = UpdateEverythingDialogContent(plan.description, running: running)
        dialog.panelContent = [content]
        let threads = runningThreads(plan.servers)
        let notes = [L.threadsLine(stopped: threads.stopped, continuing: threads.continuing)].compactMap { $0 }
        if !notes.isEmpty { dialog.headerContent = NotesView(notes) }
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Update")
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        content.onHeightChange = { [weak host, weak dialog] in
            guard let dialog else { return }
            dialog.panelContent = dialog.panelContent
            host?.needsLayout = true
        }
        window.makeFirstResponder(cancel)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in host?.close(); self?.start(runtimeAfter: runtimeAfter) }
    }

    /// `<p className="pt-2 text-sm">` paragraphs under the description, each keeping its line breaks.
    private final class NotesView: DSView {
        private let blocks: [TextBlockView]
        init(_ paragraphs: [String]) {
            blocks = paragraphs.map { TextBlockView($0, font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.foreground)) }
            super.init(frame: .zero)
            blocks.forEach(addSubview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize {
            let w = max(1, bounds.width)
            // The header's `gap-2` sits above the first paragraph and between them; each `pt-2` adds 8 more.
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

    // MARK: The pass (useUpdateEverything.ts `run`)

    private func start(runtimeAfter: Bool = false) {
        guard run == nil else { return }
        let plan = makePlan()
        let act = action
        var machines: [String: L.RunMachine] = [:], order: [String] = []
        let startedAt = Date().timeIntervalSince1970
        for m in plan.providerMachines {
            order.append(m.environmentId)
            machines[m.environmentId] = L.RunMachine(environmentId: m.environmentId, label: m.label, updatesProviders: true, updatesServer: false,
                                                     startedAt: startedAt)
        }
        for s in plan.servers {
            if machines[s.environmentId] == nil { order.append(s.environmentId) }
            machines[s.environmentId] = L.RunMachine(environmentId: s.environmentId, label: s.label,
                                                     updatesProviders: machines[s.environmentId]?.updatesProviders ?? false, updatesServer: true,
                                                     startedAt: startedAt)
        }
        let localVersion = act != .none ? plan.localVersion : nil
        run = L.Run(localVersion: localVersion, phase: .providers, machines: order.compactMap { machines[$0] })
        pill?.isActionPending = true
        Task { [weak self] in
            await self?.perform(plan, action: act, localVersion: localVersion)
            // A pass with a failed machine stays as the capsule until it is retried or dismissed (useUpdateEverything.ts:262-272).
            if var r = self?.run {
                r.phase = .servers; r.restartAt = nil; r.localVersion = nil
                self?.run = L.closeFinished(r)
            }
            self?.pill?.isActionPending = false
            // Reached only when this app didn't restart into its update.
            if runtimeAfter { self?.serverUpdates.runtimeUpdater?.request() }
        }
    }

    /// `settleUpdateRunMachine` (updateEverythingRun.tsx:38-58).
    private func settle(_ environmentId: String, failure: String?, serverUpdated: Bool = false, providerFailure: String?? = nil) {
        guard var r = run, let i = r.machines.firstIndex(where: { $0.environmentId == environmentId }) else { return }
        r.machines[i].failed = failure != nil
        r.machines[i].failure = failure
        if serverUpdated { r.machines[i].updatesServer = false }
        if let providerFailure { r.machines[i].providerFailure = providerFailure }
        run = L.closeFinished(r)
    }

    private func perform(_ plan: Plan, action act: DesktopUpdateLogic.ButtonAction, localVersion: String?) async {
        // The local download runs beside the remote work (`runUpdateEverything`).
        let download: Task<(ready: Bool, failure: String?), Never>? = act == .download ? Task { [updater] in
            let result = await updater.download()
            let error = DesktopUpdateLogic.actionError(accepted: result.accepted, completed: result.completed, state: updater.state)
            return (result.completed, error.map { "Could not download update: \($0)" })
        } : nil
        // Servers stage while providers install; each server's update waits only on its own stage.
        var staged: [String: Task<Void, Never>] = [:]
        if !plan.providerMachines.isEmpty {
            for s in plan.servers { if let task = serverUpdates.stage(s.environmentId) { staged[s.environmentId] = task } }
        }
        // Providers first, so no install is cut off by a server restart.
        var providerOutcomes: [(updated: Bool, line: String?)] = []
        var providerFailures: [String: String] = [:]
        await withTaskGroup(of: (String, Bool, String?).self) { group in
            for m in plan.providerMachines {
                for c in m.candidates {
                    group.addTask { [environments] in
                        let label = "\(m.label) · \(SidebarProviderUpdatePillModel.displayName(c.driver))"
                        do {
                            let reply = try await environments.request(m.environmentId, "server.updateProvider",
                                                                        .object(["provider": .string(c.driver), "instanceId": .string(c.instanceId.rawValue)]))
                            let returned = (try? JSONValueDecoder().decode([ServerProvider].self, from: reply["providers"] ?? .array([]))) ?? []
                            let state = returned.first { $0.instanceId == c.instanceId }?.updateState
                            if state?.status == "succeeded" { return (m.environmentId, true, nil) }
                            return (m.environmentId, false, "\(label): \(state?.message ?? "Provider update did not finish.")")
                        } catch {
                            return (m.environmentId, false, "\(label): \(error.localizedDescription)")
                        }
                    }
                }
            }
            for await (env, ok, line) in group {
                providerOutcomes.append((ok, line))
                if !ok, providerFailures[env] == nil { providerFailures[env] = line ?? "Provider update interrupted" }
            }
        }
        for m in run?.machines ?? [] where !m.updatesServer { settle(m.environmentId, failure: providerFailures[m.environmentId]) }
        // A server's time runs from the end of the providers (useUpdateEverything.ts:186-196).
        let serversStartedAt = Date().timeIntervalSince1970
        if var r = run {
            r.phase = .servers
            for i in r.machines.indices where r.machines[i].updatesServer { r.machines[i].startedAt = serversStartedAt }
            run = r
        }
        // Each server settles its row when it finishes; the pass moves on once every server has handed off its restart
        // (`waitForServerUpdateHandoff`, useUpdateEverything.ts:222-245 at 5258), so this app can restart while they do.
        let finished = Finished()
        let runs = plan.servers.map { s in
            let stage = staged[s.environmentId]
            return Task { [weak self, serverUpdates] in
                await stage?.value
                let outcome = await serverUpdates.updateQuietly(s.environmentId, serverLabel: s.label)
                let failure: String? = if case .failed(let why) = outcome { why } else { nil }
                self?.settle(s.environmentId, failure: failure ?? providerFailures[s.environmentId], serverUpdated: failure == nil,
                             providerFailure: .some(providerFailures[s.environmentId]))
                finished.servers.append((outcome == .updated, failure.map { "\(s.label): \($0)" }))
            }
        }
        for (s, task) in zip(plan.servers, runs) { await waitForHandoff(s.environmentId, finished: task) }
        let local: (ready: Bool, failure: String?) = await download?.value ?? (true, nil)
        func result() -> L.Result {
            L.Result(localVersion: nil, updatedServers: finished.servers.filter(\.updated).count,
                     updatedProviders: providerOutcomes.filter(\.updated).count,
                     failures: (local.failure.map { ["This app: \($0)"] } ?? []) + finished.servers.compactMap(\.line) + providerOutcomes.compactMap(\.line))
        }
        var installFailure: String?
        if local.ready, act != .none, let localVersion, await waitForRestart() {
            if var r = run { r.phase = .installing; r.restartAt = nil; run = r }
            var saved = result()
            saved.localVersion = localVersion
            save(saved)
            let installed = await updater.install()
            if installed.accepted, DesktopUpdateLogic.actionError(accepted: installed.accepted, completed: installed.completed, state: updater.state) == nil { return }
            Self.clearSaved()
            installFailure = DesktopUpdateLogic.actionError(accepted: installed.accepted, completed: installed.completed, state: updater.state)
                .map { "This app: Could not install update: \($0)" }
        }
        for task in runs { await task.value }
        var final = result()
        if let installFailure { final.failures.insert(installFailure, at: 0) }
        show(final)
    }

    @MainActor private final class Finished { var servers: [(updated: Bool, line: String?)] = [] }
    @MainActor private final class Once { var done = false; var token: UUID? }

    private func handedOff(_ environmentId: String) -> Bool {
        if case .running(.resuming, _, _) = serverUpdates.state(environmentId) { return true }
        return false
    }

    /// `waitForServerUpdateHandoff` (updateEverythingRun.tsx:160-180): returns once the server restarts into its update,
    /// or its update ended. It wakes on the server update changes only.
    private func waitForHandoff(_ environmentId: String, finished: Task<Void, Never>) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once()
            let finish = { [weak self] in
                guard !once.done else { return }
                once.done = true
                if let token = once.token { self?.serverUpdates.unobserve(token) }
                done.resume()
            }
            if handedOff(environmentId) { return finish() }
            once.token = serverUpdates.observe { [weak self] in if self?.handedOff(environmentId) == true { finish() } }
            Task { await finished.value; finish() }
        }
    }

    // MARK: Result (updateEverythingRun.tsx)

    /// The pass this app restarts in, in its own UserDefaults, so every bundle id (each test app) keeps its own. It is
    /// written just before this app installs its update, read and removed at the next launch, and removed when the
    /// install does not start.
    private static let savedKey = "t3code:update-everything-result:v1"

    /// `saveUpdateEverythingResult` (updateEverythingRun.tsx:233-266): the result so far and each unfinished server with
    /// the version it restarts into and its launcher's update id.
    private func save(_ result: L.Result) {
        let handedOff = L.handedOff(run) { [serverUpdates] m in
            if case .running(_, _, let target) = serverUpdates.state(m.environmentId) { return (target, serverUpdates.updateId(m.environmentId)) }
            return (ServerVersionSkewLogic.clientVersion, nil)
        }
        let pass = L.SavedPass(savedAt: Date().timeIntervalSince1970, result: result, handedOff: handedOff)
        if let data = try? JSONEncoder().encode(pass) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    private static func clearSaved() { UserDefaults.standard.removeObject(forKey: savedKey) }

    /// `startDesktopUpdateLaunchNotice` (updateEverythingRun.tsx:424-432): the toast, then the servers still restarting.
    private func showSavedResult() {
        let data = UserDefaults.standard.data(forKey: Self.savedKey)
        Self.clearSaved()
        guard let saved = L.takeSaved(data, now: Date().timeIntervalSince1970) else { return }
        let handedOff = saved.handedOff ?? []
        show(saved.result, restarting: handedOff.map(\.label))
        follow(handedOff)
    }

    // MARK: Servers a relaunch left restarting (`followHandedOffServers`, updateEverythingRun.tsx:306-422)

    private var followed: [L.HandedOffServer] = []
    private var followTally = (updated: 0, failures: [String]())
    private var followDeadlines: [String: DispatchWorkItem] = [:]
    private var nudges: [String: DispatchWorkItem] = [:]

    /// Each server's row restarts again and settles on what the server reports: its version (from its `welcome`), its
    /// launcher's outcome (from its `ready`), or the 32-minute deadline. A machine that is gone never reports, so it fails at
    /// the deadline and offers Dismiss, as in T3. Everything runs from connection and lifecycle events, plus one deadline each.
    private func follow(_ servers: [L.HandedOffServer]) {
        guard let restored = L.restoredRun(servers) else { return }
        followed = servers
        followTally = (0, [])
        run = restored
        for s in servers {
            serverUpdates.setFollowed(s.environmentId, targetVersion: s.targetVersion)
            let id = s.environmentId
            let deadline = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settleFollowed(id, failure: L.notBackMessage) } }
            followDeadlines[id] = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, s.startedAt + L.handoffTimeout - Date().timeIntervalSince1970), execute: deadline)
        }
        checkFollowed()
    }

    private func checkFollowed() {
        for s in followed {
            let outcome = L.settlement(s, serverVersion: serverUpdates.descriptor(s.environmentId)?.serverVersion,
                                       ready: environments.session(s.environmentId)?.lastReady)
            if let outcome { settleFollowed(s.environmentId, failure: outcome) } else { nudgeReconnect(s.environmentId) }
        }
    }

    /// `nudgeReconnectDuringUpdateRestart`: the restart is expected, so a connection in backoff retries after a second
    /// instead of climbing the ladder. One retry per backoff, on the connection's own change.
    private func nudgeReconnect(_ id: String) {
        guard nudges[id] == nil, let phase = environments.state(id)?.phase, phase == .backoff || phase == .blocked(.authentication) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nudges[id] = nil
                guard self.followed.contains(where: { $0.environmentId == id }), let supervisor = self.environments.session(id)?.supervisor else { return }
                Task { await supervisor.retryNow() }
            }
        }
        nudges[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func settleFollowed(_ id: String, failure: String?) {
        guard let i = followed.firstIndex(where: { $0.environmentId == id }) else { return }
        let s = followed.remove(at: i)
        followDeadlines.removeValue(forKey: id)?.cancel()
        nudges.removeValue(forKey: id)?.cancel()
        if let failure { followTally.failures.append("\(s.label): \(failure)") } else { followTally.updated += 1 }
        settle(id, failure: failure)
        serverUpdates.setFollowed(id, targetVersion: nil)
        if followed.isEmpty {
            show(L.Result(localVersion: nil, updatedServers: followTally.updated, updatedProviders: 0, failures: followTally.failures))
        }
    }

    private func show(_ result: L.Result, restarting: [String] = []) {
        guard let view = L.toast(result, appVersion: updater.currentVersion, restarting: restarting) else { return }
        toasts()?.show(ToastView(title: view.title, message: view.description, kind: view.success ? .success : .error))
    }
}
