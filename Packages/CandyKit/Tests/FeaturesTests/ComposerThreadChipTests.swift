import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Composer thread chips at 5258: the invalid state for a thread on another machine (composerContextPresentation.tsx:492-505)
/// and the hover card's warning (ThreadChipHoverCard.tsx:78-88).
@MainActor
struct ComposerThreadChipTests {
    @Test func unreadableThreadTakesTheInvalidState() {
        let record = ComposerContext.threadRecord(threadId: "t1", title: "Fix the build", environmentId: "far")
        let token = ComposerInlineToken(kind: .context(kind: "thread", contextId: record["contextId"]!.stringValue!, label: "Fix the build"), source: "[Fix the build](t3-context://v1/thread/x)",
                                        range: NSRange(location: 0, length: 1))
        let look = { (unreadable: Bool) in
            ComposerChipLook.look(for: token, skillLabel: { $0 }, record: { _ in record }, threadUnreadable: { _ in unreadable })
        }
        #expect(look(true).state == .invalid && look(true).threadRecord == record)
        #expect(look(false).state == nil)
    }

    @Test func hoverCardWarnsAboutAnotherMachine() {
        var model = SidebarThreadHoverCardModel(title: "Fix the build")
        model.unreadable = true
        let card = SidebarThreadHoverCardView(model)
        func texts(_ v: NSView) -> [String] {
            ((v as? TextBlockView).map { [$0.text] } ?? []) + v.subviews.flatMap(texts)
        }
        #expect(texts(card).contains("On another machine, so this machine's agent can't read it. Remove it or switch back to send."))
        let plain = SidebarThreadHoverCardView(SidebarThreadHoverCardModel(title: "Fix the build"))
        #expect(card.popupSize.height > plain.popupSize.height)
    }
}
