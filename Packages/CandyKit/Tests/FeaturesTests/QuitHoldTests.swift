import Foundation
import Testing
@testable import Features

/// Ported from apps/desktop/src/window/QuitHold.test.ts with a fake clock.
@MainActor
struct QuitHoldTests {
    typealias Q = QuitHoldController

    @MainActor final class Harness {
        var now: TimeInterval = 100
        var timers: [(at: TimeInterval, id: Int, block: @MainActor () -> Void)] = []
        var nextId = 0
        var notifications: [Q.Hint] = []
        var conceals = 0
        var quits = 0
        var consumed = 0
        var mode: Q.Mode
        var controller: Q!

        init(mode: Q.Mode = .hold) {
            self.mode = mode
            controller = Q(getMode: { [unowned self] in self.mode }, notify: { [unowned self] in self.notifications.append($0) },
                           concealWindow: { [unowned self] in self.conceals += 1 }, quit: { [unowned self] in self.quits += 1 },
                           now: { [unowned self] in self.now }, schedule: { [unowned self] delay, block in
                               self.nextId += 1
                               let id = self.nextId
                               self.timers.append((self.now + delay, id, block))
                               return { [unowned self] in self.timers.removeAll { $0.id == id } }
                           })
        }

        func send(_ key: Q.Key) { if controller.handle(key) { consumed += 1 } }
        func press(_ key: String = "q", meta: Bool = true, shift: Bool = false, repeat: Bool = false) {
            send(Q.Key(.down, key, meta: meta, shift: shift, isAutoRepeat: `repeat`))
        }
        func release(_ key: String = "q") { send(Q.Key(.up, key)) }

        /// Moves the clock, firing due timers in order (seconds).
        func advance(_ seconds: TimeInterval) {
            let end = now + seconds
            while let next = timers.filter({ $0.at <= end + 1e-9 }).min(by: { $0.at < $1.at }) {
                timers.removeAll { $0.id == next.id }
                now = next.at
                next.block()
            }
            now = end
        }

        /// OS auto-repeat of the held shortcut every `interval`.
        func hold(for duration: TimeInterval, meta: Bool = true, interval: TimeInterval = 0.1) {
            var elapsed: TimeInterval = 0
            while elapsed < duration - 1e-9 {
                advance(interval)
                press(meta: meta, repeat: true)
                elapsed += interval
            }
        }
    }

    @Test func tapShowsHintWithoutQuitting() {
        let h = Harness()
        h.press()
        #expect(h.consumed == 1)
        #expect(h.notifications == [.down(.hold)])
        h.advance(Q.holdDuration + Q.releaseGrace)
        #expect(h.quits == 0)
        #expect(h.notifications == [.down(.hold), .up])
    }

    @Test func completedHoldConcealsThenQuitsAfterRelease() {
        let h = Harness()
        h.press()
        h.hold(for: Q.holdDuration + 0.2)
        #expect(h.conceals == 1 && h.quits == 0)
        h.release("meta")
        #expect(h.quits == 0)
        h.advance(Q.releaseGrace)
        #expect(h.quits == 1)
        #expect(h.notifications == [.down(.hold), .up])
    }

    @Test func completedHoldGoesQuietWithoutReleases() {
        let h = Harness()
        h.press()
        h.hold(for: Q.holdDuration + Q.releaseGrace * 2)
        #expect(h.quits == 0)
        h.advance(Q.releaseGrace)
        #expect(h.quits == 1)
    }

    @Test func slowRepeatsPushTheQuitBack() {
        let h = Harness()
        h.press()
        h.advance(0.3)
        h.press(repeat: true)
        h.advance(0.9)
        h.press(repeat: true)
        h.advance(Q.releaseGrace)
        #expect(h.quits == 0)
        h.advance(0.3)
        h.press(repeat: true)
        h.advance(1.799)
        #expect(h.quits == 0)
        h.advance(0.001)
        #expect(h.quits == 1)
    }

