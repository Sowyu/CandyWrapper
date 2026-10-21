import AppKit
import Testing
@testable import Features

struct ComposerRichTextTests {
    @Test func inlineGrammar() {
        let cases = [
            ("__bold__ and _italic_", "**bold** and *italic*"),
            ("***both***", "***both***"),
            ("*outer **inner** end*", "*outer **inner** end*"),
            ("**`x`** ~~gone~~", "**`x`** ~~gone~~"),
            ("a_b_c **unclosed", "a_b_c **unclosed"),
            (#"\*literal*"#, #"\*literal*"#),
            ("`**literal**`", "`**literal**`"),
            ("``literal``", "``literal``"),
            ("👩🏽‍💻 **日本語**", "👩🏽‍💻 **日本語**"),
        ]
        for (input, expected) in cases {
            #expect(ComposerRichText.serialize(ComposerRichText.parse(input)) == expected, "\(input)")
        }
    }
    /// Typed plain text already looks rendered, so a keystroke doesn't replace the whole document
    /// and run the text change handlers a second time.
    @MainActor @Test func plainTypedTextRendersToItself() {
        let base: [NSAttributedString.Key: Any] = [.font: ComposerEditor.font, .foregroundColor: NSColor.white]
        let typed = NSAttributedString(string: "hello world", attributes: base)
        #expect(ComposerRichTextStyler.render(typed, base: base, typing: true).isEqual(to: typed))
    }
    @Test func sharedMarksAndWhitespace() {
        #expect(ComposerRichText.serialize([.init(text: " a ", marks: [.bold])]) == " **a** ")
        #expect(ComposerRichText.serialize([.init(text: " a ", marks: [.bold]), .init(text: "b", marks: [.bold, .italic])]) == " **a *b***")
    }
    @Test func languagesAndScroll() {
        #expect(ComposerCodeLanguages.replacing("  js title=x", with: "swift") == "  swift title=x")
        #expect(ComposerCodeLanguages.replacing("js title=x", with: "") == "text title=x")
        #expect(ComposerCodeLanguages.label("ts") == "TypeScript")
        var gesture = ComposerScrollGesture()
        let scrollResult1 = !gesture.record(now: 1, delta: -12, eligible: true, canScroll: true, towardEnd: false)
        #expect(scrollResult1)
        let scrollResult2 = gesture.record(now: 1.05, delta: -12, eligible: true, canScroll: true, towardEnd: false)
        #expect(scrollResult2)
        gesture.suppress(now: 1.06)
        let scrollResult3 = !gesture.record(now: 1.1, delta: -50, eligible: true, canScroll: true, towardEnd: false)
        #expect(scrollResult3)
        let scrollResult4 = gesture.record(now: 1.3, delta: -50, eligible: true, canScroll: true, towardEnd: false)
        #expect(scrollResult4)
        let scrollResult5 = !gesture.record(now: 2, delta: 50, eligible: true, canScroll: true, towardEnd: true)
        #expect(scrollResult5)
    }
    @Test func listContinuation() {
        let cases = [("09) abc", "\n10) "), ("- [X] done", "\n- [ ] "), ("  + abc", "\n  + "), ("9007199254740992. x", "\n9007199254740992. ")]
        for (text, expected) in cases {
            #expect(ComposerListContinuation.edit(text, selection: NSRange(location: text.utf16.count, length: 0))?.replacement == expected)
        }
        #expect(ComposerListContinuation.edit("- ", selection: NSRange(location: 2, length: 0)) == .init(range: NSRange(location: 0, length: 2), replacement: ""))
        #expect(ComposerListContinuation.edit("- abc", selection: NSRange(location: 3, length: 0))?.replacement == "\n- ")
        #expect(ComposerListContinuation.edit("- abc", selection: NSRange(location: 1, length: 0)) == nil)
        #expect(ComposerListContinuation.edit("- abc", selection: NSRange(location: 3, length: 1), indent: true) == nil)
        // bac96aa3b2: a bare "2." is not an item, so Return adds a line; Tab still indents it.
        #expect(ComposerListContinuation.edit("2.", selection: NSRange(location: 2, length: 0)) == nil)
        #expect(ComposerListContinuation.edit("2.", selection: NSRange(location: 2, length: 0), indent: true) != nil)
        // d407f5443b: the same-level items after the split count on; deeper lines are skipped.
        let list = "1. a\n2. b\n   1. sub\n3. c\n\n9. other"
        let split = ComposerListContinuation.edit(list, selection: NSRange(location: 4, length: 0))
        #expect(split?.replacement == "\n2. ")
        #expect(split?.renumber == [.init(range: NSRange(location: 5, length: 1), number: "3"),
                                    .init(range: NSRange(location: 20, length: 1), number: "4")])
        #expect(ComposerListContinuation.edit("1) a\n2. b", selection: NSRange(location: 4, length: 0))?.renumber == [])
        // Numbers past JavaScript's safe integers renumber nothing, and UInt64.max must not trap.
        for huge in ["18446744073709551615", "9007199254740990"] {
            let text = "\(huge). a\n2. b"
            #expect(ComposerListContinuation.edit(text, selection: NSRange(location: huge.count + 3, length: 0))?.renumber == [])
        }
    }
}

