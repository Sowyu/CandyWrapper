import Foundation
import T3Protocol

/// `WorkLogToolLifecycleStatus` (session-logic.ts:60-66).
public enum ToolLifecycleStatus: String, Sendable, Hashable {
    case idle, inProgress, completed, failed, declined, stopped
}

/// `WorkLogEntry.tone`.
public enum WorkLogTone: String, Sendable, Hashable {
    case thinking, tool, info, error
}

/// `ToolActivitySource` (validated by `extractToolActivityPresentation`,
/// work-log/toolPresentation.ts:97-108).
public struct ToolActivitySource: Sendable, Hashable {
    public var key: String
    public var name: String
    /// `browser`, `computer` or `integration`.
    public var kind: String
    public var icon: JSONValue?

    public init(key: String, name: String, kind: String, icon: JSONValue? = nil) {
        self.key = key
        self.name = name
        self.kind = kind
        self.icon = icon
    }
}

/// `WorkLogEntry` (session-logic.ts:68-95): the flat record behind every work row, group and
/// live row. `structuredPayload` keeps the whole turn item because labels and icons read both.
public struct WorkLogEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var createdAt: T3Timestamp
    public var runId: RunId?
    public var label: String
    public var detail: String?
    public var command: String?
    public var rawCommand: String?
    public var changedFiles: [String]?
    public var tone: WorkLogTone
    public var toolTitle: String?
    public var viewedImagePath: String?
    /// `browser` or `computer`.
    public var toolSurface: String?
    /// A `ToolActivityIcon` object (`website`, `native-app` or `themed-logo`).
    public var toolIcon: JSONValue?
    public var toolSource: ToolActivitySource?
    /// `context-compaction`, `runtime.warning`, `runtime.error` or `task.progress`.
    public var sourceActivityKind: String?
    /// Untyped tool data the label helpers read (the item, or `{input, output}`).
    public var toolData: JSONValue?
    public var requestKind: String?
    public var itemType: TurnItemType?
    public var toolLifecycleStatus: ToolLifecycleStatus?
    public var structuredPayload: TurnItem?
    public var projectedItem: ProjectedTurnItem?
    public var questionAnswer: JSONValue?

    public init(
        id: String, createdAt: T3Timestamp, runId: RunId? = nil, label: String, detail: String? = nil,
        command: String? = nil, rawCommand: String? = nil, changedFiles: [String]? = nil, tone: WorkLogTone,
        toolTitle: String? = nil, viewedImagePath: String? = nil, toolSurface: String? = nil,
        toolIcon: JSONValue? = nil, toolSource: ToolActivitySource? = nil, sourceActivityKind: String? = nil,
        toolData: JSONValue? = nil, requestKind: String? = nil, itemType: TurnItemType? = nil,
        toolLifecycleStatus: ToolLifecycleStatus? = nil, structuredPayload: TurnItem? = nil,
        projectedItem: ProjectedTurnItem? = nil, questionAnswer: JSONValue? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.runId = runId
        self.label = label
        self.detail = detail
        self.command = command
        self.rawCommand = rawCommand
        self.changedFiles = changedFiles
        self.tone = tone
        self.toolTitle = toolTitle
        self.viewedImagePath = viewedImagePath
        self.toolSurface = toolSurface
        self.toolIcon = toolIcon
        self.toolSource = toolSource
        self.sourceActivityKind = sourceActivityKind
        self.toolData = toolData
        self.requestKind = requestKind
        self.itemType = itemType
        self.toolLifecycleStatus = toolLifecycleStatus
        self.structuredPayload = structuredPayload
        self.projectedItem = projectedItem
        self.questionAnswer = questionAnswer
    }
}

/// `ToolGroupAction` (work-log/presentation.ts:85-100).
public enum ToolGroupAction: String, Sendable, Hashable {
    case linkPR = "link-pr", unlinkPR = "unlink-pr", listPRs = "list-prs", watchPR = "watch-pr", unwatchPR = "unwatch-pr"
    case read, edit, command, threadCreate = "thread-create", browser, device, codeSearch = "code-search"
    case search, other, update
}

/// `ToolGroupSummaryKind`: a `ToolGroupAction` raw value or `pull-request`, `dynamic-tool`,
/// `reasoning`, `agent-tool`, `tone-tool`, `mixed`.
public typealias ToolGroupSummaryKind = String

/// Label, icon and PR action of a T3 MCP tool call (`resolveT3McpToolPresentation`,
/// work-log/presentation.ts:138-187).
public struct T3ToolPresentation: Sendable, Hashable {
    public var displayName: String
    /// `t3-code`, `browser`, `device` or `pull-request`.
    public var icon: String
    public var action: ToolGroupAction?
}

/// Work log presentation: ports of packages/client-runtime/src/work-log/presentation.ts and the
/// label helpers at the top of MessagesTimeline.logic.ts.
public enum WorkLog {
    // MARK: Building entries (session-logic.ts:355-567)

