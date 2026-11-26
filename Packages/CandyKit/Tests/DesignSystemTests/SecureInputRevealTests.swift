import AppKit
import Testing
@testable import DesignSystem

/// The secret card's show/hide eye (SecretRequestCard.tsx:331-372 at 5258): the text survives both ways, the shown
/// copy is wiped when it hides, and a focused field keeps its selection (#42309).
@MainActor
struct SecureInputRevealTests {
    @Test func eyeShowsAndHidesTheSameTextAndKeepsTheSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let input = SecureInputView(placeholder: "sk-...")
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
        window.contentView?.addSubview(input)
        input.revealLabel = "Show API key"
        input.text = "secret-value"
        input.layoutSubtreeIfNeeded()
        let eye = try #require(input.subviews.compactMap { $0 as? ButtonView }.first)
        #expect(eye.accessibilityLabel() == "Show API key")
        #expect(eye.frame.maxX == 296 && eye.frame.width == 24)

        #expect(window.makeFirstResponder(input))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectedRange = NSRange(location: 3, length: 2)

        eye.action?()
        #expect(input.revealed && input.text == "secret-value")
        let plain = try #require(input.subviews.first { $0 is NSTextField && !($0 is NSSecureTextField) } as? NSTextField)
        #expect(!plain.isHidden && plain.stringValue == "secret-value")
        #expect((window.firstResponder as? NSTextView)?.selectedRange == NSRange(location: 3, length: 2))

        eye.action?()
        #expect(!input.revealed && input.text == "secret-value")
        #expect(plain.isHidden && plain.stringValue.isEmpty)
        #expect((window.firstResponder as? NSTextView)?.selectedRange == NSRange(location: 3, length: 2))
    }
}
