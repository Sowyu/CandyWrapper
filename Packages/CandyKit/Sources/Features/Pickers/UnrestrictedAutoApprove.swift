import Foundation
import T3Protocol
import T3Store

/// CandyWrapper-only (docs/decisions.md, 2026-11-26): with Unrestricted on, CandyWrapper answers the safety checks Claude
/// Code still raises in bypass mode, so an agent nobody watches doesn't wait for a person. It approves one request at a
/// time and never picks a standing "always allow" option.
///
/// Which requests can carry `fullAccessOverride: "provider_check"`: T3 sets it only in the Claude adapter's tool
/// callback, for any ask in bypass mode that no ask rule matched (`claudeApprovalPresentation`, ClaudeAdapterV2.ts:4739-4770
/// at 5258 and :4353-4384 at 4928). The callback maps the tool to a kind (`classifyClaudeNativeTool`, :3997-4033 at 5258):
/// Bash, Agent, Monitor and tools T3 doesn't know (MCP tools among them) are `command`, Read, Glob, Grep and LS are
/// `file-read`, Edit, Write, MultiEdit and NotebookEdit are `file-change`. MCP elicitations, questions, push hooks and
/// other providers' approvals never carry it. This answers only `command`: file reads and changes that bypass still
/// stops on keep asking. Both servers deny some Bash removals themselves before any client sees them: 4928 those whose
/// reason starts "Dangerous rm" (:12497), 5258 also any reason naming a "dangerous removal" (:13101-13118), which
/// covers the "can't rule out a dangerous removal" check on commands Claude Code can't parse. So on 5258 fewer of these
/// reach CandyWrapper at all.
public enum UnrestrictedAutoApprove {
    public static let providerCheck = "provider_check"
    /// After the approval's line in the timeline.
    public static let timelineNote = "Approved by CandyWrapper for Unrestricted"
    public static let toastTitle = "CandyWrapper approved a safety check"
    public static func toastMessage(thread: String) -> String {
        "Unrestricted is on, so CandyWrapper approved Claude Code's check on a command in \u{201C}\(thread)\u{201D}. Until you quit, later approvals show only in their threads."
    }
    static let claudeDriver = "claudeAgent"

    /// Everything the rule reads, gathered from the thread's own environment.
    public struct Facts: Sendable {
        /// The shell's pending request for the thread.
        public var shellRequestId: String?
        public var shellRequestKind: RuntimeRequestKind?
        public var shellRuntimeMode: String
        public var shellInstanceId: String
        /// The fetched projection's thread, which must be the same thread on the same instance.
        public var projectionThreadId: String?
        public var projectionInstanceId: String?
        public var projectionRuntimeMode: String?
        /// The pending approval the projection derives for `shellRequestId`.
        public var approval: PendingApproval?
        /// `runtimeRequests[].nativeRequestRef.driver` for that request.
        public var requestDriver: String?
        /// The `requestKind` of the request's last approval item, which must agree with the request's own kind.
        public var itemRequestKind: String?
        public var shellThreadId: String
        /// The thread environment's `server.getSettings`, read just before answering.
        public var settings: JSONValue?
        /// The user confirmed the current Unrestricted dialog for this environment and instance.
        public var confirmed: Bool

        public init(shellThreadId: String, shellRequestId: String?, shellRequestKind: RuntimeRequestKind?, shellRuntimeMode: String,
                    shellInstanceId: String, projectionThreadId: String?, projectionInstanceId: String?, projectionRuntimeMode: String?,
                    approval: PendingApproval?, requestDriver: String?, settings: JSONValue?, confirmed: Bool) {
            self.shellThreadId = shellThreadId; self.shellRequestId = shellRequestId; self.shellRequestKind = shellRequestKind
            self.shellRuntimeMode = shellRuntimeMode; self.shellInstanceId = shellInstanceId
            self.projectionThreadId = projectionThreadId; self.projectionInstanceId = projectionInstanceId
            self.projectionRuntimeMode = projectionRuntimeMode; self.approval = approval; self.requestDriver = requestDriver
            self.settings = settings; self.confirmed = confirmed
        }
    }

    /// The rule. Every condition must hold; anything missing or unexpected answers no.
    public static func shouldApprove(_ f: Facts) -> Bool {
        guard f.confirmed,
              f.shellRuntimeMode == "full-access", f.projectionRuntimeMode == "full-access",
              f.projectionThreadId == f.shellThreadId,
              f.projectionInstanceId == f.shellInstanceId,
              f.requestDriver == claudeDriver,
              f.shellRequestKind == .command, f.itemRequestKind == RuntimeRequestKind.command.rawValue,
              let settings = f.settings, settingsAllow(settings, instanceId: f.shellInstanceId),
              let approval = f.approval, approval.requestId == f.shellRequestId else { return false }
        return approvalQualifies(approval)
    }

