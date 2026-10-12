import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// Clones in flight on every environment (ProjectCloneToastCoordinator.tsx, ChatView.tsx:2535-2596).
/// The palette that starts a clone closes at once, so progress lives here: one toast per clone,
/// updated in place as git reports stages, then a success toast with "Open project" or a failure
/// toast with Retry. While the user looks at the cloning project, the composer's notice banner
/// shows the same progress and actions and the toast steps aside.
///
/// Each environment with `projectCloneTracking` streams `subscribeProjectClones`: the server sends
/// an empty list and stays quiet until a clone starts, so this costs nothing at idle.
@MainActor
final class ProjectCloneController {
    private let panel: ThreadPanelView
    private let environments: Environments
    private weak var composer: ComposerController?
    private var streams: [String: (session: ShellSession, task: Task<Void, Never>)] = [:]
    private var clones: [String: [ProjectCloneSnapshot]] = [:]
    /// One toast per clone: its id, the snapshot drawn and the phase.
    private var toasts: [String: (id: Int, key: String, phase: ProjectCloneSnapshot.Phase)] = [:]
    /// The banner's clone, by scoped project id.
    private var bannerProject: ProjectId?
    /// Opens a project's draft ("Open project").
    var openProject: ((ProjectId) -> Void)?

    init(panel: ThreadPanelView, environments: Environments, composer: ComposerController) {
        self.panel = panel
        self.environments = environments
        self.composer = composer
        panel.lazyNoticeBanner.configure { [weak self] banner in banner.onAction = { [weak self] index in self?.bannerAction(index) } }
        composer.configObservers.append { [weak self] env in self?.sessionChanged(env) }
    }

    // MARK: Streams

    /// An environment's session or config changed: follow its clone list when the server tracks clones.
    func sessionChanged(_ environmentId: String) {
        let session = environments.session(environmentId)
        let tracked = composer?.config(environmentId)?.capabilities.contains("projectCloneTracking") == true
        if let current = streams[environmentId], current.session === session, tracked { return }
        streams[environmentId]?.task.cancel()
        streams[environmentId] = nil
        guard let session, tracked else {
            if clones[environmentId] != nil { apply([], environmentId: environmentId) }
            return
        }
        let task = session.supervisor.subscribe("subscribeProjectClones", payload: { .object([:]) }, handler: { [weak self] event in
            guard case .value(let json) = event else { return }
            let list = ProjectCloneSnapshot.list(json)
            await MainActor.run {
                guard let self, self.streams[environmentId]?.session === session else { return }
                self.apply(list, environmentId: environmentId)
            }
        })
        streams[environmentId] = (session, task)
    }

    func environmentRemoved(_ environmentId: String) {
        streams[environmentId]?.task.cancel()
        streams[environmentId] = nil
        apply([], environmentId: environmentId)
    }

    private func apply(_ list: [ProjectCloneSnapshot], environmentId: String) {
        clones[environmentId] = list.isEmpty ? nil : list
        syncToasts(environmentId)
        syncBanner()
    }

    // MARK: Toasts (ProjectCloneToastCoordinator.tsx:98-221)

    private func syncToasts(_ env: String) {
        let list = clones[env] ?? []
        var seen = Set<String>()
        for clone in list {
            let key = EnvironmentScope.key(env, clone.projectId)
            seen.insert(key)
            if composer?.activeDraftProjectId?.rawValue == key {
                // The draft's banner shows it.
                if let t = toasts.removeValue(forKey: key) { panel.toasts.dismiss(t.id) }
                continue
            }
            if toasts[key]?.key == clone.renderKey { continue }
            show(clone, env: env, scopedKey: key)
        }
        // A clone the server stopped tracking takes its toast, unless it settled into a timed success.
        for (key, t) in toasts where key.hasPrefix(env + ":") && !seen.contains(key) {
            if t.phase != .done { panel.toasts.dismiss(t.id) }
            toasts[key] = nil
        }
    }

