import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// Updates version-skewed servers the way T3 does (ServerUpdateAction.tsx, versionSkew.ts, client-runtime
/// state/server.ts:684-912): one update per environment at a time, its stage for every surface (the
/// composer notice, the Connections rows), and T3's toasts when it ends. A server is behind when it runs
/// an older T3 than `ServerVersionSkewLogic.clientVersion`, read from its lifecycle `welcome`.
/// Nothing runs while no update does.
@MainActor
final class ServerUpdates {
    private let environments: Environments
    private var states: [String: ServerUpdateState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var lifecycle: [String: (shell: ShellSession, observer: UUID)] = [:]
    private var observers: [UUID: () -> Void] = [:]
    /// The failed update the user dismissed per environment (`dismissServerUpdateFailure`): only that attempt.
    private var dismissedFailures: [String: ServerUpdateState] = [:]
    private var updatingAll = false
    /// Why the last quiet update of an environment failed ("Update everything" reads it).
    private var quietFailures: [String: String] = [:]

    /// The toast stack in view: Settings while it shows, else the thread panel.
    var toasts: () -> ToastViewport? = { nil }
    var window: () -> NSWindow? = { nil }
    /// The environment's `continueThreadsAfterServerUpdate` server setting.
    var continueThreads: (String) -> Bool = { _ in false }
    /// The server is one CandyWrapper started on this Mac (`ServerController`), not T3's.
    var isOwnServer: (String) -> Bool = { _ in false }
    var runtimeUpdater: RuntimeUpdateController?

    func ownRuntimeState(_ id: String) -> DesktopUpdateState? {
        guard runtimeUpdater?.environmentId == id, runtimeUpdater?.state.enabled == true else { return nil }
        return runtimeUpdater?.state
    }


    /// Hosts that refused this client's protocol, by environment id: their HTTP descriptor, read once per refusal.
    private var outdated: [String: EnvironmentDescriptor] = [:]
    private var outdatedReads: Set<String> = []
    private var checkedDescriptors: [String: EnvironmentDescriptor] = [:]

    init(environments: Environments) {
        self.environments = environments
        environments.observe { [weak self] in self?.readOutdatedHosts() }
    }

    @discardableResult
    func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    func changed() { for o in observers.values { o() } }

    /// A new session for the environment: follow its lifecycle so a restarted server's version shows.
    func sessionChanged(_ environmentId: String) {
        checkedDescriptors[environmentId] = nil
        if let old = lifecycle.removeValue(forKey: environmentId) { old.shell.lifecycleObservers[old.observer] = nil }
        if let shell = environments.session(environmentId) {
            let id = UUID()
            shell.lifecycleObservers[id] = { [weak self] json in
                if json["type"]?.stringValue == "welcome" { self?.checkedDescriptors[environmentId] = nil; self?.changed() }
            }
            lifecycle[environmentId] = (shell, id)
        }
        changed()
    }

    // MARK: Reading

    /// The environment the server describes in its last `welcome`.
    func descriptor(_ environmentId: String) -> EnvironmentDescriptor? {
        checkedDescriptors[environmentId] ?? (try? environments.session(environmentId)?.welcome?["environment"]?.decode(as: EnvironmentDescriptor.self))
    }

    /// Re-read connected servers without reconnecting their sockets or interrupting turns.
    func check() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in environments.environmentIds where environments.state(id)?.status == .connected {
                group.addTask { [weak self] in await self?.checkDescriptor(id) ?? false }
            }
            var succeeded = true
            for await result in group { if !result { succeeded = false } }
            return succeeded
        }
    }

    private func checkDescriptor(_ id: String) async -> Bool {
        guard let shell = environments.session(id) else { return false }
        let welcome = shell.welcome
        do {
            let descriptor = try await shell.http.descriptor()
            guard environments.session(id) === shell, shell.welcome == welcome,
                  descriptor.environmentId == id else { return false }
            checkedDescriptors[id] = descriptor
            changed()
            return true
        } catch { return false }
    }

    func capabilities(_ environmentId: String) -> ServerUpdateCapabilities {
        ServerUpdateCapabilities(descriptor(environmentId)?.capabilities ?? [:])
    }

    /// `serverUpdateStateForServerVersion`: a failure clears once the server runs another version.
    func state(_ environmentId: String) -> ServerUpdateState {
        if let runtime = ownRuntimeState(environmentId) {
            let target = runtime.downloadedVersion ?? runtime.availableVersion ?? runtime.currentVersion
            if runtime.isRestarting { return .running(stage: .resuming, fromVersion: runtime.currentVersion, targetVersion: target) }
            if runtime.status == .downloading { return .running(stage: .downloading, fromVersion: runtime.currentVersion, targetVersion: target) }
            if let message = runtime.message, runtime.errorContext == .install {
                return .failed(stage: .resuming, fromVersion: runtime.currentVersion, targetVersion: target, message: message)
            }
            return .idle
        }
        return (states[environmentId] ?? .idle).forServerVersion(descriptor(environmentId)?.serverVersion)
    }

    /// `resolveVersionMismatch`: the server runs an older T3 than this client.
    func mismatch(_ environmentId: String) -> (server: String, client: String)? {
        if let runtime = ownRuntimeState(environmentId) {
            guard let target = runtime.availableVersion ?? runtime.downloadedVersion else { return nil }
            return (runtime.currentVersion, target)
        }
        if isOwnServer(environmentId) { return nil }
        guard let server = descriptor(environmentId)?.serverVersion, ServerVersionSkewLogic.serverIsBehind(server) else { return nil }
        return (server, ServerVersionSkewLogic.clientVersion)
    }

    /// `canUpdateServer`: an authenticated session granted `environment:maintain`.
    func canUpdate(_ environmentId: String) -> Bool {
        environments.authSession(environmentId)?.grants(AuthScopes.environmentMaintain) == true
            && (ownRuntimeState(environmentId) == nil || runtimeUpdater?.busy == false)
    }

    /// What the update control offers for a server behind this client.
    func offer(_ environmentId: String, serverLabel: String) -> ServerUpdateOffer? {
        guard let mismatch = mismatch(environmentId) else { return nil }
        let caps = capabilities(environmentId)
        // Our runtime has its own release feed and separate Download and Restart clicks.
        if ownRuntimeState(environmentId) != nil { return .update(confirm: nil) }
        return ServerUpdateOffer(caps, targetVersion: mismatch.client, serverLabel: serverLabel)
    }

    // MARK: Updating

    /// The button: the desktop app's confirmation first, then the update.
    func request(_ environmentId: String, serverLabel: String) {
        if ownRuntimeState(environmentId) != nil {
            if canUpdate(environmentId) { runtimeUpdater?.request() }
            return
        }
        guard canUpdate(environmentId), tasks[environmentId] == nil else { return }
        guard case .update(let question)? = offer(environmentId, serverLabel: serverLabel) else { return }
        guard let question, let window = window() else { return start(environmentId, serverLabel: serverLabel) }
        ConfirmCopy.present(question, destructive: false, in: window) { [weak self] yes in
            if yes { self?.start(environmentId, serverLabel: serverLabel) }
        }
    }

    /// Saved machines "Update all" reaches: switched on, connected, behind, remotely updatable, not mid-update
    /// (ConnectionsSettings.tsx:2075-2120).
    func updateAllTargets() -> [String] {
        environments.saved.compactMap { r in
            let id = r.environmentId
            guard r.enabled, environments.state(id)?.status == .connected, mismatch(id) != nil, !state(id).isRunning,
                  capabilities(id).canUpdateRemotely else { return nil }
            return id
        }
    }

    /// `ServerUpdatesAction`: one confirmation for the desktop apps among them, then each update on its own.
    func updateAll() {
        guard !updatingAll else { return }
        let targets = updateAllTargets().filter { tasks[$0] == nil }
        guard !targets.isEmpty else { return }
        let label: (String) -> String = { [environments] in environments.label($0) ?? $0 }
        let run = { [weak self] in
            for id in targets { self?.start(id, serverLabel: label(id), failureTitle: "\(label(id)) update failed") }
        }
        let desktops = targets.filter { capabilities($0).selfUpdate == .desktopManaged }
        guard !desktops.isEmpty, let window = window() else { return run() }
        updatingAll = true
        ConfirmCopy.present(ServerUpdateCopy.desktopConfirmAll(labels: desktops.map(label)), destructive: false, in: window) { [weak self] yes in
            self?.updatingAll = false
            if yes { run() }
        }
    }

    enum QuietOutcome: Equatable { case updated, skipped, failed(String) }

    /// `updateServer(server, { quiet: true })` for "Update everything": no toasts. A server that can't update now,
    /// or already is, is skipped rather than joined (ServerUpdateAction.tsx:84-87).
    func updateQuietly(_ environmentId: String, serverLabel: String) async -> QuietOutcome {
        guard tasks[environmentId] == nil else { return .skipped }
        quietFailures[environmentId] = nil
        start(environmentId, serverLabel: serverLabel, quiet: true)
        guard let task = tasks[environmentId] else { return .skipped }
        await task.value
        return quietFailures.removeValue(forKey: environmentId).map { .failed($0) } ?? .updated
    }

    private func start(_ environmentId: String, serverLabel: String, failureTitle: String = ServerUpdateCopy.failureTitle, quiet: Bool = false) {
        guard ownRuntimeState(environmentId) == nil, !isOwnServer(environmentId),
              tasks[environmentId] == nil, canUpdate(environmentId), let shell = environments.session(environmentId),
              let mismatch = mismatch(environmentId) else { return }
        let caps = capabilities(environmentId)
        let from = mismatch.server
        let continueThreads = caps.threadContinuation && continueThreads(environmentId)
        states[environmentId] = .running(stage: .downloading, fromVersion: from, targetVersion: mismatch.client)
        changed()
        tasks[environmentId] = Task { [weak self] in
            do {
                let result = try await ServerUpdater.run(supervisor: shell.supervisor, targetVersion: mismatch.client,
                                                         continueRunningThreads: continueThreads, capabilities: caps) { stage, target in
                    await MainActor.run {
                        self?.states[environmentId] = .running(stage: stage, fromVersion: from, targetVersion: target)
                        self?.changed()
                    }
                }
                guard let self else { return }
                states[environmentId] = .idle
                if !quiet {
                    toast(ToastView(title: ServerUpdateCopy.successTitle(serverLabel: serverLabel),
                                    message: ServerUpdateCopy.successDescription(caps.selfUpdate, targetVersion: result.targetVersion), kind: .success))
                }
            } catch is CancellationError {
                self?.states[environmentId] = .idle
                if quiet { self?.quietFailures[environmentId] = "Server update was interrupted." }
            } catch {
                guard let self else { return }
                let message = (error as? ServerUpdater.Failure)?.message ?? "Server update failed."
                var stage = ServerUpdateStage.downloading, target = mismatch.client
                if case .running(let s, _, let t)? = states[environmentId] { stage = s; target = t }
                states[environmentId] = .failed(stage: stage, fromVersion: from, targetVersion: target, message: message)
                if quiet { quietFailures[environmentId] = message } else { toast(ToastView(title: failureTitle, message: message, kind: .error)) }
            }
            self?.tasks[environmentId] = nil
            self?.changed()
        }
    }

    private func toast(_ view: ToastView) { _ = toasts()?.show(view) }

    // MARK: Hosts too old to connect

    /// A saved host on an older orchestration protocol: "Client not supported". Its descriptor tells whether
    /// this client can update it (compatibility.ts `serverUpdateRequired`).
    private func readOutdatedHosts() {
        for id in environments.environmentIds {
            guard environments.state(id)?.status == .unsupported else {
                if outdated.removeValue(forKey: id) != nil { changed() }
                continue
            }
            guard outdated[id] == nil, !outdatedReads.contains(id), let shell = environments.session(id) else { continue }
            outdatedReads.insert(id)
            let http = shell.http
            Task { [weak self] in
                let d = try? await http.descriptor()
                guard let self else { return }
                outdatedReads.remove(id)
                if let d, environments.state(id)?.status == .unsupported { outdated[id] = d; changed() }
            }
        }
    }

    /// The host needs an update before this client can connect, and this client can run it.
    func outdatedHost(_ environmentId: String) -> EnvironmentDescriptor? {
        outdated[environmentId].flatMap { Pairing.serverUpdateRequired($0) ? $0 : nil }
    }

    /// `OutdatedServerUpdateAction`: the update over a bare socket, then the normal connection again.
    // ponytail: direct routes only; a T3 Connect-only host shows no button until relay sockets can skip the protocol check
    func updateOutdated(_ environmentId: String, serverLabel: String) {
        guard tasks[environmentId] == nil, let d = outdatedHost(environmentId), let shell = environments.session(environmentId),
              !shell.token.isEmpty else { return }
        let http = shell.http, token = shell.token, from = d.serverVersion
        let target = ServerVersionSkewLogic.clientVersion
        let identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        states[environmentId] = .running(stage: .downloading, fromVersion: from, targetVersion: target)
        changed()
        tasks[environmentId] = Task { [weak self] in
            do {
                let version = try await ServerUpdater.runOutdated(
                    connect: { try await ServerUpdater.bareConnection(http: http, identity: identity, token: token) },
                    descriptor: { try await http.descriptor() },
                    environmentId: environmentId, label: d.label, targetVersion: target,
                    capabilities: ServerUpdateCapabilities(d.capabilities)) { stage, t in
                    await MainActor.run {
                        self?.states[environmentId] = .running(stage: stage, fromVersion: from, targetVersion: t)
                        self?.changed()
                    }
                }
                guard let self else { return }
                states[environmentId] = .idle
                outdated[environmentId] = nil
                environments.reconnect(environmentId)
                toast(ToastView(title: ServerUpdateCopy.successTitle(serverLabel: serverLabel),
                                message: ServerUpdateCopy.successDescription(nil, targetVersion: version), kind: .success))
            } catch is CancellationError {
                self?.states[environmentId] = .idle
            } catch {
                guard let self else { return }
                let message = (error as? ServerUpdater.Failure)?.message ?? "Server update failed."
                var stage = ServerUpdateStage.downloading
                if case .running(let s, _, _)? = states[environmentId] { stage = s }
                states[environmentId] = .failed(stage: stage, fromVersion: from, targetVersion: target, message: message)
                toast(ToastView(title: ServerUpdateCopy.failureTitle, message: message, kind: .error))
            }
            self?.tasks[environmentId] = nil
            self?.changed()
        }
    }

    // MARK: Dismissals

    /// `buildVersionMismatchDismissalKey`.
    func dismissalKey(_ environmentId: String) -> String? {
        mismatch(environmentId).map { "\(environmentId):\($0.client):\($0.server)" }
    }

    private static let dismissalsKey = "t3code:version-mismatch-dismissals:v1"

    func isDismissed(_ environmentId: String) -> Bool {
        guard let key = dismissalKey(environmentId) else { return false }
        return UserDefaults.standard.stringArray(forKey: Self.dismissalsKey)?.contains(key) == true
    }

    func isFailureDismissed(_ environmentId: String) -> Bool {
        let s = state(environmentId)
        return s.isFailed && dismissedFailures[environmentId] == s
    }

    /// The notice's X: the failed attempt, and the version pair, stay dismissed.
    func dismiss(_ environmentId: String) {
        let s = state(environmentId)
        if s.isFailed { dismissedFailures[environmentId] = s }
        if let key = dismissalKey(environmentId) {
            var keys = UserDefaults.standard.stringArray(forKey: Self.dismissalsKey) ?? []
            if !keys.contains(key) { keys.append(key); UserDefaults.standard.set(keys, forKey: Self.dismissalsKey) }
        }
        changed()
    }
}
