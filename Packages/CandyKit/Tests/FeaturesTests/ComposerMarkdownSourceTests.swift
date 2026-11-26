import AppKit
import Testing
@testable import Features

// Ports of T3's tests for editable Markdown markers (#30421, af54fe2344): composer-rich-text.test.ts
// `inlineMarkdownUnitMarks`, and the "Markdown markers around styled text" cases of
// ComposerPromptEditorTiptap.input.browser.test.tsx. T3 positions count from 1 in a paragraph; the port turns
// them into display offsets before the reveal. `{End}` is Cmd+Down, which leaves the styled word.

private typealias Mark = ComposerRichText.Mark

@MainActor private final class Host {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let editor = ComposerEditor()
    init(_ value: String) {
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        editor.chipLook = ComposerChipLook.basic
        editor.richTextEnabled = true
        editor.onSubmitKey = { _ in false }
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.setText(value)
    }
    var value: String { editor.expandedText }
    var text: String { editor.string }
    func caret(_ display: Int) { editor.setSelectedRange(NSRange(location: display, length: 0)) }
    func select(_ from: Int, _ to: Int) { editor.setSelectedRange(NSRange(location: from, length: to - from)) }
    func end() { editor.moveToEndOfDocument(nil) }
    func type(_ s: String) { for c in s { editor.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)); settle() } }
    func delete() { editor.deleteForward(nil); settle() }
    func backspace() { editor.deleteBackward(nil); settle() }
    func right() { editor.moveRight(nil) }
    func undo() { #expect(editor.tryToPerform(Selector(("undo:")), with: nil)); settle() }
    func redo() { #expect(editor.tryToPerform(Selector(("redo:")), with: nil)); settle() }
    func settle() { RunLoop.main.run(mode: .default, before: Date()) }
    func press(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        editor.keyDown(with: event)
        settle()
    }

    /// `textWithMark`: the display text of each run with `mark`.
    func text(with mark: Mark) -> [String] { runs { ComposerRichTextStyler.marks($0[.composerMarks]).contains(mark) } }
    /// The text shown as Markdown source.
    var source: [String] { runs { $0[ComposerMarkdownSource.key] != nil } }
    private func runs(_ test: ([NSAttributedString.Key: Any]) -> Bool) -> [String] {
        let storage = editor.textStorage!
        var out: [String] = [], last = -1
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            guard test(attrs) else { return }
            let piece = (storage.string as NSString).substring(with: range)
            if last == range.location, !out.isEmpty { out[out.count - 1] += piece } else { out.append(piece) }
            last = NSMaxRange(range)
        }
        return out
    }
}

@MainActor struct ComposerMarkdownSourceTests {
    @Test func mapsEachSourceCharacterToItsMarksOrNilForADroppedDelimiter() {
        let bold: [Mark] = [.bold]
        let units = ComposerRichText.unitMarks("**`*` w** \\*").map { $0.map(Set.init) }
        let expected: [[Mark]?] = [nil, nil, nil, [.bold, .code], nil, bold, bold, nil, nil, [], [], []]
        #expect(units == expected.map { $0.map(Set.init) })
    }

    struct BoldCase: Sendable { var word: String; var prefix: String; var prefixText: String?; var source: [String]; var code: [String] = [] }

