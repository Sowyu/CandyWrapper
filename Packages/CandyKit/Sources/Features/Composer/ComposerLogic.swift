import Foundation
import T3Protocol

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
        case send, stop, queue, steer, resume, busy
    }

    /// `ComposerDispatchMode` without `restart`, which the stock composer never produces.
    public enum SendMode: Sendable, Equatable { case auto, queue, steer }

    /// `resolveComposerDispatchMode` (client-runtime composerDispatch.ts:13-23). `steerByDefault`
    /// is the `followUpBehavior` setting (default queue); `alternate` is Cmd/Ctrl held.
    public static func sendMode(running: Bool, alternate: Bool, steerByDefault: Bool) -> SendMode {
        guard running else { return .auto }
        return steerByDefault != alternate ? .steer : .queue
    }

    /// `ComposerPrimaryActions.tsx:267-289`.
    public static func primaryAction(run: RunState, hasContent: Bool, busy: Bool, mode: SendMode) -> PrimaryAction {
        if busy { return .busy }
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
}
