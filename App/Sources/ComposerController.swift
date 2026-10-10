import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// What the composer sends and where: `message.dispatch` on an open thread, `orchestration.launchThread`
/// for a new-thread draft's first send, `run.interrupt` for Stop, the continuation for Resume.
/// Keeps the prompt per thread and one draft session per project, persisted like T3's
/// composer draft store (I-composer-flow sections 1, 2, 4.8 and 6).
@MainActor
final class ComposerController {
    /// A new thread that exists only here until its first send (T3's `DraftSessionState`).
    struct DraftSession: Codable, Equatable {
        var draftId: String
        var threadId: String
        var projectId: String
        var createdAt: Date
    }

    enum Target: Equatable {
        case thread(ThreadId)
        case draft(DraftSession)
    }

    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private var composer: ComposerView { panel.composer }
    private var shell: ShellSession?
    private var environment: String?
    private(set) var target: Target?
    private var projection: ThreadProjection?
    /// Sent messages the stream hasn't confirmed, for the open thread.
    private var optimistic: [ChatMessage] = []
    /// A send whose message hasn't shown up in the projection yet.
    private var pendingMessageId: MessageId?
    private var resuming = false
    /// Opens a thread in the panel (the launch's new thread).
    var openThread: ((ThreadId) -> Void)?

    /// The pickers (WP5.4) set these; nil sends the thread's, project's or newest thread's choice.
    var modelSelectionOverride: ModelSelection?
    var runtimeModeOverride: String?

    // Persisted like T3's `t3code:composer-drafts:v1`: prompts by draft key, sessions by project.
    private static let promptsKey = "composer.prompts.v1", sessionsKey = "composer.draftSessions.v1"
    private var prompts: [String: String]
    private var sessions: [String: DraftSession]
    private var saveWork: DispatchWorkItem?

    init(panel: ThreadPanelView, sidebar: SidebarContentView) {
        self.panel = panel
        self.sidebar = sidebar
        let defaults = UserDefaults.standard
        prompts = defaults.dictionary(forKey: Self.promptsKey) as? [String: String] ?? [:]
        sessions = (defaults.data(forKey: Self.sessionsKey)).flatMap { try? JSONDecoder().decode([String: DraftSession].self, from: $0) } ?? [:]
        composer.onSend = { [weak self] text, mode in self?.send(text, mode: mode) }
        composer.onStop = { [weak self] in self?.stop() }
        composer.onResume = { [weak self] in self?.resume() }
        composer.onTextChange = { [weak self] text in self?.remember(text) }
        panel.hero.onPickProject = { [weak self] anchor in self?.pickProject(from: anchor) }
        composer.stageArt = sidebar.stage != .none
        refresh()
    }

    func follow(_ shell: ShellSession?, environment: String?) {
        self.shell = shell
        self.environment = environment
        refresh()
    }

    // MARK: Targets

    private var draftKey: String? {
        switch target {
        case .thread(let id): environment.map { "\($0):\(id.rawValue)" }
        case .draft(let session): session.draftId
        case nil: nil
        }
    }

    /// The panel switched to a thread. A launch's optimistic message travels with it.
    func showThread(_ id: ThreadId) {
        var carried: [ChatMessage] = []
        if case .draft(let s) = target, s.threadId == id.rawValue { carried = optimistic }
        flushPrompt()
        target = .thread(id)
        projection = nil
        optimistic = carried
        if carried.isEmpty { pendingMessageId = nil }
        resuming = false
        loadPrompt()
    }

    /// Sidebar new-thread button (`handleNewThread`, useHandleNewThread.ts:64-390): the open
    /// thread's project, else the first project. Reuses the project's draft session, else mints one.
    @discardableResult
    func newThread() -> Bool {
        guard let snapshot = sidebar?.snapshot, !snapshot.projects.isEmpty else { return false }
        var projectId: ProjectId?
        switch target {
        case .thread(let id): projectId = snapshot.threads.first { $0.id == id }?.projectId
        case .draft(let s): projectId = ProjectId(s.projectId)
        case nil: break
        }
        let project = snapshot.projects.first { $0.id == projectId } ?? snapshot.projects[0]
        showDraft(project)
        return true
    }

