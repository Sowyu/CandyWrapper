import AppKit
import Testing
@testable import Features

/// #27287 (useFocusComposerOnThreadOpen.browser.test.tsx at 4928): a rename started by the double click keeps focus.
@MainActor struct SidebarRenameFocusTests {
    @Test func seesFocusInsideTheRenameFieldOnly() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let field = SidebarRenameFieldView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        #expect(!SidebarRenameFocus.isActive(in: window))
        field.focus()
        #expect(SidebarRenameFocus.isActive(in: window))
        #expect(!SidebarRenameFocus.isActive(in: nil))
    }
}
