import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// One open thread: the `orchestration.subscribeThread` stream on its environment's supervisor (the
/// same socket as that environment's shell, resumed from the store's cursor), the store (decodes and
/// reduces off the main thread) and the panel (pulls one merged update per change window). Older
/// history comes over HTTP when the timeline scrolls near its first row.
@MainActor
final class ThreadSession {
    /// Scoped, `environmentId:threadId` (`EnvironmentScope`). The store and the wire use the local id.
    let threadId: ThreadId
    let environmentId: String
    private let store: ThreadStore
    private weak var panel: ThreadPanelView?
    private weak var sidebar: SidebarContentView?
    private var shell: ShellSession?
    private var subscription: Task<Void, Never>?
    private var historyLoad: Task<Void, Never>?
    /// False once another thread took the panel.
    private var active = true
    /// After each projection the panel shows (the composer reads runs and requests from it).
    var onProjection: ((ThreadProjection?) -> Void)?
    /// The store's sync status after each render (the composer's "Loading messages..." row).
    var onStatus: ((ThreadSyncStatus) -> Void)?

    private let relay: ShellSession.ChangeRelay

    /// A closed thread's store and its change relay, kept so a reopen paints at once and resumes
    /// after the store's sequence instead of fetching a new snapshot.
    struct Retained {
        let store: ThreadStore
        let relay: ShellSession.ChangeRelay
    }

    init(threadId: ThreadId, panel: ThreadPanelView, sidebar: SidebarContentView?, retained: Retained? = nil, cache: ThreadCache? = nil) {
        self.threadId = threadId
        environmentId = threadId.environmentId ?? ""
        self.panel = panel
        self.sidebar = sidebar
        let relay = retained?.relay ?? ShellSession.ChangeRelay()
        self.relay = relay
        let store = retained?.store ?? ThreadStore(threadId: threadId.localId, cache: cache, environmentId: environmentId, onChange: { relay.fire() })
        self.store = store
        relay.set { [weak self] in Task { @MainActor in await self?.pull() } }
        panel.onLoadEarlier = { [weak self] in self?.loadEarlier() }
        if retained != nil {
            Task { [weak self] in await self?.showRetained() }
        } else {
            // A cold open paints from the disk cache before the network; the store publishes it.
            Task { await store.restoreFromCache() }
        }
    }

    /// The retained state, before the resumed stream catches up.
    private func showRetained() async {
        guard let update = await store.currentUpdate() else { return }
        OpenTiming.mark("retained store", "\(update.projection?.visibleTurnItems.count ?? 0) rows")
        render(update)
    }

    /// Subscribes on `shell`'s supervisor. Called again when the app replaces its shell session
    /// (server restart, idle stop then wake); the store keeps its cursor, so the new stream resumes.
    func attach(_ shell: ShellSession) {
        // Already streaming on this session: the supervisor resubscribes across reconnects itself.
        if shell === self.shell, subscription != nil { return }
        subscription?.cancel()
        historyLoad?.cancel()
        historyLoad = nil
        self.shell = shell
        if active {
            panel?.diffPanel.loader = Self.diffLoader(shell.supervisor)
            panel?.model.turnItemLoader = Self.turnItemLoader(shell.supervisor)
        }
        let store = self.store
        subscription = shell.supervisor.subscribe("orchestration.subscribeThread", payload: {
            ThreadSession.encode(await store.subscribeInput())
        }, handler: { event in
            guard case .value(let json) = event,
                  let item = OpenTiming.measure("typed decode", ThreadSession.label(json), { ThreadSession.decode(json) })
            else { return }
            await store.apply([item])
        })
    }

    /// The shell went away without a successor yet. The panel keeps the last state.
    func detach() {
        subscription?.cancel()
        subscription = nil
        historyLoad?.cancel()
        historyLoad = nil
        shell = nil
    }

    /// Ends the subscription for good; the panel belongs to another thread or the window closed.
    /// Returns the store for retention.
    @discardableResult
    func end() -> Retained {
        detach()
        active = false
        relay.set {}
        let store = self.store
        Task { await store.flushCache() }
        return Retained(store: store, relay: relay)
    }

    /// The store calls `onChange` once per window between takes, so each pull renders every change since the last.
    private func pull() async {
        guard let update = await store.takeUpdate() else { return }
        OpenTiming.mark("panel pull", "\(update.projection?.visibleTurnItems.count ?? 0) rows")
        render(update)
    }

