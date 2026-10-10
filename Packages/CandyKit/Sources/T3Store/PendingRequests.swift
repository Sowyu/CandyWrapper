import Foundation
import T3Protocol

// Approvals and questions the composer answers (I-composer-flow.md section 3). Ports of
// `derivePendingThreadRequests` and `seedUserInputDraftAnswers` (client-runtime/src/state/
// threadRequests.ts:45-115), `pendingUserInput.ts` (apps/web/src) and the respond commands
// (client-runtime/src/operations/commands.ts:834-870). The answered history in the timeline is
// `TimelineEntries.projectingQuestionHistory`.

/// `ProviderApprovalDecision` (providerPolicy.ts:50-56).
public struct ApprovalDecision: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let accept: Self = "accept"
    public static let acceptForSession: Self = "acceptForSession"
    public static let acceptAlways: Self = "acceptAlways"
    public static let decline: Self = "decline"
    public static let cancel: Self = "cancel"
}

/// `ProviderApprovalOption` (providerPolicy.ts:59-64).
public struct ApprovalOption: Hashable, Sendable, Decodable {
    public var decision: ApprovalDecision
    public var label: String
    /// A provider caution (prompt injection and the like): a warning triangle and a tooltip.
    public var warning: String?

    public init(_ decision: ApprovalDecision, _ label: String, warning: String? = nil) {
        self.decision = decision
        self.label = label
        self.warning = warning
    }

    /// The web client's list when the provider sends none (ComposerPendingApprovalActions.tsx:25-30).
    public static let defaults: [ApprovalOption] = [
        ApprovalOption(.cancel, "Cancel"), ApprovalOption(.decline, "Decline"),
        ApprovalOption(.acceptForSession, "Always allow this session"), ApprovalOption(.accept, "Approve"),
    ]
}

public struct PendingApproval: Hashable, Sendable {
    public var requestId: String
    public var requestKind: RuntimeRequestKind
    public var createdAt: T3Timestamp?
    /// The command line, file path or description (`approval_request.prompt`).
    public var detail: String?
    /// The app asking, for `mcp-elicitation`.
    public var appName: String?
    /// Provider choices; nil means `ApprovalOption.defaults`.
    public var options: [ApprovalOption]?
    /// Only `live` requests can be answered; anything else reads as `not_resumable`.
    public var canRespond: Bool

    public init(requestId: String, requestKind: RuntimeRequestKind, createdAt: T3Timestamp? = nil, detail: String? = nil,
                appName: String? = nil, options: [ApprovalOption]? = nil, canRespond: Bool = true) {
        self.requestId = requestId
        self.requestKind = requestKind
        self.createdAt = createdAt
        self.detail = detail
        self.appName = appName
        self.options = options
        self.canRespond = canRespond
    }

    public var effectiveOptions: [ApprovalOption] { options ?? ApprovalOption.defaults }
    /// Decline and accept are buttons, the rest go in the ellipsis menu.
    public var buttonOptions: [ApprovalOption] { effectiveOptions.filter { $0.decision == .decline || $0.decision == .accept } }
    public var menuOptions: [ApprovalOption] { effectiveOptions.filter { $0.decision != .decline && $0.decision != .accept } }

    /// ComposerPendingApprovalPanel.tsx:16-25.
    public var label: String {
        switch requestKind {
        case .mcpElicitation: "App access approval"
        case .command: "Command approval"
        case .fileRead: "File read approval"
        case .permission: "App permission approval"
        default: "File change approval"
        }
    }

    /// The panel's detail line (the source uses an em dash in the gone message).
    public var detailText: String {
        if !canRespond { return "Provider process is gone — interrupt or restart the run to respond." }
        if let detail, !detail.isEmpty { return detail }
        return label
    }
}

