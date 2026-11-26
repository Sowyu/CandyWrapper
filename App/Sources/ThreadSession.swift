import AppKit
import os
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
    private var citation: (messageId: String, pages: Int)?
    private var familyLease: UUID?
    /// False once another thread took the panel.
    private var active = true
    /// After each projection the panel shows (the composer reads runs and requests from it).
    /// `onlyStreamingText`: the update only grew a streaming answer's or reasoning text.
    var onProjection: ((ThreadProjection?, _ onlyStreamingText: Bool) -> Void)?
    /// The store's sync status after each render (the composer's "Loading messages..." row).
    var onStatus: ((ThreadSyncStatus) -> Void)?

    /// A linked environment's thread, read through `via`, the environment whose shell this session attaches to
    /// (5258 client-runtime state/peerLinks.ts:75-101): `peerLinks.subscribeThread`, `threadHistoryPage` and
    /// `threadItem` stand in for the thread's own calls, and nothing that would act on the thread is wired.
    struct LinkedSource: Equatable {
        let via: String
        /// The linked environment the thread lives in.
        let environmentId: String
    }
    private let linked: LinkedSource?
    /// A linked read failed (the error) or a value arrived again (nil), for the pane's notice.
    var onLinkedFailure: ((RPCClientError?) -> Void)?
    private var linkedRetry: Task<Void, Never>?

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

    init(threadId: ThreadId, panel: ThreadPanelView, sidebar: SidebarContentView?, retained: Retained? = nil, cache: ThreadCache? = nil,
         linked: LinkedSource? = nil) {
        self.threadId = threadId
        self.linked = linked
        environmentId = threadId.environmentId ?? ""
        self.panel = panel
        self.sidebar = sidebar
        let relay = retained?.relay ?? ShellSession.ChangeRelay()
        self.relay = relay
        let store = retained?.store ?? ThreadStore(threadId: threadId.localId, cache: cache, environmentId: environmentId, onFirstChange: { relay.fire(streaming: $0) }, onRequestsResolved: QuestionDraftResolution.sink(threadId))
        self.store = store
        relay.setStreaming { [weak self] streaming in Task { @MainActor in self?.requestPull(streaming: streaming) } }
        panel.onLoadEarlier = { [weak self] in self?.loadEarlier() }
        panel.model.onLoadDeferredWork = { [weak self] anchors in await self?.loadDeferredWork(anchors) ?? false }
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
        if let linked { return attachLinked(shell, linked) }
        subscription?.cancel()
        historyLoad?.cancel()
        historyLoad = nil
        if let familyLease { self.shell?.releaseFamily(familyLease) }
        self.shell = shell
        familyLease = shell.retainFamily(threadId.localId)
        if active {
            panel?.lazyDiffPanel.set(\.loader, Self.diffLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.gitLoader, Self.gitDiffLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.fileContentsLoader, Self.diffFileContentsLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.refLoader, Self.baseRefLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.commitLoader, Self.commitDiffLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.branchCommitsLoader, Self.branchCommitsLoader(shell.supervisor))
            panel?.lazyDiffPanel.set(\.toolCallLoader, Self.toolCallDiffLoader(shell.supervisor))
            panel?.model.turnItemLoader = Self.turnItemLoader(shell.supervisor)
            let supervisor = shell.supervisor
            panel?.model.commandOutput = { thread, item, receive in
                supervisor.subscribe("orchestration.subscribeCommandOutput", payload: {
                    .object(["threadId": .string(thread), "itemId": .string(item)])
                }, handler: { event in
                    switch event {
                    case .value(let value):
                        do { let frame = try value.decode(as: CommandOutputFrame.self); await receive(.success(frame)) }
                        catch { await receive(.failure(error)) }
                    case .interrupted(let error): await receive(.failure(error))
                    case .subscribed: break
                    }
                })
            }
        }
        let store = self.store
        let wireSubscription = UUID()
        let loader = ThreadSnapshotLoader(http: shell.http, token: shell.token, threadId: threadId.localId)
        let supervisor = shell.supervisor, configFeed = shell.configFeed
        subscription = supervisor.subscribe("orchestration.subscribeThread", resubscribesOnActivation: true, keepsRetryingServerFailures: true, payload: {
            if await store.subscribeInput(subscription: wireSubscription).afterSequence == nil {
                if let snapshot = await loader.coldOpen(supervisor: supervisor, config: configFeed),
                   !Task.isCancelled {
                    await store.applySnapshot(snapshot, subscription: wireSubscription)
                }
            }
            return ThreadSession.encode(await store.subscribeInput(subscription: wireSubscription))
        }, handler: { event in
            guard case .value(let json) = event else { return }
            try await ThreadSession.applyWire(json, to: store, subscription: wireSubscription)
        })
    }

    /// `followLinkedThread` (5258 linkedThread.ts:283-453): every subscription starts from the linked environment's
    /// snapshot, since `PeerLinkThreadInput` takes no resume cursor. An unreachable environment is asked again after
    /// 15 s with what was read kept; any other failure ends the stream until Try again.
    /// A resubscribe's snapshot holds only the latest turns, so the rows read before it come back by paging to the oldest
    /// one again (`restoreThrough`, linkedThread.ts:318-367), the way T3 recovers a newer snapshot's window.
    private func attachLinked(_ shell: ShellSession, _ linked: LinkedSource) {
        subscription?.cancel()
        historyLoad?.cancel()
        historyLoad = nil
        linkedRetry?.cancel()
        linkedRetry = nil
        self.shell = shell
        let supervisor = shell.supervisor
        if active {
            panel?.model.turnItemLoader = Self.linkedTurnItemLoader(supervisor, linked: linked)
        }
        let store = self.store
        let wireSubscription = UUID()
        let input = PeerLinkRPC.threadInput(environmentId: linked.environmentId, threadId: threadId.localId)
        // Set while a failure shows, so only the first value after it hops to the main actor to clear it.
        let failed = OSAllocatedUnfairLock(initialState: false)
        // The oldest row shown when this (re)subscribe started, until its snapshot lands.
        let restoreThrough = OSAllocatedUnfairLock<TurnItemId?>(initialState: nil)
        subscription = supervisor.subscribe(PeerLinkRPC.subscribeThread, payload: {
            let oldest = await store.oldestShownItemId()
            restoreThrough.withLock { $0 = oldest }
            // Claims the store for this stream; the linked read itself takes no cursor.
            _ = await store.subscribeInput(subscription: wireSubscription)
            return input
        }, handler: { [weak self] event in
            switch event {
            case .value(let json):
                try await ThreadSession.applyWire(json, to: store, subscription: wireSubscription)
                if Self.carriesSnapshot(json), let anchor = restoreThrough.withLock({ let a = $0; $0 = nil; return a }),
                   await !store.shows(anchor) {
                    await self?.restoreLinkedHistory(through: anchor)
                }
                if failed.withLock({ let was = $0; $0 = false; return was }) { await self?.linkedRead(nil) }
            case .interrupted(let error):
                failed.withLock { $0 = true }
                await self?.linkedRead(error)
            case .subscribed: break
            }
        })
    }

    /// Reports a linked read's outcome. A failure other than a transport loss stops the stream: unreachable asks
    /// again after `LinkedThreads.retrySeconds`, anything else waits for `retryLinked`.
    private func linkedRead(_ error: RPCClientError?) {
        guard active else { return }
        onLinkedFailure?(error)
        guard let error, !error.isTransport else { return }
        subscription?.cancel()
        subscription = nil
        guard LinkedThreads.isUnreachable(error.typedError) else { return }
        linkedRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LinkedThreads.retrySeconds))
            guard !Task.isCancelled else { return }
            self?.retryLinked()
        }
    }

    /// Try again (LinkedThreadPane.tsx:156-162): subscribes again now.
    func retryLinked() {
        guard active, let shell, linked != nil else { return }
        subscription?.cancel()
        subscription = nil
        attach(shell)
    }

    /// `linkedThreadItemSource` (5258 state/linkedThreadView.ts:278-286): an expanded row reads its item in full through
    /// the linking environment.
    nonisolated static func linkedTurnItemLoader(_ supervisor: ConnectionSupervisor, linked: LinkedSource) -> ThreadViewModel.TurnItemLoader {
        { input, wireType in
            do {
                let json = try await supervisor.request(PeerLinkRPC.threadItem,
                                                        payload: PeerLinkRPC.itemInput(environmentId: linked.environmentId, threadId: input.threadId,
                                                                                       itemId: input.itemId))
                let result = try json.decode(as: GetTurnItemResult.self)
                return TurnItemDetail.resolve(result, wireType: wireType)
            } catch let error as RPCClientError {
                throw DiffLoadError(error)
            }
        }
    }

    /// The shell went away without a successor yet. The panel keeps the last state.
    func detach() {
        if let familyLease { shell?.releaseFamily(familyLease); self.familyLease = nil }
        subscription?.cancel()
        subscription = nil
        historyLoad?.cancel()
        historyLoad = nil
        linkedRetry?.cancel()
        linkedRetry = nil
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
        panel.timeline.historyCursor = update.history.historyCursor
        panel.timeline.historyLoading = update.history.loading
        panel.timeline.historyFailed = update.history.error != nil
        let (projectTitle, workspaceRoot) = place(update.projection)
        OpenTiming.measure("panel setProjection") {
            panel.setProjection(update.projection, projectTitle: projectTitle, workspaceRoot: workspaceRoot, onlyStreamingText: onlyStreamingText)
        }
        panel.header.projectIcon = project(update.projection).map(ProjectIconSource.init)
        if update.projection != nil { LaunchGuard.shared.shown(threadId.rawValue) }
        onProjection?(update.projection, onlyStreamingText)
        onStatus?(update.status)
        advanceCitation(update)
    }

    /// Project title and workspace root from the shell (the worktree when the thread has one).
    private func place(_ projection: ThreadProjection?) -> (String, String?) {
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.thread(threadId)
        guard let project = project(projection) else { return ("", nil) }
        return (Self.crumbTitle(project, sidebar: sidebar), projection?.thread.worktreePath ?? shell?.worktreePath ?? project.workspaceRoot)
    }

    /// The header's project crumb: a scratch thread reads "No project" (43076b57cb, ChatHeader.tsx:80).
    static func crumbTitle(_ project: ProjectShell, sidebar: SidebarContentView?) -> String {
        guard let state = sidebar?.state, SidebarListBuilder.isScratch(project, state: state) else { return project.title }
        return "No project"
    }

    private func project(_ projection: ThreadProjection?) -> ProjectShell? {
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.thread(threadId)
        guard let projectId = projection?.thread.projectId?.scoped(to: environmentId) ?? shell?.projectId else { return nil }
        return snapshot?.projects.first { $0.id == projectId }
    }

    func revealCitation(_ messageId: String) {
        citation = (messageId, 0)
        if let shown { advanceCitation(shown) }
    }

    private func advanceCitation(_ update: ThreadUpdate) {
        guard active, let citation, let panel else { return }
        switch CitationHistory.step(messageId: citation.messageId, projection: update.projection,
                                    history: update.history, status: update.status, pages: citation.pages) {
        case .waiting: break
        case .loadEarlier:
            guard historyLoad == nil, shell != nil else { return }
            self.citation?.pages += 1
            loadEarlier(throughEntryId: citation.messageId)
        case .found(let entryId, let runId):
            self.citation = nil
            panel.revealCitation(entryId: entryId, runId: runId)
        case .failed(let title, let message):
            self.citation = nil
            panel.toasts.show(ToastView(title: title, message: message, kind: .error))
        }
    }

    private func loadEarlier(throughEntryId: String? = nil) {
        guard historyLoad == nil, let shell else { return }
        if let linked { return loadEarlierLinked(shell, linked, throughEntryId: throughEntryId) }
        var http = shell.http
        // T3's history request timeout (RT/threadHistoryHttp.ts).
        http.timeout = 6
        let store = self.store, token = shell.token
        historyLoad = Task { [weak self] in
            guard var request = await store.beginLoadEarlier(throughEntryId: throughEntryId) else {
                if self?.store === store { self?.historyLoad = nil }; return
            }
            do {
                // One click pages on until a turn starts (threads.ts:788-873 at 4928, #24417).
                while true {
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
                    guard let next = await store.applyHistoryPage(
                        page, requestCursor: request.cursor, throughEntryId: request.throughEntryId)
                    else { break }
                    request.cursor = next
                }
                self?.historyLoad = nil
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

    /// Loads deferred work groups as an opened fold asks (`loadEarlier` with `workAnchorId`, threads.ts:727-860 at 4928,
    /// #26240): `view: "work"` pages from each anchor's cursor until the group is complete, each merged at its anchor.
    /// The anchors load side by side, like T3's `Promise.all` (MessagesTimeline.tsx:1815-1825). False when any failed.
    /// `loadEarlier` of a linked thread (linkedThread.ts:298-304, 381-443): `peerLinks.threadHistoryPage` from the
    /// snapshot's or the last page's cursor, paging on as a thread's own load does until a turn starts.
    private func loadEarlierLinked(_ shell: ShellSession, _ linked: LinkedSource, throughEntryId: String?) {
        let store = self.store, supervisor = shell.supervisor, local = threadId.localId
        historyLoad = Task { [weak self] in
            guard var request = await store.beginLoadEarlier(throughEntryId: throughEntryId) else {
                if self?.store === store { self?.historyLoad = nil }; return
            }
            do {
                while true {
                    try Task.checkCancellation()
                    let json = try await supervisor.request(PeerLinkRPC.threadHistoryPage,
                                                            payload: PeerLinkRPC.historyInput(environmentId: linked.environmentId, threadId: local, cursor: request.cursor))
                    let page = try json.decode(as: ThreadHistoryPage.self)
                    try Task.checkCancellation()
                    guard let next = await store.applyHistoryPage(page, requestCursor: request.cursor, throughEntryId: request.throughEntryId)
                    else { break }
                    request.cursor = next
                }
                self?.historyLoad = nil
            } catch {
                if Task.isCancelled {
                    await store.cancelHistoryLoad(requestCursor: request.cursor)
                    return
                }
                self?.historyLoad = nil
                // LinkedThreadPane.tsx:174.
                await store.failHistoryLoad(requestCursor: request.cursor, message: "Could not load earlier turns. Try again.")
            }
        }
    }

    /// Whether a stream value, one item or a chunk of them, holds a snapshot.
    nonisolated static func carriesSnapshot(_ json: JSONValue) -> Bool {
        if case .array(let items) = json { return items.contains { $0["kind"]?.stringValue == "snapshot" } }
        return json["kind"]?.stringValue == "snapshot"
    }

    /// Pages a linked thread back until `anchor` shows again, or its history runs out.
    private func restoreLinkedHistory(through anchor: TurnItemId) {
        guard historyLoad == nil, let shell, let linked else { return }
        let store = self.store, supervisor = shell.supervisor, local = threadId.localId
        historyLoad = Task { [weak self] in
            var pages = 0
            // ponytail: stops after 50 pages; a longer read before the reconnect comes back from Load earlier
            while pages < 50, await !store.shows(anchor), var request = await store.beginLoadEarlier() {
                do {
                    while pages < 50 {
                        pages += 1
                        try Task.checkCancellation()
                        let json = try await supervisor.request(PeerLinkRPC.threadHistoryPage,
                                                                payload: PeerLinkRPC.historyInput(environmentId: linked.environmentId, threadId: local, cursor: request.cursor))
                        let page = try json.decode(as: ThreadHistoryPage.self)
                        try Task.checkCancellation()
                        guard let next = await store.applyHistoryPage(page, requestCursor: request.cursor) else { break }
                        request.cursor = next
                    }
                } catch {
                    if Task.isCancelled {
                        await store.cancelHistoryLoad(requestCursor: request.cursor)
                        return
                    }
                    await store.failHistoryLoad(requestCursor: request.cursor, message: "Could not load earlier turns. Try again.")
                    break
                }
            }
            self?.historyLoad = nil
        }
    }

    private func loadDeferredWork(_ anchors: [String]) async -> Bool {
        // ponytail: `PeerLinkThreadHistoryInput` has no `view`, so a linked thread's folded work stays folded; read it whole if T3 adds the field
        guard let shell, linked == nil else { return false }
        var http = shell.http
        http.timeout = 6
        return await Self.loadDeferredWork(anchors, store: store, http: http, token: shell.token)
    }

    /// Nonisolated so the task group's children run off the main actor and capture only Sendable values.
    /// The pages merge in the store actor; session state stays on the main actor in the caller.
    nonisolated private static func loadDeferredWork(
        _ anchors: [String], store: ThreadStore, http: EnvironmentHTTP, token: String
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for anchor in anchors {
                group.addTask {
                    let anchorId = TurnItemId(anchor)
                    var request = await store.deferredWorkRequest(anchorId: anchorId)
                    while let current = request {
                        guard let page = try? await http.get(current.path, token: token, as: ThreadHistoryPage.self) else { return false }
                        switch await store.applyDeferredWorkPage(page, anchorId: anchorId, requestCursor: current.cursor) {
                        case .loaded(let next?):
                            request = ThreadHistoryRequest(threadId: current.threadId, cursor: next, throughEntryId: anchor, view: .work)
                        case .loaded(nil), .noop: return true
                        case .failed: return false
                        }
                    }
                    return true
                }
            }
            var ok = true
            for await result in group { ok = ok && result }
            return ok
        }
    }

    /// Restore compact wire records before reduction. An invalid reference must request a
    /// new snapshot instead of advancing past an answer whose body could not be restored.
    nonisolated static func applyWire(_ json: JSONValue, to store: ThreadStore, subscription: UUID) async throws {
        do {
            try await store.applyWire(json, subscription: subscription)
        } catch {
            await store.resetForResynchronization(subscription: subscription)
            throw error
        }
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
                throw DiffLoadError(error)
            }
        }
    }

    /// The RPC failure as text for T3's error line, with the typed error kept so Redesign can say what failed.
    struct DiffLoadError: LocalizedError, TypedErrorCarrying {
        var errorDescription: String?
        var typedError: RPCTypedError?
        init(_ error: RPCClientError) { errorDescription = error.description; typedError = error.typedError }
    }

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
                throw DiffLoadError(error)
            }
        }
    }

    /// `review.getDiffPreview` with `commitSha` for one local commit (4928 DiffPanel.tsx:375-388, #19941).
    nonisolated static func commitDiffLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.CommitLoader {
        { cwd, sha, baseRef, ignoreWhitespace in
            do {
                let json = try await supervisor.request(ReviewDiffPreview.method,
                                                        payload: ReviewDiffPreview.input(cwd: cwd, commitSha: sha, baseRef: baseRef, ignoreWhitespace: ignoreWhitespace))
                return try json.decode(as: ReviewDiffPreview.self)
            } catch let error as RPCClientError {
                throw DiffLoadError(error)
            }
        }
    }

    /// `review.getBranchCommits` (4928 rpc.ts:1767). A 3824 server does not serve it; its refusal
    /// reaches the Commits submenu as the reason.
    nonisolated static func branchCommitsLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.BranchCommitsLoader {
        { cwd, baseRef in
            do {
                return try await supervisor.request(ReviewBranchCommits.method, payload: ReviewBranchCommits.input(cwd: cwd, baseRef: baseRef))
                    .decode(as: ReviewBranchCommits.self)
            } catch let error as RPCClientError {
                throw DiffLoadError(error)
            }
        }
    }

    /// `diffFileContents.ts:77-98` (3824): full sides for an explicit context expansion.
    nonisolated static func diffFileContentsLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.FileContentsLoader {
        { cwd, source, file in
            do {
                let json = try await supervisor.request(ReviewDiffFileContents.method,
                    payload: ReviewDiffFileContents.input(cwd: cwd, source: source, changeType: file.change.rawValue,
                                                          oldPath: file.oldPath ?? file.path, newPath: file.path))
                return try json.decode(as: ReviewDiffFileContents.self)
            } catch let error as RPCClientError {
                throw DiffLoadError(error)
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

    /// File-change details retain the recorded patch and contents for the diff panel.
    nonisolated static func toolCallDiffLoader(_ supervisor: ConnectionSupervisor) -> DiffPanelView.ToolCallLoader {
        { input in
            do {
                let json = try await supervisor.request("orchestration.getTurnItem", payload: encode(input))
                return try json.decode(as: GetTurnItemResult.self)
            } catch let error as RPCClientError {
                throw DiffLoadError(error)
            }
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
                throw DiffLoadError(error)
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
    /// Redesign's header figure, after Capy's: what the open thread would cost at API prices.
    private var cost: ThreadCostEstimate.Breakdown?
    /// The projection and thread the figure reads, kept so subagent usage that arrives later can join it.
    private var costProjection: ThreadProjection?
    private var costThreadId: ThreadId?
    /// Subagent threads' own usage, read when their parent thread opens and when the cost card opens, with the shell
    /// `updatedAt` it was read at (nil after a failed read, so the next open retries).
    // ponytail: kept for the session, a few numbers per subagent thread; drop entries on archive if it grows
    private var subagentCosts: [ThreadId: (updatedAt: T3Timestamp?, own: ThreadCostEstimate.Breakdown?)] = [:]
    private var readingSubagentCosts: Set<ThreadId> = []
    /// Redesign's agent image gallery, fed by the open projection and the same child reads as the cost.
    private(set) var gallery: ThreadImageGalleryController!
    // ponytail: kept for the session beside `subagentCosts`, a few paths per child; drop on archive if it grows
    private var subagentImages: [ThreadId: ThreadImageGallery.Collected] = [:]
    /// Environments whose kept images were checked against their threads this session.
    private var prunedImageEnvironments: Set<String> = []
    /// Whether the window shows a thread route; Settings and the utility pages hide the figure.
    var costRouteShowsThread = true { didSet { syncCost() } }
    private(set) var terminal: TerminalController!
    private(set) var composer: ComposerController!
    private(set) var git: GitController!
    private(set) var clones: ProjectCloneController!
    private(set) var addToMachine: AddProjectToMachineController!
    private(set) var scripts: ProjectScriptsController!
    private(set) var files: FilesController!
    private(set) var pullRequests: ThreadPullRequestsController!
    private(set) var browser: BrowserController!
    private var devices: DevicePanelController!
    private(set) var automations: ThreadAutomationsController!
    private var checkoutStatus: SidebarCheckoutStatus!
    private(set) var lineage: ThreadLineageController!
    private(set) var sideChats: SideChatController!
    private(set) var linkedThreads: LinkedThreadController!
    /// `peerLinks.names` per environment, as the open thread's links read them (5258 state/peerLinks.ts:48-52).
    private var linkNames: [String: (at: Date, labels: [String: String])] = [:]
    private var readingLinkNames: Set<String> = []
    /// Machines a link named that the names lacked, each asked about once (`refreshNamesLacking`, peerLinks.ts:103-121).
    private var askedLinkNames: Set<String> = []
    private var issueStates: SidebarIssueStates?
    /// Signed inline URLs of HTML renders and MCP Apps, by attachment id.
    private var webAssets: [String: (url: URL, expires: Date)] = [:]
    /// Runs whose Retry is in flight: one retry per failed run (ChatView.tsx:4047-4058).
    private var retryingPreparations: Set<RunId> = []
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    /// `getThreadLinkMetadata` answers by `<environment>/<thread>`; nil inside means the server doesn't know the thread.
    fileprivate var linkMetadata: [String: ThreadLinkMetadata?] = [:]
    fileprivate var linkMetadataLoading: Set<String> = []
    /// `claimWorkspaceBasenameLookup`: only the latest clicked link opens.
    private var fileLookupSequence = 0

    /// Opens a chat file link, first finding the file the agent cited (#33943, #35036).
    func openCitedFile(_ meta: FileLinkMeta, open: @escaping (FileLinkMeta) -> Void) {
        fileLookupSequence += 1
        let claimed = fileLookupSequence
        guard meta.workspaceRelativePath.map({ WorkspaceLinkLookup.query($0, cwd: "") != nil }) == true,
              let env = files.workspaceEnvironmentId else { open(meta); return }
        let threadProject = sidebar?.snapshot?.threads.first { $0.id == openThreadId }?.projectId
        let roots = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env && $0.id != threadProject }.map(\.workspaceRoot)
        let revision = files.openRevision, thread = openThreadId
        Task { [weak self] in
            let found = await self?.files.citedFile(meta, otherRoots: roots)
            // A later link, a file opened meanwhile or another thread wins (#39130).
            guard let self, claimed == self.fileLookupSequence, revision == self.files.openRevision, thread == self.openThreadId else { return }
            open(found ?? meta)
        }
    }

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
        panel.lazyDiffPanel.set(\.canReadFiles, { [weak self, weak environments] in
            guard let id = self?.openThreadId?.environmentId else { return false }
            return environments?.authSession(id)?.grants(AuthScopes.filesystemRead) == true
        })
        PullRequestDetailBinding.savedLinks = { [weak sidebar] env in
            ((sidebar?.snapshot?.threads ?? []) + (sidebar?.snapshot?.archivedThreads ?? []))
                .filter { $0.id.environmentId == env }.flatMap { $0.pullRequests ?? [] }
        }
        PullRequestDetailBinding.serverSettings = { [weak composer] env in composer?.config(env).map { ServerSettingsValues($0.settings.raw) } }
        terminal = TerminalController(panel: panel, sidebar: sidebar, environments: environments)
        // `runShellCommand` (ChatView.tsx:5105-5116): a code block's command runs as a one-off project script.
        // ponytail: T3 passes the handler only when the thread has a project; runScript does nothing without a launch target
        panel.model.runShellCommand = { [weak self] command in
            self?.terminal.runScript(ProjectScript(id: "chat-code-block", name: "Chat code block", command: command), preserveHistory: true)
        }
        git = GitController(panel: panel, sidebar: sidebar, environments: environments, composer: composer)
        automations = ThreadAutomationsController(panel: panel, environments: environments)
        clones = ProjectCloneController(panel: panel, environments: environments, composer: composer)
        addToMachine = AddProjectToMachineController(panel: panel, sidebar: sidebar, environments: environments, composer: composer, clones: clones)
        composer.onTargetChange = { [weak self] in
            self?.hideNoActiveThread(); self?.linkedThreads?.closePage(); self?.syncUnavailable(); self?.git.refresh(); self?.automations.sync(); self?.clones.syncBanner(); self?.updateServerUpdateNotice()
            self?.sideChats?.sync()
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
        // Project pins (4928 #26154, useProjectGroupUpdate.ts): offered where every member's server keeps them and this
        // connection may change it; the write goes to each member in turn and the first failure says so.
        sidebar.actions.canPinProject = { [weak self, weak environments] group in
            guard let self, let environments else { return false }
            return group.members.allSatisfy { member in
                let env = member.id.environmentId
                return env.flatMap { self.composer.config($0) }?.capabilities.contains(ProjectOrganization.capability) == true
                    && environments.canOperate(env)
            }
        }
        sidebar.actions.setProjectPinned = { [weak self, weak environments] group, pinned in
            Task { [weak self] in
                for member in group.members {
                    guard let env = member.id.environmentId, let environments else { return }
                    do {
                        _ = try await environments.request(env, "projects.mutate", ProjectOrganization.update(projectId: member.id.localId.rawValue, pinned: pinned))
                    } catch {
                        let message = (error as? RPCClientError)?.typedError?.fields["message"]?.stringValue ?? "An error occurred."
                        _ = self?.panel.toasts.show(ToastView(title: pinned ? "Failed to pin project" : "Failed to unpin project", message: message, kind: .error))
                        return
                    }
                }
            }
        }
        checkoutStatus = SidebarCheckoutStatus(environments: environments) { [weak sidebar] in sidebar?.checkoutBranchChanged() }
        sidebar.actions.checkoutBranch = { [weak self] env, cwd in self?.checkoutStatus.branch(environmentId: env, cwd: cwd) }
        // Scratch rows name their machine; the sidebar learns each environment's scratch folder from its config.
        composer.configObservers.append { [weak self, weak sidebar] env in
            guard let sidebar, let config = self?.composer.config(env) else { return }
            let root = config.scratchWorkspaceRoot.map(SidebarModel.normalizeProjectPath)
            if sidebar.state.scratchRoots[env] != root { sidebar.state.scratchRoots[env] = root }
            // Threads with a hidden tag leave the sidebar while the environment hides them (T3 4928 #29053).
            let tags = SidebarModel.hiddenThreadTags(settings: config.settings.raw)
            if sidebar.state.hiddenThreadTags[env] != tags { sidebar.state.hiddenThreadTags[env] = tags }
        }
        lineage = ThreadLineageController(panel: panel)
        sideChats = SideChatController(panel: panel, sidebar: sidebar, environments: environments, composer: composer)
        sideChats.parentId = { [weak self] in self?.openThreadId }
        linkedThreads = LinkedThreadController(panel: panel, environments: environments)
        linkedThreads.openConnected = { [weak self] id in self?.open(id) }
        linkedThreads.addWithCode = { [weak self] host in self?.addEnvironment?(host) }
        gallery = ThreadImageGalleryController(pill: panel.header.pill)
        gallery.onOpen = { [weak self] in self?.readSubagentCosts() }
        gallery.onOpenInThread = { [weak self] image in
            guard let self, let open = self.openThreadId, let env = open.environmentId else { return }
            if image.threadId == open.localId { self.panel.timeline.revealEntry(containing: image.entryId) } else { self.open(image.threadId.scoped(to: env)) }
        }
        gallery.canReveal = { [weak self] image in self?.localImageURL(image) != nil }
        // Our copy of what agents viewed, for when their temp files are gone (`AgentImageCache`).
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "CandyWrapper").appendingPathComponent("agent-images")
        let cache = AgentImageCache.shared ?? AgentImageCache(root: cacheRoot)
        AgentImageCache.shared = cache
        // Reply images kept across launches, per test app like other storage (`MediaDiskCache`).
        if MediaDiskCache.shared == nil {
            let media = MediaDiskCache(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "CandyWrapper").appendingPathComponent("media"))
            MediaDiskCache.shared = media
            MarkdownImages.preload(media.launchSizes)
            Task.detached(priority: .background) { await media.sweep() }
        }
        MarkdownImages.keptCopy = { [weak self] thread, item in
            guard let env = self?.openThreadId?.environmentId else { return nil }
            return await cache.url(env: env, thread: thread.rawValue, item: item.rawValue)
        }
        gallery.fileExists = { [weak self] image in
            guard let self, let env = self.openThreadId?.environmentId, env == self.environments.primaryId else { return nil }
            return self.localImageURL(image) != nil
        }
        gallery.keptHashes = { [weak self] thread in
            guard let env = self?.openThreadId?.environmentId else { return [:] }
            return await cache.entries(env: env, thread: thread.rawValue).mapValues(\.hash)
        }
        gallery.keep = { [weak self] image in
            guard let self, let env = self.openThreadId?.environmentId, let item = image.itemId else { return nil }
            if env == self.environments.primaryId {
                guard let url = self.localImageURL(image) else { return nil }
                return await cache.capture(env: env, thread: image.threadId.rawValue, item: item.rawValue, file: url)?.hash
            }
            guard let resource = image.resource else { return nil }
            return await cache.keepRemote(env: env, thread: image.threadId.rawValue, item: item.rawValue, resource: resource)?.hash
        }
        gallery.storedCount = { [weak self] thread, item in
            guard let self, let env = self.openThreadId?.environmentId else { return nil }
            let payload: JSONValue = .object(["threadId": .string(thread.rawValue), "itemId": .string(item.rawValue)])
            guard let json = try? await self.environments.request(env, "orchestration.getTurnItem", payload),
                  let result = try? json.decode(as: GetTurnItemResult.self) else { return nil }
            return result.item.map(TurnItemDetail.outputImageCount) ?? 0
        }
        gallery.onReveal = { [weak self] image in
            guard let url = self?.localImageURL(image) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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
        lineage.guest.canOperate = { [weak environments] env in environments?.canOperate(env) ?? true }
        lineage.openThreadInTab = { [weak self] id in
            if let inTab = self?.sidebar?.onOpenInNewTab { inTab(id) } else { self?.open(id) }
        }
        // A second `orchestration.subscribeThread` for the parent, only while the lineage controller needs it.
        lineage.watchThread = { [weak environments] id, onProjection in
            guard let env = id.environmentId, let shell = environments?.session(env) else { return {} }
            let supervisor = shell.supervisor
            let familyLease = shell.retainFamily(id.localId)
            let store = ThreadStore(threadId: id.localId, environmentId: env, onChange: {})
            let wireSubscription = UUID()
            let task = supervisor.subscribe("orchestration.subscribeThread", keepsRetryingServerFailures: true, payload: {
                ThreadSession.encode(await store.subscribeInput(subscription: wireSubscription))
            }, handler: { event in
                guard case .value(let json) = event else { return }
                try await ThreadSession.applyWire(json, to: store, subscription: wireSubscription)
                guard let projection = await store.takeUpdate()?.projection else { return }
                await MainActor.run { onProjection(projection) }
            })
            return { task.cancel(); shell.releaseFamily(familyLease) }
        }
        lineage.localVisit = { [weak sidebar] id in sidebar?.state.localVisits[id] }
        lineage.acknowledgeWake = { [weak self] id, time in self?.acknowledgeWake(id, at: time) }
        // The open thread's snooze ended with no push: the visit rules see it woke while shown.
        lineage.onWake = { [weak self] in self?.syncVisit() }
        // `viewingAtom` (ThreadVisitWatermark.tsx:12-29 at 5258, #42084): the visit waits for the window to be shown
        // and key, so it catches up when the user comes back.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            // Any window: `syncVisit` reads its own window's state, and the notification can't cross into the main actor.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncVisit() }
            }
        }
        panel.header.cost.onOpen = { [weak self] in self?.readSubagentCosts() }
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
        panel.model.onOpenWebLink = { [weak self] url, modified in self?.pullRequests.openChatLink(url, modified: modified) }
        panel.model.showError = { [weak panel] title, message in _ = panel?.toasts.show(ToastView(title: title, message: message, kind: .error)) }
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
            if let link = ThreadLink(href: local.rawValue), let environment = link.environmentId {
                self.open(ThreadId(link.threadId).scoped(to: environment))
            } else {
                self.open(local.scoped(to: env))
            }
        }
        panel.model.threadTitle = { [weak self, weak sidebar] local in
            guard let env = self?.openThreadId?.environmentId,
                  let shell = sidebar?.snapshot?.threads.first(where: { $0.id == local.scoped(to: env) }) else { return nil }
            let title = shell.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        panel.model.linkedEnvironment = { [weak self] id in
            guard let self, let label = environments.label(id) else { return nil }
            return .init(label: label, machine: environments.machine(id) ?? "server")
        }
        // MarkdownThreadLink.tsx:46-58 at 5258: a link to a machine the thread's environment links to reads through it.
        panel.model.linkedEnvironmentLabel = { [weak self] env in self?.linkedLabel(env) }
        panel.model.onOpenLinkedThread = { [weak self] target in self?.openLinkedThread(target) }
        panel.model.linkedThread = { [weak self, weak sidebar] local in
            guard let self, let env = self.openThreadId?.environmentId, let snapshot = sidebar?.snapshot else { return nil }
            guard let link = ThreadLink(href: local.rawValue) ?? ThreadLink(href: "t3-thread://v1/\(local.rawValue)") else { return nil }
            guard let shell = ThreadLinkResolution.resolve(link, messageEnvironmentId: env, threads: snapshot.threads + snapshot.archivedThreads) else {
                return self.linkMetadataThread(link, env: env, projects: snapshot.projects)
            }
            let project = snapshot.projects.first { $0.id == shell.projectId }
            let destination = "t3-thread://v2/\(shell.id.environmentId ?? env)/\(shell.id.localId.rawValue)"
            return MarkdownContextChips.LinkedThread(title: shell.title, project: project.map(ProjectIconSource.init), destination: destination)
        }
        // `ThreadChipHoverCard` (5258 components/ThreadChipHoverCard.tsx:18-90, #38895): the project, the branch, the
        // model alone (`getTriggerDisplayModelName`), and the pull requests, in the sidebar's card.
        MarkdownView.threadHoverCard = { [weak self, weak sidebar] destination in
            guard let self, let env = self.openThreadId?.environmentId, let snapshot = sidebar?.snapshot,
                  let link = ThreadLink(href: destination) ?? ThreadLink(href: "t3-thread://v1/\(destination)") else { return nil }
            guard let shell = ThreadLinkResolution.resolve(link, messageEnvironmentId: env, threads: snapshot.threads + snapshot.archivedThreads) else {
                guard let meta = self.linkMetadataThread(link, env: env, projects: snapshot.projects) else { return nil }
                var card = SidebarThreadHoverCardModel(title: meta.title)
                card.projectIcon = meta.project
                card.projectLabel = meta.project?.title
                return card
            }
            var card = SidebarThreadHoverCardModel(title: shell.title)
            if let project = snapshot.projects.first(where: { $0.id == shell.projectId }) {
                card.projectLabel = project.title
                card.projectIcon = ProjectIconSource(project)
            }
            card.branch = shell.branch
            if let threadEnv = shell.id.environmentId, let providers = self.composer.config(threadEnv)?.providers {
                let instance = SidebarModel.shellRuntime(shell) != nil ? shell.providerInstanceId : shell.modelSelection.instanceId
                if let entry = ProviderCatalog(providers).entry(instance) {
                    let model = entry.model(shell.modelSelection.model).map(ModelNames.trigger) ?? shell.modelSelection.model.trimmingCharacters(in: .whitespaces)
                    if !model.isEmpty { card.provider = (entry.driver, model) }
                }
            }
            if !(shell.pullRequests ?? []).isEmpty { card.pullRequests = SidebarPullRequestBadge(shell) }
            return card
        }
        // A composer thread chip shows the same card, with the warning when this machine's agent can't read it.
        ComposerChipLook.threadHoverCard = { record, unreadable in
            guard let env = record["environmentId"]?.stringValue, let local = record["threadId"]?.stringValue,
                  var card = MarkdownView.threadHoverCard?("t3-thread://v2/\(env)/\(local)") else { return nil }
            card.unreadable = unreadable
            return card
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
        // An agent's feedback report (5258 FeedbackRequestCard.tsx:91-117): `agentFeedback.answerRequest` on the thread's
        // environment, which needs `orchestration:operate`.
        panel.model.answerFeedback = { [weak self] input in
            guard let env = self?.openThreadId?.environmentId, let environments = self?.environments else { return FeedbackRequests.genericFailure }
            do {
                _ = try await environments.request(env, AgentFeedbackRPC.answerRequest, input)
                return nil
            } catch let error as RPCClientError where error.typedError?.tag == AgentFeedbackRPC.errorTag {
                return AgentFeedbackRPC.failure(error.typedError?.fields["reason"]?.stringValue) ?? error.typedError?.message ?? FeedbackRequests.genericFailure
            } catch {
                return FeedbackRequests.genericFailure
            }
        }
        // "Sign in" on an MCP notice (5258 McpSignInAction.tsx): `provider.mcpSignIn.start`, then `.complete` with the
        // address the browser landed on. Both need `providers:manage`.
        panel.model.onMcpSignIn = { [weak self] threadId, providerThreadId, server in
            guard let self, let window = self.panel.window, let env = self.openThreadId?.environmentId else { return }
            let environments = self.environments, model = self.panel.model, toasts = self.panel.toasts
            @MainActor func message(_ error: Error) -> McpSignInDialog.Failure {
                let text = ((error as? RPCClientError)?.typedError?.message ?? error.localizedDescription).trimmingCharacters(in: .whitespacesAndNewlines)
                return McpSignInDialog.Failure(text.isEmpty ? "The environment request failed." : text)
            }
            @MainActor func signedIn(_ reply: JSONValue) {
                guard let at = reply["signedInAt"]?.stringValue.flatMap({ T3Timestamp($0).date }) else { return }
                let key = McpSignIn.key(threadId, server)
                model.mcpSignedInAt[key] = max(model.mcpSignedInAt[key] ?? .distantPast, at)
            }
            let dialog = McpSignInDialog(server: server)
            dialog.start = {
                do {
                    let reply = try await environments.request(env, McpSignInRPC.start,
                                                               McpSignInRPC.startInput(threadId: threadId, providerThreadId: providerThreadId, server: server))
                    signedIn(reply)
                    return reply["authorizationUrl"]?.stringValue
                } catch { throw message(error) }
            }
            dialog.complete = { url in
                do {
                    signedIn(try await environments.request(env, McpSignInRPC.complete, McpSignInRPC.completeInput(
                        threadId: threadId, providerThreadId: providerThreadId, server: server, callbackUrl: url)))
                } catch { throw message(error) }
            }
            dialog.openURL = { url in if let url = SafeExternalURL.parse(url) { NSWorkspace.shared.open(url) } }
            let host = ModalHost.present(dialog, in: window)
            host.onDismiss = { [weak dialog] in dialog?.cancelPending() }
            dialog.onClose = { [weak host] in host?.close() }
            dialog.onSignedIn = { [weak host] in
                host?.close()
                _ = toasts.show(ToastView(title: "Signed in to \(server)", message: nil, kind: .success))
            }
            dialog.begin()
        }
        panel.model.canAnswerFeedback = { [weak self] in
            guard let self, let env = self.openThreadId?.environmentId else { return false }
            return self.environments.canOperate(env)
        }
        // An agent's link request (LinkRequestCard.tsx at 3814): Decline answers in place, Review opens the link dialog,
        // and both go to `peerLinks.answerRequest` on the thread's environment.
        panel.model.canAnswerLinkRequests = { [weak self] in
            guard let self, let env = self.openThreadId?.environmentId else { return false }
            return self.environments.canCreateGuestShare(env)
        }
        panel.model.declineLinkRequest = { [weak self] item in
            guard let self, let env = self.openThreadId?.environmentId else { return PeerLinkDialog.answerFailure(CancellationError()) }
            do {
                _ = try await self.environments.request(env, "peerLinks.answerRequest", LinkRequestAnswer.payload(item, .object(["type": .string("decline")])))
                self.onPeerLinksChanged?(env)
                return nil
            } catch {
                return PeerLinkDialog.answerFailure(error)
            }
        }
        panel.model.reviewLinkRequest = { [weak self] item in self?.reviewLinkRequest(item) }
        lineage.providers = { [weak composer] env in composer?.providers(env) ?? [] }
        lineage.selectedModel = { [weak composer] in composer?.selectedModel }
        composer.onModelChange = { [weak self] in self?.lineage.syncFooter() }
        files = FilesController(panel: panel, sidebar: sidebar, environments: environments)
        files.openThread = { [weak self] id in self?.open(id) }
        let prCapabilities = PullRequestCapabilities(environments: environments)
        issueStates = SidebarIssueStates(sidebar: sidebar, environments: environments, capabilities: prCapabilities)
        pullRequests = ThreadPullRequestsController(panel: panel, sidebar: sidebar, environments: environments, capabilities: prCapabilities)
        pullRequests.openThreadId = { [weak self] in self?.openThreadId }
        // ponytail: dedupes the PR chip by id only; T3 also skips it when a `#` chip names the same URL.
        pullRequests.addToChat = { [weak self] records in records.forEach { self?.composer.addReviewComment($0) } }
        pullRequests.handoff = { [weak self] task in self?.composer.appendHandoff(task) ?? false }
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
        terminal.availableEditors = { [weak self] env in self?.composer.config(env)?.availableEditors }
        pullRequests.openIntegratedBrowser = { [weak self] url in self?.browser.openURL(url.absoluteString) }
        pullRequests.openBrowserLink = { [weak self] url in self?.browser.openLink(url) ?? false }
        WorkDetailLinks.open = { [weak self] url in self?.browser.openLink(url) ?? false }
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
            let reply: JSONValue?
            do { reply = try await environments?.request(env, "projects.readFile", .object(["cwd": .string(cwd), "relativePath": .string(path)])) }
            catch RPCClientError.failure { return nil } // the server answered: no readable file
            guard let reply, let contents = reply["contents"]?.stringValue else { return nil }
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
        addToMachine.openProject = { [weak self] project in self?.newThread(in: project) }
        // A row's pull request badge: one link opens it beside the thread, a stack or several open
        // the thread's pull requests tab (`ThreadPullRequestBadgeControl`).
        sidebar.actions.openPullRequest = { [weak self, weak sidebar] id in
            guard let self, let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }) else { return }
            if !ClientSettingsStore.shared.current.bool("pullRequestLinksOpenInApp") || NSApp.currentEvent?.buttonNumber == 2 {
                if let href = ThreadPullRequests.current(thread.pullRequests ?? [])?.url ?? thread.linkedPullRequest?.url ?? thread.branchPullRequest?.url,
                   let url = SafeExternalURL.parse(href) { NSWorkspace.shared.open(url) }
                return
            }
            self.open(id)
            if SidebarPullRequestBadge(thread)?.opensList == true {
                self.panel.mutatePanel { $0.open(.pullRequests); return [] }
            } else {
                self.pullRequests.openCurrentPullRequest()
            }
        }
        sidebar.actions.openLinkedItems = { [weak self] id in
            self?.open(id)
            self?.panel.mutatePanel { $0.open(.pullRequests); return [] }
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
            let popup = AssistantCitationCommentPopup.present(citation, anchor: anchor, save: { edited, send in
                replace(edited.markdown)
                if send { composer.submit() }
            }, remove: { replace("") }, restoreFocus: { composer.focus() })
            // A question taking the editor closes the comment the way a click outside does, which saves an
            // unsaved comment into the prompt that comes back afterwards (T3 3105 9fb4ddb2d).
            self.composer.onEditorTaken = { [weak popup, weak composer] in
                guard let popup, let host = composer?.popupHost else { return }
                host.close(popup, returnFocus: false)
            }
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
        // Reveal resolves the cited file first, as opening does (#33943).
        MarkdownView.onRevealFile = { [weak self] meta in
            guard let self, let env = self.openThreadId?.environmentId else { return }
            self.openCitedFile(meta) { [weak self] meta in
                self?.shellOpen(env, OpenInEditors.launchInput(cwd: meta.filePath, editor: "file-manager", reveal: true), failure: "Unable to reveal file")
            }
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
            let reply: JSONValue
            do {
                // A call the server never answers would keep its turn of `AssetURLLimit` forever. Giving up sends
                // `Interrupt`, and the image shows "Image unavailable" like a failed one.
                reply = try await shell.supervisor.request("assets.createUrl", payload: .object(["resource": resource]),
                                                           timeout: MarkdownImages.signingTimeout)
            } catch let error as RPCClientError {
                guard resource["_tag"]?.stringValue == "media-file", let path = resource["path"]?.stringValue else { return nil }
                let typed = error.typedError
                // `blockedAssetUrlState` (client-runtime state/assets.ts:91-119): a session without `filesystem:read`
                // says so instead of implying the file is gone.
                if typed?.tag == "EnvironmentAuthorizationError", typed?.message?.contains(AuthScopes.filesystemRead) == true {
                    MarkdownImages.missingFileAccess.insert("media-file:" + path)
                    MarkdownImages.unavailableReasons["media-file:" + path] = MarkdownImages.missingFileAccessMessage
                    return nil
                }
                // The primary environment runs on this Mac (`resolveRemoteOpenState`'s local-exec, as OpenInController reads it).
                let remoteHost = env == self.environments.primaryId ? nil : self.environments.label(env) ?? env
                MarkdownImages.unavailableReasons["media-file:" + path] = MarkdownImages.mediaUnavailableDescription(
                    errorTag: typed?.tag, message: typed?.message, checkedPath: typed?.fields["checkedPath"]?.stringValue, path: path,
                    remoteHost: remoteHost)
                return nil
            } catch {
                return nil
            }
            guard let relative = reply["relativeUrl"]?.stringValue,
                  let url = URL(string: relative, relativeTo: shell.http.baseURL)?.absoluteURL else { return nil }
            let size = reply["imageDimensions"].flatMap { d in
                d["width"]?.doubleValue.flatMap { w in d["height"]?.doubleValue.map { CGSize(width: w, height: $0) } }
            }
            return (url, size, reply["fileRevision"]?.stringValue)
        }
        MarkdownImages.openInFileViewer = { [weak self] relative in self?.files.openFile(relative, line: nil) }
        MarkdownImages.onMediaUnavailable = { [weak self] description in
            self?.panel.toasts.show(ToastView(title: "Media unavailable", message: description, kind: .error))
        }
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
            guard let self else { return }
            self.open(ThreadId(rawValue: citation.threadId).scoped(to: citation.environmentId))
            self.session?.revealCitation(citation.messageId)
        }
        composer.openThread = { [weak self] id in self?.open(id) }
        composer.onNewThread = { [weak self] in self?.newThread() }
        sidebar.actions.newThread = { [weak self] in self?.newThread() }
        sidebar.actions.newThreadInProject = { [weak self] in self?.newThread(in: $0) }
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
            setCost(nil)
            lineage.update(threadId: nil, projection: nil)
            terminal.show(nil)
            scripts.show(nil)
            files.show(nil)
        }
        sidebar.actions.discardDraft = { [weak self] id in self?.composer.discardDraft(id) }
        sidebar.actions.searchThreads = { [weak environments] query in await environments?.searchThreads(query) }
        sidebar.actions.clearShellSearch = { [weak environments] in environments?.clearShellSearch() }
        sidebar.actions.demandOlderSettled = { [weak environments] count, scope in environments?.demandOlderSettled(minimum: count, projectIds: scope) }
        environments.onSessionChange = { [weak self] env in self?.sessionChanged(env) }
        environments.onShell = { [weak self] snapshot in self?.shellChanged(snapshot) }
        environments.onRemove = { [weak self] env in self?.environmentRemoved(env) }
        environments.observe { [weak self] in self?.updateEnvironmentBanner(); self?.syncUnavailable() }
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
        // ⇧⌘I: Redesign's agent image gallery. CandyWrapper's own key, so it stays out of T3's keybinding contract.
        shortcuts.onKey { [weak self] event in
            guard event.charactersIgnoringModifiers?.lowercased() == "i",
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift],
                  let self, self.gallery.isOpen || self.gallery.images.count > 0, !self.panel.header.pill.isHidden else { return false }
            self.gallery.toggle()
            return true
        }
        // ⌥⌘I: the full image gallery over the thread panel. Free in T3's keybindings and in our menus.
        shortcuts.onKey { [weak self] event in
            guard event.keyCode == 34, event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .option],
                  let self, self.gallery.isWallOpen || self.gallery.images.count > 0, !self.panel.header.pill.isHidden else { return false }
            self.gallery.toggleWall()
            return true
        }
        composer.registerShortcuts(shortcuts)
        sideChats.registerShortcuts(shortcuts)
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
            let (rows, active) = sidebar.orderedRowTargets
            let target: SidebarContentView.RowTarget?
            if let index = Keymap.jumpIndex(call.command, prefix: "thread.jump.") {
                target = index < rows.count ? rows[index] : nil
            } else {
                target = Self.adjacentThread(rows, current: active, previous: call.command == "thread.previous")
            }
            switch target {
            case .thread(let id):
                sidebar.navigated(to: id)
                self.open(id)
            case .draft(let id):
                sidebar.actions.openDraft(id)
            case nil:
                return false
            }
            return true
        }
    }

    /// `resolveAdjacentThreadId` (Sidebar.logic.ts:873-898).
    static func adjacentThread<Row: Equatable>(_ ids: [Row], current: Row?, previous: Bool) -> Row? {
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
        connectDeviceNotice.sessionChanged(environmentId)
        serverUpdates.sessionChanged(environmentId)
        composer.sessionChanged(environmentId)
        terminal.sessionChanged(environmentId)
        clones.sessionChanged(environmentId)
        composer.addTargetsMayHaveChanged()
        git.sessionChanged(environmentId)
        browser.sessionChanged(environmentId)
        devices.sync()
        linkedThreads.sync()
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
        // A side chat opens as its parent with its tab shown (`resolveThreadOpenRoute`, lib/sideChatPane.ts:22-35).
        let route = SideChats.openRoute(id, shell: sidebar?.snapshot?.threads.first { $0.id == id })
        if let side = route.sideChat {
            open(route.open, force: force)
            if openThreadId == route.open { panel.mutatePanel { $0.openSideChat(side.localId); return [] } }
            return
        }
        panel.model.environmentId = id.environmentId
        MarkdownImages.cacheScope = id.environmentId
        sidebar?.state.activeThreadId = id
        defer { onOpenThreadChange?() }
        UserDefaults.standard.set(id.rawValue, forKey: Self.lastThreadKey)
        guard force || id != session?.threadId || panel.isDraft || noActiveThread.superview != nil else { return }
        OpenTiming.begin(id.rawValue)
        ImageTiming.mark("open", id.rawValue)
        hideNoActiveThread()
        linkedThreads?.closePage()
        let previousEnvironment = panel.isDraft ? nil : session?.environmentId
        session?.end()
        setCost(nil)
        // The panel keeps painting until the new thread's first projection replaces it in one pass
        // (`beginThreadSwitch`); clearing it here showed an empty window for a frame or more.
        let snapshot = sidebar?.snapshot
        let shell = snapshot?.threads.first { $0.id == id } ?? snapshot?.archivedThreads.first { $0.id == id }
        let keepRows = !force && previousEnvironment == id.environmentId
        if let shell {
            let project = snapshot?.projects.first { $0.id == shell.projectId }
            panel.beginThreadSwitch(projectTitle: project.map { ThreadSession.crumbTitle($0, sidebar: sidebar) } ?? "", threadTitle: shell.title, keepRows: keepRows)
            panel.header.projectIcon = project.map(ProjectIconSource.init)
            panel.titleTyping = titleTypings[id]
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
                let thread = self.sidebar?.snapshot?.threads.thread(id)
                let link = thread?.linkedPullRequest ?? thread?.branchPullRequest
                self.pullRequests.followLink(from: observedLink, to: link)
                observedLink = link
                self.panel.onProactivePullRequest = { [weak self] in self?.pullRequests.openProactive() }
                self.panel.proactiveLinkedPullRequestKey = thread.flatMap { self.pullRequests.proactiveKey($0) }
            }
            self?.composer.projectionChanged(projection, threadId: id)
            if let projection { self?.files.workspaceMutated(TurnDiffs.workspaceMutationId(projection), threadId: id) }
            self?.lineage.update(threadId: id, projection: projection)
            self?.setCost(projection, id: id)
        }
        session.onStatus = { [weak self] status in self?.composer.threadStatusChanged(status, threadId: id) }
        if let shell = environments.session(id.environmentId) { session.attach(shell) }
        self.session = session
        session.paintRetained()
        // composer.showThread fired onTargetChange before the session was set, so sync now.
        automations.sync()
        syncVisit()
        terminal.show(id)
        scripts.show(id)
        updateEnvironmentBanner()
        syncUnavailable()
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
    /// A draft with content moves to a project Add project just added, in place of a new draft (#42889).
    func moveDraft(_ draftId: String, toAdded project: ProjectShell) -> Bool {
        let previous = session
        guard composer.moveDraft(draftId, toAdded: project) else { return false }
        leftThread(previous)
        return true
    }

    func newThread(in project: ProjectShell? = nil) {
        let previous = session
        guard composer.newThread(in: project) else { return }
        leftThread(previous)
    }

    /// The composer now shows a draft: the thread that was open lets go of its panes.
    private func leftThread(_ previous: ThreadSession?) {
        previous?.end()
        session = nil
        setCost(nil)
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
        files.show(nil)
        keepAlive?.update()
    }

    /// The open thread's own cost between updates (`ThreadCostEstimate.OwnMemo`).
    private let costMemo = ThreadCostEstimate.OwnMemo()

    private func setCost(_ projection: ThreadProjection?, id: ThreadId? = nil) {
        let dither = ThemeRuntime.isDither(dark: true) || ThemeRuntime.isDither(dark: false)
        let opened = projection != nil && id != nil && id != costThreadId
        costProjection = projection
        costThreadId = projection == nil ? nil : id
        // Read subagent usage once as the thread opens, so the figure doesn't jump when the card opens.
        if opened, dither { readSubagentCosts() }
        gallery.update(threadId: projection == nil ? nil : id, projection: dither ? projection : nil)
        // While the gallery shows, a parent push reads the children that moved, so their images stream in too.
        if !opened, dither, gallery.isOpen { readSubagentCosts() }
        if opened || projection == nil { syncGalleryChildren() }
        var next: ThreadCostEstimate.Breakdown?
        if dither, let projection, let id {
            let byParent = subagentShellsByParent()
            next = ThreadCostEstimate.breakdown(projection, id: id, memo: costMemo) { [subagentCosts, readingSubagentCosts] parent in
                (byParent[parent] ?? []).map {
                    .init(id: $0.id, title: $0.title, own: subagentCosts[$0.id]?.own,
                          reading: subagentCosts[$0.id] == nil && readingSubagentCosts.contains($0.id))
                }
            }
        }
        guard next != cost || projection == nil else { return }
        cost = next
        syncCost()
    }

    /// Subagent threads by their parent, archived ones included (lineage, orchestrationV2.ts:108-112).
    /// It runs on every update of the open thread, so it reads each shell's lineage by index and copies only the
    /// subagents: joining and filtering the arrays copied every 1.8 KB shell, 1.3 ms at 2,580 threads against 0.02 ms.
    private func subagentShellsByParent() -> [ThreadId: [ThreadShell]] {
        var out: [ThreadId: [ThreadShell]] = [:]
        guard let snapshot = sidebar?.snapshot else { return out }
        for list in [snapshot.threads, snapshot.archivedThreads] {
            for i in list.indices where list[i].lineage.relationshipToParent == .subagent {
                if let parent = list[i].lineage.parentThreadId { out[parent, default: []].append(list[i]) }
            }
        }
        return out
    }

    /// Reads each subagent thread under the open one that changed since its last read, nested ones included.
    /// Neither the shell nor the subagent record carries usage (orchestrationV2.ts:700-731, 1836-1928), so this
    /// takes the child's projection (`orchestration.getThreadProjection`, rpc.ts:1675-1682) when the parent opens and
    /// when the card opens, only for children whose `updatedAt` moved. No polling.
    private func readSubagentCosts() {
        guard let root = costThreadId, let env = root.environmentId else { return }
        let byParent = subagentShellsByParent()
        var stale: [ThreadShell] = [], queue = [root], seen: Set<ThreadId> = [root]
        while let parent = queue.popLast() {
            for child in byParent[parent] ?? [] where seen.insert(child.id).inserted {
                queue.append(child.id)
                if subagentCosts[child.id]?.updatedAt != child.updatedAt, !readingSubagentCosts.contains(child.id) { stale.append(child) }
            }
        }
        guard !stale.isEmpty else { return }
        readingSubagentCosts.formUnion(stale.map(\.id))
        let environments = environments
        Task { [weak self] in
            // Two at a time: each read holds the child's whole projection while it decodes, about 80 MB at the peak for
            // a 20 MB thread, and a parent with many long children read them all at once.
            await forEachBounded(stale, limit: 2, work: { child -> (ThreadId, T3Timestamp?, ThreadCostEstimate.Breakdown?, ThreadImageGallery.Collected?) in
                let payload: JSONValue = .object(["threadId": .string(child.id.localId.rawValue)])
                guard let json = try? await environments.request(env, "orchestration.getThreadProjection", payload),
                      let projection = try? json.decode(as: ThreadProjection.self) else { return (child.id, nil, nil, nil) }
                return (child.id, child.updatedAt, ThreadCostEstimate.own(projection), ThreadImageGallery.collect(projection, agent: ""))
            }, each: { (id, at, own, images) in
                // A failed read keeps the last good figure and retries on the next open.
                if at == nil, let kept = self?.subagentCosts[id]?.own { self?.subagentCosts[id] = (nil, kept) } else { self?.subagentCosts[id] = (at, own) }
                if let images { self?.subagentImages[id] = images }
            })
            guard let self else { return }
            self.readingSubagentCosts.subtract(stale.map(\.id))
            self.syncGalleryChildren()
            self.setCost(self.costProjection, id: self.costThreadId)
            self.panel.header.cost.refreshCard()
        }
    }

    /// Hands the gallery the open thread's children's images, named after their place under it.
    private func syncGalleryChildren() {
        guard let root = costThreadId else { gallery.setChildren([:], names: [:]); return }
        let byParent = subagentShellsByParent()
        var children: [ThreadShell] = [], queue = [root], seen: Set<ThreadId> = [root]
        while let parent = queue.popLast() {
            for child in byParent[parent] ?? [] where seen.insert(child.id).inserted { children.append(child); queue.append(child.id) }
        }
        let names = ThreadImageGallery.agentNames(children.map { (id: $0.id.localId, title: $0.title, providerNative: $0.isProviderNativeSubagent, createdAt: $0.createdAt) })
        pruneKeptImages()
        var images: [ThreadId: ThreadImageGallery.Collected] = [:]
        for child in children { if let list = subagentImages[child.id] { images[child.id.localId] = list } }
        gallery.setChildren(images, names: names)
    }

    /// Drops kept images of threads this environment no longer has, once per environment per session, after the
    /// shell snapshot lists its threads (live and archived).
    private func pruneKeptImages() {
        guard let env = openThreadId?.environmentId, !prunedImageEnvironments.contains(env), let cache = AgentImageCache.shared,
              let snapshot = sidebar?.snapshot, !environments.hasPartialShell(env) else { return }
        let threads = (snapshot.threads + snapshot.archivedThreads).filter { $0.id.environmentId == env }
        guard !threads.isEmpty else { return }
        prunedImageEnvironments.insert(env)
        let ids = Set(threads.map { $0.id.localId.rawValue })
        Task { await cache.keepOnly(env: env, threads: ids) }
    }

    /// A gallery image's file on this Mac: the primary environment, a path that exists.
    private func localImageURL(_ image: GalleryImage) -> URL? {
        guard let env = openThreadId?.environmentId, env == environments.primaryId, var path = image.filePath else { return nil }
        if path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        if !path.hasPrefix("/"), image.threadId == openThreadId?.localId, let root = panel.model.workspaceRoot { path = root + "/" + path }
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private func syncCost() {
        panel.header.cost.breakdown = !costRouteShowsThread || panel.isDraft ? nil : cost
    }

    /// The thread the panel shows, nil on a draft (the route's thread in T3).
    var openThreadId: ThreadId? { panel.isDraft ? nil : session?.threadId }

    /// Rewrite title's typing effect per thread; the open thread's shows on its header.
    var titleTypings: [ThreadId: TitleTyping.Phase] = [:] { didSet { syncTitleTyping() } }
    func syncTitleTyping() { panel.titleTyping = openThreadId.flatMap { titleTypings[$0] } }
    /// The open thread changed, for the window title (#34697).
    var onOpenThreadChange: (() -> Void)?

    /// The thread view is back after Settings or a utility page: T3 mounts ChatView again, which focuses
    /// the composer unless the terminal is open (ChatView.tsx:6837-6845).
    func focusComposerOnReturn() {
        if !panel.terminalOpen { composer.focusComposer() }
    }

    private var visits = ThreadVisitTracker()
    private var visitTimer: DispatchWorkItem?
    private var visitViewShown = false
    /// The thread whose open the view last recorded (`recordedOpenRef`).
    private var recordedOpen: ThreadId?
    /// The wake the open thread last acknowledged, so a shell change before the visit's echo doesn't send it again.
    private var acknowledgedWake: String?

    /// `useAcknowledgeThreadWoke` (useThreadActions.ts:240-256): visits the thread at its wake time, on the server
    /// when it tracks visits and in the local watermark otherwise.
    func acknowledgeWake(_ id: ThreadId, at time: T3Timestamp) {
        sidebar?.state.localVisits[id] = time
        guard let env = id.environmentId, composer.config(env)?.capabilities.contains("threadVisitedTracking") == true else { return }
        Task { _ = try? await environments.dispatch(id, ThreadCommands.visit(id.localId, visitedAt: time)) }
    }

    /// ChatView's visit effect (ChatView.tsx:2938-3000) for the open thread while the thread view shows:
    /// a visit clears the row's Done and Woke marks. Runs on every shell change and route change.
    func syncVisit() {
        visitTimer?.cancel()
        visitTimer = nil
        // In a window counts as shown for the dedupe below; the visit itself also needs the window on screen and key
        // (`isDocumentViewed`: visible and focused, ThreadVisitWatermark.tsx:12-15 at 5258, #42084). Until then
        // nothing is recorded, the open included, and a run that finishes in a background window stays unread.
        let shown = panel.window != nil
        // Settings and Usage unmount ChatView in T3, so its per-watermark dedupe starts over on the way back.
        if shown, !visitViewShown { visits.reset() }
        if !shown { recordedOpen = nil }
        visitViewShown = shown
        // A popup or menu window of this one that took key keeps the document focused, as it does in a browser.
        let key = NSApp.keyWindow
        guard shown, let window = panel.window, NSApp.isActive, key === window || key?.parent === window,
              window.occlusionState.contains(.visible),
              let id = openThreadId, let sidebar,
              let shell = sidebar.snapshot?.threads.first(where: { $0.id == id }) else { return }
        let now = TimestampFormat.nowMs()
        // Opening a thread is one visit that also counts toward search ranking; a palette pick already sent it with
        // its query (ThreadVisitWatermark.tsx:31-56). The open is recorded locally even when the server can't take
        // it, so recents follow it. Only a server whose shells carry `opens` gets `opened`.
        if recordedOpen != id {
            visits.reset()
            recordedOpen = id
            if ThreadOpenLog.claim(id, now: Double(now)), !shell.lastVisitedAt.isAbsent, !shell.opens.isAbsent {
                visits.didDispatch(shell, routeKey: id.rawValue, nowMs: now)
                Task { _ = try? await environments.dispatch(id, ThreadCommands.visit(id.localId, visitedAt: shell.updatedAt, opened: true)) }
            }
        }
        // Opening a woken thread dismisses its Woke pill. T3 keeps a timer wake through a visit until the pill or the
        // footer's Dismiss is clicked (Sidebar.tsx:1276-1282); the user asked for it to clear once seen (decisions.md).
        // A subagent's request wakes a snoozed thread too (T3 f4df794777); only a snoozed thread needs the scan.
        let request = shell.snoozedUntil == nil ? nil : PendingSubagentRequests.byThread(sidebar.snapshot?.threads ?? [])[id]
        let thread = SidebarThread(shell, pendingSubagentRequest: request)
        if let wake = SidebarModel.threadWokeAt(thread, nowMs: now), acknowledgedWake != id.rawValue + wake.raw,
           SidebarModel.isWoke(thread, lastVisitedAt: SidebarModel.resolveThreadLastVisitedAt(server: shell.lastVisitedAt,
                                                                                             local: sidebar.state.localVisits[id]), nowMs: now) {
            acknowledgedWake = id.rawValue + wake.raw
            acknowledgeWake(id, at: wake)
        }
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
        setCost(nil)
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
        } else if reconnecting && reconnectingFor < 2 && !state.awaitingApproval {
            panel.showsEnvironmentBanner = false
            wake = 2 - reconnectingFor
        } else {
            // Waiting on device approval skips the grace and names it (useSystemComposerBanners.tsx:189-216).
            // T3 puts the "Approve this device…" text after the title as the banner's muted description.
            let label = environments.label(id) ?? "Remote"
            banner.text = state.awaitingApproval ? "\(label) is waiting to approve this device"
                : "\(label) is \(reconnecting ? "reconnecting" : "offline")"
            banner.detailText = state.awaitingApproval ? state.presentedError : nil
            banner.isError = state.status == .error
            // "Retry now" while reconnecting, nothing on the first attempt (useSystemComposerBanners.tsx:215-228).
            banner.showsReconnect = state.status != .connecting
            banner.reconnect.title = state.status == .reconnecting ? "Retry now" : "Reconnect"
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
        if let runtime = serverUpdates.ownRuntimeState(id) {
            guard mismatch != nil || runtime.isRestarting || runtime.status == .downloading else { panel.serverUpdateNotice = nil; return }
            let action = runtime.isRestarting || runtime.status == .downloading ? nil
                : DesktopUpdateLogic.buttonAction(runtime) == .install ? "Restart" : "Download"
            let status: ComposerServerUpdateNotice.Status = runtime.isRestarting ? .running(.resuming)
                : runtime.status == .downloading ? .running(.downloading)
                : .available(serverVersion: runtime.currentVersion, clientVersion: runtime.availableVersion ?? runtime.downloadedVersion ?? "")
            panel.serverUpdateNotice = ComposerServerUpdateNotice(serverLabel: label, status: status,
                guidance: DesktopUpdateLogic.buttonTooltip(runtime), action: action, actionEnabled: serverUpdates.canUpdate(id), dismissible: false)
            return
        }
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
        if serverUpdates.ownRuntimeState(id) != nil { serverUpdates.request(id, serverLabel: notice.serverLabel); return }
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
        setCost(nil)
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
            let remaining = state.projectScopeKeys.filter { !$0.hasPrefix(prefix) }
            if remaining != state.projectScopeKeys { sidebar.setProjectScopes(remaining) }
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
        notice.onGrants = { [weak self] env in
            self?.connectDeviceNotice.sessionChanged(env)
            self?.composer.grantsChanged()
            self?.serverUpdates.changed()
        }
        return notice
    }()
    private lazy var migrationToast = LegacyThreadMigrationToast(environments: environments, toasts: panel.toasts)
    /// "New device signed in" toasts (ConnectDeviceApprovalCoordinator.tsx, 5258 #42311).
    lazy var connectDeviceNotice: ConnectDeviceNotice = {
        let notice = ConnectDeviceNotice(environments: environments, toasts: panel.toasts)
        notice.approvalRequired = { [weak self] env in self?.composer.config(env)?.settings.raw["requireConnectDeviceApproval"]?.boolValue }
        composer.configObservers.append { [weak notice] env in notice?.configChanged(env) }
        return notice
    }()
    /// Whether an environment offers threads without a project, for the hero's second button.
    var offersScratch: () -> Bool = { false }
    /// The panel moved to another thread or draft (route history).
    var onRouteChange: (() -> Void)?
    /// An answered link request may have added a link, so lists of the environment's links reload
    /// (T3 3824 #26434: `peerLinkEnvironment.answerRequest` refreshes `peerLinks.list`).
    var onPeerLinksChanged: ((String) -> Void)?

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
            // The first project arrived: land in its draft instead of leaving the panel empty.
            if session == nil && !panel.isDraft { landOnIndex() }
        }
    }

    /// `NoActiveThreadState` over the thread panel: the chat surface with no thread (ChatView.tsx:10958-10961).
    private(set) lazy var noActiveThread: NoActiveThreadStateView = {
        let view = NoActiveThreadStateView()
        view.autoresizingMask = [.width, .height]
        return view
    }()
    /// `openLinkedThreadRead` (5258 lib/sideChatPane.ts:93-113): a linked thread opens as a right panel tab, or on the
    /// main screen for the "Main view" setting, a Cmd-click or a middle click.
    private func openLinkedThread(_ target: LinkedThreadSurfaceTarget) {
        let event = NSApp.currentEvent
        let intent = SideThreadOpen.intent(command: event?.modifierFlags.contains(.command) == true,
                                           middleButton: event?.type == .otherMouseUp && event?.buttonNumber == 2)
        let place = SideThreadOpen.resolve(preference: ClientSettingsStore.shared.current.string("sideThreadOpenTarget"), intent: intent,
                                           panelAvailable: openThreadId != nil)
        if place == .panel {
            panel.mutatePanel { $0.openLinkedThread(target); return [] }
            return
        }
        // LinkedThreadPage.tsx:28-39: once this client is connected to the thread's own environment, it opens there.
        if environments.session(target.environmentId) != nil, environments.hasShell(target.environmentId) {
            open(ThreadId(target.threadId).scoped(to: target.environmentId))
            return
        }
        // The `/linked/...` route leaves the thread: no thread is active, and the page is all that streams.
        session?.end()
        session = nil
        setCost(nil)
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
        files.show(nil)
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        sidebar?.state.activeThreadId = nil
        onOpenThreadChange?()
        linkedThreads.showPage(target, over: panel)
    }

    /// `UnreachableEnvironmentState` over the thread panel (5258 ThreadRouteView.tsx:219-220, 250-268).
    private(set) lazy var threadUnavailable: ThreadUnavailableStateView = {
        let view = ThreadUnavailableStateView()
        view.autoresizingMask = [.width, .height]
        view.onOpenEnvironments = { [weak self] in self?.openEnvironments?() }
        return view
    }()
    /// Settings > Connections with the add dialog, its address filled in when one is known (Enter code).
    var addEnvironment: ((String?) -> Void)?
    /// Settings > Connections, where T3's Open Environments goes (`/settings/connections`).
    var openEnvironments: (() -> Void)?
    /// Shows the unavailable page while the open thread's environment has no enabled entry, and takes it down when one
    /// comes back (`environmentUnreachableAtom` is reactive in T3); the session attaches when that environment connects.
    private func syncUnavailable() {
        let id = panel.isDraft ? nil : session?.threadId
        let unreachable = ThreadEnvironmentReach.unreachable(environmentId: id?.environmentId, catalogReady: environments.catalogReady,
                                                             primaryId: environments.primaryId,
                                                             enabledIds: Set(environments.saved.filter(\.enabled).map(\.environmentId)))
        if unreachable {
            guard threadUnavailable.superview !== panel else { return }
            threadUnavailable.frame = panel.bounds
            panel.addSubview(threadUnavailable)
        } else if threadUnavailable.superview != nil {
            threadUnavailable.removeFromSuperview()
        }
    }

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
        if !listed, environments.hasPartialShell(env), environments.session(env)?.confirmsMissing(id) != true { return }
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
        setCost(nil)
        lineage.update(threadId: nil, projection: nil)
        terminal.show(nil)
        scripts.show(nil)
        files.show(nil)
        panel.setProjection(nil, projectTitle: "", workspaceRoot: nil)
        sidebar?.state.activeThreadId = nil
        onOpenThreadChange?()
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
        sideChats.sync()
        issueStates?.sync(snapshot)
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
        let available = remembered.map { id in
            snapshot.threads.contains(where: { $0.id == id }) || id.environmentId.map({ environments.hasPartialShell($0) }) == true
        } ?? false
        // The last run crashed, froze or was killed, maybe on this thread: start on a new one, once.
        let launch = LaunchGuard.shared
        if let remembered, available, launch.restoresLastThread {
            launch.willRestore(remembered.rawValue)
            open(remembered)
            return
        }
        if let remembered, available, let notice = launch.takeNotice(title: snapshot.threads.first { $0.id == remembered }?.title) {
            var toast: Int?
            toast = panel.toasts.show(ToastView(title: "Started on a new thread", message: notice, kind: .warning, actionTitle: "Open thread",
                                                action: { [weak self] in
                                                    if let toast { self?.panel.toasts.dismiss(toast) }
                                                    self?.open(remembered)
                                                }), timeout: 0)
        }
        if let project = SidebarModel.sortProjectsForSidebar(snapshot.projects, threads: snapshot.threads, order: .updatedAt).first {
            _ = composer.newThread(in: project)
        }
    }
}

