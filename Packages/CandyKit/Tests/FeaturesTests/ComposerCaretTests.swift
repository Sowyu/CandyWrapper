import AppKit
import Testing
@testable import Features

/// Chromium's caret and selection band in the prompt (ComposerCaretView).
@MainActor
struct ComposerCaretTests {
    @Test func caretIsOnePixelTheFontsHeightAndBlinksHard() {
        let editor = ComposerEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        editor.setText("Tt\nsecond")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let first = editor.caretRect()
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        let second = editor.caretRect()
        #expect(first?.width == 1)
        let font = ComposerEditor.font // ascent and descent, each rounded to device pixels (2x off screen)
        #expect(first?.height == (font.ascender * 2).rounded() / 2 + (-font.descender * 2).rounded() / 2)
        #expect(abs(((second?.minY ?? 0) - (first?.minY ?? 0)) - ComposerEditor.lineHeight) <= 0.5)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(editor.caretRect() == nil)

        let blink = ComposerCaretView.blink
        #expect(blink.calculationMode == .discrete && blink.repeatCount == .infinity && blink.duration == 1)
        #expect(blink.keyTimes == [0, 0.5, 1] && (blink.values as? [Int]) == [1, 0])
    }

    @Test func selectionCoversTheWholeLineBox() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240), styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = ComposerEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        window.contentView?.addSubview(editor)
        editor.setText("one line\nand another")
        #expect(window.makeFirstResponder(editor))
        #expect(editor.selectionBands().isEmpty)
        editor.setSelectedRange(NSRange(location: 0, length: 12))
        let bands = editor.selectionBands()
        #expect(bands.count >= 2)
        for band in bands { #expect(abs(band.height - ComposerEditor.lineHeight) <= 1, "\(band)") }
        // Stacked line boxes: the second band starts where the first ends.
        let rows = Set(bands.map(\.minY)).sorted()
        #expect(rows.count == 2 && abs(rows[1] - rows[0] - ComposerEditor.lineHeight) <= 1)
    }
}
