import Foundation

/// The Dither tab strip's state (after Capy and a browser): the open routes in strip order and the selected one.
/// Navigating replaces the selected tab's route; a navigation marked as a new tab inserts one after it; a route
/// already open in another tab selects that tab. The window shows the selected tab's route.
public struct DitherTabList {
    public private(set) var tabs: [RouteHistory.Route] = []
    public private(set) var selected = 0
    // ponytail: twelve tabs, the oldest unselected one drops first; make it a setting if people keep more open
    public static let limit = 12

    public init() {}

    public static func key(_ route: RouteHistory.Route) -> String {
        switch route {
        case .thread(let id): "thread:\(id.rawValue)"
        case .draft: "draft"
        case .settings: "settings"
        case .pullRequests: "pull-requests"
        case .usage: "usage"
        case .orchestrator: "orchestrator"
        }
    }

    public var selectedRoute: RouteHistory.Route? { tabs.indices.contains(selected) ? tabs[selected] : nil }
    public var selectedKey: String? { selectedRoute.map(Self.key) }
    public func index(of key: String) -> Int? { tabs.firstIndex { Self.key($0) == key } }

    /// The window now shows `route`.
    public mutating func shown(_ route: RouteHistory.Route, newTab: Bool) {
        let key = Self.key(route)
        if let i = index(of: key) {
            // Already open: that tab shows, holding the latest Settings section or draft.
            tabs[i] = route
            selected = i
        } else if tabs.isEmpty || newTab {
            let at = tabs.isEmpty ? 0 : min(selected + 1, tabs.count)
            tabs.insert(route, at: at)
            selected = at
            while tabs.count > Self.limit, let drop = tabs.indices.first(where: { $0 != selected }) {
                tabs.remove(at: drop)
                if drop < selected { selected -= 1 }
            }
        } else {
            tabs[selected] = route
        }
    }

    /// Selects the tab; returns its route when it isn't the selected one already.
    public mutating func select(_ key: String) -> RouteHistory.Route? {
        guard let i = index(of: key), i != selected else { return nil }
        selected = i
        return tabs[i]
    }

    /// Closes the tab. Closing the selected one selects its right neighbor, or the left one at the end;
    /// returns true when the selection changed, so the window must show `selectedRoute` (nil when none is left).
    @discardableResult
    public mutating func close(_ key: String) -> Bool {
        guard let i = index(of: key) else { return false }
        tabs.remove(at: i)
        if i < selected { selected -= 1; return false }
        guard i == selected else { return false }
        selected = max(0, min(selected, tabs.count - 1))
        return true
    }

    /// Drops tabs (never the selected one) whose route no longer exists.
    public mutating func prune(keeping exists: (RouteHistory.Route) -> Bool) {
        let keep = selectedKey
        tabs.removeAll { Self.key($0) != keep && !exists($0) }
        selected = keep.flatMap(index(of:)) ?? 0
    }

    /// Moves the tab to `index` in strip order; the same tab stays selected.
    public mutating func move(_ key: String, to index: Int) {
        guard let from = self.index(of: key) else { return }
        let keep = selectedKey
        let route = tabs.remove(at: from)
        tabs.insert(route, at: max(0, min(index, tabs.count)))
        selected = keep.flatMap(self.index(of:)) ?? 0
    }
}
