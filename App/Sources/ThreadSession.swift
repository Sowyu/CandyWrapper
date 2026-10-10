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

    init(threadId: ThreadId, panel: ThreadPanelView, sidebar: SidebarContentView?) {
        self.threadId = threadId
        environmentId = threadId.environmentId ?? ""
        self.panel = panel
        self.sidebar = sidebar
        let relay = ShellSession.ChangeRelay()
        store = ThreadStore(threadId: threadId.localId, onChange: { relay.fire() })
        relay.set { [weak self] in Task { @MainActor in await self?.pull() } }
        panel.onLoadEarlier = { [weak self] in self?.loadEarlier() }
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
            guard case .value(let json) = event, let item = ThreadSession.decode(json) else { return }
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
    func end() {
        detach()
        active = false
    }

    /// The store calls `onChange` once per window between takes, so each pull renders every change since the last.
    private func pull() async {
        guard let update = await store.takeUpdate(), active, let panel else { return }
        let (projectTitle, workspaceRoot) = place(update.projection)
        panel.setProjection(update.projection, projectTitle: projectTitle, workspaceRoot: workspaceRoot)
        panel.header.projectIcon = project(update.projection).map(ProjectIconSource.init)
        onProjection?(update.projection)
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
                let page = try await http.get(request.path, token: token, as: ThreadHistoryPage.self)
                await store.applyHistoryPage(page, requestCursor: request.cursor)
            } catch {
                await store.failHistoryLoad(requestCursor: request.cursor, message: "Could not load earlier turns.")
            }
        }
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
    private(set) var composer: ComposerController!
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private var session: ThreadSession?
    /// Development: `--open-thread <title prefix>` opens the first matching thread once the shell arrives.
    private var openPrefix: String?
    /// Development: `--open-diff` opens the right panel on that thread's newest turn that changed files.
    private var openDiff = CommandLine.arguments.contains("--open-diff")
    private var restored = false
    private var keyMonitor: Any?
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
        sidebar.actions.openThread = { [weak self] id in self?.open(id) }
        composer = ComposerController(panel: panel, sidebar: sidebar, environments: environments)
        composer.openThread = { [weak self] id in self?.open(id) }
        sidebar.actions.newThread = { [weak self] in self?.newThread() }
        sidebar.actions.openDraft = { [weak self] id in
            guard let self, composer.openDraft(id) else { return }
            session?.end()
            session = nil
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
        panel.onRightPanelChange = { [weak self] open in self?.rememberRightPanel(open) }
        // Nothing to show until the shell arrives; T3's index route renders nothing before bootstrap.
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        // Cmd+D is T3's `diff.toggle` (a web keydown handler, not a menu item in the desktop app).
        // ponytail: the default binding only; read the user's keybindings from server config in M7
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard event.window === window, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "d", let self else { return event }
            MainActor.assumeIsolated { self.panel.toggleDiff() }
            return nil
        }
    }

    /// T3 keeps the right panel's state per thread and persists it (rightPanelStore.ts,
    /// `t3code:right-panel-state:v2`). Only open threads are stored.
    private static let rightPanelKey = "thread.rightPanelOpen"

    private func rememberRightPanel(_ open: Bool) {
        guard let id = session?.threadId else { return }
        var ids = UserDefaults.standard.stringArray(forKey: Self.rightPanelKey) ?? []
        ids.removeAll { $0 == id.rawValue }
        // ponytail: newest 200 threads; T3 keeps every thread's entry
        if open { ids = Array(([id.rawValue] + ids).prefix(200)) }
        UserDefaults.standard.set(ids, forKey: Self.rightPanelKey)
    }

    private func rightPanelWasOpen(_ id: ThreadId) -> Bool {
        UserDefaults.standard.stringArray(forKey: Self.rightPanelKey)?.contains(id.rawValue) == true
    }

    /// The open thread across launches, scoped. T3 routes by `_chat.$environmentId.$threadId`.
    private static let lastThreadKey = "thread.lastOpenScoped"

    /// An environment's session started, was replaced or ended: the open thread follows its own one.
    private func sessionChanged(_ environmentId: String) {
        composer.sessionChanged(environmentId)
        guard let session, session.environmentId == environmentId else { return }
        if let shell = environments.session(environmentId) { session.attach(shell) } else { session.detach() }
    }

    func open(_ id: ThreadId) {
        sidebar?.state.activeThreadId = id
        UserDefaults.standard.set(id.rawValue, forKey: Self.lastThreadKey)
        guard id != session?.threadId || panel.isDraft else { return }
        session?.end()
        panel.setDraft(projectTitle: nil)
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        composer.showThread(id)
        panel.setRightPanelOpen(rightPanelWasOpen(id))
        let session = ThreadSession(threadId: id, panel: panel, sidebar: sidebar)
        session.onProjection = { [weak self] projection in self?.composer.projectionChanged(projection, threadId: id) }
        if let shell = environments.session(id.environmentId) { session.attach(shell) }
        self.session = session
        updateEnvironmentBanner()
        if openDiff {
            openDiff = false
            panel.opensChangedTurnOnLoad = true
        }
    }

    /// The sidebar's new-thread button: the draft page for the open thread's project.
    // ponytail: no projects means no draft; T3 shows "Add a project to start" there
    func newThread() {
        let previous = session
        guard composer.newThread() else { return }
        previous?.end()
        session = nil
    }

    func close() {
        session?.end()
        session = nil
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
        composer.environmentRemoved(environmentId)
        let defaults = UserDefaults.standard
        if let ids = defaults.stringArray(forKey: Self.rightPanelKey) {
            defaults.set(ids.filter { !$0.hasPrefix(prefix) }, forKey: Self.rightPanelKey)
        }
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