    @Test(arguments: [
        BoldCase(word: "ship", prefix: "", source: ["**ship**"]),
        BoldCase(word: "path\\", prefix: "", source: []),
        BoldCase(word: "2*3", prefix: "", source: []),
        BoldCase(word: "b", prefix: "*", source: []),
        BoldCase(word: "word", prefix: "\\\\*", source: []),
        BoldCase(word: "word", prefix: "\\\\**", source: []),
        BoldCase(word: "word", prefix: "\\", source: []),
        BoldCase(word: "word", prefix: "\\\\", source: ["**word**"]),
        BoldCase(word: "word", prefix: "\\\\\\", source: []),
        BoldCase(word: "word", prefix: "`path\\`", prefixText: "path\\", source: ["**word**"], code: ["path\\"]),
    ])
    func boldsAfterPrefixWithModBOnlyWhenTextIsSelected(_ row: BoldCase) {
        let value = "\(row.prefix)\(row.word) it"
        let host = Host(value)
        let from = (row.prefixText ?? row.prefix).utf16.count, to = from + row.word.utf16.count
        host.select(from, to)
        host.editor.toggleMark(.bold)
        #expect(host.value == "\(row.prefix)**\(row.word)** it")
        #expect(host.source == row.source)
        host.end()
        #expect(host.value == "\(row.prefix)**\(row.word)** it")
        #expect(host.text(with: .bold) == [row.word])
        #expect(host.text(with: .code) == row.code)
        host.select(from, to)
        // Whether the selection spans shown markers or not, Mod+B removes the bold.
        host.editor.toggleMark(.bold)
        #expect(host.value == value)
    }

    @Test func deletingTheOpeningMarkersRemovesBold() {
        let host = Host("**bold** after")
        host.caret(0)
        #expect(host.text == "**bold** after")
        host.delete(); host.delete(); host.end()
        #expect(host.value == "bold** after")
        #expect(host.text(with: .bold) == [])
    }

    @Test func turningTwoStarsIntoOneMakesItItalic() {
        let host = Host("**bold** after")
        host.caret(0)
        host.delete()
        for _ in 0..<5 { host.right() }
        host.delete(); host.end()
        #expect(host.value == "*bold* after")
        #expect(host.text(with: .italic) == ["bold"])
        #expect(host.text(with: .bold) == [])
    }

    @Test func backspacingFromTheClosingEdgeKeepsItalic() {
        let host = Host("**bold** after")
        host.caret(0)
        host.delete()
        #expect(host.text == "*bold** after")
        for position in 2...8 {
            host.right()
            #expect(host.editor.selectedRange().location == position - 1)
        }
        host.backspace(); host.end()
        #expect(host.value == "*bold* after")
        #expect(host.text(with: .italic) == ["bold"])
    }

    @Test func retypingDeletedClosingMarkersRestoresBold() {
        let host = Host("**bold** after")
        host.caret(2)
        host.right(); host.right()
        host.delete(); host.delete()
        host.type("**")
        host.end()
        #expect(host.value == "**bold** after")
        #expect(host.text(with: .bold) == ["bold"])
    }

    @Test func deletingABacktickRemovesInlineCode() {
        let host = Host("`code` after")
        host.caret(0)
        host.delete(); host.end()
        #expect(host.value == "code` after")
        #expect(host.text(with: .code) == [])
    }

    @Test func aLineBreakInsideBoldKeepsBothHalvesBold() throws {
        let host = Host("**bold** after")
        host.caret(2)
        try host.press(36, "\r", flags: .shift)
        host.end()
        #expect(host.value == "**bo**\n**ld** after")
        #expect(host.text(with: .bold) == ["bo", "ld"])
    }

    /// T3 c83e78fe07 (#36285): a caret after the closing markers is outside the style.
    @Test(arguments: [("`Test`", "`Test`\nf", Mark.code), ("**Test**", "**Test**\nf", Mark.bold)])
    func aLineBreakAfterTypedStyledTextLeavesTheNextLinePlain(typed: String, expected: String, mark: ComposerRichText.Mark) throws {
        let host = Host("")
        host.type(typed)
        try host.press(36, "\r", flags: .shift)
        host.type("f")
        host.end()
        #expect(host.value == expected)
        #expect(host.text(with: mark) == ["Test"])
    }

    @Test func splittingAListItemInsideBoldKeepsBothHalvesBold() throws {
        let host = Host("- **bold** after")
        host.caret(3)
        try host.press(36, "\r")
        host.end()
        #expect(host.value == "- **bo**\n- **ld** after")
        #expect(host.text(with: .bold) == ["bo", "ld"])
    }

