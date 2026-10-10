import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The built-in browser (PreviewView.tsx, ServerBrowserSurface.tsx, ThreadPreviewMiniPlayer.tsx).
/// Every tab is a server tab: the T3 server runs it in its own headless Chrome and this app views
/// and steers it over `/api/preview-stream` (previewRuntime.ts:20-29 picks `server` for every client
/// without a desktop browser runtime). The open thread's tabs come from `preview.list` plus
/// `subscribePreviewEvents`; a tab streams only while its panel tab or the floating player shows.
@MainActor
final class BrowserController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private weak var files: FilesController?
    private var view: BrowserPanelView { panel.browserPanel }

    /// `capabilities.serverBrowser` per environment, from its descriptor.
    private var serverBrowser: [String: Bool] = [:]
    private var capabilityTasks: Set<String> = []
    /// One `subscribePreviewEvents` per environment with an open thread.
    private var eventStreams: [String: (session: ShellSession, task: Task<Void, Never>)] = [:]
    /// Tab state per scoped thread key.
    private var states: [String: ThreadPreviewState] = [:]
    private var threadId: ThreadId?
    private var listTask: Task<Void, Never>?
    /// Tabs each thread had at the last reveal check, with their reveal request ids.
    private var revealBaseline: [String: [String: String]] = [:]

    private final class Stream {
        let key: String
        let tabId: String
        let client: PreviewStreamClient
        var refusals = 0
        var chooser: String?
        var cap: CGSize
        init(key: String, tabId: String, client: PreviewStreamClient, cap: CGSize) {
            self.key = key; self.tabId = tabId; self.client = client; self.cap = cap
        }
    }
    /// The panel's viewer and the floating player's.
    private var panelStream: Stream?
    private var miniStream: Stream?
    /// The panel viewer has control of its tab (the chrome row is live).
    private var panelControl = false
    private var panelFramed = false

    /// The floating player's tab per thread key, and where it was dragged.
    private var miniTab: [String: String] = [:]

    private var discovery: (environmentId: String, configured: [String], task: Task<Void, Never>)?
    private var discovered: [String: DiscoveredLocalServerList] = [:]
    private var history = BrowserHistory()
    private static let historyKey = "browser.history.v1"
    private var favicons: [String: NSImage] = [:]
    private var faviconRequests: Set<String> = []

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, files: FilesController) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.files = files
        if let data = UserDefaults.standard.data(forKey: Self.historyKey), let h = try? JSONDecoder().decode(BrowserHistory.self, from: data) { history = h }
        files.browserURL = { [weak self] tabId in self?.currentState?.sessions[tabId]?.navStatus.url }
        files.onBrowserTabsClosed = { [weak self] tabs in self?.closeTabs(tabs) }
        files.onReopenBrowser = { [weak self] thread, url in self?.reopen(thread: thread, url: url) }
        panel.onAddBrowser = { [weak self] in self?.createTab() }
        wireChrome()
        wireViewer(view.viewer, mini: false)
        wireViewer(panel.miniPlayer.viewer, mini: true)
        panel.miniPlayer.onOpenInPanel = { [weak self] in
            guard let self, let key = self.threadKey, let tab = self.miniTab[key] else { return }
            self.miniTab[key] = nil
            self.panel.mutatePanel { $0.openBrowser(tab); return [] }
            self.render()
        }
        panel.miniPlayer.onClose = { [weak self] in
            guard let self, let key = self.threadKey else { return }
            self.miniTab[key] = nil
            self.render()
        }
        panel.miniPlayer.onMove = { [weak self] origin in self?.panel.miniPlayerOrigin = origin }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    private var threadKey: String? { threadId?.rawValue }
    private var currentState: ThreadPreviewState? { threadKey.flatMap { states[$0] } }

    // MARK: Thread

    /// The panel's thread or state changed (`FilesController.onSync`).
    func sync() {
        let id = files?.currentThreadId
        if id != threadId { switchThread(id) }
        render()
    }

    private func switchThread(_ id: ThreadId?) {
        threadId = id
        listTask?.cancel()
        stopStream(mini: false)
        stopStream(mini: true)
        panel.miniPlayerOrigin = nil
        guard let id, let env = id.environmentId else {
            panel.browserAvailable = false
            return
        }
        panel.browserAvailable = serverBrowser[env] ?? false
        ensureCapability(env)
        for (e, s) in eventStreams where e != env { s.task.cancel(); eventStreams[e] = nil }
        if serverBrowser[env] == true { startSync(env, thread: id) }
    }

    private func ensureCapability(_ env: String) {
        guard serverBrowser[env] == nil, !capabilityTasks.contains(env), let shell = environments.session(env) else { return }
        capabilityTasks.insert(env)
        Task { [weak self] in
            let supported = (try? await shell.http.descriptor())?.capability("serverBrowser")
            guard let self else { return }
            self.capabilityTasks.remove(env)
            guard let supported else { return }
            self.serverBrowser[env] = supported
            if let id = self.threadId, id.environmentId == env {
                self.panel.browserAvailable = supported
                if supported { self.startSync(env, thread: id) }
                self.render()
            }
        }
    }

    /// `usePreviewSession`: the authoritative list, then the environment's event stream.
    private func startSync(_ env: String, thread: ThreadId) {
        guard let shell = environments.session(env) else { return }
        if eventStreams[env]?.session !== shell {
            eventStreams[env]?.task.cancel()
            let task = shell.supervisor.subscribe(PreviewRPC.events, payload: { .object([:]) }, handler: { [weak self] event in
                guard case .value(let json) = event, let e = try? JSONValueDecoder().decode(PreviewEvent.self, from: json) else { return }
                await MainActor.run { self?.apply(e, environmentId: env) }
            })
            eventStreams[env] = (shell, task)
        }
        fetchList(thread)
    }

    private func fetchList(_ thread: ThreadId) {
        guard let env = thread.environmentId, let shell = environments.session(env) else { return }
        listTask?.cancel()
        listTask = Task { [weak self] in
            guard let reply = try? await shell.supervisor.request(PreviewRPC.list, payload: .object(["threadId": .string(thread.localId.rawValue)])),
                  let list = try? JSONValueDecoder().decode(PreviewListResult.self, from: reply), !Task.isCancelled, let self else { return }
            self.mutateState(thread) { $0.reconcile(list) }
        }
    }

    private func apply(_ event: PreviewEvent, environmentId: String) {
        let key = EnvironmentScope.key(environmentId, event.threadId)
        guard states[key] != nil || key == threadKey else { return }
        let thread = ThreadId(key)
        var refetch = false
        mutateState(thread) { refetch = !$0.apply(event) }
        if refetch, thread == threadId { fetchList(thread) }
    }

    /// Applies a change to a thread's tabs and lets the panel follow (`reconcileBrowserSurfaces`
    /// runs only when the tab set changed, as ChatView's effect does).
    private func mutateState(_ thread: ThreadId, _ change: (inout ThreadPreviewState) -> Void) {
        let key = thread.rawValue
        var state = states[key] ?? ThreadPreviewState()
        let before = state
        change(&state)
        guard state != before else { return }
        states[key] = state
        guard thread == threadId else { return }
        let surfacesBefore = panel.panelState.surfaces
        if Set(state.sessions.keys) != Set(before.sessions.keys) || state.panelTabIds.hidden != before.panelTabIds.hidden {
            let tabs = state.panelTabIds
            if state.listLoaded { panel.mutatePanel { $0.reconcileBrowser(tabIds: tabs.all, hidden: tabs.hidden); return [] } }
        }
        checkReveals(state, key: key, surfaces: surfacesBefore)
        if let tab = miniTab[key], state.listLoaded, state.sessions[tab] == nil { miniTab[key] = nil }
        recordTitles(state)
        render()
    }

    /// An agent's new revealed tab floats over the chat unless the panel already lists it
    /// (ChatView.tsx:5529-5568, `browserAutoShowFloatingPreview` default on).
    private func checkReveals(_ state: ThreadPreviewState, key: String, surfaces: [RightPanelSurface]) {
        guard state.listLoaded else { return }
        let server = state.sessions.values.filter(\.isServerTab)
        let next = Dictionary(server.map { ($0.tabId, $0.revealRequest?.id ?? "") }, uniquingKeysWith: { a, _ in a })
        let previous = revealBaseline[key]
        revealBaseline[key] = next
        guard let previous else { return }
        for session in server {
            let requested = session.revealRequest
            let fresh = requested.map { previous[session.tabId] != $0.id } ?? (previous[session.tabId] == nil)
            guard fresh, session.reveal == true else { continue }
            let surface = surfaces.first { $0.browserTabId == session.tabId }
            if let surface, requested?.force == true {
                panel.mutatePanel { $0.activate(surface.id); return [] }
            } else if surface == nil {
                miniTab[key] = session.tabId
            }
        }
    }

    // MARK: Rendering

    /// The tab the panel's browser surface shows: its own, or the thread's active one for the placeholder.
    private var panelTab: (surface: RightPanelSurface, tabId: String?)? {
        guard let active = panel.panelState.active, active.kind == .browser else { return nil }
        return (active, active.browserTabId ?? currentState?.activeTabId)
    }

    private var windowVisible: Bool {
        guard let window = panel.window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private func render() {
        let state = currentState ?? ThreadPreviewState()
        // Tab titles and favicons.
        var titles: [String: String] = [:], icons: [String: NSImage] = [:]
        for surface in panel.panelState.surfaces where surface.kind == .browser {
            guard let tab = surface.browserTabId, let snapshot = state.sessions[tab] else { continue }
            titles[surface.id] = snapshot.tabTitle
            if let url = PreviewURL.faviconURL(for: snapshot.navStatus.url) {
                if let image = favicons[url.absoluteString] { icons[surface.id] = image } else { fetchFavicon(url) }
            }
        }
        panel.browserTitles = titles
        panel.browserFavicons = icons

        let visible = panel.panelState.isOpen && windowVisible && panel.window != nil
        if let (_, tabId) = panelTab, visible {
            renderPanel(tabId: tabId, state: state)
        } else {
            stopStream(mini: false)
            stopDiscovery()
        }

        // The floating player: its tab unless the panel shows that tab right now.
        let key = threadKey
        let tab = key.flatMap { miniTab[$0] }
        let shownInPanel = panel.panelState.isOpen && panelTab?.tabId == tab
        if let tab, let snapshot = state.sessions[tab], snapshot.isServerTab, !shownInPanel, windowVisible {
            panel.miniPlayerShown = true
            ensureStream(mini: true, tabId: tab)
        } else {
            panel.miniPlayerShown = false
            stopStream(mini: true)
        }
        view.chrome.pictureInPictureActive = tab != nil && tab == panelTab?.tabId
    }

    private func renderPanel(tabId: String?, state: ThreadPreviewState) {
        let snapshot = tabId.flatMap { state.sessions[$0] }
        let isServer = snapshot?.isServerTab ?? false
        let nav = snapshot?.navStatus ?? .idle
        let inputDisabled = isServer && !panelControl
        let chrome = view.chrome
        chrome.url = nav.url ?? ""
        chrome.loading = nav.isLoading || (isServer && !nav.isIdle && !nav.isFailed && !panelFramed)
        chrome.canGoBack = (snapshot?.canGoBack ?? false) && !inputDisabled
        chrome.canGoForward = (snapshot?.canGoForward ?? false) && !inputDisabled
        chrome.refreshDisabled = nav.isIdle || inputDisabled
        chrome.inputDisabled = inputDisabled
        if tabId == nil { chrome.onOpenExternal = nil } else { chrome.onOpenExternal = { [weak self] in self?.openExternal() } }
        if tabId == nil || !isServer {
            chrome.onPictureInPicture = nil
        } else {
            chrome.onPictureInPicture = { [weak self] in self?.togglePictureInPicture() }
        }
        chrome.pictureInPictureDisabled = nav.isFailed
        if snapshot == nil { chrome.onMore = nil } else { chrome.onMore = { [weak self] anchor in self?.showMoreMenu(anchor) } }

        view.hasServerTab = isServer
        switch nav {
        case .idle: view.body = .empty
        case .loadFailed(let url, _, let code, let description, let download):
            view.body = .unreachable
            if let download {
                view.unreachable.onDownload = { [weak self] in self?.saveDownload(id: download.id, fileName: download.fileName) }
                view.unreachable.content = .fileNotShown(url: url, fileName: download.fileName)
            } else {
                view.unreachable.content = .failed(url: url, code: code, description: description)
            }
        default: view.body = .page
        }
        if isServer, let tabId { ensureStream(mini: false, tabId: tabId) } else { stopStream(mini: false) }
        if view.body == .empty { renderEmptyState() } else { stopDiscovery() }
    }

    // MARK: Empty state

    private var projectKey: String? {
        guard let id = threadId, let env = id.environmentId,
              let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }) else { return nil }
        return env + ":" + thread.projectId.rawValue
    }

    private func renderEmptyState() {
        guard let id = threadId, let env = id.environmentId else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let recents = (projectKey.map { history.entries($0) } ?? []).filter { URL(string: $0.url) != nil }.prefix(BrowserHistory.shown).map { e in
            BrowserEmptyStateView.Recent(url: e.url, title: e.title,
                                         visited: TimestampFormat.formatRelativeTimeLabel(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: e.lastVisitedAt / 1000)), nowMs: now))
        }
        let configured = LocalServerDiscovery.boundConfiguredUrls(configuredUrls())
        let list = discovered[env]
        let servers = LocalServerDiscovery.merge(scanner: list?.servers ?? [], configuredUrls: configured, configuredUrlProbing: list?.configuredUrlProbing)
        view.empty.apply(recents: Array(recents), servers: servers)
        startDiscovery(env, configured: configured)
    }

    /// `getConfiguredPreviewUrls`: the project's scripts' `previewUrl`s.
    private func configuredUrls() -> [String] {
        guard let id = threadId, let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }),
              let project = sidebar?.snapshot?.projects.first(where: { $0.id == thread.projectId }) else { return [] }
        return project.scripts.compactMap { $0["previewUrl"]?.stringValue }
    }

    /// `subscribeDiscoveredLocalServers` while the empty state shows.
    private func startDiscovery(_ env: String, configured: [String]) {
        if let d = discovery, d.environmentId == env, d.configured == configured { return }
        stopDiscovery()
        guard let shell = environments.session(env) else { return }
        let payload: JSONValue = configured.isEmpty ? .object([:]) : .object(["configuredUrls": .array(configured.map { .string($0) })])
        let task = shell.supervisor.subscribe(PreviewRPC.discoveredServers, payload: { payload }, handler: { [weak self] event in
            guard case .value(let json) = event, let list = try? JSONValueDecoder().decode(DiscoveredLocalServerList.self, from: json) else { return }
            await MainActor.run {
                guard let self, self.discovered[env] != list else { return }
                self.discovered[env] = list
                self.render()
            }
        })
        discovery = (env, configured, task)
    }

    private func stopDiscovery() {
        discovery?.task.cancel()
        discovery = nil
    }

    // MARK: Streams

    private func ensureStream(mini: Bool, tabId: String) {
        guard let id = threadId, let env = id.environmentId, let shell = environments.session(env) else { return }
        let key = "\(id.rawValue)\u{0}\(tabId)"
        if let s = mini ? miniStream : panelStream, s.key == key { return }
        stopStream(mini: mini)
        let viewer = mini ? panel.miniPlayer.viewer : view.viewer
        viewer.reset()
        viewer.accessDenied = false
        viewer.hostSetup = nil
        let scale = panel.window?.backingScaleFactor ?? 2
        // The frame cap in device px grows with the surface and never shrinks (`cap`).
        let size = mini ? CGSize(width: 1280, height: 800) : view.bounds.size
        let cap = CGSize(width: max(1, size.width * scale).rounded(), height: max(1, size.height * scale).rounded())
        startClient(key: key, tabId: tabId, mini: mini, shell: shell, threadLocal: id.localId.rawValue, cap: cap)
    }

    private func startClient(key: String, tabId: String, mini: Bool, shell: ShellSession, threadLocal: String, cap: CGSize, refusals: Int = 0) {
        let viewer = mini ? panel.miniPlayer.viewer : view.viewer
        let http = shell.http, token = shell.token
        var events = PreviewStreamClient.Events()
        var streamRef: Stream?
        events.onFrame = { [weak self] image in
            viewer.setFrame(image)
            if !mini, self?.panelFramed == false { self?.panelFramed = true; self?.render() }
        }
        events.onMessage = { [weak self] message in self?.handle(message, viewer: viewer, mini: mini, stream: streamRef) }
        events.onConnectedChange = { [weak self] connected in
            guard !connected else { return }
            viewer.control = nil
            viewer.fileChooser = nil
            if !mini, self?.panelControl == true { self?.panelControl = false; self?.render() }
        }
        events.onUnauthorized = { [weak self] in
            // Fresh tickets reconnect; three refusals in a row need an explicit retry.
            guard let self, let s = streamRef else { return }
            let count = s.refusals + 1
            if count >= 3 { viewer.accessDenied = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (count == 1 ? 0 : pow(2, Double(count - 1)))) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, (mini ? self.miniStream : self.panelStream) === s else { return }
                    self.startClient(key: key, tabId: tabId, mini: mini, shell: shell, threadLocal: threadLocal, cap: s.cap, refusals: count)
                }
            }
        }
        events.onGone = { [weak self] in self?.stopStream(mini: mini) }
        events.onHostSetup = { setup in viewer.hostSetup = setup }
        let client = PreviewStreamClient(url: {
            let ticket = try await http.webSocketTicket(token: token)
            guard let url = PreviewStream.socketURL(base: http.baseURL, threadId: threadLocal, tabId: tabId,
                                                    maxWidth: Int(cap.width), maxHeight: Int(cap.height), ticket: ticket.ticket) else {
                throw URLError(.badURL)
            }
            return url
        }, events: events)
        let stream = Stream(key: key, tabId: tabId, client: client, cap: cap)
        stream.refusals = refusals
        streamRef = stream
        (mini ? miniStream : panelStream)?.client.stop()
        if mini { miniStream = stream } else { panelStream = stream; panelControl = false; panelFramed = false }
        client.start()
    }

    private func stopStream(mini: Bool) {
        guard let s = mini ? miniStream : panelStream else { return }
        s.client.stop()
        if mini { miniStream = nil } else { panelStream = nil; panelControl = false; panelFramed = false }
        let viewer = mini ? panel.miniPlayer.viewer : view.viewer
        viewer.reset()
    }

    private func handle(_ message: PreviewStream.Message, viewer: ServerBrowserView, mini: Bool, stream: Stream?) {
        switch message {
        case .viewport(let w, let h):
            viewer.viewport = CGSize(width: w, height: h)
            if mini { panel.miniPlayerSource = CGSize(width: w, height: h) }
        case .control(let control):
            let had = viewer.control?.controller == .you
            viewer.control = control
            if control.controller == .you, !had, !mini, let size = viewer.frameSize {
                stream?.client.send(.resize(width: Int(size.width), height: Int(size.height)))
            }
            if !mini, panelControl != (control.controller == .you) { panelControl = control.controller == .you; render() }
        case .clipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .download(let id, let fileName, _):
            panel.toasts.show(ToastView(title: "Downloaded \(fileName)", kind: .info, actionTitle: "Save", action: { [weak self] in
                self?.saveDownload(id: id, fileName: fileName)
            }))
        case .fileChooser(let id, let multiple, let accept):
            stream?.chooser = id
            viewer.fileChooser = (multiple, accept)
        case .fileChooserClosed(let id):
            if stream?.chooser == id { stream?.chooser = nil; viewer.fileChooser = nil }
        case .popup(let tabId):
            // `showPreviewPopup`: a floating opener floats the popup, else the panel switches to it.
            whenKnown(tabId) { [weak self] in
                guard let self, let key = self.threadKey else { return }
                if mini { self.miniTab[key] = tabId } else { self.panel.mutatePanel { $0.openBrowser(tabId); return [] } }
                self.render()
            }
        case .pointer(let phase, let x, let y, let sequence):
            viewer.showPointer(phase: phase, x: x, y: y, sequence: sequence)
        case .probe:
            break
        }
    }

    /// `whenPreviewTabKnown`: runs once the tab is in the thread's list.
    private func whenKnown(_ tabId: String, attempts: Int = 20, _ body: @escaping () -> Void) {
        if currentState?.sessions[tabId] != nil { body(); return }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.whenKnown(tabId, attempts: attempts - 1, body) }
        }
    }

    private func wireViewer(_ viewer: ServerBrowserView, mini: Bool) {
        viewer.onInput = { [weak self] input in
            guard let s = mini ? self?.miniStream : self?.panelStream else { return }
            s.client.send(input)
        }
        viewer.onSizeChange = { [weak self] size in
            guard let self, let s = mini ? self.miniStream : self.panelStream else { return }
            // The floating player scales the page instead of resizing it (`followSize={false}`).
            if !mini { s.client.send(.resize(width: Int(size.width), height: Int(size.height))) }
            let scale = self.panel.window?.backingScaleFactor ?? 2
            let need = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            if need.width > s.cap.width || need.height > s.cap.height, let id = self.threadId, let env = id.environmentId,
               let shell = self.environments.session(env) {
                // Outgrowing the cap reconnects with a bigger one.
                let cap = CGSize(width: max(need.width, s.cap.width), height: max(need.height, s.cap.height))
                self.startClient(key: s.key, tabId: s.tabId, mini: mini, shell: shell, threadLocal: id.localId.rawValue, cap: cap)
            }
        }
        viewer.onChooseFiles = { [weak self] urls in self?.upload(urls, mini: mini) }
        viewer.onRetryHostSetup = { [weak self] in self?.restart(mini: mini) }
        viewer.onReconnect = { [weak self] in self?.restart(mini: mini) }
    }

    private func restart(mini: Bool) {
        guard let s = mini ? miniStream : panelStream, let id = threadId, let env = id.environmentId,
              let shell = environments.session(env) else { return }
        startClient(key: s.key, tabId: s.tabId, mini: mini, shell: shell, threadLocal: id.localId.rawValue, cap: s.cap)
    }

    // MARK: Files

    /// `uploadPreviewStreamFiles`: multipart `file` parts to the page's open picker; none cancels it.
    private func upload(_ urls: [URL], mini: Bool) {
        guard let s = mini ? miniStream : panelStream, let chooser = s.chooser, let id = threadId, let env = id.environmentId,
              let shell = environments.session(env) else { return }
        s.chooser = nil
        let http = shell.http, token = shell.token, tab = s.tabId, thread = id.localId.rawValue
        Task { [weak self] in
            do {
                let ticket = try await http.webSocketTicket(token: token)
                guard let url = PreviewStream.httpURL(base: http.baseURL, route: "upload", query: [("threadId", thread), ("tabId", tab), ("chooser", chooser)],
                                                      ticket: ticket.ticket) else { return }
                let boundary = "candywrapper-\(UUID().uuidString)"
                var body = Data()
                for file in urls {
                    let data = try Data(contentsOf: file)
                    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
                    body.append(data)
                    body.append(Data("\r\n".utf8))
                }
                body.append(Data("--\(boundary)--\r\n".utf8))
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let (reply, response) = try await URLSession.shared.upload(for: request, from: body)
                if ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 != 2 {
                    let text = String(decoding: reply, as: UTF8.self)
                    throw NSError(domain: "preview", code: 0, userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "The upload was refused." : text])
                }
            } catch {
                self?.panel.toasts.show(ToastView(title: "Could not send the files to the page", message: error.localizedDescription, kind: .error))
            }
        }
    }

    /// The download happened on the environment; this saves the finished file on this Mac.
    private func saveDownload(id downloadId: String, fileName: String) {
        guard let tab = panelTab?.tabId ?? panelStream?.tabId, let id = threadId, let env = id.environmentId,
              let shell = environments.session(env), let window = panel.window else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = fileName
        let http = shell.http, token = shell.token, thread = id.localId.rawValue
        save.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = save.url else { return }
            Task { @MainActor in
                do {
                    let ticket = try await http.webSocketTicket(token: token)
                    guard let url = PreviewStream.httpURL(base: http.baseURL, route: "download", query: [("threadId", thread), ("tabId", tab), ("id", downloadId)],
                                                          ticket: ticket.ticket) else { return }
                    let (file, _) = try await URLSession.shared.download(from: url)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: file, to: target)
                } catch {
                    self?.panel.toasts.show(ToastView(title: "Could not save \(fileName)", message: error.localizedDescription, kind: .error))
                }
            }
        }
    }

    // MARK: Actions

    private func wireChrome() {
        let chrome = view.chrome
        chrome.onBack = { [weak self] in self?.panelStream?.client.send(.history(delta: -1)) }
        chrome.onForward = { [weak self] in self?.panelStream?.client.send(.history(delta: 1)) }
        chrome.onRefresh = { [weak self] in self?.panelStream?.client.send(.reload(ignoreCache: false)) }
        chrome.onSubmit = { [weak self] text in
            // Only empty input or an unsupported scheme fails; the bar keeps the text.
            guard let self, let url = PreviewURL.resolveAddressBarInput(text) else { return }
            if self.navigate(to: url) { self.recordVisit(url) }
        }
        view.empty.onOpen = { [weak self] raw in
            // A server tab's browser runs on the environment, where loopback is already right.
            guard let self, let url = PreviewURL.normalize(raw) else { return }
            if self.navigate(to: url) { self.recordVisit(raw) }
        }
        view.empty.onRemoveRecent = { [weak self] url in
            guard let self, let key = self.projectKey else { return }
            self.history.remove(key, url: url)
            self.saveHistory()
            self.render()
        }
        view.unreachable.onReload = { [weak self] in self?.panelStream?.client.send(.reload(ignoreCache: false)) }
        view.unreachable.onOpenExternal = { [weak self] in self?.openExternal() }
    }

    /// `navigateToResolvedUrl`: the server tab's viewer navigates (it needs control); without a
    /// tab, `preview.open` makes one at the URL.
    private func navigate(to url: String) -> Bool {
        let snapshot = panelTab?.tabId.flatMap { currentState?.sessions[$0] }
        if snapshot?.isServerTab == true, let stream = panelStream {
            guard panelControl else { return false }
            return stream.client.send(.navigate(url: url))
        }
        openTab(url: url)
        return true
    }

    /// `createBrowserSurface`: a new server tab, then the panel shows it.
    private func createTab() { openTab(url: nil) }

    private func openTab(url: String?) {
        guard let id = threadId, let env = id.environmentId, let shell = environments.session(env) else { return }
        Task { [weak self] in
            do {
                let reply = try await shell.supervisor.request(PreviewRPC.open, payload: PreviewRPC.openPayload(threadId: id.localId.rawValue, url: url))
                let snapshot = try JSONValueDecoder().decode(PreviewSessionSnapshot.self, from: reply)
                guard let self else { return }
                self.mutateState(id) { $0.applyOpened(snapshot) }
                if self.threadId == id { self.panel.mutatePanel { $0.openBrowser(snapshot.tabId); return [] } }
                self.render()
            } catch {
                self?.panel.toasts.show(ToastView(title: "Unable to open browser", message: "\(error)", kind: .error))
            }
        }
    }

    /// `reopenClosedView` for a server tab: a new tab at the closed one's page.
    private func reopen(thread: ThreadId, url: String?) {
        guard thread == threadId else {
            // The thread opens first; its sync runs before this retry.
            DispatchQueue.main.async { [weak self] in if self?.threadId == thread { self?.openTab(url: url) } }
            return
        }
        openTab(url: url)
    }

    /// The panel closed browser tabs: `preview.close` each (`closePreviewSession`), optimistically.
    private func closeTabs(_ tabs: [String]) {
        guard let id = threadId, let env = id.environmentId, let shell = environments.session(env) else { return }
        for tab in tabs {
            let snapshot = currentState?.sessions[tab]
            mutateState(id) { $0.beginClose(tab) }
            Task { [weak self] in
                do {
                    _ = try await shell.supervisor.request(PreviewRPC.close, payload: .object(["threadId": .string(id.localId.rawValue), "tabId": .string(tab)]))
                } catch {
                    self?.mutateState(id) { $0.cancelClose(snapshot, tabId: tab) }
                }
            }
        }
    }

    private func openExternal() {
        guard let tab = panelTab?.tabId, let url = currentState?.sessions[tab]?.navStatus.url, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    /// `handlePictureInPicture`: floats the tab over the chat and closes the panel, or closes the float.
    private func togglePictureInPicture() {
        guard let key = threadKey, let tab = panelTab?.tabId else { return }
        if miniTab[key] == tab {
            miniTab[key] = nil
        } else {
            miniTab[key] = tab
            panel.mutatePanel { $0.isOpen = false; return [] }
        }
        render()
    }

    /// `PreviewMoreMenu` for a server tab: every action goes through `preview.adjust`.
    private func showMoreMenu(_ anchor: NSView) {
        guard let tab = panelTab?.tabId, let snapshot = currentState?.sessions[tab] else { return }
        let zoom = snapshot.zoomFactor ?? 1
        let cluster = BrowserMoreMenu.ZoomCluster()
        let actions = BrowserMoreMenu.Actions(
            hardReload: { [weak self] in self?.adjust(tab, ["hardReload": .bool(true)]) },
            setColorScheme: { [weak self] scheme in self?.adjust(tab, ["colorScheme": .string(scheme)]) },
            zoom: { [weak self, weak cluster] direction in
                guard let self, let current = self.currentState?.sessions[tab]?.zoomFactor ?? Optional(1.0),
                      let next = PreviewRPC.steppedZoom(from: current, direction: direction) else { return }
                cluster?.zoomFactor = next
                self.adjust(tab, ["zoomFactor": .number(next)])
            },
            clearCookies: { [weak self] in self?.adjust(tab, ["clear": .string("cookies")]) },
            clearCache: { [weak self] in self?.adjust(tab, ["clear": .string("cache")]) })
        let items = BrowserMoreMenu.items(enabled: true, zoomFactor: zoom, colorScheme: snapshot.colorScheme ?? "system",
                                          deviceToolbarVisible: snapshot.hasFixedViewport, profileName: "Default", actions: actions, zoomLabel: cluster)
        MenuPopupView.show(items, from: anchor, placement: .dropdown)
    }

    private func adjust(_ tab: String, _ change: [String: JSONValue]) {
        guard let id = threadId, let env = id.environmentId, let shell = environments.session(env) else { return }
        var payload = change
        payload["threadId"] = .string(id.localId.rawValue)
        payload["tabId"] = .string(tab)
        Task { [weak self] in
            do {
                let reply = try await shell.supervisor.request(PreviewRPC.adjust, payload: .object(payload))
                let snapshot = try JSONValueDecoder().decode(PreviewSessionSnapshot.self, from: reply)
                self?.mutateState(id) { $0.update(snapshot) }
            } catch {
                self?.panel.toasts.show(ToastView(title: "Unable to change the browser tab", message: "\(error)", kind: .error))
            }
        }
    }

    // MARK: History and favicons

    private func recordVisit(_ url: String) {
        guard let key = projectKey else { return }
        history.recordVisit(key, url: url, at: Date().timeIntervalSince1970 * 1000, environmentHost: environmentHost)
        saveHistory()
    }

    /// Agent-driven pages only enrich a URL already in the history.
    private func recordTitles(_ state: ThreadPreviewState) {
        guard let key = projectKey, !history.entries(key).isEmpty else { return }
        let before = history
        for snapshot in state.sessions.values {
            if case .success(let url, let title) = snapshot.navStatus, !title.isEmpty {
                history.setTitle(key, url: url, title: title, environmentHost: environmentHost)
            }
        }
        if history != before { saveHistory() }
    }

    private var environmentHost: String? {
        threadId?.environmentId.flatMap { environments.session($0)?.http.baseURL.host }
    }

    private func saveHistory() {
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }

    /// `PreviewFavicon`: Google's favicon service for public hosts, cached for the session.
    private func fetchFavicon(_ url: URL) {
        let key = url.absoluteString
        guard !faviconRequests.contains(key) else { return }
        faviconRequests.insert(key)
        Task { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2, let image = NSImage(data: data), let self else { return }
            self.favicons[key] = image
            self.render()
        }
    }

    // MARK: Shortcuts

    /// Keyboard focus is inside the browser panel (`isPreviewFocused`).
    var isFocused: Bool {
        guard let responder = panel.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func registerShortcuts(_ shortcuts: Shortcuts) {
        // `preview.toggle` (ChatView.tsx:5875-5893): closes an open browser panel, else opens the
        // thread's active tab or a new one.
        shortcuts.on("preview.toggle") { [weak self] call in
            guard let self, !call.isRepeat, self.threadId != nil else { return false }
            guard self.panel.browserAvailable else {
                self.panel.toasts.show(ToastView(title: "Preview is desktop-only", message: "Open T3 Code in the desktop app to use the in-app preview.", kind: .info))
                return true
            }
            if self.panel.panelState.isOpen, self.panel.panelState.active?.kind == .browser {
                self.panel.mutatePanel { $0.isOpen = false; return [] }
            } else if let tab = self.currentState?.activeTabId {
                self.panel.mutatePanel { $0.openBrowser(tab); return [] }
            } else {
                self.createTab()
            }
            return true
        }
        shortcuts.on(["preview.refresh", "preview.focusUrl", "preview.zoomIn", "preview.zoomOut", "preview.resetZoom"]) { [weak self] call in
            guard let self, self.panelTab != nil else { return false }
            switch call.command {
            case "preview.refresh": self.panelStream?.client.send(.reload(ignoreCache: false))
            case "preview.focusUrl": self.view.chrome.focusAddress()
            default:
                guard let tab = self.panelTab?.tabId, let current = self.currentState?.sessions[tab] else { return true }
                let direction = call.command == "preview.zoomIn" ? 1 : call.command == "preview.zoomOut" ? -1 : 0
                if let next = PreviewRPC.steppedZoom(from: current.zoomFactor ?? 1, direction: direction) { self.adjust(tab, ["zoomFactor": .number(next)]) }
            }
            return true
        }
    }

    /// A removed environment's tab state goes with it.
    func environmentRemoved(_ environmentId: String) {
        let prefix = environmentId + ":"
        states = states.filter { !$0.key.hasPrefix(prefix) }
        miniTab = miniTab.filter { !$0.key.hasPrefix(prefix) }
        eventStreams[environmentId]?.task.cancel()
        eventStreams[environmentId] = nil
        serverBrowser[environmentId] = nil
    }

    /// The environment's session changed (reconnect): the list is fetched again.
    func sessionChanged(_ environmentId: String) {
        eventStreams[environmentId]?.task.cancel()
        eventStreams[environmentId] = nil
        if let id = threadId, id.environmentId == environmentId, serverBrowser[environmentId] == true { startSync(environmentId, thread: id) }
    }
}
