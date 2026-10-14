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
    /// `onlyStreamingText`: the update only grew a streaming answer's or reasoning text.
    var onProjection: ((ThreadProjection?, _ onlyStreamingText: Bool) -> Void)?
    /// The store's sync status after each render (the composer's "Loading messages..." row).
    var onStatus: ((ThreadSyncStatus) -> Void)?

    private let relay: ShellSession.ChangeRelay
    /// Streaming deltas reach the panel at most 30 times a second, also on 120 Hz screens: 60 a second
    /// cost 30% of a core against 26.5% at 30 on a heavy thread, with text still appearing as it
    /// arrives (docs/perf/README.md, "Streaming text").
    private lazy var pacer = FramePacer(maxRate: 30) { [weak self] in Task { @MainActor in await self?.pull() } }

    /// T3 sends each streaming update twice, `message.updated` then `turn-item.updated` with the
    /// same text (assistantStreaming.ts:92-128), as separate stream values. While text streams,
    /// the first of a pair waits one frame for the second, so the pair costs one render instead of
    /// two. A change that opens the window with anything else (a turn ending, a send, an approval)
    /// renders at once, also right after a stream.
    // ponytail: a fixed 16 ms window, measured only with a replay proxy that sends the pair in one chunk; widen it or pair by item id if a live Codex stream still renders twice
    private func requestPull(streaming: Bool) {
        pacer.request(settle: streaming ? 1.0 / 60 : 0)
    }

    /// A closed thread's store and its change relay, kept so a reopen paints at once and resumes
    /// after the store's sequence instead of fetching a new snapshot.
    struct Retained {
        let store: ThreadStore
        let relay: ShellSession.ChangeRelay
        /// The last update the panel showed, painted in the same pass as the click on a reopen.
        var shown: ThreadUpdate? = nil
    }
    /// The last update rendered, kept for `Retained.shown`.
    private var shown: ThreadUpdate?

    init(threadId: ThreadId, panel: ThreadPanelView, sidebar: SidebarContentView?, retained: Retained? = nil, cache: ThreadCache? = nil) {
        self.threadId = threadId
        environmentId = threadId.environmentId ?? ""
        self.panel = panel
        self.sidebar = sidebar
        let relay = retained?.relay ?? ShellSession.ChangeRelay()
        self.relay = relay
        let store = retained?.store ?? ThreadStore(threadId: threadId.localId, cache: cache, environmentId: environmentId, onFirstChange: { relay.fire(streaming: $0) })
        self.store = store
        relay.setStreaming { [weak self] streaming in Task { @MainActor in self?.requestPull(streaming: streaming) } }
        panel.onLoadEarlier = { [weak self] in self?.loadEarlier() }
        shown = retained?.shown
        if retained != nil {
            Task { [weak self] in await self?.showRetained() }
        } else {
            // A cold open paints from the disk cache before the network; the store publishes it.
            Task { await store.restoreFromCache() }
        }
    }

    /// Paints the retained store's last shown update now, inside the click's pass, so a reopen
    /// goes from the old thread's frame to this one with nothing between. Call once the callbacks
    /// are set. The store's own state follows a moment later (`showRetained`).
    func paintRetained() {
        if let shown { render(shown) }
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
            panel?.lazyDiffPanel.set(\.loader, Self.diffLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.gitLoader, Self.gitDiffLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.refLoader, Self.baseRefLoader(shell.supervisor))
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
        return Retained(store: store, relay: relay, shown: shown)
    }

    /// The store calls `onChange` once per window between takes, so each pull renders every change since the last.
    private func pull() async {
        guard let update = await store.takeUpdate() else { return }
        OpenTiming.mark("panel pull", "\(update.projection?.visibleTurnItems.count ?? 0) rows")
        let changes = update.changes
        render(update, onlyStreamingText: changes.projectionChanged && changes.onlyStreamingText && !changes.reset)
    }

    private func render(_ update: ThreadUpdate, onlyStreamingText: Bool = false) {
        guard active, let panel else { return }
        shown = update
        let (projectTitle, workspaceRoot) = place(update.projection)
        OpenTiming.measure("panel setProjection") {
            panel.setProjection(update.projection, projectTitle: projectTitle, workspaceRoot: workspaceRoot, onlyStreamingText: onlyStreamingText)
        }
        panel.header.projectIcon = project(update.projection).map(ProjectIconSource.init)
        onProjection?(update.projection, onlyStreamingText)
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
            guard let request = await store.beginLoadEarlier() else {
                if self?.store === store { self?.historyLoad = nil }; return
            }
            do {
                let start = ContinuousClock.now
                try Task.checkCancellation()
                let page = try await http.get(request.path, token: token, as: ThreadHistoryPage.self)
                if OpenTiming.enabled {
                    // History pages come after first paint; they print on their own clock.
                    FileHandle.standardError.write(Data(String(
                        format: "thread-timing history page %.1f ms (fetch and decode), %d rows, more %@\n",
                        OpenTiming.ms(ContinuousClock.now - start), page.items.count, page.hasMoreHistory ? "yes" : "no").utf8))
                }
                try Task.checkCancellation()
                self?.historyLoad = nil
                await store.applyHistoryPage(page, requestCursor: request.cursor)
            } catch {
                // `attach` cancelled the request and already let go of it. Like T3's interrupt path
                // (threads.ts:733-741), the control becomes usable again, with no error and no stuck spinner.
                if Task.isCancelled {
                    await store.cancelHistoryLoad(requestCursor: request.cursor)
                    return
                }
                self?.historyLoad = nil
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

    /// `review.getDiffPreview` for the diff panel's Changes and Uncommitted scopes. A refusal reaches the panel,
    /// which shows its message over "No patch available" (DiffPanel.tsx:1074-1076 in Nightly 2994). Nightly 2994
    /// dropped 2861's retry at the server's cwd (2861 DiffPanel.tsx:354-374), which showed another repo's diff.
    nonisolated static func gitDiffLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.GitLoader {
        { cwd, baseRef, ignoreWhitespace in
            do {
                let json = try await supervisor.request(ReviewDiffPreview.method,
                                                        payload: ReviewDiffPreview.input(cwd: cwd, baseRef: baseRef, ignoreWhitespace: ignoreWhitespace))
                return try JSONDecoder().decode(ReviewDiffPreview.self, from: JSONEncoder().encode(json))
            } catch let error as RPCClientError {
                throw DiffLoadError(errorDescription: error.description)
            }
        }
    }

    /// `vcs.listRefs` for the Changes scope's comparison target menu; nothing on failure.
    nonisolated static func baseRefLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.RefLoader {
        { cwd, remote in
            guard let json = try? await supervisor.request(VcsRPC.listRefs, payload: VcsRPC.baseRefsInput(cwd: cwd, remote: remote)),
                  let result = try? JSONDecoder().decode(VcsListRefsResult.self, from: JSONEncoder().encode(json)) else { return [] }
            return result.refs
        }
    }

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
    private(set) var clones: ProjectCloneController!
    private(set) var scripts: ProjectScriptsController!
    private(set) var files: FilesController!
    private(set) var pullRequests: ThreadPullRequestsController!
    private(set) var browser: BrowserController!
    private var devices: DevicePanelController!
    private(set) var automations: ThreadAutomationsController!
    private var checkoutStatus: SidebarCheckoutStatus!
    private(set) var lineage: ThreadLineageController!
    /// Signed inline URLs of HTML renders and MCP Apps, by attachment id.
    private var webAssets: [String: (url: URL, expires: Date)] = [:]
    /// Runs whose Retry is in flight: one retry per failed run (ChatView.tsx:4047-4058).
    private var retryingPreparations: Set<RunId> = []
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
    /// When the open environment last entered connecting or reconnecting. T3's 2 s grace restarts each
    /// time (ChatView.tsx:2680-2697), so an error or offline spell doesn't skip the next grace.
    private var reconnectingSince: (id: String, since: Date)?
    private var bannerTimer: DispatchWorkItem?
    /// Server updates for every environment; the composer notice speaks for the open thread's.
    let serverUpdates: ServerUpdates
    /// The running update's notice offers "Disconnect server": a remote machine unavailable for 20 s.
    private var updateDisconnect = false
    private var disconnecting = false

    init(sidebar: SidebarContentView, window: NSWindow, environments: Environments) {
        self.sidebar = sidebar
        self.environments = environments
        serverUpdates = ServerUpdates(environments: environments)
        panel.projectIconForTitle = { [weak sidebar] title in
            sidebar?.snapshot?.projects.first { $0.title == title }.map(ProjectIconSource.init)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-thread"), i + 1 < args.count { openPrefix = args[i + 1] }
        if let i = args.firstIndex(of: "--perf-open"), i + 2 < args.count, let delay = Double(args[i + 1]) { perfOpen = (delay, args[i + 2]) }
        sidebar.actions.openThread = { [weak self] id in self?.open(id) }
        composer = ComposerController(panel: panel, sidebar: sidebar, environments: environments)
        PullRequestDetailBinding.savedLinks = { [weak sidebar] env in
            ((sidebar?.snapshot?.threads ?? []) + (sidebar?.snapshot?.archivedThreads ?? []))
                .filter { $0.id.environmentId == env }.flatMap { $0.pullRequests ?? [] }
        }
        PullRequestDetailBinding.serverSettings = { [weak composer] env in composer?.config(env).map { ServerSettingsValues($0.settings.raw) } }
        terminal = TerminalController(panel: panel, sidebar: sidebar, environments: environments)
        // `runShellCommand` (ChatView.tsx:5105-5116): a code block's command runs as a one-off project script.
        // ponytail: T3 passes the handler only when the thread has a project; runScript does nothing without a launch target
        panel.model.runShellCommand = { [weak self] command in
            self?.terminal.runScript(ProjectScript(id: "chat-code-block", name: "Chat code block", command: command))
        }
        git = GitController(panel: panel, sidebar: sidebar, environments: environments, composer: composer)
        automations = ThreadAutomationsController(panel: panel, environments: environments)
        clones = ProjectCloneController(panel: panel, environments: environments, composer: composer)
        composer.onTargetChange = { [weak self] in
            self?.hideNoActiveThread(); self?.git.refresh(); self?.automations.sync(); self?.clones.syncBanner(); self?.updateServerUpdateNotice()
            self?.onRouteChange?()
        }
        // The hover card's provider row (Sidebar.tsx:1354-1369, 466-469): the model's trigger label, with the
        // instance's name when instances need telling apart (`shouldShowInstanceBadge`), and earlier providers.
        sidebar.actions.hoverProvider = { [weak self] thread in
            guard let env = thread.id.environmentId, let providers = self?.composer.config(env)?.providers else { return nil }
            let catalog = ProviderCatalog(providers)
            let instance = SidebarModel.shellRuntime(thread) != nil ? thread.providerInstanceId : thread.modelSelection.instanceId
            let history = (thread.providerInstanceHistory ?? []).filter { $0 != instance }.map { catalog.entry($0)?.displayName ?? $0.rawValue }
            guard let entry = catalog.entry(instance) else { return nil }
            let model = entry.model(thread.modelSelection.model).map(ModelNames.trigger) ?? thread.modelSelection.model
            let badge = ProviderBadge.shows(entry, in: catalog)
            return (entry.driver, badge ? "\(model) \u{00B7} \(entry.displayName)" : model, history, badge ? ProviderBadge.accent(entry) : nil)
        }
        checkoutStatus = SidebarCheckoutStatus(environments: environments) { [weak sidebar] in sidebar?.checkoutBranchChanged() }
        sidebar.actions.checkoutBranch = { [weak self] env, cwd in self?.checkoutStatus.branch(environmentId: env, cwd: cwd) }
        // Scratch rows name their machine; the sidebar learns each environment's scratch folder from its config.
        composer.configObservers.append { [weak self, weak sidebar] env in
            guard let sidebar, let config = self?.composer.config(env) else { return }
            let root = config.scratchWorkspaceRoot.map(SidebarModel.normalizeProjectPath)
            if sidebar.state.scratchRoots[env] != root { sidebar.state.scratchRoots[env] = root }
        }
        lineage = ThreadLineageController(panel: panel)
        lineage.shells = { [weak sidebar] in (sidebar?.snapshot?.threads ?? []) + (sidebar?.snapshot?.archivedThreads ?? []) }
        lineage.dispatch = { [weak environments] id, payload in
            guard let environments else { throw Environments.CommandError.notConnected }
            return try await environments.dispatch(id, payload)
        }
        lineage.request = { [weak environments] env, method, payload in
            guard let environments else { throw Environments.CommandError.notConnected }
            return try await environments.request(env, method, payload)
        }
        lineage.openThread = { [weak self] id in self?.open(id) }
        lineage.localVisit = { [weak sidebar] id in sidebar?.state.localVisits[id] }
        lineage.acknowledgeWake = { [weak self, weak sidebar] id, time in
            sidebar?.state.localVisits[id] = time
            guard let self, let env = id.environmentId, self.composer.config(env)?.capabilities.contains("threadVisitedTracking") == true else { return }
            Task { _ = try? await self.environments.request(env, "orchestration.dispatchCommand", .object([
                "type": .string("thread.visit"), "commandId": .string(UUID().uuidString.lowercased()),
                "threadId": .string(id.localId.rawValue), "visitedAt": .string(time.raw)])) }
        }
        // HTML renders and MCP Apps: a signed inline URL per attachment, reused while it has 5 minutes left
        // (HtmlRenderFrame.tsx:62-92), and the app's RPCs on the open thread's environment.
        panel.model.webAssetURL = { [weak self] id, name in
            guard let self, let env = self.openThreadId?.environmentId, let shell = self.environments.session(env) else { return nil }
            if let hit = self.webAssets[id], hit.expires.timeIntervalSinceNow > 300 { return hit.url }
            let resource: JSONValue = .object(["_tag": .string("attachment"), "attachmentId": .string(id), "fileName": .string(name),
                                               "mimeType": .string("text/html"), "disposition": .string("inline")])
            guard let reply = try? await shell.supervisor.request("assets.createUrl", payload: .object(["resource": resource])),
                  let relative = reply["relativeUrl"]?.stringValue,
                  let url = URL(string: relative, relativeTo: shell.http.baseURL)?.absoluteURL else { return nil }
            let expires = reply["expiresAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date().addingTimeInterval(3600)
            self.webAssets[id] = (url, expires)
            return url
        }
        panel.model.onOpenHtmlRender = { [weak self] url, _ in self?.browser.openURL(url.absoluteString) }
        panel.model.onRetryWorkspacePreparation = { [weak self] runId in
            guard let self, let id = self.openThreadId, !self.retryingPreparations.contains(runId) else { return }
            self.retryingPreparations.insert(runId)
            Task { [weak self] in
                // `retryWorkspacePreparation` (client-runtime commands.ts:1011-1020); T3 only logs a failure.
                _ = try? await self?.environments.dispatch(id, .object([
                    "type": .string("prepared-run.retry"), "commandId": .string(UUID().uuidString.lowercased()),
                    "threadId": .string(id.localId.rawValue), "runId": .string(runId.rawValue)]))
                self?.retryingPreparations.remove(runId)
            }
        }
        panel.model.onOpenThread = { [weak self] local in
            guard let self, let env = self.openThreadId?.environmentId else { return }
            self.open(local.scoped(to: env))
        }
        panel.model.threadTitle = { [weak self, weak sidebar] local in
            guard let env = self?.openThreadId?.environmentId,
                  let shell = sidebar?.snapshot?.threads.first(where: { $0.id == local.scoped(to: env) }) else { return nil }
            let title = shell.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        panel.model.onOpenScheduledTask = { [weak self] taskId in
            guard let self, let env = self.openThreadId?.environmentId else { return }
            self.automations.openSettings?(env, taskId)
        }
        panel.model.mcpApp = McpAppActions(
            request: { [weak self] method, payload in
                guard let self, let env = self.openThreadId?.environmentId else { throw Environments.CommandError.notConnected }
                return try await self.environments.request(env, method, payload)
            },
            turnItem: { [weak self] thread, item in
                guard let self, let env = self.openThreadId?.environmentId else { return nil }
                let payload: JSONValue = .object(["threadId": .string(thread.rawValue), "itemId": .string(item.rawValue)])
                return try? await self.environments.request(env, "orchestration.getTurnItem", payload)["item"]
            },
            sendMessage: { [weak self] text in
                guard let self else { throw Environments.CommandError.notConnected }
                try await self.composer.sendAppMessage(text)
            })
        // `secrets.answerRequest` (SecretRequestCard.tsx:65-97): only the server's own secret and
        // authorization errors reach the card, so the typed value never shows.
        panel.model.answerSecret = { [weak self] input in
            guard let env = self?.openThreadId?.environmentId, let environments = self?.environments else { return SecretRequests.genericFailure }
            do {
                _ = try await environments.request(env, "secrets.answerRequest", input)
                return nil
            } catch let error as RPCClientError {
                return SecretRequests.failureMessage(tag: error.typedError?.tag, message: error.typedError?.message)
            } catch {
                return SecretRequests.genericFailure
            }
        }
        lineage.providers = { [weak composer] env in composer?.providers(env) ?? [] }
        lineage.selectedModel = { [weak composer] in composer?.selectedModel }
        composer.onModelChange = { [weak self] in self?.lineage.syncFooter() }
        files = FilesController(panel: panel, sidebar: sidebar, environments: environments)
        files.openThread = { [weak self] id in self?.open(id) }
        let prCapabilities = PullRequestCapabilities(environments: environments)
        pullRequests = ThreadPullRequestsController(panel: panel, sidebar: sidebar, environments: environments, capabilities: prCapabilities)
        pullRequests.openThreadId = { [weak self] in self?.openThreadId }
        automations.openThreadId = { [weak self] in self?.openThreadId }
        prCapabilities.onChange = { [weak self] in
            guard let self else { return }
            pullRequests.sync()
            // A deferred proactive link goes ahead once the capabilities are known.
            if let id = openThreadId, let thread = sidebar.snapshot?.threads.first(where: { $0.id == id }) {
                panel.proactiveLinkedPullRequestKey = pullRequests.proactiveKey(thread)
            }
        }
        browser = BrowserController(panel: panel, sidebar: sidebar, environments: environments, files: files)
        panel.timeline.worktreeSetup.onOpenTerminal = { [weak self] in
            guard let self, let id = self.panel.timeline.worktreeSetup.snapshot?.terminalId else { return }
            self.terminal.openExistingSetupTerminal(id)
        }
        terminal.openBrowserLink = { [weak self] url in self?.browser.openLink(url) ?? false }
        pullRequests.openIntegratedBrowser = { [weak self] url in self?.browser.openURL(url.absoluteString) }
        pullRequests.openBrowserLink = { [weak self] url in self?.browser.openLink(url) ?? false }
        devices = DevicePanelController(panel: panel, environments: environments, files: files)
        files.onSync = { [weak self] in self?.pullRequests.sync(); self?.browser.sync(); self?.terminal.panelChanged(); self?.devices.sync() }
        files.onTerminalTabsClosed = { [weak self] tabs in self?.terminal.panelTerminalsClosed(tabs) }
        files.onSaveAttachment = { [weak self] a in
            self?.panel.model.onOpenAttachment?(.object(["type": .string("file"), "id": .string(a.id), "name": .string(a.name),
                                                         "mimeType": .string(a.mimeType), "sizeBytes": .number(Double(a.sizeBytes))]), true)
        }
        scripts = ProjectScriptsController(panel: panel, sidebar: sidebar, composer: composer, terminal: terminal)
        scripts.openProjectSettings = { [weak sidebar] key in sidebar?.actions.openProjectSettings(key) }
        scripts.readFile = { [weak environments] env, cwd, path in
            guard let reply = try? await environments?.request(env, "projects.readFile", .object(["cwd": .string(cwd), "relativePath": .string(path)])),
                  let contents = reply["contents"]?.stringValue else { return nil }
            return (contents, reply["truncated"] == .bool(true))
        }
        // `runProjectScript` (ChatView.tsx:5059-5075): a script with `autoOpenPreview` opens its URL in the browser panel
        // once its command is written.
        terminal.onScriptStarted = { [weak self] script in
            guard let self, script.autoOpenPreview == true, let raw = script.previewUrl, self.panel.browserAvailable else { return }
            guard let url = PreviewURL.normalize(raw) else {
                self.panel.toasts.show(ToastView(title: "Could not open preview", message: "An unexpected error occurred.", kind: .error))
                return
            }
            self.browser.openURL(url)
        }
        panel.confirmCloseTerminalTab = { [weak self] surface, close in self?.terminal.confirmCloseSurface(surface, then: close) }
        panel.lazyDiffPanel.configure { [weak self] diff in
            diff.onDeleteReviewComment = { [weak self] id in self?.composer.deleteReviewComment(id) }
            diff.onReviewComment = { [weak self] record in self?.composer.addReviewComment(record) }
        }
        panel.lazyFileSurface.configure { [weak self] file in
            file.onReviewComment = { [weak self] record in self?.composer.addReviewComment(record) }
            file.onDeleteReviewComment = { [weak self] id in self?.composer.deleteReviewComment(id) }
            file.onUpdateReviewComment = { [weak self] record in self?.composer.updateReviewComment(record) }
        }
        terminal.onAddToChat = { [weak self] selection in self?.composer.addTerminalContext(selection) }
        clones.openProject = { [weak self, weak sidebar] id in
            guard let self, let project = sidebar?.snapshot?.projects.first(where: { $0.id == id }) else { return }
            self.newThread(in: project)
        }
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
        sidebar.actions.openPullRequestURL = { [weak self, weak sidebar] id, url in
            guard let self, let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }) else { return }
            self.open(id)
            if let link = (thread.pullRequests ?? []).first(where: { $0.url == url }) {
                self.pullRequests.open(link)
            } else {
                self.pullRequests.openCurrentPullRequest()
            }
        }
        // Cite inserts the chip, then opens its comment under the selection (ChatComposer.tsx:6435-6440,
        // AssistantCitationChip.tsx:167-240). Save rewrites the chip, Save and send also submits, Cancel removes it.
        panel.model.onCiteSelection = { [weak self] messageId, selection, anchor in
            guard let self, let id = self.openThreadId, let env = id.environmentId else { return }
            let citation = ThreadAssistantCitation.selection(environmentId: env, threadId: id.localId.rawValue, messageId: messageId, selection: selection)
            let composer = self.panel.composer
            // A composer that takes no text gets no chip and no comment (ChatView.tsx:1849-1862).
            guard composer.acceptsInsertion else {
                self.panel.toasts.show(ToastView(title: "The composer is not ready",
                                                 message: "Try citing the selection after the connection or pending input is resolved.", kind: .warning))
                return
            }
            composer.insertAtCaret(citation.markdown + " ")
            var current = citation.markdown
            func replace(_ with: String) {
                var text = composer.text
                guard let range = text.range(of: current + " ") ?? text.range(of: current) else { return }
                text.replaceSubrange(range, with: with.isEmpty ? "" : with + " ")
                composer.text = text
                current = with
            }
            AssistantCitationCommentPopup.present(citation, anchor: anchor, save: { edited, send in
                replace(edited.markdown)
                if send { composer.submit() }
            }, remove: { replace("") }, restoreFocus: { composer.focus() })
        }
        // Save to workspace (ProposedPlanCard.tsx:105-163): `projects.writeFile` under the thread's workspace root.
        panel.model.onSavePlanToWorkspace = { [weak self] contents, filename in
            guard let self, let window = self.panel.window, let id = self.openThreadId, let env = id.environmentId else { return }
            guard let root = self.panel.model.workspaceRoot else {
                self.panel.toasts.show(ToastView(title: "Workspace path is unavailable",
                                                 message: "This thread does not have a workspace path to save into.", kind: .error))
                return
            }
            ProposedPlanSaveDialog.present(in: window, workspaceRoot: root, filename: filename, save: { [weak self] path in
                guard let self, let shell = self.environments.session(env) else { return false }
                do {
                    let reply = try await shell.supervisor.request("projects.writeFile", payload: .object(
                        ["cwd": .string(root), "relativePath": .string(path), "contents": .string(contents)]))
                    self.panel.toasts.show(ToastView(title: "Plan saved to workspace", message: reply["relativePath"]?.stringValue ?? path, kind: .success))
                    return true
                } catch {
                    self.panel.toasts.show(ToastView(title: "Could not save plan", message: "\(error)", kind: .error))
                    return false
                }
            }, emptyPath: { [weak self] in
                self?.panel.toasts.show(ToastView(title: "Enter a workspace path", kind: .warning))
            })
        }
        // The file chip menu's shell items: only on this Mac's environment (`canUseMarkdownFileShellActions`,
        // ChatMarkdown.tsx:255-261, the "local-exec" open mode).
        MarkdownView.fileChipShell = { [weak self] in
            guard let self, let env = self.openThreadId?.environmentId, env == self.environments.primaryId,
                  let config = self.composer.config(env) else { return (nil, nil) }
            let editor = OpenInEditors.preferred(available: config.availableEditors, last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey))
            return (OpenInEditors.menuLabel(editor), OpenInEditors.revealLabel(config))
        }
        MarkdownView.onOpenFileInEditor = { [weak self] meta in
            guard let self, let env = self.openThreadId?.environmentId, let config = self.composer.config(env),
                  let editor = OpenInEditors.preferred(available: config.availableEditors, last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey))
            else { return }
            self.shellOpen(env, OpenInEditors.launchInput(cwd: meta.targetPath, editor: editor), failure: "Unable to open file")
        }
        // ponytail: reveals `filePath` as written; T3 first resolves a bare basename against the workspace. Add the lookup if bare names miss
        MarkdownView.onRevealFile = { [weak self] meta in
            guard let self, let env = self.openThreadId?.environmentId else { return }
            self.shellOpen(env, OpenInEditors.launchInput(cwd: meta.filePath, editor: "file-manager", reveal: true), failure: "Unable to reveal file")
        }
        // Media and browser documents in chat Markdown (ChatMarkdown.tsx:2545-2590, 3270-3290): host files load
        // through signed asset URLs on the open thread's environment.
        // Tool output images (`tool-output-image`, V2ItemInspector.tsx:149-158) sign the same way.
        MarkdownImages.assetURL = { [weak self] path in
            guard let id = self?.openThreadId else { return nil }
            return await MarkdownImages.signedURL(resource: .object(["_tag": .string("media-file"), "threadId": .string(id.localId.rawValue), "path": .string(path)]))
        }
        MarkdownImages.resourceURL = { [weak self] resource in
            guard let self, let env = self.openThreadId?.environmentId, let shell = self.environments.session(env) else { return nil }
            guard let reply = try? await shell.supervisor.request("assets.createUrl", payload: .object(["resource": resource])),
                  let relative = reply["relativeUrl"]?.stringValue,
                  let url = URL(string: relative, relativeTo: shell.http.baseURL)?.absoluteURL else { return nil }
            let size = reply["imageDimensions"].flatMap { d in
                d["width"]?.doubleValue.flatMap { w in d["height"]?.doubleValue.map { CGSize(width: w, height: $0) } }
            }
            return (url, size)
        }
        MarkdownImages.openInFileViewer = { [weak self] relative in self?.files.openFile(relative, line: nil) }
        MarkdownView.canOpenFileInBrowser = { [weak self] in self?.openThreadId != nil && self?.panel.browserAvailable == true }
        // `openFileInPreview` (browser/openFileInPreview.ts:117-160): inside the workspace the page may load its siblings.
        MarkdownView.onOpenFileInBrowser = { [weak self] meta in
            guard let self, let id = self.openThreadId, let env = id.environmentId, let shell = self.environments.session(env) else { return }
            let tag = meta.workspaceRelativePath != nil ? "workspace-file" : "media-file"
            let resource: JSONValue = .object(["_tag": .string(tag), "threadId": .string(id.localId.rawValue), "path": .string(meta.filePath)])
            Task { [weak self] in
                guard let self else { return }
                if let reply = try? await shell.supervisor.request("assets.createUrl", payload: .object(["resource": resource])),
                   let relative = reply["relativeUrl"]?.stringValue,
                   let url = URL(string: relative, relativeTo: shell.http.baseURL)?.absoluteURL {
                    guard self.openThreadId == id else { return }
                    self.browser.openURL(url.absoluteString)
                } else {
                    self.panel.toasts.show(ToastView(title: "Unable to open file in browser", message: "An error occurred.", kind: .error))
                }
            }
        }
        MarkdownView.onOpenCitation = { [weak self] citation in
            self?.open(ThreadId(rawValue: citation.threadId).scoped(to: citation.environmentId))
            self?.panel.timeline.revealFindEntry(citation.messageId)
        }
        composer.openThread = { [weak self] id in self?.open(id) }
        composer.onNewThread = { [weak self] in self?.newThread() }
        sidebar.actions.newThread = { [weak self] in self?.newThread() }
        // Files dropped on a row open its thread and attach there (`handleThreadFileDrop`, Sidebar.tsx:3163-3187).
        sidebar.actions.dropFiles = { [weak self] id, urls in
            guard let self else { return }
            self.open(id)
            guard self.openThreadId == id else { return }
            self.composer.attachDroppedFiles(urls)
        }
        sidebar.actions.openDraft = { [weak self] id in
            guard let self, composer.openDraft(id) else { return }
            session?.end()
            session = nil
            lineage.update(threadId: nil, projection: nil)
            terminal.show(nil)
            scripts.show(nil)
            files.show(nil)
        }
        sidebar.actions.discardDraft = { [weak self] id in self?.composer.discardDraft(id) }
        sidebar.actions.searchThreads = { [weak environments] query in await environments?.searchThreads(query) }
        environments.onSessionChange = { [weak self] env in self?.sessionChanged(env) }
        environments.onShell = { [weak self] snapshot in self?.shellChanged(snapshot) }
        environments.onRemove = { [weak self] env in self?.environmentRemoved(env) }
        environments.observe { [weak self] in self?.updateEnvironmentBanner() }
        serverUpdates.observe { [weak self] in self?.updateEnvironmentBanner() }
        serverUpdates.continueThreads = { [weak composer] env in composer?.config(env)?.settings.raw["continueThreadsAfterServerUpdate"]?.boolValue == true }
        panel.onServerUpdateAction = { [weak self] index in self?.serverUpdateAction(index) }
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
        scripts.registerShortcuts(shortcuts)
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
        // `rightPanel.toggleMaximized` (ChatView.tsx:8079-8084): no default key, ignored on repeat.
        shortcuts.on("rightPanel.toggleMaximized") { [weak self] call in
            guard let self, self.panel.window != nil else { return false }
            if !call.isRepeat { self.panel.toggleMaximized() }
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
            sidebar.navigated(to: target)
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
        migrationToast.sessionChanged(environmentId)
        permissionNotice.sessionChanged(environmentId)
        serverUpdates.sessionChanged(environmentId)
        composer.sessionChanged(environmentId)
        terminal.sessionChanged(environmentId)
        clones.sessionChanged(environmentId)
        git.sessionChanged(environmentId)
        browser.sessionChanged(environmentId)
        guard let session, session.environmentId == environmentId else { return }
        if let shell = environments.session(environmentId) { session.attach(shell) } else { session.detach() }
    }

    func forceReload() {
        retained.removeAll()
        files.forceReload()
        guard let id = session?.threadId, !panel.isDraft else { return }
        open(id, force: true)
    }

    func open(_ id: ThreadId, force: Bool = false) {
        sidebar?.state.activeThreadId = id
        UserDefaults.standard.set(id.rawValue, forKey: Self.lastThreadKey)
        guard force || id != session?.threadId || panel.isDraft || noActiveThread.superview != nil else { return }
        OpenTiming.begin(id.rawValue)
        ImageTiming.mark("open", id.rawValue)
        hideNoActiveThread()
        let previousEnvironment = panel.isDraft ? nil : session?.environmentId
        session?.end()
        // The panel keeps painting until the new thread's first projection replaces it in one pass
        // (`beginThreadSwitch`); clearing it here showed an empty window for a frame or more.
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.threads.first { $0.id == id } ?? snapshot?.archivedThreads.first { $0.id == id }
        let keepRows = !force && previousEnvironment == id.environmentId
        if let shell {
            let project = snapshot?.projects.first { $0.id == shell.projectId }
            panel.beginThreadSwitch(projectTitle: project?.title ?? "", threadTitle: shell.title, keepRows: keepRows)
            panel.header.projectIcon = project.map(ProjectIconSource.init)
        } else {
            // No shell yet (a link before the first snapshot): T3 renders nothing (ThreadRouteView.tsx:181).
            panel.setDraft(projectTitle: nil)
            panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        }
        composer.showThread(id)
        files.show(id)
        let kept = force ? nil : (takeRetained(id) ?? keepAlive?.take(id))
        // Held rows keep their lineage header and footer; the first projection resets them.
        if !keepRows || shell == nil { lineage.update(threadId: id, projection: nil) }
        let session = ThreadSession(threadId: id, panel: panel, sidebar: sidebar, retained: kept, cache: force ? nil : environments.threadCache)
        var observedLink: ThreadLinkedPullRequest?
        session.onProjection = { [weak self] projection, onlyStreamingText in
            // A token changes no run, request, plan or relationship: only find needs the new text.
            if onlyStreamingText {
                self?.composer.projectionTextChanged(projection, threadId: id)
                return
            }
            if let self {
                let thread = self.sidebar?.snapshot?.threads.first { $0.id == id }
                let link = thread?.linkedPullRequest ?? thread?.branchPullRequest
                self.pullRequests.followLink(from: observedLink, to: link)
                observedLink = link
                self.panel.onProactivePullRequest = { [weak self] in self?.pullRequests.openProactive() }
                self.panel.proactiveLinkedPullRequestKey = thread.flatMap { self.pullRequests.proactiveKey($0) }
            }
            self?.composer.projectionChanged(projection, threadId: id)
            self?.lineage.update(threadId: id, projection: projection)
        }
        session.onStatus = { [weak self] status in self?.composer.threadStatusChanged(status, threadId: id) }
        if let shell = environments.session(id.environmentId) { session.attach(shell) }
        self.session = session
        session.paintRetained()
        // composer.showThread fired onTargetChange before the session was set, so sync now.
        automations.sync()
        terminal.show(id)
        scripts.show(id)
        updateEnvironmentBanner()
        if openDiff {
            openDiff = false
            panel.opensChangedTurnOnLoad = true
        }
        // The thread left behind may still run: it streams on in the background.
        keepAlive?.update()
    }

    /// `shell.openInEditor` with T3's error toast (ChatMarkdown.tsx:1950-1990, 2038-2075).
    private func shellOpen(_ environmentId: String, _ input: JSONValue, failure title: String) {
        Task { [weak self] in
            do {
                _ = try await self?.environments.request(environmentId, "shell.openInEditor", input)
            } catch {
                let message = (error as? RPCClientError)?.typedError?.fields["message"]?.stringValue ?? "An error occurred."
                self?.panel.toasts.show(ToastView(title: title, message: message, kind: .error))
            }
        }
    }

    /// Running threads' streams while they are not open (`RunningThreadKeepAlive`).
    var keepAlive: RunningThreadKeepAlive?

    func takeRetained(_ id: ThreadId) -> ThreadSession.Retained? {
        retained.firstIndex { $0.id == id }.map { retained.remove(at: $0).store }
    }

    /// Keeps a closed thread's store for 5 minutes, like T3. Only the newest few: a huge thread's
    /// bounded window holds about 12 MB (900 runs, 3,600 nodes).
    // ponytail: count cap of 2, no byte budget; weigh retained stores by snapshot size if memory reviews flag it
    private func retain(_ old: ThreadSession) {
        retainStore(old.threadId, old.end())
    }

    func retainStore(_ id: ThreadId, _ store: ThreadSession.Retained) {
        retained.removeAll { $0.id == id }
        retained.append((id, store, Date().addingTimeInterval(Self.retention)))
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
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
        files.show(nil)
        keepAlive?.update()
    }

    /// The thread the panel shows, nil on a draft (the route's thread in T3).
    var openThreadId: ThreadId? { panel.isDraft ? nil : session?.threadId }

    /// The thread view is back after Settings or a utility page: T3 mounts ChatView again, which focuses
    /// the composer unless the terminal is open (ChatView.tsx:6837-6845).
    func focusComposerOnReturn() {
        if !panel.terminalOpen { composer.focusComposer() }
    }

    private var visits = ThreadVisitTracker()
    private var visitTimer: DispatchWorkItem?
    private var visitViewShown = false

    /// ChatView's visit effect (ChatView.tsx:2938-3000) for the open thread while the thread view shows:
    /// a visit clears the row's Done and Woke marks. Runs on every shell change and route change.
    func syncVisit() {
        visitTimer?.cancel()
        visitTimer = nil
        // In a window counts as shown, minimized or covered too: T3's visit effect has no visibility
        // gate (ChatView.tsx:2938-3000), so the open thread is visited as activity lands in either app.
        let shown = panel.window != nil
        // Settings and Usage unmount ChatView in T3, so its per-watermark dedupe starts over on the way back.
        if shown, !visitViewShown { visits.reset() }
        visitViewShown = shown
        guard shown, let id = openThreadId, let sidebar,
              let shell = sidebar.snapshot?.threads.first(where: { $0.id == id }) else { return }
        let now = TimestampFormat.nowMs()
        switch visits.decide(shell, routeKey: id.rawValue, local: sidebar.state.localVisits[id], nowMs: now) {
        case .none: break
        case .local(let time): sidebar.state.localVisits[id] = time
        case .dispatch(let time, let delay):
            let send: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.visits.didDispatch(shell, routeKey: id.rawValue, nowMs: TimestampFormat.nowMs())
                Task { _ = try? await self.environments.dispatch(id, ThreadCommands.visit(id.localId, visitedAt: time)) }
            }
            guard delay > 0 else { return send() }
            let work = DispatchWorkItem { MainActor.assumeIsolated { send() } }
            visitTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: work)
        }
    }

    func close() {
        session?.end()
        session = nil
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
        files.show(nil)
        keepAlive?.update()
    }

    /// "<label> is reconnecting|offline" over the composer while the open thread's environment is not
    /// connected (ChatView.tsx:2668-2750, 3091-3142): reconnecting shows after a 2 s grace
    /// (`ENVIRONMENT_RECONNECT_WARNING_GRACE_MS`), "Disconnect server" after 20 s on a remote machine
    /// (`useEnvironmentDisconnectDelay`). No session (the local server stopped while idle) shows nothing.
    private func updateEnvironmentBanner() {
        bannerTimer?.cancel()
        bannerTimer = nil
        updateDisconnect = false
        defer { updateServerUpdateNotice() }
        let banner = panel.environmentBanner
        guard let id = session?.environmentId, let state = environments.state(id),
              state.status != .connected, state.status != .available else {
            bannerEnvironment = nil
            reconnectingSince = nil
            panel.showsEnvironmentBanner = false
            return
        }
        if bannerEnvironment?.id != id { bannerEnvironment = (id, Date()) }
        let elapsed = Date().timeIntervalSince(bannerEnvironment!.since)
        let reconnecting = state.status == .connecting || state.status == .reconnecting
        if !reconnecting { reconnectingSince = nil } else if reconnectingSince?.id != id { reconnectingSince = (id, Date()) }
        let reconnectingFor = reconnectingSince.map { Date().timeIntervalSince($0.since) } ?? 0
        let remote = id != environments.primaryId
        var wake: TimeInterval?
        // The server restarts during an update, and the update notice already shows it (ChatView.tsx:3116-3121).
        // Its "Disconnect server" comes after the same 20 s on a remote machine (`disconnectAction`, :3096-3109).
        if reconnecting && serverUpdates.state(id).isRunning {
            panel.showsEnvironmentBanner = false
            updateDisconnect = remote && elapsed >= 20
            if remote && elapsed < 20 { wake = 20 - elapsed }
        } else if reconnecting && reconnectingFor < 2 {
            panel.showsEnvironmentBanner = false
            wake = 2 - reconnectingFor
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

    /// The open thread's server version item (ChatView.tsx:3060-3222): "Server update available" while the
    /// server runs an older T3 and nobody dismissed that pair of versions, then the update's progress or failure.
    private func updateServerUpdateNotice() {
        guard let id = session?.environmentId ?? composer.targetEnvironmentId else { panel.serverUpdateNotice = nil; return }
        let state = serverUpdates.state(id)
        let label = environments.environmentIds.count > 1 ? "\(environments.label(id) ?? id) server" : "server"
        let mismatch = serverUpdates.mismatch(id)
        let show: Bool
        switch state {
        case .idle: show = mismatch != nil && !serverUpdates.isDismissed(id)
        case .running: show = true
        case .failed: show = !serverUpdates.isFailureDismissed(id)
        }
        guard show else { panel.serverUpdateNotice = nil; return }
        let caps = serverUpdates.capabilities(id)
        let offer = serverUpdates.offer(id, serverLabel: label)
        var action: String?
        var guidance: String?
        switch offer {
        case .update?: action = state.isFailed ? "Retry" : "Update"
        case .manual(let manual)?: action = manual.label
        case .desktopManual?, nil: break
        }
        if guidance == nil, let cap = caps.selfUpdate, cap != .desktopManaged || !caps.desktopAppUpdate { guidance = ServerUpdateCopy.guidance(cap) }
        let status: ComposerServerUpdateNotice.Status
        switch state {
        case .running(let stage, _, _): status = .running(stage)
        case .failed(_, _, _, let message): status = .failed(message)
        case .idle: status = .available(serverVersion: mismatch?.server ?? "", clientVersion: mismatch?.client ?? "")
        }
        var actionEnabled = true
        if case .update? = offer { actionEnabled = serverUpdates.canUpdate(id) }
        if state.isRunning { action = updateDisconnect && session?.environmentId == id ? "Disconnect server" : nil; actionEnabled = !disconnecting }
        panel.serverUpdateNotice = ComposerServerUpdateNotice(serverLabel: label, status: status, guidance: state == .idle ? guidance : nil,
                                                              action: action, actionEnabled: actionEnabled,
                                                              actionTooltip: state.isRunning ? "Hide this server's threads. Switch it on again in Connections." : nil,
                                                              dismissible: state.isFailed || serverUpdates.dismissalKey(id) != nil)
    }

    private func serverUpdateAction(_ index: Int?) {
        guard let id = session?.environmentId ?? composer.targetEnvironmentId, let notice = panel.serverUpdateNotice else { return }
        guard index != nil else { return serverUpdates.dismiss(id) }
        if case .running = notice.status { return disconnect(id) }
        switch serverUpdates.offer(id, serverLabel: notice.serverLabel) {
        case .update?: serverUpdates.request(id, serverLabel: notice.serverLabel)
        case .manual(let manual)?:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(manual.command, forType: .string)
            panel.toasts.show(ToastView(title: manual.toastTitle, message: manual.toastDescription, kind: .success))
        default: break
        }
    }

    /// "Disconnect server": switches the machine off and goes to the index, as T3 navigates to "/".
    private func disconnect(_ environmentId: String) {
        panel.environmentBanner.disconnect.isEnabled = false
        disconnecting = true
        updateServerUpdateNotice()
        Task {
            defer { panel.environmentBanner.disconnect.isEnabled = true; disconnecting = false; updateServerUpdateNotice() }
            do {
                try await environments.setEnabled(environmentId, false)
            } catch {
                // ChatView.tsx:2730-2744: the error's message, else T3's fallback.
                let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription
                panel.toasts.show(ToastView(title: "Could not disconnect server", message: message ?? "Failed to disconnect.", kind: .error))
                return
            }
            if session?.environmentId == environmentId { landOnIndex() }
        }
    }

    /// Like T3's index route: a draft for the most recently active project, else nothing.
    func landOnIndex() {
        session?.end()
        session = nil
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
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
        keepAlive?.drop(environmentId: environmentId)
        composer.environmentRemoved(environmentId)
        checkoutStatus.environmentRemoved(environmentId)
        terminal.environmentRemoved(environmentId)
        clones.environmentRemoved(environmentId)
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
    /// `NoProjectsHero` over the thread panel while no environment has a project (_chat.index.tsx:84-88).
    private(set) lazy var noProjectsHero: SidebarNoProjectsHeroView = {
        let hero = SidebarNoProjectsHeroView()
        hero.autoresizingMask = [.width, .height]
        return hero
    }()
    /// The legacy thread migration toast on the primary environment.
    lazy var permissionNotice: ThreadPermissionUpdateNotice = {
        let notice = ThreadPermissionUpdateNotice(environments: environments, toasts: panel.toasts)
        notice.onGrants = { [weak self] _ in
            self?.composer.grantsChanged()
            self?.serverUpdates.changed()
        }
        return notice
    }()
    private lazy var migrationToast = LegacyThreadMigrationToast(environments: environments, toasts: panel.toasts)
    /// Whether an environment offers threads without a project, for the hero's second button.
    var offersScratch: () -> Bool = { false }
    /// The panel moved to another thread or draft (route history).
    var onRouteChange: (() -> Void)?

    private func updateNoProjectsHero(_ snapshot: ShellSnapshot) {
        let show = snapshot.projects.isEmpty
        guard show || noProjectsHero.superview != nil else { return }
        if show {
            noProjectsHero.offersScratch = offersScratch()
            if noProjectsHero.superview !== panel {
                noProjectsHero.frame = panel.bounds
                panel.addSubview(noProjectsHero)
            }
        } else {
            noProjectsHero.removeFromSuperview()
        }
    }

    /// `NoActiveThreadState` over the thread panel: the chat surface with no thread (ChatView.tsx:10958-10961).
    private(set) lazy var noActiveThread: NoActiveThreadStateView = {
        let view = NoActiveThreadStateView()
        view.autoresizingMask = [.width, .height]
        return view
    }()
    /// The open thread once a shell listed it, so a thread launched a moment ago is not taken for a deleted one.
    private var seenOpenThread: ThreadId?

    private func hideNoActiveThread() {
        guard noActiveThread.superview != nil else { return }
        noActiveThread.removeFromSuperview()
    }

    /// The open thread left its environment's shell (deleted from another client). T3 reads the route as
    /// "missing" and goes to "/" while the environment still has threads (ThreadRouteView.tsx:144-158,
    /// threadRoutes.ts:23-39); with none left the chat surface has no thread and shows `NoActiveThreadState`.
    private func dropMissingThread(_ snapshot: ShellSnapshot) {
        guard let id = session?.threadId, let env = id.environmentId else { return }
        let listed = snapshot.threads.contains { $0.id == id } || snapshot.archivedThreads.contains { $0.id == id }
        if listed { seenOpenThread = id }
        let outcome = MissingThreadRoute.resolve(shellLoaded: environments.hasShell(env), listed: listed, seenBefore: seenOpenThread == id,
                                                 environmentHasThreads: snapshot.threads.contains { $0.id.environmentId == env })
        guard outcome != .keep else { return }
        seenOpenThread = nil
        if UserDefaults.standard.string(forKey: Self.lastThreadKey) == id.rawValue { UserDefaults.standard.removeObject(forKey: Self.lastThreadKey) }
        if outcome == .landOnIndex {
            landOnIndex()
            return
        }
        session?.end()
        session = nil
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
        files.show(nil)
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        sidebar?.state.activeThreadId = nil
        noActiveThread.frame = panel.bounds
        // Under `NoProjectsHero` when that shows too.
        if noProjectsHero.superview === panel {
            panel.addSubview(noActiveThread, positioned: .below, relativeTo: noProjectsHero)
        } else {
            panel.addSubview(noActiveThread)
        }
    }

    private func shellChanged(_ snapshot: ShellSnapshot) {
        defer { syncVisit() }
        updateNoProjectsHero(snapshot)
        dropMissingThread(snapshot)
        composer.projectsChanged()
        git.refresh()
        files.shellChanged()
        scripts.refresh()
        pullRequests.sync()
        lineage.sync()
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
