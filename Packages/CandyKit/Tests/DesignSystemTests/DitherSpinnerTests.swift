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

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) func sweepStopsWhenTheWindowIsCoveredOrDisplayOptionsChange() {
        let window = StubWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        let spinner = DotGridSpinnerView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(!spinner.sweepingForTesting)
        window.contentView?.addSubview(spinner)
        #expect(spinner.sweepingForTesting)

        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window); settle()
        #expect(!spinner.sweepingForTesting)
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window); settle()
        #expect(spinner.sweepingForTesting)

        // A Reduce Motion change arrives as this notification; the loop rechecks then.
        window.shown = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil); settle()
        #expect(!spinner.sweepingForTesting)
        spinner.removeFromSuperview()
    }
}
