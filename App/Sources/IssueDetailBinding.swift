import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// One issue surface's reads and writes (4928 IssueDetailPanel.tsx, IssueThreadLinks.tsx):
/// `issues.detail`, older pages through `issues.comments`, `issues.setState`, `issues.update`,
/// `issues.comment`, `issues.react`, the label and assignee pickers' `issues.candidates`, the
/// linked threads' `issues.linkedThreads` and `thread.issue.link`/`unlink`. Drives an
/// `IssueDetailView`. Every write reads the detail again, as each confirmed write refreshes the
/// detail it touched (client-runtime state/issues.ts:158-164).
@MainActor
final class IssueDetailBinding {
    let surface: LazyView<IssueDetailView>
    var view: IssueDetailView { surface.view }
    private let environments: Environments
    private let capabilities: PullRequestCapabilities
    var toast: (String, String?, ToastQueue.Kind) -> Void = { _, _, _ in }
    /// The issue's state is known: the tab's glyph wears it.
    var onStatus: ((String, IssueState) -> Void)?
    /// A write landed: the page lists again (`refreshIssueLists`).
    var onChanged: (() -> Void)?
    /// A linked pull request pressed: open it beside the issue.
    var onOpenPullRequest: ((PullRequestSurfaceTarget) -> Void)?
    /// The linked-threads count pressed: the palette searches the issue's URL.
    var onSearchThreads: ((String) -> Void)?
    /// The thread the panel stands beside, scoped; nil on the Issues page.
    var threadId: ThreadId?
    /// The thread's linked issues, so the link button knows its state.
    var threadIssues: () -> [ThreadIssueLink] = { [] }
    /// On the Issues page, with no thread beside it: the shell to pick a thread from (IssueThreadLinks.tsx:168-171).
    var pickerSnapshot: (() -> ShellSnapshot?)?
    private var pickerHost: ModalHost?
    /// The workspace root of the reading project, for file links in Markdown.
    var cwd: (String, String) -> String? = { _, _ in nil }
    private(set) var environmentId: String?
    private(set) var target: IssueSurfaceTarget?
    private var seed: IssueListEntry?
    private var detail: IssueDetail?
    private var older: [IssueComment] = []
    private var olderCursor: String??
    private var loadingOlder = false
    private var refreshing = false
    private var refreshError: String?
    private var changingState = false
    private var saving = false
    private var linkedCount: Int?
    private var linkedFailed = false
    private var linkPending = false
    private var generation = 0
    private var picker: (view: PullRequestCandidatePickerView, popup: OpenPopup?)?

    init(surface: LazyView<IssueDetailView>, environments: Environments, capabilities: PullRequestCapabilities) {
        self.surface = surface
        self.environments = environments
        self.capabilities = capabilities
        surface.configure { [weak self] v in self?.wire(v) }
    }

    private func wire(_ v: IssueDetailView) {
        v.onRetry = { [weak self] in self?.reload() }
        v.onRefresh = { [weak self] in self?.reload(manual: true) }
        v.onOpenURL = { url in if let u = SafeExternalURL.parse(url) { NSWorkspace.shared.open(u) } }
        v.onSetState = { [weak self] s in self?.setState(s) }
        v.onSaveTitle = { [weak self] t in self?.update(title: t) }
        v.onSaveBody = { [weak self] b in self?.update(body: b) }
        v.onPickLabels = { [weak self] anchor in self?.pick(.issueLabels, from: anchor) }
        v.onPickAssignees = { [weak self] anchor in self?.pick(.issueAssignees, from: anchor) }
        v.onReact = { [weak self] id, content, reacted, bar in self?.react(id, content, reacted, bar) }
        v.onLoadOlder = { [weak self] in self?.loadOlder() }
        v.onComment = { [weak self] text in self?.comment(text) }
        v.onToggleLink = { [weak self] in self?.toggleLink() }
        v.onShowLinkedThreads = { [weak self] in if let url = self?.detail?.url { self?.onSearchThreads?(url) } }
        v.onOpenPullRequest = { [weak self] pr in
            guard let self, let t = self.target else { return }
            if let open = self.onOpenPullRequest {
                open(PullRequestSurfaceTarget(environmentId: self.environmentId, projectId: t.projectId, host: t.host,
                                              repository: pr.repository, number: pr.number, url: pr.url))
            } else if let u = SafeExternalURL.parse(pr.url) { NSWorkspace.shared.open(u) }
        }
    }

