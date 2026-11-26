import AppKit
import Features
import T3Protocol
import T3Store

/// The details card's repository sections for the open thread (5258 ThreadRepositorySections.tsx): the repositories
/// the thread changed, from its projection, each with its folder's local `vcs` status. Statuses are read while the
/// card shows, when the listed repositories change and after a workspace mutation, never on a timer.
// ponytail: one vcs.refreshStatus per listed repository instead of T3's subscribeVcsStatus each, so a change made
// outside the thread shows on the next card open or mutation; subscribe per section if that lag matters
@MainActor
final class RepositorySectionsController {
    private let panel: ThreadPanelView
    private let sidebar: SidebarContentView
    private let environments: Environments
    private let git: GitController
    private var threadId: ThreadId?
    private var changed: [ThreadRepositories.Scope] = []
    private var mutation: String?
    private var showAll = false
    private var summaries: [String: ThreadRepositories.Summary] = [:]
    /// The repository paths and mutation the statuses were last read for.
    private var readFor: (keys: [String], mutation: String?)?
    private var readTask: Task<Void, Never>?

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, git: GitController) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.git = git
        panel.lazyDetailsCard.configure { [weak self] card in
            card.onRepositoriesShowAll = { [weak self] in
                guard let self else { return }
                showAll.toggle()
                render()
            }
            self?.render()
        }
        let previous = panel.onDetailsVisibilityChange
        panel.onDetailsVisibilityChange = { [weak self] in previous?(); self?.render() }
    }

    /// The open thread's projection changed (nil on a draft or a new thread).
    func update(threadId: ThreadId?, projection: ThreadProjection?) {
        if threadId != self.threadId {
            self.threadId = threadId
            showAll = false
            summaries = [:]
            readFor = nil
            readTask?.cancel()
        }
        changed = projection.map(ThreadRepositories.changed) ?? []
        mutation = projection.flatMap(TurnDiffs.workspaceMutationId)
        render()
    }

    private var project: ProjectShell? {
        guard let threadId, let snapshot = sidebar.snapshot, let thread = snapshot.threads.first(where: { $0.id == threadId }) else { return nil }
        return snapshot.projects.first { $0.id == thread.projectId }
    }

    func render() {
        guard let card = panel.lazyDetailsCard.loaded else { return }
        let tracks = !(project?.trackedFolders ?? []).isEmpty
        card.tracksFolders = tracks
        // `show.repositories` also lists what a project that tracks nothing changed, such as a submodule.
        guard threadId != nil, git.target != nil, tracks || !changed.isEmpty else { card.repositories = nil; return }
        let threadCwd = git.target?.cwd
        let sections = ThreadRepositories.sections(changed: changed, threadCwd: threadCwd, showAll: showAll)
        card.repositories = .init(visible: sections.visible.map { .init(key: $0.key, name: $0.name, summary: summaries[$0.key]) },
                                  hidden: sections.hidden.count, showAll: showAll,
                                  // `explainsEmpty={!folderIsRepo}` with `reachesTracked` (ThreadDetailsPanel.tsx:298-302).
                                  explainsEmpty: tracks && !card.isRepo)
        readStatuses(sections.visible, card: card)
    }

    /// Folded sections hold nothing (ThreadRepositorySections.tsx:220): only the visible ones read.
    private func readStatuses(_ sections: [ThreadRepositories.Section], card: ThreadDetailsCardView) {
        guard card.window != nil, !card.isHiddenOrHasHiddenAncestor, let env = threadId?.environmentId,
              let shell = environments.session(env), !sections.isEmpty else { return }
        let keys = sections.map(\.key)
        if let readFor, readFor.keys == keys, readFor.mutation == mutation { return }
        readFor = (keys, mutation)
        readTask?.cancel()
        let thread = threadId
        readTask = Task { [weak self] in
            await withTaskGroup(of: (String, ThreadRepositories.Summary?).self) { group in
                for section in sections {
                    group.addTask {
                        let reply = try? await shell.supervisor.request(VcsRPC.refreshStatus, payload: VcsRPC.cwd(section.cwd))
                        return (section.key, ThreadRepositories.Summary(status: reply))
                    }
                }
                for await (key, summary) in group {
                    guard let self, !Task.isCancelled, self.threadId == thread, let summary else { continue }
                    self.summaries[key] = summary
                }
            }
            guard let self, !Task.isCancelled, self.threadId == thread else { return }
            self.render()
        }
    }
}
