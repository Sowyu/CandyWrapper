import AppKit
import DesignSystem
import UniformTypeIdentifiers
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
///
/// Thread and project ids here are scoped (`EnvironmentScope`). Commands go to the target's own
/// environment session with the local ids.
@MainActor
final class ComposerController {
    enum Target: Equatable {
        case thread(ThreadId)
        case draft(DraftSession)
    }

    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private var composer: ComposerView { panel.composer }
    private let environments: Environments
    private var settingsWorkspaceTask: Task<Void, Never>?
    private var settingsWorkspaceSendPending = false
    private(set) var target: Target?
    private var projection: ThreadProjection?
    /// Sent messages the stream hasn't confirmed, for the open thread.
    private var optimistic: [ChatMessage] = []
    /// A send whose message hasn't shown up in the projection yet.
    private var pendingMessageId: MessageId?
    private var uncertainFanout: [String: ThreadId] = [:]
    private var fanoutInFlight: Set<String> = []
    private var resuming = false
    private var threadRewindBusy = false
    /// `projectCloneSendBlockReason` for the open thread's or draft's project, set by the clone controller.
    var projectCloneSendBlock: String? { didSet { if projectCloneSendBlock != oldValue { syncSendBlock() } } }
    /// The "Not connected" toasts on screen, at most three (`ENVIRONMENT_UNAVAILABLE_SEND_TOAST_TRAIL_SIZE`).
    private var environmentToastIds: [Int] = []
    private var recoveryPending: Set<ThreadId> = []
    /// The user's `followUpBehavior` is steer; pending approvals steer regardless.
    private var followUpSteers = false
    /// A send is declining approvals before it goes (`sendInFlightRef` in T3).
    private var declineInFlight = false
    /// The thread whose background work Stop is stopping (`stoppingBackgroundWorkKey`, ChatView.tsx:3794).
    private var stoppingBackgroundWork: ThreadId?
    private var recoveryErrors: [ThreadId: String] = [:]
    private var recoveryResetWork: DispatchWorkItem?
    private var recoveryResetKey: String?
    private var threadWorktreeSetupTask: Task<Void, Never>?
    private var threadWorktreeSetupTarget: ThreadId?
    private var threadFindTask: Task<Void, Never>?
    private var threadFindRefreshTask: Task<Void, Never>?
    private var threadFindSearching = false
    private var threadFindRefreshPending = false
    private var threadFindResult: ThreadFindResult?
    private var threadFindGeneration = 0
    private var threadFindTarget: ThreadId?

    /// Opens a thread in the panel (the launch's new thread).
    var openThread: ((ThreadId) -> Void)?
    /// "Open provider setup" on the provider status banner: Settings, Providers.
    var openProviderSetup: (() -> Void)?
    /// The provider status the user dismissed (`dismissedProviderStatusBannerKey`).
    private var dismissedProviderBannerKey: String?
    /// Opens a new thread in the open thread's project, leaving the thread (`handleNewThreadInActiveProject`).
    var onNewThread: (() -> Void)?
    /// The draft picker's "Add project" row.
    var onAddProject: (() -> Void)?
    /// Dither's project popover: "No project" starts a draft in this machine's scratch project, nil hides the row.
    var scratchEnvironment: (() -> String?)?
    var onStartWithoutProject: ((String) -> Void)?
    /// Dither's project popover: "Manage projects" opens Settings, Projects.
    var onManageProjects: (() -> Void)?
    /// The open draft's project is a Git repository: the strip shows the run context and branch.
    var draftIsGitRepo = false { didSet { if draftIsGitRepo != oldValue { updateRunOn() } } }
    /// The target changed (a thread or draft opened, or the draft's workspace changed).
    var onTargetChange: (() -> Void)?
    /// The provider or model pick changed: the pending handoff row follows it (ChatView.tsx:7744-7757).
    var onModelChange: (() -> Void)?
    /// The model the next send uses.
    var selectedModel: ModelSelection? { pickers.current.modelSelection }
    /// After thread state or prompt content presence changes: the branch notice follows the prompt.
    var onRefresh: (() -> Void)?
    private var refreshedHasUserContent: Bool?
    /// `composerDraftHasUserContent` (composerDraftStore.ts:426-441): typed text or an attachment.
    var hasUserContent: Bool { !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentAttachments.isEmpty }

    /// The open draft, if the panel shows one.
    var currentDraft: DraftSession? { if case .draft(let s) = target { s } else { nil } }
    /// The open server thread.
    var openThreadId: ThreadId? { if case .thread(let id) = target { id } else { nil } }

    func focusComposer() { DispatchQueue.main.async { [weak self] in self?.composer.focus() } }

    // MARK: Prompt links (promptLinks/linkedPrompt.ts, NewThreadLinkView.tsx in T3 3105)

    private var linkedPromptToast: Int?

    /// `warnAboutHiddenCharacters`: stays until dismissed.
    func warnAboutHiddenCharacters(_ prompt: PromptLinks.Prompt) {
        let n = prompt.hiddenCharacters
        guard n > 0 else { return }
        panel.toasts.show(ToastView(title: "This prompt had hidden characters, it may be malicious",
                                    message: "CandyWrapper removed \(n) hidden character\(n == 1 ? "" : "s"). Read the prompt before you send it.",
                                    kind: .warning), timeout: 0)
    }

    /// `placeLinkedPrompt`: the open thread's or draft's composer takes the prompt to read and send. Text the user
    /// already typed there is replaced only from the toast's "Replace draft". `notes` say what the link didn't get.
    func placeLinkedPrompt(_ prompt: PromptLinks.Prompt, notes: [String] = []) {
        warnAboutHiddenCharacters(prompt)
        guard let key = draftKey else { return }
        flushPrompt()
        let place = { [weak self] in
            guard let self else { return }
            if self.draftKey == key, self.questionRequestId == nil, self.queuedEdit == nil {
                self.composer.text = prompt.text
                self.remember(prompt.text)
                self.focusComposer()
            } else {
                self.prompts[key] = prompt.text
                self.scheduleSave()
            }
            self.panel.toasts.show(ToastView(title: "Prompt added from a link",
                                             message: (["Read it before you send."] + notes).joined(separator: " "), kind: .info))
        }
        let existing = prompts[key] ?? ""
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || existing == prompt.text { place(); return }
        if let old = linkedPromptToast { panel.toasts.dismiss(old) }
        linkedPromptToast = panel.toasts.show(ToastView(
            title: "Linked prompt ready", message: "This thread already has a draft. Replace it with the linked prompt?", kind: .info,
            actionTitle: "Replace draft", action: { [weak self] in
                if let id = self?.linkedPromptToast { self?.panel.toasts.dismiss(id) }
                place()
            }), timeout: 0)
    }

    /// `resolvePromptLinkModelSelection` (client-runtime promptLinks.ts:72-105) picked into the open draft. Returns
    /// the note when the link's model isn't used (NewThreadLinkView.tsx:121-127).
    func pickLinkedModel(provider: String, model: String?) -> String? {
        let driver = provider == "claude" ? "claudeagent" : provider
        let usable = pickers.context.catalog.entries.map(\.provider)
            .filter { $0.driver.lowercased() == driver && $0.enabled && $0.availability != "unavailable" }
        let instance = usable.first { $0.status == .ready } ?? usable.first { $0.status == .warning }
        let requested = instance.flatMap { i in model.flatMap { ThreadRelationships.resolveModel(i.models, $0)?.slug } }
        guard let instance, let slug = requested ?? (instance.models.first { $0.isDefault == true } ?? instance.models.first)?.slug else {
            return "The link asked for \(provider), which is not set up here, so your default model is used."
        }
        pickers.select(instance.instanceId, model: slug)
        guard let model, requested == nil else { return nil }
        return "The link asked for \(model), which \(provider) does not offer here, so its default model is used."
    }

    /// Changes a draft's workspace picks and stores them: the open draft, or the stored draft `draftId` when
    /// another one is open (T3 writes by draft id, `setDraftThreadContext`, composerDraftStore.ts:2617). A gone
    /// draft is skipped.
    func updateDraft(id draftId: String? = nil, _ change: (inout DraftSession) -> Void) {
        if let draftId, currentDraft?.draftId != draftId {
            guard let key = sessions.first(where: { $0.value.draftId == draftId })?.key else { return }
            change(&sessions[key]!)
            scheduleSave()
            return
        }
        guard case .draft(var session) = target else { return }
        change(&session)
        if let key = sessions.first(where: { $0.value.draftId == session.draftId })?.key { sessions[key] = session }
        target = .draft(session)
        scheduleSave()
        onTargetChange?()
    }

    /// Model, traits and access: the footer controls and the per-draft picks they own.
    let pickers = ComposerPickers(store: ComposerSelectionStore(), draftKey: "", context: ComposerSelectionContext(catalog: ProviderCatalog([])))
    /// `server.getConfig` providers and settings per environment, followed through `subscribeServerConfig`
    /// on each environment's session (T3 follows every environment's config, CR/state/server.ts:437).
    private var serverConfigs: [String: ServerProviderConfig] = [:]
    private var configSubscriptions: [String: (shell: ShellSession, task: Task<Void, Never>)] = [:]
    private var serverConfig: ServerProviderConfig {
        targetEnvironmentId.flatMap { serverConfigs[$0] } ?? ServerProviderConfig(providers: [])
    }
    /// An environment's providers as its server config last reported them.
    func providers(_ environmentId: String) -> [ServerProvider] { serverConfigs[environmentId]?.providers ?? [] }

    /// A queued message open in the composer (`beginEditingQueuedRun`, ChatView.tsx:4673-4699).
    /// Its text lives here, not in the thread's prompt, which comes back on save or cancel.
    private struct QueuedEdit { let runId: RunId; let threadId: ThreadId; let originalText: String }
    private var queuedEdit: QueuedEdit?
    /// A queue command is in flight: the strip's actions wait (`busyRunId`).
    private var queueBusy = false

    /// The open thread's pending approvals and questions (`derivePendingThreadRequests`).
    private var requests = PendingRequests()
    /// Requests with a respond or dismiss in flight (`respondingRequestIds`): their actions are disabled.
    private var responding: Set<String> = []
    /// The question whose custom answer the editor holds. The thread's prompt waits in `prompts`
    /// until it closes (ChatComposer.tsx shows `activePendingProgress.customAnswer` in place of the prompt).
    private var questionRequestId: String?
    /// Thread errors by draft key and their session dismissals (the banner over the timeline).
    private var threadErrors = ThreadErrorState()
    /// Threads whose Compact chip is off (`fullHistoryThreadKeys`, ChatView.tsx:7711-7726), in memory like T3's.
    /// A send that starts its turn clears its thread's entry; a failed send keeps it.
    private var fullHistoryThreadKeys: Set<String> = []
    /// One wakeup at the moment the open thread's resume compaction offer becomes due. T3 re-renders on a
    /// minute clock; this waits for that one moment and nothing ticks before or after.
    private var resumeOfferWork: (due: Date, work: DispatchWorkItem)?
    /// The open thread's context window (`activeContextWindow`), whether or not the meter shows.
    private var contextWindow: ThreadContextWindowUsage?
    /// `compactThreadUnavailable` as the last refresh found it; the `/compact` slash item reads it.
    private var compactUnavailable = true
    /// The `/`, `@`, `$` and `#` menus' searches and the chips' context records (extension below).
    private var menuState = MenuState()

    /// Files attached to question answers, by `questionKey` (T3's `questionAttachmentDraftId`).
    fileprivate var questionFiles: [String: [QuestionFile]] = [:]
    /// Each environment's `questionAttachments` capability and upload limit (`fileAttachmentStagingLimit`),
    /// read from `/.well-known/t3/environment` when its session changes.
    fileprivate var capabilities: [String: (questionAttachments: Bool, uploadLimit: Int?, threadStop: Bool)] = [:]
    /// Redesign's "+" > Threads set it: the bare `@` it inserts lists threads, not files.
    fileprivate var browsingThreads = false
    fileprivate var supportsQuestionAttachments: Bool { targetEnvironmentId.flatMap { capabilities[$0]?.questionAttachments } ?? false }
    fileprivate var fileUploadLimit: Int? { targetEnvironmentId.flatMap { capabilities[$0]?.uploadLimit } }
    private var capabilityTasks: [String: Task<Void, Never>] = [:]

    /// Draft attachments by draft key (extension "Attachments" below), saved with the drafts
    /// (`DraftAttachmentRecord`). Restored ones wait here for their environment to connect.
    private var restoredUploads: [String: DraftAttachmentRecord.Pending] = [:]
    /// Restored files whose upload the server has not confirmed yet: they keep their upload id when saved.
    private var unverifiedUploads: Set<String> = []
    private var savedDraftAttachments: [DraftAttachmentRecord] = []
    private var draftAttachments: [String: [ComposerAttachment]] = [:]
    private var attachmentTasks: [String: Task<Void, Never>] = [:]
    /// A send that is retrying failed uploads, by draft key; it goes once they are all ready.
    private var sendAfterRetry: [String: (text: String, mode: ComposerLogic.SendMode, background: Bool)] = [:]
    /// Images still being prepared per draft key: they hold their attachment slots.
    private var preparingImages: [String: Int] = [:]
    /// Uploaded attachment ids to their local file, so a sent image shows before the server copy is fetched.
    private var sentFiles: [String: URL] = [:]
    /// Server copies being fetched, so a cell and a chip asking for one image share one download.
    private var attachmentFetches: [String: Task<URL?, Never>] = [:]
    /// The prompt stash (`usePromptStashStore`), shared by every thread and environment like T3's.
    private lazy var stash = PromptStashStore(directory: Self.supportDirectory.appendingPathComponent("PromptStash", isDirectory: true))
    private var stashInFlight: Set<String> = []
    private var stashPulseWork: DispatchWorkItem?
    private var stashKeyMonitor: Any?
    /// The open stash delete confirmation's Delete action, nil while none is up.
    private var stashDeleteConfirm: (@MainActor () -> Void)?
    /// `useDelayedStatus` for the thread's sync row: the phase, when it was asked for and shown.
    private var syncStatus = DelayedStatus()
    /// The attachments the chips were last drawn for; chips rebuild only when these change.
    private var chipAttachments: [ComposerAttachment] = []

