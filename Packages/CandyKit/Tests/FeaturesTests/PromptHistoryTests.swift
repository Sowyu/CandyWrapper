import AppKit
import Testing
@testable import Features

/// Port of chat/composerPromptHistory.test.ts.
struct PromptHistoryTests {
    typealias H = PromptHistory

    @Test func recallableStripsSendTimeAppends() {
        for comment in ["Render <preview_annotation>", "Render\n<preview_annotation>\nhere", "Render &lt;preview_annotation&gt;"] {
            #expect(H.recallable("Prompt\n<preview_annotation>\nComment: \(comment)\n</preview_annotation>") == "Prompt")
        }
        let malformed = "Prompt\n<preview_annotation>\nouter literal\n<preview_annotation>\ninner\n</preview_annotation>"
        #expect(H.recallable(malformed) == malformed)
        #expect(H.recallable("email@build:7\n<terminal_context>\n- Build line 7:\n  output\n</terminal_context>") == "email@build:7")
        let sent = "Ultrathink:\nInvestigate this\n\n<terminal_context>\n- Terminal 1 lines 12-13:\n  12 | git status\n  13 | On branch main\n</terminal_context>\n\n<element_context>\n- <button>:\n  url: https://example.com\n</element_context>"
        #expect(H.recallable(sent) == "Investigate this")
    }

    @Test func removesOnlyMatchingTerminalLabels() {
        let cases = [
            ("Look at @terminal-1:4 please", "Look at please"),
            ("@terminal-1:4 typed twice: @terminal-1:4\n    indented  code", "typed twice: @terminal-1:4\n    indented  code"),
            ("see @terminal-1:40 and @terminal-1:4-12 then @terminal-1:4", "see @terminal-1:40 and @terminal-1:4-12 then"),
        ]
        for (typed, expected) in cases {
            #expect(H.recallable(typed + "\n\n<terminal_context>\n- Terminal 1 line 4:\n  4 | ls\n</terminal_context>") == expected)
        }
    }

    @Test func reviewCommentsAnnotationsAndReferences() {
        let block = #"<review_comment filePath="src/app.ts">Keep this configurable.</review_comment>"#
        #expect(H.recallable("Please update this.\n\n" + block) == "Please update this.")
        let mid = "Before\n\n" + block + "\n\nAfter"
        #expect(H.recallable(mid) == mid)
        #expect(H.recallable(mid + "\n\n" + block) == mid)
        #expect(H.recallable("Fix this\n\n<preview_annotation>\nPage: Example\n<element_context>\n- <button>:\n  html: Save\n</element_context>\n</preview_annotation>") == "Fix this")
        #expect(H.recallable("Look at [Terminal](t3-context://v1/terminal/term-1) please\n    indented  code\n![image](t3-context://v1/image/img-1)")
                == "Look at please\n    indented  code")
        #expect(H.recallable("![image](t3-context://v1/image/img-1)") == "")
    }

    @Test func appComposedSendsAreNotHistory() {
        #expect(H.recallable("   ") == "")
        #expect(H.recallable(H.attachmentOnlyPrompt) == "")
        #expect(H.recallable(H.planPrefix + "# Plan\n1. do it") == "")
    }

    static let entries = H.entries([
        .init(id: "m1", isUser: true, text: "first"),
        .init(id: "a1", isUser: false, text: "reply"),
        .init(id: "m2", isUser: true, text: "second"),
        .init(id: "img", isUser: true, text: ""),
        .init(id: "m3", isUser: true, text: "third"),
    ])

    func backward(_ p: H.Position?, _ prompt: String) -> H.Step? { H.step(.backward, entries: Self.entries, position: p, currentPrompt: prompt) }
    func forward(_ p: H.Position?, _ prompt: String) -> H.Step? { H.step(.forward, entries: Self.entries, position: p, currentPrompt: prompt) }

    @Test func entriesKeepUserTextAndCollapseDuplicates() {
        #expect(Self.entries.map(\.prompt) == ["first", "second", "third"])
        let collapsed = H.entries([
            .init(id: "m1", isUser: true, text: "same"), .init(id: "m2", isUser: true, text: "same"),
            .init(id: "m3", isUser: true, text: "other"), .init(id: "m4", isUser: true, text: "same"),
        ])
        #expect(collapsed == [.init(id: "m2", prompt: "same"), .init(id: "m3", prompt: "other"), .init(id: "m4", prompt: "same")])
    }

    @Test func stepping() {
        #expect(backward(nil, "typing") == nil)
        let first = backward(nil, "")
        #expect(first == H.Step(position: .init(entryId: "m3", recalled: "third"), prompt: "third"))
        #expect(backward(first?.position, "third")?.prompt == "second")
        #expect(backward(.init(entryId: "m1", recalled: "first"), "first") == nil)
        let newer = forward(.init(entryId: "m2", recalled: "second"), "second")
        #expect(newer?.prompt == "third")
        #expect(forward(newer?.position, "third") == H.Step(position: nil, prompt: ""))
        // An edited recall is a fresh draft; sent and cleared starts over.
        let p = H.Position(entryId: "m3", recalled: "third")
        #expect(backward(p, "third edited") == nil)
        #expect(forward(p, "third edited") == nil)
        #expect(backward(p, "")?.position == p)
        #expect(forward(nil, "") == nil)
    }

    /// ChatComposer.tsx:4393-4436 on a real composer: empty start, caret edges, edits end browsing.
    @MainActor @Test func composerArrowKeys() {
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        composer.layoutSubtreeIfNeeded()
        composer.historyMessages = { [.init(id: "m1", isUser: true, text: "one\ntwo"), .init(id: "m2", isUser: true, text: "three")] }
        let up = { composer.editor.onHistoryKey?(true) ?? false }, down = { composer.editor.onHistoryKey?(false) ?? false }
        #expect(down() == false)
        #expect(up() && composer.text == "three")
        #expect(up() && composer.text == "one\ntwo")
        // The caret sits at the end of a two-line recall: ArrowUp moves the caret first.
        #expect(up() == false)
        composer.editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(up() == false) // oldest entry
        #expect(down() == false) // caret not on the last line
        composer.editor.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(down() && composer.text == "three")
        #expect(down() && composer.text == "")
        // A typed draft never starts browsing.
        composer.text = "draft"
        #expect(up() == false)
        // A question owns the keys; an approval no longer does (ChatComposer.tsx:3607, a93b03c8a5).
        composer.text = ""
        composer.pending = .question(.init(label: "Submit", compactLabel: "Submit", enabled: true, showsPrevious: false, responding: false, showsAttach: false))
        #expect(up() == false)
    }

    @Test func followsIdThenText() {
        let grown = H.entries([
            .init(id: "m0", isUser: true, text: "zeroth"), .init(id: "m1", isUser: true, text: "A"),
            .init(id: "m2", isUser: true, text: "B"), .init(id: "m3", isUser: true, text: "A"),
        ])
        #expect(H.step(.backward, entries: grown, position: .init(entryId: "m1", recalled: "A"), currentPrompt: "A")?.prompt == "zeroth")
        #expect(H.step(.forward, entries: grown, position: .init(entryId: "gone", recalled: "not sent"), currentPrompt: "not sent") == nil)
        let collapsed = H.entries([.init(id: "m1", isUser: true, text: "first"), .init(id: "m3", isUser: true, text: "A")])
        #expect(H.step(.backward, entries: collapsed, position: .init(entryId: "m2", recalled: "A"), currentPrompt: "A")?.prompt == "first")
    }
}
