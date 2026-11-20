import AppKit
import Testing
import DesignSystem
@testable import Features

/// Redesign sizes each notice to its `pillWidth`. The reply banner, whose only action is the X, came out narrower
/// than `layout()` needs for the actions column (`min-w-12`, #22236), so the response's opening was swapped for the
/// details button. At its own pill width a banner shows its whole description.
@MainActor @Suite struct ReplyBannerPillTests {
    @Test func replyPillShowsTheResponseOpening() {
        let banner = ComposerNoticeBannerView()
        banner.appearance = NSAppearance(named: .darkAqua)
        banner.apply(.init(variant: .neutral, icon: .reply, title: "Replying to", dismissLabel: "Cancel reply",
                           descriptionParts: [.init(text: "Apple", link: "Apple")]))
        banner.frame = NSRect(x: 0, y: 0, width: banner.pillWidth, height: ComposerNoticeBannerView.height)
        banner.layoutSubtreeIfNeeded()
        #expect(banner.detailsButton.isHidden, "pill \(banner.pillWidth)")
        #expect(banner.subviews.contains { ($0 as? LabelView)?.text == "Apple" && !$0.isHidden || ($0 as? ThreadStatusLineAction).map { !$0.isHidden } == true })
    }
}
