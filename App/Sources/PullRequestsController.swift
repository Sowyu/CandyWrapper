import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// What each environment says it can do with pull requests (`ExecutionEnvironmentCapabilities`):
/// `pullRequests`, `pullRequestChecks`, `threadPullRequests`, `threadPullRequestLinking`,
/// `threadPullRequestWatch`. Read once per session from the descriptor.
@MainActor
final class PullRequestCapabilities {
    private var descriptors: [String: EnvironmentDescriptor] = [:]
    private var pending: Set<String> = []
    private let environments: Environments
    var onChange: (() -> Void)?

    init(environments: Environments) { self.environments = environments }

    func has(_ environmentId: String?, _ name: String) -> Bool {
        guard let environmentId else { return false }
        guard let d = descriptors[environmentId] else { load(environmentId); return false }
        return d.capability(name)
    }

    func known(_ environmentId: String) -> Bool { descriptors[environmentId] != nil }

    func load(_ environmentId: String) {
        guard !pending.contains(environmentId), let http = environments.session(environmentId)?.http else { return }
        pending.insert(environmentId)
        Task { [weak self] in
            let d = try? await http.descriptor()
            guard let self else { return }
            self.pending.remove(environmentId)
            if let d { self.descriptors[environmentId] = d; self.onChange?() }
        }
    }

    func forget(_ environmentId: String) { descriptors[environmentId] = nil }
}

/// One pull request surface's reads and writes (PullRequestDetailPanel.tsx): `pullRequests.detail`,
/// then `pullRequests.activity`; the Code tab's `POST /api/pull-requests/diff` and
/// `pullRequests.filesViewed`; the actions, comments and reviews. Drives a `PullRequestDetailView`.
@MainActor
final class PullRequestDetailBinding {
    let view: PullRequestDetailView
    private let environments: Environments
    private let capabilities: PullRequestCapabilities
    var toast: (String, String?, ToastQueue.Kind) -> Void = { _, _, _ in }
    /// The state the surface's tab glyph wears, by surface id.
    var onStatus: ((String, PullRequestStateTone) -> Void)?
    /// A write landed; the list or the thread's status behind it may have moved.
    var onActed: ((String) -> Void)?
    private(set) var environmentId: String?
    private(set) var target: PullRequestSurfaceTarget?
    private(set) var detail: PullRequestDetail?
    private var generation = 0
    private var commit: String?
    private var patchKey: String?
    private var viewedStates: [String: String]?
    private var overlay: [String: Bool] = [:]
    private var pendingViewed: Set<String> = []

    init(view: PullRequestDetailView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.view = view
        self.environments = environments
        self.capabilities = capabilities
        view.preferredMergeMethod = UserDefaults.standard.string(forKey: Self.mergeMethodKey) ?? "merge"
        view.onTab = { [weak self] tab in if tab == .code { self?.loadCode() } }
        view.onRetry = { [weak self] in self?.reload(invalidate: false) }
        view.onRefresh = { [weak self] in self?.reload(invalidate: true) }
        view.onOpenURL = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        view.onCopy = { [weak self] text, label in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.toast("\(label) copied", text, .success)
        }
        view.onMergeMethod = { m in UserDefaults.standard.set(m, forKey: Self.mergeMethodKey) }
        view.onAction = { [weak self] action, method in self?.perform(action, mergeMethod: method) }
        view.onComment = { [weak self] body in self?.comment(body) }
        view.onReview = { [weak self] verdict, body in self?.review(verdict, body: body) }
        view.onCommit = { [weak self] oid in self?.commit = oid; self?.patchKey = nil; self?.loadCode() }
        view.onSetViewed = { [weak self] path, viewed in self?.setViewed(path, viewed) }
        view.onCheckout = { [weak self] _ in self?.toast("Check out is not in CandyWrapper yet", "Use the copied command from the header.", .info) }
    }

    /// `pullRequestMergeMethod` in T3's UI state store.
    static let mergeMethodKey = "pullRequests.mergeMethod"

    private var shell: ShellSession? { environments.session(environmentId) }

