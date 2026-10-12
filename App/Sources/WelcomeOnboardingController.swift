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
            task?.cancel(); task = nil; self.host = nil; self.dialog = nil
            if gateRoute == .wizard && !suspendingWelcome && ClientSettingsStore.shared.current.string("onboardingCompletedAt").isEmpty { show() }
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
                for driver in ["claudeAgent", "codex"] {
                    let provider = OnboardingProviderReadiness.select(composer.config(env)?.providers ?? [], driver: driver)
                    let title = driver == "codex" ? "Codex" : "Claude Code"
                    content.append(LabelView("\(title) · \(provider?.status ?? "Checking…")", font: DSFont.ui(14)))
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
