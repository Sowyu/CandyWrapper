import Foundation
import T3Protocol

/// One T3 MCP tool (packages/shared/src/t3McpToolPresentation.ts:63-330).
public struct T3McpToolDefinition: Sendable, Equatable {
    public var action: String
    public var running: String
    public var completed: String
    public var detail: String
    /// A `T3McpToolSummaryAction` such as `delegate` or `thread-read`.
    public var summaryAction: String
    /// `t3-code`, `browser`, `device` or `pull-request`.
    public var icon: String
    public var displayName: String

    init(labels: (String, String, String, String), summaryAction: String, icon: String, displayName: String? = nil) {
        (action, running, completed, detail) = labels
        self.summaryAction = summaryAction
        self.icon = icon
        self.displayName = displayName ?? "\(labels.0) \(labels.3)"
    }
}

/// The T3 orchestration tool inventory, generated from `T3_MCP_TOOLS`
/// (t3McpToolPresentation.ts:86-323). Regenerate when T3_VERSION moves.
public enum T3McpTools {
    static let all: [String: T3McpToolDefinition] = [
        "link_pull_request": .init(labels: ("Link", "Linking", "Linked", "a pull request"), summaryAction: "link-pr", icon: "pull-request"),
        "unlink_pull_request": .init(labels: ("Unlink", "Unlinking", "Unlinked", "a pull request"), summaryAction: "unlink-pr", icon: "pull-request"),
        "list_thread_pull_requests": .init(labels: ("Check", "Checking", "Checked", "linked pull requests"), summaryAction: "list-prs", icon: "pull-request"),
        "watch_pull_request": .init(labels: ("Watch", "Watching", "Watching", "a pull request"), summaryAction: "watch-pr", icon: "pull-request"),
        "unwatch_pull_request": .init(labels: ("Stop watching", "Stopping watching", "Stopped watching", "a pull request"), summaryAction: "unwatch-pr", icon: "pull-request"),
        "orchestrator_capabilities": .init(labels: ("Get", "Getting", "Got", "orchestration capabilities"), summaryAction: "capabilities", icon: "t3-code"),
        "delegate_task": .init(labels: ("Delegate", "Delegating", "Delegated", "a child task"), summaryAction: "delegate", icon: "t3-code"),
        "task_status": .init(labels: ("Get", "Getting", "Got", "delegated task status"), summaryAction: "task-status", icon: "t3-code"),
        "task_cancel": .init(labels: ("Cancel", "Canceling", "Requested cancellation of", "delegated task"), summaryAction: "task-cancel", icon: "t3-code"),
        "schedule_task": .init(labels: ("Schedule", "Scheduling", "Scheduled", "a recurring task"), summaryAction: "schedule-create", icon: "t3-code"),
        "list_scheduled_tasks": .init(labels: ("List", "Listing", "Listed", "scheduled tasks"), summaryAction: "schedule-list", icon: "t3-code"),
        "update_scheduled_task": .init(labels: ("Update", "Updating", "Updated", "a scheduled task"), summaryAction: "schedule-update", icon: "t3-code"),
        "delete_scheduled_task": .init(labels: ("Delete", "Deleting", "Requested deletion of", "a scheduled task"), summaryAction: "schedule-delete", icon: "t3-code"),
        "request_secret": .init(labels: ("Ask for", "Asking for", "Asked for", "a secret"), summaryAction: "secret-request", icon: "t3-code"),
        "create_threads": .init(labels: ("Create", "Creating", "Created", "T3 threads"), summaryAction: "thread-create", icon: "t3-code"),
        "t3_thread_start": .init(labels: ("Start", "Starting", "Started", "a T3 thread"), summaryAction: "thread-create", icon: "t3-code"),
        "t3_thread_list": .init(labels: ("List", "Listing", "Listed", "T3 threads"), summaryAction: "thread-list", icon: "t3-code"),
        "t3_thread_read": .init(labels: ("Read", "Reading", "Read", "a T3 thread"), summaryAction: "thread-read", icon: "t3-code"),
        "t3_thread_send": .init(labels: ("Send", "Sending", "Sent", "to a T3 thread"), summaryAction: "thread-send", icon: "t3-code"),
        "t3_thread_wait": .init(labels: ("Wait", "Waiting", "Waited", "for a T3 thread"), summaryAction: "thread-wait", icon: "t3-code"),
        "t3_thread_interrupt": .init(labels: ("Interrupt", "Interrupting", "Requested an interrupt of", "a T3 thread"), summaryAction: "thread-interrupt", icon: "t3-code"),
        "t3_worktree_handoff": .init(labels: ("Hand off", "Handing off", "Handed off", "thread to a git worktree"), summaryAction: "worktree-handoff", icon: "t3-code"),
        "t3_worktree_status": .init(labels: ("Get", "Getting", "Got", "thread worktree status"), summaryAction: "worktree-status", icon: "t3-code"),
        "preview_status": .init(labels: ("Get", "Getting", "Got", "preview browser status"), summaryAction: "browser", icon: "browser"),
        "preview_open": .init(labels: ("Open", "Opening", "Opened", "a page in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_navigate": .init(labels: ("Navigate", "Navigating", "Navigated", "the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_dialog": .init(labels: ("Respond", "Responding", "Responded", "to a preview browser dialog"), summaryAction: "browser", icon: "browser"),
        "preview_snapshot": .init(labels: ("Take a snapshot of", "Taking a snapshot of", "Took a snapshot of", "the preview page"), summaryAction: "browser", icon: "browser", displayName: "Snapshot the preview page"),
        "preview_click": .init(labels: ("Click", "Clicking", "Clicked", "in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_press": .init(labels: ("Press", "Pressing", "Pressed", "a key in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_type": .init(labels: ("Type", "Typing", "Typed", "in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_hover": .init(labels: ("Hover", "Hovering", "Hovered", "in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_select": .init(labels: ("Choose", "Choosing", "Chose", "an option in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_drag": .init(labels: ("Drag", "Dragging", "Dragged", "in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_upload": .init(labels: ("Upload", "Uploading", "Uploaded", "files to the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_scroll": .init(labels: ("Scroll", "Scrolling", "Scrolled", "the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_resize": .init(labels: ("Resize", "Resizing", "Resized", "the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_evaluate": .init(labels: ("Evaluate", "Evaluating", "Evaluated", "script in the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_wait_for": .init(labels: ("Wait", "Waiting", "Waited", "for the preview page"), summaryAction: "browser", icon: "browser"),
        "preview_set_appearance": .init(labels: ("Set", "Setting", "Set", "preview browser appearance"), summaryAction: "browser", icon: "browser"),
        "preview_recording_start": .init(labels: ("Start", "Starting", "Started", "recording the preview browser"), summaryAction: "browser", icon: "browser"),
        "preview_recording_stop": .init(labels: ("Stop", "Stopping", "Stopped", "recording the preview browser"), summaryAction: "browser", icon: "browser"),
        "device_list": .init(labels: ("List", "Listing", "Listed", "simulators and emulators"), summaryAction: "device", icon: "device"),
        "device_open": .init(labels: ("Open", "Opening", "Opened", "a device in the Device panel"), summaryAction: "device", icon: "device"),
        "device_screenshot": .init(labels: ("Take a screenshot of", "Taking a screenshot of", "Took a screenshot of", "the device"), summaryAction: "device", icon: "device"),
        "device_close": .init(labels: ("Close", "Closing", "Closed", "a device"), summaryAction: "device", icon: "device"),
        "run_scheduled_task_now": .init(labels: ("Run", "Running", "Requested a run of", "a scheduled task"), summaryAction: "schedule-run", icon: "t3-code"),
        "t3_queue_list": .init(labels: ("List", "Listing", "Listed", "queued messages"), summaryAction: "queue-list", icon: "t3-code"),
        "t3_queue_read": .init(labels: ("Read", "Reading", "Read", "a queued message"), summaryAction: "queue-read", icon: "t3-code"),
        "t3_queue_edit": .init(labels: ("Edit", "Editing", "Edited", "a queued message"), summaryAction: "queue-edit", icon: "t3-code"),
        "t3_queue_cancel": .init(labels: ("Cancel", "Canceling", "Requested cancellation of", "a queued run"), summaryAction: "queue-cancel", icon: "t3-code"),
        "t3_queue_reorder": .init(labels: ("Reorder", "Reordering", "Reordered", "a queued run"), summaryAction: "queue-reorder", icon: "t3-code"),
        "t3_queue_promote_to_steer": .init(labels: ("Steer with", "Steering with", "Requested steering with", "a queued message"), summaryAction: "queue-steer", icon: "t3-code"),
        "t3_pending_request_list": .init(labels: ("List", "Listing", "Listed", "pending questions"), summaryAction: "question-list", icon: "t3-code"),
        "t3_pending_request_read": .init(labels: ("Read", "Reading", "Read", "pending questions"), summaryAction: "question-read", icon: "t3-code"),
        "t3_pending_request_respond": .init(labels: ("Answer", "Answering", "Answered", "pending questions"), summaryAction: "question-respond", icon: "t3-code"),
        "t3_thread_configuration": .init(labels: ("Read", "Reading", "Read", "thread configuration"), summaryAction: "thread-configuration", icon: "t3-code"),
        "t3_thread_configure": .init(labels: ("Set", "Setting", "Set", "thread model"), summaryAction: "thread-configure", icon: "t3-code"),
        "t3_thread_fork": .init(labels: ("Fork", "Forking", "Requested a fork of", "this thread"), summaryAction: "thread-fork", icon: "t3-code"),
        "t3_thread_merge_back": .init(labels: ("Merge", "Merging", "Requested a merge of", "thread context"), summaryAction: "thread-merge", icon: "t3-code"),
        "t3_thread_search": .init(labels: ("Search", "Searching", "Searched", "thread content"), summaryAction: "thread-search", icon: "t3-code"),
        "t3_thread_transfers": .init(labels: ("Read", "Reading", "Read", "thread transfers"), summaryAction: "thread-transfers", icon: "t3-code"),
        "t3_thread_organize": .init(labels: ("Organize", "Organizing", "Organized", "a thread"), summaryAction: "thread-organize", icon: "t3-code"),
        "t3_thread_update": .init(labels: ("Update", "Updating", "Updated", "T3 thread metadata"), summaryAction: "thread-update", icon: "t3-code"),
        "t3_worktree_list": .init(labels: ("List", "Listing", "Listed", "workspace branches"), summaryAction: "worktree-list", icon: "t3-code"),
        "t3_preview_list": .init(labels: ("List", "Listing", "Listed", "preview tabs"), summaryAction: "browser", icon: "browser"),
        "t3_preview_close": .init(labels: ("Close", "Closing", "Closed", "a preview tab"), summaryAction: "browser", icon: "browser"),
        "t3_environment_read": .init(labels: ("Read", "Reading", "Read", "environment preferences"), summaryAction: "environment-read", icon: "t3-code"),
        "t3_environment_preferences_update": .init(labels: ("Update", "Updating", "Updated", "environment preferences"), summaryAction: "environment-update", icon: "t3-code"),
        "t3_thread_launch": .init(labels: ("Launch", "Launching", "Launched", "a project thread"), summaryAction: "thread-create", icon: "t3-code"),
        "t3_project_list": .init(labels: ("List", "Listing", "Listed", "projects"), summaryAction: "project-list", icon: "t3-code"),
        "t3_project_read": .init(labels: ("Read", "Reading", "Read", "a project"), summaryAction: "project-read", icon: "t3-code"),
        "t3_project_create": .init(labels: ("Register", "Registering", "Registered", "a project"), summaryAction: "project-create", icon: "t3-code"),
        "t3_project_update": .init(labels: ("Update", "Updating", "Updated", "a project"), summaryAction: "project-update", icon: "t3-code"),
        "t3_project_delete": .init(labels: ("Delete", "Deleting", "Deleted", "a project"), summaryAction: "project-delete", icon: "t3-code"),
        "t3_project_clone": .init(labels: ("Clone", "Cloning", "Cloned", "a repository"), summaryAction: "project-clone", icon: "t3-code"),
        "t3_attachment_prepare_upload": .init(labels: ("Prepare", "Preparing", "Prepared", "an attachment upload"), summaryAction: "attachment-prepare", icon: "t3-code"),
        "t3_attachment_discard": .init(labels: ("Discard", "Discarding", "Discarded", "a pending attachment"), summaryAction: "attachment-discard", icon: "t3-code"),
        "t3_thread_send_attachments": .init(labels: ("Send", "Sending", "Sent", "attachments"), summaryAction: "attachment-send", icon: "t3-code"),
        "html_preview": .init(labels: ("Preview", "Previewing", "Previewed", "an HTML page"), summaryAction: "html-preview", icon: "t3-code"),
        "html_render": .init(labels: ("Render", "Rendering", "Rendered", "an HTML page"), summaryAction: "html-render", icon: "t3-code"),
    ]

    static let serverAliases: Set<String> = ["t3-code", "t3_code", "t3code"]

    /// Port of `resolveT3McpToolName` (t3McpToolPresentation.ts:337-369): the bare tool name for
    /// any provider's spelling (`mcp__t3-code__x`, `t3-code.x`, `t3_code:x`, OpenCode's
    /// `t3-code-<thread>_x`).
    static func toolName(_ value: String) -> String? {
        // A handful of labels repeat across thousands of rows; resolve each once.
        if let known = nameCache.object(forKey: value as NSString) { return known.name }
        let name = resolveToolName(value)
        nameCache.setObject(Resolved(name), forKey: value as NSString)
        return name
    }

    private final class Resolved {
        let name: String?
        init(_ name: String?) { self.name = name }
    }

    nonisolated(unsafe) private static let nameCache = NSCache<NSString, Resolved>()

    private static func resolveToolName(_ value: String) -> String? {
        let label = normalizeCompactToolLabel(value)
        if let match = label.wholeMatch(of: /mcp__(.+?)__(.+)/.ignoresCase()) {
            return serverAliases.contains(String(match.1).lowercased()) ? String(match.2) : nil
        }
        if let match = label.wholeMatch(of: /(?:t3-code|t3_code|t3code)(?:[.:\/]|\s*·\s*)(.+)/.ignoresCase()) {
            return String(match.1)
        }
        let prefixed = label.wholeMatch(of: /(?:mcp[-_]{1,2})?t3[-_ ]?code(?:__|[-_.:\/ ])(.+)/.ignoresCase())
        let candidate = prefixed.map { String($0.1) } ?? label
        if all[candidate] != nil { return candidate }
        guard label.lowercased().hasPrefix("t3-code-") else { return nil }
        var longest: String?
        for tool in all.keys where label.hasSuffix("_\(tool)") && tool.count > (longest?.count ?? 0) {
            longest = tool
        }
        return longest
    }

    /// Port of `resolveT3McpToolDefinition`.
    public static func definition(_ toolName: String?) -> T3McpToolDefinition? {
        guard let toolName, let name = Self.toolName(toolName) else { return nil }
        return all[name]
    }
}

// MARK: - T3 tool results (packages/client-runtime/src/t3ToolSummary.ts)

struct T3ToolResult {
    var data: [String: JSONValue]?
    var failed = false
}

/// Port of `readResult` (t3ToolSummary.ts:25-60): reads structured and JSON-text MCP result
/// envelopes.
func readT3ToolResult(_ value: JSONValue?, depth: Int = 0) -> T3ToolResult {
    guard depth <= 4, let value else { return T3ToolResult() }
    switch value {
    case .string(let text):
        guard let parsed = try? JSONValue(parsing: Data(text.utf8)) else { return T3ToolResult() }
        return readT3ToolResult(parsed, depth: depth + 1)
    case .array(let blocks):
        var result = T3ToolResult()
        for block in blocks {
            let text = block["text"] ?? block["content"]?["text"]
            let inner = readT3ToolResult(text?["text"] ?? text, depth: depth + 1)
            if result.data == nil { result.data = inner.data }
            result.failed = result.failed || inner.failed
        }
        return result
    case .object(let record):
        var failed = record["isError"] == .bool(true) || record["is_error"] == .bool(true)
            || (record["error"] != nil && record["error"] != .null)
        if let tag = record["_tag"]?.stringValue, tag.hasSuffix("Error") || tag.hasSuffix("Failure") { failed = true }
        if let content = record["structuredContent"] ?? record["content"] {
            let inner = readT3ToolResult(content, depth: depth + 1)
            return T3ToolResult(data: inner.data, failed: failed || inner.failed)
        }
        return T3ToolResult(data: record, failed: failed)
    default:
        return T3ToolResult()
    }
}

/// Port of `t3ToolResultIndicatesFailure`: MCP errors can come back as data on a completed call.
func t3ToolResultIndicatesFailure(_ output: JSONValue?) -> Bool { readT3ToolResult(output).failed }

struct T3ToolSummaryCall {
    var input: JSONValue?
    var output: JSONValue?
    /// `completed`, `failed` or `unfinished`.
    var outcome: String
}

/// Port of `summarizeT3ToolCalls` (t3ToolSummary.ts:84-412): the group label for calls of one
/// T3 summary action. Successful effects count separately from failed or unfinished calls.
func summarizeT3ToolCalls(_ action: String, _ calls: [T3ToolSummaryCall]) -> (label: String, failedCount: Int) {
    func nonEmptyID(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
    struct Call { var input: [String: JSONValue]?; var output: [String: JSONValue]?; var outcome: String }
    let results = calls.map { call -> Call in
        let result = readT3ToolResult(call.output)
        var input = readT3ToolResult(call.input).data
        // Cursor retains its MCP args envelope; other adapters retain the arguments directly.
        if let wrapped = input, wrapped["toolName"]?.stringValue != nil { input = wrapped["args"]?.objectValue }
        return Call(input: input, output: result.data, outcome: result.failed ? "failed" : call.outcome)
    }
    let completed = results.filter { $0.outcome == "completed" }
    let failedCount = results.filter { $0.outcome == "failed" }.count
    let selected = completed.isEmpty ? results : completed
    func quantity(_ count: Int, _ noun: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? noun : (plural ?? noun + "s"))"
    }
    let times = quantity(selected.count, "time")
    func phrase(_ past: String, _ infinitive: String, _ object: String) -> String {
        "\(completed.isEmpty ? "Tried to \(infinitive)" : past) \(object)"
    }
    func countEntities(_ ids: [String?]) -> Int {
        Set(ids.compactMap { $0 }).count + ids.filter { $0 == nil }.count
    }
    func entityIds(_ key: String) -> [String?] {
        selected.map { nonEmptyID($0.output?[key]) ?? nonEmptyID($0.input?[key]) }
    }
    let projectIds = selected.map {
        nonEmptyID($0.output?["id"]) ?? nonEmptyID($0.output?["projectId"]) ?? nonEmptyID($0.input?["projectId"])
    }
    let threadIds = selected.map {
        nonEmptyID($0.output?["threadId"]) ?? nonEmptyID($0.output?["thread"]?["threadId"]) ?? nonEmptyID($0.input?["threadId"])
    }
    let threadTargetsKnown = threadIds.allSatisfy { $0 != nil }
    let threadCount = Set(threadIds.compactMap { $0 }).count
    let label: String
    switch action {
    case "thread-send":
        let messages = countEntities(selected.map { nonEmptyID($0.output?["messageId"]) })
        let object = threadTargetsKnown
            ? (messages == threadCount && messages > 1
                ? "messages to \(quantity(threadCount, "thread"))"
                : "\(quantity(messages, "message")) to \(quantity(threadCount, "thread"))")
            : quantity(messages, "message")
        label = phrase("Sent", "send", object)
    case "thread-create":
        var createdIds = Set<String>()
        let resultsKnown = !completed.isEmpty && completed.allSatisfy { call in
            let threads: [JSONValue?] = call.output?["threads"]?.arrayValue.map { $0.map { Optional($0) } }
                ?? [call.output.map { JSONValue.object($0) }]
            return threads.allSatisfy { thread in
                if thread?["status"]?.stringValue == "rolled_back" { return true }
                guard let id = nonEmptyID(thread?["threadId"]) else { return false }
                createdIds.insert(id)
                return true
            }
        }
        label = resultsKnown ? "Created \(quantity(createdIds.count, "thread"))" : "Requested thread creation \(times)"
    case "delegate": label = phrase("Delegated", "delegate", quantity(countEntities(entityIds("taskId")), "task"))
    case "thread-read", "thread-wait":
        let targets = threadTargetsKnown ? quantity(threadCount, "thread") : "threads \(times)"
        label = action == "thread-read" ? phrase("Read", "read", targets) : phrase("Waited on", "wait on", targets)
    case "thread-list": label = phrase("Listed", "list", "threads \(times)")
    case "thread-interrupt": label = phrase("Requested interrupts for", "interrupt", quantity(countEntities(threadIds), "thread"))
    case "task-status": label = phrase("Checked", "check", "task status \(times)")
    case "task-cancel": label = phrase("Requested cancellation of", "cancel", quantity(countEntities(entityIds("taskId")), "task"))
    case "schedule-create": label = phrase("Scheduled", "schedule", quantity(countEntities(entityIds("scheduledTaskId")), "task"))
    case "schedule-list": label = phrase("Listed", "list", "scheduled tasks \(times)")
    case "schedule-update": label = phrase("Updated", "update", quantity(countEntities(entityIds("scheduledTaskId")), "scheduled task"))
    case "schedule-delete": label = phrase("Requested deletion of", "delete", quantity(countEntities(entityIds("scheduledTaskId")), "scheduled task"))
    case "schedule-run": label = phrase("Requested", "request", quantity(selected.count, "scheduled task run"))
    case "thread-configuration": label = phrase("Checked", "check", "thread configuration \(times)")
    case "thread-configure": label = phrase("Set", "set", "thread model \(times)")
    case "thread-fork": label = phrase("Requested", "request", quantity(selected.count, "thread fork"))
    case "thread-merge": label = phrase("Requested", "request", quantity(selected.count, "context merge"))
    case "thread-search": label = phrase("Searched", "search", "threads \(times)")
    case "thread-transfers": label = phrase("Checked", "check", "thread transfers \(times)")
    case "thread-organize": label = phrase("Organized", "organize", "threads \(times)")
    case "thread-update": label = phrase("Updated", "update", quantity(countEntities(threadIds), "thread"))
    case "queue-list": label = phrase("Listed", "list", "queued messages \(times)")
    case "queue-read": label = phrase("Read", "read", quantity(countEntities(entityIds("queuedRunId")), "queued message"))
    case "queue-edit": label = phrase("Edited", "edit", quantity(countEntities(entityIds("queuedRunId")), "queued message"))
    case "queue-cancel": label = phrase("Requested cancellation of", "cancel", quantity(countEntities(entityIds("queuedRunId")), "queued run"))
    case "queue-reorder": label = phrase("Reordered", "reorder", quantity(countEntities(entityIds("queuedRunId")), "queued run"))
    case "queue-steer": label = phrase("Requested steering with", "steer with", quantity(countEntities(entityIds("queuedRunId")), "queued message"))
    case "question-list": label = phrase("Listed", "list", "pending questions \(times)")
    case "question-read": label = phrase("Read", "read", quantity(countEntities(entityIds("requestId")), "pending question request"))
    case "question-respond": label = phrase("Answered", "answer", quantity(countEntities(entityIds("requestId")), "pending question request"))
    case "secret-request": label = phrase("Asked for", "ask for", quantity(selected.count, "secret"))
    case "worktree-handoff": label = phrase("Handed off to", "hand off to", quantity(countEntities(entityIds("worktreePath")), "worktree"))
    case "worktree-list": label = phrase("Listed", "list", "workspace branches \(times)")
    case "worktree-status": label = phrase("Checked", "check", "worktree status \(times)")
    case "project-list": label = phrase("Listed", "list", "projects \(times)")
    case "project-read": label = phrase("Read", "read", quantity(countEntities(projectIds), "project"))
    case "project-create": label = phrase("Registered", "register", quantity(countEntities(projectIds), "project"))
    case "project-update": label = phrase("Updated", "update", quantity(countEntities(projectIds), "project"))
    case "project-delete": label = phrase("Deleted", "delete", quantity(countEntities(projectIds), "project"))
    case "project-clone": label = phrase("Cloned", "clone", quantity(countEntities(entityIds("cwd")), "repository", "repositories"))
    case "environment-read": label = phrase("Checked", "check", "environment preferences \(times)")
    case "environment-update": label = phrase("Updated", "update", "environment preferences \(times)")
    case "attachment-prepare": label = phrase("Prepared", "prepare", quantity(countEntities(entityIds("attachmentId")), "attachment upload"))
    case "attachment-discard": label = phrase("Discarded", "discard", quantity(countEntities(entityIds("attachmentId")), "pending attachment"))
    case "attachment-send":
        // A message can carry several attachments. Count retries by message identity.
        var messageOrder: [String] = []
        var messages: [String: Call] = [:]
        for (index, call) in selected.enumerated() {
            let key = nonEmptyID(call.output?["messageId"]) ?? "call-\(index)"
            if messages[key] == nil { messageOrder.append(key) }
            messages[key] = call
        }
        let calls = messageOrder.compactMap { messages[$0] }
        let attachmentCount = calls.reduce(0) { $0 + ($1.input?["attachments"]?.arrayValue?.count ?? 0) }
        let countsKnown = calls.allSatisfy { ($0.input?["attachments"]?.arrayValue?.count ?? 0) > 0 }
        let targets = threadTargetsKnown ? " to \(quantity(threadCount, "thread"))" : ""
        label = phrase("Sent", "send", countsKnown ? "\(quantity(attachmentCount, "attachment"))\(targets)" : "attachments\(targets) \(times)")
    case "link-pr": label = phrase("Linked", "link", quantity(selected.count, "pull request"))
    case "unlink-pr": label = phrase("Unlinked", "unlink", quantity(selected.count, "pull request"))
    case "watch-pr": label = phrase("Watching", "watch", quantity(selected.count, "pull request"))
    case "unwatch-pr": label = phrase("Stopped watching", "stop watching", quantity(selected.count, "pull request"))
    case "list-prs": label = phrase("Checked", "check", "linked pull requests\(selected.count == 1 ? "" : " \(times)")")
    case "browser": label = phrase("Used", "use", "browser \(times)")
    case "device": label = phrase("Used", "use", "device controls \(times)")
    case "html-preview": label = phrase("Previewed", "preview", quantity(selected.count, "HTML page"))
    case "html-render": label = phrase("Rendered", "render", quantity(selected.count, "HTML page"))
    case "capabilities": label = phrase("Checked", "check", "orchestration capabilities \(times)")
    default: label = phrase("Used", "use", "T3 tools \(times)")
    }
    return (label, failedCount)
}
