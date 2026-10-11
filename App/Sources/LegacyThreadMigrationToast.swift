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
        guard let shell else { return }
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

/// The running update lives in the sidebar pill. Terminal results and launch advice use toasts.
@MainActor
final class ProviderUpdateLaunchToast {
    private weak var viewport: ToastViewport?
    private var shown: Int?
    private var shownKey: String?
    private var announced: Set<String> = []
    private var updating: Set<String> = []
    var openSettings: (() -> Void)?
    init(viewport: ToastViewport) { self.viewport = viewport }
    func update(_ providers: [ServerProvider]) {
        let active = providers.filter { ["queued", "running"].contains($0.updateState?.status ?? "") }
        updating.formUnion(active.map(\.driver))
        let model: ProviderUpdateToastModel?
        if !updating.isEmpty {
            model = ProviderUpdateToastModel.progress(providers.filter { updating.contains($0.driver) }, count: updating.count)
        } else { model = ProviderUpdateToastModel.initial(providers) }
        guard let model, model.key != shownKey else { return }
        if let shown { viewport?.dismiss(shown) }; shown = nil; shownKey = model.key
        if model.phase == "running" { return }
        guard announced.insert(model.key).inserted else { return }
        if model.phase != "initial" { updating = [] }
        let kind: ToastQueue.Kind = model.phase == "failed" ? .error : model.phase == "succeeded" ? .success : .warning
        shown = viewport?.show(ToastView(title: model.title, message: model.message, kind: kind,
            actionTitle: model.phase == "succeeded" ? nil : "Provider settings", action: { [weak self] in self?.openSettings?() }), timeout: model.timeout)
    }
}
