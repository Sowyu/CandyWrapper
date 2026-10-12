import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// `LegacyThreadMigrationToast` (apps/web/src/components/LegacyThreadMigrationToast.tsx): while the primary
/// server migrates threads from the previous version (`subscribeServerLifecycle` event `legacyThreadMigration`,
/// status `running`), a loading toast says so; `complete` closes it.
@MainActor
final class LegacyThreadMigrationToast {
    private let environments: Environments
    private weak var toasts: ToastViewport?
    private var subscription: (environmentId: String, shell: ShellSession, observer: UUID)?
    private var toastId: Int?

    init(environments: Environments, toasts: ToastViewport) {
        self.environments = environments
        self.toasts = toasts
    }

    /// An environment's session started or ended: the primary one's lifecycle stream follows it.
    func sessionChanged(_ environmentId: String) {
        guard environmentId == environments.primaryId else { return }
        let shell = environments.session(environmentId)
        guard shell !== subscription?.shell else { return }
        if let subscription { subscription.shell.lifecycleObservers[subscription.observer] = nil }
        subscription = nil
        guard let shell else { apply(status: nil, total: 0); return }
        let observer = UUID()
        shell.lifecycleObservers[observer] = { [weak self] json in
            guard json["type"]?.stringValue == "legacyThreadMigration" else { return }
            self?.apply(status: json["payload"]?["status"]?.stringValue,
                        total: json["payload"]?["totalThreadCount"]?.intValue ?? 0)
        }
        subscription = (environmentId, shell, observer)
    }

    func apply(status: String?, total: Int) {
        if status == "running" {
            guard toastId == nil, let toasts else { return }
            let count = total.formatted(.number)
            toastId = toasts.show(ToastView(title: "Restoring your threads\u{2026}",
                                            message: "Migrating \(count) \(total == 1 ? "thread" : "threads") from the previous version. You can keep working while this finishes.",
                                            kind: .loading), timeout: 0)
            return
        }
        if let toastId { toasts?.dismiss(toastId) }
        toastId = nil
    }
}

/// `ProviderUpdatePrimaryNotification` (ProviderUpdatePrimaryNotification.tsx): the launch prompt for the primary
/// environment's outdated providers, with "Update" running each one-click update in turn and "Settings". Closing
/// the prompt with X remembers its key. The running update lives in the sidebar pill; results use toasts.
/// T3's per-environment variant (ProviderUpdateLaunchNotification.tsx:40-48) only exists beside a WSL backend.
@MainActor
final class ProviderUpdateLaunchToast {
    private weak var viewport: ToastViewport?
    private var shown: Int?
    private var shownKey: String?
    /// True while this class closes its own toast, so `onDidDismiss` can tell a user's X from a replacement.
    private var closing = false
    private var announced: Set<String> = []
    private var updating: Set<String> = []
    /// A run the prompt started (`ActiveProviderUpdateToast` kind "update"): its instances and count.
    private var run: (key: String, ids: Set<String>, count: Int)?
    private var providers: [ServerProvider] = []
    var openSettings: (() -> Void)?
    /// `server.updateProvider` on the primary environment.
    var request: ((String, JSONValue) async throws -> JSONValue)?
    init(viewport: ToastViewport) { self.viewport = viewport }

    func update(_ providers: [ServerProvider]) {
        self.providers = providers
        // A prompt-started run reports its own outcome (ProviderUpdatePrimaryNotification.tsx:176-195).
        if let run {
            let view = ProviderUpdateToastModel.progress(providers.filter { run.ids.contains($0.instanceId.rawValue) }, count: run.count)
            if view.phase != "running" { self.run = nil; showResult(view) }
            return
        }
        let active = providers.filter { ["queued", "running"].contains($0.updateState?.status ?? "") }
        updating.formUnion(active.map(\.driver))
        let model: ProviderUpdateToastModel?
        if !updating.isEmpty {
            model = ProviderUpdateToastModel.progress(providers.filter { updating.contains($0.driver) }, count: updating.count)
        } else { model = ProviderUpdateToastModel.initial(providers) }
        guard let model, model.key != shownKey else { return }
        close(); shownKey = model.key
        if model.phase == "running" { return }
        if model.phase == "initial", ProviderUpdateToastModel.isDismissed(model.key) { return }
        guard announced.insert(model.key).inserted else { return }
        if model.phase != "initial" { updating = []; showResult(model); return }
        showPrompt(model)
    }

