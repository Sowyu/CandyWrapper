import Foundation

/// Hold-to-quit, a port of `makeQuitShortcutHandler` (apps/desktop/src/window/QuitHold.ts). The app feeds it
/// the main window's key events before the menu sees them; quitting from the menu stays immediate.
/// "Still held" is proven by auto-repeat keydowns, since macOS can swallow the Q keyUp while Command is down.
@MainActor
public final class QuitHoldController {
    public enum Mode: String, Sendable { case direct, hold, doubleClick = "double-click" }

    /// `QuitShortcutHintEvent`: the overlay shows on `down` and hides on `up`.
    public enum Hint: Equatable, Sendable {
        case down(Mode)
        case up
    }

    /// `QuitHoldKeyInput`. `key` is lowercased: "q", or "meta" for the Command key itself.
    public struct Key: Sendable {
        public enum Kind: Sendable { case down, up }
        public var kind: Kind
        public var key: String
        public var meta = false
        public var control = false
        public var alt = false
        public var shift = false
        public var isAutoRepeat = false

        public init(_ kind: Kind, _ key: String, meta: Bool = false, control: Bool = false, alt: Bool = false, shift: Bool = false,
                    isAutoRepeat: Bool = false) {
            self.kind = kind
            self.key = key.lowercased()
            self.meta = meta
            self.control = control
            self.alt = alt
            self.shift = shift
            self.isAutoRepeat = isAutoRepeat
        }
    }

    /// QuitHold.ts:8-20, in seconds.
    public static let holdDuration: TimeInterval = 1.2
    public static let doublePressWindow: TimeInterval = 0.5
    public static let releaseGrace: TimeInterval = 0.6
    static let repeatCadenceMultiplier: Double = 2

    private let getMode: () -> Mode
    private let notify: (Hint) -> Void
    private let concealWindow: () -> Void
    private let quit: () -> Void
    private let now: () -> TimeInterval
    /// Runs the block once after a delay; the returned closure cancels it.
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private var cancelWatchdog: (() -> Void)?
    private var holding = false
    private var mode: Mode?
    private var notified = false
    private var armed = false
    private var quitOnRelease = false
    private var heldSince: TimeInterval = 0
    private var lastPressAt: TimeInterval = 0
    private var lastRepeatAt: TimeInterval = 0
    private var repeatCadence: TimeInterval = 0

    public init(getMode: @escaping () -> Mode, notify: @escaping (Hint) -> Void, concealWindow: @escaping () -> Void,
                quit: @escaping () -> Void, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void)? = nil) {
        self.getMode = getMode
        self.notify = notify
        self.concealWindow = concealWindow
        self.quit = quit
        self.now = now
        self.schedule = schedule ?? { QuitHoldController.dispatchAfter($0, $1) }
    }

    /// A one-shot main-queue timer; nothing runs while no quit is pending.
    public static func dispatchAfter(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> () -> Void {
        nonisolated(unsafe) let block = block
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        timer.tolerance = delay * 0.05
        return { timer.invalidate() }
    }

    private func clearWatchdog() {
        cancelWatchdog?()
        cancelWatchdog = nil
    }

    private func release(keepDoublePressHint: Bool = false) {
        guard holding || notified else { return }
        let keepHint = keepDoublePressHint && mode == .doubleClick && notified
        holding = false
        armed = false
        quitOnRelease = false
        lastRepeatAt = 0
        repeatCadence = 0
        if keepHint { return }
        mode = nil
        clearWatchdog()
        if notified {
            notified = false
            notify(.up)
        }
    }

    /// Dismisses any overlay first so a cancelled quit can't leave a stale hint.
    private func quitNow() {
        release()
        lastPressAt = 0
        quit()
    }

    private func quitAfterQuietPeriod() {
        clearWatchdog()
        let quiet = max(Self.releaseGrace, repeatCadence * Self.repeatCadenceMultiplier)
        cancelWatchdog = schedule(quiet) { [weak self] in self?.quitNow() }
    }

    /// Returns true when the key is consumed (T3's `preventDefault`).
    @discardableResult
    public func handle(_ input: Key) -> Bool {
        let key = input.key
        if input.kind == .up {
            if key == "q" {
                let shouldQuit = quitOnRelease
                release(keepDoublePressHint: true)
                if shouldQuit { quit() }
            } else if key == "meta" {
                if !quitOnRelease { release(keepDoublePressHint: true) } else { quitAfterQuietPeriod() }
            }
            return false
        }

        let modifierDown = input.meta
        if input.isAutoRepeat, modifierDown, key == "q" {
            let t = now()
            repeatCadence = t - (lastRepeatAt == 0 ? heldSince : lastRepeatAt)
            lastRepeatAt = t
        }
        if quitOnRelease {
            // A Q keydown proves the key is still down, so it only pushes the quiet period back.
            if key == "q" { quitAfterQuietPeriod() }
            return true
        }

        if !modifierDown || input.alt || input.shift || key != "q" {
            // Pressing Command again starts the second shortcut, so it keeps a double-press window open.
            if key == "meta", !input.alt, !input.shift { return false }
            // Other keys cancel the hold and the first tap.
            if !input.isAutoRepeat {
                lastPressAt = 0
                release()
            }
            return false
        }

        if input.isAutoRepeat {
            if mode == .hold, armed, now() - heldSince >= Self.holdDuration {
                armed = false
                quitOnRelease = true
                concealWindow()
                quitAfterQuietPeriod()
            }
            return true
        }

        let t = now()
        let previousPressAt = lastPressAt
        lastPressAt = t
        if holding || notified { release() }
        // Every mode accepts two presses.
        if previousPressAt != 0, t - previousPressAt <= Self.doublePressWindow {
            quitNow()
            return true
        }

        holding = true
        heldSince = t
        let resolved = getMode()
        switch resolved {
        case .direct:
            quitNow()
        case .doubleClick:
            mode = resolved
            notified = true
            notify(.down(resolved))
            cancelWatchdog = schedule(Self.doublePressWindow) { [weak self] in self?.release() }
        case .hold:
            mode = resolved
            notified = true
            notify(.down(resolved))
            armed = true
            // No auto-repeat by then means the key was released (or repeat is off): don't quit.
            cancelWatchdog = schedule(Self.holdDuration + Self.releaseGrace) { [weak self] in
                self?.cancelWatchdog = nil
                self?.release()
            }
        }
        return true
    }

    /// `QuitHoldOverlay`'s text (apps/web/src/components/QuitHoldOverlay.tsx:41-45).
    public static func overlayMessage(_ mode: Mode) -> String {
        mode == .hold ? "Hold ⌘Q or press twice to quit" : "Press ⌘Q again to quit"
    }

    /// A released hold hint lingers this long; a double-press hint hides at once (QuitHoldOverlay.tsx:5-7).
    public static let holdHintLinger: TimeInterval = 1.2
}
