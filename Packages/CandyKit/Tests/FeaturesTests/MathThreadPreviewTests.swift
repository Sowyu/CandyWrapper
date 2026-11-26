import Foundation
import Testing
import T3Protocol
@testable import Features

/// `--thread-preview "Math preview"`: the markdown thread with the math reply in place of its own.
struct MathThreadPreviewTests {
    @Test func mathThreadCarriesTheFormulas() throws {
        let p = try #require(try ThreadPreview.projection(titled: ThreadPreview.mathThread))
        #expect(p.thread.title == ThreadPreview.mathThread)
        #expect(p.messages.contains { $0.role == "assistant" && $0.text == ThreadPreview.mathReply })
        #expect(!p.messages.contains { $0.text.contains("Demo heading") })
    }
}
