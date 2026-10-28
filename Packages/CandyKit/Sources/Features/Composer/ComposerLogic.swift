import Foundation
import T3Protocol
import T3Store

/// The composer's pure rules, ported from T3's web client. Spec: docs/research/I-composer-flow.md.
public enum ComposerLogic {
    /// Client setting `sendShortcut` (contracts settings.ts:455-457), default `enter`.
    public enum SendShortcut: String, Sendable, CaseIterable {
        case enter
        case modEnterMultiline = "mod-enter-multiline"
        case modEnter = "mod-enter"
    }

    /// What a keydown in the editor asks for.
    public enum SubmitIntent: Sendable, Equatable {
        case foreground
        /// Cmd/Ctrl+Enter while a turn runs: the follow-up action that isn't the default.
        case alternate
        /// `composer.sendBackground` (a draft) or `composer.sendAndNewThread` (a thread).
        case background
    }

    /// One Return keydown, as `composerSubmissionIntentForKey` sees it.
    public struct Key: Sendable, Equatable {
        public var isReturn: Bool
        public var shift = false
        public var option = false
        /// Command (`mod` on macOS).
        public var mod = false
        public var control = false
        public var isRepeat = false
        public var composing = false
        public init(isReturn: Bool, shift: Bool = false, option: Bool = false, mod: Bool = false, control: Bool = false,
                    isRepeat: Bool = false, composing: Bool = false) {
            self.isReturn = isReturn; self.shift = shift; self.option = option; self.mod = mod; self.control = control
            self.isRepeat = isRepeat; self.composing = composing
        }
    }

    /// `composerSubmissionIntentForKey` (composer-logic.ts:39-72), pinned by composer-logic.test.ts:80-158.
    /// The keybindings decide first (`composer.sendAlternate`, `composer.sendBackground`,
    /// `composer.sendAndNewThread` in the composer's context); any other bound command is not a send.
    /// Nil means "not a send": the editor handles the key (a newline for Return).
    public static func submitIntent(_ key: Key, prompt: String, mode: SendShortcut, turnRunning: Bool,
                                    isDraft: Bool = false, keymap: Keymap = .default) -> SubmitIntent? {
        guard key.isReturn, !key.composing, !key.isRepeat else { return nil }
        let stroke = KeyStroke(key: "enter", meta: key.mod, ctrl: key.control, shift: key.shift, alt: key.option)
        let needsModifier = requiresModifier(mode, prompt: prompt)
        let context = KeybindingContext(["composerFocus": true, "draftThreadRoute": isDraft, "turnRunning": turnRunning,
                                         "composerRequiresModifier": needsModifier])
        let command = keymap.resolve(stroke, context: context)
        if command == "composer.sendAlternate", turnRunning { return .alternate }
        if command == "composer.sendBackground", isDraft { return .background }
        if command == "composer.sendAndNewThread", !isDraft { return .background }
        guard command == nil, !key.shift, !key.option else { return nil }
        if needsModifier, !key.mod, !key.control { return nil }
        return .foreground
    }

    /// `composerRequiresModifier` (composer-logic.ts:49-57).
    public static func requiresModifier(_ mode: SendShortcut, prompt: String) -> Bool {
        mode == .modEnter || (mode == .modEnterMultiline && (prompt.contains("\n") || prompt.contains("\r")))
    }

    // MARK: Approvals

    /// A send while approvals are pending declines them first, then goes only if every one was declined,
    /// the draft stayed as sent, no approval arrived meanwhile and the thread is still open
    /// (ChatView.tsx:5222-5263, a93b03c8a5). `toast` is the info toast's title when it stops for a reason
    /// the user can act on; its description is "Send again when it's ready."
    public static func approvalRedirect(declined: Bool, draftChanged: Bool, approvalResponding: Bool, approvalArrived: Bool,
                                        threadChanged: Bool) -> (sends: Bool, toast: String?) {
        if declined, !draftChanged, !approvalArrived, !threadChanged { return (true, nil) }
        guard draftChanged || approvalResponding || (declined && approvalArrived) else { return (false, nil) }
        let title = draftChanged
            ? declined ? "Approval declined. Your message changed, so it wasn't sent." : "Your message changed, so it wasn't sent."
            : approvalResponding ? "An approval is already being answered, so your message wasn't sent."
            : "Another approval arrived, so your message wasn't sent."
        return (false, title)
    }

