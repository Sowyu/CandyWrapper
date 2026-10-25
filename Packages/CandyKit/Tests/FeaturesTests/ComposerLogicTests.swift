import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// T3's composer rules: composer-logic.test.ts:80-158, composerSubmission.test.ts, String.ts truncate.
struct ComposerLogicTests {
    typealias L = ComposerLogic

    @Test func compactionAlwaysQueuesFollowUps() {
        for alternate in [true, false] {
            for steer in [true, false] {
                #expect(ComposerLogic.sendMode(running: true, alternate: alternate, steerByDefault: steer, canSteer: false) == .queue)
            }
        }
    }

    @Test func sendShortcutModes() {
        let enter = L.Key(isReturn: true), mod = L.Key(isReturn: true, mod: true)
        // mode, prompt, key, expected
        let cases: [(L.SendShortcut, String, L.Key, L.SubmitIntent?)] = [
            (.enter, "hi", enter, .foreground), (.enter, "a\nb", enter, .foreground), (.enter, "hi", mod, .foreground),
            (.modEnterMultiline, "hi", enter, .foreground), (.modEnterMultiline, "a\nb", enter, nil), (.modEnterMultiline, "a\nb", mod, .foreground),
            (.modEnter, "hi", enter, nil), (.modEnter, "a\nb", enter, nil), (.modEnter, "hi", mod, .foreground),
        ]
        for (mode, prompt, key, expected) in cases {
            #expect(L.submitIntent(key, prompt: prompt, mode: mode, turnRunning: false) == expected, "\(mode) \(prompt) \(key)")
        }
        #expect(L.submitIntent(L.Key(isReturn: true, shift: true), prompt: "", mode: .enter, turnRunning: false) == nil)
        #expect(L.submitIntent(L.Key(isReturn: true, option: true), prompt: "", mode: .enter, turnRunning: false) == nil)
        #expect(L.submitIntent(L.Key(isReturn: true, composing: true), prompt: "", mode: .enter, turnRunning: false) == nil)
        #expect(L.submitIntent(L.Key(isReturn: true, isRepeat: true), prompt: "", mode: .enter, turnRunning: false) == nil)
        // With a send that needs the modifier, Mod+Enter sends and the alternate moves to Mod+Shift+Enter
        // (keybindings.ts:108-124, composer-logic.test.ts:124-143).
        let modShift = L.Key(isReturn: true, shift: true, mod: true)
        for (mode, prompt) in [(L.SendShortcut.enter, "a\nb"), (.modEnterMultiline, "hi")] {
            #expect(L.submitIntent(mod, prompt: prompt, mode: mode, turnRunning: true) == .alternate)
            #expect(L.submitIntent(modShift, prompt: prompt, mode: mode, turnRunning: true) == nil)
        }
        for (mode, prompt) in [(L.SendShortcut.modEnter, "hi"), (.modEnterMultiline, "a\nb")] {
            #expect(L.submitIntent(mod, prompt: prompt, mode: mode, turnRunning: true) == .foreground)
            #expect(L.submitIntent(modShift, prompt: prompt, mode: mode, turnRunning: true) == .alternate)
        }
        // A saved Mod+Enter rule moves too; any other chord stays.
        let ctx = KeybindingContext(["composerFocus": true, "turnRunning": true, "composerRequiresModifier": true])
        let saved = Keymap.merged(withServer: [ResolvedKeybindingRule(key: "mod+enter", command: "composer.sendAlternate")!])
        #expect(saved.effectiveShortcuts(for: "composer.sendAlternate", context: ctx).first?.shiftKey == true)
        let altQ = Keymap.merged(withServer: [ResolvedKeybindingRule(key: "alt+q", command: "composer.sendAlternate")!])
        #expect(altQ.effectiveShortcuts(for: "composer.sendAlternate", context: ctx).first?.shiftKey == false)
        // The keybindings decide first (composer-logic.test.ts): mod+enter in a draft starts in the
        // background, mod+alt+enter on a thread sends and opens a new thread.
        let modAlt = L.Key(isReturn: true, option: true, mod: true)
        #expect(L.submitIntent(mod, prompt: "hi", mode: .enter, turnRunning: false, isDraft: true) == .background)
        #expect(L.submitIntent(modAlt, prompt: "hi", mode: .enter, turnRunning: false, isDraft: true) == .background)
        #expect(L.submitIntent(modAlt, prompt: "hi", mode: .enter, turnRunning: false, isDraft: false) == .background)
        #expect(L.submitIntent(modAlt, prompt: "hi", mode: .enter, turnRunning: true, isDraft: false) == .background)
        // A user rule that rebinds Enter to another command makes it not a send.
        let rebound = Keymap(rules: Keymap.defaultRules + [ResolvedKeybindingRule(key: "enter", command: "chat.new", when: "composerFocus")!])
        #expect(L.submitIntent(L.Key(isReturn: true), prompt: "hi", mode: .enter, turnRunning: false, keymap: rebound) == nil)
        // Control+Enter counts as the modifier for the mod-enter send modes.
        #expect(L.submitIntent(L.Key(isReturn: true, control: true), prompt: "hi", mode: .modEnter, turnRunning: false) == .foreground)
    }

