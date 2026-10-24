import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The Orchestrator (docs/orchestrator.md, phase 1 in docs/orchestrator-phase1.md): one ordinary T3 thread per machine
/// that manages every thread there through T3's own thread tools. This side starts it with its brief, sends your
/// messages with an updated brief when the brief changed, relays other threads' turn ends, failures and requests,
/// keeps its sidebar row and pane current, and hands its "while closed" schedule to T3 when the app quits.
///
/// Nothing here exists while the toggle is off or Redesign isn't the theme: no views, no feed, no relay state.
@MainActor
final class OrchestratorController {
    private let environments: Environments
    private weak var sidebar: SidebarContentView?
    private let threads: ThreadController
    private var store: OrchestratorStore { .shared }
    private var config: OrchestratorConfig { store.config }

    /// Shows the pane in the main area; set by the app.
    var showPane: (OrchestratorPaneView) -> Void = { _ in }
    var toast: (String, String?, ToastQueue.Kind) -> Void = { _, _, _ in }

    /// The pane, only while it shows.
    private(set) var pane: OrchestratorPaneView?
    private var feed: OrchestratorThreadFeed?
    private var projection: ThreadProjection?
    /// Each machine's threads as last seen, the baseline for events; reset with each new session.
    private var baselines: [String: (session: ObjectIdentifier, threads: [ThreadId: ThreadShell])] = [:]
    /// Runs its `orchestrator-call` blocks on every machine.
    private let remote: OrchestratorRemote
    private var batch = OrchestratorEventBatch()
    private var flushWork: DispatchWorkItem?
    private var starting = false
    /// Notes a reply saved this session, by message id, with what they replaced, for Undo.
    private var memoryUndo: [String: [(note: String, previous: String)]] = [:]
    private var undone: Set<String> = []
    private var scheduleSynced: Set<String> = []
    /// Whether this Mac or the Android app relays for the Orchestrator (`OrchestratorHandoff`).
    private var handoff = OrchestratorHandoff()
    /// Machines already searched this session for an Orchestrator thread to adopt.
    private var adoptionTried: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    /// Images waiting to go with your next message, kept while you leave the pane.
    // ponytail: kept in memory only; a relaunch drops unsent images, persist them like the thread composer's if that bites
    private var pendingImages: [ComposerAttachment] = []
    private var uploads: [String: Task<Void, Never>] = [:]
    /// Signed page URLs by attachment id, reused while they have 5 minutes left (HtmlRenderFrame.tsx:62-92).
    private var pageURLs: [String: (url: URL, expires: Date)] = [:]
    private var wasActive = false
    /// The settings documents last seen on its machine, by prompt; nil until that machine's task list loads.
    private var seenSettings: [String]?
    /// The machine the settings sync with, to tell when it moved.
    private var settingsMachine: String?
    /// The stamps last merged, to tell your edits from the other devices'.
    private var syncedStamps: [String: OrchestratorSettingsSync.Stamp] = [:]
    private var settingsChain: Task<Void, Never>?
    private var settingsPush: DispatchWorkItem?

