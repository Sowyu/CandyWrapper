import AppKit
import Testing
@testable import DesignSystem
import T3Store
@testable import Features

/// Each call site taps once per detent. The helper's own rules (setting, rate limit, events) are in HapticsTests.
@MainActor
struct HapticsCallSiteTests {
    @Test func theRailTapsOncePerTurnItMovesTo() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = DSView(frame: window.contentLayoutRect)
        window.contentView = content
        let map = ThreadMinimapView(frame: NSRect(x: 12, y: 100, width: 40, height: 72))
        content.addSubview(map)
        map.items = (0..<10).map { ThreadMinimapItem(id: "\($0)", rowIndex: $0, userText: "Turn \($0)", assistantText: "Reply \($0)") }
        let host = try #require(map.popupHost)
        defer { host.closeAll(); map.removeFromSuperview(); window.close() }
        window.makeFirstResponder(map)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        // Eleven presses walk turns 0 through 9, then stop at the last.
        let played = Haptics.recording(.keyDown) { for _ in 0..<11 { map.keyDown(with: down) } }
        #expect(played == Array(repeating: .alignment, count: 10))
        // The same moves from a model change, with no event, stay silent.
        map.items = map.items.reversed()
        #expect(Haptics.recording(nil) { map.keyDown(with: down) }.isEmpty)
    }

    @Test func zoomTapsAtOneHundredPercentAndTheLimits() {
        let view = ZoomableImageView(picture: AsyncImageView())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.naturalSize = { CGSize(width: 1600, height: 1200) } // 100% is 2x fit at 2x backing; the limit is 16x
        view.layoutSubtreeIfNeeded()
        let up = Haptics.recording(.magnify) { for _ in 0..<20 { view.zoom(to: view.scale * 1.25) } }
        #expect(view.scale == 16)
        #expect(up == [.alignment, .alignment], "crossing 100%, then the limit; nothing while pinching on past it")
        let down = Haptics.recording(.magnify) { for _ in 0..<20 { view.zoom(to: view.scale / 1.25) } }
        #expect(view.scale == 1)
        #expect(down == [.alignment, .alignment], "crossing 100%, then fit")
    }

    @Test func aSidebarDragTapsOnTheSlotAndOnTheDrop() throws {
        var drops = 0
        let played = try Haptics.recording(.appKitDefined, buttons: 1) {
            let (f, _) = try SidebarSortDragTests().liftFirstAndDragOntoLast { _, _, _ in drops += 1 }
            // Moving within the same slot taps nothing more.
            f.list.moveSort(to: f.list.convert(NSPoint(x: f.list.bounds.midX, y: f.list.rowView("thread:a3")!.frame.midY + 3), to: nil))
            f.list.draggingSession(f.session, endedAt: .zero, operation: .move)
            f.window.contentView = nil
        }
        #expect(drops == 1)
        #expect(played == [.alignment, .generic])
    }
}