    /// `projectedWorkEntryStatus`.
    static func lifecycleStatus(_ status: TurnItemStatus) -> ToolLifecycleStatus {
        switch status {
        case .pending, .running, .waiting: .inProgress
        case .completed: .completed
        case .failed: .failed
        case .cancelled, .interrupted: .stopped
        default: .idle
        }
    }

    /// `projectedWorkEntryTone`.
    static func tone(_ type: TurnItemType) -> WorkLogTone {
        switch type {
        case .reasoning: .thinking
        case .commandExecution, .fileChange, .fileSearch, .webSearch, .dynamicTool, .subagent, .threadCreated,
            .userInputRequest, .approvalRequest:
            .tool
        default: .info
        }
    }

    /// `providerErrorPresentation` (session-logic.ts:394-428).
    public static func providerErrorPresentation(_ item: TurnItem) -> (label: String, detail: String) {
        let failure = item["failure"]
        let message = failure?["message"]?.stringValue ?? ""
        let usageLimit = failure?["class"]?.stringValue == "usage_limit"
        guard let retry = item["retry"] else {
            return (usageLimit ? "Usage limit reached" : (item.title?.jsTrimmed.nonEmpty ?? "Provider error"), message)
        }
        let attempt = retry["attempt"]?.intValue ?? 0
        let progress = retry["maxAttempts"]?.intValue.map { "\(attempt)/\($0)" } ?? "\(attempt)"
        let label = switch item.status {
        case .running: "Retrying provider (\(progress))"
        case .completed: "Provider recovered (\(progress) retries)"
        case .failed: "\(usageLimit ? "Usage limit reached" : "Provider error") after \(progress) retries"
        default: "Provider retry stopped (\(progress))"
        }
        var delay = ""
        if item.status == .running, let ms = retry["retryDelayMs"]?.doubleValue, ms > 0 {
            delay = ms < 1_000
                ? " Retrying in \(Int(ms))ms."
                : " Retrying in \(String(format: "%.1f", ms / 1_000).replacing(/\.0$/, with: ""))s."
        }
        return (label, message + delay)
    }

    /// `contextCompactionLabel` (client-runtime work-log/presentation.ts:70-79).
    static func contextCompactionLabel(_ item: TurnItem) -> String {
        if item.status == .failed { return "Context compaction failed" }
        if item.status == .cancelled || item.status == .interrupted { return "Context compaction stopped" }
        if ThreadRelationships.isWorkActive(item.status.rawValue) { return "Compacting context" }
        if let tokens = contextCompactionTokenCounts(item) { return "Context compacted \(tokens.before) → \(tokens.after) tokens" }
        return "Context compacted"
    }

    /// `contextCompactionTokenCounts` (presentation.ts:57-68): the row draws an arrow icon between them.
    public static func contextCompactionTokenCounts(_ item: TurnItem) -> (before: String, after: String)? {
        guard item.status != .running, let before = item["beforeTokenCount"]?.doubleValue,
              let after = item["afterTokenCount"]?.doubleValue else { return nil }
        return (formatTokens(before), formatTokens(after))
    }

    /// `extractToolActivityPresentation` (work-log/toolPresentation.ts:110-131).
    ///
    /// // ponytail: icon URLs are not scheme-checked here; the view must accept only http(s) and
    /// data URLs before loading one.
    static func applyToolActivityPresentation(_ item: TurnItem, to entry: inout WorkLogEntry) {
        if let surface = item.string("toolSurface"), surface == "browser" || surface == "computer" { entry.toolSurface = surface }
        if let icon = item["toolIcon"], ["website", "native-app", "themed-logo"].contains(icon["_tag"]?.stringValue ?? "") {
            entry.toolIcon = icon
        }
        if let source = item["toolSource"], let key = source["key"]?.stringValue?.jsTrimmed.nonEmpty,
            let name = source["name"]?.stringValue?.jsTrimmed.nonEmpty, let kind = source["kind"]?.stringValue,
            ["browser", "computer", "integration"].contains(kind)
        {
            entry.toolSource = ToolActivitySource(key: key, name: name, kind: kind, icon: source["icon"])
        }
        if let path = item.string("viewedImagePath")?.jsTrimmed, !path.isEmpty, !path.contains(where: \.isNewline),
            isWorkspaceImagePath(path)
        {
            entry.viewedImagePath = path
        }
    }

    /// `workEntryViewedImagePath` (client-runtime/src/work-log/presentation.ts:477-493): the item's viewed image,
    /// else a read whose detail is one image path.
    public static func viewedImagePath(_ e: WorkLogEntry) -> String? {
        if let path = e.viewedImagePath { return path }
        guard let detail = e.detail?.jsTrimmed, !detail.isEmpty, !detail.contains(where: \.isNewline),
              toolGroupAction(e) == .read, isWorkspaceImagePath(detail) else { return nil }
        return detail
    }

