import AppKit
import Foundation
import Testing
@testable import Features
import T3Protocol
import T3Store

/// The composer section rows of the 4928 catch-up (docs/research/nightly-diff-4928-commits.md).
@MainActor
struct Composer4928SectionTests {
    /// #34784: a Claude option's `preview` decodes and adds its own lines under the option.
    @Test func optionPreviewShowsUnderItsOption() throws {
        let json = #"{"id":"q1","header":"Issue","question":"Approve this issue?","options":[{"label":"Approve","description":"File it.","preview":"Title: Login fails\n\nBody: A quote breaks login."},{"label":"Cancel","description":"Do not file it."}]}"#
        let question = try JSONDecoder().decode(UserInputQuestion.self, from: Data(json.utf8))
        #expect(question.options.first?.preview?.hasPrefix("Title:") == true)
        #expect(question.options.last?.preview == nil)
        func height(_ q: UserInputQuestion) -> CGFloat {
            let panel = QuestionPanelView()
            panel.configure(PendingUserInput(requestId: "r", questions: [q]), threadId: "t")
            return panel.preferredHeight(width: 600)
        }
        var plain = question
        plain.options[0].preview = nil
        // Markdown since tail-1: two 16pt paragraphs 0.65rem apart and the 6pt `pb-1.5`.
        #expect(abs(height(question) - height(plain) - (16 + 10.4 + 16 + 6)) < 0.5)
    }
}
