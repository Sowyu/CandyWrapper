import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct DitherSpinnerTests {
    /// A window whose visibility the test sets, so the loop's checks don't depend on the real screen.
    final class StubWindow: NSWindow {
        var shown = true
        override var isVisible: Bool { shown }
        override var occlusionState: NSWindow.OcclusionState { shown ? .visible : [] }
    }

    /// `post` returns once every observer ran its block, `.main` ones included, so each check follows its post directly.
    /// Sets the global `Motion.reducedOverride`, so the body stays synchronous on the main actor.
    @Test func sweepStopsWhenTheWindowIsCovered() {
        Motion.reducedOverride = false
        defer { Motion.reducedOverride = nil }
        let window = StubWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        let spinner = DotGridSpinnerView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(!spinner.sweepingForTesting)
        window.contentView?.addSubview(spinner)
        #expect(spinner.sweepingForTesting)
        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!spinner.sweepingForTesting)
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(spinner.sweepingForTesting)
        spinner.removeFromSuperview()
    }
}
