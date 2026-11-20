import AppKit
import Testing
import DesignSystem
@testable import Features

/// The rail stayed in its hovered fisheye after the card closed or the pointer left (v1.14.14, Redesign). Every exit
/// that can be driven offscreen must leave the rail pixel-identical to one that was never hovered.
@MainActor
struct ThreadMinimapHoverTests {
    private func makeRail() -> (NSWindow, ThreadMinimapView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let content = DSView(frame: window.contentLayoutRect)
        window.contentView = content
        let map = ThreadMinimapView(frame: NSRect(x: 12, y: 100, width: 40, height: 72))
        content.addSubview(map)
        map.items = (0..<10).map { ThreadMinimapItem(id: "\($0)", rowIndex: $0 * 2, userText: "Turn \($0)", assistantText: "Reply \($0)") }
        map.inView = IndexSet(7...9)
        return (window, map)
    }

    private func pixels(_ map: ThreadMinimapView) throws -> Data {
        let rep = try #require(map.bitmapImageRepForCachingDisplay(in: map.bounds))
        map.cacheDisplay(in: map.bounds, to: rep)
        return try #require(rep.tiffRepresentation)
    }

    private func key(_ code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    enum Exit: CaseIterable { case cardClosedFromOutside, exitOverTheRail, focusLeaves, railHides }

    @Test(arguments: Exit.allCases)
    func everyExitReturnsTheRailToRest(_ exit: Exit) throws {
        let (window, map) = makeRail()
        let host = try #require(map.popupHost)
        defer { host.closeAll(); map.removeFromSuperview(); window.close() }
        let resting = try pixels(map)
        // Hover the fifth turn from the keyboard: the fisheye and the card show.
        window.makeFirstResponder(map)
        for _ in 0..<5 { map.keyDown(with: key(125, in: window)) }
        #expect(try pixels(map) != resting, "the hover draws the fisheye")
        #expect(host.popups.count == 1, "the hover opens the card")
        switch exit {
        case .cardClosedFromOutside:
            // A click anywhere, Escape or another hover card closes the card through the host.
            host.closeAll()
        case .exitOverTheRail:
            // HoverSync's exit carries the pointer position, which can still be on the rail or the card.
            let point = map.convert(NSPoint(x: 4, y: 36), to: nil)
            map.mouseExited(with: try #require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
                                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        case .focusLeaves:
            window.makeFirstResponder(nil)
        case .railHides:
            map.isHidden = true
            map.isHidden = false
        }
        #expect(host.popups.isEmpty, "the card closes")
        #expect(try pixels(map) == resting, "the rail is back to rest")
    }
}
