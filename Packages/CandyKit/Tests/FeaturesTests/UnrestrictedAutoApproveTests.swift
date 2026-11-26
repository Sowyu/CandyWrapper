import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// CandyWrapper approving Claude Code's safety checks under Unrestricted (docs/decisions.md, 2026-11-26). The rule
/// answers no to anything it doesn't recognize, so most cases here are ones it must leave for the user.
@MainActor @Suite
struct UnrestrictedAutoApproveTests {
    typealias Rule = UnrestrictedAutoApprove

    static func settings(on: Bool = true, driver: String = "claudeAgent", redacted: Bool = false, instance: String = "claudeAgent") -> JSONValue {
        var variable: [String: JSONValue] = ["name": .string(UnrestrictedAccess.variable), "value": .string(on ? "1" : "0"), "sensitive": .bool(redacted)]
        if redacted { variable["value"] = .string(""); variable["valueRedacted"] = .bool(true) }
        return .object(["providerInstances": .object([instance: .object(["driver": .string(driver), "environment": .array([.object(variable)])])])])
    }

    static func shell(_ id: String = "t", request: String? = "r1", kind: String = "command", mode: String = "full-access",
                      instance: String = "claudeAgent", parent: String? = nil) -> ThreadShell {
        let pending = request.map { #"{"id":"\#($0)","kind":"\#(kind)","createdAt":"2026-11-26T00:00:00.000Z"}"# } ?? "null"
        let json = """
            {"id":"\(id)","projectId":"p","title":"Child \(id)","providerInstanceId":"\(instance)",
             "modelSelection":{"instanceId":"\(instance)","model":"claude-haiku-5-5"},"runtimeMode":"\(mode)",
             "interactionMode":"default","branch":null,"worktreePath":null,"activeProviderThreadId":null,
             "lineage":{"rootThreadId":"\(parent ?? id)","parentThreadId":\(parent.map { "\"\($0)\"" } ?? "null"),
                        "relationshipToParent":\(parent == nil ? "null" : "\"subagent\"")},
             "forkedFrom":null,"createdBy":"agent","creationSource":"web","activeRunId":"run","status":"running",
             "pendingRuntimeRequest":\(pending),"latestVisibleMessage":null,"latestUserMessageAt":null,
             "hasActionableProposedPlan":false,"itemCount":3,"visibleItemCount":3,
             "createdAt":"2026-11-26T00:00:00.000Z","updatedAt":"2026-11-26T00:00:00.000Z","archivedAt":null,
             "settledOverride":null,"settledAt":null,"lastVisitedAt":null,"deletedAt":null}
            """
        return try! JSONDecoder().decode(ThreadShell.self, from: Data(json.utf8))
    }

    /// A projection with one pending request and its approval item. `item` nil leaves the item out.
    static func projectionJSON(thread: String = "t", request: String = "r1", kind: String = "command", mode: String = "full-access",
                               instance: String = "claudeAgent", driver: JSONValue = .string("claudeAgent"), capability: String = "live",
                               item: [String: JSONValue]? = ["fullAccessOverride": .string("provider_check")]) -> JSONValue {
        var requestJSON: [String: JSONValue] = ["id": .string(request), "nodeId": .string("n"), "kind": .string(kind), "status": .string("pending"),
                                                "createdAt": .string("2026-11-26T00:00:00.000Z"), "responseCapability": .object(["type": .string(capability)])]
        requestJSON["nativeRequestRef"] = .object(["driver": driver, "nativeId": .string("native"), "strength": .string("strong")])
        var items: [JSONValue] = []
        if let item {
            var fields: [String: JSONValue] = ["id": .string("i-\(request)"), "threadId": .string(thread), "type": .string("approval_request"),
                                               "requestId": .string(request), "requestKind": .string(kind), "status": .string("waiting"),
                                               "prompt": .string("python3 - <<'EOF'\nprint(\"\"\"it's\"\"\")\nEOF"), "ordinal": .number(1),
                                               "createdAt": .string("2026-11-26T00:00:00.000Z"), "updatedAt": .string("2026-11-26T00:00:00.000Z")]
            fields.merge(item) { _, new in new }
            items.append(.object(fields))
        }
        return .object(["thread": .object(["id": .string(thread), "title": .string("T"), "providerInstanceId": .string(instance),
                                           "runtimeMode": .string(mode)]),
                        "runs": .array([]), "runtimeRequests": .array([.object(requestJSON)]), "turnItems": .array(items),
                        "updatedAt": .string("2026-11-26T00:00:00.000Z")])
    }

    static func facts(shell: ThreadShell = shell(), json: JSONValue = projectionJSON(), settings: JSONValue? = settings(),
                      confirmed: Bool = true) throws -> Rule.Facts {
        Rule.facts(shell: shell, projection: try json.decode(as: ThreadProjection.self), projectionJSON: json, settings: settings, confirmed: confirmed)
    }

    // MARK: The rule

    @Test func approvesAProviderCheckOnACommandInAConfirmedUnrestrictedClaudeThread() throws {
        #expect(Rule.shouldApprove(try Self.facts()))
    }

    @Test func neverForTheUsersOwnAskRuleOrAMissingOrOddOverride() throws {
        for override: JSONValue? in [.string("ask_rule"), nil, .string("Provider_check"), .string(" provider_check"), .number(1),
                                     .object(["provider_check": .bool(true)]), .array([.string("provider_check")]), .null] {
            var item: [String: JSONValue] = [:]
            if let override { item["fullAccessOverride"] = override }
            #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(item: item))), "override \(String(describing: override))")
        }
    }

    @Test func neverForOtherRequestKinds() throws {
        for kind in ["file-change", "file-read", "mcp-elicitation", "permission", "user_input", "dynamic_tool_call", "auth_refresh"] {
            #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(kind: kind), json: Self.projectionJSON(kind: kind))), "kind \(kind)")
        }
        // The shell and the projection disagree on the kind.
        #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(kind: "file-change"))))
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(kind: "file-change"))))
        // The approval item names another kind than its request.
        for kind: JSONValue in [.string("file-change"), .null, .number(0)] {
            let item: [String: JSONValue] = ["fullAccessOverride": .string("provider_check"), "requestKind": kind]
            #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(item: item))), "item kind \(kind)")
        }
    }

    @Test func neverForPushHooksAnAppOrWithoutAPlainApprove() throws {
        let hooks: JSONValue = .object(["branch": .string("main"), "files": .array([]), "commands": .array([])])
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(item: ["fullAccessOverride": .string("provider_check"), "pushHooks": hooks]))))
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(item: ["fullAccessOverride": .string("provider_check"), "appName": .string("Figma")]))))
        let standing: JSONValue = .array([.object(["decision": .string("acceptAlways"), "label": .string("Always")]),
                                          .object(["decision": .string("decline"), "label": .string("Decline")])])
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(item: ["fullAccessOverride": .string("provider_check"), "options": standing]))))
        // Claude's own two-button list still has Approve.
        let twoButtons: JSONValue = .array([.object(["decision": .string("decline"), "label": .string("Decline")]),
                                            .object(["decision": .string("accept"), "label": .string("Approve")])])
        #expect(Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(item: ["fullAccessOverride": .string("provider_check"), "options": twoButtons]))))
    }

    @Test func neverWhenItCantBeAnswered() throws {
        for capability in ["message", "not_resumable"] {
            #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(capability: capability))))
        }
    }

    @Test func neverForAnotherProviderOrAMismatchedThread() throws {
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(driver: .string("codex")))))
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(driver: .null))))
        #expect(!Rule.shouldApprove(try Self.facts(settings: Self.settings(driver: "codex"))))
        // The thread's instance is not the one whose settings say on.
        #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(instance: "claudeWork"), json: Self.projectionJSON(instance: "claudeWork"))))
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(instance: "claudeWork"))))
        #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(thread: "other"))))
        // The shell's pending request is another one.
        #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(request: "r2"))))
        #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(request: nil))))
    }

    @Test func neverOutsideFullAccess() throws {
        for mode in ["approval-required", "auto-accept-edits", "auto"] {
            #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(mode: mode), json: Self.projectionJSON(mode: mode))))
            #expect(!Rule.shouldApprove(try Self.facts(json: Self.projectionJSON(mode: mode))))
            #expect(!Rule.shouldApprove(try Self.facts(shell: Self.shell(mode: mode))))
        }
    }

    @Test func neverWhenUnrestrictedIsOffHiddenMissingOrUnconfirmed() throws {
        #expect(!Rule.shouldApprove(try Self.facts(settings: Self.settings(on: false))))
        #expect(!Rule.shouldApprove(try Self.facts(settings: Self.settings(redacted: true))))
        #expect(!Rule.shouldApprove(try Self.facts(settings: nil)))
        #expect(!Rule.shouldApprove(try Self.facts(settings: .object([:]))))
        // On for another instance only, or the default slot that was never configured.
        #expect(!Rule.shouldApprove(try Self.facts(settings: Self.settings(instance: "claudeWork"))))
        #expect(!Rule.shouldApprove(try Self.facts(settings: .object(["providerInstances": .object(["claudeAgent": .string("claudeAgent")])]))))
        #expect(!Rule.shouldApprove(try Self.facts(confirmed: false)))
    }

    @Test func settledRefusalsAreRecognizedAndNothingElse() {
        #expect(Rule.isAlreadySettled(tag: "OrchestratorDispatchError", cause: "Runtime request r1 is resolved."))
        #expect(Rule.isAlreadySettled(tag: "OrchestratorDispatchError", cause: "Runtime request r1 is cancelled."))
        #expect(!Rule.isAlreadySettled(tag: "OrchestratorDispatchError", cause: "Provider session s was not found."))
        #expect(!Rule.isAlreadySettled(tag: "Other", cause: "Runtime request r1 is resolved."))
        #expect(!Rule.isAlreadySettled(tag: nil, cause: nil))
    }

    @Test func theConfirmKeyChangedSoEarlierConfirmationsAskAgain() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnrestrictedAutoApproveConfirm"))
        defaults.removePersistentDomain(forName: "UnrestrictedAutoApproveConfirm")
        defaults.set(["e|claudeAgent"], forKey: "unrestrictedAccessConfirmed")
        #expect(UnrestrictedAccess.needsConfirm(environment: "e", instance: "claudeAgent", defaults: defaults))
        UnrestrictedAccess.markConfirmed(environment: "e", instance: "claudeAgent", defaults: defaults)
        #expect(!UnrestrictedAccess.needsConfirm(environment: "e", instance: "claudeAgent", defaults: defaults))
    }

    @Test func theRecordKeepsTheNewest() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnrestrictedAutoApproveRecord"))
        defaults.removePersistentDomain(forName: "UnrestrictedAutoApproveRecord")
        let record = UnrestrictedApprovalRecord(defaults: defaults)
        for i in 0...UnrestrictedApprovalRecord.limit { record.add(environmentId: "e", threadId: "t", requestId: "r\(i)") }
        #expect(!record.contains(environmentId: "e", threadId: "t", requestId: "r0"))
        #expect(record.contains(environmentId: "e", threadId: "t", requestId: "r\(UnrestrictedApprovalRecord.limit)"))
        #expect(!record.contains(environmentId: "other", threadId: "t", requestId: "r1"))
        #expect(UnrestrictedApprovalRecord(defaults: defaults).contains(environmentId: "e", threadId: "t", requestId: "r1"))
    }

    // MARK: The wiring, with a fake transport

    final class Fake {
        var settings: [String: JSONValue] = [:]
        var cached: [String: JSONValue] = [:]
        var projections: [String: JSONValue] = [:]
        var outcome: Rule.Outcome = .answered
        var confirmed = true
        var responses: [(env: String, payload: JSONValue)] = []
        var settingsReads: [String] = []
        var projectionReads: [String] = []
        var answered: [String] = []
        /// Runs between the projection read and the settings read.
        var beforeSettings: (() -> Void)?
    }

    static func approver(_ fake: Fake, defaults: String = #function) -> UnrestrictedAutoApprover {
        let suite = "UnrestrictedAutoApprove.\(defaults)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let a = UnrestrictedAutoApprover()
        a.record = UnrestrictedApprovalRecord(defaults: store)
        a.cachedSettings = { fake.cached[$0] ?? fake.settings[$0] }
        a.fetchSettings = { env in
            fake.beforeSettings?()
            fake.settingsReads.append(env)
            guard let s = fake.settings[env] else { throw CancellationError() }
            return s
        }
        a.fetchProjection = { env, thread in
            fake.projectionReads.append("\(env)/\(thread.rawValue)")
            guard let p = fake.projections["\(env)/\(thread.rawValue)"] else { throw CancellationError() }
            return p
        }
        a.respond = { env, payload in fake.responses.append((env, payload)); return fake.outcome }
        a.confirmed = { _, _ in fake.confirmed }
        a.onAnswered = { env, thread, request in fake.answered.append("\(env)/\(thread.id.rawValue)/\(request)") }
        return a
    }

    static func snapshot(_ threads: [ThreadShell]) -> ShellSnapshot {
        ShellSnapshot(schemaVersion: 1, snapshotSequence: 0, threads: threads, projects: [])
    }

    static func run(_ a: UnrestrictedAutoApprover, _ env: String, _ threads: [ThreadShell]) async {
        for task in a.shellChanged(env, snapshot(threads)) { await task.value }
    }

    @Test func answersAChildThreadNobodyOpenedOnceWithAOneTimeApprove() async throws {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/child"] = Self.projectionJSON(thread: "child")
        let a = Self.approver(fake)
        let child = Self.shell("child", parent: "parent")
        await Self.run(a, "e", [Self.shell("parent", request: nil), child])
        await Self.run(a, "e", [Self.shell("parent", request: nil), child])
        #expect(fake.responses.count == 1)
        let payload = try #require(fake.responses.first)
        #expect(payload.env == "e")
        #expect(payload.payload["type"] == .string("runtime-request.respond") && payload.payload["decision"] == .string("accept"))
        #expect(payload.payload["threadId"] == .string("child") && payload.payload["requestId"] == .string("r1"))
        #expect(fake.answered == ["e/child/r1"])
        #expect(a.record.contains(environmentId: "e", threadId: "child", requestId: "r1"))
        #expect(fake.projectionReads == ["e/child"])
    }

    @Test func alreadySettledCountsAsDoneAndIsNotMarkedAsOurs() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/t"] = Self.projectionJSON()
        fake.outcome = .alreadySettled
        let a = Self.approver(fake)
        await Self.run(a, "e", [Self.shell()])
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.responses.count == 1 && fake.answered.isEmpty)
        #expect(!a.record.contains(environmentId: "e", threadId: "t", requestId: "r1"))
    }

    @Test func aFailureLeavesItPendingAndNeverRetries() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/t"] = Self.projectionJSON()
        fake.outcome = .failed("socket closed")
        let a = Self.approver(fake)
        for _ in 0..<3 { await Self.run(a, "e", [Self.shell()]) }
        #expect(fake.responses.count == 1 && fake.answered.isEmpty)
    }

    @Test func aFailedReadNeverRetries() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        let a = Self.approver(fake)
        for _ in 0..<3 { await Self.run(a, "e", [Self.shell()]) }
        #expect(fake.projectionReads.count == 1 && fake.responses.isEmpty)
    }

    @Test func offOrUnconfirmedFetchesNothing() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings(on: false)
        fake.projections["e/t"] = Self.projectionJSON()
        let a = Self.approver(fake)
        await Self.run(a, "e", [Self.shell()])
        fake.settings["e"] = Self.settings()
        fake.confirmed = false
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.projectionReads.isEmpty && fake.settingsReads.isEmpty && fake.responses.isEmpty)
        // Confirming later answers the request still waiting.
        fake.confirmed = true
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.responses.count == 1)
    }

    @Test func theServersSettingsDecideNotTheCachedOnes() async {
        let fake = Fake()
        fake.cached["e"] = Self.settings()
        fake.settings["e"] = Self.settings(on: false)
        fake.projections["e/t"] = Self.projectionJSON()
        let a = Self.approver(fake)
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.settingsReads == ["e"] && fake.responses.isEmpty)
    }

    @Test func turnedOffWhileTheReadIsInFlight() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/t"] = Self.projectionJSON()
        fake.beforeSettings = { fake.settings["e"] = Self.settings(on: false) }
        let a = Self.approver(fake)
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.responses.isEmpty)
    }

    @Test func settledOrChangedWhileTheReadIsInFlight() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/t"] = Self.projectionJSON()
        let a = Self.approver(fake)
        // The user answers in another window: the next shell no longer shows the request.
        fake.beforeSettings = { _ = a.shellChanged("e", Self.snapshot([Self.shell(request: nil)])) }
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.responses.isEmpty)
        // The environment drops mid-read.
        fake.projections["e/u"] = Self.projectionJSON(thread: "u")
        fake.beforeSettings = { _ = a.shellChanged("e", nil) }
        await Self.run(a, "e", [Self.shell("u")])
        #expect(fake.responses.isEmpty)
    }

    @Test func askRuleAndOtherKindsStayPending() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/t"] = Self.projectionJSON(item: ["fullAccessOverride": .string("ask_rule")])
        fake.projections["e/f"] = Self.projectionJSON(thread: "f", kind: "file-change")
        let a = Self.approver(fake)
        await Self.run(a, "e", [Self.shell(), Self.shell("f", kind: "file-change")])
        #expect(fake.responses.isEmpty)
        // A file change never even gets read.
        #expect(fake.projectionReads == ["e/t"])
    }

    @Test func eachEnvironmentAnswersOnlyByItsOwnSettings() async {
        let fake = Fake()
        fake.settings["on"] = Self.settings()
        fake.settings["off"] = Self.settings(on: false)
        fake.cached["off"] = Self.settings()
        fake.projections["off/t"] = Self.projectionJSON()
        fake.projections["on/t"] = Self.projectionJSON()
        let a = Self.approver(fake)
        await Self.run(a, "off", [Self.shell()])
        #expect(fake.settingsReads == ["off"] && fake.responses.isEmpty)
        await Self.run(a, "on", [Self.shell()])
        #expect(fake.responses.map(\.env) == ["on"])
    }

    @Test func anApprovalItemThatArrivesLateGetsOneMoreRead() async {
        let fake = Fake()
        fake.settings["e"] = Self.settings()
        fake.projections["e/t"] = Self.projectionJSON(item: nil)
        let a = Self.approver(fake)
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.responses.isEmpty)
        fake.projections["e/t"] = Self.projectionJSON()
        await Self.run(a, "e", [Self.shell()])
        #expect(fake.responses.count == 1)
        // Still missing on the second read: left for the user.
        fake.projections["e/u"] = Self.projectionJSON(thread: "u", item: nil)
        for _ in 0..<3 { await Self.run(a, "e", [Self.shell("u")]) }
        #expect(fake.responses.count == 1 && fake.projectionReads.filter { $0 == "e/u" }.count == 2)
    }
}
