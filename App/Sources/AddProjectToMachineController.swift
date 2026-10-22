import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// "Add to another machine" from the composer's Run on menu (T3 #22180 and #22254): clones the draft's project
/// onto another connected machine, copies the ignored files the user ticked, and takes the user there.
/// The client relays the files because the two servers never talk to each other (addProjectToMachine.ts:136-141).
/// Nothing here runs until the user opens the dialog, and nothing polls while it is closed.
@MainActor
final class AddProjectToMachineController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let composer: ComposerController
    private let clones: ProjectCloneController
    /// Opens a new thread in a project, when no draft on the source project is open to move.
    var openProject: ((ProjectShell) -> Void)?
    private var modal: ModalHost?

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, composer: ComposerController, clones: ProjectCloneController) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.composer = composer
        self.clones = clones
        composer.addProjectTargets = { [weak self] project, projectEnvironmentIds in
            self?.targets(project, projectEnvironmentIds: projectEnvironmentIds) ?? []
        }
        composer.configObservers.append { [weak composer] _ in composer?.addTargetsMayHaveChanged() }
        panel.contextStrip.runOn.onAddToMachine = { [weak self] targetId in self?.open(targetEnvironmentId: targetId) }
    }

    private var sidebarEnvironments: SidebarEnvironments { sidebar?.state.environments ?? SidebarEnvironments() }

    /// `useAddProjectTargets` over every registered environment.
    func targets(_ project: ProjectShell, projectEnvironmentIds: [String]) -> [AddProjectToMachine.Target] {
        let envs = sidebarEnvironments
        let candidates = environments.environmentIds.map { env in
            AddProjectToMachine.Candidate(
                target: .init(environmentId: env, label: environments.label(env) ?? env, machine: envs.machine(env)),
                connected: environments.state(env)?.status == .connected,
                // ponytail: a session not read yet counts as granted, as `canOperate` does; block until it reads if
                // scoped pairings show the entry where T3 hides it
                canClone: environments.authSession(env).map { $0.grants(AuthScopes.sourceControlWrite) } ?? true,
                tracksClones: composer.config(env)?.capabilities.contains("projectCloneTracking") == true)
        }
        return AddProjectToMachine.targets(remoteUrl: AddProjectToMachine.remoteUrl(project), sourceEnvironmentId: project.id.environmentId,
                                           projectEnvironmentIds: projectEnvironmentIds, candidates: candidates)
    }

    /// `openAddProjectToMachine` for the open draft's project.
    func open(targetEnvironmentId: String?) {
        guard modal == nil, let window = panel.window, let draft = composer.currentDraft,
              let project = sidebar?.snapshot?.projects.first(where: { $0.id.rawValue == draft.projectId }),
              let sourceEnv = project.id.environmentId, let remote = AddProjectToMachine.remoteUrl(project) else { return }
        let targets = panel.contextStrip.runOn.addTargets
        guard !targets.isEmpty else { return }
        let source = AddProjectToMachineDialog.Source(
            label: environments.label(sourceEnv) ?? "This machine", machine: sidebarEnvironments.machine(sourceEnv),
            workspaceRoot: project.workspaceRoot, displayName: project.repositoryIdentity?.displayName ?? project.title, remoteUrl: remote)
        let canList = composer.config(sourceEnv)?.capabilities.contains("ignoredFileListing") == true
        let environments = environments
        let list: @MainActor () async throws -> (files: [AddProjectToMachine.IgnoredFile], truncated: Bool) = {
            do {
                let reply = try await environments.request(sourceEnv, "projects.listIgnoredFiles",
                                                           AddProjectToMachine.listIgnoredFilesPayload(cwd: project.workspaceRoot))
                return AddProjectToMachine.ignoredFiles(reply)
            } catch {
                throw AddProjectToMachineDialog.Failure(PaletteAddProjectFlow.message(error))
            }
        }
        let host = AddProjectToMachineDialog.present(
            in: window, source: source, targets: targets, initialTargetId: targetEnvironmentId,
            defaultDestination: { [weak self] target in
                AddProjectToMachine.defaultDestination(
                    baseDirectory: self?.composer.config(target.environmentId)?.settings.raw["addProjectBaseDirectory"]?.stringValue, remoteUrl: remote)
            },
            listFiles: canList ? list : nil,
            submit: { [weak self] submission in
                guard let self else { return }
                let projectId = try await self.add(project, submission: submission)
                // The dialog closes as this returns, then the user lands on the new machine (AddProjectToMachineDialog.tsx:184-185).
                let id = ProjectId(EnvironmentScope.key(submission.target.environmentId, projectId))
                Task { [weak self] in await self?.openWhenLoaded(id, source: project.id) }
            })
        let previous = host.onDismiss
        host.onDismiss = { [weak self] in previous?(); self?.modal = nil }
        modal = host
    }

    /// `addProjectToMachine` (addProjectToMachine.ts:142-227): reads the files first, so the copy reflects them as they
    /// were when the user asked, starts the clone, and copies once it finishes. Returns once the clone starts, with
    /// the new project's id.
    private func add(_ project: ProjectShell, submission: AddProjectToMachineDialog.Submission) async throws -> String {
        guard let sourceEnv = project.id.environmentId else { throw AddProjectToMachineDialog.Failure("An error occurred.") }
        let environments = environments
        // ponytail: one read after another, where T3 reads them all at once; overlap them if many files make it slow
        var reads: [(String, Result<String, AddProjectToMachineDialog.Failure>)] = []
        for path in submission.files {
            do {
                let reply = try await environments.request(sourceEnv, "projects.readFile",
                                                           AddProjectToMachine.readFilePayload(cwd: project.workspaceRoot, relativePath: path))
                reads.append((path, reply["truncated"]?.boolValue == true ? .failure(.init("Too large to copy.")) : .success(reply["contents"]?.stringValue ?? "")))
            } catch {
                reads.append((path, .failure(.init(PaletteAddProjectFlow.message(error)))))
            }
        }

        let targetEnv = submission.target.environmentId
        let projectId = UUID().uuidString.lowercased()
        let scoped = EnvironmentScope.key(targetEnv, projectId)
        // Marked before the start request, since the clone list can arrive before its reply.
        clones.silenceToasts(scoped)
        if !reads.isEmpty { clones.setFileCopy(scoped, .copying) }
        let started: JSONValue
        do {
            started = try await environments.request(targetEnv, "projectClone.start", AddProjectToMachine.cloneStartPayload(
                projectId: projectId, title: project.title, createdAt: T3Timestamp(Date()).raw,
                remoteUrl: submission.remoteUrl, destinationPath: submission.destinationPath))
        } catch {
            clones.setFileCopy(scoped, nil)
            throw AddProjectToMachineDialog.Failure(PaletteAddProjectFlow.message(error))
        }
        guard !reads.isEmpty else { return projectId }
        let cwd = started["cwd"]?.stringValue ?? submission.destinationPath
        let subdirectory = AddProjectToMachine.projectSubdirectory(repositoryRoot: project.repositoryIdentity?.rootPath, workspaceRoot: project.workspaceRoot)
        let label = submission.target.label
        Task { [weak self] in
            guard let self else { return }
            guard await self.clones.waitForClone(environmentId: targetEnv, projectId: projectId) != nil else {
                self.clones.setFileCopy(scoped, nil)
                return
            }
            var failed: [String] = []
            for (path, read) in reads {
                switch read {
                case .failure(let failure):
                    failed.append("\(path): \(failure.message)")
                case .success(let contents):
                    do {
                        _ = try await environments.request(targetEnv, "projects.writeFile", AddProjectToMachine.writeFilePayload(
                            cwd: cwd, subdirectory: subdirectory, relativePath: path, contents: contents))
                    } catch {
                        failed.append("\(path): \(PaletteAddProjectFlow.message(error))")
                    }
                }
            }
            self.clones.setFileCopy(scoped, failed.isEmpty ? nil : .failed(title: AddProjectToMachine.copyFailureTitle(count: failed.count, machine: label),
                                                                        failures: failed))
        }
        return projectId
    }

    /// `openClonedProject` (AddProjectToMachineDialog.tsx:137-159): a draft open on the source project moves over,
    /// else a new thread opens in the clone. CandyWrapper needs the project in its shell first.
    private func openWhenLoaded(_ id: ProjectId, source: ProjectId) async {
        // ponytail: polls the shell for up to 3 seconds after the clone starts, as the palette's clone does; wait on
        // the shell's own update if that ever feels slow
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let project = sidebar?.snapshot?.projects.first(where: { $0.id == id }) {
                if !composer.moveOpenDraft(from: source, to: project) { openProject?(project) }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