    // Persisted like T3's `t3code:composer-drafts:v1`: prompts by draft key, sessions by scoped project id.
    // v2 sessions hold scoped ids; v1 (one environment) is read once and scoped by its key's prefix.
    private static let promptsKey = "composer.prompts.v1", sessionsKey = "composer.draftSessions.v2"
    private static let sessionsKeyV1 = "composer.draftSessions.v1"
    private var prompts: [String: String]
    private var sessions: [String: DraftSession]
    private var saveWork: DispatchWorkItem?
    private lazy var refreshes = ComposerRefreshCoordinator(
        threadState: { [weak self] in self?.refreshThreadState() },
        promptState: { [weak self] in self?.refreshPromptState() })

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        let defaults = UserDefaults.standard
        prompts = defaults.dictionary(forKey: Self.promptsKey) as? [String: String] ?? [:]
        func decode(_ key: String) -> [String: DraftSession]? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: DraftSession].self, from: $0) }
        }
        sessions = decode(Self.sessionsKey) ?? Self.scopeV1(decode(Self.sessionsKeyV1) ?? [:])
        restoreDraftAttachments(defaults)
        if let data = defaults.data(forKey: "composer.reviewComments.v1"),
           let records = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            menuState.records.merge(records.filter { $0.value["kind"]?.stringValue == "review-comment" }) { current, _ in current }
        }
        applyClientSettings()
        pickers.favorites = { [unowned self] in self.modelPreferences(self.targetEnvironmentId).favorites }
        pickers.modelPreferences = { [unowned self] in self.modelPreferences(self.targetEnvironmentId).providers }
        pickers.toggleFavorite = { [unowned self] id, model in self.toggleModelFavorite(self.targetEnvironmentId, id, model) }
        ClientSettingsStore.shared.observe { [weak self] keys in
            guard let self else { return }
            self.applyClientSettings()
            if keys.contains("planModeEnabled") || keys.contains("contextWindowMeterEnabled") { self.refresh() }
        }
        composer.restingBlocked = { [weak self] in
            guard let self else { return true }
            return self.panel.menus.isOpen || self.panel.stashMenuOpen || !self.panel.timeline.overflowsComposerViewport
                || self.composer.isBusy || self.draftKey.flatMap { self.threadErrors.visible($0, shell: self.shellThread) } != nil
        }
        panel.timeline.onComposerScrollGesture = { [weak self] delta, canScroll, towardEnd in
            self?.composer.recordTimelineScroll(delta: delta, canScroll: canScroll, towardEnd: towardEnd)
        }
        composer.onSend = { [weak self] text, mode, background in self?.send(text, mode: mode, background: background) }
        // `compactThreadContext` (ChatComposer.tsx:4315-4330) then `onCompactContext` (ChatView.tsx:8651-8654):
        // `/compact` runs as its own turn and the draft stays.
        composer.contextWindowMeter.onCompact = { [weak self] in
            guard let self, !self.composer.contextWindowMeter.compactDisabled, self.requests.isEmpty,
                  !self.composer.runState.canInterrupt, !self.composer.isBusy else { return }
            self.sendThreadStandalone("/compact", failure: "Failed to compact context.")
        }
        composer.onToggleKeepFullHistory = { [weak self] in
            guard let self, let key = self.draftKey else { return }
            if self.fullHistoryThreadKeys.remove(key) == nil { self.fullHistoryThreadKeys.insert(key) }
            self.refresh()
        }
        composer.onStop = { [weak self] in self?.stop() }
        composer.onImplementInNewThread = { [weak self] in self?.implementPlanInNewThread() }
        composer.onResume = { [weak self] in self?.resume() }
        composer.onTextChange = { [weak self] text in self?.remember(text) }
        panel.hero.onPickProject = { [weak self] anchor in self?.pickProject(from: anchor) }
        panel.contextStrip.runOn.onAutoBalance = { [weak self] in self?.chooseAutomaticEnvironment() }
        panel.contextStrip.runOn.onChange = { [weak self] env in self?.changeEnvironment(env) }
        composer.stageArt = sidebar.stage != .none && ClientSettingsStore.shared.current.string("environmentIdentificationMode") == "artwork"
        composer.footerControls = [pickers.controlsView]
        pickers.onPromptChange = { [weak self] text in
            guard let self else { return }
            composer.text = text
            remember(text)
        }
        pickers.focusComposer = { [weak self] in self?.composer.focus() }
        pickers.onBlocked = { [weak self] reason in self?.report(.modelChangeBlocked(reason), key: nil) }
        // ponytail: Settings has no page per provider, so Manage lands on Providers; deep-link when it gets one
        pickers.onManageProvider = { [weak self] _ in self?.openProviderSetup?() }
        panel.errorBanner.onDismiss = { [weak self] in self?.dismissThreadError() }
        composer.historyMessages = { [weak self] in self?.historyMessages() ?? [] }
        pickers.onChange = { [weak self] _ in
            self?.composer.needsLayout = true
            self?.onTargetChange?()
            self?.onModelChange?()
        }
        let queue = panel.queue
        queue.onRemove = { [weak self] runId in self?.queueCommand("queued-run.cancel", ["runId": .string(runId.rawValue)]) }
        queue.onReorder = { [weak self] runId, before in
            self?.queueCommand("queued-run.reorder", ["runId": .string(runId.rawValue), "beforeRunId": before.map { .string($0.rawValue) } ?? .null])
        }
        queue.onSteer = { [weak self] runId in self?.promoteToSteer(runId) }
        queue.onEdit = { [weak self] item in self?.beginEdit(item) }
        queue.onCancelEdit = { [weak self] in self?.endEdit() }
        panel.approvalPanel.onRespond = { [weak self] _, payload in
            self?.respond(payload, failure: ComposerFeedback.Failure.approval)
        }
        panel.lazyQuestionPanel.configure { [weak self] question in
            question.onSubmit = { [weak self] payload in self?.submitAnswers(payload) }
            question.onDismiss = { [weak self] payload in self?.respond(payload, failure: ComposerFeedback.Failure.dismissQuestion) }
            question.onDisplacedAnswer = { [weak self] text in self?.carryDisplaced(text) }
            question.onChange = { [weak self] in self?.syncQuestion() }
        }
        composer.onAttach = { [weak self] in self?.attachPressed() }
        composer.onInsertRejected = { [weak self] in
            self?.toast(.error, "Unable to add to chat", "The composer is busy; try again once it is ready.")
        }
        composer.fileList.onRemove = { [weak self] id in self?.removeQuestionFile(id) }
        composer.fileList.onOpen = { [weak self] id in self?.expandQuestionFile(id) }
        composer.fileList.onRetry = { [weak self] id in self?.retryQuestionFile(id) }
        composer.onQuestionAdvance = { [weak self] in self?.panel.lazyQuestionPanel.loaded?.advance() }
        composer.onQuestionPrevious = { [weak self] in self?.panel.lazyQuestionPanel.loaded?.previous() }
        panel.lazyGoalBanner.configure { [weak self] banner in banner.onAction = { [weak self] index in
            guard let self, let goal = self.shellThread?.goal, let index else { return }
            let resume = index == 0 && ThreadGoalPresentation.canResume(goal)
            // ChatView.tsx:7526, 7534.
            self.sendThreadStandalone(resume ? "/goal resume" : "/goal clear", failure: resume ? "Failed to resume goal." : "Failed to clear goal.")
        } }
        panel.lazyRecoveryBanner.configure { [weak self] banner in banner.onAction = { [weak self] index in self?.updateThreadRecovery(index) } }
        panel.model.onEditPrompt = { [weak self] message in self?.editEarlierPrompt(message) }
        panel.header.onEmptyTitle = { [weak self] in self?.toast(.warning, "Thread title cannot be empty") }
        panel.header.onRenameThread = { [weak self] title in
            guard let self, let id = self.openThreadId else { return }
            Task {
                do { try await self.environments.dispatch(id, ThreadCommands.rename(id.localId, title: title)) }
                catch { self.toast(.error, "Failed to rename thread", error.localizedDescription) }
            }
        }
        panel.lazyFindBar.configure { [weak self] bar in
            bar.input.onChange = { [weak self] _ in self?.searchThread() }
            bar.onStep = { [weak self] delta in self?.searchThread(delta: delta) }
            bar.onRetry = { [weak self] in self?.searchThread() }
            bar.onClose = { [weak self] in self?.closeThreadFind() }
        }
        setUpMenus()
        setUpAttachments()
        // The send gate follows the connection, not only the session (`activeEnvironmentUnavailable`).
        environments.observe { [weak self] in self?.syncSendBlock() }
        refresh()
    }

    /// v1 sessions were keyed `environmentId:projectId` with unscoped ids inside.
    static func scopeV1(_ v1: [String: DraftSession]) -> [String: DraftSession] {
        var out: [String: DraftSession] = [:]
        for (key, var s) in v1 {
            guard let env = EnvironmentScope.environmentId(of: key), !env.isEmpty else { continue }
            s.projectId = EnvironmentScope.key(env, s.projectId)
            s.threadId = EnvironmentScope.key(env, s.threadId)
            out[key] = s
        }
        return out
    }

    /// The session (shell) of the target's environment. Nil without a session; a session stays while it
    /// reconnects, so `connected` says whether a send can go out.
    private var shell: ShellSession? { environments.session(targetEnvironmentId) }

    /// `activeEnvironmentConnectionPhase === "connected"` (ChatView.tsx:2676-2677). A send while the socket
    /// is down would fail at once and only put the text back, so T3 refuses it with a toast instead.
    private var connected: Bool { shell != nil && targetEnvironmentId.flatMap { environments.state($0) }?.status == .connected }

    var targetEnvironmentId: String? {
        switch target {
        case .thread(let id): id.environmentId
        case .draft(let s): ProjectId(s.projectId).environmentId
        case nil: nil
        }
    }

    /// An environment's session started, was replaced or ended: its config stream and capabilities follow.
    func sessionChanged(_ environmentId: String) {
        let shell = environments.session(environmentId)
        if shell !== configSubscriptions[environmentId]?.shell {
            configSubscriptions[environmentId]?.task.cancel()
            configSubscriptions[environmentId] = shell.map { ($0, subscribeConfig($0)) }
            readCapabilities(shell, environmentId: environmentId)
            if shell == nil, environmentId == environments.primaryId {
                ThemeLibrary.shared.setEnvironmentThemes([])
            }
        }
        // Restored attachments upload or verify once the new session has connected (requests are not queued).
        var restored: [(key: String, id: String, pending: DraftAttachmentRecord.Pending)] = []
        for (key, attachments) in draftAttachments where shell != nil {
            for attachment in attachments where attachment.environmentId == environmentId {
                if let pending = restoredUploads.removeValue(forKey: attachment.id) { restored.append((key, attachment.id, pending)) }
            }
        }
        if let supervisor = shell?.supervisor, !restored.isEmpty {
            Task { [weak self] in
                guard await supervisor.waitForConnection(after: -1) != nil, let self else { return }
                for r in restored {
                    switch r.pending {
                    case .upload: startUpload(r.id, key: r.key)
                    case .verify: verifyRestoredUpload(r.id, key: r.key)
                    case .reattach: break
                    }
                }
            }
        }
        refresh()
    }

    /// `subscribeServerConfig`: a snapshot first, then provider and settings updates (protocol.md 1562).
    private func subscribeConfig(_ shell: ShellSession) -> Task<Void, Never> {
        let env = shell.environmentId
        // `usageLimitSources` streams the hubs' quota; `usageLimitsCommand` says this client answers `/usage-limits`.
        let stream = shell.supervisor.subscribe("subscribeServerConfig", payload: {
            .object(["environmentThemes": .bool(true), "usageLimitSources": .bool(true), "usageLimitsCommand": .bool(true)])
        }, handler: { [weak self] event in
            guard case .value(let json) = event, let change = try? json.decode(as: ServerConfigEvent.self) else { return }
            await MainActor.run { self?.configChanged(change, environmentId: env) }
        })
        return stream
    }

    private var keybindingsNotice = KeybindingsUpdateNotice()
    /// Host freezes already toasted, as environment and detection time (HostFreezeToastCoordinator.tsx:13-31).
    private var shownStalls: Set<String> = []

    private func configChanged(_ event: ServerConfigEvent, environmentId: String) {
        var config = serverConfigs[environmentId] ?? ServerProviderConfig(providers: [])
        var refreshComposer = true
        switch event {
        case .snapshot(let snapshot):
            // A host that froze reports it on reconnect for a few minutes: say why it dropped, once per stall. The
            // label is the environment's, else its descriptor's (HostFreezeToastCoordinator.tsx:22-24).
            if let stall = snapshot.lastEventLoopStall, shownStalls.insert("\(environmentId):\(stall.detectedAt)").inserted {
                let notice = stall.notice(hostLabel: environments.label(environmentId) ?? snapshot.environmentLabel ?? "This environment")
                toast(.warning, notice.title, notice.description)
            }
            // Hub snapshots never ride in a config snapshot; keep the last ones.
            let themes = config.environmentThemes
            let sources = config.usageLimitSources
            config = snapshot
            config.usageLimitSources = sources
            config.environmentThemes = themes
        case .environmentThemesUpdated(let themes): config.environmentThemes = themes
        case .usageLimitSourcesUpdated(let sources): config.usageLimitSources = sources
        case .providerStatuses(let providers):
            guard config.providers != providers else { return }
            let unchanged = config.providers.count == providers.count
                && zip(config.providers, providers).allSatisfy { $0.hasSamePresentation(as: $1) }
            config.providers = providers
            refreshComposer = !unchanged
        case .settingsUpdated(let settings): config.settings = settings
        case .keybindingsUpdated(let rules):
            config.keybindings = rules
            if environmentId == environments.primaryId, keybindingsNotice.shouldShowSuccess(now: Date.timeIntervalSinceReferenceDate) {
                toast(.success, "Keybindings updated", "Keybindings configuration reloaded successfully.")
            }
        case .keybindingsInvalid(let rules, let message):
            config.keybindings = rules
            if environmentId == environments.primaryId { showKeybindingsWarning(message, config: config) }
        case .other: return
        }
        serverConfigs[environmentId] = config
        // App shortcuts follow the primary environment's keybindings (`primaryServerKeybindingsAtom`).
        if environmentId == environments.primaryId {
            ActiveKeymap.setServerRules(config.keybindings)
            ThemeLibrary.shared.setEnvironmentThemes(config.environmentThemes)
        }
        environments.setIconOverride(environmentId, config.settings.environmentIcon)
        switch event { case .snapshot, .settingsUpdated: migrateModelPreferences(environmentId); default: break }
        if refreshComposer && environmentId == targetEnvironmentId { refresh() }
        onConfigChange?(environmentId)
        configObservers.forEach { $0(environmentId) }
    }

    /// An environment's live shell: a thread draft whose model pick the thread now runs drops it, so the
    /// composer follows later changes made on other clients (composerDraftStore.ts:4152-4219, T3 2767012996).
    func liveShell(_ environmentId: String, _ snapshot: ShellSnapshot?) {
        guard let snapshot, !pickers.store.drafts.isEmpty else { return }
        var models: [String: ModelSelection] = [:]
        for thread in snapshot.threads { models[thread.id.scoped(to: environmentId).rawValue] = thread.modelSelection }
        if pickers.store.reconcileThreadModels({ models[$0] }), environmentId == targetEnvironmentId { refresh() }
    }

    /// `sendShortcut` and `followUpBehavior` (client settings) drive the composer's Enter and follow-up rules.
    private func applyClientSettings() {
        let c = ClientSettingsStore.shared.current
        composer.stageArt = (sidebar?.stage ?? .none) != .none && c.string("environmentIdentificationMode") == "artwork"
        composer.sendShortcut = ComposerLogic.SendShortcut(rawValue: c.string("sendShortcut")) ?? .enter
        composer.collapseOnScroll = c.bool("composerCollapseOnScroll")
        composer.richTextEnabled = c.bool("composerRichTextEnabled")
        followUpSteers = c.string("followUpBehavior") == "steer"
        composer.steerByDefault = followUpSteers || !requests.approvals.isEmpty
    }

    /// `activeProjectSettings.settings.newWorktreesStartFromOrigin` for the open draft: the project's
    /// override, else the environment's setting (default on).
    var newWorktreesStartFromOrigin: Bool {
        guard case .draft(let session) = target, let env = targetEnvironmentId, let raw = serverConfigs[env]?.settings.raw else { return true }
        let projectLocalId = ProjectId(session.projectId).localId.rawValue
        return raw["projectSettingsOverrides"]?[projectLocalId]?["newWorktreesStartFromOrigin"]?.boolValue
            ?? raw["newWorktreesStartFromOrigin"]?.boolValue ?? true
    }

    /// Called after an environment's server config changed (the Settings pages follow it).
    var onConfigChange: ((String) -> Void)?
    /// More listeners for config changes (the Usage page's limits).
    var configObservers: [(String) -> Void] = []
    /// A question is about to take the editor: an open citation comment saves into the prompt first
    /// (T3 3105 9fb4ddb2d, ComposerPromptEditorTiptap.tsx `saveCitationDraft`).
    var onEditorTaken: (() -> Void)?
    /// Every environment's config, for the Usage page.
    var allConfigs: [String: ServerProviderConfig] { serverConfigs }
    /// An environment's last `server.getConfig` snapshot with its updates.
    func config(_ environmentId: String) -> ServerProviderConfig? { serverConfigs[environmentId] }

    /// `isScratchProject`: the project sits at its environment's scratch folder.
    func isScratch(_ project: ProjectShell) -> Bool {
        guard let env = project.id.environmentId, let root = config(env)?.scratchWorkspaceRoot else { return false }
        return SidebarModel.normalizeProjectPath(root) == SidebarModel.normalizeProjectPath(project.workspaceRoot)
    }

    /// An environment's grants arrived: the send button may now say it can't change threads, and background work may now be stoppable.
    func grantsChanged() { syncSendBlock(); updateBackgroundWorkBanner(shellThread) }

    /// Applies the settings a `server.updateSettings` reply returned, before `settingsUpdated` arrives.
    func applySettings(_ environmentId: String, _ raw: JSONValue) {
        guard serverConfigs[environmentId] != nil, let settings = try? raw.decode(as: ServerThreadDefaults.self) else { return }
        configChanged(.settingsUpdated(settings), environmentId: environmentId)
    }

    // MARK: Model preferences

    /// Favorites and `providerModelPreferences` for an environment: the server's from 2994 on
    /// (f84589527), else this client's UserDefaults favorites and client setting.
    func modelPreferences(_ environmentId: String?) -> (favorites: [ModelFavorite], providers: JSONValue) {
        let raw = environmentId.flatMap { serverConfigs[$0]?.settings.raw } ?? .null
        let local = pickers.store.favorites, localPrefs = ClientSettingsStore.shared.current["providerModelPreferences"]
        return (ModelPreferences.favorites(raw, local: local), ModelPreferences.providerPreferences(raw, local: localPrefs))
    }

    func toggleModelFavorite(_ environmentId: String?, _ provider: ProviderInstanceId, _ model: String) {
        guard let env = environmentId, let raw = serverConfigs[env]?.settings.raw, ModelPreferences.serverOwned(raw) else {
            pickers.store.toggleFavorite(provider, model)
            return
        }
        let (patch, next) = ModelPreferences.favoritePatch(raw, local: pickers.store.favorites,
                                                           localPreferences: ClientSettingsStore.shared.current["providerModelPreferences"],
                                                           provider: provider, model: model)
        writeModelPreferences(env, patch, shown: ModelPreferences.applying(raw, favorites: next), failure: "Favorites not saved")
    }

    func writeModelPreferences(_ environmentId: String, instanceId: String, hidden: [String], order: [String]) {
        let localPrefs = ClientSettingsStore.shared.current["providerModelPreferences"]
        guard let raw = serverConfigs[environmentId]?.settings.raw, ModelPreferences.serverOwned(raw) else {
            // Before 2994: this client's setting, the instance dropped when both lists are empty.
            var all = localPrefs.objectValue ?? [:]
            if hidden.isEmpty && order.isEmpty { all.removeValue(forKey: instanceId) } else {
                all[instanceId] = .object(["hiddenModels": .array(hidden.map(JSONValue.string)), "modelOrder": .array(order.map(JSONValue.string))])
            }
            ClientSettingsStore.shared.update(["providerModelPreferences": .object(all)])
            return
        }
        let patch = ModelPreferences.preferencesPatch(raw, local: pickers.store.favorites, localPreferences: localPrefs,
                                                      instanceId: instanceId, hidden: hidden, order: order)
        writeModelPreferences(environmentId, patch, shown: ModelPreferences.applying(raw, instanceId: instanceId, hidden: hidden, order: order,
                                                                                    localPreferences: localPrefs),
                              failure: "Model preferences not saved")
    }

    /// Shows `shown` at once, then sends the patch; the reply (or the next `settingsUpdated`) replaces it.
    private func writeModelPreferences(_ env: String, _ patch: JSONValue, shown: JSONValue, failure: String) {
        applySettings(env, shown)
        Task { [weak self] in
            do {
                let result = try await self?.environments.request(env, "server.updateSettings", .object(["patch": patch]))
                if let result { self?.applySettings(env, result) }
            } catch {
                self?.toast(.error, failure, "\(error)")
            }
        }
    }

    /// The connection generation each environment's migration was last sent in (`attemptedMigrationGenerations`).
    private var migrationGenerations: [String: Int] = [:]

    /// `useMigrateModelPreferences` (useSettings.ts:328-368): copies this client's favorites and model preferences
    /// to a 2994 server that has none yet, once per connection. A server that predates the migration drops it and
    /// keeps reporting no favorites, so a retry waits for the next connection (T3 b34501a466). The local copies stay.
    private func migrateModelPreferences(_ env: String) {
        let generation = environments.state(env)?.generation ?? 0
        guard migrationGenerations[env] != generation, let raw = serverConfigs[env]?.settings.raw,
              let patch = ModelPreferences.migrationPatch(raw, local: pickers.store.favorites,
                                                          localPreferences: ClientSettingsStore.shared.current["providerModelPreferences"])
        else { return }
        migrationGenerations[env] = generation
        Task { [weak self] in
            if let result = try? await self?.environments.request(env, "server.updateSettings", .object(["patch": .object(patch)])) {
                self?.applySettings(env, result)
            }
        }
    }

    /// Applies the rules a keybinding upsert or removal returned.
    func applyKeybindings(_ environmentId: String, _ rules: [ResolvedKeybindingRule]) {
        guard serverConfigs[environmentId] != nil else { return }
        configChanged(.keybindingsUpdated(rules), environmentId: environmentId)
    }

    /// A removed environment: its drafts, prompts, picks, question files, config and capabilities go
    /// (T3's `clearComposerDraftsEnvironment`, composerDraftStore.ts:4419-4450, plus the rest).
    func environmentRemoved(_ environmentId: String) {
        let prefix = environmentId + ":"
        configSubscriptions.removeValue(forKey: environmentId)?.task.cancel()
        capabilityTasks.removeValue(forKey: environmentId)?.cancel()
        serverConfigs[environmentId] = nil
        capabilities[environmentId] = nil
        migrationGenerations[environmentId] = nil
        // Sessions are keyed by project group; the environment is in the session's project id.
        let removed = sessions.filter { ProjectId($0.value.projectId).environmentId == environmentId }
        let draftIds = Set(removed.values.map(\.draftId))
        for key in removed.keys { sessions[key] = nil }
        prompts = prompts.filter { !$0.key.hasPrefix(prefix) && !draftIds.contains($0.key) }
        pickers.store.removeDrafts { $0.hasPrefix(prefix) || draftIds.contains($0) }
        for key in questionFiles.keys where key.hasPrefix(prefix) { releaseQuestionFiles(key) }
        if targetEnvironmentId == environmentId { target = nil; projection = nil; requests = PendingRequests() }
        save()
        refresh()
    }

    // MARK: Shortcuts

    /// The composer's keybindings, run by the app's dispatcher (ChatView.tsx:8030-8255).
    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.on("chat.find") { [weak self] _ in self?.openThreadFind() ?? false }

        shortcuts.onKey { [weak self, weak shortcuts] event in
            guard let self, self.isActive else { return false }
            // ChatView's keybindings listen in the capture phase (ChatView.tsx:8277), ahead of the editor, so
            // a bound key such as Mod+Shift+S (`thread.settle`) beats the editor's strikethrough. Only Mod+B
            // stays with the editor (AppSidebarLayout.tsx:105-112).
            if let shortcuts, let command = ActiveKeymap.resolve(event, context: shortcuts.context()), command != "sidebar.toggle" {
                return false
            }
            return self.panel.composer.handleFormattingKey(event)
        }
        // Digits 1 to 9 pick a question's option unless focus is in an editable field
        // (ComposerPendingUserInputPanel.tsx:157-182, a document-level listener, not a keybinding).
        shortcuts.onKey { [weak self] event in
            guard let self, self.isActive, self.panel.drawer == .question,
                  let question = self.panel.lazyQuestionPanel.loaded, !question.isHidden,
                  !Shortcuts.editableFocused(in: event.window) else { return false }
            return question.handleKey(event)
        }
        // `modelPicker.toggle`, `composer.effort`, `composer.mode`: swallowed, repeats ignored.
        shortcuts.on(["modelPicker.toggle", "composer.effort", "composer.mode"]) { [weak self] call in
            guard let self, self.isActive else { return false }
            if !call.isRepeat {
                switch call.command {
                case "modelPicker.toggle": self.pickers.toggleModelPicker()
                case "composer.effort": self.pickers.openTraits()
                default: self.pickers.openAccessMode()
                }
            }
            return true
        }
        // `composer.increaseEffort` and `composer.decreaseEffort` (no default keys, ChatView.tsx:5563-5568):
        // one reasoning step per press, repeats ignored. Nothing happens with no provider, an open question
        // or a queued edit (ChatComposer.tsx:6055-6063; approvals stopped counting in a93b03c8a5).
        shortcuts.on(["composer.increaseEffort", "composer.decreaseEffort"]) { [weak self] call in
            guard let self, self.isActive else { return false }
            if !call.isRepeat, !self.noProviderAvailable, self.questionRequestId == nil, self.queuedEdit == nil,
               let step = self.pickers.stepEffort(call.command == "composer.increaseEffort" ? 1 : -1, cursor: self.composer.expandedCaret),
               step.prompt != self.composer.text {
                self.composer.text = step.prompt
                self.composer.expandedCaret = step.cursor
                self.remember(step.prompt)
            }
            return true
        }
        // `composer.host`: opens "Run on" when it can choose (ChatView.tsx:8183-8192).
        shortcuts.on("composer.host") { [weak self] call in
            guard let self, self.isActive else { return false }
            // Only the machine picker carries `composer.host`, and only with a choice of machines on an
            // unlocked draft (BranchToolbar.tsx:297-299, 697-699); otherwise the key does nothing.
            guard case .draft = self.target, !self.panel.contextStrip.runOn.locked else { return true }
            if !call.isRepeat, ThemeRuntime.isDither(dark: self.panel.effectiveAppearance.isDark) {
                if !self.panel.deviceRow.isHidden { self.panel.deviceRow.performAction() }
            } else if !call.isRepeat, !self.panel.contextStrip.isHidden {
                if self.panel.contextStrip.showsGitControls { self.panel.contextStrip.runContext.performAction() } else { self.panel.contextStrip.runOn.open() }
            }
            return true
        }
        // `composer.cycleHost` (no default key, ChatView.tsx:8195-8208): a draft moves to the next machine
        // of its project group, wrapping; locked drafts and single-machine groups leave the key alone.
        shortcuts.on("composer.cycleHost") { [weak self] call in
            guard let self, self.isActive, case .draft(let session) = self.target, self.pendingMessageId == nil,
                  let group = self.group(of: ProjectId(session.projectId)) else { return false }
            let targets = self.runOnTargets(group)
            guard targets.count > 1 else { return false }
            if !call.isRepeat {
                let current = ProjectId(session.projectId).environmentId
                let index = targets.firstIndex { $0.option.environmentId == current } ?? -1
                self.changeEnvironment(targets[(index + 1) % targets.count].option.environmentId)
            }
            return true
        }
        // `modelPicker.jump.N` while the picker is open (ModelPickerContent.tsx:797-811).
        shortcuts.on(Keymap.modelPickerJumpCommands) { [weak self] call in
            guard let self, self.pickers.isModelPickerOpen,
                  let index = Keymap.jumpIndex(call.command, prefix: "modelPicker.jump.") else { return false }
            if !call.isRepeat { self.pickers.jumpModel(index) }
            return true
        }
        // `thread.steerQueuedMessage`: steers the first queued message; swallowed even on repeat or
        // with nothing to steer (QueuedRunsControl.tsx:208-214). A draft leaves the key alone.
        shortcuts.on("thread.steerQueuedMessage") { [weak self] call in
            guard let self, self.isActive, case .thread = self.target else { return false }
            let queue = self.panel.queue.state
            if !call.isRepeat, queue.canPromoteToSteer, !self.queueBusy, let first = queue.items.first?.runId {
                self.promoteToSteer(first)
            }
            return true
        }
        // `thread.editQueuedMessage` (alt+arrowup while the composer has focus, ChatView.tsx:8232-8241):
        // only from the very start of the draft; opens the latest queued run (`editLatest`,
        // QueuedRunsControl.tsx:216-231), which declines while an edit is open or a command runs.
        shortcuts.on("thread.editQueuedMessage") { [weak self] call in
            guard let self, self.isActive, case .thread = self.target, self.composer.isCaretAtStart,
                  let latest = self.panel.queue.state.items.last(where: { $0.runId != nil }), latest.isEditable,
                  self.queuedEdit == nil, !self.queueBusy else { return false }
            if !call.isRepeat {
                self.panel.queue.expand()
                self.beginEdit(latest)
            }
            return true
        }
        // The stash menu's keys while it is open (`ComposerStashMenu`, a capture-phase listener).
        shortcuts.onKey { [weak self] event in self?.handleStashMenuKey(event) ?? false }
        // `composer.stash` is always claimed, so the key never reaches anything else.
        shortcuts.on("composer.stash") { [weak self] call in
            guard let self else { return false }
            // The Orchestrator's pane has a composer of its own, with its own stash.
            guard self.isActive else { return !call.isRepeat && self.stashElsewhere?() == true }
            if !call.isRepeat { self.stashShortcut() }
            return true
        }
        // `thread.stop` (no default key): interrupts a running turn, else leaves the key alone.
        shortcuts.on("thread.stop") { [weak self] call in
            guard let self, self.isActive, self.composer.runState.canInterrupt else { return false }
            if !call.isRepeat { self.stop() }
            return true
        }
    }

    /// The composer shows for a thread or draft in this window.
    private var isActive: Bool { !composer.isHidden && target != nil && composer.window != nil }
    /// The stash key while this composer is away: true when another composer, the Orchestrator's, took it.
    var stashElsewhere: (() -> Bool)?

    /// Keybinding context keys the composer owns.
    var shortcutContext: [String: Bool] {
        ["composerFocus": composer.isEditorFocused, "modelPickerOpen": pickers.isModelPickerOpen,
         "turnRunning": composer.runState.canInterrupt, "composerRequiresModifier": composer.requiresSendModifier]
    }

    /// The open draft's project, nil on a thread.
    var activeDraftProjectId: ProjectId? {
        if case .draft(let s) = target { return ProjectId(s.projectId) }
        return nil
    }

    /// The project the open thread or draft belongs to (`contextualProjectRef`).
    var activeProjectId: ProjectId? {
        switch target {
        case .thread(let id): sidebar?.snapshot?.threads.first { $0.id == id }?.projectId
        case .draft(let s): ProjectId(s.projectId)
        case nil: nil
        }
    }

    // MARK: Targets

    private var draftKey: String? {
        switch target {
        case .thread(let id): id.rawValue
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
        panel.usageLimitsBanner = nil
        projection = nil
        requests = PendingRequests()
        optimistic = carried
        if carried.isEmpty { pendingMessageId = nil }
        resuming = false
        loadPrompt()
        syncSidebarDrafts()
        onTargetChange?()
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

    /// Opens the draft for `project`'s group, or `stored` as it is (a sidebar draft row). One draft per
    /// project group, like T3's `logicalProjectDraftThreadKeyByLogicalProjectKey`; the session's project is
    /// the member (and so the environment) the thread will be created in. An empty stored draft moves to
    /// the requested member (`setLogicalProjectDraftThreadId` in useHandleNewThread.ts:280-305).
    // ponytail: a draft with text is reused as is; T3 mints a fresh draft then (useHandleNewThread.ts:185-195)
    private func showDraft(_ project: ProjectShell, stored: DraftSession? = nil, workspace: DraftSession? = nil) {
        let group = group(of: project.id)
        let key = group?.key ?? project.id.rawValue
        var session: DraftSession
        // The thread or draft on screen, whose model and interaction mode a new draft carries.
        let carry = pickers.store.carry(from: draftKey, thread: shellThread)
        let sourceDraftId: String? = if case .draft(let s) = target { s.draftId } else { nil }
        if let stored {
            session = stored
        } else if var existing = storedSession(key, members: Set(group?.memberProjectIds ?? [project.id])) {
            let alreadyOpen = sourceDraftId == existing.draftId
            let empty = (alreadyOpen ? composer.text : prompts[existing.draftId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !alreadyOpen, empty {
                if existing.projectId != project.id.rawValue { Self.retarget(&existing, to: project) }
                existing.resetWorkspace(to: workspace)
                sessions[key] = existing
            }
            session = existing
            if empty { pickers.store.seedNewDraft(existing.draftId, carry: carry, carriedFromSameDraft: alreadyOpen,
                                       projectDefault: project.defaultModelSelection, alreadyOpen: alreadyOpen) }
        } else {
            let threadId = ThreadId(UUID().uuidString.lowercased()).scoped(to: project.id.environmentId ?? "")
            session = DraftSession(draftId: UUID().uuidString.lowercased(), threadId: threadId.rawValue,
                                   projectId: project.id.rawValue, createdAt: Date(), envMode: workspace?.envMode,
                                   branch: workspace?.branch, worktreePath: workspace?.worktreePath, startFromOrigin: workspace?.startFromOrigin)
            sessions[key] = session
            pickers.store.seedNewDraft(session.draftId, carry: carry, carriedFromSameDraft: false,
                                       projectDefault: project.defaultModelSelection, alreadyOpen: false)
        }
        flushPrompt()
        queuedEdit = nil
        questionRequestId = nil
        target = .draft(session)
        loadSettingsWorkspaceDefault(project, session: session)
        panel.usageLimitsBanner = nil
        projection = nil
        requests = PendingRequests()
        optimistic = []
        pendingMessageId = nil
        sidebar?.state.activeThreadId = nil
        // The hero names the group (`activeProjectDisplayName`, DraftHeroHeadline.tsx:143-144).
        panel.setDraft(projectTitle: group?.label ?? project.title, isScratch: isScratch(project))
        // T3 keeps the right panel per thread (rightPanelStore.ts); a draft opens with it closed.
        // ponytail: drafts don't remember an opened panel; key the state by draft id if that shows
        panel.setRightPanelOpen(false)
        loadPrompt()
        scheduleSave()
        syncSidebarDrafts()
        onTargetChange?()
    }

    /// Read once when an unresolved draft opens; never override a subsequent workspace choice.
    private func loadSettingsWorkspaceDefault(_ project: ProjectShell, session: DraftSession) {
        settingsWorkspaceTask?.cancel(); settingsWorkspaceTask = nil
        settingsWorkspaceSendPending = false
        guard session.envMode == nil, let environment = project.id.environmentId else { return }
        let environments = environments
        settingsWorkspaceTask = Task { [weak self] in
            let reply = try? await environments.request(environment, "projects.readFile", .object(["cwd": .string(project.workspaceRoot), "relativePath": .string("t3.json")]))
            guard !Task.isCancelled, let self else { return }
            self.settingsWorkspaceTask = nil
            guard case .draft(let current) = self.target, current.draftId == session.draftId,
                  current.projectId == session.projectId, current.envMode == nil else { return }
            let settings = ServerSettingsValues(self.serverConfigs[environment]?.settings.raw)
            let configured = SettingsProjectWorkspaceDefaults.resolveWithSource(settings: settings, projectId: project.id.localId.rawValue,
                legacy: .init(defaultThreadEnvMode: project.defaultThreadEnvMode),
                contents: reply?["truncated"]?.boolValue == true ? nil : reply?["contents"]?.stringValue)
            let mode = SettingsProjectWorkspaceDefaults.newThreadEnvMode(
                configured: configured.mode, source: configured.source, workspaceRoot: project.workspaceRoot,
                newProjectsRoot: self.serverConfigs[environment]?.newProjectsRoot,
                projectHasThreads: self.sidebar?.snapshot?.threads.contains { $0.projectId == project.id } ?? false)
            self.updateDraft { $0.envMode = mode == "worktree" ? .worktree : .local }
        }
    }

    /// The group's session. Sessions saved under a project id (before groups) move to the group key.
    private func storedSession(_ key: String, members: Set<ProjectId>) -> DraftSession? {
        if let session = sessions[key] { return session }
        guard let (old, session) = sessions.first(where: { members.contains(ProjectId($0.value.projectId)) }) else { return nil }
        sessions[old] = nil
        sessions[key] = session
        return session
    }

    /// The merged shell changed: a group may have gained or lost a machine.
    /// After every shell update. "Run on" depends only on the projects and environments, so a thread
    /// change (most updates) skips the regrouping.
    func projectsChanged() {
        guard case .draft = target else { return }
        let inputs = RunOnInputs(projects: sidebar?.snapshot?.projects ?? [], environments: sidebarEnvironments)
        guard inputs != lastRunOnInputs else { return }
        lastRunOnInputs = inputs
        updateRunOn()
    }

    private struct RunOnInputs: Equatable {
        var projects: [ProjectShell]
        var environments: SidebarEnvironments
    }
    private var lastRunOnInputs: RunOnInputs?
    private var loadBalanceTask: Task<Void, Never>?

    /// Drafts whose automatic sample ran and found no machine (`loadBalancing.failed`), so they do not poll.
    private var loadBalanceFailed: Set<String> = []

    /// `automaticEnvironment` for the open draft.
    private func isAutomatic(_ session: DraftSession, machines: Int) -> Bool {
        ProviderLoadBalanceLogic.isAutomatic(enabled: ClientSettingsStore.shared.current.bool("loadBalancingEnabled"), canBalance: machines > 1,
                                             locked: pendingMessageId != nil, selection: session.environmentSelection,
                                             resolved: session.loadBalancedEnvironmentId, hasAttachments: !currentAttachments.isEmpty,
                                             branch: session.branch, worktreePath: session.worktreePath)
    }

    /// Points a draft at another member: same draft and local thread id, the member's environment.
    static func retarget(_ session: inout DraftSession, to project: ProjectShell) {
        session.projectId = project.id.rawValue
        session.threadId = ThreadId(EnvironmentScope.localId(of: session.threadId)).scoped(to: project.id.environmentId ?? "").rawValue
    }

    private var sidebarEnvironments: SidebarEnvironments { sidebar?.state.environments ?? SidebarEnvironments() }

    /// The project group holding `projectId` (`buildProjectGroups`, the sidebar's grouping).
    private func group(of projectId: ProjectId) -> SidebarModel.ProjectGroup? {
        guard let projects = sidebar?.snapshot?.projects else { return nil }
        return SidebarModel.buildProjectGroups(projects, preferredEnvironmentId: sidebarEnvironments.primaryId)
            .first { $0.memberProjectIds.contains(projectId) }
    }

    /// `logicalProjectEnvironments` (ChatView.tsx:2758-2818): the first member per environment in project
    /// order, labelled by its environment (else the id), the primary first, then by label.
    private func runOnTargets(_ group: SidebarModel.ProjectGroup) -> [(option: RunOnOption, project: ProjectShell)] {
        let envs = sidebarEnvironments
        let members = Set(group.memberProjectIds)
        var seen = Set<String>()
        var out: [(option: RunOnOption, project: ProjectShell)] = []
        for project in sidebar?.snapshot?.projects ?? [] where members.contains(project.id) {
            guard let env = project.id.environmentId, seen.insert(env).inserted else { continue }
            out.append((RunOnOption(environmentId: env, label: envs.labels[env] ?? env, machine: envs.machine(env)), project))
        }
        return out.sorted { a, b in
            let ap = a.option.environmentId == envs.primaryId, bp = b.option.environmentId == envs.primaryId
            if ap != bp { return ap }
            return a.option.label.localizedCompare(b.option.label) == .orderedAscending
        }
    }

    /// The draft's "Run on" control: shown with a choice of machines or on a machine other than this one
    /// (`shouldShowEnvironmentIndicator`, BranchToolbar.logic.ts:59-65), a static label without a choice.
    private func updateRunOn() {
        guard case .draft(let session) = target, let group = group(of: ProjectId(session.projectId)) else {
            if case .thread = target { return } // GitController supplies the active thread's context.
            panel.showsContextStrip = false
            onRunOnUpdate?()
            return
        }
        let targets = runOnTargets(group)
        let env = ProjectId(session.projectId).environmentId
        let runOn = panel.contextStrip.runOn
        runOn.options = targets.map(\.option)
        runOn.offersAutoBalance = targets.count > 1 && ClientSettingsStore.shared.current.bool("loadBalancingEnabled")
        // `autoEnvironmentLabel` (ChatView.tsx:4429-4437).
        let automatic = isAutomatic(session, machines: targets.count)
        runOn.autoBalanceLabel = !automatic ? nil : session.loadBalancedEnvironmentId != nil ? "Auto balance"
            : loadBalanceTask != nil ? "Checking machines…" : loadBalanceFailed.contains(session.draftId) ? "Auto balance unavailable" : "Auto balance"
        // An unresolved automatic draft samples the machines once (`useLoadBalancedEnvironment` is mounted only then).
        // ponytail: one sample per draft; T3 re-reads when candidates or weights change. Re-sample on provider or weight changes if drafts stay unresolved
        if automatic, session.loadBalancedEnvironmentId == nil, loadBalanceTask == nil, !loadBalanceFailed.contains(session.draftId) {
            DispatchQueue.main.async { [weak self] in self?.sampleLoadBalance() }
        }
        runOn.selectedId = env
        let project = sidebar?.snapshot?.projects.first { $0.id.rawValue == session.projectId }
        runOn.addTargets = project.flatMap { addProjectTargets?($0, targets.map(\.option.environmentId)) } ?? []
        runOn.locked = (targets.count < 2 && runOn.addTargets.isEmpty) || pendingMessageId != nil
        // `shouldShowComposerContextStrip`: a Git project, or a machine to show.
        panel.contextStrip.showsGitControls = draftIsGitRepo
        panel.showsContextStrip = draftIsGitRepo || targets.count > 1 || (env != nil && env != sidebarEnvironments.primaryId)
        onRunOnUpdate?()
        panel.needsLayout = true
    }

    /// After the draft's "Run on" changes, so Redesign's machine row follows it.
    var onRunOnUpdate: (() -> Void)?

    /// `useAddProjectTargets` for the draft's project and the machines its group already runs on, set by the app.
    var addProjectTargets: ((ProjectShell, [String]) -> [AddProjectToMachine.Target])?

    /// A machine connected, dropped or changed its config: the draft's Add to another machine targets follow.
    func addTargetsMayHaveChanged() { updateRunOn() }

    /// After Add to another machine (AddProjectToMachineDialog.tsx:137-159): a draft open on the source project moves
    /// to the clone with whatever was typed in it, dropping the source machine's branch and worktree
    /// (`setDraftThreadContext` with a new project, composerDraftStore.ts:2637-2651). False when no such draft is open.
    func moveOpenDraft(from source: ProjectId, to project: ProjectShell) -> Bool {
        guard case .draft(var session) = target, session.projectId == source.rawValue, pendingMessageId == nil else { return false }
        flushPrompt()
        let key = sessions.first { $0.value.draftId == session.draftId }?.key ?? group(of: source)?.key ?? source.rawValue
        loadBalanceTask?.cancel(); loadBalanceTask = nil
        Self.retarget(&session, to: project)
        session.environmentSelection = "manual"; session.loadBalancedEnvironmentId = nil
        session.branch = nil; session.worktreePath = nil
        sessions[key] = session
        target = .draft(session)
        scheduleSave()
        refresh()
        syncSidebarDrafts()
        onTargetChange?()
        return true
    }

    /// "Auto balance" picked (`onAutoEnvironment`, ChatView.tsx:4398-4428): the draft drops its machine, branch and
    /// worktree and samples again.
    private func chooseAutomaticEnvironment() {
        guard case .draft(var session) = target, pendingMessageId == nil, let group = group(of: ProjectId(session.projectId)) else { return }
        guard currentAttachments.isEmpty else {
            toast(.warning, "Keep attachments on this machine", "Remove attachments before choosing automatic routing, then attach them on the selected machine.")
            return
        }
        loadBalanceTask?.cancel(); loadBalanceTask = nil
        loadBalanceFailed.remove(session.draftId)
        session.environmentSelection = "auto"; session.loadBalancedEnvironmentId = nil; session.branch = nil; session.worktreePath = nil
        let key = sessions.first { $0.value.draftId == session.draftId }?.key ?? group.key
        sessions[key] = session; target = .draft(session)
        sampleLoadBalance()
    }

    /// ChatView.tsx:4344-4397: samples each eligible host once and moves the draft to the best one; resolved drafts do
    /// no idle work.
    private func sampleLoadBalance() {
        guard case .draft(let session) = target, pendingMessageId == nil, loadBalanceTask == nil, session.loadBalancedEnvironmentId == nil,
              let group = group(of: ProjectId(session.projectId)), let selection = pickers.current.modelSelection else { return }
        let key = sessions.first { $0.value.draftId == session.draftId }?.key ?? group.key
        let weights = LoadBalancingLogic.weights(ClientSettingsStore.shared.current["loadBalancingWeights"])
        let candidates = runOnTargets(group).filter { candidate in
            guard environments.session(candidate.option.environmentId) != nil, (weights[candidate.option.environmentId] ?? 50) > 0 else { return false }
            return providers(candidate.option.environmentId).contains { p in
                p.instanceId == selection.instanceId && p.enabled && p.installed && p.status != .error
                    && p.auth?["status"]?.stringValue != "unauthenticated" && p.availability != "unavailable"
            }
        }
        let draftID = session.draftId
        loadBalanceTask = Task { [weak self] in
            guard let self else { return }
            var snapshots: [ProviderLoadBalanceLogic.Candidate] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let env = candidate.option.environmentId
                if let value = try? await self.environments.request(env, "server.getHostResources", .object([:])) {
                    snapshots.append(.init(id: env, resources: value, receivedAt: Date().timeIntervalSince1970 * 1000, weight: Double(weights[env] ?? 50)))
                }
            }
            guard !Task.isCancelled else { return }
            self.loadBalanceTask = nil
            guard case .draft(var current) = self.target, current.draftId == draftID, current.environmentSelection != "manual" else { return }
            if let chosen = ProviderLoadBalanceLogic.choose(snapshots, now: Date().timeIntervalSince1970 * 1000),
               let project = candidates.first(where: { $0.option.environmentId == chosen })?.project {
                self.flushPrompt(); Self.retarget(&current, to: project)
                current.environmentSelection = "auto"; current.loadBalancedEnvironmentId = chosen
                self.sessions[key] = current; self.target = .draft(current); self.syncSidebarDrafts(); self.onTargetChange?()
            } else {
                self.loadBalanceFailed.insert(draftID)
            }
            self.scheduleSave(); self.refresh()
        }
        scheduleSave(); refresh()
    }

    /// `onEnvironmentChange` (ChatView.tsx:4450-4517): the open draft moves to the group's member on that
    /// machine, keeping its prompt, picks, draft id and thread id. The pick is stored with the draft.
    private func changeEnvironment(_ environmentId: String) {
        guard case .draft(var session) = target, pendingMessageId == nil,
              let group = group(of: ProjectId(session.projectId)),
              let project = runOnTargets(group).first(where: { $0.option.environmentId == environmentId })?.project,
              (project.id.rawValue != session.projectId || session.environmentSelection == "auto") else { return }
        flushPrompt()
        let key = sessions.first { $0.value.draftId == session.draftId }?.key ?? group.key
        loadBalanceTask?.cancel(); loadBalanceTask = nil
        session.environmentSelection = "manual"; session.loadBalancedEnvironmentId = nil
        Self.retarget(&session, to: project)
        sessions[key] = session
        target = .draft(session)
        scheduleSave()
        refresh()
        syncSidebarDrafts()
        onTargetChange?()
    }

    /// The hero's project menu (DraftHeroHeadline.tsx:236-310): one radio row per project group, the open
    /// one first and checked, each with the machine badge while projects span environments. Picking a group
    /// opens its draft on the member in the current draft's environment, else its representative
    /// (`buildSidebarProjectPickerEntries`, sidebarProjectGrouping.ts:136-176).
    // ponytail: no "No project" or "Add project" rows; add them with scratch threads and Add Project
    private func pickProject(from anchor: NSView) {
        guard let snapshot = sidebar?.snapshot, case .draft(let current) = target else { return }
        if ThemeRuntime.isDither(dark: anchor.effectiveAppearance.isDark) { return pickProjectDither(from: anchor, snapshot: snapshot, current: current) }
        let envs = sidebarEnvironments
        let currentId = ProjectId(current.projectId)
        var groups = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: envs.primaryId)
        if let i = groups.firstIndex(where: { $0.memberProjectIds.contains(currentId) }), i > 0 {
            groups.insert(groups.remove(at: i), at: 0)
        }
        let active = groups.first { $0.memberProjectIds.contains(currentId) }
        // `onValueChange` (DraftHeroHeadline.tsx:282-295 in 2994): "Add project" opens the add flow, the current
        // project does nothing, another opens its draft.
        DraftHeroView.showProjectPicker(groups: groups, selectedKey: active?.key, environments: envs, from: anchor) { [weak self] key in
            guard let self else { return }
            guard let key else { self.onAddProject?(); return }
            guard key != active?.key, let group = groups.first(where: { $0.key == key }) else { return }
            self.openPickedGroup(group, key: key, currentEnvironment: currentId.environmentId)
        }
    }

    /// Dither's project popover (Capy's): the projects without the scratch one, "No project" (the scratch draft,
    /// `startScratchThread`), "New project" (Add project) and "Manage projects" (Settings, Projects).
    private func pickProjectDither(from anchor: NSView, snapshot: ShellSnapshot, current: DraftSession) {
        let envs = sidebarEnvironments
        let currentId = ProjectId(current.projectId)
        let groups = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: envs.primaryId)
            .filter { !isScratch($0.representative) }
        let scratch = snapshot.projects.first { $0.id == currentId }.map(isScratch) ?? false
        let scratchEnv = scratchEnvironment?()
        let active = groups.first { $0.memberProjectIds.contains(currentId) }
        DitherProjectPopoverView.show(groups: groups, selectedKey: active?.key, noProjectMachine: scratchEnv.map { envs.labels[$0] ?? "This device" },
                                      isScratch: scratch, from: anchor) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .project(let key):
                guard key != active?.key || scratch, let group = groups.first(where: { $0.key == key }) else { return }
                self.openPickedGroup(group, key: key, currentEnvironment: currentId.environmentId)
            case .noProject:
                if !scratch, let scratchEnv { self.onStartWithoutProject?(scratchEnv) }
            case .newProject: self.onAddProject?()
            case .manageProjects: self.onManageProjects?()
            }
        }
    }

    /// `selectProject` (DraftHeroHeadline.tsx:211-247 in 2994, 38571328a): an empty draft opens the project's own
    /// draft; one with content moves there and keeps its prompt.
    private func openPickedGroup(_ group: SidebarModel.ProjectGroup, key: String, currentEnvironment: String?) {
        let project = group.members.first { $0.id.environmentId == currentEnvironment } ?? group.representative
        guard case .draft(let open) = target, hasUserContent(open, prompt: composer.text) else { return showDraft(project) }
        let r = DraftProjectMove.move(open, to: project.id, key: key, in: sessions) {
            self.hasUserContent($0, prompt: self.prompts[$0.draftId] ?? "")
        }
        sessions = r.sessions
        showDraft(project, stored: r.moved)
    }

    private func hasUserContent(_ session: DraftSession, prompt: String) -> Bool {
        DraftProjectMove.hasUserContent(prompt: prompt, attachmentCount: draftAttachments[session.draftId]?.count ?? 0)
    }

    // MARK: Prompts

    private func loadPrompt() {
        attachmentsTargetChanged()
        composer.resetPromptHistory()
        composer.text = draftKey.flatMap { prompts[$0] } ?? ""
        pickers.prompt = composer.text
        refresh()
        DispatchQueue.main.async { [weak self] in self?.composer.focus() }
    }

    private func remember(_ text: String) {
        // An open question: the editor is its custom answer, not the prompt.
        if questionRequestId != nil {
            if let question = panel.lazyQuestionPanel.loaded, text != question.customAnswer { question.setCustomAnswer(text) }
            return
        }
        pickers.prompt = text
        // An open queued edit keeps its text out of the thread's prompt.
        guard queuedEdit == nil, let key = draftKey else { return }
        let attachments = currentAttachments
        pruneUnreferencedFiles(text, key: key)
        if panel.stashMenuOpen { setStashMenu(false) }
        prompts[key] = text.isEmpty ? nil : text
        scheduleSave()
        // Removing a file chip changes attachment-dependent send and plan state. Ordinary
        // typing only changes prompt links, menus and the branch notice.
        if attachments != currentAttachments { refresh() } else { refreshes.promptChanged() }
    }

    /// A thread's saved draft, for a composer outside the thread panel (the Orchestrator's chat). It is the same
    /// per-thread draft the thread's own composer keeps, saved to `composer.prompts.v1`.
    func draftText(_ id: ThreadId) -> String { prompts[id.rawValue] ?? "" }

    /// Saves a thread's draft from a composer outside the thread panel, debounced like typing here.
    func setDraftText(_ text: String, for id: ThreadId) {
        let key = id.rawValue
        guard (prompts[key] ?? "") != text else { return }
        prompts[key] = text.isEmpty ? nil : text
        // The panel's composer, if it still shows this thread, follows, so it never writes back an older text.
        if draftKey == key, queuedEdit == nil, questionRequestId == nil, composer.text != text {
            composer.text = text
            pickers.prompt = text
        }
        scheduleSave()
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
        let referenced = Set(prompts.values.flatMap { ComposerContext.referencedIds($0) })
        let reviews = menuState.records.filter { referenced.contains($0.key) && $0.value["kind"]?.stringValue == "review-comment" }
        UserDefaults.standard.set(try? JSONEncoder().encode(reviews), forKey: "composer.reviewComments.v1")
        syncSidebarDrafts()
    }

    // MARK: Agent session

    /// `stopThreadSession` for the open thread: one `provider-session.detach` per provider session in its projection.
    func stopSessions(_ thread: ThreadShell) async throws {
        guard target == .thread(thread.id) else { return }
        let sessions = projection?.providerSessions.compactMap { $0["id"]?.stringValue } ?? []
        for payload in ThreadCommands.detachSessions(thread.id.localId, sessionIds: sessions) {
            try await environments.dispatch(thread.id, payload)
        }
    }

    /// "Restart agent session" on the open thread (CommandPalette.tsx:1999-2033): detach every provider
    /// session when the thread has a runtime, toast, then `server.refreshProviders {instanceId, cwd, fresh}`.
    func restartAgentSession(_ thread: ThreadShell, cwd: String?) async throws {
        let id = thread.id
        let runtime = SidebarModel.shellRuntime(thread)
        if runtime != nil { try await stopSessions(thread) }
        panel.toasts.show(ToastView(title: "Agent session will restart", message: "Your next message starts a fresh session.", kind: .success))
        guard let env = id.environmentId, let cwd else { return }
        let instance = runtime != nil ? thread.providerInstanceId.rawValue : thread.modelSelection.instanceId.rawValue
        let reply = try await environments.request(env, "server.refreshProviders",
                                                   .object(["instanceId": .string(instance), "cwd": .string(cwd), "fresh": .bool(true)]))
        if let providers = try? reply["providers"]?.decode(as: [ServerProvider].self) {
            var config = serverConfigs[env] ?? ServerProviderConfig(providers: [])
            config.providers = providers
            serverConfigs[env] = config
        }
    }

    // MARK: Stream

    /// Every thread store update for the open thread.
    /// A streaming update that only grew an answer's or reasoning text: keeps the projection
    /// current and refreshes an open find, without the pickers, queue and request passes.
    func projectionTextChanged(_ projection: ThreadProjection?, threadId: ThreadId) {
        guard target == .thread(threadId) else { return }
        self.projection = projection
        if panel.findOpen, !panel.findBar.input.text.isEmpty {
            threadFindRefreshPending = true
            scheduleThreadFindRefresh()
        }
    }

    func projectionChanged(_ projection: ThreadProjection?, threadId: ThreadId) {
        guard target == .thread(threadId) else { return }
        self.projection = projection
        if panel.findOpen, !panel.findBar.input.text.isEmpty {
            threadFindRefreshPending = true
            scheduleThreadFindRefresh()
        }
        requests = projection.map(PendingRequests.derive) ?? PendingRequests()
        // A pending approval or question settles the local send (ChatView.logic.ts:1236-1238).
        if !requests.isEmpty { pendingMessageId = nil }
        // Only while something waits for confirmation: a long thread has thousands of messages.
        if !optimistic.isEmpty || pendingMessageId != nil {
            let confirmed = TimelineEntries.acknowledgedUserMessageIds(projection)
            optimistic.removeAll { confirmed.contains($0.id) }
            if let id = pendingMessageId, confirmed.contains(id) { pendingMessageId = nil }
        }
        // Resume is done once a run is active again.
        if resuming, let projection, ComposerLogic.RunState(runs: projection.runs).canInterrupt { resuming = false }
        // The edited message left the queue (it started, or another client removed it): the
        // unsaved text moves to an empty prompt, else it is dropped (queuedMessageEdit.ts:10-24).
        if let edit = queuedEdit, let projection, !projection.runs.contains(where: { $0.id == edit.runId && $0.status == .queued }) {
            let unsaved = composer.text
            queuedEdit = nil
            composer.editingQueued = false
            composer.resetPromptHistory()
            let saved = draftKey.flatMap { prompts[$0] } ?? ""
            let recovery = ComposerFeedback.recoverQueuedEdit(edited: unsaved, original: edit.originalText, threadPrompt: saved)
            composer.text = recovery == .kept ? unsaved : saved
            remember(composer.text)
            if recovery != .clean { report(.queuedEditLeft(kept: recovery == .kept), key: nil) }
        }
        refresh()
    }

    private func refresh() { refreshes.refresh() }

    private func refreshPromptState() {
        panel.lazyDiffPanel.set(\.reviewComments, contextRecords(for: composer.text).values.filter { $0["kind"]?.stringValue == "review-comment" }.sorted { ($0["contextId"]?.stringValue ?? "") < ($1["contextId"]?.stringValue ?? "") })
        if panel.menus.isOpen { panel.menus.reload() }
        let content = hasUserContent
        if refreshedHasUserContent != content {
            refreshedHasUserContent = content
            onRefresh?()
        }
    }

    private func refreshThreadState() {
        panel.model.commandOutputEnabled = targetEnvironmentId.flatMap { serverConfigs[$0] }?.capabilities.contains("commandOutputStreaming") == true
        panel.model.inlineSkills = menuProvider?.skills(cwd: menuCwd) ?? []
        if threadFindTarget != openThreadId { closeThreadFind() }

        syncWorktreeSetup()
        panel.tasksView.steps = ThreadTaskStep.derive(projection)
        contextWindow = ThreadContextWindowUsage.derive(projection)
        composer.contextWindowMeter.projection = projection
        composer.contextWindowMeter.usage = meterEnabled ? contextWindow : nil
        composer.needsLayout = true
        let runs = projection?.runs ?? []
        var runState = ComposerLogic.RunState(runs: runs)
        if let thread = shellThread, thread.status == .failed, thread.lastErrorClass == .usageLimit {
            runState.resumableRunId = thread.latestRunId
        }
        composer.isCompacting = projection.map {
            let state = TimelineRunState(projection: $0)
            return state.isWorking && TimelineRunState.compactRequestActive($0, latestRun: state.latestRun)
        } ?? false
        composer.runState = runState
        composer.isDraftRoute = panel.isDraft
        // A rewind is no busy spinner in T3: the arrow stays, disabled with "Rewinding conversation".
        composer.isBusy = pendingMessageId != nil || resuming || draftKey.map { fanoutInFlight.contains($0) } == true
        updatePickers()
        var placeholder = ComposerLogic.PlaceholderInput()
        placeholder.noProvider = pickers.controlsView.unavailableTitle != nil
        // T3's `phase === "disconnected"` means the thread has no runtime (`derivePhase(activeRuntime)`,
        // session-logic.ts:1069-1078), not a lost connection: drafts and unstarted threads get it.
        // ponytail: ignores the PR-watch background work that also creates a runtime; add it with PR watches
        placeholder.disconnected = !ComposerLogic.QueueState.hasStartedSession(projection)
        placeholder.approvalPending = requests.activeApproval != nil
        // A send declines the shown approvals, so it steers the waiting turn instead of queueing behind it
        // (`followUpBehavior`, ChatComposer.tsx:2286-2292).
        composer.steerByDefault = followUpSteers || !requests.approvals.isEmpty
        composer.placeholderInput = placeholder
        updateRequests()
        syncSendBlock()
        syncAttachmentViews()
        composer.editingQueued = queuedEdit != nil
        panel.model.optimisticMessages = optimistic
        panel.queue.state = target == nil || panel.isDraft ? ComposerLogic.QueueState()
            : ComposerLogic.QueueState(projection: projection, optimistic: optimistic)
        panel.queue.editingRunId = queuedEdit?.runId
        panel.queue.isBusy = queueBusy
        let plan = ThreadPlanFollowUp.activePlan(projection)
        let showPlan = pickers.current.interactionMode == .plan && plan != nil && requests.isEmpty && currentAttachments.isEmpty && !composer.isBusy
        composer.planFollowUp = showPlan
        updateCompaction(showPlan: showPlan)
        panel.showsPlanFollowUp = showPlan
        if let markdown = plan?.markdown, showPlan {
            let title = markdown.components(separatedBy: .newlines).first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
            panel.planFollowUpBanner.apply(.init(variant: .neutral, icon: .listTodo, title: "Plan ready", description: title))
        }
        updateThreadBanners()
        updateRunOn()
        refreshWorkspaceSnapshot()
        let banner = draftKey.flatMap { threadErrors.visible($0, shell: shellThread) }
        if banner != panel.errorBanner.banner {
            panel.errorBanner.banner = banner
            panel.needsLayout = true
        }
        // The provider status banner (ChatView.tsx:4206-4221): the composer's provider instance; a
        // dismissal holds until the status key changes, and a cleared key forgets it.
        let provider = targetEnvironmentId.flatMap { config($0) }?.providers.first { $0.instanceId == pickers.current.instanceId }
        let providerKey = ProviderStatusBannerLogic.key(provider)
        if providerKey == nil { dismissedProviderBannerKey = nil }
        let providerBanner = ProviderStatusBannerLogic.banner(provider, dismissedKey: dismissedProviderBannerKey)
        if providerBanner != panel.providerBanner.banner {
            panel.providerBanner.banner = providerBanner
            panel.providerBanner.onDismiss = { [weak self] in
                self?.dismissedProviderBannerKey = providerKey
                self?.refresh()
            }
            panel.providerBanner.setup.action = { [weak self] in self?.openProviderSetup?() }
            panel.needsLayout = true
        }
        panel.updateComposerShown()
        refreshedHasUserContent = hasUserContent
        onRefresh?()
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
            panel.approvalPanel.configure(approval, pendingCount: requests.approvals.count, threadId: threadId.localId)
            panel.approvalPanel.isResponding = responding.contains(approval.requestId)
            panel.drawer = .approval
            composer.pending = .approval
        } else if let input = requests.activeUserInput {
            let question = panel.questionPanel
            question.markdownCwd = menuCwd
            question.configure(input, threadId: threadId.localId)
            question.isResponding = responding.contains(input.requestId)
            if questionRequestId == nil {
                // The editor becomes the answer field; an open queued edit closes first.
                if queuedEdit != nil { endEdit() }
                onEditorTaken?()
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
        composer.fileRows = []
        pruneQuestionFiles()
        composer.text = draftKey.flatMap { prompts[$0] } ?? ""
        pickers.prompt = composer.text
    }

    /// The question card changed (pick, typing, next, previous): the editor, placeholder and
    /// footer follow its active question.
    private func syncQuestion() {
        guard questionRequestId != nil, panel.lazyQuestionPanel.loaded?.session != nil else { return }
        // Files first: their state feeds the session that the footer reads below.
        syncQuestionFiles()
        guard let session = panel.lazyQuestionPanel.loaded?.session else { return }
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
            showsAttach: question.editorEnabled && supportsQuestionAttachments && fileUploadLimit != nil))
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
    /// `done` gets whether the server accepted the answer.
    private func respond(_ payload: JSONValue, failure: @escaping (String?) -> ComposerFeedback.Failure,
                         done: (@MainActor (Bool) -> Void)? = nil) {
        guard let shell, case .string(let requestId)? = payload["requestId"], !responding.contains(requestId) else { done?(false); return }
        let key = draftKey
        responding.insert(requestId)
        refresh()
        let supervisor = shell.supervisor
        Task { [weak self] in
            var accepted = false
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload); accepted = true } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport {} else {
                    self?.report(failure(Self.message(error)), key: key)
                }
            }
            self?.responding.remove(requestId)
            self?.refresh()
            done?(accepted)
        }
    }

    /// `declinePendingApprovals` (threadRequests.ts:18-29): declines every approval a redirect replaces, in turn.
    /// One the provider can no longer answer is skipped; one that is gone or refused stops it.
    private func declineApprovals(_ approvals: [PendingApproval], threadId: ThreadId) async -> Bool {
        for approval in approvals where approval.canRespond {
            // `onRespondToApproval` answers only a live request still pending (usePendingThreadRequests.ts:304-310):
            // the agent may have resolved it while the send got here.
            guard requests.approvals.contains(where: { $0.requestId == approval.requestId && $0.canRespond }) else { return false }
            let payload = RuntimeRequestCommands.respond(threadId: threadId.localId, requestId: approval.requestId, decision: .decline)
            let accepted = await withCheckedContinuation { continuation in
                respond(payload, failure: ComposerFeedback.Failure.approval) { continuation.resume(returning: $0) }
            }
            if !accepted { return false }
        }
        return true
    }

    /// The pickers follow the draft key, the server config and the open thread.
    private func updatePickers() {
        dropUsageLimitsIfStale(instance: pickers.current.instanceId?.rawValue)
        let snapshot = sidebar?.snapshot
        let thread = shellThread
        let projectId: ProjectId? = switch target {
        case .draft(let s): ProjectId(s.projectId)
        case .thread: thread?.projectId
        case nil: nil
        }
        let project = snapshot?.projects.first { $0.id == projectId }
        let context = ComposerSelectionContext(
            catalog: ProviderCatalog(serverConfig.providers, settings: ServerSettingsValues(serverConfig.settings.raw), projectId: projectId?.localId.rawValue),
            thread: thread, projectDefaultModel: project?.defaultModelSelection,
            serverDefaults: serverConfig.settings,
            hasStartedSession: ComposerLogic.QueueState.hasStartedSession(projection),
            supportsProviderHandoff: thread == nil || ComposerLogic.QueueState.supportsProviderHandoff(projection),
            planModeEnabled: ClientSettingsStore.shared.current.bool("planModeEnabled"))
        // Shift-click fan-out: a new thread on a server that bootstraps worktrees (ChatView.tsx:11584-11587).
        if case .draft = target { pickers.supportsMultipleModels = serverConfig.capabilities.contains("requiredWorktreeBootstrap") } else { pickers.supportsMultipleModels = false }
        pickers.update(draftKey: draftKey ?? "", context: context)
        panel.model.providers = serverConfig.providers
        onModelChange?()
        // No enabled provider (ChatComposer.tsx:2140-2153): sending stays blocked, and once the catalog
        // is known one button replaces the cluster (:5473-5487). It opens setup for the requested
        // instance, else (on an unstarted thread) for the first instance that can install or sign in.
        noProviderAvailable = target != nil && pickers.current.entry == nil && pickers.currentMultiple == nil
        let catalogKnown = targetEnvironmentId.map { serverConfigs[$0] != nil } == true
        let requested = [draftKey.flatMap { pickers.store.drafts[$0]?.activeInstance }, thread?.providerInstanceId,
                         thread?.modelSelection.instanceId, project?.defaultModelSelection?.instanceId].compactMap { $0 }.first
        let canSetUp = requested != nil || (!context.hasStartedSession && serverConfig.providers.contains(where: ProviderStatusBannerLogic.hasSetup))
        let controls = pickers.controlsView
        controls.unavailableTitle = noProviderAvailable && catalogKnown ? (canSetUp ? "Open provider settings" : "No provider available") : nil
        controls.unavailable.isEnabled = canSetUp
        if controls.unavailable.action == nil { controls.unavailable.action = { [weak self] in self?.openProviderSetup?() } }
        var placeholder = composer.placeholderInput
        placeholder.noProvider = controls.unavailableTitle != nil
        composer.placeholderInput = placeholder
        // A new label (config arrived, thread switched) changes the controls' width.
        composer.needsLayout = true
    }

    /// `noProviderAvailable`, the catalog still loading included: the send button is blocked.
    private var noProviderAvailable = false

    // MARK: Commands

    private var shellThread: ThreadShell? {
        guard case .thread(let id) = target else { return nil }
        return sidebar?.snapshot?.threads.first { $0.id == id }
    }

    /// `background`: a draft starts in the background behind a fresh draft (`beginBackgroundDraftSubmission`,
    /// ChatView.tsx:9905-10032); a thread sends and then opens a new thread in its project.
    /// `redirecting`: the pending approvals were just declined for this send, which now goes.
    private func send(_ text: String, mode: ComposerLogic.SendMode, background: Bool = false, redirecting: Bool = false, compactConfirmed: Bool = false) {
        guard !threadRewindBusy, !declineInFlight else { return }
        let sentText = text
        // A send now would leave a still-compressing pasted image behind (ChatComposer.tsx:4222-4237).
        if let key = draftKey, (preparingImages[key] ?? 0) > 0 {
            toast(.info, "Still compressing a pasted image.", "Send again once its thumbnail appears.")
            return
        }
        if case .draft(let draft) = target, draft.envMode == nil, let task = settingsWorkspaceTask {
            guard !settingsWorkspaceSendPending else { return }
            settingsWorkspaceSendPending = true
            Task { [weak self] in
                await task.value
                guard let self else { return }
                self.settingsWorkspaceSendPending = false
                guard case .draft(let current) = self.target, current.draftId == draft.draftId, current.projectId == draft.projectId else { return }
                self.send(text, mode: mode, background: background)
            }
            return
        }
        // `needsLoadBalancing` (ChatView.tsx:8785-8796).
        if case .draft(let draft) = target, draft.loadBalancedEnvironmentId == nil,
           let group = group(of: ProjectId(draft.projectId)), isAutomatic(draft, machines: runOnTargets(group).count) {
            if loadBalanceTask != nil {
                toast(.warning, "Checking machine resources", "Resource checks are still running. You can choose a machine in the composer.")
            } else {
                // ChatView.tsx:4686-4695: attached threads no single machine can read.
                let threads = ComposerContext.referencedIds(text).compactMap { menuState.records[$0] }
                    .filter { $0["kind"]?.stringValue == "thread" }.compactMap { $0["environmentId"]?.stringValue }
                let readable = runOnTargets(group).contains { t in threads.allSatisfy { $0 == t.option.environmentId } }
                toast(.warning, "Choose a machine to continue", !threads.isEmpty && !readable
                      ? "No machine can read every attached thread. Choose a machine in the composer or remove the threads."
                      : "No eligible machine has available resources. Choose a machine in the composer to override.")
            }
            return
        }
        // `activeEnvironmentUnavailable` (ChatView.tsx:8797-8811).
        if !connected, target != nil, pendingMessageId == nil {
            toastEnvironmentUnavailable()
            return
        }
        // ChatView.tsx:4780-4796 (c1377176b1): this machine's agent can't read a thread from another one.
        if let env = targetEnvironmentId,
           let stranded = ComposerContext.threadsOutsideEnvironment(text, records: menuState.records, environmentId: env).first {
            let owner = stranded["environmentId"]?.stringValue.flatMap { sidebarEnvironments.labels[$0] } ?? "its machine"
            let title = stranded["title"]?.stringValue ?? ""
            toast(.warning, "Attached thread is on another machine",
                  "This machine's agent can't read \"\(title)\". Remove it, or switch back to \(owner) to send.")
            return
        }
        var text = text
        var implementationPlan: PlanArtifact?
        var planFollowUp = false
        if composer.planFollowUp, let plan = ThreadPlanFollowUp.activePlan(projection), let markdown = plan.markdown, let key = draftKey {
            planFollowUp = true
            let next = ThreadPlanFollowUp.submission(draft: text, markdown: markdown)
            text = next.text
            if next.mode == .default { implementationPlan = plan }
            pickers.store.setInteractionMode(key, next.mode)
            updatePickers()
        }
        guard let shell, pendingMessageId == nil, let target else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let edit = queuedEdit { if !trimmed.isEmpty { saveEdit(edit, text: trimmed) }; return }
        let attachments = currentAttachments
        // Typed in full, `/usage-limits` is answered here from the Limits snapshot; the agent never sees it.
        if attachments.isEmpty, usageLimitsOffered, UsageLimitsLogic.isUsageLimitsCommand(trimmed) {
            if openUsageLimits() { composer.text = ""; remember("") }
            return
        }
        // The panel closes when the next message goes.
        if !trimmed.isEmpty || !attachments.isEmpty { panel.usageLimitsBanner = nil }
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // Send retries failed uploads and goes once they finish (ChatView.tsx:6438-6446, 073734c1e9).
        let failed = ComposerAttachmentRules.retryableFailures(attachments)
        if let key = draftKey, !failed.isEmpty {
            sendAfterRetry[key] = (text, mode, background)
            // `retryAttachmentUpload` (attachmentUploadQueue.ts:556-572) deletes the failed server copy first.
            for a in failed { retryAttachment(a.id) }
            return
        }
        // Every upload must be done (`attachmentUploadBlockReason`), within the turn's limits.
        guard ComposerAttachmentRules.uploadBlockReason(attachments) == nil else { return }
        if let limit = ComposerAttachmentRules.providerLimitError(attachments.map { ($0.kind == .image, $0.sizeBytes) }) {
            if let key = draftKey { threadErrors.set(key, limit) }
            refresh()
            return
        }
        let uploaded = attachments.compactMap(\.chatAttachment)
        // A message with only attachments carries T3's bootstrap text (ChatView.tsx:9282).
        let messageText = trimmed.isEmpty ? ComposerAttachmentRules.attachmentOnlyPrompt : trimmed
        let messageId = MessageId(UUID().uuidString.lowercased())
        let commandId = UUID().uuidString.lowercased()
        let now = T3Timestamp(Date())
        let picks = pickers.current
        let picksKey = draftKey
        guard let selection = picks.modelSelection else {
            report(.noModel, key: picksKey)
            return
        }
        if case .draft(let session) = target {
            guard !fanoutInFlight.contains(session.draftId) else { return }
            // A failed fan-out can leave one model selected and enter the single-send path.
            let retryKey = fanoutRetryKey(session.draftId, selection)
            if let thread = uncertainFanout[retryKey] {
                showFanoutRetry(retryKey, thread: thread, model: selection.model)
                return
            }
        }
        // Models picked on a server that bootstraps worktrees, sent where it can't (ChatView.tsx:8826-8832).
        if case .draft = target, let picksKey, pickers.multipleSelections[picksKey] != nil, !pickers.supportsMultipleModels {
            threadErrors.set(picksKey, "Update this server before starting multiple models.")
            refresh()
            return
        }
        // `/feedback` to Codex needs a started provider thread (ChatView.tsx:9043-9062).
        // ponytail: only the guard; on a started thread the command goes out as a message where T3 uploads feedback
        // (`submitCodexFeedback`). Port the upload if Codex users ask for it
        if pickers.current.entry?.driver == "codex", attachments.isEmpty, ComposerContext.referencedIds(trimmed).isEmpty,
           pickers.currentMultiple == nil, ComposerLogic.isCodexFeedbackCommand(trimmed),
           shellThread?.activeProviderThreadId == nil {
            toast(.warning, "Start a Codex thread first", "Send a message before you submit feedback.")
            return
        }
        // The draft's project was removed (ChatView.tsx:9205-9214).
        let sendProjectId: ProjectId? = switch target {
        case .draft(let d): ProjectId(d.projectId)
        case .thread: shellThread?.projectId
        }
        if let sendProjectId, let projects = sidebar?.snapshot?.projects, !projects.contains(where: { $0.id == sendProjectId }) {
            toast(.warning, "Choose a project first", "This draft no longer points to an available project.")
            return
        }
        // In worktree mode a base branch is required (ChatView.tsx:9223-9230).
        if case .draft(let d) = target, d.envMode == .worktree, d.worktreePath == nil, d.branch == nil, draftIsGitRepo {
            if let picksKey { threadErrors.set(picksKey, "Select a base branch before sending in New worktree mode.") }
            refresh()
            return
        }
        // Several models picked: one thread and worktree each, the draft stays (ChatView.tsx:8824-8845, 9464-9680).
        if case .draft(let session) = target, let multiple = pickers.currentMultiple {
            sendFanout(multiple, session: session, text: text, messageText: messageText, trimmed: trimmed, attachments: attachments,
                       uploaded: uploaded, picks: picks, supervisor: shell.supervisor)
            return
        }
        // A message sent while approvals are pending redirects the agent. They are declined only here, after
        // everything above accepted the send, and the send goes once they are (ChatView.tsx:5181-5263, a93b03c8a5).
        if case .thread(let threadId) = target, !redirecting, !requests.approvals.isEmpty {
            let approvals = requests.approvals
            let promptAtSend = composer.text, attachmentIds = attachments.map(\.id), key = draftKey
            // A draft edited since send, or a paste still landing in it, is no longer the message the user sent.
            let changed = { [weak self] () -> Bool in
                guard let self else { return true }
                if let key, (self.preparingImages[key] ?? 0) > 0 { return true }
                let now = self.currentAttachments
                return ComposerAttachmentRules.uploadBlockReason(now) != nil || self.composer.text != promptAtSend || now.map(\.id) != attachmentIds
            }
            let changedBefore = changed()
            let answering = approvals.contains { responding.contains($0.requestId) }
            let before = Set(requests.approvals.map(\.requestId))
            declineInFlight = true
            Task { [weak self] in
                guard let self else { return }
                let declined = !changedBefore && !answering ? await self.declineApprovals(approvals, threadId: threadId) : false
                self.declineInFlight = false
                let outcome = ComposerLogic.approvalRedirect(
                    declined: declined, draftChanged: changedBefore || changed(), approvalResponding: answering,
                    // An approval that arrived during the decline would block the redirect; the draft stays for the next send.
                    approvalArrived: self.requests.approvals.contains { !before.contains($0.requestId) },
                    threadChanged: self.target != .thread(threadId))
                if let title = outcome.toast { self.toast(.info, title, "Send again when it's ready.") }
                if outcome.sends { self.send(sentText, mode: mode, background: background, redirecting: true) }
            }
            return
        }
        // The send goes ahead: the thread's local error clears (ChatView.tsx:9782).
        if let picksKey { threadErrors.set(picksKey, nil) }
        // A stale Claude session compacts first and the message queues behind the `/compact` run, since
        // steering into it is rejected (`compactBeforeSend`, ChatView.tsx:9267-9276).
        var compactFirst = false
        if case .thread = target {
            compactFirst = ComposerCompaction.compactsBeforeSend(resumeTokens: composer.compactBeforeSendTokens,
                                                                 keepFullHistory: composer.keepFullHistory, text: trimmed)
        }
        // A compaction below 500k asks first; above it, it just goes (the user's call, a difference from T3).
        if compactFirst, !compactConfirmed, ComposerCompaction.confirmsCompaction(tokens: composer.compactBeforeSendTokens),
           let window = composer.window {
            let alert = NSAlert()
            alert.messageText = "Compact before sending?"
            alert.informativeText = "This thread uses \(composer.compactBeforeSendTokens.map(ThreadContextWindowUsage.tokens) ?? "") tokens. Compacting summarizes the history first."
            alert.addButton(withTitle: "Compact and send")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                MainActor.assumeIsolated { self?.send(sentText, mode: mode, background: background, redirecting: redirecting, compactConfirmed: true) }
            }
            return
        }
        let mode: ComposerLogic.SendMode = compactFirst ? .queue : mode
        // Optimistic echo, then clear the composer before the command returns (ChatView.tsx:9763-9793).
        let intent: InputIntent? = mode == .queue ? .queuedTurn : mode == .steer ? .steer : nil
        // Every attachment rides as a record bound to its upload (`buildMessageContext`).
        let referenced = contextRecords(for: trimmed)
        let records = ComposerContext.referencedIds(trimmed).compactMap { referenced[$0] } + attachments.compactMap(\.contextRecord)
        let context: JSONValue? = records.isEmpty ? nil : .object(["version": .number(1), "records": .array(records)])
        optimistic.append(ChatMessage(id: messageId, role: .user, text: messageText, createdAt: now, inputIntent: intent,
                                      context: context, attachments: uploaded))
        pendingMessageId = messageId
        for a in attachments { if let id = a.attachmentId { sentFiles[id] = a.fileURL } }
        // The draft's attachments leave with the message; the server claims their uploads.
        if let key = draftKey { draftAttachments[key] = nil }
        composer.text = ""
        remember("")
        // `deriveThreadTitleSeed` (ChatView.tsx:5538-5542); records ride as `context`.
        let title = ComposerLogic.threadTitleSeed(trimmed, attachments: attachments.map { ($0.kind == .image, $0.name) })
        let selectionJSON = ThreadSession.encode(selection)
        let supervisor = shell.supervisor

        switch target {
        case .draft(let stored):
            // First send of a draft: one launchThread; the thread exists after the reply (05-composer.jsonl).
            // The launch takes a thread id of its own and the draft leaves the store (`NewThreadDraftLaunch`).
            let (session, sessionKey) = NewThreadDraftLaunch.begin(stored, in: &sessions)
            self.target = .draft(session)
            scheduleSave()
            panel.setDraft(projectTitle: nil)
            refresh()
            let payload = ComposerLogic.launchThreadPayload(
                commandId: commandId, threadId: EnvironmentScope.localId(of: session.threadId),
                projectId: EnvironmentScope.localId(of: session.projectId), title: title,
                modelSelection: selectionJSON, runtimeMode: picks.runtimeMode.rawValue,
                interactionMode: picks.interactionMode.rawValue, messageId: messageId.rawValue, text: messageText, context: context,
                attachments: uploaded,
                workspaceStrategy: BranchToolbarLogic.workspaceStrategy(
                    mode: draftIsGitRepo ? session.envMode ?? .local : .local, branch: session.branch,
                    worktreePath: session.worktreePath, startFromOrigin: session.startFromOrigin ?? false))
            // Started in the background: a fresh draft in the same project, with the same workspace
            // picks (`resolveBackgroundDraftWorkspaceOptions`), replaces the composer at once.
            if background, let project = sidebar?.snapshot?.projects.first(where: { $0.id.rawValue == session.projectId }) {
                var workspace = session
                workspace.worktreePath = nil
                workspace.startFromOrigin = session.envMode == .worktree && session.startFromOrigin == true
                showDraft(project, workspace: workspace)
            }
            Task { [weak self] in
                do {
                    _ = try await supervisor.request("orchestration.launchThread", payload: payload)
                    guard let self else { return }
                    sentSnapShots(attachments)
                    pickers.store.didSend(session.draftId)
                    prompts[session.draftId] = nil
                    scheduleSave()
                    if background {
                        let id = ThreadId(session.threadId)
                        panel.toasts.show(ToastView(title: "Started in background", kind: .success, actionTitle: "Open",
                                                    action: { [weak self] in self?.openThread?(id) }), timeout: 5)
                    } else {
                        openThread?(ThreadId(session.threadId))
                    }
                } catch {
                    guard let self else { return }
                    // A fresh draft took the composer (`backgroundDraftOpened`), so the failed one comes back on its own.
                    if background, self.target != .draft(session) {
                        backgroundSendFailed(error, session: session, key: sessionKey, text: text, attachments: attachments)
                        return
                    }
                    // The draft comes back with another thread id: the server may have created this one.
                    let restored = NewThreadDraftLaunch.restore(session, key: sessionKey, in: &sessions)
                    if let restored, self.target == .draft(session) { self.target = .draft(restored) }
                    scheduleSave()
                    restoreAttachments(attachments, key: picksKey)
                    sendFailed(error, messageId: messageId, text: text, draft: restored ?? session, key: picksKey)
                }
            }
        case .thread(let threadId):
            let (dispatchMode, deliveryIntent) = ComposerLogic.dispatch(mode)
            var command: [String: JSONValue] = [
                "type": .string("message.dispatch"), "commandId": .string(commandId), "createdBy": .string("user"),
                "creationSource": .string("web"), "threadId": .string(threadId.localId.rawValue), "messageId": .string(messageId.rawValue),
                "text": .string(messageText), "attachments": .array(uploaded), "titleSeed": .string(title),
                "modelSelection": selectionJSON, "dispatchMode": dispatchMode,
            ]
            if let deliveryIntent { command["deliveryIntent"] = .string(deliveryIntent) }
            if let context { command["context"] = context }
            if let plan = implementationPlan {
                command["sourcePlanRef"] = .object(["threadId": .string(threadId.localId.rawValue), "planId": .string(plan.id.rawValue)])
            }
            let runtimeChange = picks.runtimeModeToPersist, interactionChange = picks.interactionModeToPersist
            Task { [weak self] in
                do {
                    // Changed access and interaction modes are persisted before the message, each
                    // aborting the send on failure (persistThreadSettingsForNextTurn, ChatView.tsx:6267-6340).
                    if let runtimeChange {
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                            "type": .string("thread.runtime-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                            "threadId": .string(threadId.localId.rawValue), "runtimeMode": .string(runtimeChange.rawValue)]))
                    }
                    if let interactionChange {
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                            "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                            "threadId": .string(threadId.localId.rawValue), "interactionMode": .string(interactionChange.rawValue)]))
                    }
                    if compactFirst {
                        // ChatView.tsx:9859-9873: `/compact` starts its own turn with the same model and modes.
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: Self.standaloneCommand(
                            threadId: threadId, messageId: MessageId(UUID().uuidString.lowercased()), text: "/compact",
                            selection: selection, queue: false))
                    }
                    _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(command))
                    // The turn is under way: the chip's off state for this thread is spent (ChatView.tsx:9984-9986).
                    if let picksKey { self?.fullHistoryThreadKeys.remove(picksKey) }
                    self?.sentSnapShots(attachments)
                    if let picksKey { self?.pickers.store.didSend(picksKey) }
                    self?.refresh()
                    // `composer.sendAndNewThread`: the thread keeps running; a fresh composer opens
                    // in its project while the user still looks at it (ChatView.tsx:10020-10027).
                    if background, self?.target == .thread(threadId) { self?.onNewThread?() }
                } catch {
                    self?.restoreAttachments(attachments, key: picksKey)
                    self?.sendFailed(error, messageId: messageId, text: text, draft: nil, key: picksKey, planFollowUp: planFollowUp)
                }
            }
        }
    }

    private var implementInFlight = false

    /// The inspector's Roll back (`onRollbackCheckpoint`, ChatView.tsx:8543-8590): refused while a turn runs,
    /// confirmed through `requestConfirmDialog`, then `checkpoint.rollback` for that checkpoint.
    private func rollBack(checkpointId: String, scopeId: String) {
        guard case .thread(let id) = target, !threadRewindBusy, let window = panel.window, let key = draftKey else { return }
        if composer.runState.running || composer.isBusy {
            threadErrors.set(key, "Interrupt the current turn before reverting checkpoints.")
            refresh()
            return
        }
        let dialog = DialogView(kind: .alertDialog, title: "Roll back this thread to the selected checkpoint?", message: "This action cannot be undone.")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in
            host?.close()
            guard let self, self.openThreadId == id, let supervisor = self.shell?.supervisor else { return }
            self.threadRewindBusy = true
            self.threadErrors.set(key, nil)
            self.refresh()
            Task { [weak self] in
                do {
                    _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                        "type": .string("checkpoint.rollback"), "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(id.localId.rawValue), "scopeId": .string(scopeId), "checkpointId": .string(checkpointId)]))
                } catch {
                    self?.threadErrors.set(key, "\(error)")
                }
                self?.threadRewindBusy = false
                self?.refresh()
            }
        }
    }

    /// "Implement in a new thread" (`onImplementPlanInNewThread`, ChatView.tsx:10522-10668): `thread.create` in the
    /// same project, branch and worktree with the default access mode, then the plan prompt with `sourcePlanRef`
    /// pointing at the plan. A failure deletes the new thread and toasts; success opens it.
    private func implementPlanInNewThread() {
        guard !implementInFlight, pendingMessageId == nil, !composer.isBusy, case .thread(let sourceId) = target,
              let shell, let thread = shellThread, let env = sourceId.environmentId,
              let plan = ThreadPlanFollowUp.activePlan(projection), let markdown = plan.markdown else { return }
        guard let selection = pickers.current.modelSelection else { report(.noModel, key: draftKey); return }
        // `getSendContext()` (ChatView.tsx:10537-10540): no write without a provider entry (a nil
        // selection above) or with interaction mode off.
        // ponytail: T3's Antigravity send block (getAntigravitySendBlockReason) is not ported; add it with that driver
        guard pickers.context.interactionModeEnabled(menuProvider) else { return }
        implementInFlight = true
        let supervisor = shell.supervisor
        let newLocal = UUID().uuidString.lowercased()
        let title = ProposedPlanText.implementationThreadTitle(markdown)
        let runtime = pickers.context.projectDefaultRuntimeMode ?? pickers.context.serverDefaults.defaultRuntimeMode
        let selectionJSON = ThreadSession.encode(selection)
        var create: [String: JSONValue] = [
            "type": .string("thread.create"), "commandId": .string(UUID().uuidString.lowercased()), "createdBy": .string("user"),
            "creationSource": .string("web"), "threadId": .string(newLocal),
            "projectId": .string(EnvironmentScope.localId(of: thread.projectId.rawValue)), "title": .string(title),
            "modelSelection": selectionJSON, "runtimeMode": .string(runtime.rawValue), "interactionMode": .string("default"),
        ]
        create["branch"] = thread.branch.map(JSONValue.string) ?? .null
        create["worktreePath"] = thread.worktreePath.map(JSONValue.string) ?? .null
        let (dispatchMode, deliveryIntent) = ComposerLogic.dispatch(.auto)
        var message: [String: JSONValue] = [
            "type": .string("message.dispatch"), "commandId": .string(UUID().uuidString.lowercased()), "createdBy": .string("user"),
            "creationSource": .string("web"), "threadId": .string(newLocal), "messageId": .string(UUID().uuidString.lowercased()),
            "text": .string(ProposedPlanText.implementationPrompt(markdown)), "attachments": .array([]), "titleSeed": .string(title),
            "modelSelection": selectionJSON, "dispatchMode": dispatchMode,
            "sourcePlanRef": .object(["threadId": .string(sourceId.localId.rawValue), "planId": .string(plan.id.rawValue)]),
        ]
        if let deliveryIntent { message["deliveryIntent"] = .string(deliveryIntent) }
        Task { [weak self] in
            var created = false
            do {
                _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(create))
                created = true
                _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(message))
                guard let self else { return }
                self.implementInFlight = false
                self.openThread?(ThreadId(newLocal).scoped(to: env))
            } catch {
                if created {
                    _ = try? await supervisor.request("orchestration.dispatchCommand", payload: .object([
                        "type": .string("thread.delete"), "commandId": .string(UUID().uuidString.lowercased()), "threadId": .string(newLocal)]))
                }
                guard let self else { return }
                self.implementInFlight = false
                self.toast(.error, "Could not start implementation thread", "\(error)")
            }
        }
    }

    /// The multi-model send: every selection gets `orchestration.launchThread` with its own thread id
    /// and a `worktree` strategy on the draft's base branch, as `startThreadTurn` builds it from
    /// `bootstrap.prepareWorktree` (client-runtime commands.ts:626-680). The draft keeps the
    /// composer; models that failed stay picked and the text comes back.
    private func sendFanout(_ selections: [ModelSelection], session: DraftSession, text: String, messageText: String, trimmed: String,
                            attachments: [ComposerAttachment], uploaded: [JSONValue], picks: ResolvedComposerSelection,
                            supervisor: ConnectionSupervisor) {
        guard draftIsGitRepo, let branch = session.branch, !selections.isEmpty else {
            panel.toasts.show(ToastView(title: "Choose models and a base branch",
                                        message: "Multiple models need a new thread in a Git project. Each gets its own worktree.", kind: .warning))
            return
        }
        let key = session.draftId
        guard !fanoutInFlight.contains(key) else { return }
        for selection in selections {
            let retryKey = fanoutRetryKey(key, selection)
            if let thread = uncertainFanout[retryKey] {
                showFanoutRetry(retryKey, thread: thread, model: selection.model)
                return
            }
        }
        // The project's provider switches apply to the fan-out too (ChatView.tsx:3245-3249).
        let catalog = ProviderCatalog(serverConfig.providers, settings: ServerSettingsValues(serverConfig.settings.raw), projectId: ProjectId(session.projectId).localId.rawValue)
        for s in selections where catalog.entry(s.instanceId)?.isReady != true {
            threadErrors.set(key, "Provider for \(s.model) is unavailable.")
            refresh()
            return
        }
        threadErrors.set(key, nil)
        let referenced = contextRecords(for: trimmed)
        let records = ComposerContext.referencedIds(trimmed).compactMap { referenced[$0] } + attachments.compactMap(\.contextRecord)
        let context: JSONValue? = records.isEmpty ? nil : .object(["version": .number(1), "records": .array(records)])
        let title = ComposerLogic.threadTitleSeed(trimmed, attachments: attachments.map { ($0.kind == .image, $0.name) })
        let strategy = BranchToolbarLogic.workspaceStrategy(mode: .worktree, branch: branch, worktreePath: nil,
                                                            startFromOrigin: session.startFromOrigin ?? false)
        if let draftKey { draftAttachments[draftKey] = nil }
        composer.text = ""
        remember("")
        let projectId = EnvironmentScope.localId(of: session.projectId)
        fanoutInFlight.insert(key); refresh()
        Task { [weak self] in
            var failed: [ModelSelection] = []
            await withTaskGroup(of: (ModelSelection, String, Error?).self) { group in
                for s in selections {
                    let threadId = UUID().uuidString.lowercased()
                    let payload = ComposerLogic.launchThreadPayload(
                        commandId: UUID().uuidString.lowercased(), threadId: threadId, projectId: projectId, title: title,
                        modelSelection: ThreadSession.encode(s), runtimeMode: picks.runtimeMode.rawValue,
                        interactionMode: picks.interactionMode.rawValue, messageId: UUID().uuidString.lowercased(), text: messageText,
                        context: context, attachments: uploaded, workspaceStrategy: strategy)
                    group.addTask {
                        do { _ = try await supervisor.request("orchestration.launchThread", payload: payload); return (s, threadId, nil) } catch { return (s, threadId, error) }
                    }
                }
                for await (s, threadId, error) in group {
                    guard let error else { continue }
                    failed.append(s)
                    guard let self else { continue }
                    let retryKey = self.fanoutRetryKey(key, s)
                    let thread = ThreadId(threadId).scoped(to: ProjectId(session.projectId).environmentId ?? "")
                    self.uncertainFanout[retryKey] = thread
                    self.showFanoutRetry(retryKey, thread: thread, model: s.model, message: Self.message(error))
                }
            }
            guard let self else { return }
            let started = selections.count - failed.count
            if started > 0 {
                panel.toasts.show(ToastView(title: "Started \(started) \(started == 1 ? "thread" : "threads") in background", kind: .success))
            }
            fanoutInFlight.remove(key)
            if !failed.isEmpty {
                // `restoreFailedDraft` (ChatView.tsx:9653-9680): the failed models, the text and the attachments.
                let restore = { [weak self] in
                    guard let self else { return }
                    pickers.setMultiple(failed, for: key)
                    if draftKey == key { composer.text = text; remember(text) } else { prompts[key] = text; scheduleSave() }
                    restoreAttachments(attachments, key: key)
                    syncSidebarDrafts()
                    refresh()
                }
                // `canRestoreDraft` (:9494-9498): still on the draft, which nothing changed since the send.
                if draftKey == key, composer.text.isEmpty, currentAttachments.isEmpty, pickers.currentMultiple == selections {
                    restore()
                } else {
                    showFailedPromptRecovery(key: key, restore: restore)
                }
            } else if started > 0 {
                sentSnapShots(attachments)
                pickers.setMultiple(nil, for: key)
            }
            refresh()
        }
    }

    /// ChatView.tsx:9684-9712: the failed prompt waits behind a toast until its draft is empty again.
    private func showFailedPromptRecovery(key: String, restore: @escaping () -> Void) {
        var id = 0
        id = panel.toasts.show(ToastView(title: "A background prompt could not be sent",
            message: "Your newer draft is unchanged. Restore the failed prompt when this composer is empty.", kind: .error,
            actionTitle: "Restore prompt", action: { [weak self] in
                guard let self else { return }
                let prompt = draftKey == key ? composer.text : prompts[key] ?? ""
                let hasContent = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(draftAttachments[key] ?? []).isEmpty
                if !hasDraft(key) || fanoutInFlight.contains(key) || hasContent {
                    panel.toasts.update(id, title: "A background prompt could not be sent",
                                        message: "Return to the original draft and send or clear its current prompt before restoring.")
                    return
                }
                restore()
                openDraft(key)
                panel.toasts.dismiss(id)
            }), timeout: 0)
    }

    private func fanoutRetryKey(_ draft: String, _ selection: ModelSelection) -> String {
        // Length-delimited fields avoid collisions in user-defined model ids.
        [draft, selection.instanceId.rawValue, selection.model].map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// ChatView.tsx:9503-9616. Any sent request can have succeeded despite a missing response.
    private func showFanoutRetry(_ key: String, thread: ThreadId, model: String, message: String? = nil) {
        panel.toasts.show(ToastView(title: "Could not start \(model)",
            message: message ?? "The previous request may have started. Open its thread to check before sending again.",
            kind: .error, actionTitle: "Allow retry", action: { [weak self] in
                guard let self, let window = self.panel.window else { return }
                let dialog = DialogView(kind: .alertDialog, title: "Allow retry?", message: "The previous request may already be running. Check its thread first. Allow another send that could create a duplicate thread?")
                let open = ButtonView("Open thread", variant: .outline), cancel = ButtonView("Cancel", variant: .ghost), allow = ButtonView("Allow retry")
                dialog.footerButtons = [open, cancel, allow]
                let modal = ModalHost.present(dialog, in: window)
                open.action = { [weak self, weak modal] in modal?.close(); self?.openThread?(thread) }
                cancel.action = { [weak modal] in modal?.close() }
                allow.action = { [weak self, weak modal] in
                    if self?.uncertainFanout[key] == thread { self?.uncertainFanout[key] = nil }
                    modal?.close()
                }
            }), timeout: 0)
    }

    /// I-composer-flow 1.7: drop the optimistic row, restore the text if the composer is still
    /// empty, and show the server's message (transport errors stay silent).
    /// `planFollowUp`: the plan card's refine or implement send (`onSubmitPlanFollowUp`, ChatView.tsx:10508-10516).
    private func sendFailed(_ error: Error, messageId: MessageId, text: String, draft: DraftSession?, key: String?, planFollowUp: Bool = false) {
        optimistic.removeAll { $0.id == messageId }
        if pendingMessageId == messageId { pendingMessageId = nil }
        if let draft, target == .draft(draft) || target == nil {
            // Back to the draft page with its text.
            if let project = sidebar?.snapshot?.projects.first(where: { $0.id.rawValue == draft.projectId }) {
                panel.setDraft(projectTitle: project.title, isScratch: isScratch(project))
            }
        }
        let restore = composer.text.isEmpty ? text : nil
        if let restore { composer.text = restore; remember(restore) }
        refresh()
        if let rpc = error as? RPCClientError, rpc.isTransport { return }
        report(planFollowUp ? .command(Self.message(error), fallback: "Failed to send plan follow-up.") : .send(Self.message(error)), key: key)
    }

    /// A background start failed after a fresh draft took the composer (ChatView.tsx:10029-10101): the
    /// failed draft comes back as its own draft (`restoreFailedBackgroundDraftThread`) with its prompt
    /// if it has none, its error banner, and a "Background task failed" toast that opens it.
    private func backgroundSendFailed(_ error: Error, session: DraftSession, key: String?, text: String, attachments: [ComposerAttachment]) {
        // The group's key usually holds the fresh draft by now; the failed one then keeps its own id as key.
        let restored = NewThreadDraftLaunch.restore(session, key: key, in: &sessions)
            ?? NewThreadDraftLaunch.restore(session, key: session.draftId, in: &sessions)
        let draftId = session.draftId
        if (prompts[draftId] ?? "").isEmpty { prompts[draftId] = text }
        restoreAttachments(attachments, key: draftId)
        scheduleSave()
        syncSidebarDrafts()
        let message = Self.message(error)
        if !((error as? RPCClientError)?.isTransport ?? false) { report(.send(message), key: draftId) }
        guard restored != nil else { return }
        panel.toasts.show(ToastView(title: "Background task failed", message: message ?? "Failed to send message.", kind: .error,
                                    actionTitle: "Open draft", action: { [weak self] in _ = self?.openDraft(draftId) }))
    }

    /// Shows a failure where T3 does: the thread error banner for `key` (the thread or draft the
    /// command ran for), a toast, or nothing (`ComposerFeedback.surface`).
    private func report(_ failure: ComposerFeedback.Failure, key: String?) {
        switch ComposerFeedback.surface(for: failure) {
        case .none: return
        case .banner(let message):
            guard let key else { return }
            threadErrors.set(key, message)
            refresh()
        case .toast(let kind, let title, let description):
            panel.toasts.show(ToastView(title: title, message: description, kind: kind))
        }
    }

    /// The banner's X (ChatView.tsx:11369-11373).
    private func dismissThreadError() {
        guard let key = draftKey else { return }
        threadErrors.dismiss(key, shell: shellThread)
        refresh()
    }

    /// The thread's timeline messages for prompt history (`timelineMessages`, ChatView.tsx:3960):
    /// the projection's timeline plus sends the stream hasn't confirmed, without queued ones.
    private func historyMessages() -> [PromptHistory.Message] {
        var messages: [ChatMessage] = []
        if let projection {
            for entry in TimelineRowsInput(projection: projection).entries {
                if case .message(let message, _) = entry.kind { messages.append(message) }
            }
        }
        let shown = Set(messages.map(\.id))
        messages += optimistic.filter { $0.inputIntent != .queuedTurn && !shown.contains($0.id) }
        // Recall skips messages sent by automations and other agents (composerPromptHistory.ts:131-132).
        return messages.map { PromptHistory.Message(id: $0.id.rawValue, isUser: UserMessagePresentation.isTypedByUser($0), text: $0.text) }
    }

    /// The server's message for a failed command, else nil for the caller's fallback.
    private static func message(_ error: Error) -> String? {
        (error as? RPCClientError)?.typedError?.message
    }

    /// Stop (`interruptThreadTurn`, commands.ts:767-858). A server with `threadStop` takes
    /// `thread.stop` and finds what to stop itself, including background work and commands left
    /// from earlier turns. Older servers get `run.interrupt` with `holdQueue` on the active run
    /// (I-composer-flow 2.1). No local "stopping" state; the button stays until the run settles.
    /// `done` runs once the server answered, or at once when there was nothing to send.
    private func stop(done: (@MainActor () -> Void)? = nil) {
        guard let shell, case .thread(let threadId) = target, let projection else { done?(); return }
        let commandId = JSONValue.string(UUID().uuidString.lowercased())
        let payload: JSONValue
        if let env = threadId.environmentId, capabilities[env]?.threadStop == true {
            payload = .object(["type": .string("thread.stop"), "commandId": commandId, "threadId": .string(threadId.localId.rawValue)])
        } else {
            let state = ComposerLogic.RunState(runs: projection.runs)
            // The shell's activeRunId skips `waiting`; T3's helper falls back to the projection's last live run, then
            // to the latest run while background work is pending (commands.ts:813-835).
            let background = shellThread?.backgroundTasks.isEmpty == false ? projection.runs.last?.id : nil
            guard let runId = state.activeRunId ?? projection.runs.last(where: { $0.status == .waiting })?.id ?? background else { done?(); return }
            payload = .object([
                "type": .string("run.interrupt"), "commandId": commandId,
                "threadId": .string(threadId.localId.rawValue), "runId": .string(runId.rawValue), "holdQueue": .bool(true),
            ])
        }
        let supervisor = shell.supervisor
        let key = draftKey
        Task { [weak self] in
            defer { done?() }
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload) } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.report(.interrupt(Self.message(error)), key: key)
            }
        }
    }

    /// Resume (ChatView.tsx:8656-8730): continue an interrupted run, then release held queued runs.
    private func resume() {
        guard let shell, case .thread(let threadId) = target, let projection, !resuming else { return }
        let state = composer.runState
        guard state.canResume, let selection = pickers.current.modelSelection else { return }
        resuming = true
        let key = draftKey
        if let key { threadErrors.set(key, nil) }
        refresh()
        let supervisor = shell.supervisor
        var continuation: JSONValue?
        if let runId = state.resumableRunId {
            continuation = .object([
                "type": .string("message.dispatch"), "commandId": .string(UUID().uuidString.lowercased()),
                "createdBy": .string("user"), "creationSource": .string("web"), "threadId": .string(threadId.localId.rawValue),
                "messageId": .string(UUID().uuidString.lowercased()), "text": .string("Continue where you left off."),
                "attachments": .array([]), "modelSelection": ThreadSession.encode(selection),
                "dispatchMode": .object(["type": .string("start_immediately")]), "manualContinuationOfRunId": .string(runId.rawValue),
            ])
        }
        let release: JSONValue? = state.hasHeldQueuedRuns ? .object([
            "type": .string("queue.resume"), "commandId": .string(UUID().uuidString.lowercased()), "threadId": .string(threadId.localId.rawValue),
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
                self?.report(.resume(Self.message(error)), key: key)
            }
        }
    }

    // MARK: Queue

    /// One strip command (`queued-run.cancel`, `queued-run.reorder`): the strip is busy until it returns.
    private func queueCommand(_ type: String, _ fields: [String: JSONValue]) {
        guard let shell, case .thread(let threadId) = target, !queueBusy else { return }
        var command = fields
        command["type"] = .string(type)
        command["commandId"] = .string(UUID().uuidString.lowercased())
        command["threadId"] = .string(threadId.localId.rawValue)
        queueBusy = true
        refresh()
        let supervisor = shell.supervisor
        Task { [weak self] in
            defer { self?.queueBusy = false; self?.refresh() }
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(command)) } catch {
                // T3 only logs these (QueuedRunsControl.tsx:168-245 through useAtomCommand).
                self?.report(.queueCommand, key: nil)
            }
        }
    }

    /// Steer now: the server cancels the queued run and steers the same message into the active run.
    private func promoteToSteer(_ runId: RunId) {
        guard let active = panel.queue.state.activeRunId, panel.queue.state.canPromoteToSteer else { return }
        queueCommand("queued-message.promote-to-steer", ["queuedRunId": .string(runId.rawValue), "targetRunId": .string(active.rawValue)])
    }

    private func beginEdit(_ item: ComposerLogic.QueueState.Item) {
        guard let runId = item.runId, case .thread(let threadId) = target, queuedEdit == nil, !queueBusy else { return }
        flushPrompt()
        queuedEdit = QueuedEdit(runId: runId, threadId: threadId, originalText: item.text)
        composer.resetPromptHistory()
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
            "threadId": .string(edit.threadId.localId.rawValue), "runId": .string(edit.runId.rawValue), "text": .string(text),
        ])
        queueBusy = true
        refresh()
        let supervisor = shell.supervisor
        let key = draftKey
        Task { [weak self] in
            do {
                _ = try await supervisor.request("orchestration.dispatchCommand", payload: command)
                guard let self else { return }
                if let key { threadErrors.set(key, nil) }
                queueBusy = false
                if queuedEdit?.runId == edit.runId { endEdit() } else { refresh() }
            } catch {
                self?.queueBusy = false
                self?.refresh()
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.report(.queuedEditSave, key: key)
            }
        }
    }
}

