import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// WelcomeWizard.tsx:115-285, 1330-1415. Reads and writes only the selected environments.
@MainActor
final class WelcomeOnboardingController {
    private weak var window: NSWindow?
    private let environments: Environments
    private let composer: ComposerController
    private weak var settings: SettingsController?
    private var host: ModalHost?
    private var dialog: DialogView?
    private var gate: FirstRunRecoveryView?
    private var deadline: DispatchWorkItem?
    private var suspendingWelcome = false
    private var gateRoute: FirstRunDecision.Route = .pending
    private var live: Set<String> = []
    private var lifecycle: (ShellSession, UUID)?
    private var settingsObserver: Int?
    private var step = 0
    private var selected: Set<String> = []
    private var seenComputers: Set<String> = []
    /// One `agentSessions.scan` per computer set up, run together (`useProjectScans`).
    private struct ProjectScan {
        var pending = true
        var error: String?
        var truncated = false
        var candidates: [OnboardingProjectCandidate]?
        /// `orchestration:operate`: nil until the session is read, then whether imports may run.
        var writable: Bool?
        var task: Task<Void, Never>?
    }
    private var scanIds: [String] = []
    private var scans: [String: ProjectScan] = [:]
    /// nil until the user changes it: the recent repositories (`partitionOnboardingProjects`).
    private var selectedKeys: Set<String>?
    /// Retries skip what landed: projects whose history came across, and the ids and command ids of
    /// creations in flight so a retry reuses them (WelcomeWizard.tsx:1218-1224).
    private var importedProjects: [String: (env: String, projectId: String)] = [:]
    private var projectsWithHistory: [String: (env: String, projectId: String)] = [:]
    private var projectAttempts: [String: (projectId: String, commandId: String)] = [:]
    private var lastImportSelection: [String] = []
    private var importWarning = ""
    private var importedThreadCount = 0
    /// The project to open once its environment's shell lists it.
    private var landing: (env: String, projectId: String)?
    private let importList = OnboardingImportListView()
    private var task: Task<Void, Never>?
    private var busy = false
    private var error: String?
    /// Opens a new thread in a project, by environment and local id; false while the sidebar lacks it.
    var openProject: ((String, String) -> Bool)?
    var toasts: ToastViewport?
    private var codexCards: [String: CodexSetupView] = [:]
    private var createdAccount: (env: String, instance: String, displayName: String, autoStart: Bool)?

