import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// `NewConnectDeviceToast` (ConnectDeviceApprovalCoordinator.tsx:62-160, T3 5258, #42311): on an environment
/// this client may manage (`access:write`) whose devices sign in without approval, a warning toast with no
/// timeout names T3 Connect devices first seen after this client's watermark. One toast per environment
/// updates in place. "Review" opens Access; closing the toast or Review marks the devices seen.
@MainActor
final class ConnectDeviceNotice {
    /// `CONNECT_DEVICES_SEEN_KEY`: each environment's host-clock watermark, kept per client.
    static let seenKey = "t3code:connect-devices-seen-through"

    private let environments: Environments
    private weak var toasts: ToastViewport?
    /// The environment's `requireConnectDeviceApproval`; nil while its config is unknown.
    var approvalRequired: (String) -> Bool? = { _ in nil }
    var openAccess: ((String) -> Void)?
    private var subscriptions: [String: (shell: ShellSession, task: Task<Void, Never>)] = [:]
    private var devices: [String: [AuthConnectDevice]] = [:]
    private var shown: [String: (toastId: Int, renderedKey: String)] = [:]
    private let defaults: UserDefaults

    init(environments: Environments, toasts: ToastViewport, defaults: UserDefaults = .standard) {
        self.environments = environments
        self.toasts = toasts
        self.defaults = defaults
    }

    /// An environment's session or grants changed: its access stream follows the session while it grants `access:write`.
    func sessionChanged(_ environmentId: String) {
        let shell = environments.session(environmentId)
        let canApprove = shell != nil && environments.canCreateGuestShare(environmentId)
        if let current = subscriptions[environmentId], current.shell === shell, canApprove { return }
        subscriptions.removeValue(forKey: environmentId)?.task.cancel()
        devices[environmentId] = nil
        guard let shell, canApprove else { close(environmentId); return }
        let env = environmentId
        var snapshot = AuthAccessSnapshot()
        let task = shell.supervisor.subscribe("subscribeAuthAccess", payload: { .object([:]) }, handler: { [weak self] event in
            guard case .value(let json) = event else { return }
            await MainActor.run {
                guard let self, (try? snapshot.apply(json)) != nil else { return }
                // Older servers omit the list.
                self.devices[env] = snapshot.connectDevices
                self.update(env)
            }
        })
        subscriptions[environmentId] = (shell, task)
    }

    /// The approval setting may have changed.
    func configChanged(_ environmentId: String) { update(environmentId) }

    func update(_ environmentId: String) {
        guard let list = devices[environmentId] else { return }
        let seenThrough = seen()[environmentId]
        let (unseen, newest) = ConnectDeviceNames.unseen(list, seenThrough: seenThrough)
        let announce = approvalRequired(environmentId) == false
        if !announce || unseen.isEmpty {
            close(environmentId)
            if seenThrough != newest { markSeen(environmentId, newest) }
            return
        }
        let renderedKey = unseen.map(\.proofKeyThumbprint).joined(separator: ",")
        if shown[environmentId]?.renderedKey == renderedKey { return }
        let label = environments.label(environmentId) ?? environmentId
        let (title, message) = ConnectDeviceNames.newDeviceToast(label: label, unseen: unseen)
        if let current = shown[environmentId], toasts?.update(current.toastId, title: title, message: message) == true {
            shown[environmentId] = (current.toastId, renderedKey)
            return
        }
        guard let toasts else { return }
        var toastId = 0
        let toast = ToastView(title: title, message: message, kind: .warning, actionTitle: "Review", action: { [weak self] in
            guard let self else { return }
            self.markSeen(environmentId, newest)
            self.close(environmentId)
            self.openAccess?(environmentId)
        })
        toast.onDidDismiss = { [weak self] in
            guard let self else { return }
            self.markSeen(environmentId, max(self.seen()[environmentId] ?? 0, ConnectDeviceNames.unseen(self.devices[environmentId] ?? [], seenThrough: self.seen()[environmentId]).newest))
            // A dismissed toast is gone, so the next unseen device needs a new one.
            if self.shown[environmentId]?.toastId == toastId { self.shown[environmentId] = nil }
        }
        toastId = toasts.show(toast, timeout: 0)
        shown[environmentId] = (toastId, renderedKey)
    }

    private func close(_ environmentId: String) {
        guard let current = shown.removeValue(forKey: environmentId) else { return }
        toasts?.dismiss(current.toastId)
    }

    private func seen() -> [String: Int64] {
        (defaults.dictionary(forKey: Self.seenKey) ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    private func markSeen(_ environmentId: String, _ newest: Int64) {
        var all = defaults.dictionary(forKey: Self.seenKey) ?? [:]
        all[environmentId] = NSNumber(value: max(seen()[environmentId] ?? 0, newest))
        defaults.set(all, forKey: Self.seenKey)
    }
}