// MARK: Sidebar draft rows (the sidebar's draft block reads and drives the draft sessions)

extension ComposerController {
    /// Drafts with a prompt, for `SidebarDraftBlock` (Sidebar.tsx:962-1066), and the open draft.
    func syncSidebarDrafts() {
        // Draft rows show for every environment in the merged shell, each under its own (scoped) project.
        let projects = Set(sidebar?.snapshot?.projects.map(\.id) ?? [])
        let drafts = sessions.values.compactMap { s -> SidebarDraft? in
            guard projects.contains(ProjectId(s.projectId)) else { return nil }
            // The open draft's prompt lives in the editor until the next save.
            let prompt = target == .draft(s) ? composer.text : prompts[s.draftId] ?? ""
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
                : SidebarDraft(id: s.draftId, projectId: ProjectId(s.projectId), prompt: prompt, createdAt: s.createdAt)
        }
        var active: String?
        if case .draft(let s) = target { active = s.draftId }
        sidebar?.setDrafts(drafts, activeDraftId: active)
    }

    /// A draft row's click: a plain navigation to the draft, which changes nothing in it. False when the
    /// draft or its project is gone.
    @discardableResult
    /// Whether a draft session still exists (it goes once its thread is sent or it is discarded).
    func hasDraft(_ draftId: String) -> Bool { sessions.values.contains { $0.draftId == draftId } }