    var reference: PullRequestRef? {
        target.map { PullRequestRef(projectId: $0.projectId, host: capabilities.has(environmentId, "threadPullRequests") ? $0.host : nil,
                                    repository: $0.repository, number: $0.number) }
    }

    /// Shows a pull request; the same one again keeps what is loaded.
    func show(environmentId: String, target: PullRequestSurfaceTarget) {
        if self.environmentId == environmentId, self.target?.surfaceId == target.surfaceId { return }
        self.environmentId = environmentId
        self.target = target
        detail = nil
        commit = nil
        patchKey = nil
        viewedStates = nil
        overlay = [:]
        view.tab = .summary
        view.showLoading(number: target.number)
        reload(invalidate: false)
    }

    func clear() {
        generation += 1
        environmentId = nil
        target = nil
        detail = nil
    }

    /// `refreshDetail`, or the header's Refresh (`refreshFromHost`, which invalidates the server's
    /// cache first with `pullRequests.invalidate`).
    func reload(invalidate: Bool) {
        guard let shell, let ref = reference, let target else { return }
        generation += 1
        let gen = generation
        view.refreshing = true
        Task { [weak self] in
            if invalidate { _ = try? await shell.supervisor.request("pullRequests.invalidate", payload: .object(["reference": ref.payload])) }
            do {
                let reply = try await shell.supervisor.request("pullRequests.detail", payload: ref.payload)
                let d = try reply.decode(as: PullRequestDetail.self)
                guard let self, self.generation == gen else { return }
                self.detail = d
                self.view.activityPending = true
                self.view.activityError = nil
                self.view.show(d)
                self.onStatus?(target.surfaceId, PullRequestStateTone(state: d.state, isDraft: d.isDraft))
                self.loadActivity(gen: gen)
                if self.view.tab == .code { self.patchKey = nil; self.loadCode() }
            } catch {
                guard let self, self.generation == gen else { return }
                self.view.refreshing = false
                let (title, message) = Self.failure(error, number: target.number)
                self.view.showFailure(title: title, message: message)
            }
        }
    }

    private func loadActivity(gen: Int) {
        guard let shell, let ref = reference else { return }
        Task { [weak self] in
            do {
                let reply = try await shell.supervisor.request("pullRequests.activity", payload: ref.payload)
                let activity = try reply.decode(as: PullRequestActivity.self)
                guard let self, self.generation == gen, var d = self.detail else { return }
                d.apply(activity)
                self.detail = d
                self.view.activityPending = false
                self.view.show(d)
            } catch {
                guard let self, self.generation == gen else { return }
                self.view.activityPending = false
                self.view.activityError = Self.failure(error, number: ref.number).1
            }
            self?.view.refreshing = false
        }
    }

    /// The Code tab: the patch over HTTP (large payloads skip the socket) and the viewed marks.
    private func loadCode() {
        guard let shell, let ref = reference, let d = detail, d.capabilities.diff else { return }
        let key = "\(ref.projectId):\(ref.repository):\(ref.number):\(commit ?? "all"):\(d.updatedAt)"
        guard patchKey != key else { return }
        patchKey = key
        let commit = self.commit
        view.setPatch(nil, loading: true, error: nil, commit: commit)
        let gen = generation
        Task { [weak self] in
            do {
                let result = try await shell.http.post("api/pull-requests/diff", PullRequestPayloads.diff(ref, commit: commit), token: shell.token,
                                                       as: PullRequestDiffResult.self)
                guard let self, self.generation == gen, self.patchKey == key else { return }
                self.view.setPatch(result.patch, loading: false, error: nil, commit: commit)
            } catch {
                guard let self, self.generation == gen, self.patchKey == key else { return }
                self.view.setPatch(nil, loading: false, error: Self.failure(error, number: ref.number).1, commit: commit)
            }
        }
        loadViewed()
    }

