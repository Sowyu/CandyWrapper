import AppKit
import Testing
@testable import DesignSystem
import T3Store
@testable import Features

/// Each call site taps once per detent. The helper's own rules (setting, rate limit, events) are in HapticsTests.
@MainActor
struct HapticsCallSiteTests {
    /// The rail ticks per keyboard move at each level: every turn at strong, every few turns on a long thread below.
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
        #expect(walk(.light, turns: 10) == Array(repeating: .generic, count: 9), "a short thread ticks every turn")
        #expect(walk(.light, turns: 100).count == 9, "about ten taps end to end on a long thread")
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

    @Test func pacerTapsAboutTenTimesAcrossALongRailAndNotWhenFast() {
        var pacer = MessageRailHapticPacer()
        // A slow sweep over 200 messages and 400pt in four seconds: 100pt a second.
        var taps = 0
        for i in 1..<200 {
            let t = Double(i) * 0.02
            let speed = pacer.sample(y: CGFloat(i) * 2, at: t)
            if pacer.pattern(.light, from: i - 1, to: i, count: 200, speed: speed, at: t) != nil { taps += 1 }
        }
        #expect((8...12).contains(taps), "\(taps)")
        // The same rail crossed in a fifth of a second: 2,000pt a second.
        var fast = MessageRailHapticPacer(), fastTaps = 0
        for i in 1..<200 {
            let t = 10 + Double(i) * 0.001
            let speed = fast.sample(y: CGFloat(i) * 2, at: t)
            if fast.pattern(.light, from: i - 1, to: i, count: 200, speed: speed, at: t) != nil { fastTaps += 1 }
        }
        #expect(fastTaps == 0)
        #expect(MessageRailHaptic.allCases.map { $0.feel?.pattern } == [nil, .generic, .generic, .alignment])
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