    func openDraft(_ draftId: String) -> Bool {
        guard let session = sessions.values.first(where: { $0.draftId == draftId }),
              let project = sidebar?.snapshot?.projects.first(where: { $0.id.rawValue == session.projectId }) else { return false }
        if target == .draft(session) { return true }
        showDraft(project, stored: session)
        return true
    }

    /// `discardComposerDraft`: drops the session and its prompt. The open draft's route then has nothing
    /// to show, and like T3's index route the panel lands in a fresh draft for the same project.
    func discardDraft(_ draftId: String) {
        guard let (key, session) = sessions.first(where: { $0.value.draftId == draftId }) else { return }
        sessions[key] = nil
        prompts[draftId] = nil
        pickers.store.didSend(draftId)
        if target == .draft(session), let project = sidebar?.snapshot?.projects.first(where: { $0.id.rawValue == session.projectId }) {
            composer.text = ""
            showDraft(project)
        }
        scheduleSave()
        syncSidebarDrafts()
    }
}

// MARK: Question file answers (questionAttachments.ts, ChatComposer.tsx:5736-5880, ChatView.tsx:10148-10200)

/// One file attached to a question's answer: picked, uploaded through `attachments.createUploadUrl`
/// and the signed upload route, then sent in `attachmentsByQuestionId`.
fileprivate struct QuestionFile {
    let id: String
    let url: URL
    let name: String
    let mimeType: String
    let sizeBytes: Int
    var status: ComposerFileRow.Status
    /// The pending upload the server minted; it becomes the attachment id on submit.
    var attachmentId: String?
    var task: Task<Void, Never>?
    /// A SnapShot: sent as an image with its source, and its local copy is the app's to delete.
    var snapShot = false
    var snapShotSource: JSONValue?

    var type: String { snapShot ? "image" : "file" }
    var row: ComposerFileRow { ComposerFileRow(id: id, name: name, sizeBytes: sizeBytes, status: status) }
    /// `ChatFileAttachment`: `{type, id, name, mimeType, sizeBytes}`, or `ChatImageAttachment` with its `source`.
    var attachment: JSONValue? {
        guard status == .ready, let attachmentId else { return nil }
        var fields: [String: JSONValue] = ["type": .string(type), "id": .string(attachmentId), "name": .string(name),
                                           "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))]
        if let snapShotSource { fields["source"] = snapShotSource }
        return .object(fields)
    }
}

/// Upload progress from the URL session, on the main actor.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

extension ComposerController {
    /// `PROVIDER_SEND_TURN_MAX_ATTACHMENTS` across one set of answers.
    static let maxQuestionAttachments = 100

    /// Thread, request and question, like `questionAttachmentDraftId`.
    fileprivate static func questionKey(_ threadId: ThreadId, _ requestId: String, _ questionId: String) -> String {
        requestPrefix(threadId, requestId) + questionId
    }
    fileprivate static func requestPrefix(_ threadId: ThreadId, _ requestId: String) -> String { threadId.rawValue + "\u{0}" + requestId + "\u{0}" }

    fileprivate func readCapabilities(_ shell: ShellSession?, environmentId: String) {
        capabilityTasks[environmentId]?.cancel()
        capabilities[environmentId] = nil
        guard let http = shell?.http else { return }
        capabilityTasks[environmentId] = Task { [weak self] in
            guard let descriptor = try? await http.descriptor(), !Task.isCancelled, let self else { return }
            var limit: Int?
            if descriptor.capability("attachmentUploads"), case .number(let max)? = descriptor.capabilities["fileAttachments"]?["maxUploadBytes"] {
                limit = Int(max)
            }
            capabilities[environmentId] = (descriptor.capability("questionAttachments"), limit, descriptor.capability("threadStop"))
            menuState.pullRequestsSupported[environmentId] = descriptor.capability("pullRequests")
            refresh()
        }
    }

    /// The active question's key, when it can take files.
    private var activeQuestionKey: String? {
        guard case .thread(let threadId) = target, let requestId = questionRequestId,
              let question = panel.lazyQuestionPanel.loaded?.session?.progress.activeQuestion else { return nil }
        return Self.questionKey(threadId, requestId, question.id)
    }

    /// Files across one request's questions, against `maxQuestionAttachments` (`countQuestionRequestAttachments`).
    private func questionRequestAttachmentCount(_ requestId: String) -> Int {
        guard case .thread(let threadId) = target else { return 0 }
        let prefix = Self.requestPrefix(threadId, requestId)
        return questionFiles.filter { $0.key.hasPrefix(prefix) }.reduce(0) { $0 + $1.value.count }
    }

    /// The question's file list and the attachment state the answer rules read. Files of requests
    /// that are no longer pending are released (ChatView.tsx:3374-3398).
    fileprivate func syncQuestionFiles() {
        pruneQuestionFiles()
        composer.fileRows = activeQuestionKey.map { (questionFiles[$0] ?? []).map(\.row) } ?? []
        guard let session = panel.lazyQuestionPanel.loaded?.session, case .thread(let threadId) = target else { return }
        var states: [String: UserInputSession.AttachmentState] = [:]
        for q in session.request.questions {
            let files = questionFiles[Self.questionKey(threadId, session.request.requestId, q.id)] ?? []
            if !files.isEmpty {
                states[q.id] = .init(count: files.count, blocked: !supportsQuestionAttachments || files.contains { $0.status != .ready })
            }
        }
        panel.lazyQuestionPanel.loaded?.setAttachments(states)
    }

    /// The open thread's files whose request is no longer pending go (other threads keep theirs).
    fileprivate func pruneQuestionFiles() {
        guard case .thread(let threadId) = target else { return }
        let live = Set(requests.userInputs.flatMap { r in r.questions.map { Self.questionKey(threadId, r.requestId, $0.id) } })
        for key in questionFiles.keys where key.hasPrefix(threadId.rawValue + "\u{0}") && !live.contains(key) { releaseQuestionFiles(key) }
    }

    private func releaseQuestionFiles(_ key: String) {
        for file in questionFiles[key] ?? [] { discard(file) }
        questionFiles[key] = nil
    }

    /// Cancels an upload and deletes its pending server copy (`releaseAttachmentUpload`; a claimed
    /// upload is no longer pending, so the delete is a no-op).
    private func discard(_ file: QuestionFile) {
        file.task?.cancel()
        if file.snapShot { try? FileManager.default.removeItem(at: file.url) }
        guard let id = file.attachmentId, let supervisor = shell?.supervisor else { return }
        Task { _ = try? await supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(id)])) }
    }

    private func setThreadError(_ message: String) {
        guard let key = draftKey else { return }
        threadErrors.set(key, message)
        refresh()
    }

    /// The attach button while a question that takes a custom answer is open: an open panel, then
    /// T3's checks (count, empty, size) and an upload per accepted file.
    // ponytail: images go up as plain files without thumbnails, compression or the image type, and there is no paste or drop; add them with the composer's own attachments
    fileprivate func attachToQuestion() {
        guard let requestId = questionRequestId, let session = panel.lazyQuestionPanel.loaded?.session, let key = activeQuestionKey,
              session.progress.activeQuestion?.allowsCustomAnswer == true, supportsQuestionAttachments,
              !responding.contains(requestId), let window = composer.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.addQuestionFiles(panel.urls, key: key, requestId: requestId) }
        }
    }

    private func addQuestionFiles(_ urls: [URL], key: String, requestId: String) {
        guard let session = panel.lazyQuestionPanel.loaded?.session, session.request.requestId == requestId, case .thread(let threadId) = target else { return }
        var reserved = session.request.questions.reduce(0) { $0 + (questionFiles[Self.questionKey(threadId, requestId, $1.id)]?.count ?? 0) }
        var error: String?
        for url in urls {
            let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if reserved >= Self.maxQuestionAttachments {
                error = "You can attach up to \(Self.maxQuestionAttachments) files per message."
                continue
            }
            guard let limit = fileUploadLimit else { error = "This server does not support file attachments."; continue }
            if size <= 0 { error = "'\(name)' is empty or could not be read."; continue }
            if size > limit { error = Self.tooLargeMessage(name, limit); continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let file = QuestionFile(id: UUID().uuidString, url: url, name: name, mimeType: mime.lowercased(), sizeBytes: size, status: .uploading(0))
            questionFiles[key, default: []].append(file)
            reserved += 1
            upload(file.id, key: key)
        }
        if let error { setThreadError(error) }
        syncQuestion()
    }

    /// `fileAttachmentTooLargeMessage` (packages/client-runtime/src/state/attachments.ts:228-236).
    static func tooLargeMessage(_ name: String, _ limit: Int) -> String {
        let mb = 1024 * 1024
        let size = limit >= mb && limit % mb == 0 ? "\(limit / mb) MB"
            : limit >= 1024 && limit % 1024 == 0 ? "\(limit / 1024) KB" : "\(limit) \(limit == 1 ? "byte" : "bytes")"
        return "'\(name)' exceeds the \(size) attachment limit."
    }

    private func updateFile(_ id: String, key: String, _ change: (inout QuestionFile) -> Void) {
        guard let i = questionFiles[key]?.firstIndex(where: { $0.id == id }) else { return }
        change(&questionFiles[key]![i])
        syncQuestion()
    }

    /// `runUpload` for a question's file (`uploadAttachment` below).
    private func upload(_ id: String, key: String) {
        guard let file = questionFiles[key]?.first(where: { $0.id == id }) else { return }
        guard let shell else { updateFile(id, key: key) { $0.status = .failed("This connection cannot upload attachments.") }; return }
        let task = Task { [weak self] in
            let result = await Self.uploadAttachment(
                supervisor: shell.supervisor, base: shell.http.baseURL, type: file.type, name: file.name,
                mimeType: file.mimeType, sizeBytes: file.sizeBytes, file: file.url,
                onMinted: { minted in self?.updateFile(id, key: key) { $0.attachmentId = minted } },
                onProgress: { p in
                    self?.updateFile(id, key: key) { f in
                        if case .uploading(let old) = f.status, Int(old * 20) == Int(p * 20) { return }
                        f.status = .uploading(p)
                    }
                })
            switch result {
            case .uploaded: self?.updateFile(id, key: key) { $0.status = .ready }
            case .failed(let reason): self?.updateFile(id, key: key) { $0.status = .failed(reason) }
            case .cancelled: break
            }
        }
        updateFile(id, key: key) { $0.task = task }
    }


    private func fileKey(_ id: String) -> String? { questionFiles.first { $0.value.contains { $0.id == id } }?.key }

    fileprivate func removeQuestionFile(_ id: String) {
        guard let key = fileKey(id), let i = questionFiles[key]?.firstIndex(where: { $0.id == id }) else { return }
        discard(questionFiles[key]!.remove(at: i))
        if questionFiles[key]?.isEmpty == true { questionFiles[key] = nil }
        syncQuestion()
    }

    /// `retryAttachmentUpload`: drop the failed pending copy and upload again.
    fileprivate func retryQuestionFile(_ id: String) {
        guard let key = fileKey(id), let file = questionFiles[key]?.first(where: { $0.id == id }) else { return }
        discard(file)
        updateFile(id, key: key) { $0.attachmentId = nil; $0.task = nil; $0.status = .uploading(0) }
        upload(id, key: key)
    }

    /// `onRespondToUserInput`: every question's files must be uploaded; they ride along in
    /// `attachmentsByQuestionId`.
    fileprivate func submitAnswers(_ payload: JSONValue) {
        guard case .object(var fields) = payload, case .string(let requestId)? = payload["requestId"],
              case .thread(let threadId) = target else { return }
        let prefix = Self.requestPrefix(threadId, requestId)
        var byQuestion: [String: JSONValue] = [:]
        for (key, files) in questionFiles where key.hasPrefix(prefix) && !files.isEmpty {
            let uploaded = files.compactMap(\.attachment)
            guard uploaded.count == files.count else {
                setThreadError("Wait for attachments to finish uploading, or remove failed uploads.")
                return
            }
            byQuestion[String(key.dropFirst(prefix.count))] = .array(uploaded)
        }
        if !byQuestion.isEmpty { fields["attachmentsByQuestionId"] = .object(byQuestion) }
        if case .object(var answers)? = fields["answers"] {
            for (id, answer) in answers {
                guard case .string(let text) = answer else { continue }
                answers[id] = .string(ComposerContext.projectAnswer(text, records: contextRecords(for: text)))
            }
            fields["answers"] = .object(answers)
        }
        respond(.object(fields), failure: ComposerFeedback.Failure.userInput)
    }
}

