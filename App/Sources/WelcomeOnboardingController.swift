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
    private var step = 0
    private var selected: Set<String> = []
    private var candidates: [(env: String, value: JSONValue)] = []
    private var selectedPaths: Set<String> = []
    private var importedProjects: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var busy = false
    private var error: String?

    init(window: NSWindow, environments: Environments, composer: ComposerController, settings: SettingsController) {
        self.window = window; self.environments = environments; self.composer = composer; self.settings = settings
        environments.observe { [weak self] in if self?.step == 0 { self?.render() } }
        composer.configObservers.append { [weak self] _ in if self?.step == 1 { self?.render() } }
    }
    func show() {
        guard host == nil, let window else { return }
        selected = Set(environments.environmentIds.filter { environments.state($0)?.status == .connected })
        let dialog = DialogView(title: "Set up T3 Code")
        dialog.maxWidth = 768
        dialog.footerVariant = .bare
        self.dialog = dialog
        render()
        let host = ModalHost.present(dialog, in: window)
        self.host = host
        dialog.onClose = { [weak host] in host?.close() }
        host.onDismiss = { [weak self] in self?.task?.cancel(); self?.task = nil; self?.host = nil; self?.dialog = nil }
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
            for env in environments.environmentIds {
                content.append(OnboardingChoiceRowView(title: environments.label(env) ?? "Computer",
                    detail: environments.state(env)?.status == .connected ? "Connected" : "Not connected", selected: selected.contains(env)) { [weak self] on in
                    if on { self?.selected.insert(env) } else { self?.selected.remove(env) }; self?.render()
                })
            }
            content.append(button("Add a computer") { [weak self] in self?.host?.close(); self?.settings?.show(.connections) })
        } else if step == 1 {
            for env in selected.sorted() {
                content.append(LabelView(environments.label(env) ?? "Computer", font: DSFont.ui(14, weight: .medium)))
                for driver in ["claudeAgent", "codex"] {
                    let provider = composer.config(env)?.providers.first { $0.driver == driver }
                    let title = driver == "codex" ? "Codex" : "Claude Code"
                    content.append(LabelView("\(title) · \(provider?.status ?? "Checking…")", font: DSFont.ui(14)))
                }
            }
            // ponytail: provider setup opens the existing provider page; add the inline onboarding terminal before claiming step-two parity.
            content.append(button("Set up agents") { [weak self] in self?.host?.close(); self?.settings?.show(.providers) })
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
