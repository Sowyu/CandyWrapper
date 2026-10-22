import AppKit
import Testing
@testable import Features

/// Typing undo in the composer behaves like a plain macOS text view: one step per burst, chips and list
/// edits as a unit. The editor sits in a window so it gets the window's undo manager, as in the app.
@MainActor struct ComposerUndoTests {
    private func host(rich: Bool) -> (NSWindow, ComposerEditor) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        editor.chipLook = ComposerChipLook.basic
        editor.richTextEnabled = rich
        window.contentView = editor
        window.makeFirstResponder(editor)
        return (window, editor)
    }

    /// One key per event: the undo manager closes its group when the event's run loop pass ends.
    private func type(_ text: String, into editor: ComposerEditor) {
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.main.run(mode: .default, before: Date())
        }
    }

    private func returnKey(_ editor: ComposerEditor) throws {
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: key)
        RunLoop.main.run(mode: .default, before: Date())
    }

    /// Edit > Undo: the action goes up the responder chain from the editor to the window's undo manager.
    private func undo(_ editor: ComposerEditor) {
        #expect(editor.tryToPerform(Selector(("undo:")), with: nil))
        RunLoop.main.run(mode: .default, before: Date())
    }

    private func redo(_ editor: ComposerEditor) {
        #expect(editor.tryToPerform(Selector(("redo:")), with: nil))
        RunLoop.main.run(mode: .default, before: Date())
    }

    @Test(arguments: [false, true]) func typingBurstUndoesAsOneStep(rich: Bool) {
        let (window, editor) = host(rich: rich)
        editor.setText("draft")
        type(" more words", into: editor)
        #expect(editor.expandedText == "draft more words")
        #expect(editor.undoManager === window.undoManager)
        #expect(window.undoManager?.canUndo == true)
        undo(editor)
        #expect(editor.expandedText == "draft")
        redo(editor)
        #expect(editor.expandedText == "draft more words")
        window.contentView = nil
    }

    /// The editor serves every thread: a draft set in code (a thread switch, a sent prompt, history) starts a fresh
    /// history, so Cmd+Z can't replay another draft's typing onto this one.
    @Test(arguments: ["", "other draft"]) func swappedDraftStartsAFreshHistory(next: String) {
        let (window, editor) = host(rich: true)
        editor.setText("")
        type("hello there", into: editor)
        editor.setText(next)
        #expect(window.undoManager?.canUndo == false)
        type(" typed", into: editor)
        undo(editor)
        #expect(editor.expandedText == next)
        undo(editor)
        #expect(editor.expandedText == next)
        type("!", into: editor)
        undo(editor)
        #expect(editor.expandedText == next)
        window.contentView = nil
    }

    @Test func caretMoveStartsANewStep() {
        let (window, editor) = host(rich: true)
        editor.setText("")
        type("one", into: editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        type("two ", into: editor)
        #expect(editor.expandedText == "two one")
        undo(editor)
        #expect(editor.expandedText == "one")
        undo(editor)
        #expect(editor.expandedText == "")
        window.contentView = nil
    }

    @Test func richTextMarksUndoWithTheirTyping() {
        let (window, editor) = host(rich: true)
        editor.setText("")
        type("**bold** x", into: editor)
        #expect(editor.expandedText == "**bold** x")
        #expect(editor.string == "bold x")
        undo(editor)
        #expect(editor.expandedText == "")
        window.contentView = nil
    }

    @Test func chipUndoesAsAUnit() {
        let (window, editor) = host(rich: true)
        editor.setText("see ")
        type("@README.md ", into: editor)
        #expect(editor.expandedText == "see @README.md ")
        #expect(editor.string.contains("\u{FFFC}"))
        // The first step may turn the chip back into its typed text, as undoing an autocorrection does.
        undo(editor)
        #expect(!editor.string.contains("\u{FFFC}"))
        if editor.expandedText != "see " { undo(editor) }
        #expect(editor.expandedText == "see ")
        window.contentView = nil
    }

    @Test func listContinuationUndoesAsAUnit() throws {
        let (window, editor) = host(rich: true)
        editor.setText("- a")
        try returnKey(editor)
        #expect(editor.expandedText != "- a")
        undo(editor)
        #expect(editor.expandedText == "- a")
        window.contentView = nil
    }
}