extension ThreadController {
    /// "Review link…" on an agent's link request (LinkRequestCard.tsx `LinkRequestDialog` at 3814): the machine it named
    /// is fixed, a hint preselects the best match, an address it named is filled in; the access starts at its suggestion.
    func reviewLinkRequest(_ item: TurnItem) {
        guard let window = panel.window, let env = openThreadId?.environmentId else { return }
        Task {
            // `useLinkableMachines` lists the environment's links on open, to mark the machines already linked.
            let links = (try? PeerLinkSummary.list(try await environments.request(env, "peerLinks.list", .object([:])))) ?? []
            let linked = Set(links.filter { $0.status != .expired }.map(\.environmentId))
            var machines = PeerLinkDialog.machines(environments, hostId: env, primaryLabel: nil, linked: linked,
                                                    reported: { composer.config($0)?.directEndpoints ?? [] })
            let named = item.string("environmentId"), url = item.string("url")
            if let named, !machines.contains(where: { $0.environmentId == named }) {
                // A machine this app doesn't know: link it at the address the agent gave, or one typed in.
                machines.insert(LinkableMachine(environmentId: named, label: item.string("label") ?? url ?? "a machine", connected: false,
                                                linked: linked.contains(named), urls: url.map { [$0] } ?? [], canMint: false), at: 0)
            } else if let named, let url, let i = machines.firstIndex(where: { $0.environmentId == named }), !machines[i].urls.contains(url) {
                machines[i].urls.append(url)
            }
            let addressOnly = named == nil && url != nil
            let choice = addressOnly ? LinkEnvironmentFormView.anotherAddress
                : LinkRequestAnswer.initialMachine(environmentId: named, hint: item.string("hint"), labels: machines.map { ($0.environmentId, $0.label) })
            PeerLinkDialog.present(
                in: window, environments: environments, machines: addressOnly ? [] : machines,
                initialChoice: choice, initialAccess: item.string("requestedAccess") ?? "approval-required",
                lockMachine: named != nil, address: addressOnly ? url : nil, answersRequest: true, successToast: false,
                toast: { [weak self] title, message, kind in
                    self?.panel.toasts.show(ToastView(title: title, message: message, kind: kind))
                },
                failureMessage: PeerLinkDialog.answerFailure,
                commit: { [weak self] choice in
                    guard let self else { return nil }
                    if choice.useExisting, let id = choice.machine?.environmentId {
                        let answer: JSONValue = .object(["type": .string("use-existing"), "environmentId": .string(id)])
                        _ = try await self.environments.request(env, "peerLinks.answerRequest", LinkRequestAnswer.payload(item, answer))
                        self.onPeerLinksChanged?(env)
                        return choice.machine?.label
                    }
                    guard let answer = LinkRequestAnswer.link(environmentId: choice.machine?.environmentId, label: choice.machine?.label,
                                                                        urls: choice.urls, access: choice.access, pairingCode: choice.pairingCode)
                    else { throw CancellationError() }
                    _ = try await self.environments.request(env, "peerLinks.answerRequest", LinkRequestAnswer.payload(item, answer))
                    self.onPeerLinksChanged?(env)
                    return choice.machine?.label
                })
        }
    }
}

