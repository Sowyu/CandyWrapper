import AppKit
import Testing
@testable import DesignSystem
@testable import Features
import T3Protocol

/// #39648: comment and review author lines are headings for VoiceOver.
@MainActor
struct PullRequestHeadingTests {
    @Test func commentAuthorLinesAreHeadings() {
        let comment = PullRequestComment(id: "c1", kind: "issue-comment", author: nil, body: "Looks good", createdAt: "2026-11-25T10:00:00Z", url: nil)
        let card = CommentCard(comment, nowMs: 1_764_100_000_000, cwd: "/repo")
        card.frame = NSRect(x: 0, y: 0, width: 500, height: card.height(forWidth: 500))
        card.layoutSubtreeIfNeeded()
        #expect(card.heading.accessibilityRole()?.rawValue == "AXHeading")
        #expect(card.heading.accessibilityValue() as? Int == 2)
        #expect(card.heading.accessibilityLabel()?.hasPrefix("ghost, ") == true)
        #expect(card.heading.frame.width > 0 && card.heading.hitTest(NSPoint(x: 20, y: 15)) == nil)
        let issue = CommentCard(comment, nowMs: 1_764_100_000_000, cwd: "/repo", headingLevel: 3)
        #expect(issue.heading.accessibilityValue() as? Int == 3)
    }
}
