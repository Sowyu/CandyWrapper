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
    private var candidates: [(env: String, value: JSONValue)] = []
    private var selectedPaths: Set<String> = []
    private var importedProjects: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var busy = false
    private var error: String?

    init(window: NSWindow, environments: Environments, composer: ComposerController, settings: SettingsController) {
        self.window = window; self.environments = environments; self.composer = composer; self.settings = settings
        settings.t3.observe { [weak self] in if self?.step == 0 { self?.render() } }
        environments.observe { [weak self] in self?.evaluateFirstRun(); if self?.step == 0 { self?.render() } }
        composer.configObservers.append { [weak self] _ in self?.evaluateFirstRun(); if self?.step == 1 { self?.render() } }
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
    private func key(_ env: String, _ value: JSONValue) -> String { env + ":" + (value["path"]?.stringValue ?? "") }
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
        } else {
            content.append(button("Select all") { [weak self] in guard let self else { return }; selectedPaths = Set(candidates.map { key($0.env, $0.value) }); render() })
            content.append(button("Select none") { [weak self] in self?.selectedPaths = []; self?.render() })
            if busy { content.append(LabelView("Looking for projects from Claude Code and Codex…", font: DSFont.ui(14))) }
            for item in candidates {
                let id = key(item.env, item.value)
                content.append(OnboardingChoiceRowView(title: item.value["title"]?.stringValue ?? "Project", detail: item.value["path"]?.stringValue ?? "",
                                                       selected: selectedPaths.contains(id)) { [weak self] on in
                    if on { self?.selectedPaths.insert(id) } else { self?.selectedPaths.remove(id) }; self?.render()
                })
            }
            if candidates.isEmpty, !busy { content.append(LabelView("No projects found.", font: DSFont.ui(14))) }
        }
        if let error { content.append(LabelView(error, font: DSFont.ui(12), color: Themed.color(\.destructive))) }
        dialog.panelContent = content
        if step == 2 {
            let skip = button("Do not import projects") { [weak self] in self?.finish() }
            let run = button("Import \(selectedPaths.count) \(selectedPaths.count == 1 ? "project" : "projects")") { [weak self] in self?.runImport() }
            run.isEnabled = !busy && !selectedPaths.isEmpty
            dialog.footerButtons = [skip, run]
        } else {
            let next = button("Continue") { [weak self] in guard let self else { return }; step += 1; if step == 2 { scan() }; render() }
            next.isEnabled = !busy && !selected.isEmpty && selected.allSatisfy { environments.state($0)?.status == .connected }
            dialog.footerButtons = [next]
        }
    }
    private func scan() {
        task?.cancel(); busy = true; candidates = []; error = nil
        let ids = selected.sorted()
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; render() }
            for env in ids {
                do {
                    let result = try await environments.request(env, "agentSessions.scan", .object([:]))
                    try Task.checkCancellation()
                    let values = result["candidates"]?.arrayValue ?? []
                    candidates += values.map { (env, $0) }
                } catch is CancellationError { return }
                catch { self.error = "Could not check projects. \(error)" }
            }
            selectedPaths = Set(candidates.filter { $0.value["alreadyImported"]?.boolValue != true }.map { key($0.env, $0.value) })
        }
    }
    private func runImport() {
        busy = true; error = nil; render()
        let selection = candidates.filter { selectedPaths.contains(key($0.env, $0.value)) }
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; render() }
            do {
                for item in selection {
                    try Task.checkCancellation()
                    guard let path = item.value["path"]?.stringValue else { continue }
                    let id = key(item.env, item.value)
                    let projectId: String
                    if let existing = importedProjects[id] ?? item.value["projectId"]?.stringValue { projectId = existing }
                    else {
                        let createdId = ProjectId(UUID().uuidString.lowercased())
                        let result = try await environments.request(item.env, "projects.mutate", ProjectCommands.create(projectId: createdId, workspaceRoot: path, createWorkspaceRootIfMissing: false, title: item.value["title"]?.stringValue))
                        projectId = try result.decode(as: ProjectShell.self).id.rawValue
                        importedProjects[id] = projectId
                    }
                    let result = try await environments.request(item.env, "agentSessions.import", .object(["projectId": .string(projectId), "expectedWorkspaceRoot": .string(path)]))
                    if (result["skippedCount"]?.intValue ?? 0) > 0 { self.error = "Some conversations could not be imported. Try again." }
                }
                if error == nil { finish() }
            } catch is CancellationError { return }
            catch { self.error = "Could not import projects. \(error)" }
        }
    }
    private func finish() {
        ClientSettingsStore.shared.update(["onboardingCompletedAt": .string(ISO8601DateFormatter().string(from: Date()))])
        host?.close()
    }
}