    private func loadViewed() {
        guard let shell, let ref = reference, let store = detail?.capabilities.viewedFiles else {
            view.setViewed(states: nil, overlay: [:], store: nil)
            return
        }
        Task { [weak self] in
            let reply = try? await shell.supervisor.request("pullRequests.filesViewed", payload: ref.payload)
            let result = try? reply?.decode(as: PullRequestFilesViewedResult.self)
            guard let self else { return }
            if let result { self.viewedStates = Dictionary(result.files.map { ($0.path, $0.state) }, uniquingKeysWith: { _, b in b }) }
            self.overlay = PullRequestDetailLogic.settleOverlay(self.overlay, states: self.viewedStates, pending: self.pendingViewed, answered: [])
            self.view.setViewed(states: self.viewedStates, overlay: self.overlay, store: store)
        }
    }

    /// `pullRequests.setFilesViewed`: the press shows at once and is taken back if the host refuses.
    private func setViewed(_ path: String, _ viewed: Bool) {
        guard let shell, let ref = reference, let store = detail?.capabilities.viewedFiles else { return }
        overlay[path] = viewed
        pendingViewed.insert(path)
        view.setViewed(states: viewedStates, overlay: overlay, store: store)
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.setFilesViewed", payload: PullRequestPayloads.setFilesViewed(ref, files: [(path, viewed)]))
                self?.pendingViewed.remove(path)
                self?.loadViewed()
            } catch {
                guard let self else { return }
                self.pendingViewed.remove(path)
                self.overlay = PullRequestDetailLogic.revertOverlay(self.overlay, batch: [(path, viewed)], owned: [path])
                self.view.setViewed(states: self.viewedStates, overlay: self.overlay, store: store)
                self.toast("Could not save the viewed mark", Self.failure(error, number: ref.number).1, .error)
            }
        }
    }

    /// `pullRequests.runAction`, then a fresh read.
    func perform(_ action: String, mergeMethod: String?) {
        guard let shell, let ref = reference else { return }
        view.actionPending = true
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.runAction", payload: PullRequestPayloads.action(ref, action: action, mergeMethod: mergeMethod))
                guard let self else { return }
                self.view.actionPending = false
                self.toast(PullRequestDetailLogic.actionSuccess(action), nil, .success)
                self.onActed?(action)
                self.reload(invalidate: action == "update-branch" || action == "approve-workflows")
            } catch {
                guard let self else { return }
                self.view.actionPending = false
                self.toast(PullRequestDetailLogic.actionFailure(action), Self.failure(error, number: ref.number).1, .error)
            }
        }
    }

    private func comment(_ body: String) {
        guard let shell, let ref = reference, let payload = PullRequestPayloads.comment(ref, body: body) else { return }
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.comment", payload: payload)
                self?.reload(invalidate: false)
            } catch {
                self?.toast("Could not post the comment", Self.failure(error, number: ref.number).1, .error)
            }
        }
    }

    private func review(_ verdict: String, body: String) {
        guard let shell, let ref = reference else { return }
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.submitReview", payload: PullRequestPayloads.submitReview(ref, verdict: verdict, body: body))
                self?.toast(verdict == "approve" ? "Pull request approved" : verdict == "request-changes" ? "Changes requested" : "Review submitted", nil, .success)
                self?.reload(invalidate: false)
            } catch {
                self?.toast("The review could not be submitted", Self.failure(error, number: ref.number).1, .error)
            }
        }
    }

    /// A failed read as the unavailable state's title and message (`PullRequestsUnavailableState`).
    nonisolated static func failure(_ error: Error, number: Int) -> (String, String) {
        if let e = error as? RPCClientError, let typed = e.typedError {
            if PullRequestErrors.isNotFound(tag: typed.tag, fields: typed.fields) {
                return ("Pull request #\(number) not found", "It may be an issue rather than a pull request, or this account can't see it.")
            }
            return ("Could not load pull requests", PullRequestErrors.message(tag: typed.tag, fields: typed.fields) ?? typed.message ?? typed.tag)
        }
        if case .status(_, let body?)? = error as? EnvironmentHTTPError {
            var fields: [String: JSONValue] = [:]
            if let r = body.reason { fields["reason"] = .string(r) }
            if let m = body.message { fields["detail"] = .string(m) }
            return ("Could not load pull requests", PullRequestErrors.message(tag: body.tag, fields: fields) ?? body.message ?? body.tag)
        }
        return ("Could not load pull requests", (error as? RPCClientError)?.description ?? "\(error)")
    }
}

