import Foundation
import Testing
import T3Protocol
@testable import T3Store
@testable import Features

/// ContextWindowMeter.logic.ts, claudeCompaction.ts and the compaction gating in ChatView.tsx:7661-7726.
@Suite struct ComposerCompactionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func resumeOfferNeedsClaudeAHundredThousandTokensAndSeventyIdleMinutes() {
        let due = start.addingTimeInterval(70 * 60)
        #expect(ComposerCompaction.shouldOfferResume(driver: "claudeAgent", usedTokens: 100_000, updatedAt: start, now: due))
        #expect(!ComposerCompaction.shouldOfferResume(driver: "claudeAgent", usedTokens: 99_999, updatedAt: start, now: due))
        #expect(!ComposerCompaction.shouldOfferResume(driver: "claudeAgent", usedTokens: 150_000, updatedAt: start, now: due.addingTimeInterval(-1)))
        #expect(!ComposerCompaction.shouldOfferResume(driver: "codex", usedTokens: 150_000, updatedAt: start, now: due))
        #expect(!ComposerCompaction.shouldOfferResume(driver: "claudeAgent", usedTokens: 150_000, updatedAt: nil, now: due))
        #expect(ComposerCompaction.offerStart(driver: "claudeAgent", usedTokens: 120_000, updatedAt: start) == due)
    }

    @Test func resumeTokensHideForDismissalsDisabledCompactionHeldQueuesAndFanOuts() {
        let usage = ThreadContextWindowUsage(used: 123_400, maximum: 200_000, automatically: true, updatedAt: start)
        let late = start.addingTimeInterval(2 * 3600)
        func tokens(dismissed: Bool = false, disabled: Bool = false, held: Bool = false, multiple: Bool = false) -> Double? {
            ComposerCompaction.resumeTokens(usage: usage, driver: "claudeAgent", dismissed: dismissed, compactDisabled: disabled,
                                            hasHeldQueuedRuns: held, multipleModels: multiple, now: late)
        }
        #expect(tokens() == 123_400)
        #expect(ThreadContextWindowUsage.tokens(tokens() ?? 0) == "123k")
        #expect(tokens(dismissed: true) == nil)
        #expect(tokens(disabled: true) == nil)
        #expect(tokens(held: true) == nil)
        #expect(tokens(multiple: true) == nil)
    }

    @Test func compactBeforeSendSkipsTheChipOffStateAndABareCompact() {
        #expect(ComposerCompaction.compactsBeforeSend(resumeTokens: 120_000, keepFullHistory: false, text: "Next step"))
        #expect(!ComposerCompaction.compactsBeforeSend(resumeTokens: 120_000, keepFullHistory: true, text: "Next step"))
        #expect(!ComposerCompaction.compactsBeforeSend(resumeTokens: 120_000, keepFullHistory: false, text: " /COMPACT "))
        #expect(!ComposerCompaction.compactsBeforeSend(resumeTokens: nil, keepFullHistory: false, text: "Next step"))
    }

    @Test func dismissalFollowsTheServersResumeQuestion() throws {
        let question = "This session is 1h 20m old and uses 150,000 tokens. Compact it before continuing?"
        #expect(ComposerCompaction.isResumeQuestion(question))
        #expect(ComposerCompaction.isResumeQuestion("This session is 75m old and uses 999 tokens. Compact it before continuing?"))
        #expect(!ComposerCompaction.isResumeQuestion("This session is 1h 20m old and uses 150000 tokens. Compact it before continuing?"))
        func request(_ answer: String, status: String = "resolved") throws -> RuntimeRequest {
            try JSONValue.object(["id": .string("r"), "kind": .string("user_input"), "status": .string(status),
                                  "answers": .object([question: .string(answer)])]).decode(as: RuntimeRequest.self)
        }
        #expect(ComposerCompaction.hasDismissedResume([try request("Don't ask again")]))
        #expect(!ComposerCompaction.hasDismissedResume([try request("Keep full history")]))
        #expect(!ComposerCompaction.hasDismissedResume([try request("Don't ask again", status: "pending")]))
        #expect(ComposerCompaction.dismissalKey(environmentId: "env-1", instanceId: "claude_work")
            == "t3code:resume-compaction-dismissed:env-1:claude_work")
        #expect(ComposerCompaction.dismissalKey(environmentId: "env-1", instanceId: nil) == "t3code:resume-compaction-dismissed:env-1:claudeAgent")
    }

    @Test func disabledReasonsFollowT3sOrder() {
        var gate = ComposerCompaction.Gate()
        gate.isServerThread = true; gate.hasCompactableConversation = true; gate.hasProject = true; gate.providerAvailable = true
        #expect(!gate.disabled && gate.reason == nil)
        gate.busy = true
        #expect(gate.reason == "Compacting is unavailable right now")
        gate.providerAvailable = false
        #expect(gate.reason == "Compaction is unavailable for this provider")
        gate.hasProject = false
        #expect(gate.reason == "Choose a project before compacting")
        gate.canOperateThread = false
        #expect(gate.reason == "This connection cannot change threads.")
    }

    @Test func availableProviderStaysInTheLockedContinuationGroup() throws {
        func claude(_ id: String, group: String, compact: Bool) -> ServerProvider {
            var p = ServerProvider(instanceId: ProviderInstanceId(rawValue: id), driver: "claudeAgent")
            p.continuationGroupKey = group
            p.slashCommands = compact ? [ServerProviderSlashCommand(name: "compact")] : []
            return p
        }
        let providers = [claude("a", group: "one", compact: false), claude("b", group: "two", compact: true)]
        #expect(ComposerCompaction.hasAvailableProvider(providers, driver: "claudeAgent", instanceId: "b", lockedInstanceId: nil))
        // Locked to "a": "b" is in another group, so the pick falls back to "a", which has no compact.
        #expect(!ComposerCompaction.hasAvailableProvider(providers, driver: "claudeAgent", instanceId: "b", lockedInstanceId: "a"))
        #expect(!ComposerCompaction.hasAvailableProvider(providers, driver: "codex", instanceId: "b", lockedInstanceId: nil))
    }

    @Test func meterHoldsItsSlotWhileAStartedThreadLoads() {
        #expect(ComposerCompaction.reservesMeter(meterEnabled: true, detailLoading: true, threadStarted: true, providerReportsContextWindow: nil))
        #expect(!ComposerCompaction.reservesMeter(meterEnabled: true, detailLoading: true, threadStarted: true, providerReportsContextWindow: false))
        #expect(!ComposerCompaction.reservesMeter(meterEnabled: true, detailLoading: false, threadStarted: true, providerReportsContextWindow: true))
        #expect(!ComposerCompaction.reservesMeter(meterEnabled: false, detailLoading: true, threadStarted: true, providerReportsContextWindow: true))
    }

    // MARK: Timeline

    private func item(_ id: String, _ type: String, run: String, status: String = "completed", extra: [String: JSONValue] = [:]) throws -> ProjectedTurnItem {
        var json: [String: JSONValue] = ["id": .string(id), "threadId": .string("t"), "type": .string(type), "runId": .string(run),
                                         "ordinal": .number(1), "status": .string(status), "updatedAt": .string("2026-10-12T10:00:00.000Z")]
        json.merge(extra) { $1 }
        return ProjectedTurnItem(position: 0, visibility: "local", sourceThreadId: "t", sourceItemId: TurnItemId(id), item: try TurnItem(json: .object(json)))
    }

    @Test func compactRequestStaysActiveUntilItsCompactionCompletes() throws {
        var p = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        let run = TimelineLatestRun(runId: "run-c", status: .running)
        let compact = try item("u", "user_message", run: "run-c", extra: ["text": .string("/compact"), "attachments": .array([])])
        p.visibleTurnItems = [compact]
        #expect(TimelineRunState.compactRequestActive(p, latestRun: run))
        p.visibleTurnItems = [compact, try item("c", "compaction", run: "run-c", status: "running")]
        #expect(TimelineRunState.compactRequestActive(p, latestRun: run))
        p.visibleTurnItems = [compact, try item("c", "compaction", run: "run-c")]
        #expect(!TimelineRunState.compactRequestActive(p, latestRun: run))
        p.visibleTurnItems = [try item("u", "user_message", run: "run-c", extra: ["text": .string("Hello")])]
        #expect(!TimelineRunState.compactRequestActive(p, latestRun: run))
        p.visibleTurnItems = [compact]
        #expect(!TimelineRunState.compactRequestActive(p, latestRun: TimelineLatestRun(runId: "run-c", status: .completed)))
    }

    @Test func compactingRelabelsTheWorkingRowAndBlanksThinking() {
        let message = TimelineEntry.message("u", ChatMessage(id: "u", role: .user, text: "/compact", runId: "run-c", createdAt: "2026-10-12T10:00:00Z"))
        var input = TimelineRowsInput(entries: [message], latestRun: TimelineLatestRun(runId: "run-c", status: .running), runningRunId: "run-c",
                                      isWorking: true, activeTurnStartedAt: "2026-10-12T10:00:00Z")
        input.isCompacting = true
        let rows = TimelineRows.derive(input)
        #expect(rows.contains { $0.kind == .working(compacting: true) })
        #expect(rows.contains { if case .thinking(_, _, true) = $0.kind { true } else { false } })
        // Once the running compaction row shows, the header goes back to "Working for".
        let active = TimelineEntry.work("c", WorkLogEntry(id: "c", createdAt: "2026-10-12T10:00:01Z", runId: "run-c", label: "Compacting context",
                                                         tone: .info, sourceActivityKind: "context-compaction", toolLifecycleStatus: .inProgress))
        input.entries.append(active)
        let later = TimelineRows.derive(input)
        #expect(later.contains { $0.kind == .working(compacting: false) })
        #expect(later.contains { $0.kind == .contextCompaction(label: "Compacting context", active: true) })
    }

    @Test func compactionDividerLabelsAndTokenDetail() throws {
        #expect(EventRowView.compactionLabel(.failed) == "Context compaction failed")
        #expect(EventRowView.compactionLabel(.interrupted) == "Context compaction stopped")
        #expect(EventRowView.compactionLabel(.cancelled) == "Context compaction stopped")
        #expect(EventRowView.compactionLabel(.running) == "Compacting context")
        #expect(EventRowView.compactionLabel(.completed) == "Context compacted")
        let both = try item("c", "compaction", run: "r", extra: ["beforeTokenCount": .number(152_000), "afterTokenCount": .number(30_500)]).item
        #expect(EventRowView.compactionTokens(both) == "152000 → 30500 tokens")
        let half = try item("c", "compaction", run: "r", extra: ["afterTokenCount": .number(12)]).item
        #expect(EventRowView.compactionTokens(half) == "? → 12 tokens")
        #expect(EventRowView.compactionTokens(try item("c", "compaction", run: "r").item) == nil)
    }
}
