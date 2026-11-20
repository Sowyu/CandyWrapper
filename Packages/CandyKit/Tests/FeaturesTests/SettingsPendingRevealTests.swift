import AppKit
import Testing
import DesignSystem
@testable import Features

/// Searching "issue trackers" opened Source control at the top: the jump came before the Issue trackers section,
/// which loads its data first, had shown. T3 scrolls from the target's ref callback once it mounts
/// (`useSettingsSearchTarget`, settingsLayout.tsx:159-170 at 4928). The page now scrolls once the section shows.
@MainActor @Suite struct SettingsPendingRevealTests {
    final class TallPage: NSView, SettingsGroupRow {
        let target = NSView()
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            target.frame = NSRect(x: 0, y: 2000, width: 300, height: 40)
            target.isHidden = true
            addSubview(target)
        }
        required init?(coder: NSCoder) { fatalError() }
        func height(forWidth width: CGFloat) -> CGFloat { 3000 }
    }

    static func offset(_ view: NSView) -> CGFloat? {
        if let clip = view as? NSClipView { return clip.bounds.origin.y }
        for sub in view.subviews { if let y = offset(sub) { return y } }
        return nil
    }

    @Test func aJumpToASectionThatShowsLaterScrollsOnceItShows() throws {
        let view = SettingsPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let page = TallPage()
        view.page = page
        view.layoutSubtreeIfNeeded()
        view.reveal(page.target)
        #expect(try #require(Self.offset(view)) == 0)
        // The section's data arrives: it shows and the page reports its new height.
        page.target.isHidden = false
        view.pageChanged()
        #expect(try #require(Self.offset(view)) > 1000)
        // Once only: later height changes leave the user's scroll alone.
        view.scrollToTop()
        view.pageChanged()
        #expect(try #require(Self.offset(view)) == 0)
    }
}