    /// ThreadErrorBanner.tsx:10-27 and ExpandableText.tsx:21 (02c81ec5ea, 38c662508c).
    @MainActor @Test func threadErrorBannerText() {
        let json = #"{"error":{"message":"Rate limited"}}"#
        #expect(ThreadErrorBannerView.collapsedMessage(json) == "Rate limited")
        #expect(ThreadErrorBannerView.collapsedMessage(#"{"error":{"message":"  "}}"#) == #"{"error":{"message":"  "}}"#)
        #expect(ThreadErrorBannerView.collapsedMessage("plain") == "plain")
        #expect(ThreadErrorBannerView.canExpand(json))
        #expect(!ThreadErrorBannerView.canExpand("short"))
        #expect(ThreadErrorBannerView.canExpand("a\nb"))
        #expect(ThreadErrorBannerView.canExpand(String(repeating: "x", count: 181)))
        let banner = ThreadErrorBannerView()
        banner.banner = .init(message: json, variant: .error)
        let collapsed = banner.height(forWidth: 400)
        #expect(abs(collapsed - 72) < 0.5) // `py-3`, one 20pt line, `mt-1` and the 20pt button
    }

    @Test func sendModesAndActions() {
        #expect(L.sendMode(running: false, alternate: true, steerByDefault: false) == .auto)
        #expect(L.sendMode(running: true, alternate: false, steerByDefault: false) == .queue)
        #expect(L.sendMode(running: true, alternate: true, steerByDefault: false) == .steer)
        #expect(L.sendMode(running: true, alternate: true, steerByDefault: true) == .queue)
        let running = L.RunState(activeRunId: RunId("r"), running: true)
        #expect(L.primaryAction(run: running, hasContent: false, busy: false, mode: .queue) == .stop)
        #expect(L.primaryAction(run: running, hasContent: true, busy: false, mode: .steer) == .steer)
        #expect(L.primaryAction(run: L.RunState(resumableRunId: RunId("r")), hasContent: false, busy: false, mode: .auto) == .resume)
        #expect(L.primaryAction(run: L.RunState(), hasContent: true, busy: true, mode: .auto) == .busy)
        #expect(L.dispatch(.queue).deliveryIntent == nil)
        #expect(L.dispatch(.auto).deliveryIntent == "auto")
    }