// MARK: - Menus and chips

/// The composer's `/`, `@`, `$` and `#` menus (ChatComposer.tsx:2550-2930) and the records behind
/// its context chips (composerContextRecords.ts). Rows are built in `ComposerMenus`; this side runs
/// the server calls: `projects.searchEntries` for `@`, `pullRequests.list` for `#`, and
/// `server.refreshProviders` for the workspace's skills and commands.
extension ComposerController {
    struct MenuState {
        /// Context records by id, from picks and pastes. Thread records are also rebuilt from the
        /// shell, so a restored draft keeps its thread chips.
        // ponytail: kept in memory only; a restart turns a pull request chip unavailable. Persist them with the drafts if that bites
        var records: [String: JSONValue] = [:]
        var paths: (key: String, entries: [(path: String, isDirectory: Bool)])?
        var pathTask: Task<Void, Never>?
        var pullRequests: (key: String, entries: [ComposerMenus.PullRequestEntry], failed: Bool)?
        var pullRequestTask: Task<Void, Never>?
        /// `#<number>` outside the listed rows: `pullRequests.detail` for it (ChatComposer.tsx:2615-2647), by key and number.
        var exactPullRequest: (key: String, number: Int, entry: ComposerMenus.PullRequestEntry?)?
        var exactPullRequestTask: Task<Void, Never>?
        /// `server.refreshProviders` requests by `env|instance|cwd`, at most one per TTL (5 minutes).
        var workspaceRefresh: [String: Date] = [:]
        var pullRequestsSupported: [String: Bool] = [:]
    }

    fileprivate func setUpMenus() {
        let menus = panel.menus
        menus.itemsProvider = { [weak self] trigger in
            self?.menuContent(trigger) ?? ComposerMenuController.Content(items: [], emptyText: "")
        }
        menus.onTriggerChange = { [weak self] trigger in
            if trigger?.kind != .path || trigger?.query.isEmpty == false { self?.browsingThreads = false }
            self?.startSearches(trigger)
        }
        menus.onPick = { [weak self] item in self?.picked(item) }
        composer.chipLook = { [weak self] token in self?.chipLook(token) ?? ComposerChipLook.basic(token) }
        composer.recordsForCopy = { [weak self] ids in
            guard let self, let env = targetEnvironmentId else { return nil }
            let records = contextRecords(for: ids)
            return (ids.compactMap { records[$0] }, env)
        }
        composer.onPasteRecords = { [weak self] records in
            self?.menuState.records.merge(records) { $1 }
        }
    }

    // MARK: Inputs

    private var menuProject: ProjectShell? {
        let projectId: ProjectId? = switch target {
        case .draft(let s): ProjectId(s.projectId)
        case .thread: shellThread?.projectId
        case nil: nil
        }
        return sidebar?.snapshot?.projects.first { $0.id == projectId }
    }

    /// `gitCwd`: the thread's worktree, else the project root.
    private var menuCwd: String? { shellThread?.worktreePath ?? menuProject?.workspaceRoot }

    private var menuProvider: ServerProvider? {
        guard let instance = pickers.current.instanceId else { return nil }
        return serverConfig.providers.first { $0.instanceId == instance }
    }

    /// `sourceControlRepositorySelector` (shared/sourceControl.ts:287-300).
    private var menuRepository: String? {
        guard let identity = menuProject?.repositoryIdentity else { return nil }
        if identity.provider == "azure-devops" {
            let segments = (identity.displayName ?? "").split(separator: "/").filter { $0 != "_git" }
            return identity.name.flatMap { $0.isEmpty ? nil : $0 } ?? segments.last.map(String.init)
        }
        if let name = identity.displayName, !name.isEmpty { return name }
        if let owner = identity.owner, let name = identity.name, !owner.isEmpty, !name.isEmpty { return "\(owner)/\(name)" }
        return nil
    }

    /// The environment's threads for `@` (the agent can only read threads on its own server).
    private var menuThreads: [ComposerMenus.ThreadCandidate] {
        guard let env = targetEnvironmentId else { return [] }
        return (sidebar?.snapshot?.threads ?? []).compactMap { t in
            guard EnvironmentScope.environmentId(of: t.id.rawValue) == env else { return nil }
            return ComposerMenus.ThreadCandidate(id: EnvironmentScope.localId(of: t.id.rawValue), title: t.title,
                                                 updatedAt: t.updatedAt.raw, archived: t.archivedAt != nil)
        }
    }

    private var currentThreadLocalId: String? {
        guard case .thread(let id) = target else { return nil }
        return EnvironmentScope.localId(of: id.rawValue)
    }

    private func pathKey(_ query: String) -> String? {
        guard let env = targetEnvironmentId, let cwd = menuCwd else { return nil }
        return "\(env)|\(cwd)|\(query.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Numbers and an empty query list the project's pull requests; text asks the host.
    private func pullRequestKey(_ query: String) -> String? {
        guard let env = targetEnvironmentId, let project = menuProject else { return nil }
        let text = query.allSatisfy(\.isNumber) ? "" : query
        return "\(env)|\(project.id.rawValue)|\(text)"
    }

    // MARK: Rows

    private func menuContent(_ trigger: ComposerTrigger) -> ComposerMenuController.Content {
        let provider = menuProvider
        let providerKey = provider?.instanceId.rawValue ?? ""
        let cwd = menuCwd
        switch trigger.kind {
        case .slashCommand:
            // `/compact` only when the prompt is the command alone, with no attachments, on a thread that can
            // compact (`compactSlashCommandAvailable`, ChatComposer.tsx:2576-2585). Inline contexts live in
            // the prompt, so an otherwise empty prompt has none.
            let text = composer.displayText as NSString
            let before = text.substring(to: trigger.rangeStart), after = text.substring(from: trigger.rangeEnd)
            let compact = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !compactUnavailable && currentAttachments.isEmpty
            let planMode = pickers.context.interactionModeEnabled(provider)
            let items = ComposerMenus.slashItems(trigger: trigger, provider: providerKey, commands: provider?.slashCommands(cwd: cwd) ?? [],
                                                 skills: provider?.skills(cwd: cwd) ?? [],
                                                 showSkills: ClientSettingsStore.shared.current.bool("showSkillsInSlashMenu"), planMode: planMode,
                                                 compactAvailable: compact)
            return .init(items: items, emptyText: ComposerMenus.emptyText(kind: .slashCommand, loading: false))
        case .skill:
            let items = ComposerMenus.skillItems(query: trigger.query, provider: providerKey, skills: provider?.skills(cwd: cwd) ?? [])
            return .init(items: items, emptyText: ComposerMenus.emptyText(kind: .skill, loading: false))
        case .path:
            let threads = ComposerMenus.threadItems(query: trigger.query, threads: menuThreads, excluding: currentThreadLocalId, browse: browsingThreads)
            // "+" > Threads: a bare `@` lists the newest threads alone, until the token changes.
            if browsingThreads, trigger.query.isEmpty {
                return .init(items: threads, emptyText: "No threads found.")
            }
            let key = pathKey(trigger.query)
            let entries = menuState.paths.flatMap { $0.key == key ? $0.entries : nil } ?? []
            let loading = !trigger.query.isEmpty && key != nil && menuState.paths?.key != key
            return .init(items: threads + ComposerMenus.pathItems(entries), emptyText: ComposerMenus.emptyText(kind: .path, loading: loading))
        case .pullRequest:
            let env = targetEnvironmentId ?? ""
            let linked = ThreadPullRequests.visible(shellThread?.pullRequests ?? [])
            let available = menuState.pullRequestsSupported[env] == true && menuProject != nil && menuRepository != nil
            let key = pullRequestKey(trigger.query)
            let listed = menuState.pullRequests.flatMap { $0.key == key ? $0 : nil }
            let exact = menuState.exactPullRequest.flatMap { $0.key == key && String($0.number) == trigger.query ? $0.entry : nil }
            let listedEntries = listed?.entries ?? []
            var entries = exact.map { e in [e] + listedEntries.filter { $0.reference.number != e.reference.number } } ?? listedEntries
            for link in linked where !entries.contains(where: { $0.reference.url == link.url }) {
                let snapshot = link.snapshot
                let pr = PullRequestReference(number: link.number, title: snapshot?.title ?? "#\(link.number)", url: link.url,
                    headBranch: snapshot?.headBranch ?? "", baseBranch: snapshot?.baseBranch ?? "",
                    state: snapshot?.state.rawValue ?? "open", isDraft: snapshot?.isDraft ?? false)
                let query = trigger.query.lowercased()
                if query.isEmpty || "#\(pr.number) \(pr.title) \(link.repository) \(pr.headBranch)".lowercased().contains(query) {
                    entries.append(.init(reference: pr, repository: link.repository, authorLogin: nil, updatedAt: snapshot?.updatedAt?.raw ?? ""))
                }
            }
            let items = ComposerMenus.pullRequestItems(query: trigger.query, entries: entries, hostSearched: true)
            return .init(items: items, emptyText: ComposerMenus.emptyText(kind: .pullRequest, loading: available && listed == nil, pullRequestsAvailable: available || !linked.isEmpty, pullRequestsFailed: listed?.failed == true,
                                                                           query: trigger.query))
        }
    }

    // MARK: Searches

    private func startSearches(_ trigger: ComposerTrigger?) {
        guard let trigger, let shell else {
            menuState.pathTask?.cancel()
            menuState.pullRequestTask?.cancel()
            return
        }
        let supervisor = shell.supervisor
        switch trigger.kind {
        case .path:
            menuState.pathTask?.cancel()
            let query = trigger.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let cwd = menuCwd, let key = pathKey(query), menuState.paths?.key != key else { return }
            menuState.pathTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ComposerMenus.pathSearchDebounce))
                guard !Task.isCancelled else { return }
                let payload: JSONValue = .object(["cwd": .string(cwd), "query": .string(query), "limit": .number(Double(ComposerMenus.pathSearchLimit))])
                let reply = try? await supervisor.request("projects.searchEntries", payload: payload)
                guard !Task.isCancelled, let self else { return }
                var entries: [(path: String, isDirectory: Bool)] = []
                if case .array(let list)? = reply?["entries"] {
                    entries = list.compactMap { e in e["path"]?.stringValue.map { ($0, e["kind"]?.stringValue == "directory") } }
                }
                menuState.paths = (key, entries)
                panel.menus.reload()
            }
        case .pullRequest:
            menuState.pullRequestTask?.cancel()
            guard menuState.pullRequestsSupported[targetEnvironmentId ?? ""] == true, let project = menuProject,
                  let repository = menuRepository, let key = pullRequestKey(trigger.query) else { return }
            let text = trigger.query.allSatisfy(\.isNumber) ? "" : trigger.query
            let projectId = EnvironmentScope.localId(of: project.id.rawValue)
            // Numbers share the listed rows; a new number may still need its own lookup.
            if menuState.pullRequests?.key == key {
                lookUpExactPullRequest(trigger.query, key: key, projectId: projectId, repository: repository, supervisor: supervisor)
                return
            }
            menuState.pullRequestTask = Task { [weak self] in
                if !text.isEmpty { try? await Task.sleep(for: .seconds(ComposerMenus.pullRequestDebounce)) }
                guard !Task.isCancelled else { return }
                var input: [String: JSONValue] = ["state": .string("all"), "projectId": .string(projectId),
                                                  "limit": .number(Double(ComposerMenus.pullRequestListLimit))]
                if !text.isEmpty { input["query"] = .string(text) }
                let reply = try? await supervisor.request("pullRequests.list", payload: .object(input))
                guard !Task.isCancelled, let self else { return }
                menuState.pullRequests = (key, Self.pullRequestEntries(reply, projectId: projectId, repository: repository, query: text),
                                          reply == nil || Self.listFailed(reply, projectId: projectId))
                panel.menus.reload()
                lookUpExactPullRequest(trigger.query, key: key, projectId: projectId, repository: repository, supervisor: supervisor)
            }
        case .slashCommand, .skill:
            break
        }
    }

    /// `#<n>` that the listed rows lack: `pullRequests.detail` after the number settles for 180 ms
    /// (`exactPullRequestLookup`). A miss leaves the list as it is.
    private func lookUpExactPullRequest(_ query: String, key: String, projectId: String, repository: String, supervisor: ConnectionSupervisor) {
        menuState.exactPullRequestTask?.cancel()
        guard let number = Int(query), number > 0, menuState.exactPullRequest?.key != key || menuState.exactPullRequest?.number != number,
              menuState.pullRequests?.entries.contains(where: { $0.reference.number == number }) != true else { return }
        menuState.exactPullRequestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let payload: JSONValue = .object(["projectId": .string(projectId), "repository": .string(repository), "number": .number(Double(number))])
            let reply = try? await supervisor.request("pullRequests.detail", payload: payload)
            guard !Task.isCancelled, let self else { return }
            var entry: ComposerMenus.PullRequestEntry?
            if let d = reply, d["number"]?.intValue == number {
                let isDraft: Bool = if case .bool(let b)? = d["isDraft"] { b } else { false }
                let pr = PullRequestReference(number: number, title: d["title"]?.stringValue ?? "", url: d["url"]?.stringValue ?? "",
                                              headBranch: d["headBranch"]?.stringValue ?? "", baseBranch: d["baseBranch"]?.stringValue ?? "",
                                              state: d["state"]?.stringValue ?? "open", isDraft: isDraft)
                entry = ComposerMenus.PullRequestEntry(reference: pr, repository: d["repository"]?.stringValue ?? repository,
                                                       authorLogin: d["author"]?["login"]?.stringValue, updatedAt: d["updatedAt"]?.stringValue ?? "")
            }
            menuState.exactPullRequest = (key, number, entry)
            if entry != nil { panel.menus.reload() }
        }
    }

    /// `pullRequests.list` rows for this project and repository. With a text query a row stays when
    /// its host searched (`searchesOnHost`) or its own fields match (`matchesPullRequestQuery`).
    private static func pullRequestEntries(_ reply: JSONValue?, projectId: String, repository: String, query: String) -> [ComposerMenus.PullRequestEntry] {
        guard case .array(let list)? = reply?["entries"] else { return [] }
        var searchesOnHost: Set<String> = []
        if case .array(let providers)? = reply?["providers"] {
            for p in providers { if case .bool(true)? = p["searchesOnHost"], let host = p["host"]?.stringValue { searchesOnHost.insert(host) } }
        }
        let repo = repository.trimmingCharacters(in: .whitespaces).lowercased()
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return list.compactMap { e in
            guard e["projectId"]?.stringValue == projectId,
                  e["repository"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() == repo,
                  let n = e["number"]?.intValue else { return nil }
            let isDraft: Bool = if case .bool(let b)? = e["isDraft"] { b } else { false }
            let pr = PullRequestReference(number: n, title: e["title"]?.stringValue ?? "", url: e["url"]?.stringValue ?? "",
                                          headBranch: e["headBranch"]?.stringValue ?? "", baseBranch: e["baseBranch"]?.stringValue ?? "",
                                          state: e["state"]?.stringValue ?? "open", isDraft: isDraft)
            let entry = ComposerMenus.PullRequestEntry(reference: pr, repository: e["repository"]?.stringValue ?? "",
                                                       authorLogin: e["author"]?["login"]?.stringValue, updatedAt: e["updatedAt"]?.stringValue ?? "")
            if !needle.isEmpty, !searchesOnHost.contains(e["host"]?.stringValue ?? "") {
                let fields = "#\(pr.number) \(pr.title) \(entry.repository) \(pr.headBranch) \(entry.authorLogin ?? "")".lowercased()
                if !fields.contains(needle) { return nil }
            }
            return entry
        }
    }

    private static func listFailed(_ reply: JSONValue?, projectId: String) -> Bool {
        guard case .array(let errors)? = reply?["errors"] else { return false }
        return errors.contains { $0["projectId"]?.stringValue == projectId }
    }

    /// `server.refreshProviders` for the composer's provider and cwd when the workspace snapshot is
    /// missing or older than its TTL (ChatComposer.tsx:2214-2300). The reply carries the providers.
    fileprivate func refreshWorkspaceSnapshot() {
        guard let shell, let env = targetEnvironmentId, let cwd = menuCwd, let provider = menuProvider else { return }
        let key = "\(env)|\(provider.instanceId.rawValue)|\(cwd)"
        let ttl: TimeInterval = 5 * 60
        if let last = menuState.workspaceRefresh[key], Date().timeIntervalSince(last) < ttl { return }
        if let snapshot = provider.workspaceSnapshot(cwd), snapshot.slashCommandsPending != true,
           let checked = T3Timestamp(snapshot.checkedAt).date, Date().timeIntervalSince(checked) < ttl { return }
        menuState.workspaceRefresh[key] = Date()
        let supervisor = shell.supervisor
        let payload: JSONValue = .object(["instanceId": .string(provider.instanceId.rawValue), "cwd": .string(cwd)])
        Task { [weak self] in
            guard let reply = try? await supervisor.request("server.refreshProviders", payload: payload),
                  let providers = try? reply["providers"]?.decode(as: [ServerProvider].self), let self else { return }
            var config = serverConfigs[env] ?? ServerProviderConfig(providers: [])
            config.providers = providers
            serverConfigs[env] = config
            if panel.menus.isOpen { panel.menus.reload() }
            composer.refreshChips()
        }
    }

    // MARK: Picks and chips

    private func picked(_ item: ComposerMenuItem) {
        switch item.kind {
        case .builtIn("model"):
            // The token goes and the model picker opens (ChatComposer.tsx:4003-4014).
            DispatchQueue.main.async { [weak self] in self?.pickers.toggleModelPicker() }
        case .providerCommand("usage-limits"):
            // Picking it is the action; the draft keeps nothing of it (ChatComposer.tsx:4026-4033).
            DispatchQueue.main.async { [weak self] in self?.openUsageLimits() }
        case .builtIn(let mode):
            if let key = draftKey { pickers.store.setInteractionMode(key, mode == "plan" ? .plan : .default) }
            updatePickers()
        case .thread(let id, let title):
            guard let env = targetEnvironmentId else { return }
            let record = ComposerContext.threadRecord(threadId: id, title: title, environmentId: env)
            if let contextId = record["contextId"]?.stringValue { menuState.records[contextId] = record }
        case .pullRequest(let pr):
            menuState.records[ComposerContext.pullRequestReference(pr).contextId] = ComposerContext.pullRequestRecord(pr)
        default:
            break
        }
    }

    /// The records the prompt's links point at: picked or pasted ones, and threads rebuilt from the
    /// shell (`thread_<id>`).
    fileprivate func contextRecords(for prompt: String) -> [String: JSONValue] {
        contextRecords(for: ComposerContext.referencedIds(prompt))
    }

    fileprivate func contextRecords(for ids: [String]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for id in ids {
            if let record = menuState.records[id] { out[id] = record; continue }
            if let record = rebuiltThreadRecord(id) { out[id] = record }
        }
        return out
    }

    private func rebuiltThreadRecord(_ contextId: String) -> JSONValue? {
        guard contextId.hasPrefix("thread_"), let env = targetEnvironmentId else { return nil }
        let local = String(contextId.dropFirst("thread_".count))
        guard let thread = sidebar?.snapshot?.threads.first(where: { $0.id.rawValue == EnvironmentScope.key(env, local) }) else { return nil }
        return ComposerContext.threadRecord(threadId: local, title: thread.title, environmentId: env)
    }

    private func chipLook(_ token: ComposerInlineToken) -> ComposerChipLook {
        if case .context(let kind, let contextId, let label) = token.kind,
           let look = attachmentChipLook(kind: kind, contextId: contextId, label: label) { return look }
        let skills = menuProvider?.skills(cwd: menuCwd) ?? []
        let env = targetEnvironmentId ?? ""
        let threads = sidebar?.snapshot?.threads ?? [], projects = sidebar?.snapshot?.projects ?? []
        return ComposerChipLook.look(for: token, skillLabel: { name in
            skills.first { $0.name == name }.map(ProviderSkills.displayName) ?? ProviderSkills.displayName(name: name, displayName: nil)
        }, record: { id in menuState.records[id] ?? rebuiltThreadRecord(id) }, threadTitle: { record in
            // `ThreadContextChip` prefers the live title.
            guard let local = record["threadId"]?.stringValue else { return nil }
            return threads.first { $0.id.rawValue == EnvironmentScope.key(env, local) }?.title
        }, threadProject: { record in
            // `ThreadContextChip` shows the thread's project icon (ThreadContextChip.tsx:18, 32-36).
            guard let local = record["threadId"]?.stringValue,
                  let shell = threads.first(where: { $0.id.rawValue == EnvironmentScope.key(env, local) }),
                  let project = projects.first(where: { $0.id == shell.projectId }) else { return nil }
            return ProjectIconSource(project)
        })
    }
}

