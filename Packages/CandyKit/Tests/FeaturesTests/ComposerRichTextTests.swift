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
    @Test func languages() {
        #expect(ComposerCodeLanguages.replacing("  js title=x", with: "swift") == "  swift title=x")
        #expect(ComposerCodeLanguages.replacing("js title=x", with: "") == "text title=x")
        #expect(ComposerCodeLanguages.label("ts") == "TypeScript")
    }
    /// composer-list-continuation.test.ts at 4928, case for case.
    @Test func listContinuation() {
        typealias L = ComposerListContinuation
        func enter(_ v: String, _ c: Int) -> String? { L.enter(v, cursor: c)?.applied(to: v) }
        func at(_ v: String, _ s: String) -> Int { (v as NSString).range(of: s).location }
        #expect(enter("- foo", 5) == "- foo\n- ")
        #expect(enter("  * foo", 7) == "  * foo\n  * ")
        #expect(enter("- [x] done", 10) == "- [x] done\n- [ ] ")
        #expect(enter("1. foobar", 5) == "1. fo\n2. obar")
        #expect(enter("1. foo\n2. ", 10) == "1. foo\n")
        #expect(enter("- ", 2) == "")
        #expect(enter("1)\t", 3) == "")
        #expect(enter("- [ ] ", 6) == "")
        var value = "1. parent\n   1. child\n      1. "
        for expected in ["1. parent\n   1. child\n   2. ", "1. parent\n   1. child\n2. ", "1. parent\n   1. child\n"] {
            value = enter(value, (value as NSString).length) ?? ""
            #expect(value == expected)
        }
        let lifted = "1. a\n   1. \n2. b"
        #expect(enter(lifted, at(lifted, "\n2.")) == "1. a\n2. \n3. b")
        #expect(L.enter(lifted, cursor: at(lifted, "\n2."))?.cursorAfter == "1. a\n2. ".utf16.count)
        #expect(L.enter("1. @README.md go", cursor: at("1. @README.md go", "README") + 2) == nil)
        // bac96aa3b2: a bare "2." is not an item, so Return adds a line; Tab still indents it.
        #expect(L.enter("2.", cursor: 2) == nil)
        #expect(L.indent("2.", cursor: 2) != nil)
        let renumber = "1. @README.md go\n2. two\n03. three\n10. four"
        #expect(enter(renumber, at(renumber, "go")) == "1. @README.md \n2. go\n3. two\n04. three\n5. four")
        let parens = "  1) a\n\t1) child\n  2) b\n1) parent\n  3) untouched"
        #expect(enter(parens, at(parens, "\n")) == "  1) a\n  2) \n\t1) child\n  3) b\n1) parent\n  3) untouched")
        for boundary in ["", "text", "1) other list"] {
            let v = "1. a\n2. b\n\(boundary)\n3. untouched"
            #expect(enter(v, at(v, "\n")) == "1. a\n2. \n3. b\n\(boundary)\n3. untouched")
        }
        let chip = "1. a\n2. @\"file\n2. name\" \n3. b"
        #expect(enter(chip, at(chip, "\n")) == "1. a\n2. \n3. @\"file\n2. name\" \n4. b")
        // Numbers past JavaScript's safe integers renumber nothing, and UInt64.max must not trap.
        for huge in ["18446744073709551615", "9007199254740990"] {
            let text = "\(huge). a\n2. b"
            #expect(L.enter(text, cursor: huge.count + 3)?.pieces.count == 1)
        }
        #expect(L.nextOrderedMarker("09.") == "10." && L.nextOrderedMarker("001)") == "002)" && L.nextOrderedMarker("99999999999999999999.") == "99999999999999999999.")
    }

    /// #17138 and #27016: Tab nests at the parent's content column, Shift+Tab undoes it.
    @Test func listIndentAndOutdent() {
        typealias L = ComposerListContinuation
        for (value, expected) in [("1. parent\n2. child", "1. parent\n   1. child"), ("10. parent\n11. child", "10. parent\n    1. child"),
                                  ("1.\tparent\n2. child", "1.\tparent\n    1. child"),
                                  ("1. @\"file\n   9. name\"\n2. child", "1. @\"file\n   9. name\"\n   1. child")] {
            let cursor = (value as NSString).range(of: "child", options: .backwards).location + 2
            let edit = L.indent(value, cursor: cursor)
            #expect(edit?.applied(to: value) == expected)
            #expect(edit?.cursorAfter == (expected as NSString).range(of: "child", options: .backwards).location + 2)
        }
        let sibling = "1. parent\n   1. first\n2. second"
        #expect(L.indent(sibling, cursor: sibling.utf16.count)?.applied(to: sibling) == "1. parent\n   1. first\n   2. second")
        for value in ["- parent\n- child", "1. parent\n2. child", "  7. child"] {
            let cursor = (value as NSString).range(of: "child", options: .backwards).location + 2
            guard let nest = L.indent(value, cursor: cursor) else { Issue.record("no indent for \(value)"); continue }
            let nested = nest.applied(to: value)
            let out = L.outdent(nested, cursor: nest.cursorAfter)
            #expect(out?.applied(to: nested) == value)
            #expect(out?.cursorAfter == cursor)
        }
        for (value, expected) in [("1. a\n   1. b\n2. c", "1. a\n2. b\n3. c"), ("- a\n  5. b", "- a\n5. b")] {
            let b = (value as NSString).range(of: "b").location
            #expect(L.outdent(value, cursor: b)?.applied(to: value) == expected)
        }
        #expect(L.outdent("- item", cursor: 6) == nil)
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
        // The caret sits on the styled edge, so 4928 shows the bold's Markdown (#30421).
        #expect(editor.string == "**bold**")
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
    /// 7d6b5bec87: Mod+B bolds a selection and otherwise falls through to `sidebar.toggle`.
    @Test func commandBBoldsOnlyASelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerEditor()
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.richTextEnabled = true
        editor.setText("hello world")
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        #expect(!editor.handleFormattingKey(key))
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(editor.handleFormattingKey(key))
        #expect(editor.expandedText == "**hello** world")
        window.contentView = nil
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
