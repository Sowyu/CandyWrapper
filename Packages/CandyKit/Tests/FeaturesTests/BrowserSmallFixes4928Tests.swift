import AppKit
import Testing
import T3Protocol
@testable import Features

/// The 4928 browser small fixes CandyWrapper ports: Stop, default zoom and appearance on a new tab, the mini
/// player's inward resize, and Edit menu Copy into a server tab.
@MainActor
struct BrowserSmallFixes4928Tests {
    @Test func wireFields() {
        #expect(PreviewStream.Input.stopLoading.json == .object(["type": .string("stopLoading")]))
        let open = PreviewRPC.openPayload(threadId: "t", zoomFactor: .number(1.25), colorScheme: "dark")
        #expect(open["zoomFactor"] == .number(1.25) && open["colorScheme"] == .string("dark"))
        #expect(PreviewRPC.openPayload(threadId: "t")["zoomFactor"] == nil)
    }

    /// #26027: a player the container squeezed under 240pt does not jump up to it on an inward drag.
    @Test func inwardResizeKeepsASmallPlayer() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 125)
        let r = BrowserMiniPlayerResizeDirection.east.resized(start, delta: CGPoint(x: -10, y: 0), container: CGSize(width: 1000, height: 800))
        #expect(r.width == 200)
    }
}