// MARK: - Attachments

/// `createDelayedStatus` (packages/client-runtime/src/delayedStatus.ts): a status shows once it has
/// lasted 400 ms and then stays at least 400 ms, so a short sync never flashes.
struct DelayedStatus {
    static let showDelay: TimeInterval = 0.4, minVisible: TimeInterval = 0.4
    var key = ""
    var value: ComposerActivityRowView.Phase?
    var shown: ComposerActivityRowView.Phase?
    var shownAt = Date.distantPast
    var timer: DispatchWorkItem?
}

/// The composer's own files and images (ChatComposer.tsx `addComposerAttachments`, :5762-5960):
/// the picker, drops and pastes, T3's checks, image preparation, the upload through
/// `attachments.createUploadUrl` and the signed route, chips, the image shelf and preview, and the
/// sent message's images. Then the prompt stash (promptStashStore.ts, ChatComposer.tsx:4536-5040)
/// and the thread's sync row (ComposerActivityStatus.tsx).
extension ComposerController {
    enum UploadResult { case uploaded(String), failed(String), cancelled }

    /// Test builds keep their own folder, so a test stash never lands in the user's real one.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CandyWrapper", isDirectory: true)
        guard AppDelegate.isTestBuild, let id = Bundle.main.bundleIdentifier else { return base }
        return base.appendingPathComponent(id, isDirectory: true)
    }
    static var attachmentWorkDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CandyWrapperAttachments", isDirectory: true)
    }
    nonisolated static var attachmentCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CandyWrapper/attachments", isDirectory: true)
    }

    /// `runAttachmentUploadCycle` plus the byte transfer: mint a signed upload URL, POST the file
    /// with its content type and report progress, failing with T3's reasons. A cancel after the
    /// mint deletes the pending upload.
    static func uploadAttachment(supervisor: ConnectionSupervisor, base: URL, type: String, name: String, mimeType: String,
                                 sizeBytes: Int, file: URL, onMinted: @escaping @MainActor (String) -> Void,
                                 onProgress: @escaping @MainActor (Double) -> Void) async -> UploadResult {
        do {
            let minted = try await supervisor.request("attachments.createUploadUrl", payload: .object([
                "type": .string(type), "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))]))
            guard case .string(let attachmentId)? = minted["attachmentId"], case .string(let relative)? = minted["relativeUrl"],
                  let url = URL(string: relative, relativeTo: base)?.absoluteURL else { return .failed("Upload failed") }
            if Task.isCancelled {
                _ = try? await supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(attachmentId)]))
                return .cancelled
            }
            await onMinted(attachmentId)
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            let progress = UploadProgress { p in Task { @MainActor in onProgress(p) } }
            let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: progress)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failed("Upload rejected (\(status))") }
            return .uploaded(attachmentId)
        } catch let error as URLError where error.code == .timedOut {
            return .failed("Upload timed out")
        } catch {
            return Task.isCancelled ? .cancelled : .failed("Upload failed")
        }
    }

    fileprivate func setUpAttachments() {
        composer.onFiles = { [weak self] files in self?.addFiles(files) }
        composer.onPullRequestDropped = { [weak self] pr in
            guard let self else { return false }
            let reference = ComposerContext.pullRequestReference(pr)
            let previous = self.menuState.records[reference.contextId]
            self.menuState.records[reference.contextId] = ComposerContext.pullRequestRecord(pr)
            guard self.composer.insertMentionAtEnd(ComposerContext.reference(reference)) else {
                self.menuState.records[reference.contextId] = previous
                return false
            }
            return true
        }
        composer.onThreadsDropped = { [weak self] ids in self?.dropThreads(ids) ?? false }
        composer.onPasteText = { [weak self] text, bypass in self?.foldPastedText(text, bypass: bypass) ?? false }
        composer.pasteDirectory = Self.attachmentWorkDirectory
        composer.imageShelf.onRemove = { [weak self] id in self?.removeImage(id) }
        composer.imageShelf.onRetry = { [weak self] id in self?.retryAttachment(id) }
        composer.onOpenChip = { [weak self] source in
            guard let self, let token = ComposerInlineTokens.collect(source + " ").first,
                  case .context(_, let contextId, _) = token.kind,
                  let attachment = self.currentAttachments.first(where: { $0.contextId == contextId }) else { return false }
            // A file to attach again has nothing to open (composerContextPresentation.tsx:237-242).
            if attachment.needsReattach { return true }
            if attachment.kind == .image { self.expandDraftImage(attachment.id) }
            else { self.expandDraftFile(attachment) }
            return true
        }
        composer.imageShelf.onExpand = { [weak self] id in self?.expandDraftImage(id) }
        panel.model.onOpenAttachment = { [weak self] file, download in self?.openSentAttachment(file, download: download) }
        panel.model.onRollbackCheckpoint = { [weak self] checkpoint, scope in self?.rollBack(checkpointId: checkpoint, scopeId: scope) }
        panel.model.attachmentMediaURL = { [weak self] id in
            await self?.mediaAttachmentURL(id)
        }
        panel.model.attachmentImage = { [weak self] id, side, cover in
            guard let source = await self?.attachmentSource(id) else { return nil }
            return await ComposerImageIO.thumbnail(source, side: side, cover: cover, measurementKey: id)
        }
        panel.model.onExpandImage = { [weak self] items, index in self?.presentPreview(items, index: index) }
        panel.stashBadge.onToggleMenu = { [weak self] in self?.toggleStashMenu() }
        panel.lazyStashMenu.configure { [weak self] menu in
            menu.imageURL = { [weak self] image in self?.stash.imageURL(image) ?? URL(fileURLWithPath: "/") }
            menu.onRestore = { [weak self] entry in self?.restoreStash(entry) }
            menu.onDelete = { [weak self] entry in self?.deleteStash(entry) }
            menu.onClose = { [weak self] in self?.setStashMenu(false) }
            menu.shortcutLabel = ActiveKeymap.label(for: "composer.stash")
        }
        stash.onChange = { [weak self] in self?.syncStashViews() }
        syncStashViews()
    }

    var currentAttachments: [ComposerAttachment] { draftKey.flatMap { draftAttachments[$0] } ?? [] }

    /// The composer shows another thread or draft.
    fileprivate func attachmentsTargetChanged() {
        if panel.stashMenuOpen { setStashMenu(false) }
        let key = draftKey ?? ""
        var phase: ComposerActivityRowView.Phase?
        if case .thread = target { phase = .loading }
        updateSyncPhase(phase, key: key)
        syncAttachmentViews()
    }

    /// The server claimed the uploads. Local captures no longer back a draft.
    private func sentSnapShots(_ attachments: [ComposerAttachment]) {
        SnapShotPendingCapture.removeDeliveredFiles(attachments)
        for attachment in attachments where attachment.snapShotSource != nil {
            if let id = attachment.attachmentId { sentFiles[id] = nil }
        }
        persistDraftAttachments()
    }

    private static let draftAttachmentsKey = "composer.draftAttachments.v1"
    /// Copies of draft images the app owns, per bundle id so test builds keep their own.
    static var draftCopyDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent(Bundle.main.bundleIdentifier ?? "CandyWrapper")
            .appendingPathComponent("DraftAttachments", isDirectory: true)
    }

    /// Puts back the attachments saved with the drafts (`toHydratedThreadDraft`, composerDraftStore.ts:2510-2546),
    /// then deletes image copies no draft holds any more (sent, stashed or dropped while the app ran).
    private func restoreDraftAttachments(_ defaults: UserDefaults) {
        var records = defaults.data(forKey: Self.draftAttachmentsKey).flatMap { try? JSONDecoder().decode([DraftAttachmentRecord].self, from: $0) }
        if records == nil, let data = defaults.data(forKey: "snapShotPending.v1"),
           let captures = try? JSONDecoder().decode([SnapShotPendingCapture].self, from: data) {
            records = captures.map(DraftAttachmentRecord.init(capture:))
        }
        for record in records ?? [] {
            guard let (attachment, pending) = record.restore(fileExists: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            draftAttachments[record.draftKey, default: []].append(attachment)
            if pending != .reattach { restoredUploads[attachment.id] = pending }
            if pending == .verify { unverifiedUploads.insert(attachment.id) }
        }
        let kept = Set(draftAttachments.values.joined().map { $0.fileURL.standardizedFileURL.path })
        let directory = Self.draftCopyDirectory
        Task.detached(priority: .utility) {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where !kept.contains(url.standardizedFileURL.path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Saves every draft's attachments. An image gets a copy the app owns first (APFS clones it), since its
    /// file may be a temporary one or the user's own, which can move.
    private func persistDraftAttachments() {
        var records: [DraftAttachmentRecord] = []
        let directory = Self.draftCopyDirectory
        for key in draftAttachments.keys.sorted() {
            guard var attachments = draftAttachments[key] else { continue }
            var copied = false
            for i in attachments.indices {
                let a = attachments[i]
                if a.kind == .image, a.snapShotSource == nil, a.fileURL.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL {
                    let copy = directory.appendingPathComponent(a.id + "-" + a.fileURL.lastPathComponent)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if (try? FileManager.default.copyItem(at: a.fileURL, to: copy)) != nil {
                        attachments[i].fileURL = copy; copied = true
                    }
                }
                records.append(DraftAttachmentRecord(draftKey: key, attachment: attachments[i]))
                if unverifiedUploads.contains(a.id), let id = a.attachmentId { records[records.count - 1].attachmentId = id }
            }
            if copied { draftAttachments[key] = attachments }
        }
        guard records != savedDraftAttachments else { return }
        savedDraftAttachments = records
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.draftAttachmentsKey)
            UserDefaults.standard.removeObject(forKey: "snapShotPending.v1")
        }
    }

    /// `verifyPersistedAttachmentUpload` (packages/client-runtime/src/state/attachments.ts:61-93, attachmentUploadQueue.ts:193-230):
    /// a restored file's upload is ready when the server still mints a URL for it. Pending uploads are swept after
    /// 24 hours, so a missing one asks for the file again; a failed check is retried.
    private func verifyRestoredUpload(_ id: String, key: String) {
        guard let a = draftAttachments[key]?.first(where: { $0.id == id }), let attachmentId = a.attachmentId,
              let shell = environments.session(a.environmentId) else { return }
        let supervisor = shell.supervisor
        updateAttachment(id, key: key) { $0.status = .uploading(0) }
        attachmentTasks[id]?.cancel()
        attachmentTasks[id] = Task { [weak self] in
            var missing = false, failed = false
            do {
                _ = try await supervisor.request("assets.createUrl", payload: .object([
                    "resource": .object(["_tag": .string("attachment"), "attachmentId": .string(attachmentId)])]))
            } catch let error as RPCClientError where error.typedError?.tag == "AssetAttachmentNotFoundError" {
                missing = true
            } catch {
                failed = true
            }
            guard let self, !Task.isCancelled else { return }
            attachmentTasks[id] = nil
            if failed {
                // Checked again on the next connection or by Retry.
                restoredUploads[id] = .verify
                updateAttachment(id, key: key) { $0.status = .failed("Upload failed") }
                return
            }
            unverifiedUploads.remove(id)
            updateAttachment(id, key: key) { a in
                if missing { a.attachmentId = nil; a.needsReattach = true; a.status = .failed("Attach the file again") } else { a.status = .ready }
            }
        }
    }

    fileprivate func syncAttachmentViews() {
        persistDraftAttachments()
        let attachments = currentAttachments
        let hidden = questionRequestId != nil
        composer.imageTiles = hidden ? [] : attachments.filter { $0.kind == .image }.map {
            ComposerImageShelfView.Tile(id: $0.id, name: $0.name, status: $0.status, fileURL: $0.fileURL, source: $0.snapShotSource)
        }
        composer.attachmentCount = questionRequestId == nil ? attachments.count : 0
        if attachments != chipAttachments {
            chipAttachments = attachments
            composer.refreshChips()
        }
        syncStashViews()
    }

    private func updateAttachment(_ id: String, key: String, _ change: (inout ComposerAttachment) -> Void) {
        guard let i = draftAttachments[key]?.firstIndex(where: { $0.id == id }) else { return }
        change(&draftAttachments[key]![i])
        persistDraftAttachments()
        if key == draftKey { refresh() }
    }

    /// The paperclip: a question's answer takes the files while one is open, else the draft does.
    fileprivate func attachPressed() {
        if questionRequestId != nil { attachToQuestion(); return }
        if ThemeRuntime.isDither(dark: composer.effectiveAppearance.isDark) { openPlusMenu(); return }
        pickFiles()
    }

    /// Redesign's "+" menu, after Capy's: attach, then what the `@`, `#` and `$` menus insert, each hinted by
    /// its trigger. Capy's side threads, environment variables, people, subagents and devices have no
    /// composer action here, so they stay out.
    private func openPlusMenu() {
        func trigger(_ text: String, threads: Bool = false) -> @MainActor () -> Void {
            { [weak self] in
                guard let self else { return }
                composer.focus()
                browsingThreads = threads
                composer.insertAtCaret(text)
            }
        }
        var items = [ComposerPlusMenuItem("Upload attachment", icon: .paperclip) { [weak self] in self?.pickFiles() }]
        items.append(ComposerPlusMenuItem("Threads", icon: .messagesSquare, shortcut: "@", startsGroup: true, action: trigger("@", threads: true)))
        if menuProject != nil { items.append(ComposerPlusMenuItem("Pull requests", icon: .gitPullRequestArrow, shortcut: "#", action: trigger("#"))) }
        if menuProvider?.skills(cwd: menuCwd).isEmpty == false {
            items.append(ComposerPlusMenuItem("Skills", icon: .package, shortcut: "$", action: trigger("$")))
        }
        items.append(ComposerPlusMenuItem("Files", icon: .file, shortcut: "@", action: trigger("@")))
        ComposerPlusMenu.toggle(from: composer.attach, items: items)
    }

    private func pickFiles() {
        guard let window = composer.window, target != nil else { return }
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = picker.urls
            MainActor.assumeIsolated { self?.addFiles(urls.map { ComposerIncomingFile(url: $0) }) }
        }
    }

    /// `addComposerAttachments`: count, type and size checks in order, so concurrent adds see each
    /// other's slots; files get a chip at the caret and upload at once; images are prepared off the
    /// main thread first and get a chip only when the prompt already has prose.
    /// Files dropped on the open thread's sidebar row (`consumePendingFileDrop`, ChatView.tsx:10930-10950).
    func attachDroppedFiles(_ urls: [URL]) { addFiles(urls.map { ComposerIncomingFile(url: $0) }) }

    /// `resolveTarget` (SnapShotCoordinator.tsx:52-71, 251-299): the thread or draft on screen, or the thread
    /// a sent draft became, else the open project's draft (`handleNewThread`, which opens it). Nil without a project.
    /// `question` pins the open question that takes SnapShots at capture start, so a question that opens
    /// later never claims the capture (`resolveSnapShotAttachmentTarget`, SnapShotCoordinator.tsx:73-83).
    var snapShotDestination: (key: String, environment: String, question: String?)? {
        switch target {
        case .thread(let id):
            if let env = id.environmentId { return (id.rawValue, env, snapShotQuestionKey) }
        case .draft(let s):
            guard let env = ThreadId(s.threadId).environmentId else { break }
            if sessions.values.contains(where: { $0.draftId == s.draftId }) { return (s.draftId, env, nil) }
            if sidebar?.snapshot?.threads.contains(where: { $0.id.rawValue == s.threadId }) == true { return (s.threadId, env, nil) }
        case nil: break
        }
        guard newThread(), case .draft(let session) = target, let env = targetEnvironmentId else { return nil }
        return (session.draftId, env, nil)
    }

    /// The open question's key while it takes SnapShots (`questionTakesSnapShots`, ChatComposer.tsx:1715-1742).
    private var snapShotQuestionKey: String? {
        guard supportsQuestionAttachments, let requestId = questionRequestId, !responding.contains(requestId),
              panel.lazyQuestionPanel.loaded?.session?.progress.activeQuestion?.allowsCustomAnswer != false else { return nil }
        return activeQuestionKey
    }

    /// The capture's draft or thread comes forward after delivery, so its tile is on screen.
    func showSnapShotTarget(_ key: String) {
        guard draftKey != key else { return }
        if sessions.values.contains(where: { $0.draftId == key }) { sidebar?.actions.openDraft(key) } else { openThread?(ThreadId(key)) }
    }

    func snapShotFrame(id: String, key: String) -> CGRect? {
        guard draftKey == key, let window = composer.window else { return nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let shelf = composer.imageShelf
        guard let index = shelf.tiles.firstIndex(where: { $0.id == id }), shelf.subviews.indices.contains(index) else { return nil }
        let tile = shelf.subviews[index]
        return window.convertToScreen(tile.convert(tile.bounds, to: nil))
    }

    /// Preserve the draft selected at capture start even if navigation changes during ScreenCaptureKit.
    func attachSnapShot(_ data: Data, source: JSONValue? = nil, destination: (key: String, environment: String, question: String?)) async throws -> String {
        let key = destination.key, env = destination.environment
        let composerFull = { (self.draftAttachments[key]?.count ?? 0) + (self.preparingImages[key] ?? 0) >= ComposerAttachmentRules.maxAttachments }
        guard destination.question != nil || !composerFull() else { throw CancellationError() }
        preparingImages[key, default: 0] += 1
        defer { preparingImages[key, default: 1] -= 1 }
        // The pinned question gets the capture while it is still the open one (SnapShotCoordinator.tsx:175-197).
        var question: (key: String, requestId: String)? {
            guard let pinned = destination.question, pinned == snapShotQuestionKey, draftKey == key,
                  let requestId = questionRequestId else { return nil }
            return (pinned, requestId)
        }
        let work = URL.applicationSupportDirectory.appendingPathComponent(Bundle.main.bundleIdentifier ?? "CandyWrapper").appendingPathComponent("SnapShots")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = work.appendingPathComponent("snapshot-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        var keepsSource = false
        defer { if !keepsSource { try? FileManager.default.removeItem(at: url) } }
        let prepared = try await ComposerImageIO.prepare(url, name: "Snapshot.png", mimeType: "image/png",
                                                        maxBytes: ComposerAttachmentRules.maxImageBytes, workDir: work)
        keepsSource = prepared.url == url
        let snapShotSource = source.flatMap { source in
            ComposerImageIO.pixelSize(prepared.url).map { SnapShotSource.resized(source, width: Int($0.width), height: Int($0.height)) }
        }
        if let question {
            // Only question drafts skip the composer's own attachment checks; the request's cap still holds.
            guard questionRequestAttachmentCount(question.requestId) < Self.maxQuestionAttachments else {
                try? FileManager.default.removeItem(at: prepared.url)
                throw CancellationError()
            }
            var file = QuestionFile(id: UUID().uuidString, url: prepared.url, name: prepared.name, mimeType: prepared.mimeType,
                                    sizeBytes: prepared.sizeBytes, status: .uploading(0))
            file.snapShot = true
            file.snapShotSource = snapShotSource
            questionFiles[question.key, default: []].append(file)
            upload(file.id, key: question.key)
            syncQuestion()
            return file.id
        }
        // A question that closed during the capture hands it back to the composer, under the composer's cap.
        if destination.question != nil, (draftAttachments[key]?.count ?? 0) + (preparingImages[key] ?? 0) > ComposerAttachmentRules.maxAttachments {
            try? FileManager.default.removeItem(at: prepared.url)
            throw CancellationError()
        }
        var attachment = ComposerAttachment(kind: .image, name: prepared.name, mimeType: prepared.mimeType,
                                            sizeBytes: prepared.sizeBytes, fileURL: prepared.url, environmentId: env)
        attachment.snapShotSource = snapShotSource
        draftAttachments[key, default: []].append(attachment)
        persistDraftAttachments()
        startUpload(attachment.id, key: key)
        refresh()
        return attachment.id
    }

    /// Sidebar threads dropped on the composer (ChatComposer.tsx:6245-6267): threads from another
    /// environment are refused; the rest become thread context references at the caret, once each.
    func dropThreads(_ ids: [ThreadId]) -> Bool {
        guard let env = targetEnvironmentId, !ids.isEmpty else { return false }
        if ids.contains(where: { $0.environmentId != env }) {
            _ = panel.toasts.show(ToastView(title: "Use threads from this environment",
                                            message: "The agent can only read threads on its own server.", kind: .error))
            return true
        }
        var known = Set(ComposerContext.referencedIds(composer.text))
        var references: [String] = []
        for id in ids {
            guard let shell = sidebar?.snapshot?.threads.first(where: { $0.id == id }) else { continue }
            let local = id.localId.rawValue
            let record = ComposerContext.threadRecord(threadId: local, title: shell.title, environmentId: env)
            guard let contextId = record["contextId"]?.stringValue, known.insert(contextId).inserted else { continue }
            menuState.records[contextId] = record
            references.append(ComposerContext.reference(ComposerContext.threadReference(threadId: local, title: shell.title)))
        }
        guard !references.isEmpty else { return true }
        // An open question takes the chips into its answer, when it takes typed text (T3 3105 34f845832).
        if questionRequestId != nil, !panel.questionPanel.editorEnabled || panel.questionPanel.isResponding || shell == nil {
            _ = panel.toasts.show(ToastView(title: "Unable to add thread", message: "The composer is busy; try again once it is ready.", kind: .error))
            return true
        }
        composer.insertAtCaret(references.joined(separator: " ") + " ")
        composer.focus()
        return true
    }

    /// "Add to chat" from a terminal (`addTerminalContext`, ChatComposer.tsx:6502-6533): a new
    /// excerpt record and its chip at the caret. An open question takes no context.
    func addReviewComment(_ record: JSONValue) {
        guard target != nil, questionRequestId == nil, let id = record["contextId"]?.stringValue else { return }
        let exists = ComposerContext.referencedIds(composer.text).contains(id)
        menuState.records[id] = record
        if exists { remember(composer.text); return }
        composer.insertAtCaret(ComposerContext.reference(ComposerContext.Reference(kind: "review-comment", contextId: id, label: record["label"]?.stringValue ?? "Comment")) + " ")
        if !panel.rightPanelSheetOpen { focusComposer() }
    }

    /// A moved file comment's new lines; one whose chip the user already removed stays removed.
    func updateReviewComment(_ record: JSONValue) {
        guard let id = record["contextId"]?.stringValue, ComposerContext.referencedIds(composer.text).contains(id) else { return }
        menuState.records[id] = record
        remember(composer.text)
    }

    func deleteReviewComment(_ id: String) {
        composer.text = Self.removingReferences(to: id, in: composer.text)
        menuState.records.removeValue(forKey: id)
        remember(composer.text)
    }

    func addTerminalContext(_ selection: ComposerContext.TerminalSelection) {
        guard target != nil, questionRequestId == nil else { return }
        let id = UUID().uuidString.lowercased()
        let record = ComposerContext.terminalRecord(id: id, selection)
        guard let contextId = record["contextId"]?.stringValue else { return }
        menuState.records[contextId] = record
        composer.insertAtCaret(ComposerContext.reference(ComposerContext.terminalReference(id: id, selection)) + " ")
        // After the terminal takes focus back (T3 focuses the editor on the next frame).
        focusComposer()
    }

    fileprivate func addFiles(_ files: [ComposerIncomingFile], pastedText: Bool = false) {
        guard !files.isEmpty, let key = draftKey, let env = targetEnvironmentId else { return }
        if questionRequestId != nil {
            guard let requestId = questionRequestId, let questionKey = activeQuestionKey, supportsQuestionAttachments,
                  panel.lazyQuestionPanel.loaded?.session?.progress.activeQuestion?.allowsCustomAnswer == true, !responding.contains(requestId) else {
                _ = panel.toasts.show(ToastView(title: "This question cannot accept attachments.", kind: .error))
                return
            }
            addQuestionFiles(files.map(\.url), key: questionKey, requestId: requestId)
            return
        }
        let imagesGetChips = !ComposerContext.stripReferences(composer.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var reserved = (draftAttachments[key]?.count ?? 0) + (preparingImages[key] ?? 0)
        let limit = ComposerAttachmentRules.stagingLimit(capabilityKnown: capabilities[env] != nil, maxUploadBytes: capabilities[env]?.uploadLimit)
        var images: [ComposerIncomingFile] = [], accepted: [ComposerAttachment] = []
        var reattached: [String] = []
        var error: String?
        // `addComposerFolders` (ChatComposer.tsx:5136-5173): dropped or pasted folders become file links at
        // the end, local environment only. A file URL always has a path and the editor is never busy, so
        // T3's other two toasts can't happen here.
        let isFolder = { (file: ComposerIncomingFile) in (try? file.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let folders = files.filter(isFolder)
        if !folders.isEmpty {
            if env != environments.primaryId {
                _ = panel.toasts.show(ToastView(title: "Folders can only be referenced in the local desktop environment", kind: .error))
            } else {
                for folder in folders {
                    let separator = composer.text.isEmpty || composer.text.last?.isWhitespace == true ? "" : " "
                    composer.text += separator + ComposerInlineTokens.fileLink(folder.url.path) + " "
                }
                prompts[key] = composer.text; scheduleSave()
            }
            focusComposer()
        }
        for file in files where !isFolder(file) {
            if reserved >= ComposerAttachmentRules.maxAttachments { error = ComposerAttachmentRules.countMessage; continue }
            switch ComposerAttachmentRules.classify(name: file.name, mimeType: file.mimeType) {
            case .unsupportedImage:
                error = ComposerAttachmentRules.unsupportedImageMessage(file.name)
                continue
            case .image:
                var image = file
                if let inferred = ComposerAttachmentRules.inferImageMimeType(name: file.name),
                   file.mimeType.isEmpty || file.mimeType == "application/octet-stream" { image.mimeType = inferred }
                images.append(image)
            case .file:
                guard let limit else { error = "This server does not support file attachments."; continue }
                let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])).flatMap { $0.isDirectory == true ? 0 : $0.fileSize } ?? 0
                if size <= 0 { error = "'\(file.name)' is empty or could not be read."; continue }
                if size > limit { error = ComposerAttachmentRules.tooLargeMessage(file.name, limit); continue }
                // The same file again replaces its attach-again marker in place, chip and all (composerDraftStore.ts:3530-3560).
                if let i = draftAttachments[key]?.firstIndex(where: {
                    $0.needsReattach && !reattached.contains($0.id)
                        && ComposerAttachmentRules.matchesReattachMarker($0, name: file.name, mimeType: file.mimeType, sizeBytes: size)
                }) {
                    draftAttachments[key]![i].needsReattach = false
                    draftAttachments[key]![i].fileURL = file.url
                    draftAttachments[key]![i].mimeType = file.mimeType
                    draftAttachments[key]![i].status = .uploading(0)
                    draftAttachments[key]![i].environmentId = env
                    reattached.append(draftAttachments[key]![i].id)
                    continue
                }
                var attachment = ComposerAttachment(kind: .file, name: file.name, mimeType: file.mimeType, sizeBytes: size,
                                                    fileURL: file.url, environmentId: env)
                attachment.pastedText = pastedText
                accepted.append(attachment)
            }
            reserved += 1
        }
        threadErrors.set(key, error)
        for id in reattached { startUpload(id, key: key) }
        if !accepted.isEmpty {
            draftAttachments[key, default: []] += accepted
            composer.insertAtCaret(accepted.map(\.reference).joined(separator: " ") + " ")
            for a in accepted { startUpload(a.id, key: key) }
            if pastedText, let first = accepted.first {
                toast(.info, "Large paste attached as \(first.name)",
                      "\(ComposerFileRow.formatSize(first.sizeBytes)) · Use ⌘⇧V to keep a large paste inline.")
            }
        }
        refresh()
        guard !images.isEmpty else { return }
        preparingImages[key, default: 0] += images.count
        let work = Self.attachmentWorkDirectory
        Task { [weak self] in
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            var prepared: [ComposerAttachment] = []
            var failure: String?
            for image in images {
                do {
                    let p = try await ComposerImageIO.prepare(image.url, name: image.name, mimeType: image.mimeType,
                                                              maxBytes: ComposerAttachmentRules.maxImageBytes, workDir: work)
                    prepared.append(ComposerAttachment(kind: .image, name: p.name, mimeType: p.mimeType, sizeBytes: p.sizeBytes,
                                                       fileURL: p.url, environmentId: env))
                } catch ComposerImageIO.PrepareFailure.unreadable {
                    failure = "'\(image.name)' could not be read as an image."
                } catch {
                    failure = "'\(image.name)' is too large to attach, even after compression."
                }
            }
            guard let self else { return }
            preparingImages[key, default: images.count] -= images.count
            draftAttachments[key, default: []] += prepared
            if imagesGetChips, key == draftKey, !prepared.isEmpty {
                composer.insertAtCaret(prepared.map(\.reference).joined(separator: " ") + " ")
            }
            for a in prepared { startUpload(a.id, key: key) }
            // Only failures are reported here, so a later error is never cleared by this one.
            if let failure { threadErrors.set(key, failure) }
            refresh()
        }
    }

    /// `foldPastedText` (ChatComposer.tsx:6033-6110): a large paste becomes `pasted-text.txt`, uploaded
    /// like any file, with a chip where the text would have gone. Question answers keep their text.
    fileprivate func foldPastedText(_ text: String, bypass: Bool) -> Bool {
        guard questionRequestId == nil, let key = draftKey, let env = targetEnvironmentId else { return false }
        let wouldExceed = ComposerAttachmentRules.pasteWouldExceedLimit(promptLength: composer.text.utf16.count,
                                                                        selectedLength: composer.selectedPromptLength, textLength: text.utf16.count)
        guard ComposerAttachmentRules.foldsPastedText(text, bypass: bypass, wouldExceedLimit: wouldExceed) else { return false }
        let limit = ComposerAttachmentRules.stagingLimit(capabilityKnown: capabilities[env] != nil, maxUploadBytes: capabilities[env]?.uploadLimit)
        let hasSlot = (draftAttachments[key]?.count ?? 0) + (preparingImages[key] ?? 0) < ComposerAttachmentRules.maxAttachments
        guard hasSlot, let limit else {
            if !wouldExceed { return false }
            toast(.error, "Pasted text is too large for this message", "Remove some text or an attachment, then paste again.")
            return true
        }
        let name = ComposerAttachmentRules.nextPastedTextFileName((draftAttachments[key] ?? []).map(\.name))
        let data = Data(text.utf8)
        if data.count > limit {
            if !wouldExceed { return false }
            toast(.error, "Pasted text is too large to attach", "Reduce the clipboard contents or save a smaller excerpt as a file.")
            return true
        }
        let dir = Self.attachmentWorkDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return false
        }
        addFiles([ComposerIncomingFile(url: url, name: name, mimeType: "text/plain;charset=utf-8")], pastedText: true)
        return true
    }

    private func startUpload(_ id: String, key: String) {
        guard let a = draftAttachments[key]?.first(where: { $0.id == id }) else { return }
        guard let shell = environments.session(a.environmentId) else {
            updateAttachment(id, key: key) { $0.status = .failed("This connection cannot upload attachments.") }
            return
        }
        attachmentTasks[id]?.cancel()
        attachmentTasks[id] = Task { [weak self] in
            let result = await Self.uploadAttachment(
                supervisor: shell.supervisor, base: shell.http.baseURL, type: a.kind.rawValue, name: a.name, mimeType: a.mimeType,
                sizeBytes: a.sizeBytes, file: a.fileURL,
                onMinted: { minted in self?.updateAttachment(id, key: key) { $0.attachmentId = minted } },
                onProgress: { p in
                    self?.updateAttachment(id, key: key) { f in
                        if case .uploading(let old) = f.status, Int(old * 20) == Int(p * 20) { return }
                        f.status = .uploading(p)
                    }
                })
            guard let self else { return }
            attachmentTasks[id] = nil
            switch result {
            case .uploaded: updateAttachment(id, key: key) { $0.status = .ready }
            case .failed(let reason): updateAttachment(id, key: key) { $0.status = .failed(reason) }
            case .cancelled: break
            }
            resumeSendAfterRetry(key)
        }
    }

    /// Sends the retried message once no upload runs. A retry that failed again keeps the draft.
    private func resumeSendAfterRetry(_ key: String) {
        guard let pending = sendAfterRetry[key], let list = draftAttachments[key] else { sendAfterRetry[key] = nil; return }
        if list.contains(where: { if case .uploading = $0.status { true } else { false } }) { return }
        sendAfterRetry[key] = nil
        guard key == draftKey else { return }
        guard ComposerAttachmentRules.retryableFailures(list).isEmpty else {
            // ChatView.tsx:5131-5135: the retry failed again, so the draft stays and says why.
            threadErrors.set(key, "Retry or remove failed uploads before sending.")
            refresh()
            return
        }
        send(pending.text, mode: pending.mode, background: pending.background)
    }

    /// Cancels an upload and deletes its pending server copy (`releaseDraftAttachment`).
    private func release(_ a: ComposerAttachment) {
        attachmentTasks.removeValue(forKey: a.id)?.cancel()
        guard let id = a.attachmentId, let shell = environments.session(a.environmentId) else { return }
        let supervisor = shell.supervisor
        Task { _ = try? await supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(id)])) }
    }

    /// `retryAttachmentUpload`.
    private func retryAttachment(_ id: String) {
        guard let key = draftKey, let a = draftAttachments[key]?.first(where: { $0.id == id }), !a.needsReattach else { return }
        if unverifiedUploads.contains(id) {
            restoredUploads[id] = nil
            verifyRestoredUpload(id, key: key)
            return
        }
        release(a)
        updateAttachment(id, key: key) { $0.attachmentId = nil; $0.status = .uploading(0) }
        startUpload(id, key: key)
    }

    /// Files exist only as chips: deleting a file's last chip removes the file (docs/user/composer.md).
    fileprivate func pruneUnreferencedFiles(_ text: String, key: String) {
        guard let attachments = draftAttachments[key], attachments.contains(where: { $0.kind == .file }) else { return }
        let referenced = Set(ComposerContext.referencedIds(text))
        let gone = attachments.filter { $0.kind == .file && !referenced.contains($0.contextId) }
        guard !gone.isEmpty else { return }
        gone.forEach(release)
        draftAttachments[key] = attachments.filter { a in !gone.contains { $0.id == a.id } }
    }

    /// `removeComposerImage`: asks first when the text still mentions the image, then removes it
    /// with every chip that points at it.
    private func removeImage(_ id: String) {
        guard let key = draftKey, let image = draftAttachments[key]?.first(where: { $0.id == id }) else { return }
        let remove = { [weak self] in
            guard let self, let image = draftAttachments[key]?.first(where: { $0.id == id }) else { return }
            release(image)
            draftAttachments[key]?.removeAll { $0.id == id }
            if image.snapShotSource != nil || image.fileURL.deletingLastPathComponent().standardizedFileURL == Self.draftCopyDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: image.fileURL)
            }
            persistDraftAttachments()
            if key == draftKey, ComposerContext.referencedIds(composer.text).contains(image.contextId) {
                composer.text = Self.removingReferences(to: image.contextId, in: composer.text)
                remember(composer.text)
            }
            refresh()
        }
        guard ComposerContext.referencedIds(composer.text).contains(image.contextId), let window = composer.window else { return remove() }
        let alert = NSAlert()
        alert.messageText = "Remove \(image.name) from the message?"
        alert.informativeText = "It is referenced in your text; removing it also removes every reference."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { MainActor.assumeIsolated { remove() } }
        }
    }

    /// The prompt without the links to `contextId` (`removeInlineContextReference`).
    static func removingReferences(to contextId: String, in prompt: String) -> String {
        let ns = NSMutableString(string: prompt)
        for t in ComposerInlineTokens.collect(prompt).reversed() {
            if case .context(_, let id, _) = t.kind, id == contextId { ns.replaceCharacters(in: t.range, with: "") }
        }
        return ns as String
    }

    /// A failed send puts its attachments back when the draft took no new ones meanwhile.
    fileprivate func restoreAttachments(_ attachments: [ComposerAttachment], key: String?) {
        guard let key, !attachments.isEmpty, draftAttachments[key]?.isEmpty ?? true else { return }
        draftAttachments[key] = attachments
        refresh()
    }

    /// The chip for an attachment link: its icon, middle-truncated name and size, and the upload state.
    fileprivate func attachmentChipLook(kind: String, contextId: String, label: String) -> ComposerChipLook? {
        guard kind == "image" || kind == "file", let a = currentAttachments.first(where: { $0.contextId == contextId }) else { return nil }
        var detail = ComposerFileRow.formatSize(a.sizeBytes)
        // FileContextChip (composerContextPresentation.tsx:217-247): "attach again" on a dashed chip, a failed
        // upload in the destructive colors.
        var state: ComposerChipLook.State?
        if a.needsReattach {
            detail += " attach again"; state = .unresolved
        } else if case .uploading(let p) = a.status {
            detail += " " + ComposerFileRow.formatProgress(p)
        } else if case .failed = a.status {
            detail += " upload failed"; state = .invalid
        }
        return ComposerChipLook(kind: a.kind == .image ? .image : .file(name: a.name),
                                label: ComposerAttachmentRules.middleTruncate(a.name), detail: detail, state: state)
    }

    // MARK: Previews

    /// MessagesTimeline.tsx:2453-2490: Preview opens the file in the right panel as an attachment tab
    /// (`openAttachment`, rightPanelStore.ts:725-736); Download asks where to save it.
    private func openSentAttachment(_ file: JSONValue, download: Bool) {
        guard let id = file["id"]?.stringValue, file["downloadable"]?.boolValue != false, let window = panel.window else { return }
        let name = file["name"]?.stringValue ?? "Attachment"
        if !download {
            let surface = SentAttachmentSurface(id: id, name: name, mimeType: file["mimeType"]?.stringValue ?? "",
                                                sizeBytes: file["sizeBytes"]?.intValue ?? 0, htmlRender: file["htmlRender"]?.boolValue == true)
            panel.mutatePanel { $0.openAttachment(surface); return [] }
            return
        }
        let target = self.target
        Task { [weak self, weak window] in
            guard let self, let source = await attachmentSource(id), self.target == target, let window else { return }
            self.saveCopy(of: source, name: name, in: window)
        }
    }

    /// Saves a local copy where the user picks (the browser's download of the attachment).
    private func saveCopy(of source: URL, name: String, in window: NSWindow) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: source)
                        try data.write(to: url, options: .atomic)
                    }.value
                } catch { self?.toast(.error, "Could not save file", error.localizedDescription) }
            }
        }
    }

    /// The draft file preview dialog (ChatComposer.tsx:7399-7434): `Draft › name`, Remove drops the file.
    private func expandDraftFile(_ attachment: ComposerAttachment) {
        guard let window = panel.window else { return }
        var host: ModalHost?
        let preview = ComposerAttachmentPreview(
            name: attachment.name, file: attachment.fileURL, sizeBytes: attachment.sizeBytes,
            onSave: { [weak self, weak window] in
                guard let window else { return }
                self?.saveCopy(of: attachment.fileURL, name: attachment.name, in: window)
            },
            onRemove: { [weak self] in
                guard let self else { return }
                self.composer.text = Self.removingReferences(to: attachment.contextId, in: self.composer.text)
                host?.close()
            },
            onClose: { host?.close() })
        host = ComposerAttachmentPreview.present(preview, in: window)
    }

    /// A question answer's file opens the same dialog (its draft is the question's, ChatComposer.tsx:1829-1848).
    fileprivate func expandQuestionFile(_ id: String) {
        guard let window = panel.window, let key = fileKey(id), let file = questionFiles[key]?.first(where: { $0.id == id }) else { return }
        var host: ModalHost?
        let preview = ComposerAttachmentPreview(
            name: file.name, file: file.url, sizeBytes: file.sizeBytes,
            onSave: { [weak self, weak window] in
                guard let window else { return }
                self?.saveCopy(of: file.url, name: file.name, in: window)
            },
            onRemove: { [weak self] in self?.removeQuestionFile(id); host?.close() },
            onClose: { host?.close() })
        host = ComposerAttachmentPreview.present(preview, in: window)
    }

    private func expandDraftImage(_ id: String) {
        let images = currentAttachments.filter { $0.kind == .image }
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let items = images.map { image in
            let url = image.fileURL
            let item = ExpandedImagePreviewView.Item(key: url.path, name: image.name, source: image.snapShotSource, cacheable: true) { side in
                await ComposerImageIO.thumbnail(url, side: side, cover: false, measurementKey: url.path)
            }
            return composer.imagePreviewItem(item, for: image.id)
        }
        presentPreview(items, index: index)
    }

    private func presentPreview(_ items: [ExpandedImagePreviewView.Item], index: Int) {
        guard let window = panel.window, !items.isEmpty else { return }
        ExpandedImagePreviewView(items: items, index: index).present(in: window)
    }

    /// A sent image's bytes on disk: the file it was sent from, else the server copy, fetched once
    /// through `assets.createUrl` (resource `attachment`) into the cache directory. T3 leans on the
    /// browser's cache for the same bytes (`private, max-age=3600`, apps/server/src/http.ts:420-423).
    fileprivate func attachmentSource(_ attachmentId: String) async -> URL? {
        if let local = sentFiles[attachmentId], FileManager.default.fileExists(atPath: local.path) { return local }
        let safe = attachmentId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let cached = Self.attachmentCacheDirectory.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        if let running = attachmentFetches[attachmentId] { return await running.value }
        guard case .thread(let threadId) = target, let shell = environments.session(threadId.environmentId) else { return nil }
        let supervisor = shell.supervisor, base = shell.http.baseURL
        let fetch = Task<URL?, Never> {
            do {
                ImageTiming.mark("fetch", attachmentId)
                await ImageTiming.simulateLink()
                let result = try await supervisor.request("assets.createUrl", payload: .object([
                    "resource": .object(["_tag": .string("attachment"), "attachmentId": .string(attachmentId)])]))
                guard case .string(let relative)? = result["relativeUrl"], let url = URL(string: relative, relativeTo: base)?.absoluteURL else { return nil }
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 else { return nil }
                if ImageTiming.slowLink != nil {
                    await ImageTiming.simulateLink(bytes: (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                ImageTiming.mark("fetched", attachmentId)
                try? FileManager.default.createDirectory(at: Self.attachmentCacheDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: temp, to: cached)
                return cached
            } catch {
                return nil
            }
        }
        attachmentFetches[attachmentId] = fetch
        let url = await fetch.value
        attachmentFetches[attachmentId] = nil
        return url
    }

    /// Keeps the fetched attachment copies under `limit` bytes, dropping the least recently read first.
    /// Runs once at launch, off the main thread.
    nonisolated static func pruneAttachmentCache(limit: Int = 512 << 20) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: attachmentCacheDirectory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, read: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.read < $1.read }
        for entry in entries where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Send blocks

    /// The send button's blocks (ChatView.tsx:11618-11632 and ChatComposer.tsx:2188-2193): the thread's
    /// reason, else the attachment upload's. A lost environment is separate (`isEnvironmentUnavailable`).
    private func syncSendBlock() {
        // `isEnvironmentUnavailable` covers a missing provider too (ChatComposer.tsx:7651-7655, ComposerPrimaryActions.tsx:290-291).
        composer.environmentUnavailable = !connected || noProviderAvailable
        composer.providerUnavailable = connected && noProviderAvailable
        var block = ComposerLogic.SendBlock(rewinding: threadRewindBusy, projectClone: projectCloneSendBlock)
        if case .thread(let id) = target {
            block.detailLoading = syncStatus.key == id.rawValue && syncStatus.value == .loading
            let setup = panel.timeline.worktreeSetup.snapshot.flatMap { $0.threadId == id.localId.rawValue ? $0 : nil }
            block.preparingWorktree = ComposerLogic.worktreeSetupBlocksSend(phase: setup?.phase, agentDone: setup?.agentStarted == true,
                                                                            runPreparing: projection?.runs.last?.status == .preparing)
        }
        composer.sendDisabledReason = !environments.canOperate(targetEnvironmentId) ? "This connection cannot change threads." // ChatView.tsx:11619-11620
            : block.reason ?? (questionRequestId == nil ? ComposerAttachmentRules.uploadBlockReason(currentAttachments) : nil)
    }

    /// Enter while the environment is down (ChatView.tsx:8797-8811): a warning toast in one of three
    /// slots, so repeated presses replace the oldest instead of piling up.
    fileprivate func toastEnvironmentUnavailable() {
        environmentToastIds.removeAll { panel.toasts.toast($0) == nil }
        if environmentToastIds.count >= 3 { panel.toasts.dismiss(environmentToastIds.removeFirst()) }
        environmentToastIds.append(panel.toasts.show(ToastView(title: "Not connected: message not sent",
            message: "Reconnecting to the environment. Try again once it is connected.", kind: .warning)))
    }

    // MARK: Thread sync row

    /// The thread store's status (`resolveThreadSyncPhase`): empty or synchronizing is "loading"
    /// without a projection and "syncing" with one.
    func threadStatusChanged(_ status: ThreadSyncStatus, threadId: ThreadId) {
        guard target == .thread(threadId) else { return }
        let phase: ComposerActivityRowView.Phase? = switch status {
        case .empty, .synchronizing: projection == nil ? .loading : .syncing
        case .live, .deleted: nil
        }
        updateSyncPhase(phase, key: threadId.rawValue)
        syncSendBlock()
        updateMeterSlot()
    }

    private func updateSyncPhase(_ phase: ComposerActivityRowView.Phase?, key: String) {
        if key != syncStatus.key {
            syncStatus.timer?.cancel()
            syncStatus = DelayedStatus(key: key)
        }
        syncStatus.value = phase
        func schedule(_ delay: TimeInterval, _ body: @escaping @MainActor (ComposerController) -> Void) {
            syncStatus.timer?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if let self { body(self) } } }
            syncStatus.timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        if let phase {
            if syncStatus.shown != nil {
                syncStatus.timer?.cancel()
                syncStatus.shown = phase
            } else if syncStatus.timer == nil {
                schedule(DelayedStatus.showDelay) { c in
                    c.syncStatus.timer = nil
                    guard let value = c.syncStatus.value else { return }
                    c.syncStatus.shown = value
                    c.syncStatus.shownAt = Date()
                    c.applySyncPhase()
                }
            }
        } else if syncStatus.shown != nil {
            let remaining = DelayedStatus.minVisible - Date().timeIntervalSince(syncStatus.shownAt)
            if remaining <= 0 {
                syncStatus.shown = nil
            } else {
                schedule(remaining) { c in
                    c.syncStatus.timer = nil
                    if c.syncStatus.value == nil { c.syncStatus.shown = nil; c.applySyncPhase() }
                }
            }
        } else {
            syncStatus.timer?.cancel()
            syncStatus.timer = nil
        }
        applySyncPhase()
    }

    private func applySyncPhase() {
        if let shown = syncStatus.shown { panel.activityRow.phase = shown }
        panel.showsActivity = syncStatus.shown != nil
    }

    // MARK: Prompt stash

    fileprivate func syncStashViews() {
        panel.stashBadge.count = stash.entries.count
        panel.showsStashBadge = !stash.entries.isEmpty && target != nil
        panel.stashBadge.menuOpen = panel.stashMenuOpen
        let label = ActiveKeymap.label(for: "composer.stash")
        if let menu = panel.lazyStashMenu.loaded {
            if menu.shortcutLabel != label { menu.shortcutLabel = label }
            menu.entries = stash.entries
        }
        if panel.stashMenuOpen, panel.menus.isOpen { setStashMenu(false) }
    }

    private func toggleStashMenu() { setStashMenu(!panel.stashMenuOpen) }

    /// Opens or closes the menu; while open, a click outside it or the badge closes it.
    fileprivate func setStashMenu(_ open: Bool) {
        guard open != panel.stashMenuOpen else { return }
        panel.stashMenuOpen = open
        panel.stashBadge.menuOpen = open
        if let monitor = stashKeyMonitor { NSEvent.removeMonitor(monitor); stashKeyMonitor = nil }
        guard open else { return }
        panel.stashMenu.entries = stash.entries
        panel.stashMenu.reload()
        stashKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel.window else { return }
                for view in [self.panel.lazyStashMenu.loaded, self.panel.stashBadge].compactMap({ $0 }) as [NSView] where !view.isHidden {
                    if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return }
                }
                self.setStashMenu(false)
            }
            return event
        }
    }

    /// The menu's keys while it is open, before the composer's (a capture-phase listener in T3).
    func handleStashMenuKey(_ event: NSEvent) -> Bool {
        // A dialog over the menu owns the keyboard: Return is the delete confirmation's default button, Escape
        // reaches the dialog's Cancel, and nothing reaches the menu (no restore, no second confirmation).
        if ModalHost.isPresented(in: composer.window) {
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if let confirm = stashDeleteConfirm, event.type == .keyDown, plain, event.keyCode == 36 || event.keyCode == 76 {
                confirm()
                return true
            }
            return false
        }
        guard panel.stashMenuOpen, let menu = panel.lazyStashMenu.loaded, !menu.isHidden else { return false }
        return menu.handleKey(event)
    }

    /// `composer.stash` (ChatComposer.tsx:5696-5720): always claimed; with a question open it toggles
    /// the menu, without a project it does nothing, else it stashes, approvals or not (a93b03c8a5).
    func stashShortcut() {
        if questionRequestId != nil { toggleStashMenu(); return }
        if target == nil { return }
        stashCurrentPrompt()
    }

    // MARK: /usage-limits (ChatView.tsx:3475-3570)

    /// T3 owns `/usage-limits` only where Limits has data for the selected provider.
    private var usageLimitsOffered: Bool {
        guard let p = menuProvider else { return false }
        return UsageLimitsLogic.hasLimits(driver: p.driver, providers: serverConfig.providers, sources: serverConfig.usageLimitSources)
    }

    /// Opens the panel from the last snapshot, or says the provider has none.
    @discardableResult
    func openUsageLimits() -> Bool {
        let nowMs = TimestampFormat.nowMs()
        guard let env = targetEnvironmentId, let instance = pickers.current.instanceId,
              let report = UsageLimitsLogic.report(instanceId: instance.rawValue, providers: serverConfig.providers,
                                                   sources: serverConfig.usageLimitSources, nowMs: nowMs) else {
            panel.usageLimitsBanner = nil
            toast(.info, "Usage limits are unavailable for this provider")
            return false
        }
        let banner = UsageLimitsBannerView(report: report)
        banner.onOpenURL = { url in if let u = SafeExternalURL.parse(url) { NSWorkspace.shared.open(u) } }
        for (account, view) in banner.resetViews {
            guard let target = account.resetCreditTarget ?? account.instanceId.map({ .instance($0) }) else { continue }
            view.onUse = { [weak self, weak view] in
                guard let self, let view else { return }
                UsageResetCredit.confirmAndUse(in: self.panel.window, environments: self.environments, environmentId: env, target: target) { busy, status in
                    view.busy = busy
                    if let status { view.statusText = status }
                }
            }
        }
        panel.usageLimitsBanner = banner
        return true
    }

    /// The panel belongs to one thread and model; another thread or provider drops it.
    func dropUsageLimitsIfStale(instance: String?) {
        guard let banner = panel.usageLimitsBanner else { return }
        if banner.report.accounts.allSatisfy({ $0.instanceId != nil && $0.instanceId != instance }) { panel.usageLimitsBanner = nil }
    }

    func toastPublic(_ kind: ToastQueue.Kind, _ title: String, _ message: String? = nil) { toast(kind, title, message) }

    /// "Invalid keybindings configuration" with `KeybindingsConfigWarning` (KeybindingsConfigWarning.tsx:13-54): the
    /// server's message and "Open keybindings.json" in the preferred editor, disabled without a path or editors.
    private func showKeybindingsWarning(_ message: String, config: ServerProviderConfig) {
        let toast = ToastView(title: "Invalid keybindings configuration", message: message, kind: .warning)
        let open = ButtonView("Open keybindings.json", variant: .outline, size: .xs)
        let editor = OpenInEditors.preferred(available: config.availableEditors, last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey))
        open.isEnabled = config.keybindingsConfigPath != nil && editor != nil
        open.action = { [weak self] in
            guard let self, let path = config.keybindingsConfigPath, let editor, let env = self.environments.primaryId else { return }
            Task { [weak self] in
                do {
                    _ = try await self?.environments.request(env, "shell.openInEditor", OpenInEditors.launchInput(cwd: path, editor: editor))
                } catch {
                    let detail = (error as? RPCClientError)?.typedError?.fields["message"]?.stringValue ?? "Unknown error opening file."
                    self?.toast(.error, "Unable to open keybindings file", detail)
                }
            }
        }
        toast.descriptionButton = open
        _ = panel.toasts.show(toast)
    }

    private func toast(_ kind: ToastQueue.Kind, _ title: String, _ message: String? = nil) {
        _ = panel.toasts.show(ToastView(title: title, message: message, kind: kind))
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// `stashCurrentPrompt`: an empty composer restores the only entry or opens the menu. Files must
    /// be uploaded and keep their reference; the entry is written before the composer clears, and
    /// images are encoded into it afterwards.
    private func stashCurrentPrompt() {
        guard let key = draftKey, let env = targetEnvironmentId else { return }
        if (preparingImages[key] ?? 0) > 0 {
            toast(.info, "Still bringing a pasted attachment into this message.", "Stash again once its chip resolves.")
            return
        }
        let prompt = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = currentAttachments
        let images = attachments.filter { $0.kind == .image }, files = attachments.filter { $0.kind == .file }
        if prompt.isEmpty, attachments.isEmpty {
            if stash.entries.count == 1, let only = stash.entries.first, (only.pendingImageCount ?? 0) == 0 {
                restoreStash(only)
            } else {
                toggleStashMenu()
            }
            return
        }
        var stashedFiles: [PromptStashEntry.File] = []
        for file in files {
            guard file.status == .ready, let attachmentId = file.attachmentId, file.environmentId == env else {
                toast(.error, "Wait for file uploads before stashing this prompt")
                return
            }
            stashedFiles.append(.init(id: file.id, name: file.name, mimeType: file.mimeType, sizeBytes: file.sizeBytes,
                                      attachmentId: attachmentId, environmentId: env))
        }
        let snapshot = [key, prompt, attachments.map { "\($0.kind.rawValue):\($0.id)" }.joined(separator: ",")].joined(separator: "\n")
        guard stashInFlight.insert(snapshot).inserted else { return }
        let referenced = contextRecords(for: prompt)
        let records = ComposerContext.referencedIds(prompt).compactMap { referenced[$0] }
        let entryId = UUID().uuidString.lowercased()
        let entry = PromptStashEntry(id: entryId, createdAt: Self.isoNow(), prompt: prompt, files: stashedFiles.isEmpty ? nil : stashedFiles,
                                     unreadableImageNames: [], pendingImageCount: images.count, records: records.isEmpty ? nil : records)
        let (evicted, written) = stash.stash(entry)
        guard written else {
            stashInFlight.remove(snapshot)
            toast(.error, "Could not stash this prompt", "The stash could not be written to disk, so the composer was left as-is.")
            return
        }
        // Everything the entry carries leaves the draft with it; images are uploaded again on restore.
        draftAttachments[key] = nil
        for image in images { release(image) }
        composer.text = ""
        remember("")
        // An image-only prompt leaves the text unchanged, so nothing else redraws the attachment chips.
        refresh()
        pulseStashBadge()
        if let evicted {
            for file in evicted.files ?? [] { deleteUpload(file.attachmentId, environmentId: file.environmentId) }
            toast(.warning, "Oldest stashed prompt discarded",
                  "The stash holds \(PromptStashStore.maxEntries) prompts; the oldest was removed to make room.")
        }
        guard !images.isEmpty else { stashInFlight.remove(snapshot); return }
        let directory = stash.directory
        Task { [weak self] in
            var candidates: [(image: PromptStashEntry.Image, chars: Int)] = [], unreadable: [String] = [], oversized: [String] = []
            for image in images {
                let file = "\(entryId)-\(image.id).img"
                switch await ComposerImageIO.stashCopy(image.fileURL, mimeType: image.mimeType, to: directory.appendingPathComponent(file)) {
                case .success(let copy):
                    candidates.append((.init(id: image.id, name: image.name, mimeType: copy.mimeType, sizeBytes: copy.bytes, file: file),
                                       ComposerImageIO.dataURLChars(bytes: copy.bytes, mimeType: copy.mimeType)))
                case .failure(.tooLarge): oversized.append(image.name)
                case .failure(.unreadable): unreadable.append(image.name)
                }
            }
            guard let self else { return }
            stashInFlight.remove(snapshot)
            let (kept, dropped) = PromptStashStore.partition(candidates)
            for c in candidates where !kept.contains(c.image) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(c.image.file)) }
            if !stash.finalizeImages(entryId, images: kept, dropped: oversized + dropped, unreadable: unreadable) {
                for image in kept { try? FileManager.default.removeItem(at: directory.appendingPathComponent(image.file)) }
                toast(.warning, "Stashed images were not saved", "The prompt was restored or deleted before its images finished saving.")
            }
        }
    }

    /// The badge lifts to full opacity and the count turns primary for 1.2 s (`pulseStashBadge`).
    private func pulseStashBadge() {
        stashPulseWork?.cancel()
        panel.stashBadge.pulse()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.stashBadge.pulsing = false } }
        stashPulseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func deleteUpload(_ attachmentId: String, environmentId: String) {
        guard let supervisor = environments.session(environmentId)?.supervisor else { return }
        Task { _ = try? await supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(attachmentId)])) }
    }

    /// `restoreStashEntry`: files only in the environment that holds them, checked against the
    /// server first (uploads expire after 24 hours); the text joins the current prompt after a
    /// blank line; images upload again; anything that did not come back is listed in one warning.
    private func restoreStash(_ menuEntry: PromptStashEntry) {
        guard let key = draftKey, let env = targetEnvironmentId else { return }
        let files = menuEntry.files ?? []
        if files.contains(where: { $0.environmentId != env }) {
            toast(.error, "Stashed files belong to another environment", "Restore this prompt in the environment that received its files.")
            return
        }
        setStashMenu(false)
        let supervisor = shell?.supervisor
        Task { [weak self] in
            var expired = Set<String>()
            for file in files {
                guard let supervisor else { break }
                do {
                    _ = try await supervisor.request("assets.createUrl", payload: .object([
                        "resource": .object(["_tag": .string("attachment"), "attachmentId": .string(file.attachmentId)])]))
                } catch let error as RPCClientError where error.typedError?.tag == "AssetAttachmentNotFoundError" {
                    expired.insert(file.attachmentId)
                } catch {}
            }
            // A target switch during the check leaves the entry for where the user is now.
            guard let self, draftKey == key else { return }
            finishRestore(menuEntry.id, key: key, env: env, expired: expired)
        }
    }

    private func finishRestore(_ id: String, key: String, env: String, expired: Set<String>) {
        let (taken, durable) = stash.take(id)
        guard let entry = taken else { return }
        if !durable {
            toast(.warning, "Restored prompt may reappear in the stash", "The stash could not be updated on disk, so this entry could still be there after a relaunch.")
        }
        for record in entry.records ?? [] {
            if let contextId = record["contextId"]?.stringValue { menuState.records[contextId] = record }
        }
        var existing = draftAttachments[key] ?? []
        var reasons: [String] = []
        var expiredNames: [String] = [], unrestored: [String] = []
        var capacity = max(0, ComposerAttachmentRules.maxAttachments - existing.count)
        var restoredFiles: [ComposerAttachment] = []
        for file in entry.files ?? [] where !existing.contains(where: { $0.id == file.id }) {
            if expired.contains(file.attachmentId) { expiredNames.append(file.name); continue }
            guard capacity > 0 else { unrestored.append(file.name); deleteUpload(file.attachmentId, environmentId: env); continue }
            capacity -= 1
            restoredFiles.append(ComposerAttachment(id: file.id, kind: .file, name: file.name, mimeType: file.mimeType, sizeBytes: file.sizeBytes,
                                                    fileURL: Self.attachmentWorkDirectory, status: .ready, attachmentId: file.attachmentId,
                                                    environmentId: env))
        }
        var restoredImages: [ComposerAttachment] = []
        var unrestoredImages: [String] = []
        let work = Self.attachmentWorkDirectory
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for image in entry.attachments where !existing.contains(where: { $0.id == image.id }) {
            guard capacity > 0 else { unrestoredImages.append(image.name); continue }
            let copy = work.appendingPathComponent(UUID().uuidString + "-" + image.name)
            guard (try? FileManager.default.copyItem(at: stash.imageURL(image), to: copy)) != nil else { unrestoredImages.append(image.name); continue }
            capacity -= 1
            restoredImages.append(ComposerAttachment(id: image.id, kind: .image, name: image.name, mimeType: image.mimeType,
                                                     sizeBytes: image.sizeBytes, fileURL: copy, environmentId: env))
        }
        stash.removeImages(of: entry)
        existing += restoredFiles + restoredImages
        draftAttachments[key] = existing
        // An image-only stash adds no blank lines to what is already in the composer.
        let current = composer.text
        var next = entry.prompt.isEmpty ? current
            : current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.prompt
            : current.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n\n" + entry.prompt
        // Restored files keep a chip (`appendReference`).
        let ids = Set(ComposerContext.referencedIds(next))
        let missing = restoredFiles.filter { !ids.contains($0.contextId) }.map(\.reference)
        if !missing.isEmpty { next += (next.isEmpty || next.hasSuffix(" ") || next.hasSuffix("\n") ? "" : " ") + missing.joined(separator: " ") + " " }
        if next != current {
            composer.text = next
            remember(next)
        }
        for image in restoredImages { startUpload(image.id, key: key) }
        if !entry.droppedImageNames.isEmpty { reasons.append("\(entry.droppedImageNames.joined(separator: ", ")) exceeded the stash size limit when this prompt was saved.") }
        if let unreadable = entry.unreadableImageNames, !unreadable.isEmpty { reasons.append("\(unreadable.joined(separator: ", ")) could not be read when this prompt was saved.") }
        let limited = unrestoredImages + unrestored
        if !limited.isEmpty { reasons.append("\(limited.joined(separator: ", ")) could not be restored: the composer is at its \(ComposerAttachmentRules.maxAttachments)-attachment limit.") }
        // ponytail: an expired file is dropped with this note; T3 keeps it as an "Attach again" row
        if !expiredNames.isEmpty { reasons.append("\(expiredNames.joined(separator: ", ")): stashed files are kept for 24 hours and this upload expired. Attach the file again.") }
        if !reasons.isEmpty { toast(.warning, "Some attachments were not restored", reasons.joined(separator: " ")) }
        refresh()
        composer.focus()
    }

    /// `deleteStashEntry`: the entry's file uploads go too.
    /// The x and Cmd-Backspace ask first: a stashed prompt can be long and is gone for good once deleted. CandyWrapper's
    /// own guard (the user lost a big prompt to one click); T3 deletes at once.
    private func deleteStash(_ entry: PromptStashEntry) {
        // No window to ask in: keep the prompt.
        guard let window = composer.window, stashDeleteConfirm == nil, !ModalHost.isPresented(in: window) else { return }
        let preview = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
        let dialog = DialogView(kind: .alertDialog, title: "Delete this stashed prompt?",
                                message: excerpt.isEmpty ? "It can't be restored." : "\u{201C}\(excerpt)\u{201D} can't be restored.")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Delete", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.stashDeleteConfirm = nil }
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in
            self?.stashDeleteConfirm = nil
            host?.close()
            self?.deleteStashNow(entry)
        }
        stashDeleteConfirm = ok.action
    }

    private func deleteStashNow(_ entry: PromptStashEntry) {
        let (removed, durable) = stash.take(entry.id)
        if stash.entries.isEmpty { setStashMenu(false) }
        if let removed {
            stash.removeImages(of: removed)
            if durable { for file in removed.files ?? [] { deleteUpload(file.attachmentId, environmentId: file.environmentId) } }
        }
        if !durable { toast(.warning, "Stash entry may come back", "The stash could not be updated on disk, so this prompt could reappear after a relaunch.") }
    }
}


