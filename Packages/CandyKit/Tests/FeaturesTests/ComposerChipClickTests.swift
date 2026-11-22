import AppKit
import Testing
@testable import Features

/// Reading `NSTextView.layoutManager` switches the view to TextKit 1 for good. TextKit 1 then draws
/// every chip with AppKit's default attachment cell, a blank page icon, and `caretRect()` finds no
/// TextKit 2 layout, so the composer's caret stays hidden.
@MainActor struct ComposerChipClickTests {
    @Test func clickingAChipKeepsTheEditorOnTextKit2() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let editor = ComposerEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        editor.chipLook = ComposerChipLook.basic
        editor.richTextEnabled = true
        window.contentView = editor
        editor.setText("@README.md and more")
        #expect(editor.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) is ComposerChipAttachment)
        // `mouseDown` places the anchor before it opens a chip's popover.
        editor.placeChipAnchor(at: 0)
        #expect(editor.textLayoutManager != nil)
        #expect(editor.chipAnchor.frame.width > 0)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(editor.caretRect() != nil)
    }
}
