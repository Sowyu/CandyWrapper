import Foundation

// Scheduled tasks: the contract (packages/contracts/src/scheduledTask.ts), the editor's draft rules
// (apps/web/src/components/settings/scheduledTasksSettings.logic.ts), the labels the list and the thread
// automations panel share (ScheduledTasksSettings.tsx:170-230) and the webhook helpers
// (packages/client-runtime/src/scheduledTaskWebhook.ts, webhookAddress.ts).

/// `ScheduledTaskSchedule` (scheduledTask.ts:132-140).
public enum ScheduledTaskSchedule: Equatable, Sendable {
    case interval(everyMs: Double)
    /// `timeOfDay` is local `HH:MM`; `weekdays` 0 (Sunday) to 6, nil for every day.
    case fixedTime(timeOfDay: String, weekdays: [Int]?)
    case webhook(signature: ScheduledTaskWebhookSignature?, maxDeliveryAgeMinutes: Int?,
                 dedupe: ScheduledTaskWebhookDedupe = .init(), filters: [ScheduledTaskWebhookFilter] = [])

    init?(json: JSONValue?) {
        switch json?["type"]?.stringValue {
        case "interval":
            guard let ms = json?["everyMs"]?.doubleValue else { return nil }
            self = .interval(everyMs: ms)
        case "fixed_time":
            guard let time = json?["timeOfDay"]?.stringValue else { return nil }
            self = .fixedTime(timeOfDay: time, weekdays: json?["weekdays"]?.arrayValue?.compactMap(\.intValue))
        case "webhook":
            let sig = json?["signature"]
            let signature = sig?["header"]?.stringValue.map {
                ScheduledTaskWebhookSignature(header: $0, encoding: sig?["encoding"]?.stringValue ?? "hex", prefix: sig?["prefix"]?.stringValue ?? "")
            }
            let dedupe = json?["dedupe"]
            self = .webhook(signature: signature, maxDeliveryAgeMinutes: json?["maxDeliveryAgeMinutes"]?.intValue,
                            dedupe: ScheduledTaskWebhookDedupe(replayKey: dedupe?["replayKey"]?.stringValue, coalesceKey: dedupe?["coalesceKey"]?.stringValue,
                                                               coalesceWindowSeconds: dedupe?["coalesceWindowSeconds"]?.intValue),
                            filters: json?["filters"]?.arrayValue?.compactMap(ScheduledTaskWebhookFilter.init(json:)) ?? [])
        default: return nil
        }
    }

    public var isWebhook: Bool { if case .webhook = self { true } else { false } }
}

public struct ScheduledTaskWebhookSignature: Equatable, Sendable {
    public var header: String
    /// `hex` or `base64`.
    public var encoding: String
    public var prefix: String
    public init(header: String, encoding: String, prefix: String) { self.header = header; self.encoding = encoding; self.prefix = prefix }
}

/// `ScheduledTaskWebhookDedupe` (3473 scheduledTask.ts:95-106): replay and coalesce key templates and
/// the coalesce window in seconds (the server's default is 120).
public struct ScheduledTaskWebhookDedupe: Equatable, Sendable {
    public var replayKey: String?
    public var coalesceKey: String?
    public var coalesceWindowSeconds: Int?
    public init(replayKey: String? = nil, coalesceKey: String? = nil, coalesceWindowSeconds: Int? = nil) {
        self.replayKey = replayKey; self.coalesceKey = coalesceKey; self.coalesceWindowSeconds = coalesceWindowSeconds
    }
}

/// `ScheduledTaskWebhookFilter` (3473 scheduledTask.ts:108-139): a request value under `body`, `headers`
/// or `query`, and a test. `in` holds a list, `exists` no value, the others one string.
public struct ScheduledTaskWebhookFilter: Equatable, Sendable {
    public var path: String
    /// `equals`, `notEquals`, `in`, `startsWith` or `exists`.
    public var op: String
    public var value: String?
    public var values: [String]?
    public init(path: String, op: String, value: String? = nil, values: [String]? = nil) {
        self.path = path; self.op = op; self.value = value; self.values = values
    }