@MainActor struct ComposerRichTextEditorTests {
    @Test func editorRoundTripAndPlainToggle() {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        editor.setText("**bold** and _italic_\n```swift\nlet s = \"**literal**\"\n```\n- [ ] task")
        #expect(editor.string.hasPrefix("bold and italic"))
        #expect(editor.expandedText == "**bold** and *italic*\n```swift\nlet s = \"**literal**\"\n```\n- [ ] task")
        editor.richTextEnabled = false
        #expect(editor.string == editor.expandedText)
    }
    @Test func blockRoundTrips() {
        for text in ["# Heading\n> quote\n- bullet\n09) ordered\n- [X] checked\n---", "~~~swift title=x\n**literal**\n~~~~", "```js\nabc\n```\nafter"] {
            let editor = ComposerEditor()
            editor.richTextEnabled = true
            editor.setText(text)
            #expect(editor.expandedText == text.replacingOccurrences(of: "[X]", with: "[x]"))
            editor.refreshChips()
            #expect(editor.expandedText == text.replacingOccurrences(of: "[X]", with: "[x]"))
        }
    }
    @Test func typingCharacterByCharacter() {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        for c in "**bold** and *italic* and `code`" {
            editor.insertText(String(c), replacementRange: editor.selectedRange())
        }
        #expect(editor.string == "bold and italic and code")
        #expect(editor.expandedText == "**bold** and *italic* and `code`")
        // bb76f1233c: typed underscores stay literal; `__bold__` still bolds.
        let under = ComposerEditor()
        under.richTextEnabled = true
        for c in "_build_ node_modules __b__" { under.insertText(String(c), replacementRange: under.selectedRange()) }
        #expect(under.string == "_build_ node_modules b")
        #expect(under.expandedText == "_build_ node_modules **b**")
    }
    @Test func returnRenumbersTheItemsAfter() throws {
        let editor = ComposerEditor()
        editor.setText("1. a\n2. b")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: key)
        #expect(editor.expandedText == "1. a\n2. \n3. b")
        #expect(editor.selectedRange() == NSRange(location: 8, length: 0))
    }
    @Test func codeNewlineDoesNotSend() throws {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        editor.setText("```swift\n")
        var submitted = false
        editor.onSubmitKey = { _ in submitted = true; return true }
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: key)
        #expect(!submitted)
        #expect(editor.expandedText == "```swift\n\n")
    }
    @Test func typingAndUndo() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerEditor()
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.richTextEnabled = true
        editor.setText("")
        editor.insertText("**bold**", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.expandedText == "**bold**")
        #expect(editor.string == "bold")
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        #expect(editor.expandedText == "")
        editor.undoManager?.redo()
        #expect(editor.expandedText == "**bold**")
        window.contentView = nil
    }
    @Test func formattingSelection() {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        editor.setText("hello world")
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        editor.toggleMark(.bold)
        #expect(editor.expandedText == "**hello** world")
        editor.toggleMark(.bold)
        #expect(editor.expandedText == "hello world")
    }
    @Test func pastedMarkdownAndCodeChips() {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        editor.chipLook = { _ in .init(kind: .thread, label: "Thread") }
        editor.setText("**[Thread](t3-context://v1/thread/thread_a)** \n`$skill`\n```\n$skill \n```")
        #expect(editor.expandedText == "**[Thread](t3-context://v1/thread/thread_a)** \n`$skill`\n```\n$skill \n```")
        #expect(editor.string.contains("$skill"))
    }
}
