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
    /// A new thread that exists only here until its first send (T3's `DraftSessionState`). Both ids
    /// are scoped: the project's environment is where the thread will be created.
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
    private let environments: Environments
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
    /// `server.getConfig` providers and settings per environment, followed through `subscribeServerConfig`
    /// on each environment's session (T3 follows every environment's config, CR/state/server.ts:437).
    private var serverConfigs: [String: ServerProviderConfig] = [:]
    private var configSubscriptions: [String: (shell: ShellSession, task: Task<Void, Never>)] = [:]
    private var serverConfig: ServerProviderConfig {
        targetEnvironmentId.flatMap { serverConfigs[$0] } ?? ServerProviderConfig(providers: [])
    }

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

    /// Files attached to question answers, by `questionKey` (T3's `questionAttachmentDraftId`).
    fileprivate var questionFiles: [String: [QuestionFile]] = [:]
    /// Each environment's `questionAttachments` capability and upload limit (`fileAttachmentStagingLimit`),
    /// read from `/.well-known/t3/environment` when its session changes.
    fileprivate var capabilities: [String: (questionAttachments: Bool, uploadLimit: Int?)] = [:]
    fileprivate var supportsQuestionAttachments: Bool { targetEnvironmentId.flatMap { capabilities[$0]?.questionAttachments } ?? false }
    fileprivate var fileUploadLimit: Int? { targetEnvironmentId.flatMap { capabilities[$0]?.uploadLimit } }
    private var capabilityTasks: [String: Task<Void, Never>] = [:]

    // Persisted like T3's `t3code:composer-drafts:v1`: prompts by draft key, sessions by scoped project id.
    // v2 sessions hold scoped ids; v1 (one environment) is read once and scoped by its key's prefix.
    private static let promptsKey = "composer.prompts.v1", sessionsKey = "composer.draftSessions.v2"
    private static let sessionsKeyV1 = "composer.draftSessions.v1"
    private var prompts: [String: String]
    private var sessions: [String: DraftSession]
    private var saveWork: DispatchWorkItem?

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
        composer.onSend = { [weak self] text, mode in self?.send(text, mode: mode) }
        composer.onStop = { [weak self] in self?.stop() }
        composer.onResume = { [weak self] in self?.resume() }
        composer.onTextChange = { [weak self] text in self?.remember(text) }
        panel.hero.onPickProject = { [weak self] anchor in self?.pickProject(from: anchor) }
        panel.contextStrip.runOn.onChange = { [weak self] env in self?.changeEnvironment(env) }
        composer.stageArt = sidebar.stage != .none
        composer.footerControls = [pickers.controlsView]
        pickers.onPromptChange = { [weak self] text in
            guard let self else { return }
            composer.text = text
            remember(text)
        }
        pickers.onBlocked = { [weak self] reason in self?.report(.modelChangeBlocked(reason), key: nil) }
        panel.errorBanner.onDismiss = { [weak self] in self?.dismissThreadError() }
        composer.historyMessages = { [weak self] in self?.historyMessages() ?? [] }
        pickers.onChange = { [weak self] _ in self?.composer.needsLayout = true }
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
        let question = panel.questionPanel
        question.onSubmit = { [weak self] payload in self?.submitAnswers(payload) }
        composer.onAttach = { [weak self] in self?.attachToQuestion() }
        composer.fileList.onRemove = { [weak self] id in self?.removeQuestionFile(id) }
        composer.fileList.onRetry = { [weak self] id in self?.retryQuestionFile(id) }
        question.onDismiss = { [weak self] payload in self?.respond(payload, failure: ComposerFeedback.Failure.dismissQuestion) }
        question.onDisplacedAnswer = { [weak self] text in self?.carryDisplaced(text) }
        question.onChange = { [weak self] in self?.syncQuestion() }
        composer.onQuestionAdvance = { [weak self] in self?.panel.questionPanel.advance() }
        composer.onQuestionPrevious = { [weak self] in self?.panel.questionPanel.previous() }
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

    /// The session (shell) of the target's environment. Nil while that environment is disconnected.
    private var shell: ShellSession? { environments.session(targetEnvironmentId) }

    private var targetEnvironmentId: String? {
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
        }
        refresh()
    }

    /// `subscribeServerConfig`: a snapshot first, then provider and settings updates (protocol.md 1562).
    private func subscribeConfig(_ shell: ShellSession) -> Task<Void, Never> {
        let env = shell.environmentId
        let stream = shell.supervisor.subscribe("subscribeServerConfig", payload: { .object([:]) }, handler: { [weak self] event in
            guard case .value(let json) = event, let change = try? json.decode(as: ServerConfigEvent.self) else { return }
            await MainActor.run { self?.configChanged(change, environmentId: env) }
        })
        return stream
    }

    private func configChanged(_ event: ServerConfigEvent, environmentId: String) {
        var config = serverConfigs[environmentId] ?? ServerProviderConfig(providers: [])
        switch event {
        case .snapshot(let snapshot): config = snapshot
        case .providerStatuses(let providers): config.providers = providers
        case .settingsUpdated(let settings): config.settings = settings
        case .keybindingsUpdated(let rules): config.keybindings = rules
        case .other: return
        }
        serverConfigs[environmentId] = config
        // App shortcuts follow the primary environment's keybindings (`primaryServerKeybindingsAtom`).
        if environmentId == environments.primaryId { ActiveKeymap.setServerRules(config.keybindings) }
        environments.setIconOverride(environmentId, config.settings.environmentIcon)
        if environmentId == targetEnvironmentId { refresh() }
    }

    /// A removed environment: its drafts, prompts, picks, question files, config and capabilities go
    /// (T3's `clearComposerDraftsEnvironment`, composerDraftStore.ts:4419-4450, plus the rest).
    func environmentRemoved(_ environmentId: String) {
        let prefix = environmentId + ":"
        configSubscriptions.removeValue(forKey: environmentId)?.task.cancel()
        capabilityTasks.removeValue(forKey: environmentId)?.cancel()
        serverConfigs[environmentId] = nil
        capabilities[environmentId] = nil
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
        // Digits 1 to 9 pick a question's option unless focus is in an editable field
        // (ComposerPendingUserInputPanel.tsx:157-182, a document-level listener, not a keybinding).
        shortcuts.onKey { [weak self] event in
            guard let self, self.isActive, self.panel.drawer == .question, !self.panel.questionPanel.isHidden,
                  !Shortcuts.editableFocused(in: event.window) else { return false }
            return self.panel.questionPanel.handleKey(event)
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
        // `composer.host`: opens "Run on" when it can choose (ChatView.tsx:8183-8192).
        shortcuts.on("composer.host") { [weak self] call in
            guard let self, self.isActive else { return false }
            if !call.isRepeat, !self.panel.contextStrip.isHidden { self.panel.contextStrip.runOn.open() }
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
                  let latest = self.panel.queue.state.items.last(where: { $0.runId != nil }),
                  self.queuedEdit == nil, !self.queueBusy else { return false }
            if !call.isRepeat {
                self.panel.queue.expand()
                self.beginEdit(latest)
            }
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

    /// Keybinding context keys the composer owns.
    var shortcutContext: [String: Bool] {
        ["composerFocus": composer.isEditorFocused, "modelPickerOpen": pickers.isModelPickerOpen,
         "turnRunning": composer.runState.canInterrupt]
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
        projection = nil
        requests = PendingRequests()
        optimistic = carried
        if carried.isEmpty { pendingMessageId = nil }
        resuming = false
        loadPrompt()
        syncSidebarDrafts()
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
    private func showDraft(_ project: ProjectShell, stored: DraftSession? = nil) {
        let group = group(of: project.id)
        let key = group?.key ?? project.id.rawValue
        var session: DraftSession
        if let stored {
            session = stored
        } else if var existing = storedSession(key, members: Set(group?.memberProjectIds ?? [project.id])) {
            if existing.projectId != project.id.rawValue, target != .draft(existing),
               (prompts[existing.draftId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Self.retarget(&existing, to: project)
                sessions[key] = existing
            }
            session = existing
        } else {
            let threadId = ThreadId(UUID().uuidString.lowercased()).scoped(to: project.id.environmentId ?? "")
            session = DraftSession(draftId: UUID().uuidString.lowercased(), threadId: threadId.rawValue,
                                   projectId: project.id.rawValue, createdAt: Date())
            sessions[key] = session
        }
        flushPrompt()
        queuedEdit = nil
        questionRequestId = nil
        target = .draft(session)
        projection = nil
        requests = PendingRequests()
        optimistic = []
        pendingMessageId = nil
        sidebar?.state.activeThreadId = nil
        // The hero names the group (`activeProjectDisplayName`, DraftHeroHeadline.tsx:143-144).
        panel.setDraft(projectTitle: group?.label ?? project.title)
        // T3 keeps the right panel per thread (rightPanelStore.ts); a draft opens with it closed.
        // ponytail: drafts don't remember an opened panel; key the state by draft id if that shows
        panel.setRightPanelOpen(false)
        loadPrompt()
        scheduleSave()
        syncSidebarDrafts()
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
            panel.showsContextStrip = false
            return
        }
        let targets = runOnTargets(group)
        let env = ProjectId(session.projectId).environmentId
        let runOn = panel.contextStrip.runOn
        runOn.options = targets.map(\.option)
        runOn.selectedId = env
        runOn.locked = targets.count < 2 || pendingMessageId != nil
        panel.showsContextStrip = targets.count > 1 || (env != nil && env != sidebarEnvironments.primaryId)
    }

    /// `onEnvironmentChange` (ChatView.tsx:4450-4517): the open draft moves to the group's member on that
    /// machine, keeping its prompt, picks, draft id and thread id. The pick is stored with the draft.
    private func changeEnvironment(_ environmentId: String) {
        guard case .draft(var session) = target, pendingMessageId == nil,
              let group = group(of: ProjectId(session.projectId)),
              let project = runOnTargets(group).first(where: { $0.option.environmentId == environmentId })?.project,
              project.id.rawValue != session.projectId else { return }
        flushPrompt()
        let key = sessions.first { $0.value.draftId == session.draftId }?.key ?? group.key
        Self.retarget(&session, to: project)
        sessions[key] = session
        target = .draft(session)
        scheduleSave()
        refresh()
        syncSidebarDrafts()
    }

    /// The hero's project menu (DraftHeroHeadline.tsx:236-310): one radio row per project group, the open
    /// one first and checked, each with the machine badge while projects span environments. Picking a group
    /// opens its draft on the member in the current draft's environment, else its representative
    /// (`buildSidebarProjectPickerEntries`, sidebarProjectGrouping.ts:136-176).
    // ponytail: no favicons, "No project" or "Add project" rows; add them with scratch threads and Add Project
    private func pickProject(from anchor: NSView) {
        guard let snapshot = sidebar?.snapshot, case .draft(let current) = target else { return }
        let envs = sidebarEnvironments
        let currentId = ProjectId(current.projectId)
        var groups = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: envs.primaryId)
        if let i = groups.firstIndex(where: { $0.memberProjectIds.contains(currentId) }), i > 0 {
            groups.insert(groups.remove(at: i), at: 0)
        }
        let badges = SidebarEnvironments.span(groups)
        let items = groups.map { group in
            let active = group.memberProjectIds.contains(currentId)
            var item = MenuItem.radio(group.label, checked: active)
            item.closesOnClick = true
            if badges, let badge = envs.badge(group) {
                item.badge = EnvironmentMachineIcon.definition(badge.machine)
                item.badgeTooltip = badge.description
            }
            let project = group.members.first { $0.id == currentId }
                ?? group.members.first { $0.id.environmentId == currentId.environmentId } ?? group.representative
            item.action = { [weak self] in if !active { self?.showDraft(project) } }
            return item
        }
        MenuPopupView.show(items, from: anchor, placement: PopupPlacement(side: .bottom, align: .center, sideOffset: 4))
    }

    // MARK: Prompts

    private func loadPrompt() {
        composer.resetPromptHistory()
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
        syncSidebarDrafts()
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

    private func refresh() {
        let runs = projection?.runs ?? []
        composer.runState = ComposerLogic.RunState(runs: runs)
        composer.isDraftRoute = panel.isDraft
        composer.isBusy = pendingMessageId != nil || resuming
        var placeholder = ComposerLogic.PlaceholderInput()
        // T3's `phase === "disconnected"` means the thread has no runtime (`derivePhase(activeRuntime)`,
        // session-logic.ts:1069-1078), not a lost connection: drafts and unstarted threads get it.
        // ponytail: ignores the PR-watch background work that also creates a runtime; add it with PR watches
        placeholder.disconnected = !ComposerLogic.QueueState.hasStartedSession(projection)
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
        updateRunOn()
        let banner = draftKey.flatMap { threadErrors.visible($0, shell: shellThread) }
        if banner != panel.errorBanner.banner {
            panel.errorBanner.banner = banner
            panel.needsLayout = true
        }
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
            panel.approvalPanel.configure(approval, pendingCount: requests.approvals.count, threadId: threadId.localId)
            panel.approvalPanel.isResponding = responding.contains(approval.requestId)
            panel.drawer = .approval
            composer.pending = .approval
        } else if let input = requests.activeUserInput {
            let question = panel.questionPanel
            question.configure(input, threadId: threadId.localId)
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
        composer.fileRows = []
        pruneQuestionFiles()
        composer.text = draftKey.flatMap { prompts[$0] } ?? ""
        pickers.prompt = composer.text
    }

    /// The question card changed (pick, typing, next, previous): the editor, placeholder and
    /// footer follow its active question.
    private func syncQuestion() {
        guard questionRequestId != nil, panel.questionPanel.session != nil else { return }
        // Files first: their state feeds the session that the footer reads below.
        syncQuestionFiles()
        guard let session = panel.questionPanel.session else { return }
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
    private func respond(_ payload: JSONValue, failure: @escaping (String?) -> ComposerFeedback.Failure) {
        guard let shell, case .string(let requestId)? = payload["requestId"], !responding.contains(requestId) else { return }
        let key = draftKey
        responding.insert(requestId)
        refresh()
        let supervisor = shell.supervisor
        Task { [weak self] in
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload) } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport {} else {
                    self?.report(failure(Self.message(error)), key: key)
                }
            }
            self?.responding.remove(requestId)
            self?.refresh()
        }
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
            report(.noModel, key: picksKey)
            return
        }
        // The send goes ahead: the thread's local error clears (ChatView.tsx:9782).
        if let picksKey { threadErrors.set(picksKey, nil) }
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
            let payload = ComposerLogic.launchThreadPayload(
                commandId: commandId, threadId: EnvironmentScope.localId(of: session.threadId),
                projectId: EnvironmentScope.localId(of: session.projectId), title: title,
                modelSelection: selectionJSON, runtimeMode: picks.runtimeMode.rawValue,
                interactionMode: picks.interactionMode.rawValue, messageId: messageId.rawValue, text: trimmed)
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
                    self?.sendFailed(error, messageId: messageId, text: text, draft: session, key: picksKey)
                }
            }
        case .thread(let threadId):
            let (dispatchMode, deliveryIntent) = ComposerLogic.dispatch(mode)
            var command: [String: JSONValue] = [
                "type": .string("message.dispatch"), "commandId": .string(commandId), "createdBy": .string("user"),
                "creationSource": .string("web"), "threadId": .string(threadId.localId.rawValue), "messageId": .string(messageId.rawValue),
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
                            "threadId": .string(threadId.localId.rawValue), "runtimeMode": .string(runtimeChange.rawValue)]))
                    }
                    if let interactionChange {
                        _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object([
                            "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString.lowercased()),
                            "threadId": .string(threadId.localId.rawValue), "interactionMode": .string(interactionChange.rawValue)]))
                    }
                    _ = try await supervisor.request("orchestration.dispatchCommand", payload: .object(command))
                    if let picksKey { self?.pickers.store.didSend(picksKey) }
                    self?.refresh()
                } catch {
                    self?.sendFailed(error, messageId: messageId, text: text, draft: nil, key: picksKey)
                }
            }
        }
    }

    /// I-composer-flow 1.7: drop the optimistic row, restore the text if the composer is still
    /// empty, and show the server's message (transport errors stay silent).
    private func sendFailed(_ error: Error, messageId: MessageId, text: String, draft: DraftSession?, key: String?) {
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
        report(.send(Self.message(error)), key: key)
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
        return messages.map { PromptHistory.Message(id: $0.id.rawValue, isUser: $0.role == .user, text: $0.text) }
    }

    /// The server's message for a failed command, else nil for the caller's fallback.
    private static func message(_ error: Error) -> String? {
        (error as? RPCClientError)?.typedError?.message
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
            "threadId": .string(threadId.localId.rawValue), "runId": .string(runId.rawValue), "holdQueue": .bool(true),
        ])
        let supervisor = shell.supervisor
        let key = draftKey
        Task { [weak self] in
            do { _ = try await supervisor.request("orchestration.dispatchCommand", payload: payload) } catch {
                if let rpc = error as? RPCClientError, rpc.isTransport { return }
                self?.report(.interrupt(Self.message(error)), key: key)
            }
        }
    }

    /// Resume (ChatView.tsx:8656-8730): continue an interrupted run, then release held queued runs.
    private func resume() {
        guard let shell, case .thread(let threadId) = target, let projection, !resuming else { return }
        let state = ComposerLogic.RunState(runs: projection.runs)
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

    var row: ComposerFileRow { ComposerFileRow(id: id, name: name, sizeBytes: sizeBytes, status: status) }
    /// `ChatFileAttachment`: `{type, id, name, mimeType, sizeBytes}`.
    var attachment: JSONValue? {
        guard status == .ready, let attachmentId else { return nil }
        return .object(["type": .string("file"), "id": .string(attachmentId), "name": .string(name),
                        "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))])
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
            capabilities[environmentId] = (descriptor.capability("questionAttachments"), limit)
            refresh()
        }
    }

    /// The active question's key, when it can take files.
    private var activeQuestionKey: String? {
        guard case .thread(let threadId) = target, let requestId = questionRequestId,
              let question = panel.questionPanel.session?.progress.activeQuestion else { return nil }
        return Self.questionKey(threadId, requestId, question.id)
    }

    /// The question's file list and the attachment state the answer rules read. Files of requests
    /// that are no longer pending are released (ChatView.tsx:3374-3398).
    fileprivate func syncQuestionFiles() {
        pruneQuestionFiles()
        composer.fileRows = activeQuestionKey.map { (questionFiles[$0] ?? []).map(\.row) } ?? []
        guard let session = panel.questionPanel.session, case .thread(let threadId) = target else { return }
        var states: [String: UserInputSession.AttachmentState] = [:]
        for q in session.request.questions {
            let files = questionFiles[Self.questionKey(threadId, session.request.requestId, q.id)] ?? []
            if !files.isEmpty {
                states[q.id] = .init(count: files.count, blocked: !supportsQuestionAttachments || files.contains { $0.status != .ready })
            }
        }
        panel.questionPanel.setAttachments(states)
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
        guard let requestId = questionRequestId, let session = panel.questionPanel.session, let key = activeQuestionKey,
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
        guard let session = panel.questionPanel.session, session.request.requestId == requestId, case .thread(let threadId) = target else { return }
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

    /// `runUpload`: mint a signed upload URL, POST the bytes with their content type, report progress
    /// in 5% steps, and fail with T3's reasons.
    private func upload(_ id: String, key: String) {
        guard let file = questionFiles[key]?.first(where: { $0.id == id }) else { return }
        guard let shell else { updateFile(id, key: key) { $0.status = .failed("This connection cannot upload attachments.") }; return }
        let supervisor = shell.supervisor, base = shell.http.baseURL
        let task = Task { [weak self] in
            let reason: String
            do {
                let minted = try await supervisor.request("attachments.createUploadUrl", payload: .object([
                    "type": .string("file"), "name": .string(file.name), "mimeType": .string(file.mimeType), "sizeBytes": .number(Double(file.sizeBytes))]))
                guard case .string(let attachmentId)? = minted["attachmentId"], case .string(let relative)? = minted["relativeUrl"],
                      let url = URL(string: relative, relativeTo: base)?.absoluteURL else { throw URLError(.badServerResponse) }
                if Task.isCancelled {
                    _ = try? await supervisor.request("attachments.delete", payload: .object(["attachmentId": .string(attachmentId)]))
                    return
                }
                self?.updateFile(id, key: key) { $0.attachmentId = attachmentId }
                var request = URLRequest(url: url, timeoutInterval: 600)
                request.httpMethod = "POST"
                request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
                let progress = UploadProgress { p in
                    Task { @MainActor in
                        self?.updateFile(id, key: key) { f in
                            if case .uploading(let old) = f.status, Int(old * 20) == Int(p * 20) { return }
                            f.status = .uploading(p)
                        }
                    }
                }
                let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file.url, delegate: progress)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw UploadRejected(status: status) }
                self?.updateFile(id, key: key) { $0.status = .ready }
                return
            } catch let rejected as UploadRejected {
                reason = "Upload rejected (\(rejected.status))"
            } catch let error as URLError where error.code == .timedOut {
                reason = "Upload timed out"
            } catch {
                if Task.isCancelled { return }
                reason = "Upload failed"
            }
            self?.updateFile(id, key: key) { $0.status = .failed(reason) }
        }
        updateFile(id, key: key) { $0.task = task }
    }

    private struct UploadRejected: Error { let status: Int }

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
        respond(.object(fields), failure: ComposerFeedback.Failure.userInput)
    }
}
