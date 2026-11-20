import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The Welcome page (WelcomePage.tsx:129-344, routes/welcome.tsx at Nightly 4928) over the window for the
/// primary computer, after the first-run gate (firstRun.logic.ts). The page and its import live in Features;
/// this joins them to the connection, Settings and T3 Connect.
@MainActor
final class WelcomeOnboardingController {
    private weak var window: NSWindow?
    private let environments: Environments
    private let composer: ComposerController
    private weak var settings: SettingsController?
    private var gate: FirstRunRecoveryView?
    private var deadline: DispatchWorkItem?
    private var gateRoute: FirstRunDecision.Route = .pending
    private var live: Set<String> = []
    private var lifecycle: (ShellSession, UUID)?
    private var settingsObserver: Int?
    private var page: WelcomePageView?
    private var waitsForConnection = false
    /// The project to open once its environment's shell lists it.
    private var landing: (env: String, projectId: String)?
    private let landingWait = OnboardingProjectWait()
    /// Opens a new thread in a project, by environment and local id; false while the sidebar lacks it.
    var openProject: ((String, String) -> Bool)?
    var toasts: ToastViewport?

    init(window: NSWindow, environments: Environments, composer: ComposerController, settings: SettingsController) {
        self.window = window; self.environments = environments; self.composer = composer; self.settings = settings
        settings.t3.observe { [weak self] in self?.sync() }
        environments.observe { [weak self] in self?.evaluateFirstRun(); self?.sync() }
        composer.configObservers.append { [weak self] _ in self?.evaluateFirstRun(); self?.sync() }
    }
    func beginFirstRun() {
        guard let content = window?.contentView else { return }
        let gate = FirstRunRecoveryView(frame: content.bounds)
        gate.autoresizingMask = [.width, .height]
        gate.onRetry = { [weak self] in
            guard let self else { return }
            if ClientSettingsStore.shared.readFailed { ClientSettingsStore.shared.retryRead() }
            else { for id in environments.environmentIds { environments.reconnect(id) }; armDeadline() }
            evaluateFirstRun()
        }
        self.gate = gate
        content.addSubview(gate)
        settingsObserver = ClientSettingsStore.shared.observe { [weak self] _ in self?.evaluateFirstRun() }
        armDeadline()
        evaluateFirstRun()
    }
    private func armDeadline() {
        deadline?.cancel()
        gate?.reason = .pending
        let work = DispatchWorkItem { [weak self] in
            guard let self, gateRoute == .pending else { return }
            gate?.reason = ClientSettingsStore.shared.readFailed ? .settings : .connecting
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    func liveShell(_ env: String, snapshot: ShellSnapshot?) {
        if snapshot == nil { live.remove(env) } else { live.insert(env) }
        evaluateFirstRun()
        if landing?.env == env { DispatchQueue.main.async { [weak self] in self?.land() } }
    }
    private func evaluateFirstRun() {
        guard gate != nil, gateRoute != .wizard else { return }
        let store = ClientSettingsStore.shared
        if store.readFailed { gate?.reason = .settings; return }
        let primary = environments.primaryId
        if let shell = environments.session(primary), shell !== lifecycle?.0 {
            if let lifecycle { lifecycle.0.lifecycleObservers[lifecycle.1] = nil }
            let id = UUID()
            shell.lifecycleObservers[id] = { [weak self] _ in self?.evaluateFirstRun() }
            lifecycle = (shell, id)
        }
        var evidence = FirstRunDecision.Evidence()
        evidence.completed = !store.current.string("onboardingCompletedAt").isEmpty
        evidence.catalogReady = environments.catalogReady
        evidence.primaryLive = primary.map { live.contains($0) } ?? false
        let ids = Array(Set(environments.environmentIds + environments.saved.filter(\.enabled).map(\.environmentId)))
        evidence.bootstrapped = !ids.isEmpty && ids.allSatisfy { environments.hasShell($0) }
        evidence.workspaceLive = ids.allSatisfy { live.contains($0) }
        evidence.configAvailable = primary.flatMap { composer.config($0) } != nil
        evidence.primaryId = primary
        evidence.welcome = environments.session(primary)?.welcome
        // `FirstRunDecision` reads only whether there is more than one project or thread, and the first
        // of each when there is one. Two of each is enough; encoding every thread on each change cost
        // 1.8 s of main thread at launch with 1,400 threads in five environments (docs/research/m10-load-2026-10-12.md).
        for env in ids where evidence.projects.count < 2 || evidence.threads.count < 2 {
            guard let snapshot = environments.snapshot(env) else { continue }
            for project in snapshot.projects.prefix(2 - min(2, evidence.projects.count)) {
                if var json = (try? JSONValue(parsing: JSONEncoder().encode(project)))?.objectValue {
                    json["environmentId"] = .string(env); evidence.projects.append(.object(json))
                }
            }
            for thread in snapshot.threads.prefix(2 - min(2, evidence.threads.count)) {
                if var json = (try? JSONValue(parsing: JSONEncoder().encode(thread)))?.objectValue {
                    json["environmentId"] = .string(env)
                    json["latestRun"] = thread.latestRunId.map { .string($0.rawValue) } ?? .null
                    json["runtime"] = thread.activeProviderThreadId.map { .string($0) } ?? .null
                    evidence.threads.append(.object(json))
                }
            }
        }
        let result = FirstRunDecision.resolve(evidence)
        if result.route == .pending { return }
        gateRoute = result.route
        deadline?.cancel(); deadline = nil
        gate?.removeFromSuperview()
        if result.persist || evidence.completed || result.route == .wizard { gate = nil }
        if result.persist { store.update(["onboardingCompletedAt": .string(ISO8601DateFormatter().string(from: Date()))]) }
        if result.route == .wizard { show() }
        if result.persist || evidence.completed || result.route == .wizard {
            if let lifecycle { lifecycle.0.lifecycleObservers[lifecycle.1] = nil }; lifecycle = nil
            if let settingsObserver { store.removeObserver(settingsObserver) }; settingsObserver = nil
        }
    }
    func show() {
        // Turn on writes through Settings' context, which Settings otherwise wires on its first open.
        settings?.setUpPageContext()
        guard page == nil, let window, let content = window.contentView, let context = settings?.pageContext,
              let env = environments.primaryId ?? environments.environmentIds.first else { return }
        let model = WelcomePageModel(environmentId: env, label: environments.label(env) ?? "this computer")
        model.request = { [weak self] method, payload in
            guard let self else { throw CancellationError() }
            return try await environments.request(env, method, payload)
        }
        model.refreshProviders = { [weak self] instance in
            let payload: JSONValue = .object(instance.map { ["instanceId": .string($0)] } ?? [:])
            Task { [weak self] in _ = try? await self?.environments.request(env, "server.refreshProviders", payload) }
        }
        model.existingProjectId = { [weak self] path in
            self?.environments.snapshot(env).flatMap { ProjectCommands.existing($0.projects, workspaceRoot: path)?.id.localId.rawValue }
        }
        model.openSettings = { [weak self] section in
            guard let self else { return }
            page?.isHidden = true
            settings?.onOnboardingReturn = { [weak self] in self?.page?.isHidden = false }
            settings?.show(section)
        }
        model.signInToConnect = { [weak self] in
            guard let self, let window = self.window, let t3 = settings?.t3 else { return }
            page?.isHidden = true
            t3.onOnboardingReturn = { [weak self] in self?.page?.isHidden = false; self?.sync() }
            t3.presentSignIn(in: window)
        }
        model.cloudLinkState = { [weak self] in
            guard let shell = self?.environments.session(env) else { throw CancellationError() }
            return try await shell.http.cloudLinkState(token: shell.token)
        }
        model.finish = { [weak self] landing, warning, count in
            await self?.finish(landing: landing, warning: warning, importedThreads: count) ?? false
        }
        let page = WelcomePageView(model: model, context: context)
        page.frame = content.bounds
        page.autoresizingMask = [.width, .height]
        page.topInset = SidebarMetrics.topbarHeight // `--workspace-topbar-height` on macOS desktop (index.css:123, WelcomePage.tsx:278)
        content.addSubview(page)
        self.page = page
        waitsForConnection = true
        sync()
    }

    /// `useProjectScans` waits for the connection (WelcomePage.tsx:153), so a page opened before the socket
    /// keeps its pending scan instead of failing with "not connected"; `sync` runs this on each change.
    private func startWhenConnected() {
        guard waitsForConnection, let model = page?.model,
              environments.state(model.environmentId)?.phase == .connected else { return }
        waitsForConnection = false
        readScopes(model.environmentId)
        model.refreshProviders?(nil)
        model.refreshScan()
    }

    /// Copies the computer's live state into the page.
    private func sync() {
        guard let model = page?.model else { return }
        let env = model.environmentId
        model.label = environments.label(env) ?? "this computer"
        let config = composer.config(env)
        model.providers = config?.providers
        model.settings = config?.settings.raw
        model.platform = config?.platformOS ?? "darwin"
        model.cwd = config?.cwd
        model.connectSignedOut = settings?.t3.signedIn == nil
        model.projectRoots = environments.snapshot(env)?.projects.map(\.workspaceRoot) ?? []
        startWhenConnected()
    }

    /// The session's scopes: terminals, providers, imports and the relay (Settings → Sharing & access).
    private func readScopes(_ env: String) {
        guard let shell = environments.session(env) else { return }
        Task { [weak self] in
            guard let session = try? await shell.http.session(token: shell.token), let model = self?.page?.model else { return }
            model.canOperateTerminal = session.grants(AuthScopes.terminalOperate)
            model.canManageProviders = session.grants(AuthScopes.providersManage)
            model.canWrite = session.grants(AuthScopes.orchestrationOperate)
            model.offersPhone = WelcomePageLogic.offersPhone(isPrimary: env == self?.environments.primaryId, cloud: true,
                                                             canShare: session.grants(AuthScopes.relayRead) && session.grants(AuthScopes.relayWrite))
        }
    }

    /// `finish` (WelcomePage.tsx:186-252): saves setup, lands on the project, then reports the import.
    private func finish(landing project: (env: String, projectId: String)?, warning: String, importedThreads: Int) async -> Bool {
        ClientSettingsStore.shared.update(["onboardingCompletedAt": .string(ISO8601DateFormatter().string(from: Date()))])
        let opened: Bool = await withCheckedContinuation { done in
            guard let project else { done.resume(returning: false); return }
            landing = project
            landingWait.start(open: { [weak self] in
                self?.openProject?(project.env, project.projectId) == true
            }, finish: { [weak self] opened in
                self?.landing = nil
                done.resume(returning: opened)
            })
        }
        _ = opened
        page?.removeFromSuperview()
        page = nil
        if !warning.isEmpty {
            _ = toasts?.show(ToastView(title: "Some history was not imported", message: warning, kind: .warning), timeout: 0)
        } else if importedThreads > 0 {
            _ = toasts?.show(ToastView(title: "Imported \(importedThreads) \(importedThreads == 1 ? "thread" : "threads")", kind: .success))
        }
        return true
    }

    /// The deadline still completes setup if no shell ever supplies the project.
    private func land() { landingWait.projectChanged() }
}

/// ChatGptWelcomeCoordinator.tsx (mounted in routes/__root.tsx:224): once per connected environment's
/// provider that uses a ChatGPT plan, "Your ChatGPT plan is connected". It reads the verified provider
/// snapshots, never a sign-in callback. Acknowledged profiles persist under T3's storage key.
@MainActor
final class ChatGptWelcomeCoordinator {
    private weak var window: NSWindow?
    private let environments: Environments
    private let composer: ComposerController
    private var host: ModalHost?
    private var acknowledged: [String]

    init(window: NSWindow, environments: Environments, composer: ComposerController) {
        self.window = window; self.environments = environments; self.composer = composer
        acknowledged = CodexSetupLogic.readAcknowledged(UserDefaults.standard.string(forKey: CodexSetupLogic.welcomeStorageKey))
        _ = environments.observe { [weak self] in self?.evaluate() }
        composer.configObservers.append { [weak self] _ in self?.evaluate() }
    }
    private var profiles: [CodexSetupLogic.WelcomeProfile] {
        CodexSetupLogic.welcomeProfiles(environments.environmentIds.map { id in
            (id, environments.label(id) ?? "Computer", environments.state(id)?.status == .connected, composer.config(id)?.providers ?? [])
        })
    }

    func evaluate() {
        guard host == nil, let window, let next = CodexSetupLogic.nextWelcome(profiles, acknowledged: acknowledged) else { return }
        let dialog = ChatGptWelcomeDialog(profile: next) { url in NSWorkspace.shared.open(url) }
        let host = ModalHost.present(dialog, in: window)
        dialog.onContinue = { [weak host] in host?.close() }
        // Every way out (Continue, Escape, the backdrop, the X) acknowledges the profile (`onOpenChange`).
        host.onDismiss = { [weak self] in
            guard let self else { return }
            self.host = nil
            self.dismiss(next.key)
            self.evaluate()
        }
        self.host = host
    }

    private func dismiss(_ key: String) {
        guard !acknowledged.contains(key) else { return }
        acknowledged.append(key)
        UserDefaults.standard.set(CodexSetupLogic.writeAcknowledged(acknowledged), forKey: CodexSetupLogic.welcomeStorageKey)
    }
}