    @Test func textRules() {
        #expect(L.titleSeed("  hi  ") == "hi")
        #expect(L.titleSeed("") == "New thread")
        #expect(L.titleSeed(String(repeating: "a", count: 51)) == String(repeating: "a", count: 50) + "...")
        // `deriveThreadTitleSeed` (threadTitle.ts:16-56, b20f55248d).
        let image = ComposerContext.reference(.init(kind: "image", contextId: "image_1", label: "shot.png"))
        let thread = ComposerContext.reference(.init(kind: "thread", contextId: "thread_a", label: "Fix login"))
        #expect(L.threadTitleSeed(image, attachments: [(true, "shot.png")]) == "Attached image")
        #expect(L.threadTitleSeed("", attachments: [(true, "a.png"), (true, "b.png")]) == "Attached images")
        #expect(L.threadTitleSeed(image + " look  at\nthis", attachments: [(true, "shot.png")]) == "look at this")
        #expect(L.threadTitleSeed("see " + thread, attachments: []) == "see Fix login")
        #expect(L.threadTitleSeed("", attachments: [(false, "notes.txt")]) == "File: notes.txt")
        #expect(L.threadTitleSeed(" ", attachments: []) == "New thread")
        let quote = ThreadAssistantCitation(environmentId: "e", threadId: "t", messageId: "m", text: "the quote", start: 0, end: 9,
                                            prefix: "", suffix: "", comment: "why")
        #expect(ComposerInlineTokens.citationsToPlainText("re \(quote.markdown) ok") == "re the quote\nComment: why ok")
        #expect(L.threadTitleSeed(quote.markdown, attachments: []) == "the quote Comment: why")
        #expect(L.lengthValidationMessage(String(repeating: "a", count: 120_000) + "  ") == nil)
        #expect(L.lengthValidationMessage(String(repeating: "a", count: 120_001))
            == "Prompt is 1 character over the 120,000-character limit. Shorten or split it before sending.")
        #expect(L.lengthValidationMessage(String(repeating: "a", count: 121_500))?.hasPrefix("Prompt is 1,500 characters over") == true)
        #expect(L.placeholder(.init()) == "Ask anything, @tag files/folders, $use skills, or / for commands")
        #expect(L.placeholder(.init(approvalPending: true, disconnected: true)) == "Send a message to decline and redirect the agent")
        var feedback = L.PlaceholderInput(approvalPending: true)
        feedback.approvalFeedback = true
        #expect(L.placeholder(feedback) == "Send feedback to decline this request")
    }

    /// The send after declining pending approvals and its four race toasts (ChatView.tsx:5222-5263, a93b03c8a5).
    @Test func approvalRedirectSendsOnlyAfterACleanDecline() {
        func outcome(declined: Bool = true, changed: Bool = false, answering: Bool = false, arrived: Bool = false, moved: Bool = false) -> (Bool, String?) {
            let o = L.approvalRedirect(declined: declined, draftChanged: changed, approvalResponding: answering, approvalArrived: arrived, threadChanged: moved)
            return (o.sends, o.toast)
        }
        #expect(outcome() == (true, nil))
        #expect(outcome(changed: true) == (false, "Approval declined. Your message changed, so it wasn't sent."))
        #expect(outcome(declined: false, changed: true) == (false, "Your message changed, so it wasn't sent."))
        #expect(outcome(declined: false, answering: true) == (false, "An approval is already being answered, so your message wasn't sent."))
        #expect(outcome(arrived: true) == (false, "Another approval arrived, so your message wasn't sent."))
        // A refused decline or an approval the agent resolved first already shows its error; leaving the thread says nothing.
        #expect(outcome(declined: false) == (false, nil))
        #expect(outcome(declined: false, arrived: true) == (false, nil))
        #expect(outcome(moved: true) == (false, nil))
    }

    /// The queue strip over the recorded 07-queue.jsonl: three queued, edit, two reorders, two
    /// cancels, then promote-to-steer, each step as the strip shows it.
    @Test func queueStateFollowsTheRecordedQueue() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var streamId: String?, reducer: ThreadReducer?
        var seen: [[String]] = []
        var steerable = false, reorderable = false, sendNowWhileRunning = false
        for line in try String(contentsOf: root.appendingPathComponent("fixtures/transcripts/07-queue.jsonl"), encoding: .utf8).split(separator: "\n") {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let body = record["body"] as? [String: Any] else { continue }
            if body["tag"] as? String == "orchestration.subscribeThread", let payload = body["payload"] as? [String: Any] {
                streamId = body["id"] as? String
                reducer = ThreadReducer(threadId: ThreadId(payload["threadId"] as! String))
            } else if body["_tag"] as? String == "Chunk", body["requestId"] as? String == streamId, let values = body["values"] as? [Any] {
                _ = reducer!.apply(try values.map { try JSONDecoder().decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: $0)) })
                let state = L.QueueState(projection: reducer!.projection)
                let texts = state.items.map { $0.text.replacingOccurrences(of: "Reply with one word: ", with: "") }
                if seen.last != texts { seen.append(texts) }
                if !state.items.isEmpty { steerable = steerable || state.canPromoteToSteer; reorderable = reorderable || state.canReorder }
                if state.activeRunId != nil, state.canSendNow { sendNowWhileRunning = true }
            }
        }
        #expect(seen == [[], ["alpha"], ["alpha", "beta"], ["alpha", "beta", "gamma"], ["alpha2", "beta", "gamma"],
                         ["gamma", "alpha2", "beta"], ["gamma", "beta", "alpha2"], ["gamma", "alpha2"], ["gamma"], []])
        #expect(steerable && reorderable && !sendNowWhileRunning)
        let started = try #require(reducer?.projection)
        // Settled, the thread can start a queued message as its own turn (threadWorkflows.ts:156-160).
        #expect(L.QueueState(projection: started).canSendNow)
        #expect(L.QueueState.hasStartedSession(started))
        #expect(L.QueueState.supportsProviderHandoff(started))
    }

    @Test func reorderTargets() {
        let items = ["a", "b", "c"].map { L.QueueState.Item(runId: RunId($0), messageId: nil, text: $0) }
        // Dropping on itself or right after itself does nothing.
        #expect(L.QueueState.reorderTarget(items, moving: 1, to: 1) == .none)
        #expect(L.QueueState.reorderTarget(items, moving: 1, to: 2) == .none)
        #expect(L.QueueState.reorderTarget(items, moving: 2, to: 0) == .some(RunId("a")))
        #expect(L.QueueState.reorderTarget(items, moving: 0, to: 3) == .some(nil))
        #expect(L.primaryAction(run: .init(activeRunId: RunId("r"), running: true), hasContent: true, busy: false, mode: .queue, editingQueued: true) == .update)
    }
}
