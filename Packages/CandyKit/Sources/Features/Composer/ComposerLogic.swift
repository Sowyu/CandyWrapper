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
    }

    /// One Return keydown, as `composerSubmissionIntentForKey` sees it.
    public struct Key: Sendable, Equatable {
        public var isReturn: Bool
        public var shift = false
        public var option = false
        /// Cmd or Ctrl.
        public var mod = false
        public var isRepeat = false
        public var composing = false
        public init(isReturn: Bool, shift: Bool = false, option: Bool = false, mod: Bool = false, isRepeat: Bool = false, composing: Bool = false) {
            self.isReturn = isReturn; self.shift = shift; self.option = option; self.mod = mod
            self.isRepeat = isRepeat; self.composing = composing
        }
    }

    /// `composerSubmissionIntentForKey` (composer-logic.ts:39-72), pinned by composer-logic.test.ts:80-158.
    /// Nil means "not a send": the editor handles the key (a newline for Return).
    public static func submitIntent(_ key: Key, prompt: String, mode: SendShortcut, turnRunning: Bool) -> SubmitIntent? {
        guard key.isReturn, !key.composing, !key.isRepeat, !key.shift, !key.option else { return nil }
        // `composer.sendAlternate` is mod+enter with `when: turnRunning`.
        if turnRunning, key.mod { return .alternate }
        let multiline = prompt.contains("\n") || prompt.contains("\r")
        let needsModifier = mode == .modEnter || (mode == .modEnterMultiline && multiline)
        if needsModifier, !key.mod { return nil }
        return .foreground
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
        public init(approvalPending: Bool = false, questionChoiceOnly: Bool? = nil, projectRequired: Bool = false,
                    noProvider: Bool = false, disconnected: Bool = false) {
            self.approvalPending = approvalPending; self.questionChoiceOnly = questionChoiceOnly
            self.projectRequired = projectRequired; self.noProvider = noProvider; self.disconnected = disconnected
        }
    }

    /// `composerPlaceholder.ts:1-2` and the rule list in I-composer-flow 7.2. The plan follow-up row is skipped (no plan mode yet).
    public static func placeholder(_ s: PlaceholderInput) -> String {
        if s.approvalPending { return "Resolve this approval request to continue" }
        if let choiceOnly = s.questionChoiceOnly {
            return choiceOnly ? "Choose an option above" : "Type your own answer, or leave this blank to use the selected option"
        }
        if s.projectRequired { return "Choose a project above to start a thread" }
        if s.noProvider { return "Enable a provider in Settings to send a message" }
        if s.disconnected { return "Ask for changes, send follow-ups, or attach images" }
        return "Ask anything, @tag files/folders, $use skills, or / for commands"
    }

    // MARK: Text

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

    /// The primary action button's look.
    public enum PrimaryAction: Sendable, Equatable {
        /// `update`: saving an edited queued message (a check).
        case send, stop, queue, steer, resume, busy, update
    }

    /// `ComposerDispatchMode` without `restart`, which the stock composer never produces.
    public enum SendMode: Sendable, Equatable { case auto, queue, steer }

    /// `resolveComposerDispatchMode` (client-runtime composerDispatch.ts:13-23). `steerByDefault`
    /// is the `followUpBehavior` setting (default queue); `alternate` is Cmd/Ctrl held.
    public static func sendMode(running: Bool, alternate: Bool, steerByDefault: Bool) -> SendMode {
        guard running else { return .auto }
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
        case .queue: return (.object(["type": .string("queue_after_active")]), nil)
        case .auto: return (.object(["type": .string("start_immediately")]), "auto")
        case .steer: return (.object(["type": .string("start_immediately")]), "steer")
        }
    }

    // MARK: Queue

    /// `deriveThreadQueueWorkflowState` (client-runtime threadWorkflows.ts:127-163) plus the
    /// optimistic queued messages the strip shows as "saving" (QueuedRunsControl.tsx:130-132).
    public struct QueueState: Sendable, Equatable {
        public struct Item: Sendable, Equatable {
            /// Nil while the message is still optimistic: every action is disabled.
            public var runId: RunId?
            public var messageId: MessageId?
            public var text: String
            public init(runId: RunId?, messageId: MessageId?, text: String) {
                self.runId = runId; self.messageId = messageId; self.text = text
            }
        }
        public var items: [Item] = []
        /// `resolveActiveThreadRun`: the last `preparing`, `starting`, `running` or `waiting` run.
        public var activeRunId: RunId?
        public var isHeld = false
        public var canReorder = false
        public var canPromoteToSteer = false
        public init(items: [Item] = [], activeRunId: RunId? = nil, isHeld: Bool = false, canReorder: Bool = false, canPromoteToSteer: Bool = false) {
            self.items = items; self.activeRunId = activeRunId; self.isHeld = isHeld
            self.canReorder = canReorder; self.canPromoteToSteer = canPromoteToSteer
        }

        /// `optimistic`: sent messages the stream hasn't confirmed; the queued ones show as saving.
        public init(projection: ThreadProjection?, optimistic: [ChatMessage] = []) {
            let saving = optimistic.filter { $0.inputIntent == .queuedTurn }
            guard let p = projection else {
                items = saving.map { Item(runId: nil, messageId: $0.id, text: $0.text) }
                return
            }
            let active: Set<ThreadStatus> = [.preparing, .starting, .running, .waiting]
            let activeRun = p.runs.last { active.contains($0.status) }
            activeRunId = activeRun?.id
            let automatic = Set(p.messages.filter { $0.delegatedCompletion != nil || $0.notification != nil }.map(\.id))
            let queued = p.runs.filter { $0.status == .queued && !($0.userMessageId.map(automatic.contains) ?? false) }
                .sorted { ($0.queuePosition ?? $0.ordinal, $0.ordinal) < ($1.queuePosition ?? $1.ordinal, $1.ordinal) }
            let texts = Dictionary(p.messages.map { ($0.id, $0.text) }, uniquingKeysWith: { _, b in b })
            items = queued.map { Item(runId: $0.id, messageId: $0.userMessageId, text: $0.userMessageId.flatMap { texts[$0] } ?? "Queued message") }
            // Optimistic queued sends the projection doesn't list yet go last.
            items += saving.filter { texts[$0.id] == nil }.map { Item(runId: nil, messageId: $0.id, text: $0.text) }
            isHeld = p.runs.contains { $0.status == .queued && $0.queueHeld == true }
            let turns = Self.providerSession(p)?["capabilities"]?["turns"]
            canReorder = turns?["supportsQueuedMessages"] == .bool(true)
            let steerable = activeRun?.status == .running && activeRun?.activeAttemptId != nil && p.providerTurns.contains {
                $0["runAttemptId"]?.stringValue == activeRun?.activeAttemptId?.rawValue && $0["status"]?.stringValue == "running"
            }
            canPromoteToSteer = steerable && (turns?["supportsActiveSteering"] == .bool(true) || turns?["supportsSteeringByInterruptRestart"] == .bool(true))
        }

        /// `resolveThreadProviderSession` (threadWorkflows.ts:64-88).
        static func providerSession(_ p: ThreadProjection) -> JSONValue? {
            let active: Set<ThreadStatus> = [.preparing, .starting, .running, .waiting]
            let providerThreadId = p.runs.last { active.contains($0.status) }?.providerThreadId ?? p.thread.activeProviderThreadId
            let attached = providerThreadId.flatMap { id in p.providerThreads.first { $0["id"]?.stringValue == id } }
                ?? p.providerThreads.first { $0["appThreadId"]?.stringValue == p.thread.id.rawValue && $0["providerSessionId"]?.stringValue != nil }
            if let sessionId = attached?["providerSessionId"]?.stringValue {
                return p.providerSessions.first { $0["id"]?.stringValue == sessionId }
            }
            return p.providerSessions.last { !["stopped", "error"].contains($0["status"]?.stringValue ?? "") }
        }

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

        /// The drag and arrow-key rule (QueuedRunsControl.tsx:180-190, 350-359): moving `index` to
        /// insert position `insert` (0...count) gives the run to go before, or nil for the end.
        /// Nil result `.none` means no move (dropped on itself or right after itself).
        public static func reorderTarget(_ items: [Item], moving index: Int, to insert: Int) -> RunId?? {
            guard items.indices.contains(index), insert >= 0, insert <= items.count, insert != index, insert != index + 1 else { return .none }
            return .some(insert < items.count ? items[insert].runId : nil)
        }
    }
}
