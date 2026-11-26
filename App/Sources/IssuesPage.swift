import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The Issues page (4928 apps/web/src/components/issue/IssuesPage.tsx): `issues.list` on every
/// connected environment with the `issues` capability, held with their continuation pages,
/// grouped per tracker account; the filters, sort, saved views and tracker menu; the issues and
/// pull requests opened from it in the page's own right panel.
@MainActor
final class IssuesPageController {
    let container = IssuesPageContainer()
    private var page: IssuesPageView { container.page }
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let capabilities: PullRequestCapabilities
    private let detail: IssueDetailBinding
    private let pullRequest: PullRequestDetailBinding
    /// The linked-threads count pressed: the palette searches for the issue's URL.
    var onSearchThreads: ((String) -> Void)?

    // The route's search params (`IssuesSearch`), remembered as `issueListPreferences`.
    private var query = ""
    private var sentQuery = ""
    private var state = "open"
    private var involvement = "all"
    private var sort = "updated"
    private var host: String?
    /// `environmentId:projectId` keys left out of the list (5258 `hideProjects`, 9fde959ac0 #38799).
    private var hiddenProjects: [String] = []
    private var labels: [String] = []
    private var assignee: String?

    private var pages: [String: IssueListLogic.HeldPage] = [:]
    private var failures: [String: String] = [:]
    private var loading = false
    private var loadingMore: String?
    private var generation = 0
    /// Hosts still answering the current generation's `issues.list`; `loading` clears at zero.
    private var pendingLoads = 0
    private var searchTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var readConnections: [String: Int] = [:]
    private var visible = false
    private var candidates: (labels: [IssueCandidates.Label], people: [PullRequestActor], loading: Bool, failed: Bool, truncated: Bool) = ([], [], false, false, false)
    private var candidatesKey: String?

    static let prefsKey = "t3.issues.preferences"

