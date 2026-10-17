import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The Pull Requests page (routes/_chat.pull-requests.tsx): `pullRequests.list` on every connected
/// environment that can list them, merged and grouped; the filters and sort; the selected pull
/// requests in the page's own right panel. Ports the route's reads at one page per question
/// (`PAGE_SIZE` 99, "Load more" grows it), without the cross-reload snapshot.
// ponytail: no per-scope answer cache; a refresh or filter change reads the page again. Add the
// stored snapshot when reopening the page feels slow
@MainActor
final class PullRequestsPageController {
    let container = PullRequestsPageContainer()
    private var page: PullRequestsPageView { container.page }
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let capabilities: PullRequestCapabilities
    private let detail: PullRequestDetailBinding
    /// "Add project" in the empty state.
    var onAddProject: (() -> Void)?

    // The route's search params.
    private var query = ""
    private var sentQuery = ""
    private var sort: String
    private var state: String
    private var involvement: String
    private var host: String?
    private var projectKey: String?
    private var menuFilters = PullRequestListFilters()
    private var pageSize = PullRequestListLogic.pageSize
    /// Where each environment's listing carries on (`nextCursors` per environment) and the ones
    /// truncated without a cursor (routes/_chat.pull-requests.tsx:690-760, 1175-1197).
    private var envCursors: [String: [String: String]] = [:]
    private var truncatedEnvs: [String] = []

    // Answers.
    private struct Answer {
        var result = PullRequestListResult()
        var authored: [PullRequestListEntry]?
        var reviewing: [PullRequestListEntry]?
    }
    private var answer: Answer?
    private var error: String?
    private var loading = false
    private var refreshing = false
    private var hosts: [PullRequestProviderSummary] = []
    private var stats: [String: (Int, Int)] = [:]
    private var overrides: [String: PullRequestListLogic.Override] = [:]
    private var overrideToken = 0
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var monitors: [Any] = []
    private var activeObserver: NSObjectProtocol?
    private var speedMode = false
    private var visible = false

    static let prefsKey = "pullRequests.listPreferences.v1"

