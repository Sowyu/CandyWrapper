import AppKit
import Testing
@testable import Features

/// #26958 (ChatView.tsx:3897-3903 at 4928): a draft's notices float under the composer and never move it.
@MainActor struct DraftNoticeCardsTests {
    @Test func noticesFloatBelowTheDraftComposer() {
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        panel.setDraft(projectTitle: "Demo")
        panel.layoutSubtreeIfNeeded()
        let composer = panel.composer.frame, hero = panel.hero.frame
        panel.noticeBanner.apply(.init(variant: .neutral, icon: .listTodo, title: "Reconnecting"))
        panel.showsNoticeBanner = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.composer.frame == composer)
        #expect(panel.hero.frame == hero)
        let card = panel.noticeBanner
        #expect(!card.isHidden && card.superview === panel && card.placement == .floating)
        let bottom = panel.contextStrip.isHidden ? composer.maxY : panel.contextStrip.frame.maxY
        #expect(card.frame.minY == bottom + 16)
        #expect(card.frame.minX == composer.minX && card.frame.width == composer.width)
    }
}
