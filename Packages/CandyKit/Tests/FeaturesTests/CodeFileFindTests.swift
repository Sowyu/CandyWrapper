import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Mod+F in a file source opens the diff view's search panel (ReadOnlySourcePreview.tsx at 5258, #42442).
@MainActor
struct CodeFileFindTests {
    @Test func searchPanelFindsStepsAndCloses() {
        let code = CodeFileView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: code.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = code
        code.setText((0..<400).map { "let value\($0) = Value()" }.joined(separator: "\n"), path: "a.swift")
        code.layoutSubtreeIfNeeded()
        #expect(!code.isFindShown)
        code.showFind()
        #expect(code.isFindShown && window.firstResponder === code.findWidget.field.editor)
        code.findWidget.field.text = "value1"
        code.runFind()
        // value1, value10 to value19, value100 to value199.
        #expect(code.findMatches.count == 111)
        #expect(code.findWidget.countText == "1 of 111")
        code.findWidget.wholeWord.isPressed = true
        code.runFind()
        #expect(code.findMatches.count == 1)
        code.findWidget.wholeWord.isPressed = false
        code.findWidget.field.text = "VALUE39\\d"
        code.findWidget.regex.isPressed = true
        code.runFind()
        #expect(code.findMatches.count == 10)
        code.stepFind(-1)
        #expect(code.findIndex == 9 && code.findWidget.countText == "10 of 10")
        // The last match scrolled into view under the 300pt viewport.
        #expect(code.scrollView.contentView.bounds.minY > 6000, "\(code.scrollView.contentView.bounds) \(code.textView.frame)")
        code.findWidget.matchCase.isPressed = true
        code.runFind()
        #expect(code.findMatches.isEmpty && code.findWidget.countText == "No results")
        code.closeFind()
        #expect(!code.isFindShown && code.findMatches.isEmpty && window.firstResponder === code.textView)
    }
}
