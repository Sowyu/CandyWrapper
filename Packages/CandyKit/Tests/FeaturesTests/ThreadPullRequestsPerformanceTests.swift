import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
@testable import Features

@MainActor
struct ThreadPullRequestsPerformanceTests {
    private func links(_ count: Int) -> [ThreadPullRequestLink] {
        (1...count).map {
            ThreadPullRequestLink(host: "github.com", repository: "sandbox/project", number: $0,
                                  url: "https://github.com/sandbox/project/pull/\($0)", source: .manual,
                                  linkedAt: T3Timestamp("2026-10-10T16:00:00Z"))
        }
    }

    @Test func largeLinkedListMountsOnlyViewportAndReusesRows() throws {
        let view = ThreadPullRequestsListView(frame: NSRect(x: 0, y: 0, width: 400, height: 420))
        view.set(links(1_000), nowMs: 0)
        view.layoutSubtreeIfNeeded()
        let area = try #require(view.subviews.compactMap { $0 as? ScrollAreaView }.first)
        let document = try #require(area.scrollView.documentView)
        let height = PullRequestRowView.panelHeight
        #expect(document.frame.height == 12 + 1_000 * height)
        #expect(view.liveRowViews > 0)
        #expect(view.createdRowViews < 30) // Before virtualization this allocated all 1,000.

        area.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 500 * height))
        area.scrollView.reflectScrolledClipView(area.scrollView.contentView)
        #expect(view.liveRowViews < 30)
        #expect(view.createdRowViews < 30)
        let row = try #require(document.subviews.compactMap { $0 as? PullRequestRowView }
            .first { $0.frame.minY == 6 + 500 * height })
        var selected: Int?
        view.onOpen = { selected = $0.number }
        _ = row.accessibilityPerformPress()
        #expect(selected == 501)
        let created = view.createdRowViews
        view.set(links(1_000), nowMs: 1_000)
        view.layoutSubtreeIfNeeded()
        #expect(view.createdRowViews == created)

        var changed = links(1_000)
        changed[500].number = 2_001
        changed[500].url = "https://github.com/sandbox/project/pull/2001"
        view.set(changed, nowMs: 1_000)
        view.layoutSubtreeIfNeeded()
        _ = row.accessibilityPerformPress()
        #expect(selected == 2_001)
        #expect(view.createdRowViews == created)

        view.set([], nowMs: 1_000)
        view.layoutSubtreeIfNeeded()
        #expect(view.liveRowViews == 0)
    }
}
