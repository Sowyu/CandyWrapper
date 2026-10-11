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
    private var subscription: (environmentId: String, shell: ShellSession, task: Task<Void, Never>)?
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
        subscription?.task.cancel()
        subscription = nil
        guard let shell else { return }
        // ponytail: a second `subscribeServerLifecycle` stream for this toast alone; share one when another feature reads lifecycle events
        let task = shell.supervisor.subscribe("subscribeServerLifecycle", payload: { .object([:]) }) { [weak self] event in
            guard case .value(let json) = event, json["type"]?.stringValue == "legacyThreadMigration" else { return }
            let status = json["payload"]?["status"]?.stringValue
            let total = json["payload"]?["totalThreadCount"]?.intValue ?? 0
            await MainActor.run { self?.apply(status: status, total: total) }
        }
        subscription = (environmentId, shell, task)
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
