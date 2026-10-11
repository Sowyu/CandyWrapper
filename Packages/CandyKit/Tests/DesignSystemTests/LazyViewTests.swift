import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct LazyViewTests {
    @Test func buildsOnFirstUseWithWaitingSetupsAndRebuildsAfterRelease() {
        var made = 0
        let lazy = LazyView { made += 1; return NSView() }
        lazy.set(\.toolTip, "first")
        lazy.set(\.toolTip, "last")
        var configured = 0
        lazy.configure { _ in configured += 1 }
        #expect(made == 0 && lazy.loaded == nil)
        #expect(lazy.view.toolTip == "last" && made == 1 && configured == 1)
        lazy.set(\.toolTip, "live")
        #expect(lazy.loaded?.toolTip == "live")
        let parent = NSView()
        parent.addSubview(lazy.view)
        lazy.release()
        #expect(lazy.loaded == nil && parent.subviews.isEmpty)
        #expect(lazy.view.toolTip == "live" && made == 2 && configured == 2)
    }
}
