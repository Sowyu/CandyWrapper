import AppKit
import Testing
@testable import Features

/// `htmlPreviewWidth` (5258 chatCanvasLayout.ts:180-193, #41663): an HTML preview runs wider than the chat lane,
/// centered on it while that fits and clear of the details card.
@MainActor
struct HtmlPreviewWidthTests {
    let lane: (x: CGFloat, width: CGFloat) = (432, 736)

    @Test func matchChatKeepsTheLane() {
        let r = TimelineView.htmlPreviewLane(lane, setting: "chat", canvasWidth: 1600, padding: 48, cardLeft: nil)
        #expect(r.x == 432 && r.width == 736)
    }

    @Test func wideCentersUpTo72rem() {
        let r = TimelineView.htmlPreviewLane(lane, setting: "wide", canvasWidth: 1600, padding: 48, cardLeft: nil)
        #expect(r.width == 1152 && r.x == 224)
        // A canvas narrower than 72rem: the preview fills it less the padding.
        let narrow = TimelineView.htmlPreviewLane((132, 736), setting: "wide", canvasWidth: 1000, padding: 48, cardLeft: nil)
        #expect(narrow.width == 904 && narrow.x == 48)
    }

    @Test func fullFillsTheCanvasAndStopsAtTheDetailsCard() {
        let r = TimelineView.htmlPreviewLane(lane, setting: "full", canvasWidth: 1600, padding: 48, cardLeft: nil)
        #expect(r.width == 1504 && r.x == 48)
        let card = TimelineView.htmlPreviewLane((300, 736), setting: "full", canvasWidth: 1600, padding: 48, cardLeft: 1300)
        #expect(card.width == 1220 && card.x == 48)
        // Never narrower than the chat lane.
        let tight = TimelineView.htmlPreviewLane((48, 736), setting: "full", canvasWidth: 900, padding: 48, cardLeft: 810)
        #expect(tight.x == 48 && tight.width == 736)
    }
}