    // MARK: Placeholder

    /// The states `ChatComposer.tsx:7482-7499` reads, in priority order.
    public struct PlaceholderInput: Sendable, Equatable {
        public var approvalPending = false
        /// nil: no question open. true: choice only. false: custom answers allowed.
        public var questionChoiceOnly: Bool?
        public var projectRequired = false
        public var noProvider = false
        /// T3's session phase `disconnected`: the thread has no runtime yet (a draft or an unstarted thread).
        public var disconnected = false
        /// The shown approval takes the message as decline feedback (ChatComposer.tsx:3782-3785).
        public var approvalFeedback = false
        public init(approvalPending: Bool = false, questionChoiceOnly: Bool? = nil, projectRequired: Bool = false,
                    noProvider: Bool = false, disconnected: Bool = false) {
            self.approvalPending = approvalPending; self.questionChoiceOnly = questionChoiceOnly
            self.projectRequired = projectRequired; self.noProvider = noProvider; self.disconnected = disconnected
        }
    }

    /// `composerPlaceholder.ts:1-2` and the rule list in I-composer-flow 7.2. The plan follow-up row is skipped (no plan mode yet).
    public static func placeholder(_ s: PlaceholderInput, modern: Bool = false) -> String {
        // A send declines the approvals and redirects the agent (ChatComposer.tsx:6175-6177, a93b03c8a5).
        if s.approvalPending {
            return s.approvalFeedback ? "Send feedback to decline this request" : "Send a message to decline and redirect the agent"
        }
        if let choiceOnly = s.questionChoiceOnly {
            return choiceOnly ? "Choose an option above" : "Type your own answer, or leave this blank to use the selected option"
        }
        if s.projectRequired { return "Choose a project above to start a thread" }
        if s.noProvider { return "Enable a provider in Settings to send a message" }
        if modern { return "Ask anything. @ files, $ skills, / commands" }
        if s.disconnected { return "Ask for changes, send follow-ups, or attach images" }
        return "Ask anything, @tag files/folders, $use skills, or / for commands"
    }

    // MARK: Text