    init(sidebar: SidebarContentView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.sidebar = sidebar
        self.environments = environments
        self.capabilities = capabilities
        detail = IssueDetailBinding(surface: container.lazyIssue, environments: environments, capabilities: capabilities)
        pullRequest = PullRequestDetailBinding(surface: container.lazyPullRequest, environments: environments, capabilities: capabilities)
        apply(UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: Any] ?? [:])
        readConnections = environments.connectedGenerations
        _ = environments.observe { [weak self] in
            guard let self else { return }
            let connected = self.environments.connectedGenerations
            let reconnected = connected.contains { self.readConnections[$0.key] != $0.value }
            self.readConnections = connected
            if reconnected, self.visible { self.reload() }
        }
        detail.toast = { [weak self] t, m, k in self?.toast(t, m, k) }
        pullRequest.toast = { [weak self] t, m, k in self?.toast(t, m, k) }
        detail.onStatus = { [weak self] id, s in self?.container.issueStatus[id] = s }
        pullRequest.onStatus = { [weak self] id, tone in self?.container.pullRequestStatus[id] = tone }
        detail.onChanged = { [weak self] in self?.reload(keepRows: true) }
        detail.onOpenPullRequest = { [weak self] target in self?.container.mutate { $0.openPullRequest(target) } }
        // A pull request link in an issue opens beside it on this page when a project here reads it
        // (`PullRequestMarkdownPanelContext`, 5258 IssuesPage.tsx, openPullRequestLink.ts, #39937).
        detail.openURL = { [weak self] url in
            let modified = NSApp.currentEvent.map { $0.modifierFlags.contains(.command) || $0.modifierFlags.contains(.control) || $0.buttonNumber == 2 } ?? false
            guard let self, !modified, ClientSettingsStore.shared.current.bool("pullRequestLinksOpenInApp"),
                  let env = self.detail.environmentId else { NSWorkspace.shared.open(url); return }
            let projects = (self.sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }
                .map { (id: $0.id.localId.rawValue, identity: $0.repositoryIdentity) }
            guard var ref = PullRequestWriteLogic.previewTarget(url: url.absoluteString, pullRequestsEnabled: self.capabilities.has(env, "pullRequests"),
                                                               projects: projects) else { NSWorkspace.shared.open(url); return }
            if !self.capabilities.has(env, "threadPullRequests") { ref.host = nil }
            self.container.mutate { $0.openPullRequest(PullRequestSurfaceTarget(environmentId: env, projectId: ref.projectId, host: ref.host,
                                                                               repository: ref.repository, number: ref.number, url: url.absoluteString)) }
        }
        detail.onSearchThreads = { [weak self] url in self?.onSearchThreads?(url) }
        detail.pickerSnapshot = { [weak self] in self?.sidebar?.snapshot }
        detail.cwd = { [weak self] env, projectId in
            self?.sidebar?.snapshot?.projects.first { $0.id.environmentId == env && $0.id.localId.rawValue == projectId }?.workspaceRoot
        }
        container.onPanelChange = { [weak self] _ in self?.syncPanel() }
        wire()
    }

    private func wire() {
        page.onQuery = { [weak self] text in self?.typed(text) }
        page.onQuerySubmit = { [weak self] text in self?.submit(text) }
        page.onSort = { [weak self] v in self?.sort = v; self?.changed() }
        page.onState = { [weak self] v in self?.state = v; self?.changed() }
        page.onInvolvement = { [weak self] v in self?.involvement = v; self?.changed() }
        page.onHost = { [weak self] v in self?.host = v; self?.changed() }
        page.onHiddenProjects = { [weak self] v in self?.hiddenProjects = v; self?.candidatesKey = nil; self?.changed() }
        page.onLabels = { [weak self] v in self?.labels = v; self?.changed() }
        page.onAssignee = { [weak self] v in self?.assignee = v; self?.changed() }
        page.onFiltersOpen = { [weak self] in self?.readCandidates() }
        page.onRefresh = { [weak self] in self?.reload(keepRows: true, refresh: true) }
        page.onRetry = { [weak self] in self?.reload(keepRows: true) }
        page.onLoadMore = { [weak self] env, host in self?.loadMore(env, host) }
        page.onSelect = { [weak self] row in self?.select(row) }
        page.onTogglePanel = { [weak self] in self?.togglePanel() }
        page.views.onApply = { [weak self] p in self?.apply(p.mapValues(\.anyValue)); self?.changed() }
    }

    // MARK: Preferences

    private var preferences: [String: Any] {
        var p: [String: Any] = ["who": involvement, "status": state]
        if !hiddenProjects.isEmpty { p["hideProjects"] = Array(hiddenProjects.prefix(IssueListInput.maxExcludedProjects)) }
        if let host { p["host"] = host }
        if !sentQuery.isEmpty { p["q"] = sentQuery }
        if !labels.isEmpty { p["label"] = labels }
        if let assignee { p["assignee"] = assignee }
        if sort == "created" { p["order"] = "created" }
        return p
    }

    /// `issueListPreferences` read back, with every absent control cleared (a saved view's explicit clears).
    private func apply(_ p: [String: Any]) {
        let who = p["who"] as? String
        involvement = ["assigned", "authored", "mentioned"].contains(who ?? "") ? who! : "all"
        let status = p["status"] as? String
        state = status == "closed" || status == "all" ? status! : "open"
        hiddenProjects = Array((p["hideProjects"] as? [String] ?? []).filter { EnvironmentScope.split($0) != nil }.prefix(IssueListInput.maxExcludedProjects))
        host = (p["host"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        sentQuery = String((p["q"] as? String ?? "").prefix(200))
        query = sentQuery
        page.search.input.text = sentQuery
        labels = Array((p["label"] as? [String] ?? []).prefix(20))
        assignee = p["assignee"] as? String
        sort = p["order"] as? String == "created" ? "created" : "updated"
    }

    private func changed() {
        UserDefaults.standard.set(preferences, forKey: Self.prefsKey)
        reload()
    }

    private func typed(_ text: String) {
        query = text
        render()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: IssueListLogic.searchDebounce)
            guard !Task.isCancelled else { return }
            self?.submit(text)
        }
    }

    private func submit(_ text: String) {
        searchTask?.cancel(); searchTask = nil
        query = text
        sentQuery = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        changed()
    }

    // MARK: Visibility

    func didShow() {
        if visible { didHide() }
        visible = true
        reload()
        syncLiveTimer()
        // `useLiveRefresh` stops while the window is hidden and refreshes once on return.
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            let source = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.visible, let window = self.page.window, source == ObjectIdentifier(window) else { return }
                let wasLive = self.liveTimer != nil
                self.syncLiveTimer()
                if !wasLive, self.liveTimer != nil { self.reload(keepRows: true) }
            }
        }
        // Mod+F focuses the search; `rightPanel.toggle`, as the keybindings bind it, toggles the panel
        // (IssuesPage.tsx:453, #38309).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.visible, self.page.window?.isKeyWindow == true else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, event.charactersIgnoringModifiers == "f" { self.page.focusSearch(); return nil }
            let command = ActiveKeymap.resolve(event, context: KeybindingContext())
            if command == "rightPanel.toggle" {
                if !event.isARepeat { self.togglePanel() }
                return nil
            }
            // `rightPanel.close` closes the active tab; with the panel shut the key keeps its native meaning
            // (#42417, IssuesPage.tsx:487-497 at 5258).
            if command == "rightPanel.close", self.container.panelState.isOpen, let id = self.container.panelState.activeSurfaceId {
                if !event.isARepeat { self.container.mutate { $0.close(id) } }
                return nil
            }
            return event
        }
    }

    func didHide() {
        visible = false
        liveTimer?.invalidate(); liveTimer = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private var windowVisible: Bool { visible && page.window?.occlusionState.contains(.visible) == true }

    /// `useLiveRefresh`: every five minutes while the page is in front of a visible window.
    private func syncLiveTimer() {
        guard windowVisible else { liveTimer?.invalidate(); liveTimer = nil; return }
        guard liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: IssueListLogic.liveRefreshInterval, repeats: true) { [weak self] _ in
            // A list still loading is never restarted (IssuesPage.tsx:230-236).
            MainActor.assumeIsolated { if self?.loading == false { self?.reload(keepRows: true) } }
        }
        liveTimer?.tolerance = 30
    }

    // MARK: Environments

    /// Connected environments with the `issues` capability (`capableEnvironments`).
    var capableEnvironments: [String] {
        let ids = Set((sidebar?.snapshot?.projects ?? []).compactMap { $0.id.environmentId }).union([environments.primaryId].compactMap { $0 })
        return ids.filter { environments.session($0) != nil && capabilities.has($0, "issues") }.sorted()
    }

    /// `useIssuesSupported`: the sidebar and palette offer Issues only then.
    var supported: Bool { !capableEnvironments.isEmpty }

    /// `issueFilterProjects`: scratch projects stay, since Settings can bind one to a Linear team
    /// (5258 issuesSearch.logic.ts:56-67, 9fde959ac0 #38799).
    private var projects: [ProjectShell] {
        let envs = Set(capableEnvironments)
        return (sidebar?.snapshot?.projects ?? []).filter { p in p.id.environmentId.map(envs.contains) ?? false }
    }

    private var hiddenSet: Set<String> { Set(hiddenProjects) }

    /// `everyProjectHidden` (IssuesPage.tsx:223-225).
    private var everyProjectHidden: Bool { !projects.isEmpty && projects.allSatisfy { hiddenSet.contains($0.id.rawValue) } }

    private var targets: [(environmentId: String, excludeProjectIds: [String])] {
        guard !everyProjectHidden else { return [] }
        return IssueListLogic.listTargets(environments: capableEnvironments,
                                          projects: projects.compactMap { p in p.id.environmentId.map { ($0, p.id.localId.rawValue) } },
                                          hidden: hiddenSet)
    }

    private func input(_ env: String, cursors: [String: String]? = nil, refresh: Bool = false) -> IssueListInput {
        var i = IssueListInput()
        i.state = state
        i.involvement = involvement
        i.limit = IssueListLogic.pageSize
        i.excludeProjectIds = targets.first { $0.environmentId == env }?.excludeProjectIds
        i.host = host
        i.query = sentQuery.isEmpty ? nil : sentQuery
        i.labels = labels
        i.assignee = assignee
        i.sort = sort == "created" ? "created" : nil
        i.cursors = cursors
        i.refresh = refresh
        return i
    }

    // MARK: Loading

    func reload(keepRows: Bool = false, refresh: Bool = false) {
        guard visible else { return }
        generation += 1
        let gen = generation
        if !keepRows { pages = [:]; failures = [:] }
        for env in Set((sidebar?.snapshot?.projects ?? []).compactMap { $0.id.environmentId }) where !capabilities.known(env) { capabilities.load(env) }
        let envs = targets.map(\.environmentId)
        guard !envs.isEmpty else { loading = false; render(); return }
        loading = true
        render()
        // One main-actor task per host instead of a task group. Swift 6.3's region-based isolation
        // checker gives up on a @MainActor addTask that captures self, and the build fails.
        pendingLoads = envs.count
        let environments = self.environments
        for env in envs {
            let payload = input(env, refresh: refresh).json
            Task { [weak self] in
                let result: Result<IssueListResult, Error>
                do { result = .success(try await environments.request(env, "issues.list", payload).decode(as: IssueListResult.self)) }
                catch { result = .failure(error) }
                guard let self, self.generation == gen else { return }
                switch result {
                case .success(let r): self.pages[env] = IssueListLogic.HeldPage(answer: r); self.failures[env] = nil
                case .failure(let e): self.failures[env] = IssueDetailBinding.message(e)
                }
                self.pendingLoads -= 1
                if self.pendingLoads == 0 { self.loading = false }
                self.render()
            }
        }
    }

    /// One tracker group's "Load more" carries on that host's scopes only (IssuesPage.tsx:244-277).
    private func loadMore(_ env: String, _ host: String) {
        guard let page = pages[env], loadingMore == nil else { return }
        let asked = IssueListLogic.cursors(page.nextCursors, host: host)
        guard !asked.isEmpty else { return }
        loadingMore = "\(env) \(host)"
        render()
        let gen = generation
        let payload = input(env, cursors: asked).json
        Task { [weak self] in
            guard let self else { return }
            let next: IssueListLogic.PageResult
            do { next = .page(try await self.environments.request(env, "issues.list", payload).decode(as: IssueListResult.self)) }
            catch { next = .failure((error as? RPCClientError) == nil ? "The next page failed." : IssueDetailBinding.message(error)) }
            self.loadingMore = nil
            if self.generation == gen, let held = self.pages[env] { self.pages[env] = IssueListLogic.continuePage(held, next, asked: asked) }
            self.render()
        }
    }

    /// The Filters menu's labels and people: `issues.candidates` for each scope once per scope set.
    private func readCandidates() {
        let scopes = filterScopes()
        let key = scopes.map { "\($0.0) \($0.1.scope)" }.joined(separator: ",")
        guard key != candidatesKey else { return }
        candidatesKey = key
        candidates = ([], [], !scopes.isEmpty, false, false)
        render()
        Task { [weak self] in
            var labels: [IssueCandidates.Label] = [], people: [PullRequestActor] = [], failed = false, truncated = false
            for (env, scope) in scopes {
                guard let self else { return }
                do {
                    let c = try await self.environments.request(env, "issues.candidates", scope.json).decode(as: IssueCandidates.self)
                    labels += c.labels.filter { l in !labels.contains { $0.name == l.name } }
                    people += c.assignees.map(\.actor).filter { a in !people.contains { $0.login == a.login } }
                    truncated = truncated || c.truncated
                } catch { failed = true }
            }
            self?.candidates = (labels, people, false, failed && labels.isEmpty && people.isEmpty, truncated)
            self?.render()
            // A menu already open keeps its rows; the next open shows these.
        }
    }

    /// `issueFilterScopes` (issueList.ts:182-230) from what the answers name.
    private func filterScopes() -> [(String, IssueScopeRef)] {
        let hidden = hiddenSet
        var out: [(String, IssueScopeRef)] = []
        for (env, held) in pages.sorted(by: { $0.key < $1.key }) {
            let page = IssueListLogic.dropHidden(held, environmentId: env, hidden: hidden)
            let covered = page.answer.scopes ?? page.entries.map { IssueScopeRef(projectId: $0.projectId, tracker: $0.tracker, host: $0.host, scope: $0.scope) }
            for scope in covered {
                let t = page.answer.trackers.first { $0.tracker == scope.tracker && $0.host.lowercased() == scope.host?.lowercased() }
                guard let t, t.configured, t.capabilities?.labels == true || t.capabilities?.assignees == true else { continue }
                if out.contains(where: { $0.1.scope.lowercased() == scope.scope.lowercased() && $0.1.host?.lowercased() == scope.host?.lowercased() }) { continue }
                out.append((env, scope))
            }
        }
        return out
    }

    // MARK: Render

    private func render() {
        var m = IssuesPageView.Model()
        m.state = state; m.involvement = involvement; m.sort = sort; m.host = host
        m.hiddenProjects = hiddenProjects; m.labels = labels; m.assignee = assignee
        m.query = sentQuery
        m.searchBusy = query.trimmingCharacters(in: .whitespacesAndNewlines) != sentQuery || (!sentQuery.isEmpty && loading)
        m.refreshing = loading
        m.projects = projects.map { IssuesPageView.ProjectOption(key: $0.id.rawValue, title: $0.title, icon: ProjectIconSource($0)) }
        m.labelCandidates = candidates.labels
        m.assigneeCandidates = candidates.people
        m.candidatesLoading = candidates.loading
        m.candidatesFailed = candidates.failed
        m.candidatesTruncated = candidates.truncated
        let envs = capableEnvironments
        let held = envs.compactMap { env in pages[env].map { (env, $0) } }
        let hidden = hiddenSet
        // The server names every tracker so the menu can switch hosts, but reads only the chosen one.
        let chosen = host?.lowercased()
        let shown = held.map { env, p -> (String, IssueListLogic.HeldPage) in
            var p = IssueListLogic.dropHidden(p, environmentId: env, hidden: hidden)
            guard let chosen else { return (env, p) }
            p.answer.trackers = p.answer.trackers.filter { $0.host.lowercased() == chosen }
            return (env, p)
        }
        let projectsById = Dictionary((sidebar?.snapshot?.projects ?? []).map { ("\($0.id.environmentId ?? "") \($0.id.localId.rawValue)", $0) }, uniquingKeysWith: { a, _ in a })
        m.groups = IssueListLogic.group(shown, query: sentQuery, sort: sort) { env, projectId in
            guard let id = projectsById["\(env) \(projectId)"]?.repositoryIdentity, let kind = id.provider, let h = id.pullRequestHost else { return nil }
            return "\(kind) \(h.lowercased())"
        }
        m.hostOptions = IssueListLogic.hostOptions(held.flatMap(\.1.answer.trackers), chosen: host)
        m.moreFailures = Dictionary(uniqueKeysWithValues: held.compactMap { env, p in p.moreFailure.map { (env, $0) } })
        m.loadingMore = loadingMore
        if envs.count > 1 {
            m.environmentLabels = Dictionary(uniqueKeysWithValues: envs.map { ($0, environments.label($0) ?? $0) })
        }
        let failure = failures.values.sorted().first
        if !capabilityKnown && envs.isEmpty {
            m.body = .ghost
        } else if envs.isEmpty {
            m.body = .unsupported
        } else if everyProjectHidden {
            m.body = .everyProjectHidden
        } else if held.isEmpty && loading {
            m.body = .ghost
        } else if held.isEmpty, let failure {
            m.body = .unavailable(message: failure, retrying: loading)
        } else if m.groups.isEmpty {
            m.body = .noTrackers
        } else {
            m.body = .list
            m.errorBanner = failure
        }
        if let active = container.panelState.active?.issue, container.panelState.isOpen {
            m.selectedKey = "\(active.environmentId ?? "")\u{0}\(active.projectId)\u{0}\((active.host ?? "").lowercased())\u{0}\(active.scope.lowercased())\u{0}\(active.key)"
        }
        m.panelOpen = container.panelState.isOpen
        m.panelAvailable = container.panelState.active != nil
        m.nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        page.model = m
    }

    private var capabilityKnown: Bool {
        let ids = Set((sidebar?.snapshot?.projects ?? []).compactMap { $0.id.environmentId })
        return ids.isEmpty ? environments.primaryId.map(capabilities.known) ?? false : ids.contains(where: capabilities.known)
    }

    // MARK: Panel

    private func select(_ row: IssueListLogic.Row) {
        let e = row.entry
        let target = IssueSurfaceTarget(environmentId: row.environmentId, projectId: e.projectId, tracker: e.tracker, host: e.host,
                                        scope: e.scope, key: e.key, url: e.url)
        container.issueStatus[target.surfaceId] = e.state
        seeds[target.surfaceId] = e
        container.mutate { $0.openIssue(target) }
    }

    private var seeds: [String: IssueListEntry] = [:]

    /// `toggleRightPanel` (IssuesPage.tsx:441-451): nothing to show, nothing happens.
    private func togglePanel() {
        if container.panelState.isOpen { container.mutate { $0.isOpen = false } }
        else if container.panelState.active != nil { container.mutate { $0.isOpen = true } }
    }

    private func syncPanel() {
        let state = container.panelState
        guard state.isOpen, let active = state.active else { render(); return }
        if let t = active.issue, let env = t.environmentId ?? capableEnvironments.first {
            detail.show(environmentId: env, target: t, seed: seeds[t.surfaceId])
        } else if let t = active.pullRequest, let env = t.environmentId ?? capableEnvironments.first {
            pullRequest.show(environmentId: env, target: t)
        }
        render()
    }

    private func toast(_ title: String, _ message: String?, _ kind: ToastQueue.Kind) {
        _ = container.toasts.show(ToastView(title: title, message: message, kind: kind))
    }
}

private extension JSONValue {
    /// A saved view's preference as the controller's plain values.
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .array(let a): return a.compactMap(\.stringValue)
        case .bool(let b): return b
        case .number(let n): return n
        default: return ""
        }
    }
}
