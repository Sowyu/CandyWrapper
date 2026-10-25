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