/// `OrchestrationV2UserInputQuestion` (orchestrationV2.ts:1151-1167).
public struct UserInputQuestion: Hashable, Sendable, Decodable {
    public struct Option: Hashable, Sendable, Decodable {
        public var label: String
        public var description: String
        public var value: String?
        public init(label: String, description: String, value: String? = nil) {
            self.label = label
            self.description = description
            self.value = value
        }
        /// What the answer carries: `value ?? label`.
        public var identity: String { value ?? label }
    }

    public var id: String
    public var header: String
    public var question: String
    public var options: [Option]
    public var multiSelect: Bool
    /// False means choice-only; absent means true.
    public var allowCustomAnswer: Bool?
    public var initialAnswer: String?
    public var required: Bool?

    public init(id: String, header: String, question: String, options: [Option], multiSelect: Bool = false,
                allowCustomAnswer: Bool? = nil, initialAnswer: String? = nil, required: Bool? = nil) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.allowCustomAnswer = allowCustomAnswer
        self.initialAnswer = initialAnswer
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case id, header, question, options, multiSelect, allowCustomAnswer, initialAnswer, required }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        header = try c.decode(String.self, forKey: .header)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        allowCustomAnswer = try c.decodeIfPresent(Bool.self, forKey: .allowCustomAnswer)
        initialAnswer = try c.decodeIfPresent(String.self, forKey: .initialAnswer)
        required = try c.decodeIfPresent(Bool.self, forKey: .required)
    }

    public var allowsCustomAnswer: Bool { allowCustomAnswer != false }
}

public struct PendingUserInput: Hashable, Sendable {
    public var requestId: String
    public var createdAt: T3Timestamp?
    public var questions: [UserInputQuestion]
    /// `live`, `message` or `not_resumable`.
    public var responseCapability: String
    /// Message-mode questions can be closed without an answer (`thread.user-input.dismiss`).
    public var dismissible: Bool

    public init(requestId: String, createdAt: T3Timestamp? = nil, questions: [UserInputQuestion],
                responseCapability: String = "live", dismissible: Bool = false) {
        self.requestId = requestId
        self.createdAt = createdAt
        self.questions = questions
        self.responseCapability = responseCapability
        self.dismissible = dismissible
    }

    public var canRespond: Bool { responseCapability != "not_resumable" }
}

/// What the composer shows: the oldest of each list (ChatView.tsx:3310, :3474).
public struct PendingRequests: Hashable, Sendable {
    public var approvals: [PendingApproval] = []
    public var userInputs: [PendingUserInput] = []

    public init(approvals: [PendingApproval] = [], userInputs: [PendingUserInput] = []) {
        self.approvals = approvals
        self.userInputs = userInputs
    }

    public var activeApproval: PendingApproval? { approvals.first }
    public var activeUserInput: PendingUserInput? { userInputs.first }
    public var isEmpty: Bool { approvals.isEmpty && userInputs.isEmpty }

    /// `derivePendingThreadRequests` plus the oldest-first sort (session-logic.ts:249-259).
    public static func derive(_ projection: ThreadProjection) -> PendingRequests {
        derive(requests: projection.runtimeRequests, turnItems: projection.turnItems)
    }

    public static func derive(requests: [RuntimeRequest], turnItems: [TurnItem]) -> PendingRequests {
        var result = PendingRequests()
        guard requests.contains(where: { $0.status == "pending" }) else { return result }
        // The last request item per id carries the display data.
        var lastItem: [String: TurnItem] = [:]
        for item in turnItems where item.type == .approvalRequest || item.type == .userInputRequest {
            if let id = item.requestId { lastItem["\(item.type.rawValue)|\(id)"] = item }
        }
        for request in requests where request.status == "pending" {
            let capability = request.responseCapability?.type ?? "live"
            if request.kind == .userInput {
                guard let item = lastItem["user_input_request|\(request.id)"] else { continue }
                let questions = (try? item["questions"]?.decode(as: [UserInputQuestion].self)) ?? []
                let messageMode = item.string("responseMode") == "message" || capability == "message"
                result.userInputs.append(PendingUserInput(
                    requestId: request.id, createdAt: request.createdAt, questions: questions,
                    responseCapability: capability, dismissible: messageMode))
                continue
            }
            if request.kind == .authRefresh || request.kind == .dynamicToolCall { continue }
            let item = lastItem["approval_request|\(request.id)"]
            result.approvals.append(PendingApproval(
                requestId: request.id, requestKind: request.kind, createdAt: request.createdAt,
                detail: item?.string("prompt").flatMap { $0.isEmpty ? nil : $0 },
                appName: item?.string("appName").flatMap { $0.isEmpty ? nil : $0 },
                options: item?["options"].flatMap { try? $0.decode(as: [ApprovalOption].self) },
                canRespond: capability == "live"))
        }
        result.approvals = oldestFirst(result.approvals, \.createdAt)
        result.userInputs = oldestFirst(result.userInputs, \.createdAt)
        return result
    }