    init?(json: JSONValue) {
        guard let path = json["path"]?.stringValue, let op = json["op"]?.stringValue else { return nil }
        self.init(path: path, op: op, value: json["value"]?.stringValue, values: json["value"]?.arrayValue?.compactMap(\.stringValue))
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["path": .string(path), "op": .string(op)]
        if op == "in" { o["value"] = .array((values ?? []).map(JSONValue.string)) } else if op != "exists" { o["value"] = .string(value ?? "") }
        return .object(o)
    }
}

/// `ScheduledTaskWebhookEndpoint`.
public struct ScheduledTaskWebhookEndpoint: Equatable, Sendable {
    public var path: String
    public var url: String?
    public var hasSecret: Bool
    public init(path: String, url: String?, hasSecret: Bool) { self.path = path; self.url = url; self.hasSecret = hasSecret }
}

/// `ScheduledTask` (scheduledTask.ts:182-205), with the workspace strategy and model kept as sent.
public struct ScheduledTask: Equatable, Sendable {
    public var id: String
    public var title: String
    public var prompt: String
    public var enabled: Bool
    public var schedule: ScheduledTaskSchedule
    public var projectId: String
    public var threadId: String?
    public var workspaceStrategy: JSONValue
    public var modelSelection: JSONValue
    public var runtimeMode: String
    public var interactionMode: String
    public var nextRunAt: String?
    public var lastRunAt: String?
    /// `never`, `running`, `succeeded` or `failed`.
    public var lastRunStatus: String
    public var lastRunError: String?
    public var runCount: Int
    public var webhook: ScheduledTaskWebhookEndpoint?

    public init(id: String, title: String, prompt: String, enabled: Bool = true, schedule: ScheduledTaskSchedule, projectId: String,
                threadId: String? = nil, workspaceStrategy: JSONValue = .object(["type": .string("root")]),
                modelSelection: JSONValue = .object([:]), runtimeMode: String = "full-access", interactionMode: String = "default",
                nextRunAt: String? = nil, lastRunAt: String? = nil, lastRunStatus: String = "never", lastRunError: String? = nil,
                runCount: Int = 0, webhook: ScheduledTaskWebhookEndpoint? = nil) {
        self.id = id; self.title = title; self.prompt = prompt; self.enabled = enabled; self.schedule = schedule
        self.projectId = projectId; self.threadId = threadId; self.workspaceStrategy = workspaceStrategy; self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode; self.interactionMode = interactionMode; self.nextRunAt = nextRunAt; self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus; self.lastRunError = lastRunError; self.runCount = runCount; self.webhook = webhook
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let title = json["title"]?.stringValue, let prompt = json["prompt"]?.stringValue,
              let schedule = ScheduledTaskSchedule(json: json["schedule"]), let projectId = json["projectId"]?.stringValue else { return nil }
        self.init(id: id, title: title, prompt: prompt, enabled: json["enabled"]?.boolValue ?? false, schedule: schedule, projectId: projectId,
                  threadId: json["threadId"]?.stringValue, workspaceStrategy: json["workspaceStrategy"] ?? .object(["type": .string("root")]),
                  modelSelection: json["modelSelection"] ?? .object([:]), runtimeMode: json["runtimeMode"]?.stringValue ?? "full-access",
                  interactionMode: json["interactionMode"]?.stringValue ?? "default", nextRunAt: json["nextRunAt"]?.stringValue,
                  lastRunAt: json["lastRunAt"]?.stringValue, lastRunStatus: json["lastRunStatus"]?.stringValue ?? "never",
                  lastRunError: json["lastRunError"]?.stringValue, runCount: json["runCount"]?.intValue ?? 0,
                  webhook: json["webhook"]?["path"]?.stringValue.map {
                      ScheduledTaskWebhookEndpoint(path: $0, url: json["webhook"]?["url"]?.stringValue, hasSecret: json["webhook"]?["hasSecret"]?.boolValue == true)
                  })
    }

    /// `ScheduledTaskListResult.tasks`: entries this build cannot decode are skipped (`ForwardCompatibleArray`).
    public static func list(_ json: JSONValue?) -> [ScheduledTask] { (json?["tasks"]?.arrayValue ?? []).compactMap(ScheduledTask.init(json:)) }
}

