import Foundation
import T3Protocol
import T3Store

/// Manual compaction rules: who may compact, why not, and the resume offer that compacts a stale
/// Claude session before the next send. Ported from ContextWindowMeter.logic.ts:12-83,
/// ChatView.tsx:7661-7726 and packages/shared/src/claudeCompaction.ts.
public enum ComposerCompaction {
    /// `CLAUDE_RESUME_COMPACTION_MINUTES` and `_TOKENS` (ContextWindowMeter.logic.ts:12-13).
    public static let resumeMinutes: Double = 70
    /// T3 offers compact-and-send from 100k; CandyWrapper waits for 400k (the user's call, docs/decisions.md).
    public static let resumeTokens: Double = 400_000
    /// Below this a compact-and-send asks "are you sure?" first; above it, it just compacts.
    public static let confirmBelowTokens: Double = 500_000

    public static func confirmsCompaction(tokens: Double?) -> Bool { (tokens ?? 0) < confirmBelowTokens }
    /// `CLAUDE_RESUME_COMPACTION_NEVER_ANSWER` (claudeCompaction.ts:8).
    public static let neverAnswer = "Don't ask again"

    /// `providerSupportsManualCompaction` (ContextWindowMeter.logic.ts:15-19).
    public static func supportsManualCompaction(_ provider: ServerProvider?) -> Bool {
        provider?.slashCommands.contains { $0.name == "compact" } ?? false
    }

    /// `hasAvailableCompactionProvider` (ContextWindowMeter.logic.ts:21-43): the driver's instances,
    /// narrowed to the locked instance's continuation group, then the selectable pick.
    public static func hasAvailableProvider(_ providers: [ServerProvider], driver: String?,
                                            instanceId: ProviderInstanceId?, lockedInstanceId: ProviderInstanceId?) -> Bool {
        let sameDriver = providers.filter { $0.driver == driver }
        let group = lockedInstanceId.flatMap { id in sameDriver.first { $0.instanceId == id }?.continuationGroupKey }
        let compatible = group.map { g in sameDriver.filter { $0.continuationGroupKey == g } } ?? sameDriver
        return supportsManualCompaction(ProviderCatalog(compatible).resolveInstance([instanceId])?.provider)
    }

    /// `CLAUDE_RESUME_COMPACTION_QUESTION_PATTERN` (claudeCompaction.ts:21-26).
    public static func isResumeQuestion(_ question: String) -> Bool {
        question.wholeMatch(of: /This session is (?:\d+h \d+m|\d+m) old and uses \d{1,3}(?:,\d{3})* tokens\. Compact it before continuing\?/) != nil
    }

    /// `hasDismissedResumeCompaction` over resolved user-input requests (ChatView.tsx:4185-4196): the
    /// server's resume question answered "Don't ask again".
    public static func hasDismissedResume(_ requests: [RuntimeRequest]) -> Bool {
        requests.contains { request in
            guard request.kind == .userInput, request.status == "resolved", case .object(let answers)? = request.answers else { return false }
            return answers.contains { isResumeQuestion($0.key) && $0.value == .string(neverAnswer) }
        }
    }

    /// The localStorage key T3 keeps the dismissal under (ChatView.tsx:4179-4184); here a UserDefaults key.
    public static func dismissalKey(environmentId: String, instanceId: ProviderInstanceId?) -> String {
        "t3code:resume-compaction-dismissed:\(environmentId):\(instanceId?.rawValue ?? "claudeAgent")"
    }

    /// `shouldOfferResumeCompaction` (ContextWindowMeter.logic.ts:63-86 in 2994): a Claude thread at 100k
    /// tokens or more whose usage last changed at least the prompt cache's life ago. A live report from
    /// a 2994 server carries that life (`promptCacheTtlMs`, c727d1219); without it the offer waits 70 minutes.
    public static func shouldOfferResume(driver: String?, usedTokens: Double?, updatedAt: Date?, promptCacheTtlMs: Double? = nil, now: Date) -> Bool {
        guard let start = offerStart(driver: driver, usedTokens: usedTokens, updatedAt: updatedAt, promptCacheTtlMs: promptCacheTtlMs) else { return false }
        return now >= start
    }