/// The thread's pull requests: the right panel's `pull-request` and `pull-requests` tabs, the
/// "Link pull request" dialog, unlinking and watching, the copy shortcuts.
@MainActor
final class ThreadPullRequestsController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    let capabilities: PullRequestCapabilities
    private let detail: PullRequestDetailBinding
    /// The open thread (nil on a draft).
    var openThreadId: () -> ThreadId? = { nil }
    private var modal: ModalHost?
    /// The open Link dialog; its fields talk to it weakly, so it is held here while it shows.
    private var linkDialog: LinkPullRequestDialog?

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.capabilities = capabilities
        detail = PullRequestDetailBinding(view: panel.pullRequestView, environments: environments, capabilities: capabilities)
        detail.toast = { [weak panel] title, message, kind in panel?.toasts.show(ToastView(title: title, message: message, kind: kind)) }
        detail.onStatus = { [weak self] id, tone in self?.panel.pullRequestStatus[id] = tone }
        panel.pullRequestView.context = .thread
        panel.pullRequestView.onLinkThread = { [weak self] in self?.toggleLinkFromPanel() }
        panel.onAddPullRequest = { [weak self] in self?.openCurrentPullRequest() }
        let list = panel.linkedPullRequestsView
        list.onOpen = { [weak self] link in self?.open(link) }
        list.onLink = { [weak self] in self?.openLinkDialog() }
        list.onUnlink = { [weak self] link in self?.unlink(link) }
        list.onCopy = { [weak self] url in self?.copy(url, title: "Link copied") }
        list.onOpenExternal = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        list.onWatch = { [weak self] link, watching in self?.watch(link, watching) }
    }

    private var thread: ThreadShell? {
        guard let id = openThreadId() else { return nil }
        return sidebar?.snapshot?.threads.first { $0.id == id }
    }

    private var project: ProjectShell? {
        guard let thread else { return nil }
        return sidebar?.snapshot?.projects.first { $0.id == thread.projectId }
    }

    /// The panel changed, the thread changed or its shell moved: availability, tab glyphs and the
    /// active surface's content.
    func sync() {
        guard let thread, let env = thread.id.environmentId else {
            panel.pullRequestAvailable = false
            panel.pullRequestsAvailable = false
            if cardKey != nil { cardKey = nil; panel.detailsCard.pullRequestRows = [] }
            detail.clear()
            return
        }
        let links = thread.pullRequests ?? []
        panel.pullRequestsAvailable = capabilities.has(env, "threadPullRequests") && !ThreadPullRequests.visible(links).isEmpty
        panel.pullRequestAvailable = capabilities.has(env, "pullRequests") && panelTarget(thread) != nil
        // Linked snapshots seed the tab glyphs (`resolvePullRequestTabLink`).
        var status = panel.pullRequestStatus
        for surface in panel.panelState.surfaces {
            guard let t = surface.pullRequest else { continue }
            if let link = links.first(where: { $0.number == t.number && $0.repository.lowercased() == t.repository.lowercased() }), let s = link.snapshot {
                status[surface.id] = PullRequestStateTone(state: s.state.rawValue, isDraft: s.isDraft)
            }
        }
        panel.pullRequestStatus = status
        updateCardRows(thread)
        guard panel.panelState.isOpen, let active = panel.panelState.active else { return }
        switch active {
        case .pullRequest(let target):
            let linked = links.contains { $0.number == target.number && $0.repository.lowercased() == target.repository.lowercased() }
            panel.pullRequestView.linkItemTitle = capabilities.has(env, "threadPullRequests") ? (linked ? "Unlink from this thread" : "Link to this thread") : nil
            detail.show(environmentId: target.environmentId ?? env, target: target)
        case .pullRequests:
            panel.linkedPullRequestsView.onWatch = capabilities.has(env, "threadPullRequestWatch") ? { [weak self] link, w in self?.watch(link, w) } : nil
            panel.linkedPullRequestsView.set(links, nowMs: TimestampFormat.nowMs())
        default:
            break
        }
    }

    /// Threads whose details card lists every link (`Show N more`).
    private var expandedCards: Set<ThreadId> = []
    private var cardKey: String?

    /// The details card's pull request rows (ThreadDetailsPrRows.tsx, ThreadDetailsPrRow.tsx): the
    /// current link as "#n: title" in its state's glyph and tone, then the rest of the thread's links
    /// while expanded. Each opens its pull request in the right panel.
    // ponytail: rows show the linked snapshot only; T3 reads the detail and checks for the second line
    // (checks, watch, Resolve/Ready/Fix/Merge). Add it when a server here can read a host
    private func updateCardRows(_ thread: ThreadShell) {
        let links = ThreadPullRequests.visible(thread.pullRequests ?? [])
        let current = ThreadPullRequests.current(links)
        let expanded = expandedCards.contains(thread.id)
        let key = "\(thread.id.rawValue)|\(expanded)|" + links.map { "\($0.key.id):\($0.snapshot?.state.rawValue ?? "-"):\($0.snapshot?.isDraft == true):\($0.snapshot?.title ?? "")" }.joined(separator: ",")
            + "|\(thread.linkedPullRequest?.url ?? "")"
        guard key != cardKey else { return }
        cardKey = key
        func row(number: Int, title: String?, state: PullRequestState?, isDraft: Bool, open: @escaping @MainActor @Sendable () -> Void) -> DetailsRowControl {
            let r = DetailsRowControl(kind: .row)
            let tone = state.map { PullRequestStateTone(state: $0.rawValue, isDraft: isDraft) }
            r.icons = [(tone.map(PullRequestStyle.icon) ?? .gitPullRequestArrow).definition]
            r.iconColor = tone.map(PullRequestStyle.color)
            r.text = "#\(number)" + (title.map { ": \($0)" } ?? "")
            r.setAccessibilityLabel(r.text)
            r.action = open
            return r
        }
        var rows: [DetailsRowControl] = []
        if let current {
            rows.append(row(number: current.number, title: current.snapshot?.title, state: current.snapshot?.state, isDraft: current.snapshot?.isDraft ?? false) { [weak self] in self?.open(current) })
            let rest = ThreadPullRequests.lines(links).map(\.link).filter { $0.key.id != current.key.id }
            if !rest.isEmpty {
                if expanded {
                    for link in rest {
                        rows.append(row(number: link.number, title: link.snapshot?.title, state: link.snapshot?.state, isDraft: link.snapshot?.isDraft ?? false) { [weak self] in self?.open(link) })
                    }
                }
                let toggle = DetailsRowControl(kind: .row)
                toggle.icons = [(expanded ? IconName.minus : .plus).definition]
                toggle.text = expanded ? "Show less" : "Show \(rest.count) more"
                toggle.action = { [weak self] in
                    guard let self else { return }
                    if self.expandedCards.contains(thread.id) { self.expandedCards.remove(thread.id) } else { self.expandedCards.insert(thread.id) }
                    self.sync()
                }
                rows.append(toggle)
            }
        } else if let legacy = thread.linkedPullRequest {
            rows.append(row(number: legacy.number, title: nil, state: nil, isDraft: false) { [weak self] in self?.openCurrentPullRequest() })
        }
        panel.detailsCard.pullRequestRows = rows
    }

    /// `threadPullRequestPanelTarget`: the current link, else the legacy link or the branch's PR.
    private func panelTarget(_ thread: ThreadShell) -> PullRequestSurfaceTarget? {
        let projectId = thread.projectId.localId.rawValue
        if let current = ThreadPullRequests.current(thread.pullRequests ?? []) {
            let projectForLink = ChangeRequestURL.parse(current.url).flatMap { link in
                sidebar?.snapshot?.projects.first { $0.id.environmentId == thread.id.environmentId && $0.repositoryIdentity?.owns(link) == true }
            }
            return PullRequestSurfaceTarget(projectId: projectForLink?.id.localId.rawValue ?? projectId, host: current.host,
                                            repository: current.repository, number: current.number, url: current.url)
        }
        if let legacy = thread.linkedPullRequest ?? thread.branchPullRequest {
            return PullRequestSurfaceTarget(projectId: legacy.projectId.rawValue, repository: legacy.repository, number: legacy.number, url: legacy.url)
        }
        return nil
    }

    /// "Pull request" from the + menu: the thread's current pull request.
    func openCurrentPullRequest() {
        guard let thread, let target = panelTarget(thread) else { return }
        panel.mutatePanel { $0.openPullRequest(target); return [] }
    }

    /// A linked pull request clicked: the panel when a project here reads its repository
    /// (`useOpenChangeRequestLink`), the browser otherwise.
    func open(_ link: ThreadPullRequestLink) {
        guard let thread, let env = thread.id.environmentId, capabilities.has(env, "pullRequests"),
              let parsed = ChangeRequestURL.parse(link.url) else {
            if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
            return
        }
        let projects = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }
        let project = projects.first { $0.repositoryIdentity?.owns(parsed) == true }
            ?? projects.first { $0.repositoryIdentity?.pullRequestHost == parsed.host }
            ?? self.project
        guard let project else { if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }; return }
        panel.mutatePanel {
            $0.openPullRequest(PullRequestSurfaceTarget(projectId: project.id.localId.rawValue, host: link.host, repository: link.repository,
                                                        number: link.number, url: link.url))
            return []
        }
    }

    /// The URL of the pull request the panel shows, for `thread.copyReference`.
    var openPanelPullRequestURL: String? {
        guard panel.panelState.isOpen, let target = panel.panelState.active?.pullRequest else { return nil }
        return detail.detail?.url ?? target.url
    }

    /// `resolveThreadReferenceCopyTarget` (shared/threadReference.ts:13-40).
    func copyReferenceTarget(threadId: String) -> (value: String, title: String) {
        let url = openPanelPullRequestURL ?? ThreadPullRequests.current(thread?.pullRequests ?? [])?.url ?? thread?.linkedPullRequest?.url
        return url.map { ($0, "PR link copied") } ?? (threadId, "Thread ID copied")
    }

    /// `pullRequest.copyNumber` while a pull request tab is active (PullRequestDetailPanel.tsx:745-760).
    func copyNumber() -> Bool {
        guard panel.window != nil, panel.panelState.isOpen, let target = panel.panelState.active?.pullRequest else { return false }
        copy("#\(target.number)", title: "PR number copied")
        return true
    }

    // MARK: Linking

    /// The detail's ⋯ "Link to this thread" / "Unlink from this thread".
    private func toggleLinkFromPanel() {
        guard let thread, let target = panel.panelState.active?.pullRequest, let d = detail.detail else { return }
        if let link = (thread.pullRequests ?? []).first(where: { $0.number == target.number && $0.repository.lowercased() == target.repository.lowercased() }) {
            unlink(link)
        } else if let parsed = ChangeRequestURL.parse(d.url) {
            change(thread: thread, resolved: LinkPullRequestLogic.Resolved(host: parsed.host, repository: parsed.repository, number: parsed.number, url: d.url), link: true) { _ in }
        }
    }

    /// "Link pull request to thread" (LinkPullRequestDialog.tsx).
    func openLinkDialog() {
        guard modal == nil, let thread, let env = thread.id.environmentId, let window = panel.window else { return }
        let multiple = capabilities.has(env, "threadPullRequests")
        guard multiple || capabilities.has(env, "threadPullRequestLinking") else {
            panel.toasts.show(ToastView(title: "Linking pull requests is not available on this server", kind: .error))
            return
        }
        var own: LinkPullRequestLogic.Project?
        if let identity = project?.repositoryIdentity, let host = identity.pullRequestHost,
           let repository = identity.displayName ?? identity.owner.flatMap({ o in identity.name.map { "\(o)/\($0)" } }) {
            own = LinkPullRequestLogic.Project(host: host, repository: repository, kind: identity.provider)
        }
        let projects = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }
        // `canLinkChangeRequest`: any link in `multiple` mode, a matching project in `single`.
        let canLink: (ChangeRequestURL.Link) -> Bool = { link in multiple || projects.contains { $0.repositoryIdentity?.owns(link) == true } }
        let dialog = LinkPullRequestDialog(project: own, canLink: canLink)
        let host = ModalHost.present(dialog.dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil; self?.linkDialog = nil }
        linkDialog = dialog
        modal = host
        dialog.cancel.action = { host.close() }
        dialog.onSubmit = { [weak self, weak dialog] resolved in
            guard let self, let dialog else { return }
            dialog.pending = true
            self.change(thread: thread, resolved: resolved, link: true) { error in
                dialog.pending = false
                if let error { dialog.submitError = error } else { host.close() }
            }
        }
        DispatchQueue.main.async { window.makeFirstResponder(dialog.input) }
    }

    /// `changeLink` (usePullRequestLinking.ts:84-111) through the command the server advertises.
    private func change(thread: ThreadShell, resolved: LinkPullRequestLogic.Resolved, link: Bool, done: @escaping (String?) -> Void) {
        guard let env = thread.id.environmentId else { return }
        let key = ThreadPullRequestKey(host: resolved.host, repository: resolved.repository, number: resolved.number).normalized
        let threadId = thread.id.localId.rawValue
        let payload: JSONValue
        if capabilities.has(env, "threadPullRequests") {
            payload = link ? PullRequestPayloads.link(threadId: threadId, key: key, url: resolved.url) : PullRequestPayloads.unlink(threadId: threadId, key: key)
        } else {
            let parsed = ChangeRequestURL.parse(resolved.url)
            let legacy = parsed.flatMap { p in (sidebar?.snapshot?.projects ?? []).first { $0.id.environmentId == env && $0.repositoryIdentity?.owns(p) == true } }
            guard !link || legacy != nil else { done("The pull request is not available in this environment."); return }
            payload = PullRequestPayloads.legacyLink(threadId: threadId, projectId: link ? legacy?.id.localId.rawValue : nil,
                                                     repository: legacy?.repositoryIdentity?.pullRequestRepository ?? resolved.repository,
                                                     number: resolved.number, url: resolved.url)
        }
        Task { [weak self] in
            do {
                _ = try await self?.environments.dispatch(thread.id, payload)
                done(nil)
            } catch {
                done((error as? RPCClientError)?.description ?? "Could not link the pull request.")
            }
        }
    }

    func unlink(_ link: ThreadPullRequestLink) {
        guard let thread else { return }
        change(thread: thread, resolved: LinkPullRequestLogic.Resolved(host: link.host, repository: link.repository, number: link.number, url: link.url),
               link: false) { [weak self] error in
            if let error { self?.panel.toasts.show(ToastView(title: "Could not unlink the pull request", message: error, kind: .error)) }
        }
    }

    /// `thread.pull-request.watch`.
    private func watch(_ link: ThreadPullRequestLink, _ watching: Bool) {
        guard let thread else { return }
        let payload = JSONValue.object(["type": .string("thread.pull-request.watch"), "commandId": .string(ThreadCommands.newCommandId()),
                                        "threadId": .string(thread.id.localId.rawValue), "host": .string(link.host),
                                        "repository": .string(link.repository), "number": .number(Double(link.number)),
                                        "watching": .bool(watching)])
        Task { [weak self] in
            do { _ = try await self?.environments.dispatch(thread.id, payload) } catch {
                self?.panel.toasts.show(ToastView(title: watching ? "Could not watch the pull request" : "Could not stop watching", kind: .error))
            }
        }
    }

    private func copy(_ text: String, title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        panel.toasts.show(ToastView(title: title, message: text, kind: .success))
    }

    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.on("pullRequest.copyNumber") { [weak self] call in
            guard let self else { return false }
            if call.isRepeat { return self.panel.panelState.active?.pullRequest != nil }
            return self.copyNumber()
        }
    }
}
