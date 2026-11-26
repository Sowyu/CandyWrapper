import Foundation

// Durable workflows, beta (5258 packages/contracts/src/workflow.ts, rpc.ts:643-652, 2335-2392; T3 commits
// e414cfd4be, 69c1d53826, adb6064469 and the others in docs/research/nightly-diff-5258-wire.md A2). Off unless
// `ServerSettings.workflowsEnabled`; a 4928 server has none of these methods.

/// `WorkflowRun` (:25-52). `status`: `running`, `waiting`, `paused`, `completed`, `stopped`, `skipped` (lists
/// leave these out unless asked) or `cancelled`. Times are ISO strings.
public struct WorkflowRun: Codable, Hashable, Sendable {
    public var runId: String
    public var workflow: String
    public var version: Double
    public var title: String
    public var status: String
    /// Why it is paused, what it waits on, or how it ended.
    public var detail: String?
    public var result: JSONValue?
    /// Times in a row a failing step paused it.
    public var pauses: Double
    /// Its version is no longer registered, so it cannot go on until that version is back.
    public var retired: Bool
    /// When a paused run resumes on its own; nil when it waits for a person.
    public var resumesAt: String?
    /// The run that invoked this one and waits for it, and the step it was invoked as.
    public var parentRunId: String?
    public var parentStep: String?
    public var tags: [String]?
    public var subject: WorkflowRunSubject?
    public var startedAt: String
    public var updatedAt: String
    public var endedAt: String?
}

/// `WorkflowRunSubject` (:15-23): what a run is about. `address` is an `IssueRef`, a `PullRequestRef`, `{threadId}`
/// or `{url}`, by `kind` (`WorkflowReferenceKind`, :272-282). `title` is empty until something knew it.
public struct WorkflowRunSubject: Codable, Hashable, Sendable {
    public var kind: String
    public var key: String
    public var address: JSONValue
    public var title: String
    public var url: String?
}

/// `WorkflowStep` (:54-77). `kind`: `step`, `wait`, `agent`, `ask`, `sleep` (whose `detail` is the wake time) or
/// `queue`. `status`: `running`, `completed` or `failed`.
public struct WorkflowStep: Codable, Hashable, Sendable {
    public var name: String
    public var kind: String
    public var status: String
    public var attempts: Double
    public var detail: String?
    /// The thread an agent step ran in, and its linked environment (nil for this one).
    public var threadId: String?
    public var environmentId: String?
    public var result: JSONValue?
    /// What an agent said in closing, when its result is data and not that reply.
    public var said: String?
    /// For a waiting `queue` step: how many asked for a place in its pool before it.
    public var ahead: Double?
    public var startedAt: String
    public var endedAt: String?
}

/// `WorkflowQuestion` (:80-94): answer it with `WorkflowsRPC.answerInput` and the run and name.
public struct WorkflowQuestion: Codable, Hashable, Sendable {
    public struct Thread: Codable, Hashable, Sendable {
        public var threadId: String
        public var environmentId: String?
    }
    public var runId: String
    public var name: String
    /// What `ask` was given: a title, the choices and data to lay out.
    public var request: JSONValue
    public var kind: String?
    public var askedAt: String
    /// The run's latest agent thread, for talking it through before answering.
    public var thread: Thread?

    /// `workflowQuestionKey` (:213-215): one run asks one question of a name at a time.
    public var key: String { "\(runId)\u{0}\(name)" }
}

/// `WorkflowSummary` (:105-114): a registered workflow at its newest version. `triggers` read like "every 1h".
public struct WorkflowSummary: Codable, Hashable, Sendable {
    public struct Ask: Codable, Hashable, Sendable { public var kind: String; public var label: String }
    public var name: String
    public var version: Double
    public var triggers: [String]
    public var asks: [Ask]?
}

/// `WorkflowDefinitionProblem` (:117-122).
public struct WorkflowDefinitionProblem: Codable, Hashable, Sendable {
    public var message: String
    public var file: String?
    public var line: Double?
}

/// `WorkflowDefinitionState` (:125-131): `revision` goes up whenever the file loads or is found wrong.
public struct WorkflowDefinitionState: Codable, Hashable, Sendable {
    public var revision: Double
    public var problem: String?
}