    /// When the offer starts for this usage, or nil when it never will. T3 re-checks every minute;
    /// the app waits for this moment once instead.
    public static func offerStart(driver: String?, usedTokens: Double?, updatedAt: Date?, promptCacheTtlMs: Double? = nil) -> Date? {
        guard driver == "claudeAgent", (usedTokens ?? 0) >= resumeTokens, let updatedAt else { return nil }
        return updatedAt.addingTimeInterval(promptCacheTtlMs.map { $0 / 1000 } ?? resumeMinutes * 60)
    }

    /// A bare `/compact` turn (`isCompactCommandMessage`, ChatView.tsx:820-823).
    public static func isCompactCommand(_ text: String, attachments: Int = 0) -> Bool {
        attachments == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact"
    }

    /// `activeThreadHasCompactableConversation` (ChatView.tsx:7661-7665): a user message other than a bare `/compact`.
    public static func hasCompactableConversation(_ projection: ThreadProjection?) -> Bool {
        projection?.visibleTurnItems.contains { row in
            row.item.type == .userMessage && !isCompactCommand(row.item.text, attachments: row.item["attachments"]?.arrayValue?.count ?? 0)
        } ?? false
    }

    /// `compactThreadUnavailable` and `compactDisabledReason` (ChatView.tsx:7666-7691).
    public struct Gate: Sendable, Equatable {
        public var canOperateThread = true
        /// An open server thread (not a draft) whose detail has loaded.
        public var isServerThread = false
        public var hasCompactableConversation = false
        public var hasProject = false
        /// `hasAvailableCompactionProvider`.
        public var providerAvailable = false
        /// Why the thread can't compact now: working, sending, the environment gone, an approval or question
        /// open, or the plan follow-up showing. Nil when none holds.
        public var busyReason: String?
        public var busy: Bool { busyReason != nil }
        public init() {}

        public var disabled: Bool {
            !canOperateThread || !isServerThread || !hasCompactableConversation || !hasProject || !providerAvailable || busy
        }

        /// T3's reason. `specific` (Redesign) replaces its catch-all "right now" with the condition that holds.
        public func reason(specific: Bool = false) -> String? {
            guard disabled else { return nil }
            if !canOperateThread { return "This connection cannot change threads." }
            if !hasProject { return "Choose a project before compacting" }
            if !providerAvailable { return "Compaction is unavailable for this provider" }
            guard specific else { return Self.unavailable }
            if !isServerThread { return "Send a message before compacting" }
            if !hasCompactableConversation { return "Nothing to compact yet" }
            return busyReason ?? Self.unavailable
        }
        public static let unavailable = "Compacting is unavailable right now"
    }

    /// `resumeCompactionTokens` (ChatView.tsx:7692-7710): the tokens a stale session would re-read,
    /// while the offer stands. Held queues and multi-model sends never compact first.
    public static func resumeTokens(usage: ThreadContextWindowUsage?, driver: String?, dismissed: Bool, compactDisabled: Bool,
                                    hasHeldQueuedRuns: Bool, multipleModels: Bool, now: Date) -> Double? {
        guard let usage, !dismissed, !compactDisabled, !hasHeldQueuedRuns, !multipleModels,
              shouldOfferResume(driver: driver, usedTokens: usage.used, updatedAt: usage.updatedAt,
                                promptCacheTtlMs: usage.promptCacheTtlMs, now: now) else { return nil }
        return usage.used
    }

    /// `compactBeforeSend` (ChatView.logic.ts:1515-1520): the offer is on and the message is not itself a
    /// `/compact`, with or without instructions (`COMPACT_COMMAND_PATTERN` /^\/compact(?:\s|$)/i, :927).
    public static func compactsBeforeSend(resumeTokens: Double?, keepFullHistory: Bool, text: String) -> Bool {
        resumeTokens != nil && !keepFullHistory && text.range(of: #"^/compact(\s|$)"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// `shouldReserveContextWindowMeter` (ContextWindowMeter.logic.ts:124-137): hold the meter's slot while a
    /// started thread's detail loads, unless its provider is known not to report usage.
    public static func reservesMeter(meterEnabled: Bool, detailLoading: Bool, threadStarted: Bool, providerReportsContextWindow: Bool?) -> Bool {
        meterEnabled && detailLoading && threadStarted && providerReportsContextWindow != false
    }
}
