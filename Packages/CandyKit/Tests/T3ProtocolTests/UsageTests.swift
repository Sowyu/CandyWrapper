import Foundation
import Testing
@testable import T3Protocol

/// Ports of usageMerge.test.ts, usageFormat.test.ts and usageLimits.test.ts cases.
struct UsageTests {
    static func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }

    static func bucket(_ day: String, _ provider: UsageProviderKind, _ model: String, input: Double = 100, cached: Double = 0, output: Double = 50,
                       cost: Double = 1, source: String = "modelPriced", records: Double = 2, unpriced: Double = 0, path: String? = nil,
                       hour: String? = nil) -> UsageBucket {
        UsageBucket(day: day, hourStart: hour, provider: provider, model: model, sourcePath: path,
                    totals: UsageTokenTotals(uncached: input, cached: cached, cacheCreation: 0, output: output, reasoning: 10),
                    costUsd: cost, cacheSavingsUsd: 0.5, costSource: source, records: records, unpricedRecords: unpriced)
    }

    static func summary(readAt: String, home: String = "/Users/a/.claude", host: String = "mac", buckets: [UsageBucket], sessions: Double = 3,
                        status: String = "ok", provider: UsageProviderKind = .claude, version: Int = 6) -> UsageSummary {
        UsageSummary(contractVersion: version, readAt: readAt, buckets: buckets,
                     sources: [UsageSource(fingerprint: UsageSourceFingerprint(hostId: host, provider: provider, resolvedHomePath: home, volumeId: "1:2"),
                                           status: status, distinctSessions: sessions)])
    }

    @Test func decodesSummaryAndSkipsUnknownProviders() {
        let s = UsageSummary(json: Self.json(#"""
        {"contractVersion": 6, "readAt": "2026-10-10T10:00:00.000Z", "timeZone": "Europe/Berlin", "sinceDay": "2026-10-01", "untilDay": "2026-10-10",
         "buckets": [{"day": "2026-10-10", "provider": "claude", "model": "claude-haiku-5-5", "costUsd": 0.25, "cacheSavingsUsd": 0.1,
                      "totals": {"uncachedInputTokens": 10, "cachedInputTokens": 20, "cacheCreationTokens": 0, "outputTokens": 5, "reasoningTokens": 2},
                      "costSource": "modelPriced", "records": 1, "unpricedRecords": 0, "sessions": 1},
                     {"day": "2026-10-10", "provider": "future", "model": "x", "costUsd": 1, "cacheSavingsUsd": 0,
                      "totals": {"uncachedInputTokens": 1, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 1, "reasoningTokens": 0},
                      "costSource": "unpriced", "records": 1, "unpricedRecords": 1, "sessions": 1}],
         "sources": [{"fingerprint": {"hostId": "h", "provider": "claude", "resolvedHomePath": "/h", "volumeId": ""}, "status": "ok", "scannedFiles": 1,
                      "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 1, "message": null, "refreshing": true}],
         "pricing": {"status": "fresh", "source": "litellm", "fetchedAt": null, "knownModels": 1}, "scanDurationMs": 3}
        """#))
        #expect(s?.buckets.count == 1)
        #expect(s?.buckets[0].tokens == 35)
        #expect(s?.hasRefreshingSource == true)
    }

    @Test func mergeSumsTokensCostsAndShares() {
        let s = Self.summary(readAt: "2026-10-10T10:00:00Z", buckets: [
            Self.bucket("2026-10-09", .claude, "opus", cost: 3), Self.bucket("2026-10-10", .claude, "opus", cost: 1),
            Self.bucket("2026-10-10", .claude, "haiku", cost: 0, records: 2, unpriced: 2),
        ])
        let m = UsageMerge.merge([EnvironmentUsage(environmentId: "a", label: "A", summary: s)])
        #expect(m.costUsd == 4)
        // Reasoning sits inside output and is not added again.
        #expect(m.totalTokens == 3 * 150)
        #expect(m.reasoningTokens == 30)
        #expect(m.sessions == 3)
        #expect(m.models.map(\.model) == ["opus", "haiku"])
        #expect(m.models[1].isCostUnknown)
        #expect(m.daily.map(\.day) == ["2026-10-09", "2026-10-10"])
        #expect(m.daily[1].byProvider[.claude]?.costUsd == 1)
        #expect(m.unpricedShare == 2.0 / 6)
        #expect(m.providers.first?.costShare == 1)
        #expect(m.categoryCost.unsplit == 4)
        #expect(m.speedCost.standard == 4)
    }

    @Test func sharedTranscriptDirectoryCountsOnce() {
        let older = Self.summary(readAt: "2026-10-10T09:00:00Z", buckets: [Self.bucket("2026-10-10", .claude, "opus", cost: 2)])
        let newer = Self.summary(readAt: "2026-10-10T10:00:00Z", buckets: [Self.bucket("2026-10-10", .claude, "opus", cost: 2)])
        let m = UsageMerge.merge([EnvironmentUsage(environmentId: "a", label: "A", summary: older), EnvironmentUsage(environmentId: "b", label: "B", summary: newer)])
        #expect(m.costUsd == 2)
        #expect(m.contributingEnvironments == ["b"])
        #expect(m.duplicateSources == ["A: /Users/a/.claude"])
    }

    @Test func newerPartialScanAddsOnlyMissingCells() {
        let complete = Self.summary(readAt: "2026-10-10T09:00:00Z", buckets: [Self.bucket("2026-10-09", .claude, "opus", cost: 2)])
        let partial = Self.summary(readAt: "2026-10-10T10:00:00Z", buckets: [Self.bucket("2026-10-09", .claude, "opus", cost: 2),
                                                                              Self.bucket("2026-10-10", .claude, "opus", cost: 5)], status: "partial")
        let m = UsageMerge.merge([EnvironmentUsage(environmentId: "a", label: "A", summary: complete), EnvironmentUsage(environmentId: "b", label: "B", summary: partial)])
        #expect(m.costUsd == 7)
    }

    @Test func incompatibleContractIsExcluded() {
        let old = Self.summary(readAt: "2026-10-10T09:00:00Z", buckets: [Self.bucket("2026-10-10", .claude, "opus")], version: 3)
        let m = UsageMerge.merge([EnvironmentUsage(environmentId: "a", label: "A", summary: old)])
        #expect(m.costUsd == 0)
        #expect(m.contractMismatches.first?.direction == "serverBehind")
        #expect(UsageFormat.contractMismatch("A", direction: "serverBehind") == "A runs an older server version and is excluded from totals.")
    }

    @Test func hiddenProvidersLeaveBeforeTheMerge() {
        let s = Self.summary(readAt: "2026-10-10T09:00:00Z", buckets: [Self.bucket("2026-10-10", .claude, "opus")])
        let m = UsageMerge.merge([EnvironmentUsage(environmentId: "a", label: "A", summary: UsageMerge.withoutProviders(s, [.claude]))])
        #expect(m.totalTokens == 0 && m.sessions == 0)
        #expect(UsageMerge.providersWithUsage([]) == [])
    }

    @Test func hourlyBucketsGroupByHourStart() {
        let s = Self.summary(readAt: "2026-10-10T09:00:00Z", buckets: [
            Self.bucket("2026-10-10", .codex, "gpt", cost: 1, hour: "2026-10-10T08:00:00.000Z"),
            Self.bucket("2026-10-10", .claude, "opus", cost: 2, hour: "2026-10-10T08:00:00.000Z"),
        ])
        let m = UsageMerge.merge([EnvironmentUsage(environmentId: "a", label: "A", summary: s)])
        #expect(m.hourly.count == 1)
        // Only the claude source is scanned, so the codex cell has no owner.
        #expect(m.hourly[0].costUsd == 2)
    }

    @Test func formats() {
        #expect(UsageFormat.usd(1234.5) == "$1,234.50")
        #expect(UsageFormat.tokens(19_912_000_000) == "19.9B")
        #expect(UsageFormat.tokens(76_700_000) == "76.7M")
        #expect(UsageFormat.tokens(804_000) == "804K")
        #expect(UsageFormat.tokens(1_500_000) == "1.50M")
        #expect(UsageFormat.tokens(2_000_000) == "2M")
        #expect(UsageFormat.tokens(999) == "999")
        #expect(UsageFormat.percent(0.1234) == "12.3%")
        #expect(UsageFormat.percent(0.00001) == "<0.1%")
        #expect(UsageFormat.dayShort("2026-08-07") == "Aug 7")
        #expect(UsageFormat.count(1234.5) == "1,235")
    }

    @Test func periodBucketing() {
        #expect(UsageFormat.enumerateDays("2026-02-27", "2026-03-02") == ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"])
        #expect(UsageFormat.enumerateDays("2026-03-02", "2026-03-01") == [])
        let hours = UsageFormat.enumerateHourStarts("2026-10-10T00:30:00.000Z", "2026-10-10T03:00:00.000Z")
        #expect(hours == ["2026-10-10T00:30:00.000Z", "2026-10-10T01:30:00.000Z", "2026-10-10T02:30:00.000Z"])
        let utc = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_000_000 + 37)
        let w = UsageFormat.makeWindow(days: 30, now: now, timeZone: utc)
        #expect(UsageFormat.enumerateDays(w.sinceDay, w.untilDay).count == 30)
        let h = UsageFormat.makeWindow(days: 1, now: now, resolution: "hour", timeZone: utc)
        #expect(h.untilTime.flatMap(T3Timestamp.parseEpochMs).map { $0 % 60_000 } == 0)
        #expect(UsageFormat.enumerateHourStarts(h.sinceTime!, h.untilTime!).count == 24)
        // DST: Berlin's fall-back hour is named twice.
        #expect(UsageFormat.hourShort("2026-10-25T00:00:00.000Z", timeZone: "Europe/Berlin").contains("GMT") ||
                UsageFormat.hourShort("2026-10-25T00:00:00.000Z", timeZone: "Europe/Berlin").contains("CEST"))
        #expect(UsageFormat.hourShort("2026-10-10T12:00:00.000Z", timeZone: "UTC") == "12 PM")
        #expect(UsageFormat.relativeHourShort("2026-10-10T12:00:00.000Z", relativeTo: "2026-10-10T20:00:00.000Z", timeZone: "UTC") == "12 PM today")
        #expect(UsageFormat.relativeHourShort("2026-10-09T12:00:00.000Z", relativeTo: "2026-10-10T20:00:00.000Z", timeZone: "UTC") == "12 PM yesterday")
    }

    // MARK: Limits

    static func provider(_ id: String, driver: String = "codex", email: String?, windows: [UsageLimitWindow], checkedAt: String = "2026-10-10T10:00:00.000Z",
                         credits: UsageResetCredits? = nil) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(rawValue: id), driver: driver, displayName: id == driver ? nil : id)
        p.auth = .object(["status": .string("authenticated")].merging(email.map { ["email": .string($0)] } ?? [:]) { a, _ in a })
        p.usageLimits = ProviderUsageLimits(checkedAt: checkedAt, windows: windows, resetCredits: credits)
        return p
    }

    static let now = T3Timestamp.parseEpochMs("2026-10-10T12:00:00.000Z")!

    @Test func windowMath() {
        // A five hour window resetting in 2h 30m: 50% elapsed.
        let w = UsageLimitWindow(id: "five_hour", kind: "session", label: "5h", usedPercent: 70, resetsAt: "2026-10-10T14:30:00.000Z", windowDurationMins: 300)
        #expect(UsageLimitsLogic.remainingPercent(w) == 30)
        #expect(UsageLimitsLogic.elapsedShare(w, nowMs: Self.now) == 0.5)
        #expect(UsageLimitsLogic.pace(w, nowMs: Self.now) == .ahead)
        #expect(UsageLimitsLogic.resetsIn(w, nowMs: Self.now) == "resets in 2h 30m")
        var on = w; on.usedPercent = 53
        #expect(UsageLimitsLogic.pace(on, nowMs: Self.now) == .on)
        var under = w; under.usedPercent = 10
        #expect(UsageLimitsLogic.pace(under, nowMs: Self.now) == .under)
        var past = w; past.resetsAt = "2026-10-10T11:00:00.000Z"
        #expect(UsageLimitsLogic.resetsIn(past, nowMs: Self.now) == "resets now")
        #expect(UsageLimitsLogic.duration(3 * 86_400_000 + 4 * 3_600_000) == "3d 4h")
        #expect(UsageLimitsLogic.duration(12 * 60_000) == "12m")
        #expect(UsageLimitsLogic.remainingPercent(UsageLimitWindow(id: "x", kind: "other", label: "x", usedPercent: 140)) == 0)
    }

    @Test func poolsMergeAccountsAndOrderBySessionReset() {
        let a = Self.provider("codex", email: "A@x.com", windows: [
            UsageLimitWindow(id: "primary", kind: "session", label: "5h", usedPercent: 40, resetsAt: "2026-10-10T15:00:00.000Z", windowDurationMins: 300),
            UsageLimitWindow(id: "secondary", kind: "weekly", label: "Weekly", usedPercent: 20, resetsAt: "2026-10-14T00:00:00.000Z", windowDurationMins: 10080)])
        let b = Self.provider("work", email: "b@y.com", windows: [
            UsageLimitWindow(id: "primary", kind: "session", label: "5h", usedPercent: 80, resetsAt: "2026-10-10T13:00:00.000Z", windowDurationMins: 300)])
        // The same account on a second environment counts once; the fresher read (the first) keeps its windows.
        let aAgain = Self.provider("codex", email: "a@x.com", windows: [
            UsageLimitWindow(id: "primary", kind: "session", label: "5h", usedPercent: 50, resetsAt: "2026-10-10T15:00:00.000Z", windowDurationMins: 300)],
            checkedAt: "2026-10-10T09:00:00.000Z")
        let envs = [UsageLimitsEnvironment(environmentId: "e1", label: "One", providers: [a, b], sources: []),
                    UsageLimitsEnvironment(environmentId: "e2", label: "Two", providers: [aAgain], sources: [])]
        let accounts = UsageLimitsLogic.accounts(envs)
        #expect(accounts.count == 2)
        #expect(accounts.first { $0.email?.lowercased() == "a@x.com" }?.environments.count == 2)
        let pools = UsageLimitsLogic.pools(accounts, nowMs: Self.now)
        #expect(pools.count == 1)
        let session = pools[0].windows[0]
        #expect(session.kind == "session")
        // b resets first, so it takes the first column.
        #expect(session.columns.map { $0.account.email } == ["b@y.com", "A@x.com"])
        #expect(session.usedPercent == 60 && session.remainingPercent == 40)
        #expect(session.resets.first?.restoresPercent == 40)
        #expect(pools[0].windows.count == 2)
        #expect(pools[0].windows.last?.columns.first?.window == nil)
    }

    @Test func noticesAndReport() {
        var failing = Self.provider("claudeAgent", driver: "claudeAgent", email: nil, windows: [])
        failing.usageLimits?.unavailableReason = "probeFailed"
        let hub = UsageLimitSourceSnapshot(id: "cliproxy-hub", label: "Hub", accounts: [], error: "Unauthorized")
        let envs = [UsageLimitsEnvironment(environmentId: "e1", label: "One", providers: [failing], sources: [hub])]
        #expect(UsageLimitsLogic.notices(envs) == ["claudeAgent: Could not read limits.", "Hub: Unauthorized"])
        let codex = Self.provider("codex", email: "a@x.com", windows: [UsageLimitWindow(id: "primary", kind: "session", label: "5h", usedPercent: 10)],
                                  credits: UsageResetCredits(availableCount: 2))
        let report = UsageLimitsLogic.report(instanceId: "codex", providers: [codex], sources: [], nowMs: Self.now)
        #expect(report?.accounts.count == 1)
        #expect(report?.accounts[0].resetCreditTarget == .instance("codex"))
        #expect(report?.createdAt == "2026-10-10T12:00:00.000Z")
        #expect(UsageLimitsLogic.report(instanceId: "nope", providers: [codex], sources: [], nowMs: Self.now) == nil)
        #expect(UsageLimitsLogic.isUsageLimitsCommand("  /Usage-Limits "))
        #expect(!UsageLimitsLogic.isUsageLimitsCommand("/usage-limits now"))
        #expect(UsageLimitsLogic.resetCreditsSummary(UsageResetCredits(availableCount: 2, nextExpiresAt: "2026-10-12T13:00:00.000Z"), nowMs: Self.now)
                == "2 reset credits banked · next expires in 2d 1h")
        #expect(UsageLimitsLogic.accountInitials("someone@example.com") == "SE")
    }

    @Test func decodesProviderUsageLimitsAndSourceEvents() throws {
        let event = try Self.json(#"""
        {"version": 1, "type": "usageLimitSourcesUpdated", "payload": {"sources": [{"id": "cliproxy-h", "kind": "cliproxy", "label": "H",
          "checkedAt": "2026-10-10T10:00:00.000Z", "accounts": [{"id": "a.json", "driver": "codex",
          "usageLimits": {"checkedAt": "2026-10-10T10:00:00.000Z", "windows": [{"id": "primary", "kind": "session", "label": "5h", "usedPercent": 12}]}}]}]}}
        """#).decode(as: ServerConfigEvent.self)
        guard case .usageLimitSourcesUpdated(let sources) = event else { Issue.record("wrong event"); return }
        #expect(sources[0].accounts[0].usageLimits.windows[0].usedPercent == 12)
    }
}

/// scheduledTasksSettings.logic.ts, the labels and webhook helpers.
struct ScheduledTaskLogicTests {
    @Test func schedulePayloads() {
        var d = ScheduledTaskDraft()
        #expect(ScheduledTaskLogic.schedulePayload(d) == .object(["type": .string("fixed_time"), "timeOfDay": .string("09:00"),
                                                                "weekdays": .array([1, 2, 3, 4, 5].map { .number($0) })]))
        d.weekdays = Set(0...6)
        #expect(ScheduledTaskLogic.schedulePayload(d)?["weekdays"] == nil)
        d.scheduleMode = .interval
        d.intervalMinutes = "1.5"
        #expect(ScheduledTaskLogic.schedulePayload(d)?["everyMs"] == .number(90_000))
        d.scheduleMode = .webhook
        d.maxDeliveryAgeMinutes = "0"
        #expect(ScheduledTaskLogic.schedulePayload(d) == nil)
        d.maxDeliveryAgeMinutes = ""
        d.signatureEnabled = true
        d.signatureSecret = " s3cret "
        let w = ScheduledTaskLogic.schedulePayload(d)
        #expect(w?["maxDeliveryAgeMinutes"] == .null)
        #expect(w?["signature"]?["secret"] == .string("s3cret"))
        #expect(w?["signature"]?["header"] == .string("x-hub-signature-256"))
        #expect(ScheduledTaskLogic.parseMaxDeliveryAge("1440") == .some(1440))
        #expect(ScheduledTaskLogic.parseMaxDeliveryAge("1441") == nil)
        #expect(ScheduledTaskLogic.parseMaxDeliveryAge("2.5") == nil)
    }

    @Test func taskRoundTripsThroughTheDraft() {
        let t = ScheduledTask(json: UsageTests.json(#"""
        {"id": "t1", "title": "Nightly", "prompt": "Check", "enabled": true, "schedule": {"type": "interval", "everyMs": 900000},
         "projectId": "p", "threadId": null, "workspaceStrategy": {"type": "worktree", "baseRef": "dev", "startFromOrigin": true},
         "modelSelection": {"instanceId": "claudeAgent", "model": "claude-haiku-5-5", "options": [{"id": "effort", "value": "low"}]},
         "runtimeMode": "approval-required", "interactionMode": "plan", "createdBy": {}, "creationSource": "web",
         "createdAt": "2026-10-10T00:00:00.000Z", "updatedAt": "2026-10-10T00:00:00.000Z", "nextRunAt": "2026-10-10T12:15:00.000Z",
         "lastRunAt": null, "lastRunStatus": "never", "lastRunError": null, "runCount": 0}
        """#))!
        let d = ScheduledTaskLogic.draft(t)
        #expect(d.scheduleMode == .interval && d.intervalMinutes == "15")
        #expect(d.baseRef == "dev" && d.startFromOrigin)
        #expect(d.modelKey == "claudeAgent:claude-haiku-5-5")
        let input = try? ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("claudeAgent", "claude-haiku-5-5"),
                                                        storedSecret: false).get()
        // The model's options survive an unchanged pick; modes are kept.
        #expect(input?["modelSelection"]?["options"] != nil)
        #expect(input?["requireExisting"] == .bool(true))
        #expect(input?["runtimeMode"] == .string("approval-required"))
        #expect(input?["schedule"]?["everyMs"] == .number(900_000))
    }

    @Test func validation() {
        var d = ScheduledTaskDraft()
        #expect(ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: false) == .failure(.incomplete))
        d.title = "T"; d.prompt = "P"
        d.scheduleMode = .interval
        d.intervalMinutes = "0.5"
        #expect(ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: false) == .failure(.invalidInterval))
        d.scheduleMode = .webhook
        d.signatureEnabled = true
        #expect(ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: false) == .failure(.signatureSecret))
        #expect((try? ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: true).get()) != nil)
        d.scheduleMode = .fixed
        d.workspaceMode = .existingWorktree
        #expect(ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: false) == .failure(.checkoutPath))
    }

    @Test func labels() {
        #expect(ScheduledTaskLogic.scheduleLabel(.interval(everyMs: 900_000)) == "Every 15 min")
        #expect(ScheduledTaskLogic.scheduleLabel(.interval(everyMs: 30_000)) == "Every 30 sec")
        #expect(ScheduledTaskLogic.scheduleLabel(.fixedTime(timeOfDay: "09:00", weekdays: [1, 2, 3, 4, 5])) == "Weekdays at 09:00")
        #expect(ScheduledTaskLogic.scheduleLabel(.fixedTime(timeOfDay: "07:30", weekdays: nil)) == "Daily at 07:30")
        #expect(ScheduledTaskLogic.scheduleLabel(.fixedTime(timeOfDay: "07:30", weekdays: [0, 6])) == "Sun, Sat at 07:30")
        #expect(ScheduledTaskLogic.scheduleLabel(.webhook(signature: nil, maxDeliveryAgeMinutes: nil)) == "On webhook")
        let now = T3Timestamp.parseEpochMs("2026-10-10T12:00:00.000Z")!
        #expect(ScheduledTaskLogic.relativeLabel("2026-10-10T12:00:30.000Z", nowMs: now) == "in under a minute")
        #expect(ScheduledTaskLogic.relativeLabel("2026-10-10T12:05:00.000Z", nowMs: now) == "in 5m")
        #expect(ScheduledTaskLogic.relativeLabel("2026-10-10T15:00:00.000Z", nowMs: now) == "in 3h")
        #expect(ScheduledTaskLogic.relativeLabel("2026-10-13T12:00:00.000Z", nowMs: now) == "in 3d")
        #expect(ScheduledTaskLogic.relativeLabel("2026-10-10T11:00:00.000Z", nowMs: now) == "1h ago")
        #expect(ScheduledTaskLogic.relativeLabel(nil, nowMs: now) == "Not scheduled")
        #expect(ScheduledTaskLogic.outcomeLabel("rejected_signature") == "Bad signature")
        #expect(ScheduledTaskLogic.outcomeTone("expired") == "warning")
        // scheduledTasksSettings.logic.ts:131-147 and ScheduledTasksSettings.tsx:335-347 (3473).
        #expect(ScheduledTaskLogic.outcomeLabel("accepted", pendingWindow: true) == "Opened window")
        #expect(ScheduledTaskLogic.outcomeLabel("coalesced") == "Coalesced")
        #expect(ScheduledTaskLogic.outcomeLabel("future_outcome") == "future outcome")
        #expect(["duplicate", "coalesced", "filtered", "rejected_signature", "future_outcome"].map(ScheduledTaskLogic.outcomeTone)
            == ["warning", "warning", "outline", "error", "outline"])
        #expect(ScheduledTaskWebhookDelivery(json: .object(["id": .string("d"), "receivedAt": .string("t"), "outcome": .string("accepted"), "pendingWindow": .bool(true)]))?.pendingWindow == true)
    }

    @Test func webhookAddresses() {
        let ep = ScheduledTaskWebhookEndpoint(path: "/api/scheduled-tasks/webhook/tok", url: nil, hasSecret: false)
        let local = ScheduledTaskLogic.webhookAddress(ep, httpBaseURL: URL(string: "http://127.0.0.1:47391"))
        #expect(local.address == "http://127.0.0.1:47391/api/scheduled-tasks/webhook/tok" && local.copyable)
        #expect(local.note?.hasPrefix("Only this computer") == true)
        let none = ScheduledTaskLogic.webhookAddress(ep, httpBaseURL: nil)
        #expect(!none.copyable && none.address == ep.path)
        let connect = ScheduledTaskLogic.webhookAddress(ScheduledTaskWebhookEndpoint(path: "/p", url: "https://x.t3.codes/w", hasSecret: true), httpBaseURL: nil)
        #expect(connect.note == nil && connect.address == "https://x.t3.codes/w")
    }

    @Test func deliveriesDecode() {
        let d = ScheduledTaskWebhookDelivery(json: UsageTests.json(#"""
        {"id": "d1", "taskId": "t1", "receivedAt": "2026-10-10T11:00:00.000Z", "method": "POST", "contentType": "application/json", "bodyBytes": 2,
         "outcome": "accepted", "signatureVerified": true, "missingFields": ["body.x"], "error": null, "query": "a=1",
         "headers": {"b": "2", "a": "1"}, "body": "{}", "bodyTruncated": false, "renderedPrompt": "Handle"}
        """#))
        #expect(d?.headers.map(\.0) == ["a", "b"])
        #expect(d?.missingFields == ["body.x"])
        #expect(ScheduledTask.list(UsageTests.json(#"{"tasks": [{"id": "x", "schedule": {"type": "cron"}}]}"#)).isEmpty)
    }
}
