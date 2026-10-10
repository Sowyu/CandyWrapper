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
    }

    /// Project title and workspace root from the shell (the worktree when the thread has one).
    private func place(_ projection: ThreadProjection?) -> (String, String?) {
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.threads.first { $0.id == threadId } ?? snapshot?.archivedThreads.first { $0.id == threadId }
        guard let projectId = projection?.thread.projectId ?? shell?.projectId,
              let project = snapshot?.projects.first(where: { $0.id == projectId }) else { return ("", nil) }
        return (project.title, projection?.thread.worktreePath ?? shell?.worktreePath ?? project.workspaceRoot)
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

    // ponytail: JSON round trips like ShellSession.decode; decode from the frame bytes if profiling shows it
    nonisolated static func decode(_ json: JSONValue) -> ThreadStreamItem? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(ThreadStreamItem.self, from: data)
    }

    nonisolated static func encode(_ input: SubscribeThreadInput) -> JSONValue {
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
    private weak var sidebar: SidebarContentView?
    private var session: ThreadSession?
    private var shell: ShellSession?
    private var environment: String?
    /// Development: `--open-thread <title prefix>` opens the first matching thread once the shell arrives.
    private var openPrefix: String?
    private var restored = false

    init(sidebar: SidebarContentView, window: NSWindow) {
        self.sidebar = sidebar
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-thread"), i + 1 < args.count { openPrefix = args[i + 1] }
        sidebar.actions.openThread = { [weak self] id in self?.open(id) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private var lastThreadKey: String? { environment.map { "thread.lastOpen." + $0 } }

    /// The app's current shell session, or nil while there is none. `environment` keys the remembered thread.
    func follow(_ shell: ShellSession?, environment: String?) {
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
        guard id != session?.threadId else { return }
        session?.end()
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        let session = ThreadSession(threadId: id, panel: panel, sidebar: sidebar)
        if let shell { session.attach(shell) }
        self.session = session
    }

    func close() {
        session?.end()
        session = nil
    }

    /// Opens the `--open-thread` match or the remembered thread with the first shell that lists it.
    private func shellChanged(_ snapshot: ShellSnapshot) {
        if let prefix = openPrefix, let match = snapshot.threads.first(where: { $0.title.hasPrefix(prefix) }) {
            openPrefix = nil
            restored = true
            open(match.id)
            return
        }
        guard !restored, openPrefix == nil else { return }
        restored = true
        guard session == nil, let lastThreadKey, let raw = UserDefaults.standard.string(forKey: lastThreadKey),
              snapshot.threads.contains(where: { $0.id.rawValue == raw }) else { return }
        open(ThreadId(raw))
    }
}