// MARK: Find in thread
extension ComposerController {
    @discardableResult
    func openThreadFind() -> Bool {
        guard let id = openThreadId else { return false }
        guard serverConfig.capabilities.contains("threadFind") else {
            toast(.warning, "Thread search is unavailable on this server.", "Update the server to enable it.")
            return true
        }
        threadFindTarget = id
        panel.findOpen = true
        panel.layoutSubtreeIfNeeded()
        panel.findBar.focus()
        return true
    }

    private func closeThreadFind() {
        let wasOpen = panel.findOpen
        threadFindGeneration += 1
        threadFindTask?.cancel(); threadFindTask = nil
        threadFindRefreshTask?.cancel(); threadFindRefreshTask = nil
        threadFindSearching = false; threadFindRefreshPending = false
        threadFindResult = nil; threadFindTarget = nil
        panel.findOpen = false
        panel.timeline.threadFindQuery = ""
        if let bar = panel.lazyFindBar.loaded, !bar.input.text.isEmpty { bar.input.text = "" }
        if wasOpen { focusComposer() }
    }

    private func scheduleThreadFindRefresh() {
        guard !threadFindSearching, threadFindRefreshTask == nil, threadFindRefreshPending else { return }
        threadFindRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            self.threadFindRefreshTask = nil
            self.threadFindRefreshPending = false
            self.searchThread(preserveSelection: true)
        }
    }

    private func searchThread(delta: Int = 0, preserveSelection: Bool = false) {
        if delta != 0, threadFindResult?.complete == false { return }
        threadFindRefreshTask?.cancel(); threadFindRefreshTask = nil
        threadFindGeneration += 1
        threadFindTask?.cancel()
        let generation = threadFindGeneration
        guard panel.findOpen, let id = openThreadId, let shell else { return }
        let query = String(panel.findBar.input.text.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        panel.timeline.threadFindQuery = query
        let old = threadFindResult
        if delta == 0 && !preserveSelection { threadFindResult = nil }
        threadFindSearching = !query.isEmpty
        panel.findBar.present(query: query, index: 0, total: 0, loading: !query.isEmpty)
        guard !query.isEmpty else { return }
        var payload: [String: JSONValue] = ["threadId": .string(id.localId.rawValue), "query": .string(query)]
        if delta != 0 || preserveSelection, let match = old?.match {
            payload["start"] = .object(["entryId": .string(match.entryId), "occurrence": .number(Double(match.occurrence))])
            payload["offset"] = .number(Double(delta))
        }
        let supervisor = shell.supervisor
        let progressive = serverConfig.capabilities.contains("threadFindProgressive")
        let requestPayload = JSONValue.object(payload)
        threadFindTask = Task { [weak self] in
            do {
                if delta == 0 { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                guard let self, self.threadFindGeneration == generation else { return }
                if progressive {
                    self.threadFindTask = supervisor.subscribe("orchestration.searchThreadStream", payload: { requestPayload }) { [weak self] event in
                        await MainActor.run {
                            guard let self, self.threadFindGeneration == generation, self.openThreadId == id else { return }
                            switch event {
                            case .value(let json):
                                do { self.applyThreadFind(try json.decode(as: ThreadFindResult.self), query: query) }
                                catch { self.panel.findBar.present(query: query, index: 0, total: 0, failed: true) }
                            case .interrupted:
                                self.threadFindSearching = false
                                self.threadFindTask?.cancel()
                                self.panel.findBar.present(query: query, index: 0, total: 0, failed: true)
                            case .subscribed: break
                            }
                        }
                    }
                } else {
                    let json = try await supervisor.request("orchestration.searchThread", payload: requestPayload)
                    guard !Task.isCancelled, self.threadFindGeneration == generation, self.openThreadId == id else { return }
                    self.applyThreadFind(try json.decode(as: ThreadFindResult.self), query: query)
                }
            } catch {
                guard let self, !Task.isCancelled, self.threadFindGeneration == generation else { return }
                self.threadFindSearching = false
                self.panel.findBar.present(query: query, index: 0, total: 0, failed: true)
            }
        }
    }

    private func applyThreadFind(_ result: ThreadFindResult, query: String) {
        let changed = threadFindResult?.match != result.match
        threadFindResult = result
        threadFindSearching = result.complete == false
        panel.findBar.present(query: query, index: result.activeIndex, total: result.totalMatches, counting: threadFindSearching)
        if changed, let match = result.match { panel.revealThreadFind(match) }
        if !threadFindSearching { scheduleThreadFindRefresh() }
    }
}


// MARK: Edit from here
extension ComposerController {
    private func editEarlierPrompt(_ message: ChatMessage) {
        guard let id = openThreadId, let projection, let key = draftKey, let window = panel.window else { return }
        guard menuProvider?.supportsConversationRollback != false, menuProvider != nil else {
            toast(.warning, "This provider does not support reverting conversation history. Start a new thread instead."); return
        }
        guard !composer.runState.canInterrupt, pendingMessageId == nil, !threadRewindBusy else {
            toast(.warning, "Interrupt the current turn before reverting checkpoints."); return
        }
        guard ComposerAttachmentRules.uploadBlockReason(currentAttachments) == nil else {
            toast(.warning, "Wait for attachments to finish preparing before rewinding."); return
        }
        guard let checkpoint = ThreadPromptRewind.checkpoint(before: message, in: projection) else {
            toast(.warning, "No ready checkpoint is available before this message."); return
        }
        // ChatOverlayHosts.tsx:212-225 (7116325f03). The files sentence goes with the button it names.
        let revertsFiles = projection.thread.worktreePath != nil
        let description = "Rewind chat to before this message. Your prompt and attachments return to the composer."
            + (revertsFiles ? " \u{201C}Revert files too\u{201D} also undoes your own edits." : "")
        let dialog = DialogView(kind: .alertDialog, title: "Edit from here?", message: description)
        let cancel = ButtonView("Cancel", variant: .outline)
        let keep = ButtonView("Revert and keep changes")
        let files = ButtonView("Revert files too", variant: .destructiveOutline)
        dialog.footerButtons = revertsFiles ? [cancel, files, keep] : [cancel, keep]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        let perform: (Bool) -> Void = { [weak self, weak host] restoreFiles in
            host?.close()
            guard let self, self.openThreadId == id, let supervisor = self.shell?.supervisor else { return }
            self.threadRewindBusy = true; self.refresh()
            Task {
                defer { self.threadRewindBusy = false; self.refresh() }
                var staged: [ComposerAttachment] = []
                var minted: [String] = []
                var dispatched = false
                let observer = ThreadPromptRewindObserver(supervisor: supervisor, threadId: id.localId, messageId: message.id)
                defer { observer.stop() }
                do {
                    guard let sourceShell = self.environments.session(id.environmentId) else { throw RewindPreparationError("The environment is not connected.") }
                    if (self.draftAttachments[key]?.count ?? 0) + message.attachments.count > ComposerAttachmentRules.maxAttachments {
                        throw RewindPreparationError("Make room for this message's attachments in the composer before rewinding.")
                    }
                    for value in message.attachments {
                        guard let type = value["type"]?.stringValue, let kind = ComposerAttachment.Kind(rawValue: type),
                              let oldId = value["id"]?.stringValue, let name = value["name"]?.stringValue,
                              let mime = value["mimeType"]?.stringValue else { throw RewindPreparationError("This message has an attachment that cannot be restored.") }
                        let asset = try await supervisor.request("assets.createUrl", payload: .object(["resource": .object([
                            "_tag": .string("attachment"), "attachmentId": .string(oldId), "fileName": .string(name), "mimeType": .string(mime)])]))
                        guard let relative = asset["relativeUrl"]?.stringValue, let url = URL(string: relative, relativeTo: sourceShell.http.baseURL)?.absoluteURL else {
                            throw RewindPreparationError("The environment returned an invalid attachment URL.")
                        }
                        let (temp, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 30))
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            throw RewindPreparationError("Could not restore attachment: " + name)
                        }
                        let file = Self.attachmentWorkDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: Self.attachmentWorkDirectory, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: temp, to: file)
                        let bytes = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                        var attachment = ComposerAttachment(kind: kind, name: name, mimeType: mime, sizeBytes: bytes, fileURL: file, environmentId: sourceShell.environmentId)
                        staged.append(attachment)
                        let upload = await Self.uploadAttachment(supervisor: supervisor, base: sourceShell.http.baseURL, type: type, name: name, mimeType: mime,
                            sizeBytes: bytes, file: file, onMinted: { minted.append($0) }, onProgress: { _ in })
                        guard case .uploaded(let newId) = upload else { throw RewindPreparationError("Could not restore attachment: " + name) }
                        attachment.attachmentId = newId; attachment.status = .ready
                        staged[staged.count - 1] = attachment
                    }
                    try await observer.wait(present: true)
                    // Recheck mutable guards after staging; never rewind a turn started meanwhile.
                    guard self.openThreadId == id, !self.composer.runState.canInterrupt, self.pendingMessageId == nil,
                          (self.draftAttachments[key]?.count ?? 0) + staged.count <= ComposerAttachmentRules.maxAttachments else {
                        throw RewindPreparationError("The thread changed while preparing the rewind. Try again.")
                    }
                    dispatched = true
                    _ = try await supervisor.request("orchestration.dispatchCommand", payload: ThreadPromptRewind.command(threadId: id.localId, checkpoint: checkpoint, restoreFiles: restoreFiles))
                    try await observer.wait(present: false)
                    let recovery = ThreadPromptAttachmentRestore.restore(text: message.text, context: message.context, attachments: message.attachments, staged: staged)
                    self.draftAttachments[key, default: []] += staged
                    for record in recovery.records {
                        if let contextId = record["contextId"]?.stringValue { self.menuState.records[contextId] = record }
                    }
                    let restored = ThreadPromptRewind.restoredPrompt(draft: self.prompts[key] ?? "", message: recovery.text)
                    self.prompts[key] = restored; self.scheduleSave()
                    if self.draftKey == key { self.composer.text = restored; self.focusComposer() }
                } catch {
                    if dispatched {
                        // The server may have applied rollback before a transport error. Keep staged bytes recoverable.
                        self.draftAttachments[key, default: []] += staged
                        let recovery = ThreadPromptAttachmentRestore.restore(text: message.text, context: message.context, attachments: message.attachments, staged: staged)
                        self.prompts[key] = ThreadPromptRewind.restoredPrompt(draft: self.prompts[key] ?? "", message: recovery.text)
                        for record in recovery.records { if let contextId = record["contextId"]?.stringValue { self.menuState.records[contextId] = record } }
                        if self.draftKey == key { self.composer.text = self.prompts[key] ?? "" }
                        self.scheduleSave()
                    } else {
                        for upload in minted { _ = try? await supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(upload)])) }
                        for attachment in staged { try? FileManager.default.removeItem(at: attachment.fileURL) }
                    }
                    self.toast(.error, "Failed to revert thread state.", error.localizedDescription)
                }
            }
        }
        keep.action = { perform(false) }
        files.action = { perform(true) }
    }
}