    private func render(_ update: ThreadUpdate) {
        guard active, let panel else { return }
        let (projectTitle, workspaceRoot) = place(update.projection)
        OpenTiming.measure("panel setProjection") {
            panel.setProjection(update.projection, projectTitle: projectTitle, workspaceRoot: workspaceRoot)
        }
        panel.header.projectIcon = project(update.projection).map(ProjectIconSource.init)
        onProjection?(update.projection)
        onStatus?(update.status)
    }

    /// Project title and workspace root from the shell (the worktree when the thread has one).
    private func place(_ projection: ThreadProjection?) -> (String, String?) {
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.threads.first { $0.id == threadId } ?? snapshot?.archivedThreads.first { $0.id == threadId }
        guard let project = project(projection) else { return ("", nil) }
        return (project.title, projection?.thread.worktreePath ?? shell?.worktreePath ?? project.workspaceRoot)
    }

    private func project(_ projection: ThreadProjection?) -> ProjectShell? {
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.threads.first { $0.id == threadId } ?? snapshot?.archivedThreads.first { $0.id == threadId }
        guard let projectId = projection?.thread.projectId?.scoped(to: environmentId) ?? shell?.projectId else { return nil }
        return snapshot?.projects.first { $0.id == projectId }
    }

    private func loadEarlier() {
        guard historyLoad == nil, let shell else { return }
        var http = shell.http
        // T3's history request timeout (RT/threadHistoryHttp.ts).
        http.timeout = 6
        let store = self.store, token = shell.token
        historyLoad = Task { [weak self] in
            defer { self?.historyLoad = nil }
            guard let request = await store.beginLoadEarlier() else { return }
            do {
                let start = ContinuousClock.now
                let page = try await http.get(request.path, token: token, as: ThreadHistoryPage.self)
                if OpenTiming.enabled {
                    // History pages come after first paint; they print on their own clock.
                    FileHandle.standardError.write(Data(String(
                        format: "thread-timing history page %.1f ms (fetch and decode), %d rows, more %@\n",
                        OpenTiming.ms(ContinuousClock.now - start), page.items.count, page.hasMoreHistory ? "yes" : "no").utf8))
                }
                await store.applyHistoryPage(page, requestCursor: request.cursor)
            } catch {
                await store.failHistoryLoad(requestCursor: request.cursor, message: "Could not load earlier turns.")
            }
        }
    }

    /// The stream item's kind and size for the timing lines.
    nonisolated static func label(_ json: JSONValue) -> String {
        let kind = json["kind"]?.stringValue ?? "?"
        guard kind == "snapshot", let p = json["projection"] else { return kind }
        let count = { (key: String) -> Int in if case .array(let a)? = p[key] { a.count } else { 0 } }
        return "snapshot: \(count("visibleTurnItems")) rows, \(count("turnItems")) turn items, \(count("runs")) runs, \(count("nodes")) nodes, \(count("messages")) messages"
    }

    nonisolated static func decode(_ json: JSONValue) -> ThreadStreamItem? {
        try? json.decode(as: ThreadStreamItem.self)
    }

    /// `getTurnDiff` and `getFullThreadDiff` as unary calls on the shell's socket (DiffPanel's
    /// request rule is `TurnDiffs.request`). Failures carry the server's message, which T3 shows.
    nonisolated static func diffLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.Loader {
        { request in
            let (tag, payload) = switch request {
            case .turn(let input): ("orchestration.getTurnDiff", encode(input))
            case .fullThread(let input): ("orchestration.getFullThreadDiff", encode(input))
            }
            do {
                let json = try await supervisor.request(tag, payload: payload)
                return try JSONDecoder().decode(ThreadTurnDiff.self, from: JSONEncoder().encode(json))
            } catch let error as RPCClientError {
                throw DiffLoadError(errorDescription: error.description)
            }
        }
    }

    struct DiffLoadError: LocalizedError { var errorDescription: String? }