/// `ScheduledTaskWebhookDeliverySummary` and `ScheduledTaskWebhookDelivery` (scheduledTask.ts:329-365).
/// `outcome` is any string, so an outcome added later still lists.
public struct ScheduledTaskWebhookDelivery: Equatable, Sendable {
    public var id: String
    public var receivedAt: String
    public var method: String
    public var outcome: String
    /// An accepted delivery that opened a coalesce window and hasn't run yet.
    public var pendingWindow: Bool
    public var signatureVerified: Bool
    public var missingFields: [String]
    public var error: String?
    // Detail only.
    public var query: String = ""
    public var headers: [(String, String)] = []
    public var body: String = ""
    public var bodyTruncated = false
    public var renderedPrompt: String?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let receivedAt = json["receivedAt"]?.stringValue else { return nil }
        self.id = id
        self.receivedAt = receivedAt
        method = json["method"]?.stringValue ?? ""
        outcome = json["outcome"]?.stringValue ?? "accepted"
        pendingWindow = json["pendingWindow"]?.boolValue == true
        signatureVerified = json["signatureVerified"]?.boolValue == true
        missingFields = json["missingFields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        error = json["error"]?.stringValue
        query = json["query"]?.stringValue ?? ""
        // Object key order as sent: JSON objects decode unordered, so sort for a stable listing.
        headers = (json["headers"]?.objectValue ?? [:]).compactMap { k, v in v.stringValue.map { (k, $0) } }.sorted { $0.0 < $1.0 }
        body = json["body"]?.stringValue ?? ""
        bodyTruncated = json["bodyTruncated"]?.boolValue == true
        renderedPrompt = json["renderedPrompt"]?.stringValue
    }

    public static func == (l: Self, r: Self) -> Bool {
        l.id == r.id && l.outcome == r.outcome && l.pendingWindow == r.pendingWindow && l.body == r.body && l.receivedAt == r.receivedAt
    }
}

/// The task editor's form (`DraftState`, scheduledTasksSettings.logic.ts:51-90).
public struct ScheduledTaskDraft: Equatable, Sendable {
    public enum ScheduleMode: String, Sendable { case fixed, interval, webhook }
    public enum WorkspaceMode: String, Sendable { case root, worktree, existingWorktree = "existing_worktree" }

    public var editingId: String?
    public var title = ""
    public var prompt = ""
    public var enabled = true
    public var scheduleMode = ScheduleMode.fixed
    public var intervalMinutes = "15"
    public var timeOfDay = "09:00"
    public var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    public var projectId = ""
    public var threadId = ""
    public var workspaceMode = WorkspaceMode.worktree
    public var baseRef = "main"
    public var startFromOrigin = true
    public var existingWorktreePath = ""
    /// `instanceId:model`; empty uses the default model.
    public var modelKey = ""
    public var runtimeMode = "full-access"
    public var interactionMode = "default"
    /// The task's own selection, kept so provider options survive when the model is unchanged.
    public var baseModelSelection: JSONValue?
    public var signatureEnabled = false
    public var signatureHeader = ScheduledTaskLogic.signatureDefaults.header
    public var signatureEncoding = ScheduledTaskLogic.signatureDefaults.encoding
    public var signaturePrefix = ScheduledTaskLogic.signatureDefaults.prefix
    /// Write-only: empty keeps the stored secret.
    public var signatureSecret = ""
    public var maxDeliveryAgeMinutes = ""
    public var replayKey = ""
    public var coalesceKey = ""
    public var coalesceWindowSeconds = ""
    public var filters: [WebhookFilterDraft] = []
    /// The filter rows the form opened with.
    public var savedFilters: [WebhookFilterDraft] = []

    /// `WebhookFilterDraft` (3473 scheduledTaskWebhook.ts:24-32): one editable filter row. `in` takes a
    /// comma-separated list; `exists` ignores the value. `id` is the row's identity in the form only.
    public struct WebhookFilterDraft: Equatable, Sendable {
        public var id: String
        public var path = ""
        public var op = "equals"
        public var value = ""
        public init(id: String, path: String = "", op: String = "equals", value: String = "") {
            self.id = id; self.path = path; self.op = op; self.value = value
        }
    }

    /// `EMPTY_DRAFT`.
    public init() {}
}

