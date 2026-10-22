import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct PullRequestViewedPerformanceTests {
    @Test func viewedMarksKeepMountedCodeRows() throws {
        let view = PullRequestCodeView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.set(patches: ["""
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,3 @@
         let a = 1
        +let b = 2
         let c = 3

        """], loading: false, error: nil, nextCursor: nil, moreLoading: false, moreError: nil, commit: nil, commits: [])
        view.layoutSubtreeIfNeeded()
        let list = try #require(view.subviews.compactMap { $0 as? ScrollAreaView }
            .compactMap { $0.scrollView.documentView as? DiffListView }.first)
        let header = try #require(list.subviews.compactMap { $0 as? DiffFileHeaderView }.first)
        let configured = list.configuredRowViews
        let created = list.createdRowViews
        #expect(configured > 1)

        view.setViewed(states: ["file.swift": "viewed"], overlay: [:], store: "host")
        view.layoutSubtreeIfNeeded()
        #expect(!header.viewedBox.isHidden)
        #expect(header.viewedBox.value == .on)
        #expect(list.configuredRowViews == configured) // Previously every mounted row was configured again.
        #expect(list.createdRowViews == created)

        view.setViewed(states: ["file.swift": "dismissed"], overlay: [:], store: "host")
        #expect(header.viewedBox.value == .off)
        #expect(header.viewedLabel.text == "Changed")
        view.setViewed(states: ["file.swift": "dismissed"], overlay: ["file.swift": true], store: "host")
        #expect(header.viewedBox.value == .on)
        view.setViewed(states: nil, overlay: [:], store: nil)
        #expect(header.viewedBox.isHidden)
        #expect(list.configuredRowViews == configured)
    }
}