    /// `isWorkspaceImagePreviewPath` (packages/shared/src/filePreview.ts:76-85,182-184).
    static func isWorkspaceImagePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".avif", ".gif", ".ico", ".jpeg", ".jpg", ".png", ".svg", ".webp"].contains { lower.hasSuffix($0) }
    }

    /// `projectedWorkEntry` (session-logic.ts:430-567).
    public static func entry(for row: ProjectedTurnItem) -> WorkLogEntry {
        let item = row.item
        let title = item.title?.jsTrimmed.nonEmpty
        var entry = WorkLogEntry(
            id: item.id.rawValue, createdAt: item.startedAt ?? item.updatedAt, runId: item.runId, label: "",
            tone: tone(item.type), itemType: item.type, toolLifecycleStatus: lifecycleStatus(item.status),
            structuredPayload: item, projectedItem: row)
        applyToolActivityPresentation(item, to: &entry)
        switch item.type {
        case .threadCreated:
            entry.label = "Created thread"
        case .compaction:
            entry.label = contextCompactionLabel(item)
            entry.sourceActivityKind = "context-compaction"
            entry.detail = item.string("summary")?.nonEmpty
        case .reasoning:
            entry.label = title ?? "Thinking"
            entry.detail = item.text.nonEmpty
        case .commandExecution:
            entry.label = title ?? "Ran command"
            entry.command = item.string("input") ?? ""
            entry.rawCommand = entry.command
            entry.toolTitle = title ?? "Command"
            entry.toolData = item.raw
        case .fileChange:
            let changes = item["changes"]?.arrayValue
            let fileName = item.string("fileName") ?? ""
            entry.label = title ?? ((changes?.count ?? 0) > 1 ? "Changed \(changes!.count) files" : "Changed \(fileName)")
            entry.changedFiles = changes.map { $0.compactMap { $0["path"]?.stringValue } } ?? [fileName]
            entry.toolTitle = title ?? "File change"
            entry.toolData = item.raw
        case .fileSearch:
            entry.label = title ?? formatSearchToolLabel(item.raw) ?? "Searched files"
            entry.detail = item.string("pattern")?.nonEmpty
            entry.toolTitle = title ?? "File search"
            entry.toolData = item.raw
        case .webSearch:
            entry.label = title ?? "Searched the web"
            let patterns = item["patterns"]?.arrayValue?.compactMap(\.stringValue) ?? []
            entry.detail = patterns.isEmpty ? nil : patterns.joined(separator: ", ")
            entry.toolTitle = title ?? "Web search"
            entry.toolData = item.raw
        case .checkpoint:
            entry.label = title ?? "Checkpoint captured"
            entry.changedFiles = item["files"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
            entry.toolData = item.raw
        case .systemNotice:
            entry.label = item.string("message") ?? ""
            entry.sourceActivityKind = "runtime.warning"
        case .error:
            (entry.label, entry.detail) = providerErrorPresentation(item)
            if item["failure"]?["class"]?.stringValue == "usage_limit", item.status != .completed {
                entry.sourceActivityKind = "runtime.warning"
            } else if item["retry"] == nil {
                entry.sourceActivityKind = "runtime.error"
            }
            entry.toolData = item.raw
        case .dynamicTool:
            let toolName = item.toolName
            let toolInput = JSONValue.object(["input": item.input ?? .null])
            let classified = classifyToolActivity(
                itemType: "dynamic_tool_call", data: .object(["toolName": toolName.map(JSONValue.string) ?? .null, "input": item.input ?? .null]))
            entry.label = title ?? {
                switch classified {
                case .read: formatReadToolLabel(collectToolFilePaths(toolInput).first ?? "")
                case .search: formatSearchToolLabel(toolInput) ?? toolName ?? "Tool call"
                default: toolName ?? "Tool call"
                }
            }()
            entry.toolTitle = title ?? toolName ?? "Tool"
            entry.toolData = .object(["input": item.input ?? .null, "output": item.output ?? .null])
        case .approvalRequest:
            entry.label = title ?? "Approval requested"
            entry.detail = item.string("prompt") ?? item.string("requestKind")
            entry.toolData = item.raw
        case .userInputRequest:
            entry.label = title ?? (item.questionAnswer != nil ? "Answered questions" : "Input requested")
            entry.questionAnswer = item.questionAnswer
            entry.toolData = item.raw
        default:
            entry.label = title ?? item.type.rawValue.replacingOccurrences(of: "_", with: " ")
            entry.toolData = item.raw
        }
        return entry
    }

    // MARK: Predicates (session-logic.ts:176-218, work-log/presentation.ts:356-418)

    /// The timeline's `workLogEntryIsToolLike` (session-logic.ts:176-184).
    public static func isToolLike(_ entry: WorkLogEntry) -> Bool {
        entry.tone != .info || entry.command != nil || entry.requestKind != nil
    }

    /// The presentation module's version, which also accepts provider lifecycle item types.
    static func isToolLikeForPresentation(_ entry: WorkLogEntry) -> Bool {
        if entry.tone != .info { return true }
        if let command = entry.command, !command.jsTrimmed.isEmpty { return true }
        if entry.requestKind != nil { return true }
        return ["command_execution", "file_change", "mcp_tool_call", "dynamic_tool_call", "collab_agent_tool_call", "web_search", "image_view"]
            .contains(entry.itemType?.rawValue ?? "")
    }

    /// `workEntryToolName` (work-log/presentation.ts:117-128).
    static func toolName(_ entry: WorkLogEntry) -> String? {
        if let item = entry.structuredPayload, item.type == .dynamicTool, let name = item.toolName, !name.isEmpty { return name }
        if let server = entry.toolData?["server"]?.stringValue, let tool = entry.toolData?["tool"]?.stringValue {
            return "\(server).\(tool)"
        }
        if let name = entry.toolData?["toolName"]?.stringValue { return name }
        return T3McpTools.definition(entry.toolTitle) != nil ? entry.toolTitle : entry.label
    }

    /// `workEntryToolOutput` (work-log/presentation.ts:130-136).
    static func toolOutput(_ entry: WorkLogEntry) -> JSONValue? {
        if let item = entry.structuredPayload, item.type == .dynamicTool { return item.output }
        let data = entry.toolData
        return data?["output"] ?? data?["result"] ?? data?["rawOutput"] ?? data?["content"]
    }

    static func toolInput(_ entry: WorkLogEntry) -> JSONValue? {
        if let item = entry.structuredPayload, item.type == .dynamicTool { return item.input }
        let data = entry.toolData
        return data?["arguments"] ?? data?["input"] ?? data?["rawInput"]
    }

    static func indicatesFailure(_ entry: WorkLogEntry, includeCommand: Bool) -> Bool {
        // Rows are derived again on every stream update, and checking every tool's output each
        // time cost about 10% CPU on a long thread. An item gets a new `updatedAt` whenever it
        // changes, so the answer is kept per item revision.
        guard let revision = entry.structuredPayload?.updatedAt.raw else { return checkFailure(entry, includeCommand: includeCommand) }
        let key = "\(entry.id)|\(revision)|\(includeCommand)|\(entry.tone)|\(entry.toolLifecycleStatus.map { "\($0)" } ?? "")" as NSString
        if let known = failureCache.object(forKey: key) { return known.boolValue }
        let failed = checkFailure(entry, includeCommand: includeCommand)
        failureCache.setObject(NSNumber(value: failed), forKey: key)
        return failed
    }

    // ponytail: process-wide cache with NSCache eviction, key it per thread if memory shows up in profiles
    nonisolated(unsafe) private static let failureCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 20_000
        return cache
    }()

    private static func checkFailure(_ entry: WorkLogEntry, includeCommand: Bool) -> Bool {
        if entry.tone == .error || entry.toolLifecycleStatus == .failed || entry.toolLifecycleStatus == .declined { return true }
        // Reasoning detail is the model's own prose, not tool output, so "exit code 2 is expected" is no failure
        // (presentation.ts:368-371, T3 3315 e0366ad0e4).
        guard isToolLikeForPresentation(entry), entry.itemType != .reasoning else { return false }
        if T3McpTools.definition(toolName(entry)) != nil, t3ToolResultIndicatesFailure(toolOutput(entry)) { return true }
        if let item = entry.structuredPayload, item.type == .commandExecution {
            if item["outputIndicatesFailure"]?.boolValue == true { return true }
            if let code = item.exitCode, code != 0 { return true }
            if let output = item.output?.stringValue, toolOutputIndicatesFailure(String(output.prefix(32_768))) { return true }
        }
        let output = includeCommand
            ? [entry.detail, entry.command].compactMap { $0?.nonEmpty }.joined(separator: "\n")
            : (entry.detail ?? "")
        return !output.isEmpty && toolOutputIndicatesFailure(output)
    }

    /// `workEntryIndicatesToolFailure`: includes legacy rows that stored errors in `command`.
    public static func indicatesFailure(_ entry: WorkLogEntry) -> Bool { indicatesFailure(entry, includeCommand: true) }

    /// `workEntryDisplayIndicatesToolFailure`: the command text never counts as an error.
    public static func displayIndicatesFailure(_ entry: WorkLogEntry) -> Bool { indicatesFailure(entry, includeCommand: false) }

    /// The timeline's `workEntryIndicatesToolSuccess` (session-logic.ts:189-207).
    public static func indicatesSuccess(_ entry: WorkLogEntry) -> Bool {
        guard isToolLike(entry), !indicatesFailure(entry), !(entry.tone == .thinking && entry.itemType != .reasoning)
        else { return false }
        return ![.failed, .declined, .inProgress, .stopped, .idle].contains(entry.toolLifecycleStatus)
    }

    /// `workEntryIndicatesToolNeutralStatus`: tool-like with neither success nor failure.
    public static func indicatesNeutral(_ entry: WorkLogEntry) -> Bool {
        isToolLike(entry) && !indicatesFailure(entry) && !indicatesSuccess(entry)
    }

    /// `workEntryIsVisibleInGroup` (MessagesTimeline.logic.ts:274-286).
    public static func isVisibleInGroup(_ entry: WorkLogEntry, expandedToolGroupEntry: Bool = false) -> Bool {
        if entry.itemType == .reasoning { return !(entry.detail?.jsTrimmed.isEmpty ?? true) }
        return (expandedToolGroupEntry && (entry.toolLifecycleStatus == .inProgress || entry.sourceActivityKind == "task.progress"))
            || entry.toolLifecycleStatus == .stopped
            || !indicatesNeutral(entry)
    }

    /// `workEntryIsActiveTurnActivity` (MessagesTimeline.logic.ts:86-92).
    static func isActiveTurnActivity(_ entry: WorkLogEntry) -> Bool {
        entry.toolLifecycleStatus == .inProgress
            || (entry.toolLifecycleStatus == nil && (entry.sourceActivityKind == "task.progress" || isToolLike(entry)))
    }

    // MARK: T3 tools

    /// The trimmed thread id a `t3_thread_read` call targets (`threadReadTargetId`, MessagesTimeline.logic.ts:182-190).
    public static func threadReadTargetId(_ entry: WorkLogEntry) -> String? {
        guard let item = entry.structuredPayload, item.type == .dynamicTool,
              T3McpTools.definition(item.toolName)?.summaryAction == "thread-read",
              let id = item["input"]?["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else { return nil }
        return id
    }

    /// "Read a T3 thread" becomes "Read thread", then the target's title in quotes (`threadReadLabelPrefix`, :205-209).
    public static func threadReadLabelPrefix(_ label: String) -> String? {
        let object = " a T3 thread"
        return label.hasSuffix(object) ? String(label.dropLast(object.count)) + " thread" : nil
    }

    /// `liveActivityToolStatus` (work-log/presentation.ts:190-196).
    static func liveActivityToolStatus(_ status: ToolLifecycleStatus?, presentTense: Bool) -> ToolLifecycleStatus {
        if let status, [.failed, .declined, .stopped, .idle].contains(status) { return status }
        return presentTense || status == .inProgress ? .inProgress : .completed
    }

    /// `resolveWorkEntryToolPresentation` (work-log/presentation.ts:199-212).
    public static func toolPresentation(_ entry: WorkLogEntry, fallbackStatus: ToolLifecycleStatus? = nil) -> T3ToolPresentation? {
        guard let definition = T3McpTools.definition(toolName(entry), input: toolInput(entry)) else { return nil }
        let status = t3ToolResultIndicatesFailure(toolOutput(entry)) ? .failed : (entry.toolLifecycleStatus ?? fallbackStatus)
        let verb = switch status {
        case .inProgress: definition.running
        case .completed: definition.completed
        case .failed: "Failed to \(definition.action.lowercased())"
        case .declined: "Declined to \(definition.action.lowercased())"
        case .stopped: "Stopped \(definition.running.lowercased())"
        default: definition.running
        }
        let prAction = ToolGroupAction(rawValue: definition.summaryAction).flatMap {
            [.linkPR, .unlinkPR, .listPRs, .watchPR, .unwatchPR].contains($0) ? $0 : nil
        }
        var target = definition.detail
        let data = entry.toolData
        let input = (data?["arguments"]?.objectValue ?? data?["input"]?.objectValue ?? data?["rawInput"]?.objectValue)
        // ponytail: only GitHub-style `/pull/<n>` URLs give a number; port parseChangeRequestUrl
        // for other forges.
        let urlNumber = input?["url"]?.stringValue?.firstMatch(of: /\/pull(?:s)?\/(\d+)/).flatMap { Int($0.1) }
        if let prAction, prAction != .listPRs, let number = urlNumber ?? input?["number"]?.intValue, number > 0 {
            target = "PR #\(number)"
        }
        return T3ToolPresentation(displayName: "\(verb) \(target)", icon: definition.icon, action: prAction)
    }

    // MARK: Grouping (work-log/presentation.ts:420-761)

    static func isLocalCodeSearch(_ entry: WorkLogEntry) -> Bool {
        entry.itemType == .fileSearch
            || (entry.itemType == .webSearch && normalizeCompactToolLabel(entry.toolTitle ?? entry.label).contains(/\bgrep\b/.ignoresCase()))
    }

    /// `toolGroupAction` (work-log/presentation.ts:428-476).
    public static func toolGroupAction(_ entry: WorkLogEntry) -> ToolGroupAction {
        if entry.itemType == .threadCreated { return .threadCreate }
        let presentation = toolPresentation(entry)
        if let action = presentation?.action { return action }
        if presentation?.icon == "browser" { return .browser }
        if presentation?.icon == "device" { return .device }
        if entry.requestKind == "file-read" || entry.viewedImagePath != nil { return .read }
        if entry.itemType == .approvalRequest || entry.itemType == .userInputRequest {
            return isToolLikeForPresentation(entry) ? .other : .update
        }
        var data = entry.toolData?.objectValue ?? [:]
        let toolName = entry.structuredPayload?.type == .dynamicTool
            ? entry.structuredPayload?.toolName
            : (data["toolName"]?.stringValue ?? entry.toolTitle)
        if let toolName, !toolName.isEmpty { data["toolName"] = .string(toolName) }
        let itemType: String? = switch entry.itemType {
        case .commandExecution?, .fileChange?, .webSearch?: entry.itemType!.rawValue
        case .dynamicTool?: "dynamic_tool_call"
        default: nil
        }
        let classified = classifyToolActivity(itemType: itemType, data: .object(data))
        if classified == .read { return .read }
        if classified == .fileChange || entry.itemType == .fileChange { return .edit }
        if classified == .command || entry.itemType == .commandExecution || entry.command != nil { return .command }
        if classified == .search {
            return entry.itemType == .webSearch && !isLocalCodeSearch(entry) ? .search : .codeSearch
        }
        if isLocalCodeSearch(entry) { return .codeSearch }
        if entry.itemType == .webSearch { return .search }
        if !(entry.changedFiles ?? []).isEmpty { return .edit }
        return isToolLikeForPresentation(entry) ? .other : .update
    }

    static func toolGroupActionCount(_ action: ToolGroupAction, _ entries: [WorkLogEntry]) -> Int {
        guard action == .edit else { return entries.count }
        var files = Set<String>()
        var withoutFiles = 0
        for entry in entries {
            if let changed = entry.changedFiles, !changed.isEmpty { files.formUnion(changed) } else { withoutFiles += 1 }
        }
        return files.count + withoutFiles
    }

    static func toolGroupActionLabel(_ action: ToolGroupAction, _ count: Int) -> String {
        func n(_ singular: String, _ plural: String) -> String { "\(count) \(count == 1 ? singular : plural)" }
        return switch action {
        case .linkPR: "Linked \(n("pull request", "pull requests"))"
        case .unlinkPR: "Unlinked \(n("pull request", "pull requests"))"
        case .watchPR: "Watching \(n("pull request", "pull requests"))"
        case .unwatchPR: "Stopped watching \(n("pull request", "pull requests"))"
        case .listPRs: count == 1 ? "Checked linked pull requests" : "Checked linked pull requests \(count) times"
        case .read: "Read \(n("file", "files"))"
        case .edit: "Changed \(n("file", "files"))"
        case .command: "Ran \(n("command", "commands"))"
        case .threadCreate: "Created \(n("thread", "threads"))"
        case .device: "Used device controls \(n("time", "times"))"
        case .browser: "Used browser \(n("time", "times"))"
        case .search: "Searched the web \(n("time", "times"))"
        case .codeSearch: "Searched code \(n("time", "times"))"
        case .other: "Used \(n("tool", "tools"))"
        case .update: "Received \(n("update", "updates"))"
        }
    }

    static func summaryActionPriority(_ action: String) -> Int {
        let first: Set<String> = [
            "command", "edit", "delegate", "task-cancel", "thread-create", "thread-send", "thread-interrupt", "workflow-stop",
            "schedule-create", "schedule-update", "schedule-delete", "schedule-run", "thread-configure", "thread-fork",
            "thread-merge", "thread-organize", "thread-update", "queue-edit", "queue-cancel", "queue-reorder",
            "queue-steer", "question-respond", "worktree-handoff", "project-create", "project-update",
            "project-delete", "project-clone", "environment-update", "attachment-prepare", "attachment-discard",
            "attachment-send",
        ]
        if first.contains(action) { return 0 }
        return action == "other" || action == "update" ? 2 : 1
    }

    static func t3SummaryCall(_ entry: WorkLogEntry) -> T3ToolSummaryCall {
        let item = entry.structuredPayload
        let data = entry.toolData
        let input = item?.type == .dynamicTool ? item?.input : (data?["arguments"] ?? data?["input"] ?? data?["rawInput"])
        let outcome = entry.toolLifecycleStatus == .failed || entry.toolLifecycleStatus == .declined || entry.tone == .error
            ? "failed" : entry.toolLifecycleStatus == .completed ? "completed" : "unfinished"
        return T3ToolSummaryCall(input: input, output: toolOutput(entry), outcome: outcome)
    }

    /// `summarizeToolGroup` (work-log/presentation.ts:645-729): at most two action categories;
    /// every omitted call still counts in the remainder.
    public static func summarizeToolGroup(_ allEntries: [WorkLogEntry]) -> (summary: String, hasFailure: Bool) {
        let entries = allEntries.filter { $0.itemType != .reasoning }
        if !allEntries.isEmpty && entries.isEmpty {
            return (allEntries.count == 1 ? "Thought" : "Thought (×\(allEntries.count))", false)
        }
        struct Group { var key: String; var action: ToolGroupAction; var t3Action: String?; var entries: [WorkLogEntry] }
        var groups: [Group] = []
        var sources: [(key: String, source: ToolActivitySource)] = []
        for entry in entries {
            let t3Action = T3McpTools.definition(toolName(entry), input: toolInput(entry))?.summaryAction
            if let source = entry.toolSource, t3Action == nil {
                if let index = sources.firstIndex(where: { $0.key == source.key }) { sources[index].source = source } else { sources.append((source.key, source)) }
                continue
            }
            let action = toolGroupAction(entry)
            let key = t3Action ?? action.rawValue
            if let index = groups.firstIndex(where: { $0.key == key }) { groups[index].entries.append(entry) } else {
                groups.append(Group(key: key, action: action, t3Action: t3Action, entries: [entry]))
            }
        }
        struct Summary { var index: Int; var count: Int; var priority: Int; var label: String; var failedCount: Int }
        let summaries = groups.enumerated().map { index, group -> Summary in
            let (label, failed) = group.t3Action.map { summarizeT3ToolCalls($0, group.entries.map(t3SummaryCall)) }
                ?? (toolGroupActionLabel(group.action, toolGroupActionCount(group.action, group.entries)),
                    group.entries.filter(displayIndicatesFailure).count)
            return Summary(index: index, count: group.entries.count, priority: summaryActionPriority(group.key), label: label, failedCount: failed)
        }
        let selected = summaries.sorted { ($0.priority, $0.index) < ($1.priority, $1.index) }.prefix(2).sorted { $0.index < $1.index }
        var labels = selected.map(\.label)
        if !sources.isEmpty {
            let names = sources.map(\.source.name)
            let formatted = names.count < 2 ? names[0]
                : names.count == 2 ? names.joined(separator: " and ")
                : names.dropLast().joined(separator: ", ") + ", and " + names.last!
            let allIntegrations = sources.allSatisfy { $0.source.kind == "integration" }
            labels.insert("Used \(formatted)" + (allIntegrations ? (sources.count == 1 ? " integration" : " integrations") : ""), at: 0)
        }
        let sourced = entries.filter { $0.toolSource != nil && T3McpTools.definition(toolName($0)) == nil }.count
        let remaining = entries.count - sourced - selected.reduce(0) { $0 + $1.count }
        if remaining > 0 { labels.append("Performed \(remaining) other \(remaining == 1 ? "action" : "actions")") }
        let sentence = labels.enumerated().map { index, label in
            index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
        }
        let summary = sentence.count < 3
            ? sentence.joined(separator: " and ")
            : sentence.dropLast().joined(separator: ", ") + ", and " + sentence.last!
        return (summary, summaries.contains { $0.failedCount > 0 })
    }

    /// `toolGroupSummaryKind` (work-log/presentation.ts:731-761).
    public static func toolGroupSummaryKind(_ allEntries: [WorkLogEntry]) -> ToolGroupSummaryKind {
        let entries = allEntries.filter { $0.itemType != .reasoning }
        if !allEntries.isEmpty && entries.isEmpty { return "reasoning" }
        if !entries.isEmpty, entries.allSatisfy({ toolPresentation($0)?.icon == "pull-request" }) { return "pull-request" }
        let actions = Set(entries.map(toolGroupAction))
        guard actions.count == 1, let action = actions.first else { return "mixed" }
        if action != .other { return action.rawValue }
        let fallback = Set(entries.map { entry -> String in
            if entry.itemType == .dynamicTool { return "dynamic-tool" }
            if entry.itemType == .subagent || entry.tone == .thinking { return "agent-tool" }
            if entry.tone == .tool { return "tone-tool" }
            return "other"
        })
        return fallback.count == 1 ? fallback.first! : "mixed"
    }

    // MARK: Labels (MessagesTimeline.logic.ts:94-272)

    static func readRawPaths(_ entry: WorkLogEntry) -> [String] {
        if let changed = entry.changedFiles, !changed.isEmpty { return changed }
        if let item = entry.structuredPayload, item.type == .dynamicTool {
            let paths = collectToolFilePaths(.object(["input": item.input ?? .null]))
            if !paths.isEmpty { return paths }
        }
        return entry.toolData?.objectValue != nil ? collectToolFilePaths(entry.toolData) : []
    }

    /// `workEntryReadOutput` (MessagesTimeline.logic.ts:212-238): the unique absolute paths a read
    /// touched, one per line.
    public static func readOutput(_ entry: WorkLogEntry, workspaceRoot: String?) -> String? {
        var seen = Set<String>()
        let paths = readRawPaths(entry).compactMap { path -> String? in
            let trimmed = path.jsTrimmed.replacingOccurrences(of: "\\", with: "/")
            guard let root = workspaceRoot, !root.isEmpty, !trimmed.hasPrefix("/"),
                trimmed.wholeMatch(of: /[a-zA-Z]:(?:[\/\\].*)?/) == nil
            else { return trimmed }
            let base = root.replacingOccurrences(of: "\\", with: "/").replacing(/\/+$/, with: "")
            return base + "/" + trimmed.replacing(/^\.\//, with: "").replacing(/^\/+/, with: "")
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return paths.isEmpty ? nil : paths.joined(separator: "\n")
    }

    /// `workEntryDisplayLabel` (MessagesTimeline.logic.ts:131-180). First match wins.
    public static func displayLabel(_ entry: WorkLogEntry, workspaceRoot: String?) -> String {
        if entry.itemType == .systemNotice { return entry.label }
        if entry.itemType == .reasoning || entry.tone == .thinking {
            return entry.detail?.collapsedWhitespace.nonEmpty ?? entry.label
        }
        if let presentation = toolPresentation(entry) { return presentation.displayName }
        if let command = entry.command, !command.jsTrimmed.isEmpty { return commandDisplayText(command) }
        let action = toolGroupAction(entry)
        if action == .codeSearch || action == .search {
            let search = entry.itemType == .fileSearch ? entry.label : formatSearchToolLabel(entry.toolData?.objectValue != nil ? entry.toolData : nil)
            if let search, !search.isEmpty { return search }
        }
        if action == .read {
            let paths = readRawPaths(entry).map { formatWorkspaceRelativePath($0, workspaceRoot: workspaceRoot) }
            if let first = paths.first, !first.isEmpty { return formatReadToolLabel(first, extraCount: paths.count - 1) }
        }
        let providerRetry = entry.projectedItem?.item.type == .error && entry.projectedItem?.item["retry"] != nil
        if let item = entry.structuredPayload, item.type == .dynamicTool, let title = dynamicToolTitle(item.toolName, item.input) {
            return title
        }
        let compactDetail = entry.detail?.jsTrimmed ?? ""
        let detailIsSearchOutput = (action == .codeSearch || action == .search) && compactDetail.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
        if !compactDetail.isEmpty, !providerRetry, action != .read, !detailIsSearchOutput { return compactDetail }
        if let changed = entry.changedFiles, let first = changed.first, !first.isEmpty {
            let path = formatWorkspaceRelativePath(first, workspaceRoot: workspaceRoot)
            return changed.count == 1 ? path : "\(path) +\(changed.count - 1) more"
        }
        if action == .read && entry.viewedImagePath == nil { return "Read file" }
        let heading = normalizeCompactToolLabel(entry.toolTitle?.nonEmpty ?? entry.label)
        return heading.prefix(1).uppercased() + heading.dropFirst()
    }

    /// `singleToolCallLabel` (MessagesTimeline.logic.ts:94-104): the label of a lone settled tool.
    public static func singleToolCallLabel(_ entry: WorkLogEntry) -> String {
        if entry.itemType == .reasoning { return entry.detail?.collapsedWhitespace.nonEmpty ?? "Thought" }
        if let presentation = toolPresentation(entry, fallbackStatus: .completed) { return presentation.displayName }
        if let item = entry.structuredPayload, item.type == .dynamicTool, let title = dynamicToolTitle(item.toolName, item.input) {
            return title
        }
        if entry.itemType == .webSearch { return entry.toolTitle ?? "Web search" }
        return displayLabel(entry, workspaceRoot: nil)
    }

    /// `liveWorkEntryLabel` (MessagesTimeline.logic.ts:240-272) for the live activity row.
    ///
    /// // ponytail: the verb's object is the first token's basename, not the full
    /// `commandProgramName` (wrappers, sudo, env, PowerShell; commandLabel.ts:1073-1373).
    public static func liveLabel(_ entry: WorkLogEntry, workspaceRoot: String?, active: Bool) -> String {
        let status = liveActivityToolStatus(entry.toolLifecycleStatus, presentTense: active)
        if entry.itemType == .reasoning {
            return entry.detail?.collapsedWhitespace.nonEmpty ?? (status == .inProgress ? "Thinking" : "Thought")
        }
        var withStatus = entry
        withStatus.toolLifecycleStatus = status
        if let presentation = toolPresentation(withStatus) { return presentation.displayName }
        if let command = entry.command?.jsTrimmed.nonEmpty {
            let verb = switch status {
            case .inProgress: "Running"
            case .failed: "Failed"
            case .declined: "Declined"
            case .stopped: "Stopped"
            default: "Ran"
            }
            let unwrapped = withoutShellWrapper(command)
            let program = tokenizeShellCommand(unwrapped)?.first
                .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            return "\(verb) \(program ?? "command")"
        }
        return displayLabel(entry, workspaceRoot: workspaceRoot)
    }
}
