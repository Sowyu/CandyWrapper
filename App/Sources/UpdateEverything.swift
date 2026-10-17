import AppKit
import DesignSystem
import Features
import T3Protocol

/// "Update everything" behind the sidebar update button (T3 3105 d83929ad0, eeaac49a9: sidebar/useUpdateEverything.ts,
/// UpdateEverythingDialog.tsx, updateEverythingRun.tsx, SidebarUpdatePill.tsx:298-370). While other machines' servers
/// or any providers are behind, the button shows the circled arrow and one click asks to update them all: providers,
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

    struct Plan {
        var summary: String
        var lines: [String]
        var servers: [L.Machine]
        var skipped: [L.Skipped]
        var providerMachines: [(environmentId: String, label: String, candidates: [ServerProvider])]
        var localVersion: String?
    }

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
        environments.observe { [weak self] in self?.refresh() }
        serverUpdates.observe { [weak self] in self?.refresh() }
        updater.observe { [weak self] in self?.refresh() }
        // A pass that ended with this app's relaunch reports once the app is back (`DesktopUpdateLaunchNotice`).
        DispatchQueue.main.async { [weak self] in self?.showSavedResult() }
    }

    /// A provider list changed somewhere (the composer's config observers).
    func providersChanged() { refresh() }

    private var action: DesktopUpdateLogic.ButtonAction { DesktopUpdateLogic.buttonAction(updater.state) }

    private func machines() -> [L.Machine] {
        environments.environmentIds.filter { serverUpdates.ownRuntimeState($0) == nil && !serverUpdates.isOwnServer($0) }.map { id in
            let caps = serverUpdates.capabilities(id)
            return L.Machine(environmentId: id, label: environments.label(id) ?? id, serverVersion: serverUpdates.descriptor(id)?.serverVersion,
                             connected: environments.state(id)?.status == .connected, canMaintain: serverUpdates.canUpdate(id),
                             updating: serverUpdates.state(id).isRunning, capabilities: caps, ownServer: serverUpdates.isOwnServer(id),
                             continuesThreads: caps.threadContinuation && serverUpdates.continueThreads(id))
        }
    }

    // ponytail: no npm check before a CLI server updates (`useNpmReleasePublished`); the target is the pinned T3 release, already on npm
    private func makePlan() -> Plan {
        let target = ServerVersionSkewLogic.clientVersion
        let (servers, skipped) = L.serverTargets(machines(), target: target)
        let providerMachines = environments.environmentIds.compactMap { id -> (environmentId: String, label: String, candidates: [ServerProvider])? in
            guard environments.state(id)?.status == .connected else { return nil }
            let all = providers(id)
            let candidates = ProviderUpdateToastModel.candidates(all).filter { ProviderUpdateToastModel.canOneClick($0, among: all) }
            return candidates.isEmpty ? nil : (id, environments.label(id) ?? id, candidates)
        }
        let local = action != .none ? DesktopUpdateLogic.downloadedVersion(updater.state) : nil
        let d = L.describe(localVersion: local, servers: servers, target: target,
                           providerMachines: providerMachines.map { ($0.environmentId, $0.label, $0.candidates.map { SidebarProviderUpdatePillModel.displayName($0.driver) }) })
        return Plan(summary: d.summary, lines: d.lines, servers: servers, skipped: skipped, providerMachines: providerMachines, localVersion: local)
    }

    private func refresh() {
        let next = makePlan()
        plan = next
        // The independently downloaded runtime keeps its Download / Restart buttons. Providers
        // and service-managed servers retain their own update actions while it waits.
        let runtime = serverUpdates.runtimeUpdater?.state
        let runtimeOffer = runtime.map { $0.enabled && (DesktopUpdateLogic.buttonAction($0) != .none || $0.status == .downloading || $0.isRestarting) } ?? false
        pill?.everythingSummary = runtimeOffer || (next.servers.isEmpty && next.providerMachines.isEmpty) ? nil : next.summary
        pill?.run = run.map { (runTooltip($0), $0.localVersion != nil) }
    }

    /// `useUpdateRunTooltip`: this app first, then one line per machine.
    private func runTooltip(_ run: L.Run) -> String {
        let statuses = run.machines.map { ($0.label, L.status($0, phase: run.phase, server: serverUpdates.state($0.environmentId))) }
        var local: String?
        if run.localVersion != nil {
            let s = updater.state
            if s.status == .downloading { local = "downloading" + (s.downloadPercent.map { " \(Int($0.rounded(.down)))%" } ?? "") }
            else if run.phase == .installing { local = "restarting" }
            else { local = action == .install ? "restarts last" : "waiting" }
        }
        return L.runTooltip(statuses, local: local)
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

    private func confirm() {
        let plan = makePlan()
        guard run == nil, let window, !(plan.servers.isEmpty && plan.providerMachines.isEmpty) else { return }
        let dialog = DialogView(kind: .alertDialog, title: "\(plan.summary)?", message: plan.lines.joined(separator: "\n"))
        let threads = runningThreads(plan.servers)
        let notes = [L.threadsLine(stopped: threads.stopped, continuing: threads.continuing),
                     plan.skipped.isEmpty ? nil : plan.skipped.map { "Skips \($0.label): \($0.reason)" }.joined(separator: "\n")].compactMap { $0 }
        if !notes.isEmpty { dialog.headerContent = NotesView(notes) }
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Update")
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in host?.close(); self?.start() }
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

    private func start() {
        guard run == nil else { return }
        let plan = makePlan()
        let act = action
        var machines: [String: L.RunMachine] = [:], order: [String] = []
        for m in plan.providerMachines {
            order.append(m.environmentId)
            machines[m.environmentId] = L.RunMachine(environmentId: m.environmentId, label: m.label, updatesProviders: true, updatesServer: false)
        }
        for s in plan.servers {
            if machines[s.environmentId] == nil { order.append(s.environmentId) }
            machines[s.environmentId] = L.RunMachine(environmentId: s.environmentId, label: s.label,
                                                     updatesProviders: machines[s.environmentId]?.updatesProviders ?? false, updatesServer: true)
        }
        let localVersion = act != .none ? plan.localVersion : nil
        run = L.Run(localVersion: localVersion, phase: .providers, machines: order.compactMap { machines[$0] })
        pill?.isActionPending = true
        Task { [weak self] in
            await self?.perform(plan, action: act, localVersion: localVersion)
            self?.run = nil
            self?.pill?.isActionPending = false
        }
    }

    private func settle(_ environmentId: String, failed: Bool) {
        guard var r = run, let i = r.machines.firstIndex(where: { $0.environmentId == environmentId }) else { return }
        r.machines[i].failed = failed
        run = r
    }

    private func perform(_ plan: Plan, action act: DesktopUpdateLogic.ButtonAction, localVersion: String?) async {
        // The local download runs beside the remote work (`runUpdateEverything`).
        let download: Task<(ready: Bool, failure: String?), Never>? = act == .download ? Task { [updater] in
            let result = await updater.download()
            let error = DesktopUpdateLogic.actionError(accepted: result.accepted, completed: result.completed, state: updater.state)
            return (result.completed, error.map { "Could not download update: \($0)" })
        } : nil
        // Providers first, so no install is cut off by a server restart.
        var providerOutcomes: [(updated: Bool, line: String?)] = []
        var failedProviderMachines: Set<String> = []
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
                if !ok { failedProviderMachines.insert(env) }
            }
        }
        for m in run?.machines ?? [] where !m.updatesServer { settle(m.environmentId, failed: failedProviderMachines.contains(m.environmentId)) }
        if var r = run { r.phase = .servers; run = r }
        var serverOutcomes: [(updated: Bool, line: String?)] = []
        await withTaskGroup(of: (String, String, ServerUpdates.QuietOutcome).self) { group in
            for s in plan.servers {
                group.addTask { [serverUpdates] in
                    (s.environmentId, s.label, await serverUpdates.updateQuietly(s.environmentId, serverLabel: s.label))
                }
            }
            for await (env, label, outcome) in group {
                let failure: String? = if case .failed(let why) = outcome { why } else { nil }
                settle(env, failed: failure != nil || failedProviderMachines.contains(env))
                serverOutcomes.append((outcome == .updated, failure.map { "\(label): \($0)" }))
            }
        }
        let local: (ready: Bool, failure: String?) = await download?.value ?? (true, nil)
        var result = L.Result(localVersion: nil, updatedServers: serverOutcomes.filter(\.updated).count,
                              updatedProviders: providerOutcomes.filter(\.updated).count,
                              failures: (local.failure.map { ["This app: \($0)"] } ?? []) + serverOutcomes.compactMap(\.line) + providerOutcomes.compactMap(\.line))
        let localReady = local.ready
        if localReady, act != .none, let localVersion {
            if var r = run { r.phase = .installing; run = r }
            result.localVersion = localVersion
            Self.save(result)
            let installed = await updater.install()
            if installed.accepted, DesktopUpdateLogic.actionError(accepted: installed.accepted, completed: installed.completed, state: updater.state) == nil { return }
            Self.clearSaved()
            if let error = DesktopUpdateLogic.actionError(accepted: installed.accepted, completed: installed.completed, state: updater.state) {
                result.failures.insert("This app: Could not install update: \(error)", at: 0)
            }
            result.localVersion = nil
        }
        show(result)
    }

    // MARK: Result (updateEverythingRun.tsx)

    private static let savedKey = "t3code:update-everything-result:v1"
    /// A result older than this belongs to an install that never relaunched the app.
    private static let savedMaxAge: TimeInterval = 10 * 60

    private struct Saved: Codable { var savedAt: Double; var result: UpdateEverythingLogic.Result }

    private static func save(_ result: L.Result) {
        if let data = try? JSONEncoder().encode(Saved(savedAt: Date().timeIntervalSince1970, result: result)) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }

    private static func clearSaved() { UserDefaults.standard.removeObject(forKey: savedKey) }

    private func showSavedResult() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey) else { return }
        Self.clearSaved()
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), Date().timeIntervalSince1970 - saved.savedAt < Self.savedMaxAge else { return }
        show(saved.result)
    }

    private func show(_ result: L.Result) {
        guard let view = L.toast(result, appVersion: updater.currentVersion) else { return }
        toasts()?.show(ToastView(title: view.title, message: view.description, kind: view.success ? .success : .error))
    }
}