extension ComposerController {
    /// `sendStandaloneCommand` (ChatView.tsx:7419-7500): the command runs as its own turn with an optimistic
    /// echo; the draft stays. A failure drops the echo and shows the server's message, else `failure`, in
    /// the thread's error banner. Transport errors stay silent.
    private func sendThreadStandalone(_ text: String, failure: String) {
        guard let key = draftKey else { return }
        threadErrors.set(key, nil)
        Task { [weak self] in
            do { try await self?.dispatchThreadStandalone(text, queue: false, echo: true) }
            catch {
                guard let self else { return }
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                if error is RewindPreparationError { return } // a thread that can't send stays quiet
                self.threadErrors.set(key, Self.message(error) ?? failure)
                self.refresh()
            }
        }
    }
    func sendAppMessage(_ text: String) async throws { try await dispatchThreadStandalone(text, queue: true) }

    private func dispatchThreadStandalone(_ text: String, queue: Bool, echo: Bool = false) async throws {
        guard let id = openThreadId, let supervisor = shell?.supervisor, let selection = pickers.current.modelSelection,
              !threadRewindBusy, pendingMessageId == nil, queue || !composer.runState.canInterrupt else {
            throw RewindPreparationError("Messages from apps need an available started thread.")
        }
        let picks = pickers.current, picksKey = draftKey
        let messageId = MessageId(UUID().uuidString.lowercased())
        if echo { optimistic.append(ChatMessage(id: messageId, role: .user, text: text, createdAt: T3Timestamp(Date()))) }
        pendingMessageId = messageId; refresh()
        var sent = false
        defer {
            if pendingMessageId == messageId { pendingMessageId = nil }
            if !sent { optimistic.removeAll { $0.id == messageId } }
            refresh()
        }
        if let mode = picks.runtimeModeToPersist {
            _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                "type": .string("thread.runtime-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                "threadId": .string(id.localId.rawValue), "runtimeMode": .string(mode.rawValue)]))
        }
        if let mode = picks.interactionModeToPersist {
            _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                "threadId": .string(id.localId.rawValue), "interactionMode": .string(mode.rawValue)]))
        }
        _ = try await supervisor.request("orchestration.dispatchCommand", payload: Self.standaloneCommand(
            threadId: id, messageId: messageId, text: text, selection: selection, queue: queue))
        sent = true
        if let picksKey { pickers.store.didSend(picksKey) }
    }

    /// `startThreadTurn` with no dispatch mode for a standalone command (commands.ts:752-776): `auto`,
    /// which the server resolves (`start_immediately` plus `deliveryIntent: auto`); queued app messages
    /// go behind the active run.
    static func standaloneCommand(threadId: ThreadId, messageId: MessageId, text: String, selection: ModelSelection, queue: Bool) -> JSONValue {
        OrchestrationCommands.message(threadId: threadId.localId.rawValue, messageId: messageId.rawValue, text: text, selection: selection, queue: queue)
    }

}


extension ComposerController {
    /// `backgroundWorkBannerItem` (ThreadActivityBanners.tsx:100-170, ChatView.tsx:3791-3819, 3930-3939): shown
    /// only while the thread isn't working. One subagent gets "Show", several get their titles as links; Stop
    /// sends what the composer's Stop sends and reads "Stopping..." until the server accepts it.
    private func updateBackgroundWorkBanner(_ thread: ThreadShell?) {
        let presentation = composer.runState.canInterrupt ? nil : thread.flatMap { BackgroundWorkPresentation.present($0.backgroundTasks) }
        panel.showsBackgroundWork = presentation != nil
        guard let thread, let presentation else { return }
        let stopWork: @MainActor () -> Void = { [weak self] in
            guard let self, self.stoppingBackgroundWork != thread.id, self.openThreadId == thread.id else { return }
            self.stoppingBackgroundWork = thread.id
            self.updateThreadBanners()
            // Acceptance does not confirm termination: Stop comes back for a retry while the tasks wind down.
            self.stop { [weak self] in
                guard let self, self.stoppingBackgroundWork == thread.id else { return }
                self.stoppingBackgroundWork = nil
                self.updateThreadBanners()
            }
        }
        typealias Part = ComposerNoticeBannerView.Content.DescriptionPart
        var parts: [Part] = []
        let items = presentation.items
        if items.count > 1 || items.first?.childThreadId != nil {
            for (index, item) in items.enumerated() {
                let separator = index < items.count - 1 ? "," : ""
                if index > 0 { parts.append(Part(text: " ")) }
                if item.childThreadId == nil {
                    parts.append(Part(text: item.label + separator))
                } else {
                    let single = items.count == 1
                    parts.append(Part(text: single ? "Show" : item.label, link: (single ? "Show" : "Open") + " subagent " + item.label))
                    if !separator.isEmpty { parts.append(Part(text: separator)) }
                }
            }
        }
        // Merge neighbouring text so each run measures as one label.
        parts = parts.reduce(into: []) { merged, part in
            if part.link == nil, let last = merged.last, last.link == nil { merged[merged.count - 1].text += part.text } else { merged.append(part) }
        }
        let stopping = stoppingBackgroundWork == thread.id
        let banner = panel.backgroundWorkBanner
        banner.apply(.init(variant: .neutral, icon: .info, title: presentation.title, actions: [stopping ? "Stopping..." : "Stop"],
                           priority: .activity, dot: presentation.waiting ? .pulsing : .still, descriptionParts: parts))
        banner.disabledActions = stopping || !environments.canOperate(thread.id.environmentId) ? [0] : []
        let links = parts.enumerated().compactMap { $0.element.link == nil ? nil : $0.offset }
        let children = items.compactMap(\.childThreadId)
        banner.onLink = { [weak self] index in
            guard let position = links.firstIndex(of: index), position < children.count else { return }
            self?.openThread?(children[position])
        }
        banner.onAction = { index in if index == 0 { stopWork() } }
        // Redesign's indicator: the short label, and the banner's links and Stop in its menu.
        let canStop = !stopping && environments.canOperate(thread.id.environmentId)
        let menuLinks = items.compactMap { item in
            item.childThreadId.map { child in
                DitherWaitingView.Action(items.count == 1 ? "Show subagent" : item.label) { [weak self] in self?.openThread?(child) }
            }
        }
        panel.waitingIndicator.configure(title: BackgroundWorkPresentation.shortTitle(presentation), waiting: presentation.waiting,
                                         header: presentation.title, links: menuLinks,
                                         stop: DitherWaitingView.Action(stopping ? "Stopping..." : "Stop", enabled: canStop, run: stopWork))
    }

    private func updateThreadBanners() {
        let thread = shellThread
        panel.showsGoal = thread?.goal != nil
        if let goal = thread?.goal {
            let actions = composer.runState.canInterrupt ? [] : ThreadGoalPresentation.canResume(goal) ? ["Resume", "Clear"] : ["Clear"]
            panel.goalBanner.apply(.init(variant: .neutral, icon: .target, title: ThreadGoalPresentation.title(goal, working: composer.runState.canInterrupt), description: goal.objective, actions: actions))
        }
        updateBackgroundWorkBanner(thread)
        let limited = thread?.status == .failed && thread?.lastErrorClass == .usageLimit
        panel.showsRecovery = limited
        if let thread, limited {
            let reset = thread.usageLimitResetAt?.date
            let pending = recoveryPending.contains(thread.id)
            let description = recoveryErrors[thread.id] ?? reset.map { "Resets " + $0.formatted(date: .numeric, time: .shortened) } ?? "Reset time unavailable; retry manually"
            var actions: [String] = []
            if ThreadUsageLimitRecovery.canSchedule(thread) {
                actions = [pending ? "Saving..." : ThreadUsageLimitRecovery.scheduled(thread) ? "Cancel auto-resume" : "Resume at reset"]
                if !ThreadUsageLimitRecovery.snoozed(thread) { actions.append(pending ? "Saving..." : "Snooze until reset") }
            }
            panel.recoveryBanner.apply(.init(variant: .warning, icon: .gauge, title: "Usage limit reached", description: description, actions: actions))
            panel.recoveryBanner.disabledActions = pending ? Set(actions.indices) : (reset ?? .distantPast) <= Date() ? [1] : []
        }
        let resetKey = limited ? thread.map { $0.id.rawValue + ":" + ($0.usageLimitResetAt?.raw ?? "") } : nil
        if resetKey != recoveryResetKey {
            recoveryResetWork?.cancel(); recoveryResetWork = nil; recoveryResetKey = resetKey
            if limited, let reset = thread?.usageLimitResetAt?.date, reset > Date() {
                let work = DispatchWorkItem { [weak self] in self?.updateThreadBanners() }
                recoveryResetWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + min(reset.timeIntervalSinceNow + 0.01, 2_147_483), execute: work)
            }
        }
    }
    private func updateThreadRecovery(_ index: Int?) {
        guard let index, let thread = shellThread, !recoveryPending.contains(thread.id), ThreadUsageLimitRecovery.canSchedule(thread), let supervisor = shell?.supervisor else { return }
        if index == 1, (thread.usageLimitResetAt?.date ?? .distantPast) <= Date() {
            toast(.warning, "The reset time has passed. Retry the thread manually."); return
        }
        guard let payload = ThreadUsageLimitRecovery.update(thread: thread, autoResume: index == 0 ? !ThreadUsageLimitRecovery.scheduled(thread) : nil, snooze: index == 1 ? true : nil) else { return }
        recoveryPending.insert(thread.id); recoveryErrors[thread.id] = nil; updateThreadBanners()
        Task { [weak self] in
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload) }
            catch { self?.recoveryErrors[thread.id] = error.localizedDescription }
            self?.recoveryPending.remove(thread.id); self?.updateThreadBanners()
        }
    }
}

/// A scoped observer stays alive across navigation until rollback is confirmed.
/// No polling: ThreadStore changes resume the pending continuation.
@MainActor
private final class ThreadPromptRewindObserver {
    private let store: ThreadStore
    private let messageId: MessageId
    private var subscription: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var waiting: (Bool, CheckedContinuation<Void, Error>)?
    private var present: Bool?
    init(supervisor: ConnectionSupervisor, threadId: ThreadId, messageId: MessageId) {
        self.messageId = messageId
        store = ThreadStore(threadId: threadId, onChange: {})
        let store = self.store
        subscription = supervisor.subscribe("orchestration.subscribeThread", payload: {
            ThreadSession.encode(await store.subscribeInput())
        }) { [weak self] event in
            guard case .value(let json) = event, let item = ThreadSession.decode(json) else { return }
            await store.apply([item])
            guard let update = await store.takeUpdate(), let projection = update.projection else { return }
            let contains = projection.messages.contains { $0.id == messageId }
            await self?.received(contains)
        }
    }
    private func received(_ value: Bool) {
        present = value
        if let (expected, continuation) = waiting, expected == value {
            waiting = nil; deadline?.cancel(); deadline = nil; continuation.resume()
        }
    }
    func wait(present expected: Bool) async throws {
        if present == expected { return }
        try await withCheckedThrowingContinuation { continuation in
            waiting = (expected, continuation)
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, let (_, continuation) = waiting else { return }
                waiting = nil
                continuation.resume(throwing: NSError(domain: "ThreadPromptRewind", code: 1, userInfo: [NSLocalizedDescriptionKey: "The conversation has not confirmed the rewind."]))
            }
        }
    }
    func stop() { subscription?.cancel(); deadline?.cancel(); subscription = nil; deadline = nil }
}

private struct RewindPreparationError: LocalizedError { var errorDescription: String?; init(_ message: String) { errorDescription = message } }


extension ComposerController {
    fileprivate func mediaAttachmentURL(_ id: String) async -> URL? {
        guard let shell else { return nil }
        let base = shell.http.baseURL
        guard let result = try? await shell.supervisor.request("assets.createUrl", payload: .object([
            "resource": .object(["_tag": .string("attachment"), "attachmentId": .string(id)])])),
              let relative = result["relativeUrl"]?.stringValue else { return nil }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}


extension ComposerController {
    private func syncWorktreeSetup() {
        let followUpSent = (projection?.messages.filter { $0.role == "user" }.count ?? 0) > 1
        let setupApplies = projection?.thread.worktreePath != nil || projection?.runs.last?.status.rawValue == "preparing"
        let target = !followUpSent && setupApplies ? openThreadId : nil
        guard threadWorktreeSetupTarget != target else { return }
        threadWorktreeSetupTask?.cancel(); threadWorktreeSetupTask = nil
        threadWorktreeSetupTarget = target
        panel.timeline.worktreeSetup.snapshot = nil
        guard let target, let supervisor = shell?.supervisor else { return }
        panel.timeline.worktreeSetup.onCancel = { [weak self] in
            guard self?.openThreadId == target else { return }
            Task { do { _ = try await supervisor.request("worktreeSetup.cancel", payload: .object(["threadId": .string(target.localId.rawValue)])) }
                catch { self?.toast(.error, "Could not cancel worktree setup", error.localizedDescription) } }
        }
        threadWorktreeSetupTask = supervisor.subscribe("subscribeWorktreeSetup", payload: { .object(["threadId": .string(target.localId.rawValue)]) }) { [weak self] event in
            guard case .value(let json) = event else { return }
            let snapshot = try? json.decode(as: ThreadWorktreeSetupSnapshot.self)
            await MainActor.run {
                guard let self, self.threadWorktreeSetupTarget == target else { return }
                if let snapshot, snapshot.threadId == target.localId.rawValue,
                   snapshot.sequence >= (self.panel.timeline.worktreeSetup.snapshot?.sequence ?? -1) {
                    self.panel.timeline.worktreeSetup.snapshot = snapshot
                    self.syncSendBlock()
                }
            }
        }
    }
}

// MARK: - Compaction

/// Manual compaction and the resume offer (ComposerCompaction): who may compact and why not, the
/// meter's popup state and slot, and the Compact chip that compacts a stale Claude session first.
extension ComposerController {
    fileprivate func updateCompaction(showPlan: Bool) {
        let meter = composer.contextWindowMeter
        let provider = menuProvider
        let thread = shellThread
        var gate = ComposerCompaction.Gate()
        gate.isServerThread = openThreadId != nil && projection != nil
        gate.hasCompactableConversation = ComposerCompaction.hasCompactableConversation(projection)
        gate.hasProject = menuProject != nil
        // The locked instance's continuation group bounds the choice once the thread has started.
        let started = ComposerLogic.QueueState.hasStartedSession(projection) || thread?.latestRunId != nil
        gate.providerAvailable = ComposerCompaction.hasAvailableProvider(
            serverConfig.providers, driver: provider?.driver, instanceId: pickers.current.instanceId,
            lockedInstanceId: started ? thread?.modelSelection.instanceId : nil)
        // Working (a run, a send, a rewind), the environment gone, a request open or the plan follow-up.
        gate.busy = composer.runState.canInterrupt || composer.isBusy || shell == nil || !requests.isEmpty || showPlan
        compactUnavailable = gate.disabled
        // ChatComposer.tsx:2154-2155, 7669-7673: no provider at all, a send or a connect also disable the button.
        let noProvider = provider == nil
        let selection = thread?.modelSelection ?? pickers.current.modelSelection
        // `resolveContextWindowModelDisplayName` (ContextWindowMeter.logic.ts:85-98).
        let modelName = selection.map { s in
            serverConfig.providers.first { $0.instanceId == s.instanceId }?.models.first { $0.slug == s.model }.map(ModelNames.trigger) ?? s.model
        }
        meter.setCompactState(offered: ComposerCompaction.supportsManualCompaction(provider),
                              disabled: gate.disabled || noProvider || composer.isBusy,
                              reason: gate.reason ?? (noProvider ? "Compacting is unavailable right now" : nil), model: modelName)
        updateMeterSlot()

        // The resume offer (ChatView.tsx:7692-7710). A "Don't ask again" answer to the server's own resume
        // question turns it off for this environment and provider, like the local dismissal (:4185-4204).
        var dismissed = false
        if let environmentId = targetEnvironmentId {
            let key = ComposerCompaction.dismissalKey(environmentId: environmentId, instanceId: pickers.current.instanceId)
            dismissed = UserDefaults.standard.bool(forKey: key)
            if !dismissed, let projection, ComposerCompaction.hasDismissedResume(projection.runtimeRequests) {
                UserDefaults.standard.set(true, forKey: key)
                dismissed = true
            }
        }
        let now = Date()
        let held = projection?.runs.contains { $0.status == .queued && $0.queueHeld == true } ?? false
        let tokens = ComposerCompaction.resumeTokens(usage: contextWindow, driver: provider?.driver, dismissed: dismissed,
                                                     compactDisabled: gate.disabled, hasHeldQueuedRuns: held,
                                                     multipleModels: pickers.currentMultiple != nil, now: now)
        composer.compactBeforeSendTokens = tokens
        composer.keepFullHistory = draftKey.map(fullHistoryThreadKeys.contains) ?? false
        // Not due yet: one wakeup at the moment it is.
        let due = tokens == nil && !dismissed
            ? ComposerCompaction.offerStart(driver: provider?.driver, usedTokens: contextWindow?.used, updatedAt: contextWindow?.updatedAt,
                                            promptCacheTtlMs: contextWindow?.promptCacheTtlMs).flatMap { $0 > now ? $0 : nil }
            : nil
        if resumeOfferWork?.due != due {
            resumeOfferWork?.work.cancel()
            resumeOfferWork = nil
            if let due {
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.resumeOfferWork = nil; self?.refresh() } }
                resumeOfferWork = (due, work)
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + due.timeIntervalSince(now) + 1, execute: work)
            }
        }
    }

    /// The "Context window indicator" setting; Redesign always shows its ring under the composer, as Capy does.
    fileprivate var meterEnabled: Bool {
        ClientSettingsStore.shared.current.bool("contextWindowMeterEnabled") || ThemeRuntime.isDither(dark: composer.effectiveAppearance.isDark)
    }

    /// `shouldReserveContextWindowMeter` (ChatComposer.tsx:2385-2392): the meter's slot stays while a started
    /// thread's detail loads.
    fileprivate func updateMeterSlot() {
        let meter = composer.contextWindowMeter
        let thread = shellThread
        let loading = openThreadId.map { syncStatus.key == $0.rawValue && syncStatus.value == .loading } ?? false
        let reserved = ComposerCompaction.reservesMeter(
            meterEnabled: meterEnabled, detailLoading: loading,
            threadStarted: thread?.latestRunId != nil || thread?.latestUserMessageAt != nil,
            providerReportsContextWindow: menuProvider.map { $0.reportsContextWindow == true })
        guard reserved != meter.reserved else { return }
        meter.reserved = reserved
        composer.needsLayout = true
    }
}