    private func showPrompt(_ model: ProviderUpdateToastModel) {
        let candidates = ProviderUpdateToastModel.candidates(providers)
        let oneClick = candidates.filter { ProviderUpdateToastModel.canOneClick($0, among: providers) }
        // ponytail: the single provider's glyph shows without T3's download badge (ProviderUpdateToastIcon); add it with leading views on toasts
        let glyph: (name: IconName, color: NSColor)? = candidates.count == 1
            ? (candidates[0].driver == "codex" ? .brandOpenAI : .brandClaudeAI, Themed.color(\.foreground)) : nil
        let toast: ToastView
        if oneClick.isEmpty {
            toast = ToastView(title: model.title, message: model.message, kind: .warning, actionTitle: "Settings",
                              action: { [weak self] in self?.close(); self?.openSettings?() }, leadingIcon: glyph)
            toast.setActionVariants(.outline)
        } else {
            toast = ToastView(title: model.title, message: model.message, kind: .warning, actionTitle: "Update",
                              action: { [weak self] in self?.runUpdates(oneClick, key: model.key) },
                              secondaryTitle: "Settings", secondaryAction: { [weak self] in self?.close(); self?.openSettings?() }, leadingIcon: glyph)
            toast.setActionVariants(.outline, secondary: .outline)
        }
        // `data.onClose`: the X remembers the prompt's key.
        toast.onDidDismiss = { [weak self] in
            guard let self, !self.closing else { return }
            ProviderUpdateToastModel.dismiss(model.key)
            self.shown = nil
        }
        shown = viewport?.show(toast, timeout: 0)
    }

    /// `runUpdates`: one `server.updateProvider` at a time; the first failure, else the returned snapshots, decide
    /// the result, unless the providers already reported it.
    private func runUpdates(_ oneClick: [ServerProvider], key: String) {
        guard run == nil, !oneClick.isEmpty, let request else { return }
        let ids = Set(oneClick.map(\.instanceId.rawValue))
        run = (key, ids, oneClick.count)
        close()
        Task { [weak self] in
            var failure: String?
            var returned: [ServerProvider] = []
            for p in oneClick {
                do {
                    let reply = try await request("server.updateProvider", .object(["provider": .string(p.driver), "instanceId": .string(p.instanceId.rawValue)]))
                    returned += (try? JSONValueDecoder().decode([ServerProvider].self, from: reply["providers"] ?? .array([]))) ?? []
                } catch {
                    if failure == nil { failure = "\(error)" }
                }
            }
            guard let self, let run = self.run, run.key == key else { return }
            if let failure {
                self.run = nil
                self.showResult(ProviderUpdateToastModel.rejected(count: run.count, message: failure))
                return
            }
            var latest: [String: ServerProvider] = [:]
            for p in returned where ids.contains(p.instanceId.rawValue) { latest[p.instanceId.rawValue] = p }
            let view = ProviderUpdateToastModel.progress(Array(latest.values), count: run.count)
            if view.phase != "running" { self.run = nil; self.showResult(view) }
        }
    }

    /// `addProviderUpdateToast`: results with "Settings", success alone and gone after 3 s.
    private func showResult(_ model: ProviderUpdateToastModel) {
        close()
        let kind: ToastQueue.Kind = model.phase == "failed" ? .error : model.phase == "succeeded" ? .success : .warning
        let toast = ToastView(title: model.title, message: model.message, kind: kind, actionTitle: model.phase == "succeeded" ? nil : "Settings",
                              action: { [weak self] in self?.close(); self?.openSettings?() })
        toast.setActionVariants(.outline)
        shown = viewport?.show(toast, timeout: model.timeout)
    }

    private func close() {
        guard let id = shown else { return }
        closing = true
        viewport?.dismiss(id)
        closing = false
        shown = nil
    }
}

/// PermissionUpdateNotice.tsx:20-75. Check once per connected session, never on a clock.
@MainActor
final class ThreadPermissionUpdateNotice {
    private let environments: Environments
    private weak var toasts: ToastViewport?
    var openConnections: (() -> Void)?
    private var shown: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    init(environments: Environments, toasts: ToastViewport) { self.environments = environments; self.toasts = toasts }
    /// The session's grants arrived (`Environments.canOperate`).
    var onGrants: ((String) -> Void)?
    func sessionChanged(_ environmentId: String) {
        tasks.removeValue(forKey: environmentId)?.cancel()
        environments.setAuthSession(nil, for: environmentId)
        guard let shell = environments.session(environmentId) else { return }
        // The same read gives the session's grants, which thread actions check (T3's `sessionStateAtom`).
        tasks[environmentId] = Task { [weak self] in
            guard let session = try? await shell.http.session(token: shell.token), !Task.isCancelled, let self else { return }
            environments.setAuthSession(session, for: environmentId)
            onGrants?(environmentId)
            guard session.hasLegacyPermissions, !shown.contains(environmentId), !UserDefaults.standard.bool(forKey: key(environmentId)),
                  let toasts else { return }
            shown.insert(environmentId)
            let label = environments.label(environmentId) ?? environmentId
            var toastId: Int?
            let dismiss: @MainActor () -> Void = { [weak self, weak toasts] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: key(environmentId))
                if let toastId { toasts?.dismiss(toastId) }
            }
            let toast = ToastView(title: "Permissions have changed for \(label)",
                message: "This connection still uses the old permissions, so some actions may no longer be available. Pair again using a new link with the permissions you need.",
                actionTitle: "Open Connections", action: { [weak self] in dismiss(); self?.openConnections?() },
                secondaryTitle: "Dismiss", secondaryAction: dismiss)
            toastId = toasts.show(toast, timeout: 0)
            toast.onDidDismiss = { UserDefaults.standard.set(true, forKey: "t3code:permission-update:v1:" + environmentId) }
        }
    }
    private func key(_ environmentId: String) -> String { "t3code:permission-update:v1:" + environmentId }
}