/// `WorkflowDefinitionFile` (:133-141).
public struct WorkflowDefinitionFile: Codable, Hashable, Sendable {
    public var name: String
    /// The file on disk, which is not what runs while it has problems.
    public var source: String
    /// The workflows its last good version defines, each as `name@version`.
    public var workflows: [String]
    public var problems: [WorkflowDefinitionProblem]
}

/// `WorkflowDefinitionFiles` (:144-156), the answer of `workflows.getDefinition`.
public struct WorkflowDefinitionFiles: Codable, Hashable, Sendable {
    public var directory: String
    /// The server was pointed at one file: none can be added beside it or taken away.
    public var single: Bool
    public var files: [WorkflowDefinitionFile]
    public var problems: [WorkflowDefinitionProblem]
    public var revision: Double
    public var problem: String?
}

/// `WorkflowDefinitionChangeResult` (:169-175), the answer of save and delete. With `changed`, non-empty
/// `problems` say why the change does not run yet.
public struct WorkflowDefinitionChangeResult: Codable, Hashable, Sendable {
    public var changed: Bool
    public var problems: [WorkflowDefinitionProblem]
}

/// `WorkflowRunsSnapshot` (:177-182): newest runs first, and the questions still open.
public struct WorkflowRunsSnapshot: Codable, Hashable, Sendable {
    public var workflows: [WorkflowSummary]
    public var runs: [WorkflowRun]
    public var questions: [WorkflowQuestion]
    public var definition: WorkflowDefinitionState?

    public init(workflows: [WorkflowSummary] = [], runs: [WorkflowRun] = [], questions: [WorkflowQuestion] = [],
                definition: WorkflowDefinitionState? = nil) {
        self.workflows = workflows; self.runs = runs; self.questions = questions; self.definition = definition
    }
}

/// `WorkflowCounts` (:185-193), the badge stream of `workflows.counts`.
public struct WorkflowCounts: Codable, Hashable, Sendable {
    /// Open questions and paused runs.
    public var needsYou: Double
    /// Runs that have not ended.
    public var active: Double
    /// Runs there have ever been, so a client knows whether workflows are in use at all.
    public var total: Double
}

/// `WorkflowRunsChange` (:197-207), tagged `changed`.
public struct WorkflowRunsChange: Codable, Hashable, Sendable {
    public struct Closed: Codable, Hashable, Sendable { public var runId: String; public var name: String }
    public var runs: [WorkflowRun]
    public var removed: [String]
    public var questions: [WorkflowQuestion]
    public var closed: [Closed]
}

/// A `workflows.subscribe` frame (`WorkflowRunsUpdate`, :213): a whole list, or with `changes: true` what changed
/// since the last frame. A server older than `changes` sends whole lists.
public enum WorkflowRunsUpdate: Decodable, Hashable, Sendable {
    case snapshot(WorkflowRunsSnapshot)
    case changed(WorkflowRunsChange)

    private enum Key: String, CodingKey { case _tag }
    public init(from decoder: Decoder) throws {
        let tag = try decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: ._tag)
        self = tag == "changed" ? .changed(try WorkflowRunsChange(from: decoder)) : .snapshot(try WorkflowRunsSnapshot(from: decoder))
    }

    /// `applyWorkflowRunsUpdate` (:215-235): changed entries replace their earlier versions, removed and closed ones
    /// leave, new ones go first; then runs sort newest first by `startedAt` and questions oldest first by `askedAt`,
    /// both stable.
    public func applied(to snapshot: WorkflowRunsSnapshot?) -> WorkflowRunsSnapshot {
        guard case .changed(let change) = self else { if case .snapshot(let s) = self { return s }; return snapshot ?? .init() }
        var base = snapshot ?? WorkflowRunsSnapshot()
        base.runs = Self.merged(base.runs, change.runs, Set(change.removed), \.runId)
        base.runs = base.runs.enumerated().sorted { a, b in
            a.element.startedAt == b.element.startedAt ? a.offset < b.offset : a.element.startedAt > b.element.startedAt
        }.map(\.element)
        base.questions = Self.merged(base.questions, change.questions, Set(change.closed.map { "\($0.runId)\u{0}\($0.name)" }), \.key)
        base.questions = base.questions.enumerated().sorted { a, b in
            a.element.askedAt == b.element.askedAt ? a.offset < b.offset : a.element.askedAt < b.element.askedAt
        }.map(\.element)
        return base
    }

    /// `merged` (:217-233).
    static func merged<A>(_ held: [A], _ changed: [A], _ gone: Set<String>, _ key: (A) -> String) -> [A] {
        var fresh: [String: A] = [:]
        var order: [String] = []
        for entry in changed { let k = key(entry); if fresh[k] == nil { order.append(k) }; fresh[k] = entry }
        var kept: [A] = []
        for entry in held {
            let id = key(entry)
            if gone.contains(id) { continue }
            kept.append(fresh.removeValue(forKey: id) ?? entry)
        }
        return order.compactMap { fresh[$0] } + kept
    }
}