    func show(environmentId: String, target: IssueSurfaceTarget, seed: IssueListEntry? = nil) {
        if self.environmentId == environmentId, self.target?.surfaceId == target.surfaceId { render(); return }
        self.environmentId = environmentId
        self.target = target
        self.seed = seed
        detail = nil
        older = []
        olderCursor = nil
        refreshError = nil
        linkedCount = nil
        linkedFailed = false
        view.showLoading(seed: seed)
        reload()
    }

    /// `issues.detail`; a failed refresh keeps the issue and says why (#38537, #39000).
    func reload(manual: Bool = false) {
        guard let env = environmentId, let target else { return }
        generation += 1
        let gen = generation
        refreshing = true
        if detail != nil { render() }
        Task { [weak self] in
            do {
                let d = try await self?.environments.request(env, "issues.detail", .object(target.ref.json)).decode(as: IssueDetail.self)
                guard let self, self.generation == gen, let d else { return }
                // A successful read starts the older pages over (createIssueCommentPager.refresh).
                if self.detail?.commentsCursor != d.commentsCursor || manual { self.older = []; self.olderCursor = nil }
                self.detail = d
                self.refreshing = false
                self.refreshError = nil
                self.onStatus?(target.surfaceId, d.state)
                self.render()
                self.readLinkedThreads()
            } catch {
                guard let self, self.generation == gen else { return }
                self.refreshing = false
                let message = Self.message(error)
                if self.detail == nil { self.view.showFailure(message) } else { self.refreshError = message; self.render() }
            }
        }
    }

    private func render() {
        guard let d = detail, let env = environmentId else { return }
        var m = IssueDetailView.Model(detail: d, access: IssueListLogic.access(d, canWrite: true))
        m.comments = IssueListLogic.prepend(d.comments, older: older)
        m.nextCursor = olderCursor ?? d.commentsCursor
        m.loadingOlder = loadingOlder
        m.refreshing = refreshing
        m.refreshError = refreshError
        m.changingState = changingState
        m.saving = saving
        let key = ThreadIssueKey(tracker: d.tracker, host: d.host, scope: d.scope, key: d.key)
        if let threadId { m.linkedHere = threadIssues().contains { $0.issueKey.normalized == key.normalized } } else { m.linkedHere = nil }
        // The Issues page links through a thread picker; beside a thread the button toggles that thread.
        m.canLink = threadId == nil ? pickerSnapshot != nil : threadId?.environmentId == env
        m.linkPending = linkPending
        m.linkedThreadCount = linkedCount
        m.linkedThreadsFailed = linkedFailed
        m.cwd = cwd(env, d.projectId)
        m.nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        view.show(m)
    }

    // MARK: Writes

    private func write(_ method: String, _ payload: JSONValue, failure title: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard let env = environmentId else { return }
        Task { [weak self] in
            do {
                _ = try await self?.environments.request(env, method, payload)
                done(true)
                self?.onChanged?()
                self?.reload()
            } catch {
                done(false)
                self?.toast(title, Self.message(error, fallback: "The tracker refused it."), .error)
            }
        }
    }

    private func setState(_ state: String) {
        guard let ref = target?.ref, !changingState else { return }
        changingState = true
        render()
        write("issues.setState", IssueWrites.setState(ref, state: state), failure: "The state could not be changed") { [weak self] _ in
            self?.changingState = false
            self?.render()
        }
    }

    private func update(title: String? = nil, body: String? = nil) {
        guard let ref = target?.ref else { return }
        saving = true
        render()
        write("issues.update", IssueWrites.update(ref, title: title, body: body), failure: "The issue could not be updated") { [weak self] ok in
            guard let self else { return }
            self.saving = false
            if ok { if title != nil { self.view.finishTitleEdit() } else { self.view.finishBodyEdit() } }
            self.render()
        }
    }

    private func comment(_ text: String) {
        guard let ref = target?.ref else { return }
        write("issues.comment", IssueWrites.comment(ref, body: text), failure: "The comment could not be posted") { [weak self] ok in
            if ok { self?.view.commentPosted() } else { self?.view.commentFailed() }
        }
    }

