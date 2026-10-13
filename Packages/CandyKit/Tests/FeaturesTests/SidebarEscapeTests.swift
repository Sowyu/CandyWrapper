import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Escape drops the sidebar's multi-selection (_chat.tsx:98-102), but with a dialog open ("Close terminal?") the
/// dialog takes Escape and closes. The sidebar's handler used to take it first, so the dialog stayed open.
@MainActor
struct SidebarEscapeTests {
    @Test func openDialogKeepsEscape() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = DSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let sidebar = SidebarContentView()
        sidebar.setSnapshot(SidebarPreview.richSnapshot(), animated: false)
        sidebar.toggleSelection(ThreadId("r3"))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(escape.window === window)
        let host = ModalHost.present(DialogView(kind: .alertDialog, title: "Close terminal?"), in: window, blurBackdrop: false)
        #expect(!sidebar.escapeClearsSelection(escape))
        #expect(sidebar.selectedThreadIds == [ThreadId("r3")])
        host.close(animated: false)
        #expect(sidebar.escapeClearsSelection(escape))
        #expect(sidebar.selectedThreadIds.isEmpty)
    }
}
