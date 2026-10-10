import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// One open thread: the `orchestration.subscribeThread` stream on the shell's supervisor (the
/// same socket, resumed from the store's cursor), the store (decodes and reduces off the main
/// thread) and the panel (pulls one merged update per change window). Older history comes over
/// HTTP when the timeline scrolls near its first row.
@MainActor
final class ThreadSession {
    let threadId: ThreadId
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
        self.panel = panel
        self.sidebar = sidebar
        let relay = ShellSession.ChangeRelay()
        store = ThreadStore(threadId: threadId, onChange: { relay.fire() })
        relay.set { [weak self] in Task { @MainActor in await self?.pull() } }
        panel.onLoadEarlier = { [weak self] in self?.loadEarlier() }
    }

    /// Subscribes on `shell`'s supervisor. Called again when the app replaces its shell session
    /// (server restart, idle stop then wake); the store keeps its cursor, so the new stream resumes.
    func attach(_ shell: ShellSession) {
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
        guard let projectId = projection?.thread.projectId ?? shell?.projectId else { return nil }
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

/// Which thread the main panel shows: opens threads from the sidebar, follows the app's shell
/// session across server restarts, remembers the last thread per environment and reopens it.
@MainActor
final class ThreadController {
    let panel = ThreadPanelView()
    private(set) var composer: ComposerController!
    private weak var sidebar: SidebarContentView?
    private var session: ThreadSession?
    private var shell: ShellSession?
    private var environment: String?
    /// Development: `--open-thread <title prefix>` opens the first matching thread once the shell arrives.
    private var openPrefix: String?
    /// Development: `--open-diff` opens the right panel on that thread's newest turn that changed files.
    private var openDiff = CommandLine.arguments.contains("--open-diff")
    private var restored = false
    private var keyMonitor: Any?

    init(sidebar: SidebarContentView, window: NSWindow) {
        self.sidebar = sidebar
        panel.projectIconForTitle = { [weak sidebar] title in
            sidebar?.snapshot?.projects.first { $0.title == title }.map(ProjectIconSource.init)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-thread"), i + 1 < args.count { openPrefix = args[i + 1] }
        sidebar.actions.openThread = { [weak self] id in self?.open(id) }
        composer = ComposerController(panel: panel, sidebar: sidebar)
        composer.openThread = { [weak self] id in self?.open(id) }
        sidebar.actions.newThread = { [weak self] in self?.newThread() }
        sidebar.actions.openDraft = { [weak self] id in
            guard let self, composer.openDraft(id) else { return }
            session?.end()
            session = nil
        }
        sidebar.actions.discardDraft = { [weak self] id in self?.composer.discardDraft(id) }
        sidebar.actions.searchThreads = { [weak self] query in
            guard let supervisor = self?.shell?.supervisor,
                  let json = try? await supervisor.request("orchestration.searchThreads", payload: .object(["query": .string(query)]))
            else { return nil }
            return (try? json.decode(as: ThreadSearchResult.self))?.matches
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

    private var lastThreadKey: String? { environment.map { "thread.lastOpen." + $0 } }

    /// The app's current shell session, or nil while there is none. `environment` keys the remembered thread.
    func follow(_ shell: ShellSession?, environment: String?) {
        composer.follow(shell, environment: shell == nil ? self.environment : environment)
        guard let shell else { session?.detach(); self.shell = nil; return }
        if environment != self.environment { restored = false }
        self.shell = shell
        self.environment = environment
        // ServerController owns `onSnapshot`; chain after it.
        let previous = shell.onSnapshot
        shell.onSnapshot = { [weak self] snapshot in
            previous?(snapshot)
            self?.shellChanged(snapshot)
        }
        session?.attach(shell)
    }

    func open(_ id: ThreadId) {
        sidebar?.state.activeThreadId = id
        if let lastThreadKey { UserDefaults.standard.set(id.rawValue, forKey: lastThreadKey) }
        guard id != session?.threadId || panel.isDraft else { return }
        session?.end()
        panel.setDraft(projectTitle: nil)
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        composer.showThread(id)
        panel.setRightPanelOpen(rightPanelWasOpen(id))
        let session = ThreadSession(threadId: id, panel: panel, sidebar: sidebar)
        session.onProjection = { [weak self] projection in self?.composer.projectionChanged(projection, threadId: id) }
        if let shell { session.attach(shell) }
        self.session = session
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

    /// With the first shell: opens the `--open-thread` match or the remembered thread, else lands
    /// like T3's index route (`_chat.index.tsx:36-60`) in a draft for the most recently active project.
    private func shellChanged(_ snapshot: ShellSnapshot) {
        if let prefix = openPrefix, let match = snapshot.threads.first(where: { $0.title.hasPrefix(prefix) }) {
            openPrefix = nil
            restored = true
            open(match.id)
            return
        }
        guard !restored, openPrefix == nil else { return }
        restored = true
        guard session == nil, !panel.isDraft else { return }
        if let lastThreadKey, let raw = UserDefaults.standard.string(forKey: lastThreadKey),
           snapshot.threads.contains(where: { $0.id.rawValue == raw }) {
            open(ThreadId(raw))
        } else if let project = SidebarModel.sortProjectsForSidebar(snapshot.projects, threads: snapshot.threads, order: .updatedAt).first {
            _ = composer.newThread(in: project)
        }
    }
}