    /// `parseCodexFeedbackCommand` (client-runtime threadFeedback.ts:22-29): `/feedback`, then optionally a reason.
    public static func isCodexFeedbackCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^/feedback(?:\s+[\s\S]*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `PROVIDER_SEND_TURN_MAX_INPUT_CHARS` (contracts chatAttachment.ts:13).
    public static let maxInputCharacters = 120_000

    /// `getComposerPromptLengthValidationMessage` (composerSubmission.ts:12-23), without citations.
    /// Counts UTF-16 units, like JavaScript's `length`.
    public static func lengthValidationMessage(_ prompt: String) -> String? {
        let over = prompt.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count - maxInputCharacters
        guard over > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        let n = formatter.string(from: over as NSNumber) ?? "\(over)"
        let limit = formatter.string(from: maxInputCharacters as NSNumber) ?? "\(maxInputCharacters)"
        return "Prompt is \(n) character\(over == 1 ? "" : "s") over the \(limit)-character limit. Shorten or split it before sending."
    }

    /// `deriveThreadTitleSeed` (client-runtime operations/threadTitle.ts:16-56): the prompt with context
    /// links as their labels and citations as plain text; image links only count. An image-only message
    /// is "Attached image" or "Attached images", a file-only one "File: <name>".
    public static func threadTitleSeed(_ prompt: String, attachments: [(isImage: Bool, name: String)]) -> String {
        func normalize(_ s: String) -> String {
            ComposerInlineTokens.citationsToPlainText(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let ns = NSMutableString(string: prompt)
        var imageIds = Set<String>()
        for t in ComposerInlineTokens.collect(prompt).reversed() {
            guard case .context(let kind, let id, let label) = t.kind else { continue }
            if kind == "image" { imageIds.insert(id) }
            ns.replaceCharacters(in: t.range, with: kind == "image" ? "" : label)
        }
        let text = normalize(ns as String)
        if !text.isEmpty { return titleSeed(text) }
        let images = imageIds.isEmpty ? attachments.filter(\.isImage).count : imageIds.count
        if images > 0 { return images == 1 ? "Attached image" : "Attached images" }
        let name = normalize(attachments.first?.name ?? "")
        return name.isEmpty ? "New thread" : titleSeed("File: " + name)
    }

    /// `truncate` (packages/shared/src/String.ts:1-8) for the title seed: trimmed, cut at 50
    /// UTF-16 units with `...`; empty becomes "New thread".
    public static func titleSeed(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New thread" }
        let units = Array(trimmed.utf16)
        guard units.count > 50 else { return trimmed }
        let head = String(decoding: units.prefix(50), as: UTF16.self)
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    /// The first send of a draft (`startThreadTurn` with `bootstrap.createThread`,
    /// client-runtime/src/operations/commands.ts:640-686). The workspace strategy comes from the branch
    /// toolbar (`BranchToolbarLogic.workspaceStrategy`); a draft in "Current checkout" mode with no picked
    /// branch is a bare `root`. The server stores exactly that branch (ThreadLaunchService.ts:764-784).
    /// Checked 2026-10-10 against the official web client on the sandbox: same keys, same values.
    public static func launchThreadPayload(commandId: String, threadId: String, projectId: String, title: String,
                                           modelSelection: JSONValue, runtimeMode: String, interactionMode: String,
                                           messageId: String, text: String, context: JSONValue? = nil,
                                           attachments: [JSONValue] = [],
                                           workspaceStrategy: JSONValue = .object(["type": .string("root")])) -> JSONValue {
        OrchestrationCommands.launchThread(commandId: commandId, threadId: threadId, projectId: projectId, title: title,
                                           modelSelection: modelSelection, runtimeMode: runtimeMode, interactionMode: interactionMode,
                                           messageId: messageId, text: text, context: context, attachments: attachments,
                                           workspaceStrategy: workspaceStrategy)
    }

    // MARK: Run state

    /// What the primary action and the editor read from the thread's runs.
    public struct RunState: Sendable, Equatable {
        /// The newest `preparing`, `starting` or `running` run: what Stop interrupts (`activeRunId`).
        public var activeRunId: RunId?
        /// `derivePhase` is `running` (a run is `running` or `waiting`).
        public var running = false
        /// The latest executed run was interrupted: Resume continues it.
        public var resumableRunId: RunId?
        /// Queued runs Stop held (`queueHeld`).
        public var hasHeldQueuedRuns = false
        public init(activeRunId: RunId? = nil, running: Bool = false, resumableRunId: RunId? = nil, hasHeldQueuedRuns: Bool = false) {
            self.activeRunId = activeRunId; self.running = running
            self.resumableRunId = resumableRunId; self.hasHeldQueuedRuns = hasHeldQueuedRuns
        }

        /// `deriveCanInterruptRunningThread` (session-logic.ts:1087-1095).
        public var canInterrupt: Bool { running || activeRunId != nil }
        public var canResume: Bool { resumableRunId != nil || hasHeldQueuedRuns }

        public init(runs: [Run]) {
            let interruptible: Set<ThreadStatus> = [.preparing, .starting, .running]
            activeRunId = runs.last { interruptible.contains($0.status) }?.id
            running = runs.contains { $0.status == .running || $0.status == .waiting }
            hasHeldQueuedRuns = runs.contains { $0.status == .queued && $0.queueHeld == true }
            // `resolveResumableRun` (shared orchestrationV2ThreadError.ts:51-61): the latest run that
            // executed, skipping queued runs and runs cancelled before they started.
            // ponytail: no usage-limit failures yet (failed runs with a usage_limit error resume too); add with the usage panel
            let executed = runs.last { $0.status != .queued && !($0.status == .cancelled && $0.startedAt == nil) }
            resumableRunId = executed?.status == .interrupted ? executed?.id : nil
        }
    }

    /// Why the thread blocks a send, the `sendDisabledReason` ChatView passes the composer
    /// (ChatView.tsx:11618-11632), in T3's order. "This connection cannot change threads.",
    /// "Preparing machine" and "Sending feedback" are left out: CandyWrapper has no read-only
    /// pairings, machine switch or Codex feedback yet.
    public struct SendBlock: Sendable, Equatable {
        /// `isRevertingCheckpoint`: a rollback or prompt rewind is running.
        public var rewinding = false
        /// `threadDetailLoading`: the thread syncs with no detail yet (`resolveThreadSyncPhase` "loading").
        public var detailLoading = false
        /// `worktreeSetupBlocksSend` (ChatView.tsx:4024-4027).
        public var preparingWorktree = false
        /// `projectCloneSendBlockReason` (ChatView.tsx:2527-2533).
        public var projectClone: String?
        public init(rewinding: Bool = false, detailLoading: Bool = false, preparingWorktree: Bool = false, projectClone: String? = nil) {
            self.rewinding = rewinding; self.detailLoading = detailLoading
            self.preparingWorktree = preparingWorktree; self.projectClone = projectClone
        }
        public var reason: String? {
            rewinding ? "Rewinding conversation" : detailLoading ? "Messages loading"
                : preparingWorktree ? "Preparing worktree" : projectClone
        }
    }

    /// `worktreeSetupBlocksSend` (ChatView.tsx:4024-4027 with `resolveWorktreeSetupProgress`,
    /// ChatView.logic.ts:271-288): a running setup blocks until its agent stage is done; with no
    /// snapshot, a run still preparing does.
    public static func worktreeSetupBlocksSend(phase: String?, agentDone: Bool, runPreparing: Bool) -> Bool {
        guard let phase else { return runPreparing }
        return phase == "running" && !agentDone
    }

    /// `projectCloneSendBlockReason` (ChatView.tsx:1339-1346 in 3473): nil without a clone (`running` nil), and
    /// "Copying files" while Add to another machine still copies ignored files into a finished clone.
    public static func projectCloneSendBlockReason(running: Bool?, done: Bool, copyingFiles: Bool = false) -> String? {
        if let running {
            if running { return "Cloning repository" }
            if !done { return "Repository not cloned" }
        }
        return copyingFiles ? "Copying files" : nil
    }

    /// `submitStatus` (ComposerPrimaryActions.tsx:292-304): the send button's tooltip and label while
    /// it cannot send. A lost environment wins over every other reason.
    /// `providerUnavailable`: connected, but blocked only by a missing provider, which says so instead.
    public static func submitStatus(environmentUnavailable: Bool, providerUnavailable: Bool = false, sendDisabledReason: String?,
                                    busy: Bool, editingQueued: Bool) -> String? {
        if environmentUnavailable { return providerUnavailable ? "Enable a provider to send a message" : "Environment disconnected" }
        if let sendDisabledReason { return sendDisabledReason }
        return busy ? (editingQueued ? "Updating queued message" : "Submitting message") : nil
    }

    /// The primary action button's look.
    public enum PrimaryAction: Sendable, Equatable {
        /// `update`: saving an edited queued message (a check).
        case send, stop, queue, steer, resume, busy, update
    }

    /// `ComposerDispatchMode` without `restart`, which the stock composer never produces.
    public enum SendMode: Sendable, Equatable { case auto, queue, steer }

    /// `resolveComposerDispatchMode` (client-runtime composerDispatch.ts:13-23). `steerByDefault`
    /// is the `followUpBehavior` setting (default queue); `alternate` is Cmd/Ctrl held.
    public static func sendMode(running: Bool, alternate: Bool, steerByDefault: Bool, canSteer: Bool = true) -> SendMode {
        guard running else { return .auto }
        guard canSteer else { return .queue }
        return steerByDefault != alternate ? .steer : .queue
    }

    /// `ComposerPrimaryActions.tsx:267-289`. While a queued message is being edited the button
    /// is the check, even with a run active (`isQueuing` is false while editing).
    public static func primaryAction(run: RunState, hasContent: Bool, busy: Bool, mode: SendMode, editingQueued: Bool = false) -> PrimaryAction {
        if busy { return .busy }
        if editingQueued { return .update }
        if run.canInterrupt, !hasContent { return .stop }
        if !hasContent, run.canResume { return .resume }
        switch mode {
        case .auto: return .send
        case .queue: return .queue
        case .steer: return .steer
        }
    }

    /// The `dispatchMode` and `deliveryIntent` for a send (I-composer-flow 1.3.1), assuming the
    /// server declares `serverResolvedCommandContext`: queue goes as `queue_after_active` without
    /// an intent, the rest start immediately and name the mode.
    public static func dispatch(_ mode: SendMode) -> (mode: JSONValue, deliveryIntent: String?) {
        switch mode {
        case .queue: OrchestrationCommands.dispatchMode(queue: true)
        case .auto: OrchestrationCommands.dispatchMode(queue: false)
        case .steer: OrchestrationCommands.dispatchMode(queue: false, intent: "steer")
        }
    }

    // MARK: Queue

    /// `deriveThreadQueueWorkflowState` (client-runtime threadWorkflows.ts:127-163) plus the
    /// optimistic queued messages the strip shows as "saving" (QueuedRunsControl.tsx:130-132).
    /// T3 3814 packages/client-runtime/src/queuedRunEdit.ts:72-76.
    public static func queuedEditBlockedReason(openQuestionCount: Int) -> String? {
        openQuestionCount > 0 ? "Answer the question to edit queued messages" : nil
    }

    public struct QueueState: Sendable, Equatable {
        public struct Item: Sendable, Equatable {
            /// Nil while the message is still optimistic: every action is disabled.
            public var runId: RunId?
            public var messageId: MessageId?
            public var text: String
            /// The original message carries the same attribution as a sent turn.
            public var message: ChatMessage?
            /// The owner can cancel a guest's queued message, but cannot rewrite it.
            public var guestName: String?
            public var isEditable: Bool { guestName == nil }
            public init(runId: RunId?, messageId: MessageId?, text: String, guestName: String? = nil, message: ChatMessage? = nil) {
                self.runId = runId; self.messageId = messageId; self.text = text; self.guestName = guestName; self.message = message
            }
        }
        public var items: [Item] = []
        /// `resolveActiveThreadRun`: the last `preparing`, `starting`, `running` or `waiting` run.
        public var activeRunId: RunId?
        public var isHeld = false
        public var canReorder = false
        public var promoteSkipsCompaction = false
        public var canPromoteToSteer = false
        /// No run is active on a live thread, so a queued message can start its own turn with
        /// `queued-run.start` (threadWorkflows.ts:156-160, 96f09c6558).
        public var canSendNow = false
        public init(items: [Item] = [], activeRunId: RunId? = nil, isHeld: Bool = false, canReorder: Bool = false,
                    canPromoteToSteer: Bool = false, canSendNow: Bool = false) {
            self.items = items; self.activeRunId = activeRunId; self.isHeld = isHeld; self.canReorder = canReorder
            self.canPromoteToSteer = canPromoteToSteer; self.canSendNow = canSendNow
        }

        /// `optimistic`: sent messages the stream hasn't confirmed; the queued ones show as saving.
        /// `canStartQueuedRun`: the server takes `queued-run.start`, which servers before Nightly 3486 reject.
        public init(projection: ThreadProjection?, optimistic: [ChatMessage] = [], canStartQueuedRun: Bool = true, canSkipCompaction: Bool = false) {
            let saving = optimistic.filter { $0.inputIntent == .queuedTurn }
            guard let p = projection else {
                items = saving.map { Item(runId: nil, messageId: $0.id, text: $0.text) }
                return
            }
            let active: Set<ThreadStatus> = [.preparing, .starting, .running, .waiting]
            let activeRun = p.runs.last { active.contains($0.status) }
            activeRunId = activeRun?.id
            canSendNow = canStartQueuedRun && activeRun == nil && p.thread.archivedAt == nil && p.thread.deletedAt == nil
            let automatic = Set(p.messages.filter { $0.delegatedCompletion != nil || $0.notification != nil }.map(\.id))
            let queued = p.runs.filter { $0.status == .queued && !($0.userMessageId.map(automatic.contains) ?? false) }
                .sorted { ($0.queuePosition ?? $0.ordinal, $0.ordinal) < ($1.queuePosition ?? $1.ordinal, $1.ordinal) }
            let messages = Dictionary(p.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            let texts = messages.mapValues(\.text)
            items = queued.map { run in
                let message = run.userMessageId.flatMap { messages[$0] }
                // A queued guest message shows the guest's words; the agent still gets the attributed text
                // (threadWorkflows.ts:146-147 at 3669).
                let guest = GuestMessageAttribution(message?.context?["guest"])
                let original: ChatMessage? = message.map { (message: ConversationMessage) in ChatMessage(id: message.id, role: .user, text: message.text, runId: message.runId,
                    createdAt: message.createdAt, createdBy: message.createdBy, creationSource: message.creationSource,
                    senderThreadId: message.senderThreadId, scheduledTaskId: message.scheduledTaskId, context: message.context, attachments: message.attachments ?? []) }
                return Item(runId: run.id, messageId: run.userMessageId,
                            text: original.map { UserMessagePresentation.resolve($0).text } ?? "Queued message", guestName: guest?.name, message: original)
            }
            // Optimistic queued sends the projection doesn't list yet go last.
            items += saving.filter { texts[$0.id] == nil }.map { Item(runId: nil, messageId: $0.id, text: $0.text) }
            isHeld = p.runs.contains { $0.status == .queued && $0.queueHeld == true }
            let turns = Self.providerSession(p)?["capabilities"]?["turns"]
            let steerable = activeRun?.status == .running && activeRun?.activeAttemptId != nil && p.providerTurns.contains {
                $0["runAttemptId"]?.stringValue == activeRun?.activeAttemptId?.rawValue && $0["status"]?.stringValue == "running"
            }
            // T3 3814 threadWorkflows.ts:130-142,170-174. Older runtimes silently ignore this command during compaction.
            promoteSkipsCompaction = canSkipCompaction && activeRun?.userMessageId.flatMap { messages[$0] }.map {
                ($0.attachments ?? []).isEmpty && $0.role == "user" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact"
            } == true
            canReorder = turns?["supportsQueuedMessages"] == .bool(true)
            canPromoteToSteer = promoteSkipsCompaction || steerable && (turns?["supportsActiveSteering"] == .bool(true) || turns?["supportsSteeringByInterruptRestart"] == .bool(true))
        }

        /// CandyWrapper's own themes keep the queue's manual reorder behavior.
        public static func reorderTarget(_ items: [Item], moving index: Int, to insert: Int) -> RunId?? {
            guard items.indices.contains(index), insert >= 0, insert <= items.count, insert != index, insert != index + 1 else { return .none }
            return .some(insert < items.count ? items[insert].runId : nil)
        }

        /// `resolveThreadProviderSession` (threadWorkflows.ts:64-88).
        static func providerSession(_ p: ThreadProjection) -> JSONValue? { ThreadRelationships.providerSession(p) }

        /// `threadSupportsProviderHandoff` (threadWorkflows.ts:90-108).
        public static func supportsProviderHandoff(_ p: ThreadProjection?) -> Bool {
            guard let p else { return false }
            if let session = providerSession(p) {
                return session["capabilities"]?["sessions"]?["supportsProviderSwitchingViaHandoff"] == .bool(true)
            }
            let active: Set<ThreadStatus> = [.preparing, .starting, .running, .waiting]
            if p.runs.contains(where: { active.contains($0.status) }) { return false }
            if p.thread.historyOrigin == "v1_import" || p.runs.isEmpty { return true }
            return p.providerThreads.contains { t in
                t["id"]?.stringValue == p.thread.activeProviderThreadId && t["appThreadId"]?.stringValue == p.thread.id.rawValue
                    && t["providerInstanceId"]?.stringValue == p.thread.raw["modelSelection"]?["instanceId"]?.stringValue
                    && t["nativeThreadRef"] != nil && t["nativeThreadRef"] != .null
            }
        }

        /// `hasStartedSession` is `activeRuntime !== null` (ChatView.tsx:10687): `deriveThreadRuntime`
        /// returns null only for a thread with no run and no active provider thread
        /// (client-runtime threadExecution.ts:248-255).
        // ponytail: ignores a pull request watch holding a run-less thread (backgroundWorkHoldsRun); add with PR watches
        public static func hasStartedSession(_ p: ThreadProjection?) -> Bool {
            guard let p else { return false }
            return !p.runs.isEmpty || p.thread.activeProviderThreadId != nil
        }

    }
}
