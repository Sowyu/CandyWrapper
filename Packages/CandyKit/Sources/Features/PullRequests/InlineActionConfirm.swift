import AppKit

/// `useInlineActionConfirm` (2994 useInlineActionConfirm.ts): the first press arms a control and
/// relabels it "Confirm …?", the second press on the same control runs it. One control is armed at
/// a time. A press anywhere else, Escape, the window losing focus or 3 seconds disarm it.
/// While nothing is armed it holds no monitor, timer or observer.
@MainActor
public final class InlineActionConfirm {
    private struct Armed {
        let action: String
        /// Which control: the header slot or a menu row. T3 compares DOM nodes; CandyWrapper
        /// rebuilds its header buttons, so a slot name stands in for the node.
        let slot: String
        let contains: (NSEvent) -> Bool
        let onDisarm: () -> Void
    }

    private var armed: Armed?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var timeout: DispatchWorkItem?
    /// How long a control stays armed (`window.setTimeout(disarm, 3000)`).
    var timeoutSeconds: Double = 3

    public init() {}

    public func isArmed(_ action: String, slot: String) -> Bool { armed?.action == action && armed?.slot == slot }

    /// A press on `slot`'s `action`. True when it confirms an armed control, so the caller runs the
    /// action. Otherwise it arms this control (disarming any other) and the caller relabels it.
    /// `contains` says whether a mouse down lands on the control; `onDisarm` puts its label back.
    public func press(_ action: String, slot: String, contains: @escaping (NSEvent) -> Bool, onDisarm: @escaping () -> Void) -> Bool {
        if isArmed(action, slot: slot) {
            clear()
            return true
        }
        disarm()
        armed = Armed(action: action, slot: slot, contains: contains, onDisarm: onDisarm)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, let armed = self.armed else { return event }
            if event.type == .keyDown {
                // Escape disarms and goes no further (`preventDefault` and `stopPropagation`).
                // An open menu sees Escape first and asks its `escapeOverride`, which disarms its row.

                if event.keyCode == 53 { self.disarm(); return nil }
                return event
            }
            if !armed.contains(event) { self.disarm() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarm() }
        }
        let work = DispatchWorkItem { [weak self] in self?.disarm() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
        return false
    }

    /// Puts an armed control back, as a press elsewhere would.
    public func disarm() {
        guard let armed else { return }
        clear()
        armed.onDisarm()
    }

    private func clear() {
        armed = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        timeout?.cancel()
        timeout = nil
    }

    /// True when `event` is a mouse down inside `view`.
    public static func hits(_ event: NSEvent, _ view: NSView?) -> Bool {
        guard let view, !view.isHidden, event.window === view.window else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
}