    /// The approval itself: a live Claude command check, not the user's own ask rule, with a one-time Approve to press.
    public static func approvalQualifies(_ a: PendingApproval) -> Bool {
        a.fullAccessOverride == providerCheck && a.canRespond && a.requestKind == .command
            && a.pushHooks == nil && a.appName == nil && a.effectiveOptions.contains { $0.decision == .accept }
    }

    /// The instance is configured as a Claude instance and its environment sets the variable to a value Claude Code
    /// reads as true. Unlike `UnrestrictedAccess.isOn`, a value the server hides doesn't count: it may say `0`.
    public static func settingsAllow(_ settings: JSONValue, instanceId: String) -> Bool {
        guard let instance = settings["providerInstances"]?[instanceId], instance.objectValue != nil,
              instance["driver"]?.stringValue == claudeDriver else { return false }
        return ProviderEnvironmentLogic.variables(instance).contains { v in
            v.name == UnrestrictedAccess.variable && v.valueRedacted != true
                && ["1", "true", "yes", "on"].contains(v.value.lowercased().trimmingCharacters(in: .whitespaces))
        }
    }

    /// Facts from the shell, the fetched projection (decoded and raw) and the fetched settings.
    public static func facts(shell: ThreadShell, projection: ThreadProjection?, projectionJSON: JSONValue?, settings: JSONValue?,
                             confirmed: Bool) -> Facts {
        let requestId = shell.pendingRuntimeRequest?.id.rawValue
        let approval = projection.flatMap { p in PendingRequests.derive(p).approvals.first { $0.requestId == requestId } }
        let raw = projectionJSON?["runtimeRequests"]?.arrayValue?.first { $0["id"]?.stringValue == requestId }
        let item = projection?.turnItems.last { $0.type == .approvalRequest && $0.requestId == requestId }
        var facts = Facts(shellThreadId: shell.id.rawValue, shellRequestId: requestId, shellRequestKind: shell.pendingRuntimeRequest?.kind,
                     shellRuntimeMode: shell.runtimeMode, shellInstanceId: shell.providerInstanceId.rawValue,
                     projectionThreadId: projection?.thread.id.rawValue, projectionInstanceId: projection?.thread.providerInstanceId?.rawValue,
                     projectionRuntimeMode: projection?.thread.raw["runtimeMode"]?.stringValue,
                     approval: approval, requestDriver: raw?["nativeRequestRef"]?["driver"]?.stringValue,
                     settings: settings, confirmed: confirmed)
        facts.itemRequestKind = item?.string("requestKind")
        return facts
    }

    /// Whether the shell row is worth a look: a pending command request in Full access. Cheap, no fetches.
    static func candidate(_ shell: ThreadShell) -> Bool {
        shell.pendingRuntimeRequest?.kind == .command && shell.runtimeMode == "full-access"
    }

    /// A dispatch refusal that means the request is no longer pending, so someone or something else settled it
    /// (`Runtime request <id> is <status>.`, Orchestrator.ts:11603-11608 at 5258).
    public static func isAlreadySettled(tag: String?, cause: String?) -> Bool {
        guard tag == "OrchestratorDispatchError", let cause else { return false }
        return cause.wholeMatch(of: /Runtime request .+ is (resolved|cancelled|expired)\./) != nil
    }

    public enum Outcome: Equatable, Sendable {
        case answered
        /// Another client, window or the server settled it first.
        case alreadySettled
        case failed(String)
    }
}

/// The requests CandyWrapper approved for Unrestricted, so the timeline can say so after a restart.
// ponytail: the newest 500 in UserDefaults, a few KB; move into the thread cache if rows ever need more
public final class UnrestrictedApprovalRecord: @unchecked Sendable {
    public static let shared = UnrestrictedApprovalRecord()
    static let key = "unrestrictedAutoApproved"
    static let limit = 500
    private let defaults: UserDefaults
    private var keys: [String]
    private var lookup: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.key) ?? []
        lookup = Set(keys)
    }

    static func entry(_ environmentId: String, _ threadId: String, _ requestId: String) -> String {
        "\(environmentId)\n\(threadId)\n\(requestId)"
    }

    public func contains(environmentId: String, threadId: String, requestId: String) -> Bool {
        lookup.contains(Self.entry(environmentId, threadId, requestId))
    }

    func add(environmentId: String, threadId: String, requestId: String) {
        let e = Self.entry(environmentId, threadId, requestId)
        guard lookup.insert(e).inserted else { return }
        keys.append(e)
        if keys.count > Self.limit {
            keys.removeFirst(keys.count - Self.limit)
            lookup = Set(keys)
        }
        defaults.set(keys, forKey: Self.key)
    }
}

