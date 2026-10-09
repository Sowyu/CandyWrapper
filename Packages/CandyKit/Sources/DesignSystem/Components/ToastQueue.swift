import Foundation
import CoreGraphics

/// The timing and stacking rules of T3's stacked toasts (base-ui `Toast` with `toast.tsx` and
/// `toast.logic.ts`), kept free of views so tests can drive it with a fake clock.
/// Items are front first: a new toast goes to the front.
public struct ToastQueue {
    public enum Kind: String, CaseIterable, Sendable { case plain, success, error, info, warning, loading }

    public struct Item: Equatable {
        public let id: Int
        public var kind: Kind
        /// Seconds; 0 keeps the toast until dismissed. `loading` toasts never time out.
        public var timeout: TimeInterval
        /// Time left on the clock, counted down only while the queue runs.
        public var remaining: TimeInterval
        var expires: Bool { timeout > 0 && kind != .loading }
    }

    /// base-ui's defaults: 5000ms and 3 visible.
    public static let defaultTimeout: TimeInterval = 5
    public var limit = 3
    public private(set) var items: [Item] = []
    /// Paused while the stack is expanded (hovered or focused) or the window is not key.
    public private(set) var isPaused = false
    private var runningSince: TimeInterval?
    private var nextId = 1

    public init() {}

    @discardableResult
    public mutating func add(kind: Kind = .plain, timeout: TimeInterval = defaultTimeout, now: TimeInterval) -> Int {
        settle(now)
        let id = nextId
        nextId += 1
        items.insert(Item(id: id, kind: kind, timeout: timeout, remaining: timeout), at: 0)
        return id
    }

    public mutating func remove(_ id: Int, now: TimeInterval) {
        settle(now)
        items.removeAll { $0.id == id }
    }

    public mutating func setPaused(_ paused: Bool, now: TimeInterval) {
        settle(now)
        isPaused = paused
        runningSince = paused ? nil : now
    }

    /// Counts the running time into every item's `remaining` and restarts the run from `now`.
    private mutating func settle(_ now: TimeInterval) {
        if let since = runningSince {
            let elapsed = now - since
            for i in items.indices where items[i].expires { items[i].remaining -= elapsed }
        }
        runningSince = isPaused ? nil : now
    }

    /// When the next toast expires, or nil when nothing can: the host schedules one one-shot timer for it.
    public func nextDeadline() -> TimeInterval? {
        guard let since = runningSince, !isPaused else { return nil }
        return items.filter(\.expires).map { since + $0.remaining }.min()
    }

    /// Removes and returns the ids of toasts whose time ran out by `now`.
    public mutating func expire(now: TimeInterval) -> [Int] {
        settle(now)
        let done = items.filter { $0.expires && $0.remaining <= 0.0005 }.map(\.id)
        items.removeAll { done.contains($0.id) }
        return done
    }

    // MARK: Stacking

    /// Where one toast sits: `transform: translateY(y) scale(scale)` with origin top, at `height`.
    public struct Slot: Equatable {
        public var index: Int
        public var translateY: CGFloat
        public var scale: CGFloat
        public var height: CGFloat
        public var contentHidden: Bool
        /// `data-limited:opacity-0` past the limit.
        public var limited: Bool
    }

    /// T3's stack for top positions. Collapsed: the front toast at rest, each one behind it forced to
    /// the front's height H, scaled by 1 - 0.1i about its top and moved down i*12 + 0.1i*H, so a
    /// 12px strip peeks out per toast. Expanded: natural heights in a list with 12px gaps.
    public static func layout(heights: [CGFloat], expanded: Bool, limit: Int = 3) -> [Slot] {
        let gap: CGFloat = 12, peek: CGFloat = 12
        let front = heights.first ?? 0
        var offset: CGFloat = 0
        return heights.enumerated().map { i, h in
            defer { offset += h }
            let index = CGFloat(i)
            if expanded {
                return Slot(index: i, translateY: offset + index * gap, scale: 1, height: h, contentHidden: false, limited: i >= limit)
            }
            let scale = max(0, 1 - index * 0.1)
            let height = i == 0 ? h : front
            return Slot(index: i, translateY: index * peek + (1 - scale) * height, scale: scale, height: height,
                        contentHidden: i > 0 && heights.count > 1, limited: i >= limit)
        }
    }
}
