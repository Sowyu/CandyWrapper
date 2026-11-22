import AppKit
import Testing
@testable import DesignSystem
import T3Store
@testable import Features

/// Each call site taps once per detent. The helper's own rules (setting, rate limit, events) are in HapticsTests.
@MainActor
struct HapticsCallSiteTests {
    /// The rail ticks once per keyboard move at every level but off, with that level's pattern.
    @Test func theRailKeyTicksFollowTheLevel() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = DSView(frame: window.contentLayoutRect)
        window.contentView = content
        let map = ThreadMinimapView(frame: NSRect(x: 12, y: 100, width: 40, height: 72))
        content.addSubview(map)
        let host = try #require(map.popupHost)
        let saved = (MessageRailHaptic.current, Haptics.now)
        var clock: TimeInterval = 0
        defer { host.closeAll(); map.removeFromSuperview(); window.close(); (MessageRailHaptic.current, Haptics.now) = saved }
        Haptics.now = { clock }
        window.makeFirstResponder(map)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        func walk(_ level: MessageRailHaptic, turns: Int) -> [Haptics.Pattern] {
            MessageRailHaptic.current = { level }
            map.items = (0..<turns).map { ThreadMinimapItem(id: "\($0)-\(level)", rowIndex: $0, userText: "Turn \($0)", assistantText: "Reply") }
            map.currentIndex = 0
            map.resignFirstResponder(); window.makeFirstResponder(map)
            // A second apart, so only the level's stride decides.
            return Haptics.recording(.keyDown) { for _ in 0..<turns { clock += 1; map.keyDown(with: down) } }
        }
        #expect(walk(.strong, turns: 10) == Array(repeating: .alignment, count: 9))
        #expect(walk(.medium, turns: 10) == Array(repeating: .levelChange, count: 9))
        #expect(walk(.light, turns: 100) == Array(repeating: .generic, count: 99), "every turn, however long the thread")
        #expect(walk(.off, turns: 10).isEmpty)
        // The same moves from a model change, with no event, stay silent.
        MessageRailHaptic.current = { .strong }
        map.items = map.items.reversed()
        #expect(Haptics.recording(nil) { map.keyDown(with: down) }.isEmpty)
    }

    @Test func aClickOnTheRailNeverTaps() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = DSView(frame: window.contentLayoutRect)
        window.contentView = content
        let map = ThreadMinimapView(frame: NSRect(x: 12, y: 100, width: 40, height: 72))
        content.addSubview(map)
        map.items = (0..<10).map { ThreadMinimapItem(id: "\($0)", rowIndex: $0, userText: "Turn \($0)", assistantText: "Reply \($0)") }
        let host = try #require(map.popupHost)
        let saved = MessageRailHaptic.current
        defer { host.closeAll(); map.removeFromSuperview(); window.close(); MessageRailHaptic.current = saved }
        MessageRailHaptic.current = { .strong }
        var selected: [String] = []
        map.onSelect = { selected.append($0) }
        func click(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: map.convert(NSPoint(x: 20, y: y), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let played = Haptics.recording(.leftMouseDown, buttons: 1) {
            map.mouseDown(with: click(.leftMouseDown, y: 4))
            map.mouseDown(with: click(.leftMouseDown, y: 68))
        }
        #expect(selected.count == 2)
        #expect(played.isEmpty)
    }

    /// One pointer sample every 1/60 s, moving `step` lines each time, over `count` lines.
    private func sweep(_ level: MessageRailHaptic, count: Int, step: Int, every dt: TimeInterval = 1.0 / 60) -> Int {
        var pacer = MessageRailHapticPacer(), taps = 0, t = 0.0
        for i in Swift.stride(from: step, to: count, by: step) {
            t += dt
            if pacer.pattern(level, from: i - step, to: i, count: count, at: t) != nil { taps += 1 }
        }
        return taps
    }

    @Test func theRailTapsOncePerLineCrossedAndOncePerJump() {
        // 30 lines a second, faster than a hand reads 8pt lines at 200pt a second: every line taps.
        #expect(sweep(.light, count: 40, step: 1, every: 1.0 / 30) == 39)
        #expect(sweep(.medium, count: 40, step: 1, every: 1.0 / 30) == 39)
        // Each event jumps four lines: one tap per event, not four.
        #expect(sweep(.light, count: 41, step: 4, every: 0.1) == 10)
        #expect(sweep(.off, count: 40, step: 1, every: 0.1) == 0)
        // An absurd flick, a line every millisecond for a second: the cap of 40 a second, with its millisecond of slack, holds.
        #expect((40...42).contains(sweep(.light, count: 1001, step: 1, every: 0.001)))
        var pacer = MessageRailHapticPacer()
        #expect(pacer.pattern(.light, from: 3, to: 3, count: 10, at: 1) == nil, "the highlighted line did not change")
        #expect(MessageRailHaptic.allCases.map(\.pattern) == [nil, .generic, .levelChange, .alignment])
    }

    @Test func enteringTheRailNeverTaps() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = DSView(frame: window.contentLayoutRect)
        window.contentView = content
        let map = ThreadMinimapView(frame: NSRect(x: 12, y: 100, width: 40, height: 72))
        content.addSubview(map)
        map.items = (0..<10).map { ThreadMinimapItem(id: "\($0)", rowIndex: $0, userText: "Turn \($0)", assistantText: "Reply \($0)") }
        let host = try #require(map.popupHost)
        let saved = MessageRailHaptic.current
        defer { host.closeAll(); map.removeFromSuperview(); window.close(); MessageRailHaptic.current = saved }
        MessageRailHaptic.current = { .strong }
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        #expect(Haptics.recording(.mouseEntered) { map.mouseEntered(with: enter); map.mouseExited(with: enter); map.mouseEntered(with: enter) }.isEmpty)
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