public enum ScheduledTaskLogic {
    /// `MIN_SCHEDULED_TASK_INTERVAL_MS`.
    public static let minIntervalMs: Double = 60_000
    /// `MAX_WEBHOOK_DELIVERY_AGE_MINUTES`.
    public static let maxDeliveryAgeMinutes = 24 * 60
    /// `DEFAULT_WEBHOOK_PROMPT`.
    public static let defaultWebhookPrompt = "Handle this webhook:\n{{body}}"
    /// `WEBHOOK_SIGNATURE_DEFAULTS`: GitHub's settings.
    public static let signatureDefaults = (header: "x-hub-signature-256", encoding: "hex", prefix: "sha256=")

    /// JS day of week (0 is Sunday) shown Monday first.
    public static let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]
    public static let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    public static let weekdayShort = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    public static func workspaceLabel(_ mode: ScheduledTaskDraft.WorkspaceMode) -> String {
        switch mode {
        case .worktree: "Create a new worktree"
        case .root: "Use the project checkout"
        case .existingWorktree: "Use a specific checkout"
        }
    }

    /// `MAX_WEBHOOK_FILTERS`.
    public static let maxWebhookFilters = 16
    /// `WEBHOOK_FILTER_OPS`: the test and the words the form shows for it.
    public static let webhookFilterOps: [(op: String, label: String)] = [
        ("equals", "equals"), ("notEquals", "does not equal"), ("in", "is one of"), ("startsWith", "starts with"), ("exists", "exists"),
    ]

    nonisolated(unsafe) private static var lastFilterDraftId = 0
    /// `emptyWebhookFilterDraft`.
    public static func emptyFilterDraft() -> ScheduledTaskDraft.WebhookFilterDraft {
        lastFilterDraftId += 1
        return .init(id: "filter-\(lastFilterDraftId)")
    }

    /// `webhookFilterDrafts`: stored filters as form rows, an `in` list joined with ", ".
    static func filterDrafts(_ filters: [ScheduledTaskWebhookFilter]) -> [ScheduledTaskDraft.WebhookFilterDraft] {
        filters.map { f in
            lastFilterDraftId += 1
            return .init(id: "filter-\(lastFilterDraftId)", path: f.path, op: f.op,
                         value: f.op == "exists" ? "" : f.op == "in" ? (f.values ?? []).joined(separator: ", ") : f.value ?? "")
        }
    }

    /// `parseWebhookFilterDrafts`: the rows as the server's filters, checked by its schema
    /// (scheduledTask.ts:108-139), or the message naming the first row that would not save.
    public static func parseFilterDrafts(_ drafts: [ScheduledTaskDraft.WebhookFilterDraft]) -> Result<[ScheduledTaskWebhookFilter], FilterError> {
        if drafts.count > maxWebhookFilters { return .failure(FilterError(message: "Use at most \(maxWebhookFilters) filters.")) }
        var filters: [ScheduledTaskWebhookFilter] = []
        for (i, d) in drafts.enumerated() {
            let path = d.path.trimmingCharacters(in: .whitespacesAndNewlines)
            // `TrimmedNonEmptyString` matching `^(body|headers|query)(\.|$)`.
            let pathOK = path.range(of: #"^(body|headers|query)(\.|$)"#, options: .regularExpression) != nil
            var filter: ScheduledTaskWebhookFilter?
            switch d.op {
            case "exists": filter = pathOK ? .init(path: path, op: "exists") : nil
            case "in":
                let values = d.value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                filter = pathOK && !values.isEmpty ? .init(path: path, op: "in", values: values) : nil
            case "equals", "notEquals", "startsWith": filter = pathOK ? .init(path: path, op: d.op, value: d.value) : nil
            default: filter = nil
            }
            guard let filter else {
                let tail = d.op == "exists" ? "." : d.op == "in" ? ", and at least one value." : ", and a value."
                return .failure(FilterError(message: "Filter \(i + 1) needs a path under body, headers or query\(tail)"))
            }
            filters.append(filter)
        }
        return .success(filters)
    }

    public struct FilterError: Error, Equatable, Sendable { public var message: String }

    /// `webhookFilterDraftsChanged`: a save sends `filters` only when the rows differ from the ones
    /// the form opened with, so editing the title can't overwrite filters another device changed.
    public static func filterDraftsChanged(_ saved: [ScheduledTaskDraft.WebhookFilterDraft], _ current: [ScheduledTaskDraft.WebhookFilterDraft]) -> Bool {
        saved.count != current.count || zip(saved, current).contains { a, b in
            a.path != b.path || a.op != b.op || (a.op != "exists" && a.value != b.value)
        }
    }

    /// `isWebhookDedupeTemplate` (3473 scheduledTask.ts:86-91): at least one `{{body.…}}`, `{{headers.…}}`,
    /// `{{query.…}}` or `{{request}}`, and no stray braces around them.
    public static func isDedupeTemplate(_ template: String) -> Bool {
        let pattern = #"\{\{\s*(?:(?:body|headers|query)(?:\.[^{}.\s]+)*|request)\s*\}\}"#
        guard template.range(of: pattern, options: .regularExpression) != nil else { return false }
        let remainder = template.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return !remainder.contains("{{") && !remainder.contains("}}")
    }

    /// `webhookDraftErrors` (3473 scheduledTasksSettings.logic.ts:102-129): the age limit first, alone,
    /// then each bad key and the window.
    public static func webhookDraftErrors(_ d: ScheduledTaskDraft) -> [ValidationError] {
        guard d.scheduleMode == .webhook else { return [] }
        if parseMaxDeliveryAge(d.maxDeliveryAgeMinutes) == nil { return [.invalidAge] }
        var errors: [ValidationError] = []
        for (label, value) in [("Replay key", d.replayKey), ("Coalesce key", d.coalesceKey)] {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !isDedupeTemplate(t) { errors.append(.invalidWebhook("\(label) must contain a valid request placeholder.")) }
        }
        let window = d.coalesceWindowSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        if !window.isEmpty, coalesceWindow(window) == nil {
            errors.append(.invalidWebhook("Coalesce window must be whole seconds from 10 to 3600."))
        }
        return errors
    }

    /// JS `Number(window)` as whole seconds from 10 to 3600.
    static func coalesceWindow(_ t: String) -> Int? {
        guard let n = Double(t), n == n.rounded(), n >= 10, n <= 3600 else { return nil }
        return Int(n)
    }

    /// `parseMaxDeliveryAge`: blank is no limit (`.some(nil)`), nil is not a valid limit.
    public static func parseMaxDeliveryAge(_ value: String) -> Int?? {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        guard let n = Double(t), n == n.rounded(), n > 0, n <= Double(maxDeliveryAgeMinutes) else { return nil }
        return .some(Int(n))
    }

    /// JS `Math.round` of the minutes in ms, so `1.5` minutes is 90000.
    static func intervalMs(_ minutes: String) -> Double? {
        guard let m = Double(minutes.trimmingCharacters(in: .whitespaces)) else { return nil }
        return UsageFormat.jsRound(m * 60_000)
    }

    /// `scheduleFromDraft` as the upsert's `schedule` JSON. Nil when a webhook setting is invalid.
    public static func schedulePayload(_ d: ScheduledTaskDraft) -> JSONValue? {
        switch d.scheduleMode {
        case .webhook:
            guard webhookDraftErrors(d).isEmpty, let age = parseMaxDeliveryAge(d.maxDeliveryAgeMinutes),
                  case .success(let filters) = parseFilterDrafts(d.filters) else { return nil }
            let secret = d.signatureSecret.trimmingCharacters(in: .whitespaces)
            var signature: JSONValue = .null
            if d.signatureEnabled {
                var s: [String: JSONValue] = ["header": .string(d.signatureHeader.trimmingCharacters(in: .whitespaces)),
                                              "encoding": .string(d.signatureEncoding), "prefix": .string(d.signaturePrefix)]
                if !secret.isEmpty { s["secret"] = .string(secret) }
                signature = .object(s)
            }
            // Always a `dedupe`, empty when every field is, so clearing the fields clears the stored ones.
            var dedupe: [String: JSONValue] = [:]
            let replayKey = d.replayKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let coalesceKey = d.coalesceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !replayKey.isEmpty { dedupe["replayKey"] = .string(replayKey) }
            if !coalesceKey.isEmpty { dedupe["coalesceKey"] = .string(coalesceKey) }
            if let window = coalesceWindow(d.coalesceWindowSeconds.trimmingCharacters(in: .whitespacesAndNewlines)) {
                dedupe["coalesceWindowSeconds"] = .number(Double(window))
            }
            var o: [String: JSONValue] = ["type": .string("webhook"), "signature": signature,
                                          "maxDeliveryAgeMinutes": age.map { .number(Double($0)) } ?? .null, "dedupe": .object(dedupe)]
            if filterDraftsChanged(d.savedFilters, d.filters) { o["filters"] = .array(filters.map(\.json)) }
            return .object(o)
        case .interval:
            return .object(["type": .string("interval"), "everyMs": intervalMs(d.intervalMinutes).map(JSONValue.number) ?? .number(.nan)])
        case .fixed:
            var o: [String: JSONValue] = ["type": .string("fixed_time"), "timeOfDay": .string(d.timeOfDay.isEmpty ? "09:00" : d.timeOfDay)]
            if !(d.weekdays.isEmpty || d.weekdays.count == 7) { o["weekdays"] = .array(d.weekdays.sorted().map { .number(Double($0)) }) }
            return .object(o)
        }
    }

    /// `taskToDraft`.
    public static func draft(_ t: ScheduledTask) -> ScheduledTaskDraft {
        var d = ScheduledTaskDraft()
        d.editingId = t.id
        d.title = t.title
        d.prompt = t.prompt
        d.enabled = t.enabled
        switch t.schedule {
        case .interval(let ms):
            d.scheduleMode = .interval
            d.intervalMinutes = jsNumberString(max(1, ms / 60_000))
            d.weekdays = Set(0...6)
        case .fixedTime(let time, let days):
            d.scheduleMode = .fixed
            d.timeOfDay = time
            d.weekdays = days.map { $0.isEmpty ? Set(0...6) : Set($0) } ?? Set(0...6)
        case .webhook(let signature, let age, let dedupe, let filters):
            d.scheduleMode = .webhook
            d.replayKey = dedupe.replayKey ?? ""
            d.coalesceKey = dedupe.coalesceKey ?? ""
            d.coalesceWindowSeconds = dedupe.coalesceWindowSeconds.map(String.init) ?? ""
            d.filters = filterDrafts(filters)
            d.savedFilters = d.filters
            d.weekdays = Set(0...6)
            if let signature {
                d.signatureEnabled = true
                d.signatureHeader = signature.header
                d.signatureEncoding = signature.encoding
                d.signaturePrefix = signature.prefix
            }
            d.maxDeliveryAgeMinutes = age.map(String.init) ?? ""
        }
        d.projectId = t.projectId
        d.threadId = t.threadId ?? ""
        let strategy = t.workspaceStrategy
        d.workspaceMode = ScheduledTaskDraft.WorkspaceMode(rawValue: strategy["type"]?.stringValue ?? "root") ?? .root
        d.baseRef = d.workspaceMode == .worktree ? strategy["baseRef"]?.stringValue ?? "main" : "main"
        d.startFromOrigin = d.workspaceMode == .worktree ? strategy["startFromOrigin"]?.boolValue ?? false : true
        d.existingWorktreePath = d.workspaceMode == .existingWorktree ? strategy["worktreePath"]?.stringValue ?? "" : ""
        d.modelKey = "\(t.modelSelection["instanceId"]?.stringValue ?? ""):\(t.modelSelection["model"]?.stringValue ?? "")"
        d.runtimeMode = t.runtimeMode
        d.interactionMode = t.interactionMode
        d.baseModelSelection = t.modelSelection
        return d
    }

    /// JS `String(number)` for the interval field: `15`, `1.5`.
    static func jsNumberString(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v) }

    /// `splitModelKey`.
    public static func splitModelKey(_ key: String) -> (instanceId: String, model: String)? {
        guard let i = key.firstIndex(of: ":"), i != key.startIndex, key.index(after: i) != key.endIndex else { return nil }
        return (String(key[..<i]), String(key[key.index(after: i)...]))
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case incomplete, invalidAge, signatureSecret, invalidInterval, checkoutPath
        /// `Invalid filter` with the row's message.
        case invalidFilter(String)
        /// `Invalid webhook settings` with a key or window message.
        case invalidWebhook(String)
        /// More than one webhook problem; T3 shows a toast for each.
        case several([ValidationError])

        public var all: [ValidationError] { if case .several(let list) = self { list } else { [self] } }
        /// The toast's title and description (ScheduledTasksSettings.tsx:870-915).
        public var copy: (title: String, description: String) {
            switch self {
            case .incomplete: ("Scheduled task is incomplete", "Add a title, prompt, project, and model.")
            case .invalidAge: ("Invalid age limit", "Enter whole minutes from 1 to \(ScheduledTaskLogic.maxDeliveryAgeMinutes), or leave it blank.")
            case .signatureSecret: ("Signing secret is required", "Enter the signature header and secret.")
            case .invalidInterval: ("Invalid interval", "Enter an interval of at least one minute.")
            case .checkoutPath: ("Checkout path is required", "Enter the path of the checkout to run in.")
            case .invalidFilter(let message): ("Invalid filter", message)
            case .invalidWebhook(let message): ("Invalid webhook settings", message)
            case .several(let list): list.first?.copy ?? ("", "")
            }
        }
    }

    /// The `scheduledTasks.upsert` input `submit` builds (ScheduledTasksSettings.tsx:856-944), or the first problem.
    /// `selection` is the picked or default model; `storedSecret` whether the live task already has a signing secret.
    public static func upsertInput(_ d: ScheduledTaskDraft, projectId: String, projectExists: Bool, selection: (instanceId: String, model: String)?,
                                   storedSecret: Bool, creationSource: String = "web") -> Result<JSONValue, ValidationError> {
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines), prompt = d.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !prompt.isEmpty, projectExists, let selection else { return .failure(.incomplete) }
        if d.scheduleMode == .webhook, case .failure(let e) = parseFilterDrafts(d.filters) { return .failure(.invalidFilter(e.message)) }
        guard let schedule = schedulePayload(d) else {
            let errors = webhookDraftErrors(d)
            return .failure(errors.count > 1 ? .several(errors) : errors.first ?? .invalidAge)
        }
        if d.scheduleMode == .webhook, d.signatureEnabled,
           d.signatureHeader.trimmingCharacters(in: .whitespaces).isEmpty
            || (d.signatureSecret.trimmingCharacters(in: .whitespaces).isEmpty && !storedSecret) {
            return .failure(.signatureSecret)
        }
        if d.scheduleMode == .interval {
            guard let ms = schedule["everyMs"]?.doubleValue, ms.isFinite, ms == ms.rounded(), abs(ms) <= 9_007_199_254_740_991,
                  ms >= minIntervalMs else { return .failure(.invalidInterval) }
        }
        let path = d.existingWorktreePath.trimmingCharacters(in: .whitespaces)
        if d.workspaceMode == .existingWorktree, path.isEmpty { return .failure(.checkoutPath) }
        let base = d.baseModelSelection
        let model: JSONValue = base != nil && base?["instanceId"]?.stringValue == selection.instanceId && base?["model"]?.stringValue == selection.model
            ? base! : .object(["instanceId": .string(selection.instanceId), "model": .string(selection.model)])
        let strategy: JSONValue = switch d.workspaceMode {
        case .root: .object(["type": .string("root")])
        case .existingWorktree: .object(["type": .string("existing_worktree"), "worktreePath": .string(path)])
        case .worktree:
            .object(["type": .string("worktree"), "baseRef": .string(d.baseRef.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : d.baseRef.trimmingCharacters(in: .whitespaces)),
                     "startFromOrigin": .bool(d.startFromOrigin)])
        }
        var input: [String: JSONValue] = [
            "title": .string(title), "prompt": .string(prompt), "enabled": .bool(d.enabled), "schedule": schedule,
            "projectId": .string(projectId), "threadId": d.threadId.isEmpty ? .null : .string(d.threadId),
            "workspaceStrategy": strategy, "modelSelection": model, "runtimeMode": .string(d.runtimeMode),
            "interactionMode": .string(d.interactionMode), "creationSource": .string(creationSource),
        ]
        if let id = d.editingId { input["id"] = .string(id); input["requireExisting"] = .bool(true) }
        return .success(.object(input))
    }

    /// `scheduleLabel`: `On webhook`, `Every 15 min`, `Weekdays at 09:00`.
    public static func scheduleLabel(_ s: ScheduledTaskSchedule) -> String {
        switch s {
        case .webhook: return "On webhook"
        case .interval(let ms):
            let minutes = ms / 60_000
            return minutes == minutes.rounded() ? "Every \(jsNumberString(minutes)) min" : "Every \(Int(UsageFormat.jsRound(ms / 1000))) sec"
        case .fixedTime(let time, let weekdays):
            let days = weekdays ?? []
            let label = days.isEmpty ? "Daily"
                : days.count == 5 && days.allSatisfy({ (1...5).contains($0) }) ? "Weekdays"
                : days.map { weekdayLabels[max(0, min(6, $0))] }.joined(separator: ", ")
            return "\(label) at \(time)"
        }
    }

    /// `relativeLabel`: past times as `5m ago`, upcoming ones as `in 5m`.
    public static func relativeLabel(_ iso: String?, nowMs: Int64) -> String {
        guard let iso, let ms = T3Timestamp.parseEpochMs(iso) else { return "Not scheduled" }
        let diff = ms - nowMs
        if diff <= 0 {
            guard let r = TimestampRelative.past(iso, nowMs: nowMs) else { return "Not scheduled" }
            return r
        }
        let minutes = Int((Double(diff) / 60_000).rounded(.up))
        if minutes < 2 { return "in under a minute" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = Int(UsageFormat.jsRound(Double(minutes) / 60))
        if hours < 24 { return "in \(hours)h" }
        return "in \(Int(UsageFormat.jsRound(Double(hours) / 24)))d"
    }

    /// `webhookDeliveryLabel` (scheduledTasksSettings.logic.ts:131-147).
    public static func outcomeLabel(_ outcome: String, pendingWindow: Bool = false) -> String {
        switch outcome {
        case "accepted": pendingWindow ? "Opened window" : "Ran"
        case "dispatch_failed": "Run failed"
        case "duplicate": "Duplicate"
        case "coalesced": "Coalesced"
        case "filtered": "Filtered"
        case "rejected_signature": "Bad signature"
        case "disabled": "Task paused"
        case "rate_limited": "Rate limited"
        case "expired": "Too old"
        default: outcome.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// `deliveryOutcomeVariant` (ScheduledTasksSettings.tsx:335-347): a `BadgeView.Variant` name.
    public static func outcomeTone(_ outcome: String) -> String {
        switch outcome {
        case "accepted": "success"
        case "duplicate", "coalesced", "disabled", "rate_limited", "expired": "warning"
        case "dispatch_failed", "rejected_signature": "error"
        default: "outline"
        }
    }

    /// `statusVariant` for the last run badge.
    public static func statusTone(_ status: String) -> String {
        switch status {
        case "failed": "error"
        case "succeeded": "success"
        case "running": "info"
        default: "outline"
        }
    }

    /// `webhookAddress`: where a sender can call the task, as this client shows it.
    public static func webhookAddress(_ endpoint: ScheduledTaskWebhookEndpoint, httpBaseURL: URL?) -> (address: String, copyable: Bool, note: String?) {
        if let url = endpoint.url { return (url, true, nil) }
        guard let base = httpBaseURL, let url = URL(string: endpoint.path, relativeTo: base)?.absoluteURL else {
            return (endpoint.path, false, "Link this environment to T3 Connect for a public URL.")
        }
        let host = (url.host ?? "").lowercased()
        let loopback = host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.") || host.hasSuffix(".localhost")
        return (url.absoluteString, true, loopback
            ? "Only this computer can call this address. Link T3 Connect for a public URL."
            : "Works wherever this environment's address is reachable, for example over Tailscale or your own proxy. Link T3 Connect for a public URL.")
    }
}

/// `formatRelativeTime` for a past instant (timestampFormat.ts:235-248), joined like `relativeLabel` does.
enum TimestampRelative {
    static func past(_ iso: String, nowMs: Int64) -> String? {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return nil }
        let seconds = (nowMs - ms) / 1000
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