    /// `orchestration.getTurnItem` on the shell's socket for an open row whose output the stream
    /// left out. Decoding and trimming run here, off the main thread; the row gets only the text.
    nonisolated static func turnItemLoader(_ supervisor: ConnectionSupervisor) -> ThreadViewModel.TurnItemLoader {
        { input, wireType in
            do {
                let json = try await supervisor.request("orchestration.getTurnItem", payload: encode(input))
                let result = try json.decode(as: GetTurnItemResult.self)
                return TurnItemDetail.resolve(result, wireType: wireType)
            } catch let error as RPCClientError {
                throw DiffLoadError(errorDescription: error.description)
            }
        }
    }

    nonisolated static func encode(_ input: some Encodable) -> JSONValue {
        guard let data = try? JSONEncoder().encode(input),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .object([:]) }
        return json
    }
}

/// Which thread the main panel shows: opens threads from the sidebar on their own environment's
/// session, follows that session across reconnects and server restarts, remembers the last thread
/// (a scoped id) and reopens it.
@MainActor
final class ThreadController {
    let panel = ThreadPanelView()
    private(set) var terminal: TerminalController!
    private(set) var composer: ComposerController!
    private(set) var git: GitController!
    private(set) var files: FilesController!
    private(set) var pullRequests: ThreadPullRequestsController!
    private(set) var browser: BrowserController!
    private(set) var automations: ThreadAutomationsController!
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private var session: ThreadSession? {
        willSet { if let old = session, old !== newValue { retain(old) } }
    }
    /// Closed threads' stores, newest last, for T3's 5-minute retention (threadRetention.ts:3).
    private var retained: [(id: ThreadId, store: ThreadSession.Retained, until: Date)] = []
    /// Development: `--open-thread <title prefix>` opens the first matching thread once the shell arrives.
    private var openPrefix: String?
    /// Development: `--open-diff` opens the right panel on that thread's newest turn that changed files.
    private var openDiff = CommandLine.arguments.contains("--open-diff")
    /// Development: `--perf-open <seconds> <title prefix>` opens the first matching thread that long
    /// after the first shell, as a click would, then 2 s later the thread open before it, then 2 s
    /// later the match again (a reopen). scripts/perf-review times both with CANDY_THREAD_TIMING.
    private var perfOpen: (delay: Double, prefix: String)?
    private var restored = false
    /// The environment the connection banner speaks for, and since when it is unavailable.
    private var bannerEnvironment: (id: String, since: Date)?
    private var bannerTimer: DispatchWorkItem?

