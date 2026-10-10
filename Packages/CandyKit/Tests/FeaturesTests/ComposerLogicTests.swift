import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// T3's composer rules: composer-logic.test.ts:80-158, composerSubmission.test.ts, String.ts truncate.
struct ComposerLogicTests {
    typealias L = ComposerLogic

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
        for mode in L.SendShortcut.allCases {
            #expect(L.submitIntent(mod, prompt: "hi", mode: mode, turnRunning: true) == .alternate)
        }
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
        #expect(L.lengthValidationMessage(String(repeating: "a", count: 120_000) + "  ") == nil)
        #expect(L.lengthValidationMessage(String(repeating: "a", count: 120_001))
            == "Prompt is 1 character over the 120,000-character limit. Shorten or split it before sending.")
        #expect(L.lengthValidationMessage(String(repeating: "a", count: 121_500))?.hasPrefix("Prompt is 1,500 characters over") == true)
        #expect(L.placeholder(.init()) == "Ask anything, @tag files/folders, $use skills, or / for commands")
        #expect(L.placeholder(.init(approvalPending: true, disconnected: true)) == "Resolve this approval request to continue")
    }

    /// The queue strip over the recorded 07-queue.jsonl: three queued, edit, two reorders, two
    /// cancels, then promote-to-steer, each step as the strip shows it.
    @Test func queueStateFollowsTheRecordedQueue() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var streamId: String?, reducer: ThreadReducer?
        var seen: [[String]] = []
        var steerable = false, reorderable = false
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
            }
        }
        #expect(seen == [[], ["alpha"], ["alpha", "beta"], ["alpha", "beta", "gamma"], ["alpha2", "beta", "gamma"],
                         ["gamma", "alpha2", "beta"], ["gamma", "beta", "alpha2"], ["gamma", "alpha2"], ["gamma"], []])
        #expect(steerable && reorderable)
        let started = try #require(reducer?.projection)
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
