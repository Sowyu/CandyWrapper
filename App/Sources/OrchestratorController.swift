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
    /// The machine's threads as last seen, the baseline for events; reset with each new session.
    private var baseline: (session: ObjectIdentifier, threads: [ThreadId: ThreadShell])?
    private var batch = OrchestratorEventBatch()
    private var flushWork: DispatchWorkItem?
    private var starting = false
    /// Notes a reply saved this session, by message id, with what they replaced, for Undo.
    private var memoryUndo: [String: [(note: String, previous: String)]] = [:]
    private var undone: Set<String> = []
    private var scheduleSynced: Set<String> = []
    private var wasActive = false

    init(environments: Environments, sidebar: SidebarContentView, threads: ThreadController) {
        self.environments = environments
        self.sidebar = sidebar
        self.threads = threads
        store.actions.start = { [weak self] in self?.start() }
        store.actions.open = { [weak self] in self?.open() }
        store.actions.status = { [weak self] in self?.statusText ?? "Not started" }
        store.observe { [weak self] in self?.configChanged() }
        environments.observeShell { [weak self] in self?.shellChanged() }
        sidebar.actions.openOrchestrator = { [weak self] in self?.open() }
        // A rename changes the brief's {{name}}, so it goes out as an updated brief with your next message.
        sidebar.actions.renameOrchestrator = { name in OrchestratorStore.shared.update { $0.name = name } }
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
        syncSchedules(enabled: false)
        refreshViews()
    }

    /// The toggle went off or the theme changed: drop every view and every piece of relay state.
    private func tearDown() {
        flushWork?.cancel()
        flushWork = nil
        batch.reset()
        baseline = nil
        feed?.stop()
        feed = nil
        projection = nil
        if pane != nil { closePane() }
        sidebar?.orchestrator = nil
        sidebar?.state.hiddenThreadIds = []
    }

    private func shellChanged() {
        guard active else { return }
        // At launch the schedule turns off once its machine's shell has the thread.
        syncSchedules(enabled: false)
        forgetVanishedThread()
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
        pane.set(state)
    }

    func open() {
        guard active else { return }
        let view = pane ?? {
            let p = OrchestratorPaneView()
            p.onSend = { [weak self] text in self?.send(text) }
            p.onOpenThread = { [weak self] id in self?.sidebar?.actions.openThread(id) }
            p.onRespond = { [weak self] need, decision in self?.respond(need, decision) }
            p.onUndoMemory = { [weak self] id in self?.undoMemory(id) }
            p.onStart = { [weak self] in self?.start() }
            p.onOpenAsThread = { [weak self] in if let id = self?.threadId { self?.sidebar?.actions.openThread(id) } }
            p.onEditBot = { [weak self] in self?.openSettings() }
            pane = p
            return p
        }()
        startFeed()
        refreshViews()
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
        let titles = Dictionary((snapshot?.threads ?? []).map { ($0.id.rawValue, $0.title) }, uniquingKeysWith: { a, _ in a })
        let handsOff = config.handsOff.compactMap { key -> String? in
            let id = ThreadId(key)
            guard id.environmentId == env else { return nil }
            let local = id.localId.rawValue
            return "“\(titles[local] ?? "Untitled")” (t3-thread://v1/\(local))"
        }.sorted()
        let inputs = OrchestratorBrief.Inputs(name: config.displayName, machine: machineLabel, projects: projects, crewLimit: config.crewLimit,
                                              models: availableRows(env), notebook: config.notebook, handsOff: handsOff,
                                              askFirstMinutes: config.askFirstMinutes)
        return (OrchestratorBrief.render(config.prompt, inputs), OrchestratorBrief.fingerprint(config.prompt, inputs))
    }

    /// The Models rows whose model this machine's catalog offers; the rest stay out of the brief.
    private func availableRows(_ env: String) -> [OrchestratorModelRow] {
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
        let brief = renderBrief(env)
        var body = text
        if brief.fingerprint != machine.briefDigest { body = OrchestratorBrief.updated(brief.text, message: text) }
        dispatch(body, to: id, env: env) { [weak self] ok in
            if ok, brief.fingerprint != machine.briefDigest { self?.store.update { $0.machines[env]?.briefDigest = brief.fingerprint } }
        }
    }

    /// One message to the Orchestrator; behind a running turn it queues instead of interrupting.
    private func dispatch(_ text: String, to id: ThreadId, env: String, done: ((Bool) -> Void)? = nil) {
        guard let session = environments.session(env), let selection = ownSelection(env) ?? orchestratorShell?.modelSelection else {
            toast("Couldn't reach the Orchestrator", "\(machineLabel) isn't connected.", .error)
            done?(false)
            return
        }
        let running = orchestratorShell.map { OrchestratorEvent.running.contains($0.status) } ?? false
        let payload = ComposerController.standaloneCommand(threadId: id, messageId: MessageId(UUID().uuidString.lowercased()), text: text,
                                                           selection: selection, queue: running)
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

    // MARK: The event relay

    /// Diffs the machine's threads against the last live state and batches what changed. It runs on server pushes only;
    /// one timer is armed per batch window and none while nothing happens.
    private func relay() {
        guard let env = machineId, let orchestrator = threadId, machine != nil,
              let session = environments.session(env), let snapshot = shell(env) else { return }
        let current = snapshot.threads.map { t -> ThreadShell in var s = t; s.id = t.id.scoped(to: env); return s }
        let key = ObjectIdentifier(session)
        defer { baseline = (key, Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })) }
        // The first state of a session is the baseline; nothing in it is news.
        guard let old = baseline, old.session == key else { return }
        let config = self.config
        let events = OrchestratorEvent.diff(old: old.threads, new: current, orchestrator: orchestrator,
                                            handsOff: { config.isHandsOff($0) }, windowMinutes: config.askFirstMinutes, now: Date())
        guard let deadline = batch.add(events, now: Date()) else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
    }

    private func flush() {
        flushWork = nil
        let live = Set((machineId.flatMap { shell($0) }?.threads ?? []).filter { $0.archivedAt == nil && $0.deletedAt == nil }.map(\.id.rawValue))
        guard active, let env = machineId, let id = threadId,
              let text = batch.flush(now: Date().addingTimeInterval(0.001), keep: { live.contains($0.threadId.localId.rawValue) }) else { return }
        dispatch(text, to: id, env: env)
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
        return snapshot.threads
            .filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil && $0.id.rawValue != machine?.threadId
                && $0.settledAt == nil && $0.settledOverride != .settled }
            .sorted { ($0.updatedAt.epochMs ?? 0) > ($1.updatedAt.epochMs ?? 0) }
            // ponytail: the 30 most recent unsettled threads; page the Overview if a machine keeps more in flight
            .prefix(30)
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
                                            lastLine: last.map { String($0.prefix(160)) }, note: note)
            }
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
        guard active, id.environmentId == machineId, !config.isOrchestrator(id) else { return [] }
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
                _ = try? await session.supervisor.request("scheduledTasks.setEnabled", payload: .object(["id": .string(id), "enabled": .bool(false)]))
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