extension ThreadController {
    /// `MarkdownThreadLink` (4928 chat/MarkdownThreadLink.tsx:20-71): a link to a thread this client hasn't loaded
    /// asks its server for the title and project with `orchestration.getThreadLinkMetadata`, once per thread, where
    /// the server sets `threadLinkMetadata`. Until the answer lands the chip shows the link's own text.
        /// The name the open thread's environment knows `env` by, when it links to it. Reads `peerLinks.names` once it is
    /// 10 s old, and once more when a link names a machine the names lack; a server without `linkThreadStream` has none.
    private func linkedLabel(_ env: String) -> String? {
        guard let via = openThreadId?.environmentId, env != via,
              composer.config(via)?.capabilities.contains(PeerLinkRPC.threadStreamCapability) == true else { return nil }
        let names = linkNames[via]
        let label = names?.labels[env]
        let stale = names.map { Date().timeIntervalSince($0.at) > 10 } ?? true
        let lacking = names != nil && label == nil && askedLinkNames.insert(via + "\u{0}" + env).inserted
        if stale || lacking, !readingLinkNames.contains(via) {
            readingLinkNames.insert(via)
            Task { [weak self] in
                guard let self else { return }
                let json = try? await self.environments.request(via, PeerLinkRPC.names, .object([:]))
                self.readingLinkNames.remove(via)
                let links = (try? json?["links"]?.decode(as: [PeerLinkName].self)) ?? []
                let labels = Dictionary(links.map { ($0.environmentId, $0.label) }, uniquingKeysWith: { a, _ in a })
                let changed = self.linkNames[via]?.labels != labels
                self.linkNames[via] = (Date(), labels)
                if changed { self.panel.model.linkedThreadsChanged() }
            }
        }
        return label
    }

func linkMetadataThread(_ link: ThreadLink, env: String, projects: [ProjectShell]) -> MarkdownContextChips.LinkedThread? {
        let owner = link.environmentId ?? env
        let ids = [link.threadId, link.percentDecoded?.threadId].compactMap { $0 }
        for id in ids {
            guard let found = linkMetadata[owner + "/" + id], let meta = found else { continue }
            let project = meta.projectId.flatMap { local in projects.first { $0.id.rawValue == EnvironmentScope.key(owner, local.rawValue) } }
            return MarkdownContextChips.LinkedThread(title: meta.title, project: project.map(ProjectIconSource.init),
                                                     destination: "t3-thread://v2/\(owner)/\(id)")
        }
        let key = owner + "/" + ids[0]
        guard linkMetadata[key] == nil, !linkMetadataLoading.contains(key),
              composer.config(owner)?.capabilities.contains(ThreadLinkMetadata.configFlag) == true else { return nil }
        linkMetadataLoading.insert(key)
        Task { [weak self] in
            let answer = try? await self?.environments.request(owner, ThreadLinkMetadata.method,
                                                               ThreadLinkMetadata.input(threadIds: ids.map { ThreadId($0) }))
            guard let self else { return }
            linkMetadataLoading.remove(key)
            let found = ThreadLinkMetadata.decode(answer)
            // A failed lookup is remembered as missing too, so relayouts don't ask again.
            for id in ids { linkMetadata[owner + "/" + id] = .some(found[ThreadId(id)]) }
            if !found.isEmpty { panel.model.linkedThreadsChanged() }
        }
        return nil
    }
}