    @Test func showsNestedFormattingAsMarkdownAndRestoresItWhenTheCaretLeaves() {
        let value = "**a *b* c** d"
        let host = Host(value)
        host.caret("a b".utf16.count)
        #expect(host.text == value)
        #expect(host.text(with: .bold) == [])
        host.end()
        #expect(host.text == "a b c d")
        #expect(host.text(with: .bold) == ["a b c"])
        #expect(host.text(with: .italic) == ["b"])
        #expect(host.value == value)
    }

    @Test func undoesAMarkerEditInOneStepWithoutAnExtraStepForShowingMarkers() {
        let host = Host("**bold** after")
        host.end()
        host.type("!")
        host.caret(0)
        host.delete(); host.delete(); host.end()
        #expect(host.value == "bold** after!")
        host.undo()
        #expect(host.value == "**bold** after!")
        host.end()
        #expect(host.value == "**bold** after!")
        #expect(host.text == "bold after!")
        host.undo()
        #expect(host.value == "**bold** after")
        // Moving the caret into styled text keeps redo, and adds no undo step after it.
        host.caret(2)
        #expect(host.text == "**bold** after")
        #expect(host.source == ["**bold**"])
        host.redo()
        #expect(host.value == "**bold** after!")
        host.caret(0)
        host.redo()
        #expect(host.value == "bold** after!")
        #expect(host.text(with: .bold) == [])
        host.undo(); host.undo()
        host.redo()
        host.end()
        #expect(host.text == "bold after!")
        #expect(host.text(with: .bold) == ["bold"])
        // After a completed redo, markers still follow the caret, and Delete edits the opening one.
        host.type("?")
        host.undo(); host.redo()
        #expect(host.text == "bold after!?")
        host.caret(0)
        #expect(host.text == "**bold** after!?")
        #expect(host.source == ["**bold**"])
        host.end()
        #expect(host.text == "bold after!?")
        host.caret(0)
        host.delete()
        #expect(host.value == "*bold** after!?")
        host.undo()
        #expect(host.value == "**bold** after!?")
        host.end()
        #expect(host.text == "bold after!?")
        #expect(host.text(with: .bold) == ["bold"])
    }

    @Test func typingInsideShownSourceCoalescesIntoOneUndoStep() {
        let host = Host("**bold** after")
        host.caret(2)
        #expect(host.text == "**bold** after")
        host.type("er")
        host.end()
        #expect(host.value == "**boerld** after")
        host.undo()
        #expect(host.value == "**bold** after")
    }

    @Test func aCaretArrivingAtAStyledEdgeStaysOutsideItsMarkers() {
        let host = Host("x **bold** y")
        host.caret(6)
        #expect(host.text == "x **bold** y")
        #expect(host.editor.selectedRange().location == 10)
        host.caret(2)
        #expect(host.editor.selectedRange().location == 2)
    }

    @Test func plainDraftsAndUnfocusedEditorsShowNoSource() {
        let host = Host("**bold** after")
        host.window.makeFirstResponder(nil)
        host.editor.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(host.text == "bold after")
    }

    /// ComposerPromptEditorTiptap.input.browser.test.tsx "types after the closing markers of pasted %s" (#41327).
    /// The paste goes the way `insertClipboard` sends it, without touching the general pasteboard.
    @Test(arguments: [("**DEV**", "**DEV**!"), ("*DEV*", "*DEV*!"), ("~~DEV~~", "~~DEV~~!"), ("`DEV`", "`DEV`!"), ("***DEV***", "***DEV***!")])
    func typingAfterAPasteLandsPastTheClosingMarkers(_ pasted: String, _ typed: String) {
        let host = Host("")
        host.editor.clipboardEdit = true
        host.editor.insertText(pasted, replacementRange: host.editor.selectedRange())
        host.editor.clipboardEdit = false
        host.settle()
        host.type("!")
        #expect(host.value == typed)
    }
}