    init(sidebar: SidebarContentView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.sidebar = sidebar
        self.environments = environments
        self.capabilities = capabilities
        // `pullRequestListPreferences`: the last list scope the reader chose.
        let prefs = UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String] ?? [:]
        sort = prefs["sort"] ?? "ready"
        state = prefs["state"] ?? "open"
        involvement = prefs["involvement"] ?? "all"
        detail = PullRequestDetailBinding(surface: container.lazyDetail, environments: environments, capabilities: capabilities)
        detail.toast = { [weak self] title, message, kind in self?.toast(title, message, kind) }
        detail.onStatus = { [weak self] id, tone in self?.container.pullRequestStatus[id] = tone }
        detail.onActed = { [weak self] action in
            guard let self, let target = self.detail.target, let entry = self.entry(for: target) else { self?.reload(); return }
            if action != "merge", let o = PullRequestListLogic.override(after: action, entry: entry, now: Date(), token: self.nextToken()) {
                self.overrides[PullRequestListLogic.key(entry)] = o
            }
            self.reload()
        }
        container.onPanelChange = { [weak self] _ in self?.syncDetail() }
        wirePage()
    }

    private func nextToken() -> Int { overrideToken += 1; return overrideToken }

    private func wirePage() {
        page.onQuery = { [weak self] text in self?.typed(text) }
        page.onSort = { [weak self] v in self?.sort = v; self?.savePrefs(); self?.render() }
        page.onState = { [weak self] v in self?.state = v; self?.savePrefs(); self?.reload() }
        page.onInvolvement = { [weak self] v in self?.involvement = v; self?.savePrefs(); self?.reload() }
        page.onHost = { [weak self] v in self?.host = v; self?.reload() }
        page.onProject = { [weak self] v in self?.projectKey = v; self?.reload() }
        page.onFilters = { [weak self] f in self?.menuFilters = f; self?.reload() }
        page.onRefresh = { [weak self] in self?.refreshFromHost() }
        page.onRetry = { [weak self] in self?.reload() }
        page.onLoadMore = { [weak self] in self?.loadMore() }
        page.onShowChecks = { [weak self] entry, anchor in self?.showChecks(entry, from: anchor) }
        page.onShowStack = { [weak self] entry, anchor in self?.showStack(entry, from: anchor) }
        page.onAddProject = { [weak self] in self?.onAddProject?() }
        page.onSelect = { [weak self] entry in self?.select(entry) }
        page.onSpeedAction = { [weak self] entry, action in self?.speedAction(entry, action) }
        page.onCopyLink = { [weak self] url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            self?.toast("Link copied", url, .success)
        }
        page.onOpenURL = { url in if let u = SafeExternalURL.parse(url) { NSWorkspace.shared.open(u) } }
    }

    private func savePrefs() {
        UserDefaults.standard.set(["sort": sort, "state": state, "involvement": involvement], forKey: Self.prefsKey)
    }

    // MARK: Visibility

    func didShow() {
        // Opening the page while it is already in front calls this again; drop the old monitors first.
        if visible { didHide() }
        visible = true
        reload()
        // `useLiveRefresh`: once a minute while the page is in front, and on the way back to the window.
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(keepRows: true, periodic: true) }
        }
        liveTimer?.tolerance = 6
        let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let m = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self?.setSpeedMode(m.contains(.shift) && !m.contains(.command) && !m.contains(.control) && !m.contains(.option))
            return event
        }
        // Mod+F belongs to the page's search (`PullRequestsColumn`).
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.visible, self.page.window?.isKeyWindow == true,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "f" else { return event }
            self.page.focusSearch()
            return nil
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.visible == true { self?.reload(keepRows: true, periodic: true) } }
        }
        monitors = [flags, keys].compactMap { $0 }
    }

    func didHide() {
        visible = false
        liveTimer?.invalidate()
        liveTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        setSpeedMode(false)
    }

    private func setSpeedMode(_ on: Bool) {
        guard on != speedMode else { return }
        speedMode = on
        render()
    }

    // MARK: Environments and projects

    /// Connected environments that can list pull requests, sorted.
    private var capableEnvironments: [String] {
        let ids = Set((sidebar?.snapshot?.projects ?? []).compactMap { $0.id.environmentId }).union([environments.primaryId].compactMap { $0 })
        return ids.filter { environments.session($0) != nil && capabilities.has($0, "pullRequests") }.sorted()
    }

    private var capabilityKnown: Bool {
        let ids = Set((sidebar?.snapshot?.projects ?? []).compactMap { $0.id.environmentId })
        return ids.isEmpty ? environments.primaryId.map(capabilities.known) ?? false : ids.contains(where: capabilities.known)
    }

    private var projects: [ProjectShell] {
        let envs = Set(capableEnvironments)
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: sidebar?.snapshot, primaryEnvironmentId: environments.primaryId,
            order: SidebarModel.SortOrder(rawValue: ClientSettingsStore.shared.current.string("sidebarProjectSortOrder")) ?? .updatedAt)
        return groups.flatMap(\.members).filter { project in
            guard let env = project.id.environmentId, envs.contains(env) else { return false }
            let scratch = sidebar?.state.scratchRoots[env]
            return scratch == nil || SidebarModel.normalizeProjectPath(project.workspaceRoot) != scratch
        }
    }

    private func scopedProject() -> (env: String, projectId: String)? {
        guard let key = projectKey, let env = EnvironmentScope.environmentId(of: key) else { return nil }
        return (env, EnvironmentScope.localId(of: key))
    }

    // MARK: Loading

    private func typed(_ text: String) {
        query = text
        render()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: PullRequestListLogic.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.sentQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.pageSize = PullRequestListLogic.pageSize
            self.reload(keepRows: true)
        }
    }

    /// `refreshFromHost`: `pullRequests.invalidate` on every environment read, then the list.
    private func refreshFromHost() {
        refreshing = true
        render()
        let envs = capableEnvironments
        Task { [weak self] in
            guard let self else { return }
            for env in envs { _ = try? await self.environments.request(env, "pullRequests.invalidate", .object([:])) }
            self.refreshing = false
            self.reload(keepRows: true)
            self.detail.reload(invalidate: false)
        }
    }

    func reload(keepRows: Bool = false, periodic: Bool = false) {
        // Final rows stay cached on timed refreshes. An explicit refresh still reads the host.
        if periodic, PullRequestListLogic.periodicRefreshState(state) == nil { return }
        guard visible else { return }
        generation += 1
        let gen = generation
        if !keepRows { answer = nil; error = nil }
        let envs = capableEnvironments
        for env in Set((sidebar?.snapshot?.projects ?? []).compactMap { $0.id.environmentId }) where !capabilities.known(env) { capabilities.load(env) }
        guard !envs.isEmpty else { loading = false; render(); return }
        loading = true
        render()
        let parsed = PullRequestListLogic.parseQuery(sentQuery)
        let filters = menuFilters.merging(parsed.filters)
        let scoped = scopedProject()
        let wantsPartitions = involvement == "all" && sentQuery.isEmpty
        let previousOpen = periodic && self.state == "all" ? (answer?.result.entries ?? []).filter { $0.state == "open" } : []
        let cachedFinal = periodic ? (answer?.result.entries ?? []).filter { $0.state == "closed" || $0.state == "merged" } : []
        let (state, involvement, host, pageSize) = (periodic ? (PullRequestListLogic.periodicRefreshState(self.state) ?? self.state) : self.state, self.involvement, self.host, self.pageSize)
        let targets = envs.filter { scoped == nil || scoped?.env == $0 }
        Task { [weak self] in
            guard let self else { return }
            var merged = PullRequestListResult()
            var authored: [PullRequestListEntry]? = wantsPartitions ? [] : nil
            var reviewing: [PullRequestListEntry]? = wantsPartitions ? [] : nil
            var failure: String?
            var cursors: [String: [String: String]] = [:]
            var truncated: [String] = []
            for env in targets {
                func read(_ inv: String, _ filters: PullRequestListFilters, _ text: String?) async throws -> PullRequestListResult {
                    let input = PullRequestPayloads.list(state: state, involvement: inv, limit: pageSize, projectId: scoped?.projectId, host: host,
                                                         filters: filters, query: text)
                    var r = try await self.environments.request(env, "pullRequests.list", input).decode(as: PullRequestListResult.self)
                    for i in r.entries.indices { r.entries[i].environmentId = env }
                    return r
                }
                do {
                    let r = try await read(involvement, filters, parsed.text.isEmpty ? nil : parsed.text)
                    cursors[env] = r.nextCursors.isEmpty ? nil : r.nextCursors
                    if r.truncated { truncated.append(env) }
                    merged.entries += r.entries
                    merged.errors += r.errors
                    merged.providers += r.providers.filter { p in !merged.providers.contains { $0.host == p.host } }
                    merged.truncated = merged.truncated || r.truncated
                    for (h, v) in r.viewers { merged.viewers["\(env) \(h)"] = v; if targets.count == 1 { merged.viewers[h] = v } }
                    // The priority groups' own reads, only once the feed has rows (`partitionTargets`).
                    if wantsPartitions, !r.entries.isEmpty {
                        let a = try? await read("authored", self.menuFilters, nil)
                        let b = try? await read("reviewing", self.menuFilters, nil)
                        if let a { authored? += a.entries } else { authored = nil }
                        if let b { reviewing? += b.entries } else { reviewing = nil }
                    }
                } catch {
                    failure = PullRequestDetailBinding.failure(error, number: 0).1
                }
            }
            guard self.generation == gen else { return }
            // An open PR that left the live page may just have closed. Read that transition once,
            // then cache the final result along with the other closed and merged rows.
            for var entry in previousOpen where !merged.entries.contains(where: { PullRequestListLogic.key($0) == PullRequestListLogic.key(entry) }) {
                guard failure == nil, let env = entry.environmentId else { merged.entries.append(entry); continue }
                let ref = PullRequestRef(projectId: entry.projectId, host: entry.host, repository: entry.repository, number: entry.number)
                guard let value = try? await self.environments.request(env, "pullRequests.detail", ref.payload),
                      let detail = try? value.decode(as: PullRequestDetail.self) else { merged.entries.append(entry); continue }
                if detail.state != "open" {
                    entry.state = detail.state; entry.isDraft = detail.isDraft; entry.title = detail.title
                    entry.additions = detail.additions; entry.deletions = detail.deletions
                    merged.entries.append(entry)
                }
            }
            guard self.generation == gen else { return }
            for entry in cachedFinal where !merged.entries.contains(where: { PullRequestListLogic.key($0) == PullRequestListLogic.key(entry) }) { merged.entries.append(entry) }
            self.loading = false
            if failure != nil && merged.entries.isEmpty && targets.count > 0 {
                self.error = failure
            } else {
                self.error = failure
                self.answer = Answer(result: merged, authored: authored, reviewing: reviewing)
                self.envCursors = cursors
                self.truncatedEnvs = truncated
                if host == nil || self.hosts.isEmpty { self.hosts = merged.providers }
                self.overrides = PullRequestListLogic.settle(self.overrides, answered: merged.entries, now: Date().timeIntervalSince1970 * 1000)
                self.loadStats(merged.entries.filter { !periodic || $0.state == "open" }, gen: gen)
            }
            self.render()
            self.syncDetail()
        }
    }

    /// `pullRequests.listStats` for rows the listing left without line counts (`usePullRequestListStats`).
    private func loadStats(_ entries: [PullRequestListEntry], gen: Int) {
        let missing = entries.filter { $0.additions == 0 && $0.deletions == 0 && stats[PullRequestListLogic.key($0)] == nil }
        let byEnv = Dictionary(grouping: missing, by: { $0.environmentId ?? "" })
        for (env, rows) in byEnv where !env.isEmpty {
            let refs = rows.prefix(500).map { PullRequestRef(projectId: $0.projectId, host: $0.host, repository: $0.repository, number: $0.number).payload }
            Task { [weak self] in
                guard let self, let reply = try? await self.environments.request(env, "pullRequests.listStats", .object(["refs": .array(Array(refs))])),
                      let result = try? reply.decode(as: PullRequestListStatsResult.self), self.generation == gen else { return }
                for s in result.stats {
                    guard let row = rows.first(where: { $0.number == s.number && $0.repository == s.repository }) else { continue }
                    self.stats[PullRequestListLogic.key(row)] = (s.additions, s.deletions)
                }
                self.render()
            }
        }
    }

    // MARK: Rendering

    private func entry(for target: PullRequestSurfaceTarget) -> PullRequestListEntry? {
        answer?.result.entries.first { $0.environmentId == target.environmentId && $0.repository.lowercased() == target.repository.lowercased() && $0.number == target.number }
    }

    private func render() {
        var m = PullRequestsPageView.Model()
        m.sort = sort; m.state = state; m.involvement = involvement; m.host = host
        m.menuFilters = menuFilters
        m.projectKey = projectKey
        m.searchText = PullRequestListLogic.parseQuery(query).text
        m.refreshing = refreshing || loading
        m.searchBusy = !query.trimmingCharacters(in: .whitespaces).isEmpty && (query.trimmingCharacters(in: .whitespacesAndNewlines) != sentQuery || loading)
        m.speedMode = speedMode
        m.nowMs = TimestampFormat.nowMs()
        let projects = self.projects
        let errors = Dictionary((answer?.result.errors ?? []).map { ($0.projectId, $0.message) }, uniquingKeysWith: { a, _ in a })
        m.projects = projects.map { p in
            PullRequestsPageView.ProjectOption(key: p.id.rawValue, title: p.title, unavailable: errors[p.id.localId.rawValue],
                                               icon: ProjectIconSource(p))
        }
        // Hosts: the workspace's own, then what the server answered for each (`hostMenuOptions`).
        var expected: [(host: String, kind: String)] = []
        for p in projects {
            if let id = p.repositoryIdentity, let kind = id.provider, let h = id.pullRequestHost, !expected.contains(where: { $0.host == h }) { expected.append((h, kind)) }
        }
        let hostEntries: [(host: String, kind: String)] = hosts.isEmpty ? expected : hosts.map { ($0.host, $0.kind) }
        m.hostOptions = [PullRequestsPageView.HostOption(value: "", label: "All", kind: nil)] + hostEntries.map { e in
            let summary = hosts.first { $0.host == e.host }
            return PullRequestsPageView.HostOption(value: e.host, label: PullRequestListLogic.hostLabel(hostEntries, e), kind: e.kind,
                                                   unavailable: summary.map { $0.configured ? nil : ($0.detail ?? "This host could not be read.") } ?? nil)
        }
        m.showProvider = hosts.count > 1
        m.hostActions = PullRequestListLogic.hostActions(hosts)
        let viewers = answer?.result.viewers ?? [:]
        // The rows: involvement, local narrowing, search, then grouping and the sort.
        let typed = PullRequestListLogic.parseQuery(query)
        let localFilters = menuFilters.merging(typed.filters)
        func narrowed(_ rows: [PullRequestListEntry]) -> [PullRequestListEntry] {
            localFilters.isEmpty ? rows : rows.filter { PullRequestListLogic.matchesFilters($0, localFilters, viewer: PullRequestListLogic.viewer($0, viewers)) }
        }
        var rows = PullRequestListLogic.filterByInvolvement(answer?.result.entries ?? [], viewers: viewers, involvement: involvement)
        rows = narrowed(rows)
        let searchingHosts = Set((answer?.result.providers ?? []).filter(\.searchesOnHost).map(\.host))
        if typed.text.isEmpty {
            rows = rows.stableSortedByUpdated()
        } else {
            let settled = query.trimmingCharacters(in: .whitespacesAndNewlines) == sentQuery
            rows = PullRequestListLogic.rank(rows, typed.text).filter { (settled && searchingHosts.contains($0.host)) || PullRequestListLogic.matchesQuery($0, typed.text) }
        }
        var groups: [PullRequestListLogic.Group]
        if involvement != "all" {
            groups = [PullRequestListLogic.Group(key: .others, label: "", entries: rows)]
        } else if let a = answer?.authored, let r = answer?.reviewing, typed.text.isEmpty {
            groups = PullRequestListLogic.partition(rows, authored: narrowed(a), reviewRequested: narrowed(r))
        } else {
            groups = PullRequestListLogic.groupByInvolvement(rows, viewers: viewers)
        }
        groups = groups.map { g in
            var g = g
            g.entries = PullRequestListLogic.apply(overrides, to: g.entries.map { e in
                guard e.additions == 0, e.deletions == 0, let s = stats[PullRequestListLogic.key(e)] else { return e }
                var e = e; e.additions = s.0; e.deletions = s.1; return e
            }, state: state)
            return g
        }
        groups = PullRequestListLogic.sortGroups(groups, sort: sort, searchText: typed.text, involvement: involvement).filter { !$0.entries.isEmpty || $0.label.isEmpty }
        m.groups = groups
        let shown = groups.reduce(0) { $0 + $1.entries.count }
        let facetsSource = answer?.result.entries ?? []
        let facets = PullRequestListLogic.facets(facetsSource, state: state)
        m.authors = facets.authors
        m.labels = facets.labels
        m.truncated = answer?.result.truncated ?? false
        m.canLoadMore = pageSize < PullRequestListLogic.maxPageSize
        m.loadingMore = loading && answer != nil
        if let target = container.panelState.active?.pullRequest, container.panelState.isOpen,
           let e = answer?.result.entries.first(where: { $0.environmentId == target.environmentId && $0.number == target.number && $0.repository.lowercased() == target.repository.lowercased() }) {
            m.selectedKey = PullRequestListLogic.key(e)
        }
        // `listBody`.
        let filtered = !menuFilters.isEmpty || state != "open" || involvement != "all" || projectKey != nil || host != nil
        if !capabilityKnown {
            m.body = .ghost(caption: nil)
        } else if capableEnvironments.isEmpty {
            m.body = .unavailable(title: "Pull requests unavailable", message: "Update your T3 Code servers to browse pull requests.", retry: false)
        } else if answer == nil && loading {
            m.body = .ghost(caption: nil)
        } else if let error, shown == 0 {
            m.body = .unavailable(title: "Could not load pull requests", message: error, retry: true)
        } else if shown == 0 {
            let typedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if (sidebar?.snapshot?.projects ?? []).isEmpty {
                m.body = .noProjects
            } else if !typedQuery.isEmpty && (typedQuery != sentQuery || loading) {
                let shownQuery = typedQuery.count > 48 ? String(typedQuery.prefix(48)) + "…" : typedQuery
                m.body = .ghost(caption: "Searching every host for “\(shownQuery)”")
            } else if !typedQuery.isEmpty {
                m.body = .searchEmpty(query: typedQuery)
            } else {
                m.body = .empty(filtered: filtered, canLoadMore: (answer?.result.truncated ?? false) && pageSize < PullRequestListLogic.maxPageSize)
            }
        } else {
            m.body = .list
            m.errorBanner = error
        }
        page.model = m
    }

    // MARK: Paging

    /// "Load more pull requests": continue where each environment's listing stopped, raising the page
    /// only for the ones truncated without a cursor; with no cursors at all, read a bigger page.
    private func loadMore() {
        let next = PullRequestWriteLogic.loadMore(pageSize: pageSize, nextCursors: envCursors, truncatedEnvironments: truncatedEnvs)
        pageSize = next.pageSize
        guard let cursors = next.cursors, var answer else { reload(keepRows: true); return }
        let parsed = PullRequestListLogic.parseQuery(sentQuery)
        let filters = menuFilters.merging(parsed.filters)
        let scoped = scopedProject()
        let (state, involvement, host, pageSize, regrown) = (self.state, self.involvement, self.host, self.pageSize, next.regrown)
        let targets = capableEnvironments.filter { (scoped == nil || scoped?.env == $0) && PullRequestWriteLogic.continues($0, cursors: cursors, regrown: regrown) }
        let gen = generation
        loading = true
        render()
        Task { [weak self] in
            guard let self else { return }
            var newCursors = self.envCursors
            var truncated: [String] = []
            for env in targets {
                let input = PullRequestPayloads.list(state: state, involvement: involvement, limit: pageSize, projectId: scoped?.projectId, host: host,
                                                     filters: filters, query: parsed.text.isEmpty ? nil : parsed.text, cursors: regrown.contains(env) ? nil : cursors[env])
                guard var r = try? await self.environments.request(env, "pullRequests.list", input).decode(as: PullRequestListResult.self) else { continue }
                for i in r.entries.indices { r.entries[i].environmentId = env }
                // A regrown environment answers from the top again: its rows replace the ones it gave before.
                if regrown.contains(env) { answer.result.entries.removeAll { $0.environmentId == env } }
                let have = Set(answer.result.entries.map(PullRequestListLogic.key))
                answer.result.entries += r.entries.filter { !have.contains(PullRequestListLogic.key($0)) }
                newCursors[env] = r.nextCursors.isEmpty ? nil : r.nextCursors
                if r.truncated { truncated.append(env) }
            }
            guard self.generation == gen else { return }
            answer.result.truncated = !truncated.isEmpty
            self.answer = answer
            self.envCursors = newCursors
            self.truncatedEnvs = truncated
            self.loading = false
            self.loadStats(answer.result.entries, gen: gen)
            self.render()
        }
    }

    // MARK: Row popovers

    /// A row's checks popover: the rollup now, the checks once `pullRequests.detail` answers (`LazyChecksBody`).
    private func showChecks(_ entry: PullRequestListEntry, from anchor: NSView) {
        guard let state = entry.checksState, let env = entry.environmentId else { return }
        let view = PullRequestChecksPopoverView(checksState: state, summary: nil, body: .loading)
        view.onOpenURL = { url in if let u = SafeExternalURL.parse(url) { NSWorkspace.shared.open(u) } }
        view.present(from: anchor)
        let ref = PullRequestRef(projectId: entry.projectId, host: capabilities.has(env, "threadPullRequests") ? entry.host : nil,
                                 repository: entry.repository, number: entry.number)
        Task { [weak view] in
            do {
                let d = try await self.environments.request(env, "pullRequests.detail", ref.payload).decode(as: PullRequestDetail.self)
                view?.body = .checks(d.checks)
            } catch {
                view?.body = .message(PullRequestDetailBinding.failure(error, number: entry.number).1)
            }
        }
    }

    /// A row's stack menu (`PullRequestStackPopover`): "Loading stack…", or the saved stack from linked threads
    /// while the read runs or after it fails (`usePullRequestStack`), then the layers; a pick opens it.
    private func showStack(_ entry: PullRequestListEntry, from anchor: NSView) {
        guard let membership = entry.stack, let env = entry.environmentId else { return }
        let ref = PullRequestRef(projectId: entry.projectId, host: entry.host, repository: entry.repository, number: entry.number)
        let saved = PullRequestWriteLogic.savedStack(PullRequestDetailBinding.savedLinks?(env) ?? [], reference: ref)
        let menu = MenuPopupView(items: PullRequestStackMenu.placeholder(number: membership.number, text: "Loading stack…"))
        guard let host = anchor.popupHost else { return }
        let popup = host.open(menu, trigger: anchor, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                              swallowsOutsideClick: true)
        menu.hostPopup = popup
        let show = { [weak self, weak menu] (stack: PullRequestStackDetail, notice: String?, stale: Bool) in
            guard let menu else { return }
            let items = PullRequestStackMenu.header(number: stack.number, notice: notice, stale: stale, onRetry: nil)
                + PullRequestStackMenu.layers(stack, current: entry.number, pending: false) { [weak self] number in
                    host.close(popup)
                    var e = entry
                    e.number = number
                    e.url = ChangeRequestURL.url(kind: e.provider, host: e.host, repository: e.repository, number: number) ?? e.url
                    self?.select(e)
                }
            menu.setItems(items)
            host.reposition(popup)
        }
        if let saved {
            show(saved, PullRequestWriteLogic.stackNotice(hasData: true, isSuccess: false, isPending: true, error: false), false)
        }
        Task { [weak self, weak menu] in
            guard let self, let menu else { return }
            do {
                let value = try await self.environments.request(env, "pullRequests.stack", ref.payload)
                guard value != .null, let stack = try? value.decode(as: PullRequestStackDetail.self) else {
                    menu.setItems(PullRequestStackMenu.placeholder(number: membership.number, text: "This pull request is no longer in a stack."))
                    host.reposition(popup)
                    return
                }
                show(stack, nil, false)
            } catch {
                if let saved {
                    show(saved, PullRequestWriteLogic.stackNotice(hasData: true, isSuccess: false, isPending: false, error: true), true)
                    return
                }
                menu.setItems(PullRequestStackMenu.placeholder(number: membership.number, text: PullRequestDetailBinding.failure(error, number: entry.number).1))
                host.reposition(popup)
            }
        }
    }

    // MARK: Selection and actions

    private func select(_ entry: PullRequestListEntry) {
        container.mutate {
            $0.openPullRequest(PullRequestSurfaceTarget(environmentId: entry.environmentId, projectId: entry.projectId, host: entry.host,
                                                        repository: entry.repository, number: entry.number, url: entry.url))
        }
        container.pullRequestStatus[PullRequestSurfaceTarget(environmentId: entry.environmentId, projectId: entry.projectId, host: entry.host,
                                                             repository: entry.repository, number: entry.number).surfaceId] = PullRequestStateTone(state: entry.state, isDraft: entry.isDraft)
        render()
    }

    private func syncDetail() {
        guard container.panelState.isOpen, let target = container.panelState.active?.pullRequest, let env = target.environmentId else {
            render()
            return
        }
        detail.show(environmentId: env, target: target)
        render()
    }

    /// Shift's quick actions (PullRequestSpeedActions.tsx): close, merge, ready, reopen.
    private func speedAction(_ entry: PullRequestListEntry, _ action: String) {
        guard let env = entry.environmentId else { return }
        let ref = PullRequestRef(projectId: entry.projectId, host: entry.host, repository: entry.repository, number: entry.number)
        Task { [weak self] in
            guard let self else { return }
            var method: String?
            if action == "merge" {
                // The merge method needs the detail (`resolveMergeMethod`).
                guard let d = try? await self.environments.request(env, "pullRequests.detail", ref.payload).decode(as: PullRequestDetail.self) else { return }
                let allowed = PullRequestDetailLogic.allowedMergeMethods(d)
                guard !allowed.isEmpty else { self.toast("No merge method is available for this repository.", nil, .error); return }
                method = PullRequestDetailLogic.selectedMergeMethod(allowed, preferred: UserDefaults.standard.string(forKey: PullRequestDetailBinding.mergeMethodKey) ?? "merge")
            }
            do {
                _ = try await self.environments.request(env, "pullRequests.runAction", PullRequestPayloads.action(ref, action: action, mergeMethod: method))
                if action != "merge", let o = PullRequestListLogic.override(after: action, entry: entry, now: Date(), token: self.nextToken()) {
                    self.overrides[PullRequestListLogic.key(entry)] = o
                }
                self.toast(PullRequestDetailLogic.actionSuccess(action), nil, .success)
                self.reload(keepRows: true)
            } catch {
                self.toast(PullRequestDetailLogic.actionFailure(action), PullRequestDetailBinding.failure(error, number: entry.number).1, .error)
            }
        }
    }

    private func toast(_ title: String, _ message: String?, _ kind: ToastQueue.Kind) {
        _ = container.toasts.show(ToastView(title: title, message: message, kind: kind))
    }
}

private extension Array where Element == PullRequestListEntry {
    /// Newest update first once nothing is typed (`toSorted` by `updatedAt`, stable).
    func stableSortedByUpdated() -> [PullRequestListEntry] {
        enumerated().sorted { a, b in a.element.updatedAt != b.element.updatedAt ? a.element.updatedAt > b.element.updatedAt : a.offset < b.offset }.map(\.element)
    }
}
