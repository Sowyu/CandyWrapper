import AppKit
import Testing
@testable import Features

/// The Tab hint after a prompt suggestion is a button (T3 5258 ChatComposer.tsx:3978-3997, #39488, #40841).
@MainActor
struct ComposerSuggestionHintTests {
    @Test func clickingTheHintTakesTheSuggestionOnlyIntoAnEmptyPrompt() {
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        composer.promptSuggestion = "Run the tests"
        composer.layoutSubtreeIfNeeded()
        let hint = composer.subviews.compactMap { $0 as? PromptSuggestionHintButton }.first
        #expect(hint?.accessibilityLabel() == "Use suggested prompt")
        hint?.performAction()
        #expect(composer.text == "Run the tests")
        // A late click never prepends it to a draft that has text.
        composer.acceptSuggestionFromHint()
        #expect(composer.text == "Run the tests")
    }

    /// #40654 (ComposerPromptEditorTiptap.tsx:1924-1980 at 5258): a suggestion that wraps makes the composer taller, so
    /// it never runs under the toolbar.
    @Test func aWrappedSuggestionGrowsTheComposer() {
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        composer.layoutSubtreeIfNeeded()
        let plain = composer.preferredHeight
        composer.promptSuggestion = "Write a migration that moves every project setting into the new table, then run the tests and fix what fails"
        composer.layoutSubtreeIfNeeded()
        let placeholder = composer.placeholder
        #expect(placeholder.frame.height > 3 * 20)
        #expect(composer.preferredHeight > plain)
        composer.frame.size.height = composer.preferredHeight
        composer.layoutSubtreeIfNeeded()
        let footerTop = composer.attach.frame.minY
        #expect(placeholder.frame.maxY <= footerTop + 0.5)
    }
}