/// The sidebar issue badge's live state (`useSidebarLinkedIssueState`, state/issues.ts at 5258, #39351): `issues.detail`
/// for each issue a thread links, where the server reads issues. Read again on a shell change five minutes on.
// ponytail: reads every linked issue of every row, not only rows on screen as T3's lease does; lease visible rows if lists grow
@MainActor
final class SidebarIssueStates {
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let capabilities: PullRequestCapabilities
    private var readAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    init(sidebar: SidebarContentView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.sidebar = sidebar
        self.environments = environments
        self.capabilities = capabilities
    }

    func sync(_ snapshot: ShellSnapshot) {
        let now = Date()
        for thread in snapshot.threads {
            guard let issues = thread.issues?.values, !issues.isEmpty, let env = thread.id.environmentId,
                  environments.session(env) != nil, capabilities.has(env, "issues") else { continue }
            for link in issues { read(link, env: env, now: now) }
        }
    }

    private func read(_ link: ThreadIssueLink, env: String, now: Date) {
        let key = SidebarIssueBadge.stateKey(environmentId: env, link)
        guard !inFlight.contains(key), readAt[key].map({ now.timeIntervalSince($0) > 300 }) ?? true else { return }
        inFlight.insert(key)
        let ref = IssueRef(projectId: link.projectId.rawValue, tracker: link.tracker, host: link.host, scope: link.scope, key: link.key)
        Task { [weak self, environments] in
            let detail = try? await environments.request(env, "issues.detail", .object(ref.json)).decode(as: IssueDetail.self)
            guard let self else { return }
            inFlight.remove(key)
            readAt[key] = Date()
            if let state = detail?.state, sidebar?.state.issueStates[key] != state { sidebar?.state.issueStates[key] = state }
        }
    }
}
