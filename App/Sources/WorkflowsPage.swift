import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The Workflows page (5258 apps/web/src/components/workflows/WorkflowsPage.tsx, routes/_chat.workflows.tsx). It
/// subscribes to `workflows.subscribe` with `changes: true` only while it shows (client-runtime state/server.ts:
/// 1473-1485) and drops the list on hide, so a hidden page holds nothing and costs nothing. T3's web sidebar has no
/// Workflows entry or badge at 5258, so nothing else keeps a subscription.
@MainActor
final class WorkflowsPageController {
    let page = WorkflowsPageView()
    private let environments: Environments
    private let config: (String) -> ServerProviderConfig?
    private let store = WorkflowRunsStore()
    private var subscription: Task<Void, Never>?
    private var subscribedEnvironment: String?
    private var visible = false
    private var detailTask: Task<Void, Never>?
    private var detailKey: (runId: String, key: String?)?
    var openSettingsLabs: () -> Void = {}

    init(environments: Environments, config: @escaping (String) -> ServerProviderConfig?) {
        self.environments = environments
        self.config = config
        store.onChange = { [weak self] in self?.storeChanged() }
        page.onSelect = { [weak self] id in self?.page.selectedRunId = id }
        page.onShownRunChange = { [weak self] _ in self?.readDetail(force: true) }
        page.onOpenSettings = { [weak self] in self?.openSettingsLabs() }
        page.onOpenURL = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        page.onAnswer = { [weak self] runId, name, choice, reason, done in self?.answer(runId, name, choice, reason, done) }
        page.onCancelRun = { [weak self] runId in self?.confirmCancel(runId) }
        _ = environments.observe { [weak self] in self?.sync() }
    }

    /// `useWorkflowEnvironmentIds`: connected environments whose server has workflows on in Labs.
    var workflowEnvironmentIds: [String] {
        environments.environmentIds.filter { environments.session($0) != nil && config($0)?.settings.raw["workflowsEnabled"]?.boolValue == true }
    }

    /// WorkflowsPage.tsx:72-79: the primary environment when it has workflows on, else the first that does.
    // ponytail: one environment at a time and no Environment select; add T3's select (:229-260) once someone runs
    // workflows on two machines.
    private var environmentId: String? {
        let ids = workflowEnvironmentIds
        if let primary = environments.primaryId, ids.contains(primary) { return primary }
        return ids.first
    }

    func didShow() {
        visible = true
        sync()
    }

    func didHide() {
        visible = false
        sync()
    }

    /// The server config changed: workflows may have turned on or off.
    func configChanged() { if visible { sync() } }

    private func sync() {
        let env = visible ? environmentId : nil
        if env != subscribedEnvironment {
            subscription?.cancel()
            subscription = nil
            detailTask?.cancel()
            detailTask = nil
            detailKey = nil
            store.reset()
            page.detail = nil
            subscribedEnvironment = env
            if let env, let supervisor = environments.session(env)?.supervisor { subscribe(supervisor) }
        }
        guard visible else { return }
        page.canOperate = environments.canOperate(subscribedEnvironment)
        if subscribedEnvironment == nil {
            let connected = environments.environmentIds.contains { environments.session($0) != nil }
            page.content = connected ? .off : .noEnvironment
        } else {
            render()
        }
    }

    private func subscribe(_ supervisor: ConnectionSupervisor) {
        let store = self.store
        subscription = supervisor.subscribe(WorkflowsRPC.subscribe, payload: { WorkflowsRPC.subscribeInput() }, handler: { event in
            switch event {
            case .subscribed:
                await MainActor.run { store.subscribed() }
            case .value(let json):
                let update = try JSONDecoder().decode(WorkflowRunsUpdate.self, from: JSONEncoder().encode(json))
                await MainActor.run { store.apply(update) }
            case .interrupted(let error):
                await MainActor.run { store.fail(String(describing: error)) }
            default: break
            }
        })
    }

    private func storeChanged() {
        render()
        readDetail(force: false)
    }

    private func render() {
        if let error = store.error, store.snapshot == nil { page.content = .failed(error); return }
        page.content = store.snapshot.map { .runs($0) } ?? .loading
    }

    /// `workflowRunRefreshKey` (client-runtime workflows.ts:93-99): an ended run's steps are read again only when the
    /// run changes; a run under way on any change of the list.
    private func readDetail(force: Bool) {
        guard let runId = page.shownRunId, let env = subscribedEnvironment, let supervisor = environments.session(env)?.supervisor else {
            detailTask?.cancel(); detailTask = nil; detailKey = nil; page.detail = nil; page.detailError = nil
            return
        }
        let key = WorkflowRuns.refreshKey(store.snapshot, runId: runId)
        if !force, let last = detailKey, last.runId == runId, let key, last.key == key { return }
        if detailKey?.runId != runId { page.detail = nil }
        detailKey = (runId, key)
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            do {
                let json = try await supervisor.request(WorkflowsRPC.get, payload: WorkflowsRPC.runInput(runId))
                let detail = try JSONDecoder().decode(WorkflowRunDetail.self, from: JSONEncoder().encode(json))
                guard !Task.isCancelled, let self, self.page.shownRunId == runId else { return }
                self.page.detail = detail
                self.page.detailError = nil
            } catch {
                guard !Task.isCancelled, let self, self.page.shownRunId == runId else { return }
                self.page.detailError = Self.message(error)
            }
        }
    }

    private func answer(_ runId: String, _ name: String, _ choice: String, _ reason: String?, _ done: @escaping @MainActor (String?) -> Void) {
        guard let env = subscribedEnvironment, let supervisor = environments.session(env)?.supervisor else { return done("Not connected.") }
        Task {
            do {
                _ = try await supervisor.request(WorkflowsRPC.answer, payload: WorkflowsRPC.answerInput(runId: runId, name: name, choice: choice, reason: reason))
                done(nil)
            } catch {
                done(Self.message(error))
            }
        }
    }

    /// `cancelRun` (WorkflowRunFeed.tsx:268-280): a destructive confirm, then `workflows.cancel`.
    private func confirmCancel(_ runId: String) {
        guard let window = page.window, let run = store.snapshot?.runs.first(where: { $0.runId == runId }) else { return }
        let copy = ConfirmCopy.resolve("Cancel \(run.title)? Its agents stop and the run cannot be resumed.")
        let dialog = DialogView(kind: .alertDialog, title: copy.title, message: copy.description ?? "")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host, weak self] in
            host?.close()
            guard let self, let env = self.subscribedEnvironment, let supervisor = self.environments.session(env)?.supervisor else { return }
            Task { [weak self] in
                do { _ = try await supervisor.request(WorkflowsRPC.cancel, payload: WorkflowsRPC.cancelInput(runId: runId)) }
                catch { self?.page.toasts.show(ToastView(title: "Could not cancel the run", message: Self.message(error), kind: .error)) }
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? RPCClientError { return e.description }
        return error.localizedDescription
    }
}
