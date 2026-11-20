import AppKit

/// Drops presses on rows that something other than the user just moved, so a thread settling, waking or arriving
/// above the pointer can't hand its click to the neighbouring row (T3 4928 Sidebar.shiftGuard.ts, #23517).
/// `update` runs after each list rebuild; `dropsPress` decides a press at its event time.
@MainActor
final class SidebarShiftGuard {
    /// How long a row the list just moved ignores presses (`MOVED_ROW_PRESS_DELAY_MS`).
    static let movedRowPressDelay: TimeInterval = 0.5
    /// Moves this soon after the user's own press or key are theirs (`OWN_INPUT_WINDOW_MS`).
    static let ownInputWindow: TimeInterval = 0.5

    private var tops: [String: CGFloat] = [:]
    private var movedAt: [String: TimeInterval] = [:]
    private var lastInputAt = -TimeInterval.infinity
    /// A dropped press: its drags, release and double click stay dropped (`heldDrops`).
    private(set) var holdingDrop = false

    /// The user pressed or typed something that can move rows.
    func noteInput(at time: TimeInterval) { lastInputAt = time }

    /// Records which rows moved by half their height or more. A list filling from empty slid nothing under the
    /// pointer, and a move right after the user's own input is theirs and clears an earlier mark.
    func update(tops next: [String: (top: CGFloat, height: CGFloat)], now: TimeInterval) {
        let ownMove = tops.isEmpty || now - lastInputAt < Self.ownInputWindow
        for (key, row) in next {
            let previous = tops[key]
            if previous == row.top { continue }
            if let previous, abs(row.top - previous) * 2 < row.height { continue }
            if ownMove { movedAt[key] = nil } else { movedAt[key] = now }
        }
        movedAt = movedAt.filter { next[$0.key] != nil && now - $0.value < Self.movedRowPressDelay }
        tops = next.mapValues(\.top)
    }

    /// True when a press at `time` on the row `key` lands on a row that just slid under the pointer. A press that
    /// isn't dropped counts as the user's own input.
    func dropsPress(on key: String?, at time: TimeInterval) -> Bool {
        if let key, let moved = movedAt[key], time - moved < Self.movedRowPressDelay {
            holdingDrop = true
            return true
        }
        holdingDrop = false
        lastInputAt = time
        return false
    }

    /// The dropped press's release: swallowed, and it ends the drop.
    func releaseDrop() -> Bool {
        defer { holdingDrop = false }
        return holdingDrop
    }
}