    init(window: NSWindow, environments: Environments, composer: ComposerController, settings: SettingsController) {
        self.window = window; self.environments = environments; self.composer = composer; self.settings = settings
        settings.t3.observe { [weak self] in if self?.step == 0 { self?.render() } }
        environments.observe { [weak self] in self?.evaluateFirstRun(); if self?.step == 0 { self?.render() } }
        composer.configObservers.append { [weak self] _ in self?.evaluateFirstRun(); if self?.step == 1 { self?.render() } }
        importList.onSelectionChange = { [weak self] keys in self?.selectedKeys = keys; self?.render() }
        importList.onRetry = { [weak self] env in self?.scan(env) }
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
        for env in ids {
            guard let snapshot = environments.snapshot(env) else { continue }
            for project in snapshot.projects {
                if var json = (try? JSONValue(parsing: JSONEncoder().encode(project)))?.objectValue {
                    json["environmentId"] = .string(env); evidence.projects.append(.object(json))
                }
            }
            for thread in snapshot.threads {
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
        guard host == nil, let window else { return }
        suspendingWelcome = false
        if selected.isEmpty { selected = Set(environments.environmentIds.filter { environments.state($0)?.status == .connected }) }
        let dialog = DialogView(title: "Set up T3 Code")
        dialog.showsCloseButton = gateRoute != .wizard
        dialog.maxWidth = 768
        dialog.footerVariant = .bare
        self.dialog = dialog
        render()
        let host = ModalHost.present(dialog, in: window)
        self.host = host
        dialog.onClose = { [weak host] in host?.close() }
        host.onDismiss = { [weak self] in
            guard let self else { return }
            task?.cancel(); task = nil; self.host = nil; self.dialog = nil; codexCards = [:]
            if gateRoute == .wizard && !suspendingWelcome && ClientSettingsStore.shared.current.string("onboardingCompletedAt").isEmpty { show() }
        }
    }
    private func key(_ env: String, _ value: JSONValue) -> String { env + ":" + (value["path"]?.stringValue ?? "") }

    // MARK: Codex (WelcomeWizard.tsx:866-941, `OnboardingCodexSetup`)

    /// The card for one Codex instance, kept across renders so a sign-in survives them; nil when the user
    /// chose the existing CLI (T3's `AgentCard`, which this wizard shows as a status line).
    private func codexCard(env: String, instance: String, provider: ServerProvider?) -> CodexSetupView? {
        guard let context = settings?.pageContext else { return nil }
        let created = createdAccount.flatMap { $0.env == env && $0.instance == instance ? $0 : nil }
        let stored = composer.config(env)?.settings.raw["providerInstances"]?[instance]
        let value = stored ?? .object(["driver": .string("codex"),
                                       "config": created != nil ? .object(["enabled": .bool(true), "setupMode": .string("managed")]) : .object([:])])
        if value["config"]?["setupMode"]?.stringValue == "existing" { return nil }
        let mode = CodexSetupLogic.setupMode(value["config"])
        let key = env + "\u{0}" + instance
        if let card = codexCards[key] {
            card.update(provider: provider, enabled: provider?.enabled ?? true, readOnly: false, mode: mode)
            return card
        }
        let card = CodexSetupView(context: context, environment: env, instance: instance, provider: provider, enabled: provider?.enabled ?? true,
                                  readOnly: false, presentation: .onboarding, mode: mode, autoStart: created?.autoStart == true,
                                  displayName: created?.displayName)
        card.onAutoStartConsumed = { [weak self] in self?.createdAccount?.autoStart = false }
        card.onModeChange = { [weak self] mode in self?.setCodexMode(env: env, instance: instance, mode: mode) }
        card.onHeightChange = { [weak self] in
            guard let dialog = self?.dialog else { return }
            card.invalidateIntrinsicContentSize()
            dialog.needsLayout = true
            dialog.superview?.needsLayout = true
        }
        codexCards[key] = card
        return card
    }

    /// `changeMode`: the instance enabled, in that setup mode, on that environment only.
    private func setCodexMode(env: String, instance: String, mode: String) {
        let stored = composer.config(env)?.settings.raw["providerInstances"]?[instance]?.objectValue ?? ["driver": .string("codex")]
        var next = stored
        var config = next["config"]?.objectValue ?? [:]
        config["enabled"] = .bool(true); config["setupMode"] = .string(mode)
        next["enabled"] = .bool(true); next["config"] = .object(config)
        let payload = JSONValue.object(["patch": .object([:]), "providerInstanceMutation": .object([
            "operation": .string("upsert"), "instanceId": .string(instance), "instance": .object(next)])])
        Task { [weak self] in
            guard let self else { return }
            do { composer.applySettings(env, try await environments.request(env, "server.updateSettings", payload)) }
            catch { self.error = "Could not update Codex setup. \(error)"; render() }
        }
    }

    /// "Connect another ChatGPT account": the account dialog over the wizard; the new card starts its sign-in.
    private func addChatGptAccount(_ env: String) {
        guard let context = settings?.pageContext, let window else { return }
        let dialog = ProviderCodexAccountDialog(context: context, environment: env)
        let host = ModalHost.present(dialog, in: window)
        dialog.close = { [weak host] in host?.close() }
        dialog.onAccountCreated = { [weak self] id, name in
            self?.createdAccount = (env, id, name, true)
            self?.render()
        }
    }
    private func button(_ title: String, action: @escaping @MainActor () -> Void) -> ButtonView {
        let button = ButtonView(title, variant: .outline, size: .sm)
        button.action = action
        button.isEnabled = !busy
        return button
    }
    private func render() {
        guard let dialog else { return }
        let progress = WizardStepsView(steps: ["Connect", "Agents", "Projects"])
        progress.currentStep = step
        for (index, view) in progress.stepViews.enumerated() { view.isEnabled = !busy && index <= step }
        progress.onStepChange = { [weak self] step in guard let self, !busy else { return }; self.step = step; error = nil; render() }
        let titles = ["Connect your computers", "Connect your agents", "Choose your projects"]
        let descriptions = ["Choose one or more computers. We’ll set up agents and projects on each.",
                            "Choose an agent to start coding. You can add more later.",
                            "Import projects and conversations from your selected computers."]
        var content: [NSView] = [progress, LabelView(titles[step], font: DSFont.ui(24, weight: .semibold)),
                                 LabelView(descriptions[step], font: DSFont.ui(14), color: Themed.color(\.mutedForeground))]
        if step == 0 {
            let connected = Set(environments.environmentIds.filter { environments.state($0)?.status == .connected })
            selected.formUnion(connected.subtracting(seenComputers)); seenComputers.formUnion(connected)
            for env in environments.environmentIds {
                content.append(OnboardingChoiceRowView(title: environments.label(env) ?? "Computer",
                    detail: environments.state(env)?.status == .connected ? "Connected" : "Not connected", selected: selected.contains(env)) { [weak self] on in
                    if on { self?.selected.insert(env) } else { self?.selected.remove(env) }; self?.render()
                })
            }
            if let t3 = settings?.t3 {
                if t3.signedIn == nil {
                    content.append(button("Sign in to T3 Connect") { [weak self, weak t3] in
                        guard let self, let window else { return }
                        suspendingWelcome = true; host?.close()
                        t3?.onOnboardingReturn = { [weak self] in self?.show() }
                        t3?.presentSignIn(in: window)
                    })
                } else {
                    for machine in t3.machines ?? [] where !environments.environmentIds.contains(machine.environmentId) {
                        content.append(button("Connect \(machine.record.label)") { [weak t3] in t3?.add(machine.environmentId) })
                    }
                    if let error = t3.discoveryError { content.append(LabelView(error, font: DSFont.ui(12), color: Themed.color(\.destructive))) }
                    content.append(button("Refresh computers") { [weak t3] in t3?.refreshMachines() })
                }
            }
            content.append(button("Add a computer") { [weak self] in
                guard let self else { return }
                suspendingWelcome = true; host?.close()
                settings?.onOnboardingReturn = { [weak self] in self?.show() }
                settings?.presentAdd(routeTarget: nil)
            })
        } else if step == 1 {
            for env in selected.sorted() {
                content.append(LabelView(environments.label(env) ?? "Computer", font: DSFont.ui(14, weight: .medium)))
                let providers = composer.config(env)?.providers ?? []
                let claude = OnboardingProviderReadiness.select(providers, driver: "claudeAgent")
                content.append(LabelView("Claude Code · \(claude?.status ?? "Checking…")", font: DSFont.ui(14)))
                // WelcomeWizard.tsx:735-753: one Codex card per instance, a newly added account first.
                var codex = providers.filter { $0.driver == "codex" }.map { ($0.instanceId.rawValue, Optional($0)) }
                if codex.isEmpty { codex = [("codex", OnboardingProviderReadiness.select(providers, driver: "codex"))] }
                if let created = createdAccount, created.env == env {
                    let index = codex.firstIndex { $0.0 == created.instance }
                    let existing = index.map { codex.remove(at: $0) }
                    codex.insert(existing ?? (created.instance, nil), at: 0)
                }
                for (instance, provider) in codex {
                    if let card = codexCard(env: env, instance: instance, provider: provider) { content.append(card) }
                    else { content.append(LabelView("Codex · \(provider?.status ?? "Checking…")", font: DSFont.ui(14))) }
                }
                // WelcomeWizard.tsx:838-856.
                if providers.contains(where: { $0.driver == "codex" && OnboardingProviderReadiness.state($0) == .ready }) {
                    let another = ButtonView("Connect another ChatGPT account", variant: .ghostMuted, size: .xs)
                    another.action = { [weak self] in self?.addChatGptAccount(env) }
                    content.append(LeadingButtonRow(another))
                }
            }
            // ponytail: provider setup opens the existing provider page; add the inline onboarding terminal before claiming step-two parity.
            content.append(button("Set up agents") { [weak self] in
                guard let self else { return }
                suspendingWelcome = true; host?.close()
                settings?.onOnboardingReturn = { [weak self] in self?.show() }
                settings?.show(.providers)
            })
        } else if isLoadingProjects {
            // The first scan is still out on every computer (WelcomeWizard.tsx:1434-1450).
            content[1] = LabelView("Your projects", font: DSFont.ui(24, weight: .semibold))
            content.remove(at: 2)
            content.append(OnboardingProjectsLoadingView())
        } else {
            importList.update(scans: listScans, selected: currentSelection, importing: busy, error: visibleImportError)
            content.append(importList)
        }
        if let error, step != 2 { content.append(LabelView(error, font: DSFont.ui(12), color: Themed.color(\.destructive))) }
        dialog.panelContent = content
        // The host sizes the popup: a step with taller content (the Codex cards) needs it to measure again.
        dialog.superview?.needsLayout = true
        if step == 2 {
            let skip = ButtonView("Do not import projects", variant: .ghostMuted)
            skip.isEnabled = !busy
            skip.action = { [weak self] in
                guard let self else { return }
                if isLoadingProjects { complete() } else { finishAfterImport() }
            }
            if isLoadingProjects {
                dialog.footerButtons = [skip]
            } else {
                let count = selectedCandidates.count
                let run = ButtonView(busy ? "Importing…" : "Import \(count) \(count == 1 ? "project" : "projects")")
                run.isEnabled = canImport && !busy && count > 0
                run.action = { [weak self] in self?.runImport() }
                dialog.footerButtons = [skip, run]
            }
        } else {
            let next = button("Continue") { [weak self] in guard let self else { return }; step += 1; if step == 2 { scanAll() }; render() }
            next.isEnabled = !busy && !selected.isEmpty && selected.allSatisfy { environments.state($0)?.status == .connected }
            dialog.footerButtons = [next]
        }
    }

    // MARK: Step 3: projects (WelcomeWizard.tsx:1194-1567)

    private var allCandidates: [OnboardingProjectCandidate] { scanIds.flatMap { scans[$0]?.candidates ?? [] } }
    private var isLoadingProjects: Bool {
        !scanIds.isEmpty && scanIds.allSatisfy { scans[$0]?.candidates == nil } && scanIds.contains { scans[$0]?.pending == true }
    }
    private var currentSelection: Set<String> {
        selectedKeys ?? Set(OnboardingProjectImport.recent(allCandidates, nowMs: TimestampFormat.nowMs()).map(\.key))
    }
    private var selectedCandidates: [OnboardingProjectCandidate] {
        let keys = currentSelection
        return allCandidates.filter { keys.contains($0.key) }
    }
    /// T3 reads the session's scopes; a session not read yet does not block here.
    private func writable(_ env: String) -> Bool { scans[env]?.writable != false }
    private var canImport: Bool { selectedCandidates.allSatisfy { writable($0.environmentId) } }
    private var visibleImportError: String? {
        if !canImport { return OnboardingProjectImport.permissionMessage }
        return error == OnboardingProjectImport.permissionMessage ? nil : error
    }
    private var listScans: [OnboardingImportListView.Scan] {
        scanIds.map { env in
            let s = scans[env] ?? ProjectScan()
            return .init(environmentId: env, label: environments.label(env) ?? "Computer", pending: s.pending && s.candidates == nil,
                         error: s.error, truncated: s.truncated, candidates: s.candidates ?? [])
        }
    }

    /// One scan per computer set up, together; a computer's Retry runs its own again.
    private func scanAll() {
        for env in scanIds { scans[env]?.task?.cancel() }
        scanIds = selected.sorted()
        scans = [:]
        selectedKeys = nil
        error = nil
        for env in scanIds { scan(env) }
    }

    private func scan(_ env: String) {
        var state = scans[env] ?? ProjectScan()
        state.task?.cancel()
        state.pending = true
        state.error = nil
        let shell = environments.session(env)
        state.task = Task { [weak self] in
            guard let self else { return }
            async let access = try? shell?.http.session(token: shell?.token)
            do {
                let result = try await environments.request(env, "agentSessions.scan", .object([:]))
                try Task.checkCancellation()
                scans[env]?.candidates = (result["candidates"]?.arrayValue ?? []).compactMap { OnboardingProjectCandidate(environmentId: env, json: $0) }
                scans[env]?.truncated = result["truncated"]?.boolValue == true
            } catch is CancellationError {
                return
            } catch {
                scans[env]?.error = Self.message(error)
            }
            if let session = await access { scans[env]?.writable = session.grants(AuthScopes.orchestrationOperate) }
            scans[env]?.pending = false
            scans[env]?.task = nil
            if step == 2 { render() }
        }
        scans[env] = state
        if step == 2 { render() }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// `runImport`: creates each missing project (reusing an attempt's ids), imports its history, and
    /// retries skip what landed. Failures refresh that computer's scan; a warning sums up what did not.
    private func runImport() {
        let selection = selectedCandidates
        guard !busy else { return }
        guard selection.allSatisfy({ writable($0.environmentId) }) else { error = OnboardingProjectImport.permissionMessage; render(); return }
        if selection.isEmpty { complete(); return }
        busy = true; error = nil
        importWarning = ""
        importedThreadCount = 0
        lastImportSelection = selection.map(\.key)
        render()
        task = Task { [weak self] in
            guard let self else { return }
            var landed = selection.filter { importedProjects[$0.key] != nil }.count
            var imported = 0, skipped = 0
            var refresh: Set<String> = []
            for candidate in selection {
                guard !Task.isCancelled else { return }
                guard writable(candidate.environmentId) else {
                    busy = false; error = OnboardingProjectImport.permissionMessage; render(); return
                }
                let key = candidate.key, env = candidate.environmentId
                if importedProjects[key] != nil { continue }
                var projectId = candidate.projectId
                    ?? environments.snapshot(env).flatMap { ProjectCommands.existing($0.projects, workspaceRoot: candidate.path)?.id.localId.rawValue }
                if projectId == nil {
                    let attempt = projectAttempts[key] ?? {
                        let id = UUID().uuidString.lowercased()
                        return (id, "onboarding:project:create:\(id)")
                    }()
                    projectAttempts[key] = attempt
                    do {
                        _ = try await environments.request(env, "projects.mutate", ProjectCommands.create(
                            projectId: ProjectId(attempt.projectId), workspaceRoot: candidate.path, createWorkspaceRootIfMissing: false,
                            title: candidate.title, commandId: attempt.commandId))
                        projectId = attempt.projectId
                    } catch is CancellationError {
                        return
                    } catch {
                        projectAttempts[key] = nil
                        refresh.insert(env)
                        continue
                    }
                }
                guard let projectId else { continue }
                do {
                    let result = try await environments.request(env, "agentSessions.import", .object([
                        "projectId": .string(projectId), "expectedWorkspaceRoot": .string(candidate.path)]))
                    let count = result["importedCount"]?.intValue ?? 0, missed = result["skippedCount"]?.intValue ?? 0
                    imported += count; skipped += missed
                    if count > 0 { projectsWithHistory[key] = (env, projectId) }
                    if missed == 0 { landed += 1; importedProjects[key] = (env, projectId) }
                } catch is CancellationError {
                    return
                } catch {
                    projectAttempts[key] = nil
                    refresh.insert(env)
                }
            }
            for env in refresh { scan(env) }
            busy = false
            importedThreadCount = imported
            if landed < selection.count { importWarning = OnboardingProjectImport.warning(imported: imported, skipped: skipped) }
            finishAfterImport()
        }
    }

    /// `finishAfterImport`: open the selected project with imported history, else one that landed empty.
    private func finishAfterImport() {
        guard let project = OnboardingProjectImport.landing(lastImportSelection, withHistory: projectsWithHistory, completed: importedProjects) else {
            complete()
            return
        }
        landing = project
        busy = true
        render()
        land()
    }

    /// Waits for the landing project in its computer's shell, then finishes there.
    private func land() {
        guard let landing, openProject?(landing.env, landing.projectId) == true else { return }
        self.landing = nil
        busy = false
        complete(opened: true)
    }

    /// `finish` (WelcomeWizard.tsx:172-219): marks onboarding done, closes, then reports the import.
    private func complete(opened: Bool = false) {
        ClientSettingsStore.shared.update(["onboardingCompletedAt": .string(ISO8601DateFormatter().string(from: Date()))])
        host?.close()
        if !importWarning.isEmpty {
            _ = toasts?.show(ToastView(title: "Some history was not imported", message: importWarning, kind: .warning), timeout: 0)
        } else if importedThreadCount > 0 {
            _ = toasts?.show(ToastView(title: "Imported \(importedThreadCount) \(importedThreadCount == 1 ? "thread" : "threads")", kind: .success))
        }
        importWarning = ""
        importedThreadCount = 0
    }
}

/// "Looking for projects from Claude Code and Codex…" under a large muted spinner, centered (`min-h-40 py-6 gap-3`).
private final class OnboardingProjectsLoadingView: DSView {
    private let spinner = SpinnerView(size: .lg, tone: .muted)
    private let label = LabelView("Looking for projects from Claude Code and Codex…", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.lineHeight = 20
        addSubview(spinner); addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 112) }
    override func layout() {
        super.layout()
        let top = (bounds.height - 20 - 12 - 20) / 2
        spinner.frame = NSRect(x: (bounds.width - 20) / 2, y: top, width: 20, height: 20)
        label.frame = NSRect(x: 0, y: top + 32, width: bounds.width, height: 20)
    }
}


/// A button at its own width at the start of a full-width panel row (`<div className="mt-3"><Button size="xs">`).
private final class LeadingButtonRow: DSView {
    private let button: ButtonView
    init(_ button: ButtonView) {
        self.button = button
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: button.intrinsicContentSize.height))
        addSubview(button)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: button.intrinsicContentSize.height) }
    override func layout() { super.layout(); button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize) }
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
