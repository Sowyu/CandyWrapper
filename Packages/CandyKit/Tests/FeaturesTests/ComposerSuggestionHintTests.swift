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
}