    private static func oldestFirst<T>(_ list: [T], _ key: KeyPath<T, T3Timestamp?>) -> [T] {
        list.enumerated().sorted { a, b in
            let l = a.element[keyPath: key], r = b.element[keyPath: key]
            let lk = l?.epochMs ?? 0, rk = r?.epochMs ?? 0
            if lk != rk { return lk < rk }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: Question answers (apps/web/src/pendingUserInput.ts)

/// One question's local draft.
public struct UserInputDraft: Hashable, Sendable {
    public var selectedOptionValues: [String]?
    public var customAnswer: String?
    /// Question attachments are out of M5 scope; kept for the resolution rules.
    public var attachmentCount = 0
    public var attachmentsBlocked = false

    public init(selectedOptionValues: [String]? = nil, customAnswer: String? = nil) {
        self.selectedOptionValues = selectedOptionValues
        self.customAnswer = customAnswer
    }
}

/// An answer on the wire: one string, or an array for multi-select.
public enum UserInputAnswer: Hashable, Sendable {
    case text(String)
    case values([String])

    public var json: JSONValue {
        switch self {
        case .text(let s): .string(s)
        case .values(let v): .array(v.map { .string($0) })
        }
    }
}

public struct UserInputProgress: Hashable, Sendable {
    public var questionIndex: Int
    public var activeQuestion: UserInputQuestion?
    public var selectedOptionValues: [String]
    public var customAnswer: String
    public var resolvedAnswer: UserInputAnswer?
    public var usingCustomAnswer: Bool
    public var answeredQuestionCount: Int
    public var isLastQuestion: Bool
    public var isComplete: Bool
    public var canAdvance: Bool
}

public enum UserInputAnswers {
    /// Unique, order kept; provider ids stay byte-exact.
    static func normalized(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        return (values ?? []).filter { seen.insert($0).inserted }
    }

    /// `resolvePendingUserInputAnswer` (:42-72): custom text beats options; nil means unanswered.
    public static func resolve(_ question: UserInputQuestion, _ draft: UserInputDraft?) -> UserInputAnswer? {
        if draft?.attachmentsBlocked == true { return nil }
        let custom: String?
        if !question.allowsCustomAnswer {
            custom = nil
        } else if question.initialAnswer != nil {
            custom = draft?.customAnswer
        } else {
            let trimmed = draft?.customAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            custom = trimmed.isEmpty ? nil : trimmed
        }
        if let custom, !custom.isEmpty { return .text(custom) }
        let known = Set(question.options.map(\.identity))
        let selected = normalized(draft?.selectedOptionValues).filter { known.contains($0) }
        let attachmentOnly: UserInputAnswer? = question.allowsCustomAnswer && (draft?.attachmentCount ?? 0) > 0 ? .text("") : nil
        if question.multiSelect {
            if !selected.isEmpty { return .values(selected) }
            return custom.map { .text($0) } ?? attachmentOnly
        }
        if let first = selected.first { return .text(first) }
        return custom.map { .text($0) } ?? attachmentOnly
    }

    /// `setPendingUserInputCustomAnswer` (:74-88): non-blank text clears the selected options;
    /// blank text keeps them, unless the question has an initial answer.
    public static func setCustomAnswer(_ draft: UserInputDraft?, _ text: String, question: UserInputQuestion?) -> UserInputDraft {
        let keep = question?.initialAnswer != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : normalized(draft?.selectedOptionValues)
        return UserInputDraft(selectedOptionValues: keep.isEmpty ? nil : keep, customAnswer: text)
    }

    /// `togglePendingUserInputOptionSelection` (:112-135).
    public static func toggle(_ question: UserInputQuestion, _ draft: UserInputDraft?, _ value: String) -> UserInputDraft {
        guard question.multiSelect else { return UserInputDraft(selectedOptionValues: [value], customAnswer: "") }
        var selected = normalized(draft?.selectedOptionValues)
        if let i = selected.firstIndex(of: value) { selected.remove(at: i) } else { selected.append(value) }
        return UserInputDraft(selectedOptionValues: selected.isEmpty ? nil : selected, customAnswer: "")
    }

    /// `buildPendingUserInputAnswers` (:137-152): nil unless every question resolves.
    public static func build(_ questions: [UserInputQuestion], _ drafts: [String: UserInputDraft]) -> [String: UserInputAnswer]? {
        var answers: [String: UserInputAnswer] = [:]
        for question in questions {
            guard let answer = resolve(question, drafts[question.id]) else { return nil }
            answers[question.id] = answer
        }
        return answers
    }

    /// `carryDisplacedCustomAnswerIntoPrompt` (:98-110).
    public static func carryDisplaced(_ prompt: String, _ customAnswer: String?) -> String {
        let displaced = customAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if displaced.isEmpty { return prompt }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return displaced }
        var head = prompt
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head + "\n\n" + displaced
    }

    /// `seedUserInputDraftAnswers` (threadRequests.ts:45-63): initial answers, once per question.
    public static func seed(_ questions: [UserInputQuestion], _ drafts: [String: UserInputDraft]) -> [String: UserInputDraft] {
        var seeded = drafts
        for q in questions where q.initialAnswer != nil && q.allowsCustomAnswer && seeded[q.id] == nil {
            seeded[q.id] = UserInputDraft(customAnswer: q.initialAnswer)
        }
        return seeded
    }

    /// `derivePendingUserInputProgress` (:176-208).
    public static func progress(_ questions: [UserInputQuestion], _ drafts: [String: UserInputDraft], index: Int) -> UserInputProgress {
        let i = questions.isEmpty ? 0 : max(0, min(index, questions.count - 1))
        let active = questions.isEmpty ? nil : questions[i]
        let draft = active.flatMap { drafts[$0.id] }
        let resolved = active.flatMap { resolve($0, draft) }
        let custom = active?.allowsCustomAnswer == false ? "" : (draft?.customAnswer ?? "")
        let effective = active?.initialAnswer != nil ? custom : custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserInputProgress(
            questionIndex: i, activeQuestion: active, selectedOptionValues: normalized(draft?.selectedOptionValues),
            customAnswer: custom, resolvedAnswer: resolved, usingCustomAnswer: !effective.isEmpty,
            answeredQuestionCount: questions.filter { resolve($0, drafts[$0.id]) != nil }.count,
            isLastQuestion: questions.isEmpty || i >= questions.count - 1,
            isComplete: build(questions, drafts) != nil, canAdvance: resolved != nil)
    }
}

/// One open question card: drafts per question and the active index (ChatView.tsx:10240-10372).
/// The composer feeds the editor text in with `setCustomAnswer`; `select`, `advance` and
/// `previous` follow T3's handlers.
public struct UserInputSession: Hashable, Sendable {
    public let request: PendingUserInput
    public private(set) var drafts: [String: UserInputDraft]
    public private(set) var questionIndex = 0

    public init(_ request: PendingUserInput) {
        self.request = request
        drafts = UserInputAnswers.seed(request.questions, [:])
    }

    public var progress: UserInputProgress { UserInputAnswers.progress(request.questions, drafts, index: questionIndex) }
    public var answers: [String: UserInputAnswer]? { UserInputAnswers.build(request.questions, drafts) }

    /// Picks or toggles an option on the active question. Returns typed custom text the pick
    /// displaced, for `UserInputAnswers.carryDisplaced` into the thread draft.
    public mutating func select(_ optionValue: String) -> String? {
        guard let question = progress.activeQuestion else { return nil }
        let displaced = drafts[question.id]?.customAnswer
        drafts[question.id] = UserInputAnswers.toggle(question, drafts[question.id], optionValue)
        return displaced?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? displaced : nil
    }

    /// The composer editor's text for the active question. Choice-only questions ignore it.
    public mutating func setCustomAnswer(_ text: String) {
        guard let question = progress.activeQuestion, question.allowsCustomAnswer else { return }
        drafts[question.id] = UserInputAnswers.setCustomAnswer(drafts[question.id], text, question: question)
    }

    public enum Advance: Equatable, Sendable {
        /// Moved to the next question.
        case moved
        /// The last question with every answer resolved: send these.
        case submit([String: UserInputAnswer])
        /// Nothing to do (not answerable, or the last question is incomplete).
        case blocked
    }

    /// `onAdvanceActivePendingUserInput` (ChatView.tsx:10343-10365). T3 moves past an
    /// unanswered middle question too; the Next button is what stays disabled.
    public mutating func advance() -> Advance {
        guard request.canRespond else { return .blocked }
        let p = progress
        if p.isLastQuestion { return answers.map { .submit($0) } ?? .blocked }
        questionIndex = p.questionIndex + 1
        return .moved
    }

    public mutating func previous() { questionIndex = max(progress.questionIndex - 1, 0) }

    /// The footer pill (ComposerPrimaryActions.tsx:60-73).
    public func primaryLabel(compact: Bool, responding: Bool) -> String {
        if responding { return "Submitting..." }
        let p = progress
        if !p.isLastQuestion { return compact ? "Next" : "Next question" }
        if compact { return "Submit" }
        return p.questionIndex > 0 ? "Submit answers" : "Submit answer"
    }

    /// The pill is enabled when the active question resolves (not last) or all do (last).
    public var canPressPrimary: Bool {
        let p = progress
        return request.canRespond && (p.isLastQuestion ? p.isComplete : p.canAdvance)
    }

    public var showsPrevious: Bool { progress.questionIndex > 0 }
}

// MARK: Commands

/// `orchestration.dispatchCommand` payloads for requests (commands.ts:834-870).
public enum RuntimeRequestCommands {
    public static func newCommandId() -> String { UUID().uuidString.lowercased() }

    /// An approval: `{type, commandId, threadId, requestId, decision}`.
    public static func respond(threadId: ThreadId, requestId: String, decision: ApprovalDecision,
                               commandId: String = newCommandId()) -> JSONValue {
        .object(["type": .string("runtime-request.respond"), "commandId": .string(commandId),
                 "threadId": .string(threadId.rawValue), "requestId": .string(requestId), "decision": .string(decision.rawValue)])
    }

    /// Question answers: `{type, commandId, threadId, requestId, answers}`. No `decision`, and
    /// `attachmentsByQuestionId` only with files (out of M5 scope).
    public static func respond(threadId: ThreadId, requestId: String, answers: [String: UserInputAnswer],
                               commandId: String = newCommandId()) -> JSONValue {
        .object(["type": .string("runtime-request.respond"), "commandId": .string(commandId),
                 "threadId": .string(threadId.rawValue), "requestId": .string(requestId),
                 "answers": .object(answers.mapValues(\.json))])
    }

    /// Closes a message-mode question without an answer.
    public static func dismiss(threadId: ThreadId, requestId: String, commandId: String = newCommandId()) -> JSONValue {
        .object(["type": .string("thread.user-input.dismiss"), "commandId": .string(commandId),
                 "threadId": .string(threadId.rawValue), "requestId": .string(requestId)])
    }
}