    init(sidebar: SidebarContentView, window: NSWindow, environments: Environments) {
        self.sidebar = sidebar
        self.environments = environments
        panel.projectIconForTitle = { [weak sidebar] title in
            sidebar?.snapshot?.projects.first { $0.title == title }.map(ProjectIconSource.init)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-thread"), i + 1 < args.count { openPrefix = args[i + 1] }
        if let i = args.firstIndex(of: "--perf-open"), i + 2 < args.count, let delay = Double(args[i + 1]) { perfOpen = (delay, args[i + 2]) }
        sidebar.actions.openThread = { [weak self] id in self?.open(id) }
        composer = ComposerController(panel: panel, sidebar: sidebar, environments: environments)
        terminal = TerminalController(panel: panel, sidebar: sidebar, environments: environments)
        git = GitController(panel: panel, sidebar: sidebar, environments: environments, composer: composer)
        automations = ThreadAutomationsController(panel: panel, environments: environments)
        composer.onTargetChange = { [weak self] in self?.git.refresh(); self?.automations.sync() }
        files = FilesController(panel: panel, sidebar: sidebar, environments: environments)
        files.openThread = { [weak self] id in self?.open(id) }
        let prCapabilities = PullRequestCapabilities(environments: environments)
        pullRequests = ThreadPullRequestsController(panel: panel, sidebar: sidebar, environments: environments, capabilities: prCapabilities)
        pullRequests.openThreadId = { [weak self] in self?.openThreadId }
        automations.openThreadId = { [weak self] in self?.openThreadId }
        prCapabilities.onChange = { [weak self] in self?.pullRequests.sync() }
        browser = BrowserController(panel: panel, sidebar: sidebar, environments: environments, files: files)
        files.onSync = { [weak self] in self?.pullRequests.sync(); self?.browser.sync() }
        // A row's pull request badge: one link opens it beside the thread, a stack or several open
        // the thread's pull requests tab (`ThreadPullRequestBadgeControl`).
        sidebar.actions.openPullRequest = { [weak self, weak sidebar] id in
            guard let self, let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }) else { return }
            self.open(id)
            if SidebarPullRequestBadge(thread)?.opensList == true {
                self.panel.mutatePanel { $0.open(.pullRequests); return [] }
            } else {
                self.pullRequests.openCurrentPullRequest()
            }
        }
        // A chat file chip opens the file tab at its line (ChatMarkdown.tsx `fileLinkChip`).
        // ponytail: Cmd-click opens the panel too; route it to the preferred editor with WP7.8's editor open
        panel.model.openFile = { [weak self] meta, _ in self?.files.openLink(meta) }
        composer.openThread = { [weak self] id in self?.open(id) }
        sidebar.actions.newThread = { [weak self] in self?.newThread() }
        sidebar.actions.openDraft = { [weak self] id in
            guard let self, composer.openDraft(id) else { return }
            session?.end()
            session = nil
            terminal.show(nil)
            files.show(nil)
        }
        sidebar.actions.discardDraft = { [weak self] id in self?.composer.discardDraft(id) }
        sidebar.actions.searchThreads = { [weak environments] query in await environments?.searchThreads(query) }
        environments.onSessionChange = { [weak self] env in self?.sessionChanged(env) }
        environments.onShell = { [weak self] snapshot in self?.shellChanged(snapshot) }
        environments.onRemove = { [weak self] env in self?.environmentRemoved(env) }
        environments.observe { [weak self] in self?.updateEnvironmentBanner() }
        panel.environmentBanner.reconnect.action = { [weak self] in
            guard let self, let id = self.bannerEnvironment?.id else { return }
            self.environments.reconnect(id)
        }
        panel.environmentBanner.disconnect.action = { [weak self] in
            guard let self, let id = self.bannerEnvironment?.id else { return }
            self.disconnect(id)
        }
        sidebar.scopeDefaults = .standard
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Nothing to show until the shell arrives; T3's index route renders nothing before bootstrap.
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
    }

    /// The thread view's keybindings (ChatView.tsx:8030-8180, Sidebar.tsx:4872-4910).
    func registerShortcuts(_ shortcuts: Shortcuts) {
        composer.registerShortcuts(shortcuts)
        terminal.registerShortcuts(shortcuts)
        git.registerShortcuts(shortcuts)
        files.registerShortcuts(shortcuts)
        pullRequests.registerShortcuts(shortcuts)
        browser.registerShortcuts(shortcuts)
        // `diff.toggle` (`toggle(ref, "diff")`) and `rightPanel.toggle` (`toggleRightPanel`).
        shortcuts.on(["diff.toggle", "rightPanel.toggle"]) { [weak self] call in
            guard let self, self.panel.window != nil else { return false }
            if call.command == "diff.toggle" { self.panel.toggleDiff() } else { self.panel.toggleRightPanel() }
            return true
        }
        // `thread.previous`, `thread.next`, `thread.jump.N` walk the sidebar's rows; ignored on repeat.
        shortcuts.on(["thread.previous", "thread.next"] + Keymap.threadJumpCommands) { [weak self] call in
            guard let self, !call.isRepeat, let sidebar = self.sidebar, sidebar.window != nil else { return false }
            let ids = sidebar.orderedThreadIds
            let target: ThreadId?
            if let index = Keymap.jumpIndex(call.command, prefix: "thread.jump.") {
                target = index < ids.count ? ids[index] : nil
            } else {
                target = Self.adjacentThread(ids, current: self.openThreadId, previous: call.command == "thread.previous")
            }
            guard let target else { return false }
            self.open(target)
            return true
        }
    }

    /// `resolveAdjacentThreadId` (Sidebar.logic.ts:873-898).
    static func adjacentThread(_ ids: [ThreadId], current: ThreadId?, previous: Bool) -> ThreadId? {
        guard !ids.isEmpty else { return nil }
        guard let current else { return previous ? ids.last : ids.first }
        guard let index = ids.firstIndex(of: current) else { return nil }
        let next = index + (previous ? -1 : 1)
        return ids.indices.contains(next) ? ids[next] : nil
    }

    /// The open thread across launches, scoped. T3 routes by `_chat.$environmentId.$threadId`.
    private static let lastThreadKey = "thread.lastOpenScoped"

    /// An environment's session started, was replaced or ended: the open thread follows its own one.
    private func sessionChanged(_ environmentId: String) {
        composer.sessionChanged(environmentId)
        terminal.sessionChanged(environmentId)
        git.sessionChanged(environmentId)
        browser.sessionChanged(environmentId)
        guard let session, session.environmentId == environmentId else { return }
        if let shell = environments.session(environmentId) { session.attach(shell) } else { session.detach() }
    }

    func open(_ id: ThreadId) {
        sidebar?.state.activeThreadId = id
        UserDefaults.standard.set(id.rawValue, forKey: Self.lastThreadKey)
        guard id != session?.threadId || panel.isDraft else { return }
        OpenTiming.begin(id.rawValue)
        session?.end()
        panel.setDraft(projectTitle: nil)
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        composer.showThread(id)
        files.show(id)
        let kept = retained.firstIndex { $0.id == id }.map { retained.remove(at: $0).store }
        let session = ThreadSession(threadId: id, panel: panel, sidebar: sidebar, retained: kept, cache: environments.threadCache)
        session.onProjection = { [weak self] projection in self?.composer.projectionChanged(projection, threadId: id) }
        session.onStatus = { [weak self] status in self?.composer.threadStatusChanged(status, threadId: id) }
        if let shell = environments.session(id.environmentId) { session.attach(shell) }
        self.session = session
        terminal.show(id)
        updateEnvironmentBanner()
        if openDiff {
            openDiff = false
            panel.opensChangedTurnOnLoad = true
        }
    }

    /// Keeps a closed thread's store for 5 minutes, like T3. Only the newest few: a huge thread's
    /// bounded window holds about 12 MB (900 runs, 3,600 nodes).
    // ponytail: count cap of 2, no byte budget; weigh retained stores by snapshot size if memory reviews flag it
    private func retain(_ old: ThreadSession) {
        let store = old.end()
        retained.removeAll { $0.id == old.threadId }
        retained.append((old.threadId, store, Date().addingTimeInterval(Self.retention)))
        if retained.count > 2 { retained.removeFirst(retained.count - 2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retention + 1) { [weak self] in
            MainActor.assumeIsolated { self?.retained.removeAll { $0.until <= Date() } }
        }
    }

    private static let retention: TimeInterval = 5 * 60

    /// The sidebar's new-thread button: the draft page for the open thread's project.
    // ponytail: no projects means no draft; T3 shows "Add a project to start" there
    func newThread(in project: ProjectShell? = nil) {
        let previous = session
        guard composer.newThread(in: project) else { return }
        previous?.end()
        session = nil
        terminal.show(nil)
        files.show(nil)
    }

    /// The thread the panel shows, nil on a draft (the route's thread in T3).
    var openThreadId: ThreadId? { panel.isDraft ? nil : session?.threadId }

    func close() {
        session?.end()
        session = nil
        terminal.show(nil)
        files.show(nil)
    }

    /// "<label> is reconnecting|offline" over the composer while the open thread's environment is not
    /// connected (ChatView.tsx:2668-2750, 3091-3142): reconnecting shows after a 2 s grace
    /// (`ENVIRONMENT_RECONNECT_WARNING_GRACE_MS`), "Disconnect server" after 20 s on a remote machine
    /// (`useEnvironmentDisconnectDelay`). No session (the local server stopped while idle) shows nothing.
    private func updateEnvironmentBanner() {
        bannerTimer?.cancel()
        bannerTimer = nil
        let banner = panel.environmentBanner
        guard let id = session?.environmentId, let state = environments.state(id),
              state.status != .connected, state.status != .available else {
            bannerEnvironment = nil
            panel.showsEnvironmentBanner = false
            return
        }
        if bannerEnvironment?.id != id { bannerEnvironment = (id, Date()) }
        let elapsed = Date().timeIntervalSince(bannerEnvironment!.since)
        let reconnecting = state.status == .connecting || state.status == .reconnecting
        let remote = id != environments.primaryId
        var wake: TimeInterval?
        if reconnecting && elapsed < 2 {
            panel.showsEnvironmentBanner = false
            wake = 2 - elapsed
        } else {
            banner.text = "\(environments.label(id) ?? "Remote") is \(reconnecting ? "reconnecting" : "offline")"
            banner.isError = state.status == .error
            banner.showsReconnect = !reconnecting
            banner.showsDisconnect = remote && elapsed >= 20
            panel.showsEnvironmentBanner = true
            if remote && elapsed < 20 { wake = 20 - elapsed }
        }
        if let wake {
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updateEnvironmentBanner() } }
            bannerTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + wake + 0.05, execute: item)
        }
    }

    /// "Disconnect server": switches the machine off and goes to the index, as T3 navigates to "/".
    private func disconnect(_ environmentId: String) {
        panel.environmentBanner.disconnect.isEnabled = false
        Task {
            defer { panel.environmentBanner.disconnect.isEnabled = true }
            do {
                try await environments.setEnabled(environmentId, false)
            } catch {
                panel.toasts.show(ToastView(title: "Could not disconnect server", message: "\(error)", kind: .error))
                return
            }
            if session?.environmentId == environmentId { landOnIndex() }
        }
    }

    /// Like T3's index route: a draft for the most recently active project, else nothing.
    private func landOnIndex() {
        session?.end()
        session = nil
        terminal.show(nil)
        files.show(nil)
        updateEnvironmentBanner()
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        if let snapshot = sidebar?.snapshot,
           let project = SidebarModel.sortProjectsForSidebar(snapshot.projects, threads: snapshot.threads, order: .updatedAt).first {
            _ = composer.newThread(in: project)
        }
    }

    /// A removed environment: its open thread closes and the per-thread state the app keeps for it
    /// goes (right panel, remembered thread, visits, scope). Composer state goes in the composer.
    private func environmentRemoved(_ environmentId: String) {
        let prefix = environmentId + ":"
        retained.removeAll { $0.id.environmentId == environmentId }
        composer.environmentRemoved(environmentId)
        terminal.environmentRemoved(environmentId)
        let defaults = UserDefaults.standard
        files.environmentRemoved(environmentId)
        browser.environmentRemoved(environmentId)
        if defaults.string(forKey: Self.lastThreadKey)?.hasPrefix(prefix) == true { defaults.removeObject(forKey: Self.lastThreadKey) }
        if let sidebar {
            var state = sidebar.state
            state.localVisits = state.localVisits.filter { !$0.key.rawValue.hasPrefix(prefix) }
            if state.activeThreadId?.rawValue.hasPrefix(prefix) == true { state.activeThreadId = nil }
            sidebar.state = state
            // A `separate` mode group key is a physical key, `environmentId:path`.
            if state.projectScopeKey?.hasPrefix(prefix) == true { sidebar.setProjectScope(nil) }
        }
        guard session?.environmentId == environmentId else { return }
        landOnIndex()
    }

    /// With the first shell: opens the `--open-thread` match or the remembered thread, else lands
    /// like T3's index route (`_chat.index.tsx:36-60`) in a draft for the most recently active project.
    private func shellChanged(_ snapshot: ShellSnapshot) {
        composer.projectsChanged()
        git.refresh()
        files.shellChanged()
        pullRequests.sync()
        if let perf = perfOpen {
            perfOpen = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + perf.delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let match = self.sidebar?.snapshot?.threads.first(where: { $0.title.hasPrefix(perf.prefix) }) else { return }
                    let before = self.session?.threadId
                    self.open(match.id)
                    guard let before else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        MainActor.assumeIsolated {
                            self?.open(before)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                                MainActor.assumeIsolated { self?.open(match.id) }
                            }
                        }
                    }
                }
            }
        }
        if let prefix = openPrefix, let match = snapshot.threads.first(where: { $0.title.hasPrefix(prefix) }) {
            openPrefix = nil
            restored = true
            open(match.id)
            return
        }
        guard !restored, openPrefix == nil else { return }
        let remembered = UserDefaults.standard.string(forKey: Self.lastThreadKey).map { ThreadId($0) }
        // The remembered thread's environment is connecting but its shell hasn't arrived: wait for it.
        if let env = remembered?.environmentId, environments.isRegistered(env), !environments.hasShell(env) { return }
        restored = true
        guard session == nil, !panel.isDraft else { return }
        if let remembered, snapshot.threads.contains(where: { $0.id == remembered }) {
            open(remembered)
        } else if let project = SidebarModel.sortProjectsForSidebar(snapshot.projects, threads: snapshot.threads, order: .updatedAt).first {
            _ = composer.newThread(in: project)
        }
    }
}