    private func react(_ subjectId: String?, _ content: String, _ reacted: Bool, _ bar: PullRequestReactionBarView) {
        guard let env = environmentId, let ref = target?.ref else { return }
        Task { [weak self] in
            do {
                _ = try await self?.environments.request(env, "issues.react", IssueWrites.react(ref, subjectId: subjectId, content: content, reacted: reacted))
                self?.reload()
            } catch {
                bar.pressFailed(content)
                self?.toast("The reaction could not be changed", Self.message(error, fallback: "The tracker refused it."), .error)
            }
        }
    }

    /// "Load older comments" (`createIssueCommentPager.loadOlder`): pages walk backwards, in front.
    private func loadOlder() {
        guard let env = environmentId, let ref = target?.ref, let cursor = olderCursor ?? detail?.commentsCursor, !loadingOlder else { return }
        loadingOlder = true
        render()
        let gen = generation
        Task { [weak self] in
            do {
                let page = try await self?.environments.request(env, "issues.comments", IssueWrites.comments(ref, cursor: cursor)).decode(as: IssueCommentsPage.self)
                guard let self, let page, self.generation == gen else { self?.loadingOlder = false; return }
                self.older = IssueListLogic.prepend(self.older, older: page.comments)
                self.olderCursor = .some(page.nextCursor)
            } catch {
                self?.toast("Older comments could not be read", nil, .error)
            }
            self?.loadingOlder = false
            self?.render()
        }
    }

    // MARK: Pickers

    /// The label and assignee pickers (IssueDetailPanel.tsx:110-337): `issues.candidates` when one
    /// opens, then each press writes the whole set through `issues.update`.
    private func pick(_ kind: PullRequestCandidatePickerView.Kind, from anchor: NSView) {
        guard let env = environmentId, let ref = target?.ref, let d = detail else { return }
        let p = PullRequestCandidatePickerView(kind: kind)
        var candidates: IssueCandidates?
        var query = ""
        let labels = kind == .issueLabels
        let fill = { [weak p, weak self] in
            guard let p, let self, let d = self.detail else { return }
            let needle = query.lowercased()
            if labels {
                let applied = Set(d.labels.map(\.name))
                p.rows = (candidates?.labels ?? []).filter { needle.isEmpty || $0.name.lowercased().contains(needle) || ($0.description ?? "").lowercased().contains(needle) }
                    .map { .init(key: $0.name, title: $0.name, detail: $0.description, dot: $0.color.flatMap { PullRequestStyle.hex("#" + $0) }, checked: applied.contains($0.name)) }
            } else {
                let assigned = Set(d.assignees.map(\.login))
                p.rows = (candidates?.assignees ?? []).filter { needle.isEmpty || $0.login.lowercased().contains(needle) || ($0.name ?? "").lowercased().contains(needle) }
                    .map { .init(key: $0.login, title: $0.login, actor: $0.actor, checked: assigned.contains($0.login)) }
            }
        }
        p.onQuery = { q in query = q; fill() }
        p.onPick = { [weak self, weak p] key in
            guard let self, let d = self.detail else { return }
            p?.disabled = true
            let payload: JSONValue
            if labels {
                var names = d.labels.map(\.name)
                if let i = names.firstIndex(of: key) { names.remove(at: i) } else { names.append(key) }
                payload = IssueWrites.update(ref, labels: names)
            } else {
                // A write names people as the tracker addresses them (`IssueAssigneeCandidate.id`).
                let ids = { (login: String) in candidates?.assignees.first { $0.login == login }?.id ?? login }
                var logins = d.assignees.map(\.login)
                if let i = logins.firstIndex(of: key) { logins.remove(at: i) } else { logins.append(key) }
                payload = IssueWrites.update(ref, assignees: logins.map(ids))
            }
            self.write("issues.update", payload, failure: labels ? "Could not change labels" : "Could not change assignees") { [weak p] _ in p?.disabled = false }
        }
        let popup = p.present(from: anchor)
        picker = (p, popup)
        _ = d
        Task { [weak self, weak p] in
            do {
                candidates = try await self?.environments.request(env, "issues.candidates", ref.scopeRef.json).decode(as: IssueCandidates.self)
                p?.truncated = candidates?.truncated ?? false
                p?.state = .loaded
                fill()
            } catch {
                p?.state = .failed(Self.message(error))
            }
        }
    }

    // MARK: Thread links

