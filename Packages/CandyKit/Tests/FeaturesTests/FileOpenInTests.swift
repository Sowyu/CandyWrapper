import AppKit
import Testing
@testable import Features

/// The file header's Open in picker: `fileManagerActionForPath` (5258 OpenInPicker.logic.test.ts, #41877) and the
/// picker's looks.
@MainActor @Suite struct FileOpenInTests {
    @Test func fileManagerOpensFoldersAndRevealsSettledFiles() {
        #expect(OpenInEditors.fileManagerAction(isFolder: true, isSettled: false, canReveal: false) == .open)
        #expect(OpenInEditors.fileManagerAction(isFolder: false, isSettled: false, canReveal: true) == .unavailable)
        #expect(OpenInEditors.fileManagerAction(isFolder: false, isSettled: true, canReveal: false) == .unavailable)
        #expect(OpenInEditors.fileManagerAction(isFolder: false, isSettled: true, canReveal: true) == .reveal)
    }

    @Test func pickerSitsLeftOfTheHeaderToggles() {
        let surface = FileSurfaceView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        surface.show(path: "src/answer.ts", revealLine: nil)
        surface.setContent(.text("x", truncated: false, byteLength: 1, editable: true))
        #expect(surface.openIn.isHidden)
        surface.showsOpenIn = true
        surface.layoutSubtreeIfNeeded()
        #expect(!surface.openIn.isHidden)
        // Outline xs icon button, separator, icon-xs chevron: 30 + 1 + 24 at most, 24pt tall.
        #expect(surface.openIn.intrinsicContentSize.height == 24)
        #expect(surface.openIn.intrinsicContentSize.width <= 56)
        #expect(surface.openIn.primary.accessibilityLabel() == "Open file in preferred editor")
        #expect(surface.openIn.chevron.accessibilityLabel() == "Choose editor")
    }
}
