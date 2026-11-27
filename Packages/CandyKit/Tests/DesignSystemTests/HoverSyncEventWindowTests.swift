import AppKit
import Testing
@testable import DesignSystem

/// A pointer move reads the window under the pointer from the event's own WindowServer stamp, so hover asks the
/// WindowServer nothing per move. A user's sample (2026-11-27) had 108 of 123 `mouseMoved` samples in that round trip.
@MainActor
struct HoverSyncEventWindowTests {
    private func moved(stamp: Int64?) -> NSEvent? {
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 40, y: 40),
                               mouseButton: .left) else { return nil }
        if let stamp { cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: stamp) }
        return NSEvent(cgEvent: cg)
    }

    @Test func aStampedMoveNamesItsWindow() throws {
        let event = try #require(moved(stamp: 4242))
        #expect(HoverSync.windowTakingEvent(event) == 4242)
    }

    @Test func anUnstampedMoveFallsBackToAsking() throws {
        let event = try #require(moved(stamp: nil))
        #expect(HoverSync.windowTakingEvent(event) == nil)
    }
}