    /// `issues.linkedThreads` where the server lists them (`issueLinkedThreads`); a failure shows "?".
    private func readLinkedThreads() {
        guard let env = environmentId, let d = detail, capabilities.has(env, "issueLinkedThreads") else { return }
        let key = ThreadIssueKey(tracker: d.tracker, host: d.host, scope: d.scope, key: d.key)
        Task { [weak self] in
            do {
                let r = try await self?.environments.request(env, "issues.linkedThreads", IssueWrites.key(key)).decode(as: IssueLinkedThreadsResult.self)
                self?.linkedCount = r?.threads.filter { $0.archivedAt == nil }.count
                self?.linkedFailed = false
            } catch {
                self?.linkedFailed = true
            }
            self?.render()
        }
    }

    /// `changeLink` (IssueThreadLinks.tsx:55-90) for the thread beside the panel.
    private func toggleLink() {
        if threadId == nil { openThreadPicker(); return }
        guard let threadId, let d = detail, let t = target, !linkPending else { return }
        let key = ThreadIssueKey(tracker: d.tracker, host: d.host, scope: d.scope, key: d.key)
        let linked = threadIssues().contains { $0.issueKey.normalized == key.normalized }
        let payload = linked ? IssueWrites.unlink(threadId: threadId.localId.rawValue, key: key)
            : IssueWrites.link(threadId: threadId.localId.rawValue, key: key, projectId: t.projectId, url: d.url, displayKey: d.displayKey, title: d.title)
        linkPending = true
        render()
        Task { [weak self] in
            do {
                _ = try await self?.environments.dispatch(threadId, payload)
                self?.readLinkedThreads()
            } catch {
                self?.toast(linked ? "Could not unlink the issue" : "Could not link the issue", Self.message(error, fallback: "The server refused it."), .error)
            }
            self?.linkPending = false
            self?.render()
        }
    }

    /// `ThreadLinkPicker` in a dialog (IssueThreadLinks.tsx:193-207): link the issue to a thread of its environment.
    private func openThreadPicker() {
        guard pickerHost == nil, let d = detail, let t = target, let env = environmentId, let window = view.window,
              let snapshot = pickerSnapshot?() else { return }
        let key = ThreadIssueKey(tracker: d.tracker, host: d.host, scope: d.scope, key: d.key)
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        // ponytail: lists threads the shell holds; T3 also mounts older settled title matches (useThreadSearch), add when asked
        let threads = snapshot.threads.filter { $0.id.environmentId == env && $0.archivedAt == nil }
            .sorted { ($0.updatedAt.epochMs ?? 0) > ($1.updatedAt.epochMs ?? 0) }
        let picker = ThreadLinkPicker(title: "Link issue to a thread")
        picker.candidates = threads.map { th in
            .init(id: th.id.localId.rawValue, title: th.title, project: projects[th.projectId],
                  linked: (th.issues?.values ?? []).contains { $0.issueKey.normalized == key.normalized })
        }
        let host = ModalHost.present(picker.dialog, in: window)
        pickerHost = host
        host.onDismiss = { [weak self] in self?.pickerHost = nil }
        picker.onSelect = { [weak self, weak picker] localId in
            guard let self, let picker, let thread = threads.first(where: { $0.id.localId.rawValue == localId }) else { return }
            picker.pending = true
            let payload = IssueWrites.link(threadId: localId, key: key, projectId: t.projectId, url: d.url, displayKey: d.displayKey, title: d.title)
            Task { [weak self] in
                do {
                    _ = try await self?.environments.dispatch(thread.id, payload)
                    host.close()
                    self?.readLinkedThreads()
                } catch {
                    picker.pending = false
                    self?.toast("Could not link the issue", Self.message(error, fallback: "The server refused it."), .error)
                }
            }
        }
        DispatchQueue.main.async { window.makeFirstResponder(picker.input) }
    }

    /// The thread's links changed (`thread.issue-synced`): the button follows.
    func threadChanged() { if detail != nil { render() } }

    nonisolated static func message(_ error: Error, fallback: String? = nil) -> String {
        if let e = error as? RPCClientError, let typed = e.typedError {
            return IssueFailure.message(tag: typed.tag, fields: typed.fields) ?? typed.message ?? typed.tag
        }
        if let e = error as? RPCClientError { return e.description }
        return fallback ?? "\(error)"
    }
}
