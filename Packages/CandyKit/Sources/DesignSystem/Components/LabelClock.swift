import AppKit

/// One timer for every live elapsed or relative-time label. T3 runs a `setInterval(…, 1000)` per label
/// (MessagesTimeline.tsx:3507, AgentElapsed.tsx:63, ProviderSubagentBar.tsx:51, Sidebar.tsx:368), each
/// on its own phase. Here each label asks for one tick at the moment its text next changes; the clock
/// rounds that up to the next whole wall-clock second, so every label due in the same second shares one
/// wakeup, and a label that changes once a minute wakes the app once a minute.
///
/// Ticks only reach views that can be seen: in a visible, unoccluded window and not hidden. A due label
/// whose window is covered, minimized or hidden waits, and gets its tick as soon as the window shows again.
@MainActor
public final class LabelClock {
    public static let shared = LabelClock()

    private struct Entry {
        weak var view: NSView?
        var due: TimeInterval
        let fire: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Wall-clock seconds; tests replace it.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.catchUp() }
            })
        }
    }

    /// Calls `fire` once, `delay` seconds from now rounded up to a whole second, while `view` can be
    /// seen. Replaces the view's earlier request. `fire` usually updates the text and schedules again.
    // ponytail: every tick rounds up to a whole wall-clock second, so a label can lag its exact second by up to 1 s (T3's setInterval phase lags the same); give labels their own phase if one must flip on time
    public func schedule(_ view: NSView, in delay: TimeInterval, fire: @escaping () -> Void) {
        entries[ObjectIdentifier(view)] = Entry(view: view, due: (now() + max(0, delay)).rounded(.up), fire: fire)
        rearm()
    }

    public func cancel(_ view: NSView) {
        guard entries.removeValue(forKey: ObjectIdentifier(view)) != nil else { return }
        rearm()
    }

    /// Call when a view that has a request was unhidden or moved into a window, so a tick that came
    /// due while it couldn't be seen lands now.
    public func visibilityChanged() { catchUp() }

    /// The pending tick for `view`, for tests.
    public func due(for view: NSView) -> Date? {
        entries[ObjectIdentifier(view)].map { Date(timeIntervalSince1970: $0.due) }
    }

    public static func canSee(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    /// Fires every visible request that is due, then aims the timer at the next visible one.
    private func catchUp() {
        let t = now()
        var due: [() -> Void] = []
        for (key, entry) in entries {
            guard let view = entry.view else { entries[key] = nil; continue }
            if entry.due <= t + 0.05, Self.canSee(view) {
                entries[key] = nil
                due.append(entry.fire)
            }
        }
        due.forEach { $0() }
        rearm()
    }

    private func rearm() {
        let next = entries.values.lazy.filter { $0.view.map(Self.canSee) ?? false }.map(\.due).min()
        guard let next else { timer?.invalidate(); timer = nil; return }
        if let timer, timer.isValid, abs(timer.fireDate.timeIntervalSince1970 - next) < 0.001 { return }
        timer?.invalidate()
        let t = Timer(fire: Date(timeIntervalSince1970: next), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer = nil; self?.catchUp() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
