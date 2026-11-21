import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct HapticsTests {
    /// Runs `body` with a recorder, a clock the test moves, and the given setting and event.
    private func taps(enabled: Bool = true, event: NSEvent.EventType? = .leftMouseDragged, buttons: Int = 0,
                      at times: [TimeInterval]) -> [Haptics.Pattern] {
        let saved = (Haptics.isEnabled, Haptics.perform, Haptics.currentEvent, Haptics.now, Haptics.minimumInterval)
        defer { (Haptics.isEnabled, Haptics.perform, Haptics.currentEvent, Haptics.now, Haptics.minimumInterval) = saved }
        var played: [Haptics.Pattern] = []
        var clock: TimeInterval = 0
        Haptics.isEnabled = { enabled }
        Haptics.perform = { played.append($0) }
        Haptics.currentEvent = { (event, buttons) }
        Haptics.now = { clock }
        Haptics.minimumInterval = 1.0 / 12
        Haptics.last = -.infinity
        for t in times { clock = t; Haptics.tap(.alignment) }
        return played
    }

    @Test func theSettingTurnsEveryTapOff() {
        #expect(taps(at: [0, 1, 2]).count == 3)
        #expect(taps(enabled: false, at: [0, 1, 2]).isEmpty)
    }

    @Test func aFastSweepRatchetsAtTwelveASecond() {
        // 60 ticks crossed in one second, one every 1/60 s.
        let played = taps(at: (0..<60).map { 10 + Double($0) / 60 })
        #expect(played.count == 12)
        // Ticks a quarter second apart all play.
        #expect(taps(at: [10, 10.25, 10.5, 10.75]).count == 4)
    }

    @Test func onlyPointerAndKeyEventsTap() {
        for type: NSEvent.EventType in [.mouseMoved, .leftMouseDragged, .magnify, .keyDown, .leftMouseUp] {
            #expect(taps(event: type, at: [0]).count == 1, "\(type)")
        }
        #expect(taps(event: nil, at: [0]).isEmpty, "a model change has no event")
        #expect(taps(event: .scrollWheel, at: [0]).isEmpty, "scrolling is the system's")
        #expect(taps(event: .scrollWheel, buttons: 1, at: [0]).isEmpty)
        #expect(taps(event: .appKitDefined, at: [0]).isEmpty)
        #expect(taps(event: .appKitDefined, buttons: 1, at: [0]).count == 1, "a drag session in progress")
        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(taps(event: type, buttons: 1, at: [0]).isEmpty, "a press never taps: \(type)")
        }
    }

    @Test func crossingDetents() {
        #expect(Haptics.crosses(from: 1.5, to: 2.5, [2]))
        #expect(Haptics.crosses(from: 2.5, to: 1.5, [2]))
        #expect(Haptics.crosses(from: 1.5, to: 2, [2]), "landing on a limit")
        #expect(!Haptics.crosses(from: 2, to: 2.5, [2]), "leaving a detent")
        #expect(!Haptics.crosses(from: 2, to: 2, [2]))
        #expect(!Haptics.crosses(from: 1.2, to: 1.8, [1, 2]))
    }

    @Test func sidebarDividerTapsOncePerLimitAndOnTheDefault() {
        let d = UserDefaults(suiteName: "haptics-\(UUID().uuidString)")!
        let layout = SidebarLayoutView(defaults: d, viewport: 1100)
        layout.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        layout.layoutSubtreeIfNeeded()
        let played = Haptics.recording {
            var current = layout.beginDrag()
            // Drag in 10pt steps from 256 down past the 208 minimum and keep pulling, then back out.
            for proposed in stride(from: current - 10, through: 150, by: -10) { current = layout.drag(to: proposed, current: current) }
            for proposed in stride(from: current + 10, through: 300, by: 10) { current = layout.drag(to: proposed, current: current) }
        }
        #expect(played == [.alignment], "one tap at the minimum, none while held there or leaving it")
        let max = Haptics.recording {
            var current = layout.beginDrag()
            for proposed in stride(from: current + 50, through: 2000, by: 50) { current = layout.drag(to: proposed, current: current) }
        }
        #expect(max == [.alignment], "one tap at the maximum")
        let reset = Haptics.recording(.leftMouseDown) {
            layout.rail.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
        }
        #expect(reset.isEmpty, "a double click returns to the default width; the click is its own feedback")
    }

    @Test func sliderTapsPerStepOnDragNotOnPress() {
        let slider = SliderView(value: 0, range: 0...10, step: 1)
        slider.frame = NSRect(x: 0, y: 0, width: 116, height: 20) // 10pt per step between the 8pt insets
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let played = Haptics.recording {
            slider.mouseDown(with: event(.leftMouseDown, x: 8))
            for x in stride(from: CGFloat(9), through: 58, by: 1) { slider.mouseDragged(with: event(.leftMouseDragged, x: x)) }
        }
        #expect(slider.value == 5)
        #expect(played == Array(repeating: .levelChange, count: 5), "one per step")
    }
}
