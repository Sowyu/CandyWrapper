import AppKit
import Testing
import DesignSystem
@testable import Features

private final class HighlightCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
}

@MainActor
struct ComposerHighlightWorkTests {
    @Test func longFenceTypingTokenizesOnceAfterTheBurst() async {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        let calls = HighlightCalls()
        editor.tokenizeCodeBlock = { text, language in
            calls.record()
            return CodeHighlighter.tokens(text, language: language)
        }
        let body = String(repeating: "let value = 1\n", count: 200)
        editor.setText("```swift\n\(body)```\n")
        await editor.codeHighlightTask?.value
        calls.reset()
        for _ in 0..<8 {
            let at = (editor.string as NSString).range(of: "value").location
            editor.insertText("x", replacementRange: NSRange(location: at, length: 0))
            // Give immediate tokenization a chance to run between keystrokes.
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(calls.value == 0)
        let at = (editor.string as NSString).range(of: "let").location
        let expected = CodeHighlighter.tokens("let value = 1", language: "swift").first?.kind.color
        #expect(editor.textStorage?.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == expected)
        await editor.codeHighlightTask?.value
        #expect(calls.value == 1)
        #expect(editor.textStorage?.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == expected)
    }

    @Test func replacingADraftCancelsItsPendingHighlight() async {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        let calls = HighlightCalls()
        editor.tokenizeCodeBlock = { _, _ in calls.record(); return [] }
        editor.setText("```swift\n\(String(repeating: "x", count: 3_000))\n```")
        let pending = editor.codeHighlightTask
        editor.setText("another draft")
        await pending?.value
        #expect(calls.value == 0)
        #expect(editor.expandedText == "another draft")
    }

    @Test func hiddenEditorCancelsPendingTokenization() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let editor = ComposerEditor()
        window.contentView?.addSubview(editor)
        editor.richTextEnabled = true
        let calls = HighlightCalls()
        editor.tokenizeCodeBlock = { _, _ in calls.record(); return [] }
        editor.setText("```swift\n\(String(repeating: "x", count: 3_000))\n```")
        let at = (editor.string as NSString).range(of: String(repeating: "x", count: 3)).location
        editor.insertText("y", replacementRange: NSRange(location: at, length: 0))
        let pending = editor.codeHighlightTask
        editor.removeFromSuperview()
        await pending?.value
        #expect(calls.value == 0)
    }

    @Test func refreshClearsColorsNoLongerCoveredByTokens() async {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        editor.setText("```swift\n\(String(repeating: "let value = 1\n", count: 200))```\n")
        await editor.codeHighlightTask?.value
        let at = (editor.string as NSString).range(of: "let").location
        let before = editor.textStorage?.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
        editor.tokenizeCodeBlock = { _, _ in [] }
        editor.insertText("x", replacementRange: NSRange(location: at + 4, length: 0))
        #expect(editor.textStorage?.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == before)
        await editor.codeHighlightTask?.value
        let plain = editor.textStorage?.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
        #expect(plain?.usingColorSpace(.sRGB) == Themed.color(\.foreground).usingColorSpace(.sRGB))
    }

    @Test func shortFenceUpdatesBeforeTheLongFenceInTheSameDraft() async {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        editor.setText("```swift\nshort\n```\n\n```swift\n\(String(repeating: "long ", count: 600))\n```\n")
        await editor.codeHighlightTask?.value
        let calls = HighlightCalls()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        editor.tokenizeCodeBlock = { text, _ in
            calls.record()
            if text.utf16.count <= 2_000 { continuation.yield(()) }
            return []
        }
        let at = (editor.string as NSString).range(of: "short").location
        editor.insertText("x", replacementRange: NSRange(location: at, length: 0))
        var iterator = stream.makeAsyncIterator()
        await iterator.next()
        #expect(calls.value == 1)
        await editor.codeHighlightTask?.value
        #expect(calls.value == 2)
    }

    @Test func shortFencesStillHighlight() async {
        let editor = ComposerEditor()
        editor.richTextEnabled = true
        let calls = HighlightCalls()
        editor.tokenizeCodeBlock = { _, _ in calls.record(); return [] }
        editor.setText("```swift\nlet x = 1\n```")
        await editor.codeHighlightTask?.value
        #expect(calls.value == 1)
    }
}