    init(environments: Environments, sidebar: SidebarContentView, threads: ThreadController) {
        self.environments = environments
        self.sidebar = sidebar
        self.threads = threads
        remote = OrchestratorRemote(environments: environments, threads: threads)
        store.actions.start = { [weak self] in self?.start() }
        store.actions.open = { [weak self] in self?.open() }
        store.actions.status = { [weak self] in self?.statusText ?? "Not started" }
        store.observe { [weak self] in self?.configChanged() }
        _ = ScheduledTasksStore.shared.observe { [weak self] in self?.settingsListChanged() }
        environments.observeShell { [weak self] in self?.shellChanged() }
        sidebar.actions.openOrchestrator = { [weak self] in self?.open() }
        // A rename changes the brief's {{name}}, so it goes out as an updated brief with your next message.
        sidebar.actions.renameOrchestrator = { name in OrchestratorStore.shared.update { $0.name = name } }
        remote.homeId = { [weak self] in self?.machineId }
        remote.orchestrator = { [weak self] in self?.threadId }
        remote.rows = { [weak self] in self?.availableRows($0) ?? [] }
        remote.mayRelay = { [weak self] in await self?.mayRelay() ?? false }
        // Asleep, the Mac can't tell who held the task meanwhile: it takes it back when it wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        remote.reply = { [weak self] text in
            guard let self, self.active, let env = self.machineId, let id = self.threadId else { return }
            self.dispatch(text, to: id, env: env)
        }
        configChanged()
    }

    // MARK: State

    private var active: Bool { store.isActive }
    /// The machine it runs on: the one picked in Settings, else the primary.
    var machineId: String? { config.environmentId ?? environments.primaryId }
    private var machine: OrchestratorMachine? { machineId.flatMap { config.machines[$0] } }
    /// Its thread on its machine, scoped.
    var threadId: ThreadId? { machineId.flatMap { config.threadId(on: $0) } }
    private var machineLabel: String { machineId.flatMap { environments.label($0) } ?? "this Mac" }
    private var connected: Bool { machineId.flatMap { environments.session($0) } != nil && machineId.map { environments.state($0)?.status == .connected } == true }
    private func shell(_ env: String) -> ShellSnapshot? { environments.snapshot(env) }

    private var orchestratorShell: ThreadShell? {
        guard let env = machineId, let local = machine?.threadId else { return nil }
        return shell(env)?.threads.first { $0.id.rawValue == local } ?? shell(env)?.archivedThreads.first { $0.id.rawValue == local }
    }

    private var statusText: String {
        guard let env = machineId else { return "No machine" }
        guard machine != nil else { return environments.session(env) == nil ? "\(machineLabel) is offline" : "Not started on \(machineLabel)" }
        guard let t = orchestratorShell else { return "Running on \(machineLabel)" }
        return OrchestratorEvent.running.contains(t.status) ? "Working on \(machineLabel)" : "Running on \(machineLabel), in “\(t.title)”"
    }

    private func configChanged() {
        let nowActive = active
        if !nowActive {
            if wasActive { tearDown() }
            wasActive = false
            return
        }
        wasActive = true
        watchSettings()
        settingsEdited()
        syncSchedules(enabled: false)
        refreshViews()
    }

    /// The toggle went off or the theme changed: drop every view and every piece of relay state.
    private func tearDown() {
        flushWork?.cancel()
        flushWork = nil
        batch.reset()
        baselines = [:]
        remote.reset()
        handoff.forget()
        adoptionTried = []
        feed?.stop()
        feed = nil
        projection = nil
        if pane != nil { closePane() }
        sidebar?.orchestrator = nil
        sidebar?.state.hiddenThreadIds = []
        ScheduledTasksStore.shared.watch("orchestrator", [])
        settingsPush?.cancel()
        settingsPush = nil
        seenSettings = nil
        settingsMachine = nil
    }

    private func shellChanged() {
        guard active else { return }
        // At launch the primary machine is known only once its shell arrives.
        watchSettings()
        // At launch the schedule turns off once its machine's shell has the thread.
        syncSchedules(enabled: false)
        forgetVanishedThread()
        adoptIfNeeded()
        remote.orchestratorChanged(orchestratorShell)
        relay()
        refreshViews()
    }

    /// An Orchestrator thread that was archived or deleted is gone: Start makes a new one.
    private func forgetVanishedThread() {
        guard let env = machineId, let local = machine?.threadId, let snapshot = shell(env) else { return }
        let live = snapshot.threads.first { $0.id.rawValue == local }
        guard live == nil || live?.deletedAt != nil || live?.archivedAt != nil else { return }
        // A shell still filling in after launch may not list it yet; an archived copy says it is gone.
        guard live != nil || snapshot.archivedThreads.contains(where: { $0.id.rawValue == local }) else { return }
        store.update { $0.machines[env] = nil }
    }

    // MARK: Sidebar and pane

    private func refreshViews() {
        guard active, let sidebar else { return }
        let env = machineId
        sidebar.state.hiddenThreadIds = Set(config.machines.map { ThreadId($0.value.threadId).scoped(to: $0.key) })
        let needs = currentNeeds()
        let working = orchestratorShell.map { OrchestratorEvent.running.contains($0.status) } ?? false
        sidebar.orchestrator = OrchestratorSidebarInfo(name: config.displayName, machine: machineLabel,
                                                       machineKind: env.flatMap { environments.machine($0) } ?? "laptop", bot: config.bot, needsYou: needs.count,
                                                       working: working, started: machine != nil, isOpen: pane != nil)
        guard let pane else { return }
        var state = OrchestratorPaneState()
        state.name = config.displayName
        state.bot = config.bot
        state.machine = machineLabel
        state.environmentId = env ?? ""
        state.started = machine != nil
        state.connected = connected
        state.working = working
        state.needs = needs
        state.crew = crewCards()
        if let projection {
            let running = projection.runs.contains { OrchestratorEvent.running.contains($0.status) }
            state.items = OrchestratorChat.items(messages: projection.messages, turnItems: projection.turnItems, running: running)
        }
        state.undoable = Set(memoryUndo.keys).subtracting(undone)
        state.undone = undone
        state.pendingImages = pendingImages
        state.threadLocalId = machine?.threadId ?? ""
        // A question it asked with its question tool, the oldest first, as the thread composer shows it.
        state.question = projection.flatMap { PendingRequests.derive($0).activeUserInput }
        pane.set(state)
    }

    func open() {
        guard active else { return }
        let view = pane ?? {
            let p = OrchestratorPaneView()
            p.onSend = { [weak self] text in self?.send(text) }
            p.onOpenThread = { [weak self] id in self.map { $0.sidebar?.actions.openThread($0.locate(id)) } }
            p.onRespond = { [weak self] need, decision in self?.respond(need, decision) }
            p.onUndoMemory = { [weak self] id in self?.undoMemory(id) }
            p.onStart = { [weak self] in self?.start() }
            p.onOpenAsThread = { [weak self] in if let id = self?.threadId { self?.sidebar?.actions.openThread(id) } }
            p.onEditBot = { [weak self] in self?.openSettings() }
            // The draft is the thread's own, kept by the thread composer's store (composer.prompts.v1).
            p.onDraftChange = { [weak self] text in
                guard let self, let id = self.threadId else { return }
                self.threads.composer.setDraftText(text, for: id)
            }
            p.onImages = { [weak self] files in self?.addImages(files) }
            p.onRemoveImage = { [weak self] id in self?.removeImage(id) }
            p.imageLoader = { [weak self] id, side in await self?.sentImage(id, side: side) }
            p.onAnswer = { [weak self] payload in self?.answer(payload) }
            p.webAssetURL = { [weak self] id, name in await self?.pageURL(id, name: name) }
            pane = p
            return p
        }()
        startFeed()
        refreshViews()
        if let id = threadId { view.setDraft(threads.composer.draftText(id)) }
        showPane(view)
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        view.focusComposer()
    }

    /// The app took the main area back: the pane and its feed go away.
    func paneClosed() {
        pane = nil
        feed?.stop()
        feed = nil
        projection = nil
        refreshViews()
    }

    /// A link scoped to its own machine names a thread there; one that isn't is on another machine.
    private func locate(_ id: ThreadId) -> ThreadId {
        let local = id.localId.rawValue
        if let env = id.environmentId, shell(env)?.threads.contains(where: { $0.id.rawValue == local }) == true { return id }
        for env in environments.environmentIds where shell(env)?.threads.contains(where: { $0.id.rawValue == local }) == true {
            return ThreadId(local).scoped(to: env)
        }
        return id
    }

    /// Gives the main area back to the thread view; set by the app.
    var closePane: () -> Void = {}
    /// Opens Settings > Orchestrator; set by the app.
    var openSettings: () -> Void = {}

    private func startFeed() {
        guard let id = threadId, let env = id.environmentId, let session = environments.session(env) else { return }
        if let feed, feed.threadId == id, feed.session === session { return }
        feed?.stop()
        feed = OrchestratorThreadFeed(threadId: id, session: session, cache: environments.threadCache) { [weak self] projection in
            self?.projection = projection
            self?.saveMemories(projection)
            self?.refreshViews()
        }
    }

    // MARK: Starting and talking

    /// Starts the Orchestrator on its machine, or opens it when it already runs there.
    func start() {
        guard active, !starting else { return }
        guard let env = machineId, let session = environments.session(env), let snapshot = shell(env) else {
            toast("Can't start the Orchestrator", "Its machine isn't connected.", .error)
            return
        }
        if machine != nil { open(); return }
        let projects = snapshot.projects
        guard let project = projects.first(where: { $0.id.rawValue == config.homeProjectId }) ?? projects.first else {
            toast("Can't start the Orchestrator", "Add a project on \(machineLabel) first. Its thread lives in one.", .error)
            return
        }
        guard let selection = ownSelection(env) else {
            toast("Can't start the Orchestrator", "No model is available on \(machineLabel). Add one in Settings > Orchestrator.", .error)
            return
        }
        starting = true
        // An Orchestrator thread already on the machine, like the one the Android app started, is adopted instead.
        Task { [weak self] in
            guard let self else { return }
            if await self.adopt(env) { self.starting = false; self.open(); return }
            self.create(env, session: session, project: project, selection: selection)
        }
    }

    private func create(_ env: String, session: ShellSession, project: ProjectShell, selection: ModelSelection) {
        let brief = renderBrief(env)
        let local = UUID().uuidString.lowercased()
        let runtime = threads.composer.config(env)?.settings.defaultRuntimeMode.rawValue ?? "full-access"
        let create: JSONValue = .object([
            "type": .string("thread.create"), "commandId": .string(UUID().uuidString.lowercased()), "createdBy": .string("user"),
            "creationSource": .string("web"), "threadId": .string(local), "projectId": .string(project.id.rawValue),
            "title": .string(config.displayName), "modelSelection": ThreadSession.encode(selection), "runtimeMode": .string(runtime),
            "interactionMode": .string("default"), "branch": .null, "worktreePath": .null,
        ])
        let message = ComposerController.standaloneCommand(threadId: ThreadId(local), messageId: MessageId(UUID().uuidString.lowercased()),
                                                           text: OrchestratorBrief.first(brief.text), selection: selection, queue: false)
        Task { [weak self] in
            do {
                _ = try await session.supervisor.request("orchestration.dispatchCommand", payload: create)
                guard let self else { return }
                self.store.update { $0.machines[env] = OrchestratorMachine(threadId: local, briefDigest: brief.fingerprint) }
                _ = try await session.supervisor.request("orchestration.dispatchCommand", payload: message)
                self.starting = false
                self.scheduleSynced.remove(env)
                self.syncSchedules(enabled: false)
                self.open()
            } catch {
                self?.starting = false
                self?.toast("Couldn't start the Orchestrator", (error as? RPCClientError)?.typedError?.message ?? "\(error)", .error)
            }
        }
    }

    /// The brief for `env` and its fingerprint.
    private func renderBrief(_ env: String) -> (text: String, fingerprint: String) {
        let snapshot = shell(env)
        // The machine's scratch folder ("No project") isn't a project to work in, and it appears in the shell late,
        // which would send an updated brief for nothing.
        let scratch = sidebar?.state.scratchRoots[env]
        let projects = (snapshot?.projects ?? []).filter { SidebarModel.normalizeProjectPath($0.workspaceRoot) != scratch }
            .map { (name: $0.title, id: $0.id.rawValue, path: $0.workspaceRoot) }
        let machines = remote.machines()
        let handsOff = config.handsOff.compactMap { key -> String? in
            let id = ThreadId(key)
            guard let machine = id.environmentId, let m = machines.first(where: { $0.id == machine }) else { return nil }
            let local = id.localId.rawValue
            let title = shell(machine)?.threads.first { $0.id.rawValue == local }?.title ?? "Untitled"
            return "“\(title)” (t3-thread://v1/\(local))" + (machine == env ? "" : " on \(m.label) (machine \(machine))")
        }.sorted()
        let inputs = OrchestratorBrief.Inputs(name: config.displayName, machine: machineLabel, projects: projects, crewLimit: config.crewLimit,
                                              models: availableRows(env), notebook: config.notebook, handsOff: handsOff,
                                              askFirstMinutes: config.askFirstMinutes, machines: machines)
        return (OrchestratorBrief.render(config.prompt, inputs), OrchestratorBrief.fingerprint(config.prompt, inputs))
    }

    /// The Models rows whose model this machine's catalog offers; the rest stay out of the brief.
    func availableRows(_ env: String) -> [OrchestratorModelRow] {
        guard let providers = threads.composer.config(env)?.providers else { return config.models }
        let catalog = ProviderCatalog(providers)
        return config.models.filter { catalog.entry(ProviderInstanceId(rawValue: $0.instanceId))?.model($0.model) != nil }
    }

    /// What the Orchestrator's own turns run on: the default row, else the machine's default model.
    private func ownSelection(_ env: String) -> ModelSelection? {
        let rows = availableRows(env)
        if let row = rows.first(where: \.isDefault) ?? rows.first { return row.selection }
        return threads.composer.config(env)?.settings.defaultModelSelection
    }

    /// Your message from the pane, with the updated brief in front when the brief changed since the thread got it.
    func send(_ text: String) {
        guard let env = machineId, let id = threadId, let machine else { return }
        // The images that finished uploading go with it; a message of images only carries T3's stand-in text.
        let images = pendingImages.filter { $0.status == .ready && $0.environmentId == env }
        let message = text.isEmpty && !images.isEmpty ? ComposerAttachmentRules.attachmentOnlyPrompt : text
        let brief = renderBrief(env)
        var body = message
        if brief.fingerprint != machine.briefDigest { body = OrchestratorBrief.updated(brief.text, message: message) }
        let sentIds = Set(images.map(\.id))
        pendingImages.removeAll { sentIds.contains($0.id) }
        refreshViews()
        dispatch(body, to: id, env: env, attachments: images.compactMap(\.chatAttachment)) { [weak self] ok in
            guard let self else { return }
            if ok {
                if brief.fingerprint != machine.briefDigest { self.store.update { $0.machines[env]?.briefDigest = brief.fingerprint } }
                for image in images { Self.removeOwnCopy(image.fileURL) }
            } else {
                // Nothing is lost: the text goes back to the draft and the images back to the composer.
                if !text.isEmpty, self.threads.composer.draftText(id).isEmpty {
                    self.threads.composer.setDraftText(text, for: id)
                    self.pane?.setDraft(text)
                }
                self.pendingImages = images + self.pendingImages
                self.refreshViews()
            }
        }
    }

    /// One message to the Orchestrator; behind a running turn it queues instead of interrupting.
    private func dispatch(_ text: String, to id: ThreadId, env: String, attachments: [JSONValue] = [], done: ((Bool) -> Void)? = nil) {
        guard let session = environments.session(env), let selection = ownSelection(env) ?? orchestratorShell?.modelSelection else {
            toast("Couldn't reach the Orchestrator", "\(machineLabel) isn't connected.", .error)
            done?(false)
            return
        }
        let running = orchestratorShell.map { OrchestratorEvent.running.contains($0.status) } ?? false
        var payload = ComposerController.standaloneCommand(threadId: id, messageId: MessageId(UUID().uuidString.lowercased()), text: text,
                                                           selection: selection, queue: running)
        // The same `attachments` the thread composer sends (`ChatImageAttachment`).
        if !attachments.isEmpty, case .object(var command) = payload {
            command["attachments"] = .array(attachments)
            payload = .object(command)
        }
        Task { [weak self] in
            do {
                _ = try await session.supervisor.request("orchestration.dispatchCommand", payload: payload)
                done?(true)
            } catch {
                self?.toast("Couldn't send to the Orchestrator", (error as? RPCClientError)?.typedError?.message ?? "\(error)", .error)
                done?(false)
            }
        }
    }

    // MARK: Pages and questions

    /// A published page's signed inline URL, as the thread view asks for it (`assets.createUrl`, disposition inline).
    private func pageURL(_ id: String, name: String) async -> URL? {
        guard let env = machineId, let session = environments.session(env) else { return nil }
        if let hit = pageURLs[id], hit.expires.timeIntervalSinceNow > 300 { return hit.url }
        let resource: JSONValue = .object(["_tag": .string("attachment"), "attachmentId": .string(id), "fileName": .string(name),
                                           "mimeType": .string("text/html"), "disposition": .string("inline")])
        guard let reply = try? await session.supervisor.request("assets.createUrl", payload: .object(["resource": resource])),
              let relative = reply["relativeUrl"]?.stringValue,
              let url = URL(string: relative, relativeTo: session.http.baseURL)?.absoluteURL else { return nil }
        let expires = reply["expiresAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date().addingTimeInterval(3600)
        pageURLs[id] = (url, expires)
        return url
    }

    /// Your answer to its question, sent the way the thread composer sends one (`runtime-request.respond`).
    private func answer(_ payload: JSONValue) {
        guard let env = machineId, let session = environments.session(env) else {
            pane?.answerFailed()
            return toast("Couldn't answer the Orchestrator", "\(machineLabel) isn't connected.", .error)
        }
        Task { [weak self] in
            do { _ = try await session.supervisor.request("orchestration.dispatchCommand", payload: payload) } catch {
                self?.pane?.answerFailed()
                self?.toast("Couldn't answer the Orchestrator", (error as? RPCClientError)?.typedError?.message ?? "\(error)", .error)
            }
        }
    }

    // MARK: Images

    /// Images from the + button, a paste or a drop, prepared and uploaded the way the thread composer does it
    /// (`ComposerImageIO.prepare`, then `attachments.createUploadUrl`).
    private func addImages(_ files: [ComposerIncomingFile]) {
        guard let env = machineId, environments.session(env) != nil else { return }
        let room = ComposerAttachmentRules.maxAttachments - pendingImages.count
        guard room > 0 else { toast(ComposerAttachmentRules.countMessage, nil, .error); return }
        let images = files.filter { if case .image = ComposerAttachmentRules.classify(name: $0.name, mimeType: $0.mimeType) { true } else { false } }
        if images.count < files.count { toast("Only images can go to the Orchestrator", nil, .error) }
        let work = ComposerController.attachmentWorkDirectory
        Task { [weak self] in
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            for image in images.prefix(room) {
                do {
                    let p = try await ComposerImageIO.prepare(image.url, name: image.name, mimeType: image.mimeType,
                                                              maxBytes: ComposerAttachmentRules.maxImageBytes, workDir: work)
                    guard let self else { return }
                    let a = ComposerAttachment(kind: .image, name: p.name, mimeType: p.mimeType, sizeBytes: p.sizeBytes, fileURL: p.url, environmentId: env)
                    self.pendingImages.append(a)
                    self.refreshViews()
                    self.upload(a)
                } catch {
                    self?.toast("'\(image.name)' couldn't be attached", "It could not be read, or it is too large even after compression.", .error)
                }
            }
        }
    }

    private func upload(_ a: ComposerAttachment) {
        guard let session = environments.session(a.environmentId) else { return setStatus(a.id, .failed("Not connected")) }
        let supervisor = session.supervisor, base = session.http.baseURL
        uploads[a.id] = Task { [weak self] in
            let result = await ComposerController.uploadAttachment(
                supervisor: supervisor, base: base, type: "image", name: a.name, mimeType: a.mimeType, sizeBytes: a.sizeBytes, file: a.fileURL,
                onMinted: { id in self?.update(a.id) { $0.attachmentId = id } },
                onProgress: { p in self?.setStatus(a.id, .uploading(p)) })
            guard let self else { return }
            self.uploads[a.id] = nil
            switch result {
            case .uploaded(let id): self.update(a.id) { $0.attachmentId = id; $0.status = .ready }
            case .failed(let why): self.setStatus(a.id, .failed(why))
            case .cancelled: break
            }
        }
    }

    private func update(_ id: String, _ change: (inout ComposerAttachment) -> Void) {
        guard let i = pendingImages.firstIndex(where: { $0.id == id }) else { return }
        change(&pendingImages[i])
        refreshViews()
    }

    private func setStatus(_ id: String, _ status: ComposerFileRow.Status) { update(id) { $0.status = status } }

    /// Removes a waiting image: its upload stops and the server forgets it.
    private func removeImage(_ id: String) {
        guard let i = pendingImages.firstIndex(where: { $0.id == id }) else { return }
        let a = pendingImages.remove(at: i)
        uploads.removeValue(forKey: id)?.cancel()
        if let minted = a.attachmentId, let session = environments.session(a.environmentId) {
            Task { _ = try? await session.supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(minted)])) }
        }
        Self.removeOwnCopy(a.fileURL)
        refreshViews()
    }

    /// Deletes a pasted or re-encoded copy in the app's attachment folder. A picked file uploads as it is (`prepare`
    /// returns its own URL), and that file is yours, so it stays.
    static func removeOwnCopy(_ url: URL) {
        let own = ComposerController.attachmentWorkDirectory.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(own) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A sent image for the chat: the shared attachment cache the thread view fills, else `assets.createUrl` and a
    /// download into it, then a thumbnail at `side` pixels.
    private func sentImage(_ attachmentId: String, side: Int) async -> CGImage? {
        let safe = attachmentId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let cached = ComposerController.attachmentCacheDirectory.appendingPathComponent(safe)
        if !FileManager.default.fileExists(atPath: cached.path) {
            guard let env = machineId, let session = environments.session(env) else { return nil }
            do {
                let result = try await session.supervisor.request("assets.createUrl", payload: .object([
                    "resource": .object(["_tag": .string("attachment"), "attachmentId": .string(attachmentId)])]))
                guard case .string(let relative)? = result["relativeUrl"],
                      let url = URL(string: relative, relativeTo: session.http.baseURL)?.absoluteURL else { return nil }
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 else { return nil }
                try? FileManager.default.createDirectory(at: ComposerController.attachmentCacheDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: temp, to: cached)
            } catch {
                return nil
            }
        }
        return await ComposerImageIO.thumbnail(cached, side: side, cover: false)
    }

    // MARK: The event relay

    /// Diffs the machine's threads against the last live state and batches what changed. It runs on server pushes only;
    /// one timer is armed per batch window and none while nothing happens.
    private func relay() {
        guard let home = machineId, let orchestrator = threadId, machine != nil else { return }
        let config = self.config
        var events: [OrchestratorEvent] = []
        // Every machine's threads: the relay reaches them all (docs/orchestrator.md, "Every machine").
        for env in environments.environmentIds {
            guard let session = environments.session(env), let snapshot = shell(env) else { continue }
            let current = snapshot.threads.map { t -> ThreadShell in var s = t; s.id = t.id.scoped(to: env); return s }
            let key = ObjectIdentifier(session)
            let old = baselines[env]
            baselines[env] = (key, Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
            // The first state of a session is the baseline; nothing in it is news.
            guard let old, old.session == key else { continue }
            events += OrchestratorEvent.diff(old: old.threads, new: current, orchestrator: orchestrator,
                                             handsOff: { config.isHandsOff($0) }, windowMinutes: config.askFirstMinutes, now: Date(),
                                             relayedAt: { config.relayedAt[$0.rawValue] },
                                             machine: env == home ? nil : environments.label(env) ?? env)
        }
        // Until this Mac holds the "while closed" task, the Android app may be relaying: what happened meanwhile is its.
        if handoff.ownStamp == nil, machine?.scheduledTaskId != nil { return }
        guard let deadline = batch.add(events, now: Date()) else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
    }

    private func flush() {
        flushWork = nil
        let live = Set(environments.environmentIds.flatMap { env in
            (shell(env)?.threads ?? []).filter { $0.archivedAt == nil && $0.deletedAt == nil }.map { $0.id.scoped(to: env) }
        })
        guard active, let env = machineId, let id = threadId,
              let text = batch.flush(now: Date().addingTimeInterval(0.001), keep: { live.contains($0.threadId) }) else { return }
        Task { [weak self] in
            guard let self, await self.mayRelay() else { return }
            self.dispatch(text, to: id, env: env)
        }
    }

    // MARK: Handoff with the Android app

    /// Before relaying: whether this Mac still holds the "while closed" task. When someone else wrote it since (the
    /// Android app taking over), or the Mac hasn't since it opened or woke, the Mac writes it back off, which tells the
    /// phone to stop, and drops what it gathered.
    private func mayRelay() async -> Bool {
        guard active, let env = machineId, let machine = config.machines[env] else { return false }
        let task = await scheduledTask(env, id: machine.scheduledTaskId)
        guard handoff.verdict(task: task) == .resync else { return true }
        await syncSchedule(env, machine, enabled: false)
        return false
    }

    /// The machine's "while closed" task as the server has it now; nil when there is none or the server can't say.
    private func scheduledTask(_ env: String, id: String?) async -> ScheduledTask? {
        guard let id, let session = environments.session(env),
              let json = try? await session.supervisor.request("scheduledTasks.list", payload: .object([:])) else { return nil }
        return ScheduledTask.list(json).first { $0.id == id }
    }

    /// The Mac woke: it can't know who held the task while it slept, so it drops what it gathered and takes it back.
    private func didWake() {
        guard active else { return }
        handoff.forget()
        flushWork?.cancel()
        flushWork = nil
        batch.reset()
        baselines = [:]
        scheduleSynced.removeAll()
        syncSchedules(enabled: false)
    }

    private func adoptIfNeeded() {
        guard let env = machineId, machine == nil, !starting, !adoptionTried.contains(env), environments.session(env) != nil else { return }
        adoptionTried.insert(env)
        Task { [weak self] in _ = await self?.adopt(env) }
    }

    /// Finds an Orchestrator thread already on the machine by the "# Orchestrator brief" its first message starts with,
    /// newest first, and makes it this Mac's, with its "while closed" task when it has one. The next message you send
    /// carries this Mac's brief.
    private func adopt(_ env: String) async -> Bool {
        guard let session = environments.session(env), let snapshot = shell(env),
              let json = try? await session.supervisor.request("orchestration.searchThreads", payload: .object(["query": .string("Orchestrator brief")])),
              let matches = (try? json.decode(as: ThreadSearchResult.self))?.matches else { return false }
        let live = Dictionary(snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil }
            .map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let candidates = matches.filter(\.isUser).map(\.threadId.rawValue).filter { live[$0] != nil && seen.insert($0).inserted }
            .sorted { (live[$0]?.updatedAt.epochMs ?? 0) > (live[$1]?.updatedAt.epochMs ?? 0) }
        // A match that is a brief says so on its own; reading a projection is the fallback.
        let briefs = OrchestratorHandoff.briefThreads(matches)
        let ordered = candidates.filter { briefs.contains($0) } + candidates.filter { !briefs.contains($0) }
        // ponytail: reads the 5 newest matches; widen it if a machine keeps more threads that quote a brief
        for local in ordered.prefix(5) {
            if !briefs.contains(local) {
                guard let reply = try? await session.supervisor.request("orchestration.getThreadProjection", payload: .object(["threadId": .string(local)])),
                      let projection = try? reply.decode(as: ThreadProjection.self) else { continue }
                let first = projection.messages.filter { $0.role == "user" }.min { ($0.createdAt.epochMs ?? 0) < ($1.createdAt.epochMs ?? 0) }
                guard OrchestratorHandoff.isOrchestratorThread(firstUserMessage: first?.text) else { continue }
            }
            guard config.machines[env] == nil else { return true }
            let tasks = (try? await session.supervisor.request("scheduledTasks.list", payload: .object([:]))).map(ScheduledTask.list) ?? []
            let check = tasks.first { $0.threadId == local && $0.prompt.hasPrefix("Scheduled check:") }
            store.update { $0.machines[env] = OrchestratorMachine(threadId: local, briefDigest: "", scheduledTaskId: check?.id) }
            scheduleSynced.remove(env)
            syncSchedules(enabled: false)
            return true
        }
        return false
    }

    // MARK: Needs you and the crew

    private func currentNeeds() -> [OrchestratorNeed] {
        guard let env = machineId, let snapshot = shell(env) else { return [] }
        return snapshot.threads
            .filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.pendingRuntimeRequest != nil }
            .sorted { ($0.pendingRuntimeRequest?.createdAt.epochMs ?? 0) > ($1.pendingRuntimeRequest?.createdAt.epochMs ?? 0) }
            .compactMap { t in
                guard let r = t.pendingRuntimeRequest else { return nil }
                let scoped = t.id.scoped(to: env)
                let question = r.kind == .userInput
                let label = question ? "Has a question for you" : PendingApproval(requestId: r.id.rawValue, requestKind: r.kind).label
                return OrchestratorNeed(threadId: scoped, threadTitle: t.title, requestId: r.id.rawValue, label: label, isApproval: !question)
            }
    }

    private func crewCards() -> [OrchestratorCrewCard] {
        guard let env = machineId, let snapshot = shell(env) else { return [] }
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        let cards = snapshot.threads
            .filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil && $0.id.rawValue != machine?.threadId
                && $0.settledAt == nil && $0.settledOverride != .settled }
            .sorted { ($0.updatedAt.epochMs ?? 0) > ($1.updatedAt.epochMs ?? 0) }
            .map { t in
                let scoped = t.id.scoped(to: env)
                let presented = SidebarThread(t)
                let status = SidebarModel.resolveSidebarThreadStatus(presented)
                let unread = SidebarModel.hasUnseenCompletion(latestRun: presented.latestRun,
                                                              lastVisitedAt: SidebarModel.resolveThreadLastVisitedAt(server: t.lastVisitedAt, local: nil))
                let top = SidebarModel.resolveSidebarV2TopStatus(status: status, isUnread: unread, isWoke: false)
                let state = switch status {
                case .approval, .input: "Needs you"
                case .working, .waiting: "Working"
                case .failed: "Failed"
                case .limited: "Usage limit"
                case .ready: unread ? "Unread" : t.latestRunCompletedAt.value != nil ? "Done" : "Idle"
                }
                let permission = OrchestratorPermission.of(t, handsOff: config.isHandsOff(scoped), windowMinutes: config.askFirstMinutes, now: now)
                let note: String? = switch permission {
                case .handsOff: "Hands off"
                case .askFirst(let m): "You wrote \(m == 0 ? "just now" : "\(m) min ago"), so it asks first"
                case .free: nil
                }
                let last = t.lastError ?? t.latestVisibleMessage?["text"]?.stringValue
                return OrchestratorCrewCard(id: scoped, title: t.title, project: projects[t.projectId] ?? "", state: state, status: top,
                                            lastLine: last.map { String($0.prefix(160)) }, note: note,
                                            group: OrchestratorCrewCard.group(status, completedTurn: t.latestRunCompletedAt.value != nil))
            }
        // ponytail: every running thread, the 20 most recent finished and 10 stopped; page the Overview if a machine keeps more
        let running = cards.filter { $0.group == .running }
        return running + Array(cards.filter { $0.group == .finished }.prefix(20)) + Array(cards.filter { $0.group == .stopped }.prefix(10))
    }

    /// Allow or Deny through T3's own `runtime-request.respond`, as the composer's approval panel sends it.
    private func respond(_ need: OrchestratorNeed, _ decision: ApprovalDecision) {
        guard need.isApproval, let env = need.threadId.environmentId else { return }
        let payload = RuntimeRequestCommands.respond(threadId: need.threadId.localId, requestId: need.requestId, decision: decision)
        Task { [weak self] in
            do { _ = try await self?.environments.request(env, "orchestration.dispatchCommand", payload) } catch {
                self?.toast("Couldn't answer the request", (error as? RPCClientError)?.typedError?.message ?? "\(error)", .error)
                self?.refreshViews()
            }
        }
    }

    // MARK: Hands off

    func menuItems(_ id: ThreadId) -> [ThreadMenuItem] {
        // Every machine: the relay prompts threads anywhere, so Hands off works anywhere.
        guard active, id.environmentId != nil, !config.isOrchestrator(id) else { return [] }
        return [ThreadMenuItem("hands-off", config.isHandsOff(id) ? "Let the Orchestrator prompt it" : "Hands off")]
    }

    func perform(_ choice: String, _ id: ThreadId) -> Bool {
        guard choice == "hands-off" else { return false }
        store.update { c in if c.handsOff.contains(id.rawValue) { c.handsOff.remove(id.rawValue) } else { c.handsOff.insert(id.rawValue) } }
        return true
    }

    // MARK: Memory

    /// Saves each finished reply's memory blocks to the notebook once, keeping what they replaced for Undo.
    private func saveMemories(_ projection: ThreadProjection?) {
        guard let projection else { return }
        var saved = Set(config.savedMemoryMessages)
        var changes: [(id: String, memories: [OrchestratorReply.Memory])] = []
        for m in projection.messages where m.role == "assistant" && !m.streaming && !saved.contains(m.id.rawValue) {
            let reply = OrchestratorReply.parse(m.text)
            guard !reply.memories.isEmpty else { continue }
            changes.append((m.id.rawValue, reply.memories))
            saved.insert(m.id.rawValue)
        }
        guard !changes.isEmpty else { return }
        store.update { c in
            for change in changes {
                var previous: [(String, String)] = []
                for memory in change.memories {
                    previous.append((memory.note, c.notebook[memory.note]))
                    c.notebook[memory.note] = memory.text
                }
                memoryUndo[change.id] = previous
                c.savedMemoryMessages.append(change.id)
            }
            c.savedMemoryMessages = Array(c.savedMemoryMessages.suffix(200))
        }
    }

    private func undoMemory(_ messageId: String) {
        guard let previous = memoryUndo[messageId], !undone.contains(messageId) else { return }
        undone.insert(messageId)
        store.update { c in for (note, text) in previous.reversed() { c.notebook[note] = text } }
    }

    // MARK: Settings on every device

    /// Follows its machine's scheduled tasks while it's active, where the settings document lives (`OrchestratorSettingsSync`).
    private func watchSettings() {
        guard let env = machineId, env != settingsMachine else { return }
        if let old = settingsMachine {
            // You moved it: the old machine's document sends devices still reading there to the new one.
            if store.stamps["environmentId"]?.by == store.device { syncSettings(old) }
            seenSettings = nil
        }
        settingsMachine = env
        ScheduledTasksStore.shared.watch("orchestrator", [env])
    }

    /// The list's first load, or a write from another device.
    private func settingsListChanged() {
        guard active, let env = machineId, case .loaded(let tasks)? = ScheduledTasksStore.shared.lists[env] else { return }
        let prompts = tasks.filter { $0.title == OrchestratorSettingsSync.title }.map(\.prompt).sorted()
        guard prompts != seenSettings else { return }
        seenSettings = prompts
        syncSettings(env)
    }

    /// Your edit goes up a second after the last change, so typing in the prompt writes once.
    private func settingsEdited() {
        guard store.stamps.contains(where: { key, stamp in stamp.by == store.device && syncedStamps[key] != stamp }) else { return }
        settingsPush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, let env = self.machineId else { return }
            self.syncSettings(env)
        }
        settingsPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// One sync at a time, so writes land in order.
    private func syncSettings(_ env: String) {
        let previous = settingsChain
        settingsChain = Task { [weak self] in
            await previous?.value
            await self?.pushSettings(env)
        }
    }

    /// Merges the machine's settings documents with this Mac's, then writes the result back when it differs.
    private func pushSettings(_ env: String) async {
        guard active, let session = environments.session(env),
              let json = try? await session.supervisor.request("scheduledTasks.list", payload: .object([:])), active else { return }
        // Two devices may each have made one; every side keeps the smallest id and deletes the rest.
        let found = ScheduledTask.list(json).filter { $0.title == OrchestratorSettingsSync.title }.sorted { $0.id < $1.id }
        let merge = OrchestratorSettingsSync.merge(config: config, stamps: store.stamps, documents: found.compactMap { .parse($0.prompt) },
                                                   machine: env, home: machineId)
        syncedStamps = merge.stamps
        store.applyMerged(merge)
        guard let doc = merge.write else { return }
        var input: [String: JSONValue]
        if let task = found.first {
            input = ["id": .string(task.id), "projectId": .string(task.projectId), "workspaceStrategy": task.workspaceStrategy,
                     "modelSelection": task.modelSelection, "runtimeMode": .string(task.runtimeMode), "interactionMode": .string(task.interactionMode)]
        } else {
            let projects = shell(env)?.projects ?? []
            guard let project = projects.first(where: { $0.id.rawValue == config.homeProjectId }) ?? projects.first,
                  let selection = ownSelection(env) else { return }
            input = ["projectId": .string(project.id.rawValue), "workspaceStrategy": .object(["type": .string("root")]),
                     "modelSelection": ThreadSession.encode(selection), "runtimeMode": .string("approval-required"),
                     "interactionMode": .string("default")]
        }
        // Always off, so it never runs; the interval only has to be one T3 accepts.
        input["title"] = .string(OrchestratorSettingsSync.title)
        input["prompt"] = .string(doc.prompt)
        input["enabled"] = .bool(false)
        input["schedule"] = .object(["type": .string("interval"), "everyMs": .number(86_400_000)])
        input["creationSource"] = .string("web")
        _ = try? await session.supervisor.request("scheduledTasks.upsert", payload: .object(input))
        for extra in found.dropFirst() {
            _ = try? await session.supervisor.request("scheduledTasks.delete", payload: .object(["id": .string(extra.id)]))
        }
    }

    // MARK: The "while closed" schedule

    /// Makes sure each machine's check task exists with the set interval, on or off. CandyWrapper keeps it off while open.
    private func syncSchedules(enabled: Bool) {
        guard let env = machineId, let machine = config.machines[env], !scheduleSynced.contains(env) || enabled,
              environments.session(env) != nil, shell(env)?.threads.contains(where: { $0.id.rawValue == machine.threadId }) == true else { return }
        scheduleSynced.insert(env)
        Task { await syncSchedule(env, machine, enabled: enabled) }
    }

    private func syncSchedule(_ env: String, _ machine: OrchestratorMachine, enabled: Bool) async {
        guard let session = environments.session(env), let selection = ownSelection(env),
              let projectId = shell(env)?.threads.first(where: { $0.id.rawValue == machine.threadId })?.projectId else { return }
        guard let minutes = config.closedCheckMinutes else {
            if let id = machine.scheduledTaskId {
                if let result = try? await session.supervisor.request("scheduledTasks.setEnabled", payload: .object(["id": .string(id), "enabled": .bool(false)])) {
                    handoff.wrote(updatedAt: result["task"]?["updatedAt"]?.stringValue)
                } else {
                    scheduleSynced.remove(env)
                }
            }
            return
        }
        var input: [String: JSONValue] = [
            "title": .string("\(config.displayName) check"), "prompt": .string(OrchestratorBrief.scheduledCheckPrompt), "enabled": .bool(enabled),
            "schedule": .object(["type": .string("interval"), "everyMs": .number(Double(minutes) * 60_000)]),
            "projectId": .string(projectId.rawValue), "threadId": .string(machine.threadId),
            "workspaceStrategy": .object(["type": .string("root")]), "modelSelection": ThreadSession.encode(selection),
            "runtimeMode": .string(threads.composer.config(env)?.settings.defaultRuntimeMode.rawValue ?? "full-access"),
            "interactionMode": .string("default"), "creationSource": .string("web"),
        ]
        if let id = machine.scheduledTaskId { input["id"] = .string(id) }
        do {
            let result = try await session.supervisor.request("scheduledTasks.upsert", payload: .object(input))
            if let id = result["task"]?["id"]?.stringValue, id != machine.scheduledTaskId {
                store.update { $0.machines[env]?.scheduledTaskId = id }
            }
            // Off is this Mac holding the task; on hands it to the schedule and the Android app.
            if enabled { handoff.forget() } else { handoff.wrote(updatedAt: result["task"]?["updatedAt"]?.stringValue) }
        } catch {
            // A task removed elsewhere: make a new one next time.
            if machine.scheduledTaskId != nil { store.update { $0.machines[env]?.scheduledTaskId = nil } }
            scheduleSynced.remove(env)
        }
    }

    /// The quit was cancelled after the hand-off: CandyWrapper stays open, so the schedule goes back off.
    func quitCancelled() {
        scheduleSynced.removeAll()
        syncSchedules(enabled: false)
    }

    /// A quit should turn the "while closed" schedule on first.
    var needsQuitHandOff: Bool { active && machine != nil && config.closedCheckMinutes != nil && connected }

    /// The app is quitting: the schedule takes over. Calls `done` when the server answered or after a second and a half.
    func handOffBeforeQuit(_ done: @escaping () -> Void) {
        guard active, let env = machineId, let machine = config.machines[env], config.closedCheckMinutes != nil else { return done() }
        var finished = false
        let finish = { if !finished { finished = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
        Task { [weak self] in
            await self?.syncSchedule(env, machine, enabled: true)
            finish()
        }
    }
}

/// The Orchestrator thread's own stream, only while its pane shows: the same `orchestration.subscribeThread` the thread
/// view uses, paced to at most 20 renders a second while text streams.
@MainActor
final class OrchestratorThreadFeed {
    let threadId: ThreadId
    let session: ShellSession
    private let store: ThreadStore
    private let relay = ShellSession.ChangeRelay()
    private var subscription: Task<Void, Never>?
    private lazy var pacer = FramePacer(maxRate: 20) { [weak self] in Task { @MainActor in await self?.pull() } }
    private let onUpdate: (ThreadProjection?) -> Void

    init(threadId: ThreadId, session: ShellSession, cache: ThreadCache?, onUpdate: @escaping (ThreadProjection?) -> Void) {
        self.threadId = threadId
        self.session = session
        self.onUpdate = onUpdate
        let relay = self.relay
        let store = ThreadStore(threadId: threadId.localId, cache: cache, environmentId: threadId.environmentId ?? "",
                                onFirstChange: { relay.fire(streaming: $0) })
        self.store = store
        relay.setStreaming { [weak self] _ in Task { @MainActor in self?.pacer.request() } }
        Task { await store.restoreFromCache() }
        subscription = session.supervisor.subscribe("orchestration.subscribeThread", payload: {
            ThreadSession.encode(await store.subscribeInput())
        }, handler: { event in
            guard case .value(let json) = event, let item = ThreadSession.decode(json) else { return }
            await store.apply([item])
        })
    }

    private func pull() async {
        guard subscription != nil, let update = await store.takeUpdate() else { return }
        onUpdate(update.projection)
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        relay.set {}
        let store = self.store
        Task { await store.flushCache() }
    }
}