/// Watches every connected environment's live shell and answers qualifying approvals, driven only by shell updates.
/// A thread waiting on a command request in Full access on an instance confirmed for Unrestricted gets its projection
/// read once, then the server's settings, then one Approve. Nothing runs between shell updates.
@MainActor
public final class UnrestrictedAutoApprover {
    /// The environment's settings as the client last heard them; only skips work, never decides.
    public var cachedSettings: (String) -> JSONValue? = { _ in nil }
    /// `server.getSettings` on the environment.
    public var fetchSettings: (String) async throws -> JSONValue = { _ in throw CancellationError() }
    /// `orchestration.getThreadProjection` on the environment, by local thread id.
    public var fetchProjection: (String, ThreadId) async throws -> JSONValue = { _, _ in throw CancellationError() }
    /// `orchestration.dispatchCommand` on the environment.
    public var respond: (String, JSONValue) async -> UnrestrictedAutoApprove.Outcome = { _, _ in .failed("not connected") }
    public var confirmed: (String, String) -> Bool = { env, instance in !UnrestrictedAccess.needsConfirm(environment: env, instance: instance) }
    /// CandyWrapper approved this request (environment, the thread's shell, request id).
    public var onAnswered: (String, ThreadShell, String) -> Void = { _, _, _ in }
    public var record = UnrestrictedApprovalRecord.shared

    /// Requests looked at for good: each is answered at most once and never retried.
    private var settled: Set<String> = []
    private var inFlight: Set<String> = []
    /// Reads that found the request but not its approval item yet; one more read on the next shell update.
    private var itemMissing: Set<String> = []
    /// Per environment, the candidate requests in its latest live shell.
    private var current: [String: Set<String>] = [:]

    public init() {}

    static func key(_ env: String, _ thread: ThreadShell) -> String? {
        thread.pendingRuntimeRequest.map { "\(env)\n\(thread.id.rawValue)\n\($0.id.rawValue)" }
    }

    /// An environment's live shell, or nil when it left or reconnects. Returns the reads it started, for tests.
    @discardableResult
    public func shellChanged(_ environmentId: String, _ snapshot: ShellSnapshot?) -> [Task<Void, Never>] {
        guard let snapshot else { current[environmentId] = nil; return [] }
        let candidates = snapshot.threads.filter(UnrestrictedAutoApprove.candidate)
        current[environmentId] = Set(candidates.compactMap { Self.key(environmentId, $0) })
        var started: [Task<Void, Never>] = []
        for thread in candidates {
            guard let key = Self.key(environmentId, thread), !settled.contains(key), !inFlight.contains(key) else { continue }
            let instance = thread.providerInstanceId.rawValue
            guard confirmed(environmentId, instance), let cached = cachedSettings(environmentId),
                  UnrestrictedAutoApprove.settingsAllow(cached, instanceId: instance) else { continue }
            inFlight.insert(key)
            started.append(Task { await self.attempt(environmentId, thread, key: key) })
        }
        return started
    }

    private func attempt(_ env: String, _ thread: ThreadShell, key: String) async {
        defer { inFlight.remove(key) }
        guard let requestId = thread.pendingRuntimeRequest?.id.rawValue else { return }
        let json: JSONValue, projection: ThreadProjection
        do {
            json = try await fetchProjection(env, thread.id)
            projection = try json.decode(as: ThreadProjection.self)
        } catch { settled.insert(key); return }
        let hasItem = projection.turnItems.contains { $0.type == .approvalRequest && $0.requestId == requestId }
        if !hasItem, itemMissing.insert(key).inserted { return }
        // Read last, right before answering, so a switch turned off meanwhile wins.
        let settings = try? await fetchSettings(env)
        let facts = UnrestrictedAutoApprove.facts(shell: thread, projection: projection, projectionJSON: json, settings: settings,
                                                 confirmed: confirmed(env, thread.providerInstanceId.rawValue))
        settled.insert(key)
        // The latest shell must still show this request pending, else it was settled or the thread changed.
        guard current[env]?.contains(key) == true, UnrestrictedAutoApprove.shouldApprove(facts) else { return }
        let payload = RuntimeRequestCommands.respond(threadId: thread.id, requestId: requestId, decision: .accept)
        guard await respond(env, payload) == .answered else { return }
        record.add(environmentId: env, threadId: thread.id.rawValue, requestId: requestId)
        onAnswered(env, thread, requestId)
    }
}