    @Test func waitsForQReleaseWhenCommandGoesFirst() {
        let h = Harness()
        h.press()
        h.hold(for: Q.holdDuration + 0.2)
        h.release("meta")
        h.hold(for: Q.releaseGrace * 2, meta: false)
        #expect(h.quits == 0)
        h.release()
        #expect(h.quits == 1)
    }

    @Test func shortHoldDoesNotQuit() {
        let h = Harness()
        h.press()
        h.hold(for: 0.5)
        h.release()
        #expect(h.notifications == [.down(.hold), .up])
        h.advance((Q.holdDuration + Q.releaseGrace) * 2)
        #expect(h.conceals == 0 && h.quits == 0)
    }

    @Test func releasingCommandFirstCancels() {
        let h = Harness()
        h.press()
        h.release("meta")
        #expect(h.notifications == [.down(.hold), .up])
        h.advance(5)
        #expect(h.quits == 0)
    }

    @Test func directModeQuitsAtOnce() {
        let h = Harness(mode: .direct)
        h.press()
        #expect(h.quits == 1 && h.conceals == 0)
        #expect(h.notifications.isEmpty)
    }

    @Test func doublePress() {
        let h = Harness(mode: .doubleClick)
        h.press()
        h.advance(Q.doublePressWindow - 0.1)
        h.press()
        #expect(h.quits == 1 && h.conceals == 0)
        #expect(h.notifications == [.down(.doubleClick), .up])
    }

    @Test func doublePressHintOutlivesTheRelease() {
        let h = Harness(mode: .doubleClick)
        h.press()
        h.advance(0.1)
        h.release()
        #expect(h.notifications == [.down(.doubleClick)])
        h.advance(Q.doublePressWindow - 0.101)
        #expect(h.notifications == [.down(.doubleClick)])
        h.advance(0.001)
        #expect(h.notifications == [.down(.doubleClick), .up])
    }

    @Test func secondShortcutAfterCommandWasReleased() {
        let h = Harness(mode: .doubleClick)
        h.press()
        h.release()
        h.release("meta")
        h.advance(0.1)
        h.press("meta")
        h.press()
        #expect(h.quits == 1)
    }

    @Test func slowPressesAreSeparateAttempts() {
        let h = Harness(mode: .doubleClick)
        h.press()
        h.release()
        h.advance(Q.doublePressWindow + 0.1)
        h.press()
        #expect(h.quits == 0)
        #expect(h.notifications == [.down(.doubleClick), .up, .down(.doubleClick)])
    }

    @Test func quickSecondPressInHoldMode() {
        let h = Harness()
        h.press()
        h.advance(Q.doublePressWindow - 0.1)
        h.press()
        #expect(h.quits == 1 && h.conceals == 0)
        #expect(h.notifications == [.down(.hold), .up])
    }

    @Test func autoRepeatIsNotASecondPress() {
        let h = Harness()
        h.press()
        h.hold(for: Q.doublePressWindow - 0.1)
        #expect(h.quits == 0)
        #expect(h.notifications == [.down(.hold)])
    }

    @Test func otherKeysInterrupt() {
        let h = Harness()
        h.press()
        h.hold(for: 0.5)
        h.press(shift: true)
        #expect(h.notifications == [.down(.hold), .up])
        h.hold(for: Q.holdDuration)
        #expect(h.quits == 0)

        let d = Harness(mode: .doubleClick)
        d.press()
        d.press(shift: true)
        d.press()
        #expect(d.quits == 0)
        #expect(d.notifications == [.down(.doubleClick), .up, .down(.doubleClick)])
    }

    @Test func ignoresOtherShortcuts() {
        let h = Harness()
        h.press("w")
        h.press(shift: true)
        h.press(meta: false)
        #expect(h.consumed == 0)
        #expect(h.notifications.isEmpty)
    }

    @Test func overlayText() {
        #expect(Q.overlayMessage(.hold) == "Hold ⌘Q or press twice to quit")
        #expect(Q.overlayMessage(.doubleClick) == "Press ⌘Q again to quit")
    }
}