    private func showDraft(_ project: ProjectShell) {
        let key = "\(environment ?? ""):\(project.id.rawValue)"
        let session = sessions[key] ?? DraftSession(draftId: UUID().uuidString.lowercased(), threadId: UUID().uuidString.lowercased(),
                                                    projectId: project.id.rawValue, createdAt: Date())
        sessions[key] = session
        flushPrompt()
        target = .draft(session)
        projection = nil
        optimistic = []
        pendingMessageId = nil
        sidebar?.state.activeThreadId = nil
        panel.setDraft(projectTitle: project.title)
        loadPrompt()
        scheduleSave()
    }

    private func pickProject(from anchor: NSView) {
        guard let snapshot = sidebar?.snapshot, case .draft(let current) = target else { return }
        let items = snapshot.projects.map { project in
            var item = MenuItem.radio(project.title, checked: project.id.rawValue == current.projectId)
            item.closesOnClick = true
            item.action = { [weak self] in self?.showDraft(project) }
            return item
        }
        MenuPopupView.show(items, from: anchor, placement: PopupPlacement(side: .bottom, align: .center, sideOffset: 4))
    }

    // MARK: Prompts

    private func loadPrompt() {
        composer.text = draftKey.flatMap { prompts[$0] } ?? ""
        refresh()
        DispatchQueue.main.async { [weak self] in self?.composer.focus() }
    }

    private func remember(_ text: String) {
        guard let key = draftKey else { return }
        prompts[key] = text.isEmpty ? nil : text
        scheduleSave()
        refresh()
    }

    private func flushPrompt() {
        if let key = draftKey { prompts[key] = composer.text.isEmpty ? nil : composer.text }
    }

    /// T3 debounces draft writes by 300ms (COMPOSER_PERSIST_DEBOUNCE_MS).
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func save() {
        // ponytail: prompts of threads deleted elsewhere stay stored; prune against the shell if it grows
        UserDefaults.standard.set(prompts, forKey: Self.promptsKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(sessions), forKey: Self.sessionsKey)
    }

    // MARK: Stream

    /// Every thread store update for the open thread.
    func projectionChanged(_ projection: ThreadProjection?, threadId: ThreadId) {
        guard target == .thread(threadId) else { return }
        self.projection = projection
        let confirmed = Set(projection?.messages.map(\.id) ?? [])
        optimistic.removeAll { confirmed.contains($0.id) }
        if let id = pendingMessageId, confirmed.contains(id) { pendingMessageId = nil }
        // Resume is done once a run is active again.
        if resuming, let projection, ComposerLogic.RunState(runs: projection.runs).canInterrupt { resuming = false }
        refresh()
    }

    private func refresh() {
        let runs = projection?.runs ?? []
        composer.runState = ComposerLogic.RunState(runs: runs)
        composer.isBusy = pendingMessageId != nil || resuming
        var placeholder = ComposerLogic.PlaceholderInput()
        placeholder.disconnected = shell == nil
        let pending = projection?.runtimeRequests.filter { $0.status == "pending" } ?? []
        placeholder.approvalPending = pending.contains { $0.kind != .userInput }
        composer.placeholderInput = placeholder
        composer.sendDisabledReason = shell == nil ? "Environment disconnected" : nil
        panel.model.optimisticMessages = optimistic
        panel.updateComposerShown()
    }

    // MARK: Commands

    private var shellThread: ThreadShell? {
        guard case .thread(let id) = target else { return nil }
        return sidebar?.snapshot?.threads.first { $0.id == id }
    }

    /// The model to send: the pickers' choice, the thread's, the project's default, else the newest thread's.
    // ponytail: no server-config fallback (default provider instance); WP5.4 owns that
    private func modelSelection(projectId: ProjectId?) -> ModelSelection? {
        if let modelSelectionOverride { return modelSelectionOverride }
        if let thread = shellThread { return thread.modelSelection }
        let snapshot = sidebar?.snapshot
        if let project = snapshot?.projects.first(where: { $0.id == projectId }), let selection = project.defaultModelSelection {
            return selection
        }
        return snapshot?.threads.max { $0.updatedAt.raw < $1.updatedAt.raw }?.modelSelection
    }

