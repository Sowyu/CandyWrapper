import AppKit
import Testing
@testable import Features

/// Ordered numbers and quote rails are painted in the editor's background (`drawBlockDecorations`), which TextKit 2
/// never repaints on an edit: numbers of deleted or moved items stayed on screen until the composer changed height.
@MainActor struct ComposerBlockDecorationRedrawTests {
    private func host(_ text: String) -> (NSWindow, ComposerEditor) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        editor.chipLook = ComposerChipLook.basic
        editor.richTextEnabled = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.setText(text)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        paint(window, editor)
        return (window, editor)
    }

    /// A layer-backed view reports `needsDisplay` false; its layer knows. A window off screen never commits its
    /// layers, so the test draws them itself.
    private func repaints(_ editor: ComposerEditor) -> Bool { editor.layer?.needsDisplay() == true }
    private func paint(_ window: NSWindow, _ editor: ComposerEditor) {
        window.displayIfNeeded()
        editor.layer?.displayIfNeeded()
    }

    @Test func deletingAnOrderedItemRepaintsTheNumbers() {
        let (window, editor) = host("1. a\n2. b")
        #expect(!repaints(editor))
        // `b`, then the empty item leaves the list, then the line joins the one before.
        for _ in 0..<3 {
            editor.deleteBackward(nil)
            #expect(repaints(editor))
            paint(window, editor)
        }
        #expect(editor.expandedText == "1. a")
    }

    @Test func deletingTheLastItemRepaintsItsNumber() {
        let (_, editor) = host("1. a")
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        #expect(editor.expandedText == "")
        #expect(repaints(editor))
    }

    @Test func typingAboveANumberedListRepaintsTheNumbers() {
        let (_, editor) = host("intro\n1. a\n2. b")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(repaints(editor))
    }

    @Test func deletingAQuoteRepaintsItsRail() {
        let (_, editor) = host("> a")
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        #expect(editor.expandedText == "")
        #expect(repaints(editor))
    }

    @Test func aNewDraftRepaintsTheOldNumbers() {
        let (_, editor) = host("1. a\n2. b")
        editor.setText("plain")
        #expect(repaints(editor))
    }

    @Test func plainTypingLeavesTheBackgroundAlone() {
        let (_, editor) = host("plain words")
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!repaints(editor))
    }
}