    private func show(_ clone: ProjectCloneSnapshot, env: String, scopedKey key: String) {
        let name = clone.displayName
        let projectId = clone.projectId
        let (title, message): (String, String) = switch clone.phase {
        case .running: ("Cloning \(name)", clone.progressSummary)
        case .done: ("Cloned \(name)", clone.destinationPath)
        case .cancelled: ("Cancelled cloning \(name)", clone.destinationPath)
        case .failed: ("Failed to clone \(name)", clone.error ?? "The clone failed.")
        }
        // A running toast whose phase holds changes its text in place.
        if let t = toasts[key], t.phase == clone.phase, panel.toasts.update(t.id, title: title, message: message) {
            toasts[key] = (t.id, clone.renderKey, clone.phase)
            return
        }
        if let t = toasts[key] { panel.toasts.dismiss(t.id) }
        let toast: ToastView
        var timeout: TimeInterval = 0
        switch clone.phase {
        case .running:
            toast = ToastView(title: title, message: message, kind: .loading, actionTitle: "Cancel",
                              action: { [weak self] in self?.run("Failed to cancel clone", env, "projectClone.cancel", projectId) })
        case .done:
            timeout = 8
            toast = ToastView(title: title, message: message, kind: .success, actionTitle: "Open project", action: { [weak self] in
                guard let self else { return }
                if let t = self.toasts.removeValue(forKey: key) { self.panel.toasts.dismiss(t.id) }
                self.openProject?(ProjectId(key))
            })
        case .failed, .cancelled:
            // ponytail: one action per toast, so "Remove project" lives on the composer banner only; add a
            // secondary toast action if people miss it there
            toast = ToastView(title: title, message: message, kind: clone.phase == .cancelled ? .info : .error, actionTitle: "Retry",
                              action: { [weak self] in self?.run("Failed to retry clone", env, "projectClone.retry", projectId) })
        }
        let id = panel.toasts.show(toast, timeout: timeout)
        toasts[key] = (id, clone.renderKey, clone.phase)
    }

    /// Cancel and Retry report a request that never reached the server (`runCloneAction`).
    private func run(_ failure: String, _ env: String, _ method: String, _ projectId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.environments.request(env, method, .object(["projectId": .string(projectId)]))
            } catch {
                self.panel.toasts.show(ToastView(title: failure, message: PaletteAddProjectFlow.message(error), kind: .error))
            }
        }
    }

    // MARK: Composer banner (ChatView.tsx:2535-2596)

    /// The open thread or draft changed: the banner follows its project.
    func syncBanner() {
        let project = composer?.activeProjectId
        let clone = project.flatMap { id -> ProjectCloneSnapshot? in
            guard let env = id.environmentId else { return nil }
            return clones[env]?.first { $0.projectId == id.localId.rawValue }
        }
        composer?.projectCloneSendBlock = ComposerLogic.projectCloneSendBlockReason(running: clone.map { $0.phase == .running }, done: clone?.phase == .done)
        guard let clone, let project, clone.phase != .done else {
            bannerProject = nil
            panel.showsNoticeBanner = false
            // Leaving a cloning draft brings its toast back.
            if let env = project?.environmentId { syncToasts(env) }
            return
        }
        bannerProject = project
        let name = clone.displayName
        let content: ComposerNoticeBannerView.Content = clone.phase == .running
            ? .init(variant: .neutral, icon: .download, title: "Cloning \(name)", description: clone.progressSummary, actions: ["Cancel"], compact: true, priority: .activity)
            : .init(variant: clone.phase == .cancelled ? .warning : .error, icon: .download,
                    title: clone.phase == .cancelled ? "Cancelled cloning \(name)" : "Failed to clone \(name)",
                    description: clone.phase == .cancelled ? "Retry to bring in the repository." : clone.error,
                    actions: ["Remove project", "Retry"], compact: true)
        panel.noticeBanner.apply(content)
        panel.showsNoticeBanner = true
        if let env = project.environmentId { syncToasts(env) }
    }

    private func bannerAction(_ index: Int?) {
        guard let project = bannerProject, let env = project.environmentId, let index,
              let clone = clones[env]?.first(where: { $0.projectId == project.localId.rawValue }) else { return }
        let local = project.localId.rawValue
        if clone.phase == .running {
            run("Failed to cancel clone", env, "projectClone.cancel", local)
        } else if index == 0 {
            removeProject(env, local)
        } else {
            run("Failed to retry clone", env, "projectClone.retry", local)
        }
    }

    /// `useRemoveClonedProject`: `project.delete` without force (a project that gained threads stays).
    private func removeProject(_ env: String, _ projectId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.environments.request(env, "projects.mutate", .object([
                    "type": .string("project.delete"), "commandId": .string(ThreadCommands.newCommandId()), "projectId": .string(projectId),
                ]))
            } catch {
                self.panel.toasts.show(ToastView(title: "Failed to remove project", message: PaletteAddProjectFlow.message(error), kind: .error))
            }
        }
    }
}
