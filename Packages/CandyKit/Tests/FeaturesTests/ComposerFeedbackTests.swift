import Foundation
import Testing
import T3Protocol
@testable import Features

/// Which failure shows where (ChatView.tsx setThreadError and toast calls, ThreadErrorBanner.tsx,
/// client-runtime errors/transport.ts, chat/queuedMessageEdit.ts).
struct ComposerFeedbackTests {
    typealias F = ComposerFeedback

    @Test func failuresMapToT3Surfaces() {
        #expect(F.surface(for: .send(nil)) == .banner("Failed to send message."))
        #expect(F.surface(for: .send("Thread t is archived.")) == .banner("Thread t is archived."))
        #expect(F.surface(for: .approval(nil)) == .banner("Failed to submit approval decision."))
        #expect(F.surface(for: .userInput(nil)) == .banner("Failed to submit user input."))
        #expect(F.surface(for: .dismissQuestion(nil)) == .banner("Failed to dismiss the question."))
        #expect(F.surface(for: .interrupt(nil)) == .banner("Failed to interrupt the current turn."))
        #expect(F.surface(for: .resume(nil)) == .banner("Could not resume thread."))
        #expect(F.surface(for: .queuedEditSave) == .banner("Could not save the edited queued message."))
        #expect(F.surface(for: .queueCommand) == .none)
        #expect(F.surface(for: .modelChangeBlocked("Start a new chat to change models")) == .toast(.warning,
            title: "Start a new chat to change models",
            description: "This provider does not allow switching models after a conversation has started."))
        #expect(F.surface(for: .modelChangeBlocked("Start a new chat to switch providers")) == .toast(.warning,
            title: "Start a new chat to switch providers",
            description: "This thread does not support switching providers after it has started."))
        #expect(F.surface(for: .queuedEditLeft(kept: true)) == .toast(.info, title: "Queued message is no longer queued",
                                                                         description: "Your unsaved edit was kept in the composer."))
        #expect(F.surface(for: .queuedEditLeft(kept: false)) == .toast(.warning, title: "Queued message is no longer queued",
                                                                          description: "Your unsaved edit was discarded."))
    }

    @Test func transportErrorsShowNoBanner() {
        for message in ["SocketCloseError: 1006", "Socket is not connected", "The environment is not connected.",
                        "Server stopped responding.", "Mac stopped responding for 15s. It may be overloaded, asleep, or off the network.", "ping timeout", "RpcClientError: boom",
                        "Relay disconnected. Your DNS or firewall may be blocking T3 Connect. Try another network, such as a different Wi-Fi or mobile data."] {
            #expect(F.isTransportError(message), "\(message)")
            #expect(F.surface(for: .send(message)) == .none)
        }
        #expect(!F.isTransportError("The run is not connected to a provider, retry."))
        #expect(!F.isTransportError(""))
    }

    @Test func queuedEditRecovery() {
        #expect(F.recoverQueuedEdit(edited: "a", original: "a", threadPrompt: "") == .clean)
        #expect(F.recoverQueuedEdit(edited: "ab", original: "a", threadPrompt: "  ") == .kept)
        #expect(F.recoverQueuedEdit(edited: "ab", original: "a", threadPrompt: "draft") == .discarded)
        #expect(F.recoverQueuedEdit(edited: "a", original: "a", threadPrompt: "draft") == .clean)
    }

    static func shell(_ fields: String) -> ThreadShell {
        let json = """
            {"id":"t","projectId":"p","title":"T","providerInstanceId":"codex",
             "modelSelection":{"instanceId":"codex","model":"gpt-5.4"},"runtimeMode":"full-access",
             "interactionMode":"default","branch":null,"worktreePath":null,"activeProviderThreadId":null,
             "lineage":{"rootThreadId":"t","parentThreadId":null,"relationshipToParent":null},
             "forkedFrom":null,"createdBy":"user","creationSource":"web","activeRunId":null,
             "pendingRuntimeRequest":null,"latestVisibleMessage":null,"latestUserMessageAt":null,
             "hasActionableProposedPlan":false,"itemCount":0,"visibleItemCount":0,
             "createdAt":"2026-06-20T00:00:00.000Z","updatedAt":"2026-06-20T00:00:00.000Z","archivedAt":null,
             "settledOverride":null,"settledAt":null,"lastVisitedAt":null,"deletedAt":null,\(fields)}
            """
        return try! JSONDecoder().decode(ThreadShell.self, from: Data(json.utf8))
    }

    @Test func bannerPrefersLocalErrorAndRemembersDismissals() {
        var state = ThreadErrorState()
        let failed = Self.shell(#""status":"failed","latestRunId":"r1","lastError":"Provider crashed","lastErrorClass":"provider_error""#)
        #expect(state.visible("k", shell: failed) == .init(message: "Provider crashed", variant: .error))
        state.set("k", "Failed to send message.")
        #expect(state.visible("k", shell: failed)?.message == "Failed to send message.")
        // Dismissing masks the local error; the shell's own error still shows until dismissed too.
        state.dismiss("k", shell: failed)
        #expect(state.visible("k", shell: failed)?.message == "Provider crashed")
        state.dismiss("k", shell: failed)
        #expect(state.visible("k", shell: failed) == nil)
        // A different message on the same thread shows again; other threads are untouched.
        state.set("k", "Could not resume thread.")
        #expect(state.visible("k", shell: failed)?.message == "Could not resume thread.")
        #expect(state.visible("other", shell: nil) == nil)
        // Transport errors clear instead of showing.
        state.set("k", "Socket is not connected")
        #expect(state.visible("k", shell: nil) == nil)
    }

    @Test func usageLimitBannerRules() {
        let state = ThreadErrorState()
        let limited = Self.shell(#""status":"failed","latestRunId":"r1","lastError":"Usage limit","lastErrorClass":"usage_limit""#)
        // The usage-limit recovery banner takes over on a failed run.
        #expect(state.visible("k", shell: limited) == nil)
        let idle = Self.shell(#""status":"idle","latestRunId":"r1","lastError":"Usage limit","lastErrorClass":"usage_limit""#)
        #expect(state.visible("k", shell: idle) == .init(message: "Usage limit", variant: .warning))
    }

    /// A snooze counts only until its reset passes, since the server leaves `snoozedUntil` behind (f416175804).
    @Test func usageLimitSnoozeEndsAtReset() {
        let snoozed = Self.shell(#""status":"failed","latestRunId":"r1","lastErrorClass":"usage_limit","usageLimitResetAt":"2026-06-20T05:00:00.000Z","snoozedUntil":"2026-06-20T05:00:00.000Z","limitRecovery":{"runId":"r1","resetAt":"2026-06-20T05:00:00.000Z","autoResume":false,"snooze":true}"#)
        let before = ISO8601DateFormatter().date(from: "2026-06-20T04:00:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-06-20T06:00:00Z")!
        #expect(ThreadUsageLimitRecovery.snoozed(snoozed, now: before))
        #expect(!ThreadUsageLimitRecovery.snoozed(snoozed, now: after))
    }

    /// A ChatGPT plan limit swaps the error for T3's ChatGPT face (ThreadErrorBanner.tsx:83-123, 6f75bcb374).
    @Test func chatGptLimitCodesPickTheirFace() {
        let state = ThreadErrorState()
        let workspace = Self.shell(#""status":"idle","latestRunId":"r1","lastError":"Limit","lastErrorClass":"usage_limit","lastErrorCode":"subscription_sharing_workplace_individual_usage_limit_exceeded""#)
        let banner = state.visible("k", shell: workspace)
        #expect(banner?.chatGptLimit == .workspace && banner?.title == "ChatGPT usage limit reached" && banner?.variant == .warning)
        let plan = Self.shell(#""status":"idle","latestRunId":"r1","lastError":"Limit","lastErrorCode":"subscription_sharing_usage_limit_exceeded""#)
        #expect(state.visible("k", shell: plan)?.message == "Review your usage settings in ChatGPT.")
        // A 3473 shell has no code and keeps the plain error.
        let old = Self.shell(#""status":"idle","latestRunId":"r1","lastError":"Limit""#)
        #expect(state.visible("k", shell: old)?.chatGptLimit == nil)
    }
}