/// `WorkflowRunReference` (:255-268): something a run touched. `kind` is open; show an unknown one by title and url.
public struct WorkflowRunReference: Codable, Hashable, Sendable {
    public var kind: String
    public var key: String
    public var address: JSONValue
    public var title: String
    public var url: String?
    /// A word for where it stands, such as `open`, `merged` or `closed`.
    public var state: String?
    /// The steps that touched it, in the order they first did.
    public var steps: [String]
    /// `trigger` or `step`.
    public var origin: String
}

/// `WorkflowRunDetail` (:286-291), the answer of `workflows.get`: steps in the order they started.
public struct WorkflowRunDetail: Codable, Hashable, Sendable {
    public var run: WorkflowRun
    public var steps: [WorkflowStep]
    public var references: [WorkflowRunReference]
}

/// `WorkflowRunsAbout` (:250-254): runs about one subject, newest first and 500 at most, with their open questions.
public struct WorkflowRunsAbout: Codable, Hashable, Sendable {
    public var runs: [WorkflowRun]
    public var questions: [WorkflowQuestion]
}

/// RPC tags and payloads. Answer, resume and cancel need `orchestration:operate`, saving or deleting a definition
/// `terminal:operate` (clientRpcPermissions.ts:90-95). Watch the badge with `counts`, the list with `subscribe`.
public enum WorkflowsRPC {
    public static let subscribe = "workflows.subscribe"
    public static let counts = "workflows.counts"
    public static let get = "workflows.get"
    public static let about = "workflows.about"
    public static let answer = "workflows.answer"
    public static let resume = "workflows.resume"
    public static let cancel = "workflows.cancel"
    public static let getDefinition = "workflows.getDefinition"
    public static let saveDefinition = "workflows.saveDefinition"
    public static let deleteDefinition = "workflows.deleteDefinition"

    /// `subscribe` and `counts`. T3 subscribes with `changes: true` and folds each frame with
    /// `WorkflowRunsUpdate.applied(to:)` (client-runtime state/server.ts:1477).
    public static func subscribeInput(changes: Bool = true) -> JSONValue { changes ? .object(["changes": .bool(true)]) : .object([:]) }
    public static func runInput(_ runId: String) -> JSONValue { .object(["runId": .string(runId)]) }
    /// `about`: runs whose subject is at the web address, or is the `IssueRef` or `PullRequestRef` given.
    public static func aboutInput(subject: String, issue: JSONValue? = nil, pullRequest: JSONValue? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["subject": .string(subject)]
        if let issue { o["issue"] = issue }
        if let pullRequest { o["pullRequest"] = pullRequest }
        return .object(o)
    }
    /// `answer` (:293-299): one of the question's choices and, when given, why.
    public static func answerInput(runId: String, name: String, choice: String, reason: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["runId": .string(runId), "name": .string(name), "choice": .string(choice)]
        if let reason { o["reason"] = .string(reason) }
        return .object(o)
    }
    public static func cancelInput(runId: String, reason: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["runId": .string(runId)]
        if let reason { o["reason"] = .string(reason) }
        return .object(o)
    }
    /// `saveDefinition`: a name not there yet makes the file.
    public static func saveDefinitionInput(name: String, source: String) -> JSONValue {
        .object(["name": .string(name), "source": .string(source)])
    }
    public static func deleteDefinitionInput(name: String) -> JSONValue { .object(["name": .string(name)]) }
}