    private func send(_ text: String, mode: ComposerLogic.SendMode) {
        guard let shell, pendingMessageId == nil, let target else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let messageId = MessageId(UUID().uuidString.lowercased())
        let commandId = UUID().uuidString.lowercased()
        let now = T3Timestamp(Date())
        let projectId: ProjectId? = switch target {
        case .draft(let s): ProjectId(s.projectId)
        case .thread: shellThread?.projectId
        }
        guard let selection = modelSelection(projectId: projectId) else {
            fail("No model is available. Enable a provider in T3 Code's settings.", restore: text)
            return
        }
        // Optimistic echo, then clear the composer before the command returns (ChatView.tsx:9763-9793).
        let intent: InputIntent? = mode == .queue ? .queuedTurn : mode == .steer ? .steer : nil
        optimistic.append(ChatMessage(id: messageId, role: .user, text: trimmed, createdAt: now, inputIntent: intent))
        pendingMessageId = messageId
        composer.text = ""
        remember("")
        let title = ComposerLogic.titleSeed(trimmed)
        let selectionJSON = ThreadSession.encode(selection)
        let supervisor = shell.supervisor

        switch target {
        case .draft(let session):
            // First send of a draft: one launchThread; the thread exists after the reply (05-composer.jsonl).
            panel.setDraft(projectTitle: nil)
            refresh()
            let payload: JSONValue = .object([
                "commandId": .string(commandId), "creationSource": .string("web"), "threadId": .string(session.threadId),
                "projectId": .string(session.projectId), "title": .string(title), "generateTitle": .bool(true),
                "modelSelection": selectionJSON, "runtimeMode": .string(runtimeModeOverride ?? "full-access"),
                "interactionMode": .string("default"), "workspaceStrategy": .object(["type": .string("root")]),
                "initialMessage": .object(["messageId": .string(messageId.rawValue), "text": .string(trimmed), "attachments": .array([])]),
            ])
            Task { [weak self] in
                do {
                    _ = try await supervisor.request("orchestration.launchThread", payload: payload)
                    guard let self else { return }
                    sessions = sessions.filter { $0.value.draftId != session.draftId }
                    prompts[session.draftId] = nil
                    scheduleSave()
                    openThread?(ThreadId(session.threadId))
                } catch {
                    self?.sendFailed(error, messageId: messageId, text: text, draft: session)
                }
            }
        case .thread(let threadId):
            let (dispatchMode, deliveryIntent) = ComposerLogic.dispatch(mode)
            var command: [String: JSONValue] = [
                "type": .string("message.dispatch"), "commandId": .string(commandId), "createdBy": .string("user"),
                "creationSource": .string("web"), "threadId": .string(threadId.rawValue), "messageId": .string(messageId.rawValue),
                "text": .string(trimmed), "attachments": .array([]), "titleSeed": .string(title),
                "modelSelection": selectionJSON, "dispatchMode": dispatchMode,
            ]
            if let deliveryIntent { command["deliveryIntent"] = .string(deliveryIntent) }
            let runtimeChange = runtimeModeOverride.flatMap { $0 != shellThread?.runtimeMode ? $0 : nil }
            Task { [weak self] in
                do {
                    // A changed access mode is persisted before the message (persistThreadSettingsForNextTurn).
                    if let runtimeChange {
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                            "type": .string("thread.runtime-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                            "threadId": .string(threadId.rawValue), "runtimeMode": .string(runtimeChange)]))
                    }
                    _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(command))
                } catch {
                    self?.sendFailed(error, messageId: messageId, text: text, draft: nil)
                }
            }
        }
    }

