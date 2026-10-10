import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// What the composer sends and where: `message.dispatch` on an open thread, `orchestration.launchThread`
/// for a new-thread draft's first send, `run.interrupt` for Stop, the continuation for Resume, and
/// the queue strip's commands. Keeps the prompt per thread and one draft session per project,
/// persisted like T3's composer draft store (I-composer-flow sections 1, 2, 4, 5 and 6).
///
/// The footer pickers' picks live in one place, `ComposerSelectionStore`, keyed by the same draft
/// key as the prompt; every send reads `pickers.current` and drops the picks after it succeeds.
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

    /// Model, traits and access: the footer controls and the per-draft picks they own.
    let pickers = ComposerPickers(store: ComposerSelectionStore(), draftKey: "", context: ComposerSelectionContext(catalog: ProviderCatalog([])))
    /// `server.getConfig` providers and settings, followed through `subscribeServerConfig`.
    private var serverConfig = ServerProviderConfig(providers: [])
    private var configSubscription: Task<Void, Never>?

    /// A queued message open in the composer (`beginEditingQueuedRun`, ChatView.tsx:4673-4699).
    /// Its text lives here, not in the thread's prompt, which comes back on save or cancel.
    private struct QueuedEdit { let runId: RunId; let threadId: ThreadId }
    private var queuedEdit: QueuedEdit?
    /// A queue command is in flight: the strip's actions wait (`busyRunId`).
    private var queueBusy = false
    private var keyMonitor: Any?

    /// The open thread's pending approvals and questions (`derivePendingThreadRequests`).
    private var requests = PendingRequests()
    /// Requests with a respond or dismiss in flight (`respondingRequestIds`): their actions are disabled.
    private var responding: Set<String> = []
    /// The question whose custom answer the editor holds. The thread's prompt waits in `prompts`
    /// until it closes (ChatComposer.tsx shows `activePendingProgress.customAnswer` in place of the prompt).
    private var questionRequestId: String?

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
        composer.footerControls = [pickers.controlsView]
        pickers.onPromptChange = { [weak self] text in
            guard let self else { return }
            composer.text = text
            remember(text)
        }
        pickers.onBlocked = { [weak self] reason in self?.fail(reason, restore: nil) }
        pickers.onChange = { [weak self] _ in self?.composer.needsLayout = true }
        let queue = panel.queue
        queue.onRemove = { [weak self] runId in self?.queueCommand("queued-run.cancel", ["runId": .string(runId.rawValue)],
                                                                   fallback: "Failed to remove the queued message.") }
        queue.onReorder = { [weak self] runId, before in
            self?.queueCommand("queued-run.reorder", ["runId": .string(runId.rawValue), "beforeRunId": before.map { .string($0.rawValue) } ?? .null],
                               fallback: "Failed to reorder the queued message.")
        }
        queue.onSteer = { [weak self] runId in self?.promoteToSteer(runId) }
        queue.onEdit = { [weak self] item in self?.beginEdit(item) }
        queue.onCancelEdit = { [weak self] in self?.endEdit() }
        panel.approvalPanel.onRespond = { [weak self] _, payload in
            self?.respond(payload, fallback: "Failed to submit approval decision.")
        }
        let question = panel.questionPanel
        question.onSubmit = { [weak self] payload in self?.respond(payload, fallback: "Failed to submit user input.") }
        question.onDismiss = { [weak self] payload in self?.respond(payload, fallback: "Failed to dismiss the question.") }
        question.onDisplacedAnswer = { [weak self] text in self?.carryDisplaced(text) }
        question.onChange = { [weak self] in self?.syncQuestion() }
        composer.onQuestionAdvance = { [weak self] in self?.panel.questionPanel.advance() }
        composer.onQuestionPrevious = { [weak self] in self?.panel.questionPanel.previous() }
        installShortcuts()
        refresh()
    }

    func follow(_ shell: ShellSession?, environment: String?) {
        if shell !== self.shell {
            configSubscription?.cancel()
            configSubscription = shell.map(subscribeConfig)
        }
        self.shell = shell
        self.environment = environment
        refresh()
    }

    /// `subscribeServerConfig`: a snapshot first, then provider and settings updates (protocol.md 1562).
    private func subscribeConfig(_ shell: ShellSession) -> Task<Void, Never> {
        let stream = shell.supervisor.subscribe("subscribeServerConfig", payload: { .object([:]) }, handler: { [weak self] event in
            guard case .value(let json) = event, let change = try? json.decode(as: ServerConfigEvent.self) else { return }
            await MainActor.run { self?.configChanged(change) }
        })
        return stream
    }

    private func configChanged(_ event: ServerConfigEvent) {
        switch event {
        case .snapshot(let config): serverConfig = config
        case .providerStatuses(let providers): serverConfig.providers = providers
        case .settingsUpdated(let settings): serverConfig.settings = settings
        case .other: return
        }
        refresh()
    }

    // MARK: Shortcuts

    /// `modelPicker.toggle` (⇧⌘M), `composer.effort` (⇧⌘E), `composer.mode` (⇧⌘A) and
    /// `thread.steerQueuedMessage` (⇧⌘↩, steers the first queued message) while the composer shows.
    // ponytail: T3's default bindings only; read the user's keybindings from server config in M7
    private func installShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, MainActor.assumeIsolated({ self.handleKey(event) }) else { return event }
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel.window, !composer.isHidden, target != nil else { return false }
        // Digits 1 to 9 pick a question's option unless focus is in an editable field
        // (ComposerPendingUserInputPanel.tsx:157-182, a document-level listener).
        if panel.drawer == .question, !panel.questionPanel.isHidden, !Self.editableTextFocused(in: event.window),
           panel.questionPanel.handleKey(event) {
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command, .shift], event.keyCode == 36 || event.keyCode == 76 {
            // Swallowed even on repeat or with nothing to steer (QueuedRunsControl.tsx:208-214).
            let queue = panel.queue.state
            if !event.isARepeat, case .thread = target, queue.canPromoteToSteer, !queueBusy, let first = queue.items.first?.runId {
                promoteToSteer(first)
            }
            return true
        }
        return pickers.handleShortcut(event)
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
        queuedEdit = nil
        questionRequestId = nil
        target = .thread(id)
        projection = nil
        requests = PendingRequests()
        optimistic = carried
        if carried.isEmpty { pendingMessageId = nil }
        resuming = false
        loadPrompt()
    }

    /// Sidebar new-thread button (`handleNewThread`, useHandleNewThread.ts:64-390): the open
    /// thread's project, else the first project. Reuses the project's draft session, else mints one.
    @discardableResult
    func newThread(in chosen: ProjectShell? = nil) -> Bool {
        guard let snapshot = sidebar?.snapshot, !snapshot.projects.isEmpty else { return false }
        var projectId: ProjectId?
        switch target {
        case .thread(let id): projectId = snapshot.threads.first { $0.id == id }?.projectId
        case .draft(let s): projectId = ProjectId(s.projectId)
        case nil: break
        }
        let project = chosen ?? snapshot.projects.first { $0.id == projectId } ?? snapshot.projects[0]
        showDraft(project)
        return true
    }

    private func showDraft(_ project: ProjectShell) {
        let key = "\(environment ?? ""):\(project.id.rawValue)"
        let session = sessions[key] ?? DraftSession(draftId: UUID().uuidString.lowercased(), threadId: UUID().uuidString.lowercased(),
                                                    projectId: project.id.rawValue, createdAt: Date())
        sessions[key] = session
        flushPrompt()
        queuedEdit = nil
        questionRequestId = nil
        target = .draft(session)
        projection = nil
        requests = PendingRequests()
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
        pickers.prompt = composer.text
        refresh()
        DispatchQueue.main.async { [weak self] in self?.composer.focus() }
    }

    private func remember(_ text: String) {
        // An open question: the editor is its custom answer, not the prompt.
        if questionRequestId != nil {
            if text != panel.questionPanel.customAnswer { panel.questionPanel.setCustomAnswer(text) }
            return
        }
        pickers.prompt = text
        // An open queued edit keeps its text out of the thread's prompt.
        guard queuedEdit == nil, let key = draftKey else { return }
        prompts[key] = text.isEmpty ? nil : text
        scheduleSave()
        refresh()
    }

    private func flushPrompt() {
        guard queuedEdit == nil, questionRequestId == nil else { return }
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
        requests = projection.map(PendingRequests.derive) ?? PendingRequests()
        // A pending approval or question settles the local send (ChatView.logic.ts:1236-1238).
        if !requests.isEmpty { pendingMessageId = nil }
        let confirmed = Set(projection?.messages.map(\.id) ?? [])
        optimistic.removeAll { confirmed.contains($0.id) }
        if let id = pendingMessageId, confirmed.contains(id) { pendingMessageId = nil }
        // Resume is done once a run is active again.
        if resuming, let projection, ComposerLogic.RunState(runs: projection.runs).canInterrupt { resuming = false }
        // The edited message left the queue (it started, or another client removed it): the
        // unsaved text moves to an empty prompt, else it is dropped (queuedMessageEdit.ts:10-24).
        if let edit = queuedEdit, projection?.runs.contains(where: { $0.id == edit.runId && $0.status == .queued }) != true {
            let unsaved = composer.text
            queuedEdit = nil
            composer.editingQueued = false
            let saved = draftKey.flatMap { prompts[$0] } ?? ""
            composer.text = saved.isEmpty ? unsaved : saved
            remember(composer.text)
        }
        refresh()
    }

    private func refresh() {
        let runs = projection?.runs ?? []
        composer.runState = ComposerLogic.RunState(runs: runs)
        composer.isBusy = pendingMessageId != nil || resuming
        var placeholder = ComposerLogic.PlaceholderInput()
        placeholder.disconnected = shell == nil
        placeholder.approvalPending = requests.activeApproval != nil
        composer.placeholderInput = placeholder
        updateRequests()
        composer.sendDisabledReason = shell == nil ? "Environment disconnected" : nil
        composer.editingQueued = queuedEdit != nil
        panel.model.optimisticMessages = optimistic
        panel.queue.state = target == nil || panel.isDraft ? ComposerLogic.QueueState()
            : ComposerLogic.QueueState(projection: projection, optimistic: optimistic)
        panel.queue.editingRunId = queuedEdit?.runId
        panel.queue.isBusy = queueBusy
        updatePickers()
        panel.updateComposerShown()
    }

    // MARK: Requests

    /// The top drawer (ChatComposer.tsx:6727-6781): the oldest approval, else the oldest question.
    private func updateRequests() {
        guard case .thread(let threadId) = target else {
            leaveQuestion()
            panel.drawer = .none
            composer.pending = .none
            return
        }
        if let approval = requests.activeApproval {
            leaveQuestion()
            panel.approvalPanel.configure(approval, pendingCount: requests.approvals.count, threadId: threadId)
            panel.approvalPanel.isResponding = responding.contains(approval.requestId)
            panel.drawer = .approval
            composer.pending = .approval
        } else if let input = requests.activeUserInput {
            let question = panel.questionPanel
            question.configure(input, threadId: threadId)
            question.isResponding = responding.contains(input.requestId)
            if questionRequestId == nil {
                // The editor becomes the answer field; an open queued edit closes first.
                if queuedEdit != nil { endEdit() }
                flushPrompt()
            }
            questionRequestId = input.requestId
            panel.drawer = .question
            syncQuestion()
        } else {
            leaveQuestion()
            panel.drawer = .none
            composer.pending = .none
        }
    }

    /// The question closed: the thread's prompt comes back to the editor.
    private func leaveQuestion() {
        guard questionRequestId != nil else { return }
        questionRequestId = nil
        composer.text = draftKey.flatMap { prompts[$0] } ?? ""
        pickers.prompt = composer.text
    }

    /// The question card changed (pick, typing, next, previous): the editor, placeholder and
    /// footer follow its active question.
    private func syncQuestion() {
        guard questionRequestId != nil, let session = panel.questionPanel.session else { return }
        let question = panel.questionPanel
        if composer.text != question.customAnswer { composer.text = question.customAnswer }
        var placeholder = composer.placeholderInput
        placeholder.questionChoiceOnly = !question.editorEnabled
        composer.placeholderInput = placeholder
        let responding = question.isResponding
        composer.pending = .question(ComposerView.QuestionFooter(
            label: session.primaryLabel(compact: false, responding: responding),
            compactLabel: session.primaryLabel(compact: true, responding: responding),
            enabled: session.canPressPrimary && !responding && shell != nil,
            showsPrevious: session.showsPrevious, responding: responding,
            showsAttach: question.editorEnabled))
        panel.needsLayout = true
    }

    /// An option pick replaced typed text: it goes to the end of the thread's prompt (ChatView.tsx:10253-10270).
    private func carryDisplaced(_ text: String) {
        guard let key = draftKey else { return }
        let next = UserInputAnswers.carryDisplaced(prompts[key] ?? "", text)
        prompts[key] = next.isEmpty ? nil : next
        scheduleSave()
    }

    /// `runtime-request.respond` or `thread.user-input.dismiss` (ChatView.tsx:10114-10230). The
    /// actions stay disabled until the call returns; the request leaves the composer when the
    /// stream marks it resolved, not on the reply.
    private func respond(_ payload: JSONValue, fallback: String) {
        guard let shell, case .string(let requestId)? = payload["requestId"], !responding.contains(requestId) else { return }
        responding.insert(requestId)
        refresh()
        let supervisor = shell.supervisor
        Task { [weak self] in
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload) } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport {} else {
                    self?.fail(Self.message(error, fallback: fallback), restore: nil)
                }
            }
            self?.responding.remove(requestId)
            self?.refresh()
        }
    }

    private static func editableTextFocused(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextView)?.isEditable == true
    }

    /// The pickers follow the draft key, the server config and the open thread.
    private func updatePickers() {
        let snapshot = sidebar?.snapshot
        let thread = shellThread
        let projectId: ProjectId? = switch target {
        case .draft(let s): ProjectId(s.projectId)
        case .thread: thread?.projectId
        case nil: nil
        }
        let project = snapshot?.projects.first { $0.id == projectId }
        let context = ComposerSelectionContext(
            catalog: ProviderCatalog(serverConfig.providers), thread: thread, projectDefaultModel: project?.defaultModelSelection,
            serverDefaults: serverConfig.settings,
            hasStartedSession: ComposerLogic.QueueState.hasStartedSession(projection),
            supportsProviderHandoff: thread == nil || ComposerLogic.QueueState.supportsProviderHandoff(projection))
        pickers.update(draftKey: draftKey ?? "", context: context)
        // A new label (config arrived, thread switched) changes the controls' width.
        composer.needsLayout = true
    }

    // MARK: Commands

    private var shellThread: ThreadShell? {
        guard case .thread(let id) = target else { return nil }
        return sidebar?.snapshot?.threads.first { $0.id == id }
    }

    private func send(_ text: String, mode: ComposerLogic.SendMode) {
        guard let shell, pendingMessageId == nil, let target else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let edit = queuedEdit { saveEdit(edit, text: trimmed); return }
        let messageId = MessageId(UUID().uuidString.lowercased())
        let commandId = UUID().uuidString.lowercased()
        let now = T3Timestamp(Date())
        let picks = pickers.current
        let picksKey = draftKey
        guard let selection = picks.modelSelection else {
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
                "modelSelection": selectionJSON, "runtimeMode": .string(picks.runtimeMode.rawValue),
                "interactionMode": .string(picks.interactionMode.rawValue), "workspaceStrategy": .object(["type": .string("root")]),
                "initialMessage": .object(["messageId": .string(messageId.rawValue), "text": .string(trimmed), "attachments": .array([])]),
            ])
            Task { [weak self] in
                do {
                    _ = try await supervisor.request("orchestration.launchThread", payload: payload)
                    guard let self else { return }
                    pickers.store.didSend(session.draftId)
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
            let runtimeChange = picks.runtimeModeToPersist, interactionChange = picks.interactionModeToPersist
            Task { [weak self] in
                do {
                    // Changed access and interaction modes are persisted before the message, each
                    // aborting the send on failure (persistThreadSettingsForNextTurn, ChatView.tsx:6267-6340).
                    if let runtimeChange {
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                            "type": .string("thread.runtime-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                            "threadId": .string(threadId.rawValue), "runtimeMode": .string(runtimeChange.rawValue)]))
                    }
                    if let interactionChange {
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                            "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                            "threadId": .string(threadId.rawValue), "interactionMode": .string(interactionChange.rawValue)]))
                    }
                    _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(command))
                    if let picksKey { self?.pickers.store.didSend(picksKey) }
                    self?.refresh()
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
        guard state.canResume, let selection = pickers.current.modelSelection else { return }
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

    // MARK: Queue

    /// One strip command (`queued-run.cancel`, `queued-run.reorder`): the strip is busy until it returns.
    private func queueCommand(_ type: String, _ fields: [String: JSONValue], fallback: String) {
        guard let shell, case .thread(let threadId) = target, !queueBusy else { return }
        var command = fields
        command["type"] = .string(type)
        command["commandId"] = .string(UUID().uuidString.lowercased())
        command["threadId"] = .string(threadId.rawValue)
        queueBusy = true
        refresh()
        let supervisor = shell.supervisor
        Task { [weak self] in
            defer { self?.queueBusy = false; self?.refresh() }
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(command)) } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.fail(Self.message(error, fallback: fallback), restore: nil)
            }
        }
    }

    /// Steer now: the server cancels the queued run and steers the same message into the active run.
    private func promoteToSteer(_ runId: RunId) {
        guard let active = panel.queue.state.activeRunId, panel.queue.state.canPromoteToSteer else { return }
        queueCommand("queued-message.promote-to-steer", ["queuedRunId": .string(runId.rawValue), "targetRunId": .string(active.rawValue)],
                     fallback: "Failed to steer the queued message.")
    }

    private func beginEdit(_ item: ComposerLogic.QueueState.Item) {
        guard let runId = item.runId, case .thread(let threadId) = target, queuedEdit == nil, !queueBusy else { return }
        flushPrompt()
        queuedEdit = QueuedEdit(runId: runId, threadId: threadId)
        composer.text = item.text
        pickers.prompt = item.text
        refresh()
        composer.focus()
    }

    /// Cancel: back to the thread's own prompt (`cancelEditingQueuedRun`).
    private func endEdit() {
        guard queuedEdit != nil else { return }
        queuedEdit = nil
        loadPrompt()
    }

    /// Enter while editing saves with `queued-run.edit` and keeps the edit open on failure.
    private func saveEdit(_ edit: QueuedEdit, text: String) {
        guard let shell, !queueBusy else { return }
        let command: JSONValue = .object([
            "type": .string("queued-run.edit"), "commandId": .string(UUID().uuidString.lowercased()),
            "threadId": .string(edit.threadId.rawValue), "runId": .string(edit.runId.rawValue), "text": .string(text),
        ])
        queueBusy = true
        refresh()
        let supervisor = shell.supervisor
        Task { [weak self] in
            do {
                _ = try await supervisor.request("orchestration.dispatchCommand", payload: command)
                guard let self else { return }
                queueBusy = false
                if queuedEdit?.runId == edit.runId { endEdit() } else { refresh() }
            } catch {
                self?.queueBusy = false
                self?.refresh()
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.fail("Could not save the edited queued message.", restore: nil)
            }
        }
    }
}
