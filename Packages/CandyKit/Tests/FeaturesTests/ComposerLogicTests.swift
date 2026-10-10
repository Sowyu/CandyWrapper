import Foundation
import Testing
import T3Protocol
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
}