    /// I-composer-flow 1.7: drop the optimistic row, restore the text if the composer is still
    /// empty, and show the server's message (transport errors stay silent).
    private func sendFailed(_ error: Error, messageId: MessageId, text: String, draft: DraftSession?) {
        optimistic.removeAll { $0.id == messageId }
        if pendingMessageId == messageId { pendingMessageId = nil }
        if let draft, target == .draft(draft) || target == nil {
            // Back to the draft page with its text.
            if let project = sidebar?.snapshot?.projects.first(where: { $0.id.rawValue == draft.projectId }) {
                panel.setDraft(projectTitle: project.title)
            }
        }
        let restore = composer.text.isEmpty ? text : nil
        if let restore { composer.text = restore; remember(restore) }
        refresh()
        if let rpc = error as? RPCClientError, rpc.isTransport { return }
        fail(Self.message(error, fallback: "Failed to send message."), restore: nil)
    }

    private func fail(_ message: String, restore: String?) {
        if let restore, composer.text.isEmpty { composer.text = restore }
        // ponytail: an alert sheet; T3 shows a thread error banner above the composer (WP5.2 banner surface)
        guard let window = panel.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    private static func message(_ error: Error, fallback: String) -> String {
        (error as? RPCClientError)?.typedError?.message ?? fallback
    }

    /// Stop: `run.interrupt` with `holdQueue` on the active run (I-composer-flow 2.1). No local
    /// "stopping" state; the button stays until the run settles.
    private func stop() {
        guard let shell, case .thread(let threadId) = target, let projection else { return }
        let state = ComposerLogic.RunState(runs: projection.runs)
        // The shell's activeRunId skips `waiting`; T3's helper falls back to the projection's last live run.
        guard let runId = state.activeRunId ?? projection.runs.last(where: { $0.status == .waiting })?.id else { return }
        let payload: JSONValue = .object([
            "type": .string("run.interrupt"), "commandId": .string(UUID().uuidString.lowercased()),
            "threadId": .string(threadId.rawValue), "runId": .string(runId.rawValue), "holdQueue": .bool(true),
        ])
        let supervisor = shell.supervisor
        Task { [weak self] in
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload) } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.fail(Self.message(error, fallback: "Failed to interrupt the current turn."), restore: nil)
            }
        }
    }

    /// Resume (ChatView.tsx:8656-8730): continue an interrupted run, then release held queued runs.
    private func resume() {
        guard let shell, case .thread(let threadId) = target, let projection, !resuming else { return }
        let state = ComposerLogic.RunState(runs: projection.runs)
        guard state.canResume, let selection = modelSelection(projectId: shellThread?.projectId) else { return }
        resuming = true
        refresh()
        let supervisor = shell.supervisor
        var continuation: JSONValue?
        if let runId = state.resumableRunId {
            continuation = .object([
                "type": .string("message.dispatch"), "commandId": .string(UUID().uuidString.lowercased()),
                "createdBy": .string("user"), "creationSource": .string("web"), "threadId": .string(threadId.rawValue),
                "messageId": .string(UUID().uuidString.lowercased()), "text": .string("Continue where you left off."),
                "attachments": .array([]), "modelSelection": ThreadSession.encode(selection),
                "dispatchMode": .object(["type": .string("start_immediately")]), "manualContinuationOfRunId": .string(runId.rawValue),
            ])
        }
        let release: JSONValue? = state.hasHeldQueuedRuns ? .object([
            "type": .string("queue.resume"), "commandId": .string(UUID().uuidString.lowercased()), "threadId": .string(threadId.rawValue),
        ]) : nil
        Task { [weak self] in
            do {
                if let continuation { _ = try await supervisor.request("orchestration.dispatchCommand", payload: continuation) }
                if let release { _ = try await supervisor.request("orchestration.dispatchCommand", payload: release) }
                // Only held runs: nothing starts until the queue drains, so don't wait for a run.
                if continuation == nil { self?.resuming = false; self?.refresh() }
            } catch {
                self?.resuming = false
                self?.refresh()
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.fail(Self.message(error, fallback: "Failed to resume the thread."), restore: nil)
            }
        }
    }
}
