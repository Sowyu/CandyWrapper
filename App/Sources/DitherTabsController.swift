import AppKit
import DesignSystem
import Features
import T3Protocol

/// Dither's tab strip and history buttons (after Capy). A tab is a route from the window's `RouteHistory`: a thread,
/// the new-thread draft, Settings, Pull requests or Usage. Opening a route adds its tab, a tab click shows its route,
/// and the back and forward buttons step through the history. Tabs last for this run only.
@MainActor
final class DitherTabsController {
    private let strip: DitherTabStripView
    private let layout: SidebarLayoutView
    private weak var sidebar: SidebarContentView?
    private let history: RouteHistory
    private let current: () -> RouteHistory.Route?
    /// Open tabs in strip order.
    private var open: [RouteHistory.Route] = []
    // ponytail: eight tabs, the oldest unselected one drops first; make it a setting if people keep more open
    static let limit = 8

    init(layout: SidebarLayoutView, sidebar: SidebarContentView, history: RouteHistory, current: @escaping () -> RouteHistory.Route?) {
        self.strip = layout.tabStrip
        self.layout = layout
        self.sidebar = sidebar
        self.history = history
        self.current = current
        sidebar.onListChange = { [weak self] in self?.sync() }
        history.onChange = { [weak self] in self?.sync() }
        strip.onSelect = { [weak self] key in self?.select(key) }
        strip.onClose = { [weak self] key in self?.close(key) }
        strip.onNew = { [weak sidebar] in sidebar?.actions.newThread() }
        layout.backButton.action = { [weak history] in history?.back() }
        layout.forwardButton.action = { [weak history] in history?.forward() }
        sync()
    }

    static func key(_ route: RouteHistory.Route) -> String {
        switch route {
        case .thread(let id): "thread:\(id.rawValue)"
        case .draft: "draft"
        case .settings: "settings"
        case .pullRequests: "pull-requests"
        case .usage: "usage"
        }
    }

    func sync() {
        layout.backButton.isEnabled = history.canGoBack
        layout.forwardButton.isEnabled = history.canGoForward
        guard let sidebar else { return }
        let active = current()
        let activeKey = active.map(Self.key)
        if let active, let activeKey {
            if let i = open.firstIndex(where: { Self.key($0) == activeKey }) {
                open[i] = active // the latest Settings section or draft
            } else {
                open.append(active)
                while open.count > Self.limit, let drop = open.firstIndex(where: { Self.key($0) != activeKey }) { open.remove(at: drop) }
            }
        }
        let threads = sidebar.snapshot?.threads ?? []
        open.removeAll { route in
            guard case .thread(let id) = route, Self.key(route) != activeKey else { return false }
            return !threads.contains { $0.id == id && $0.archivedAt == nil }
        }
        strip.tabs = open.map { route in
            let key = Self.key(route)
            switch route {
            case .thread(let id):
                let title = threads.first { $0.id == id }?.title ?? ""
                return .init(id: key, title: title.isEmpty ? "Untitled" : title, icon: .messageSquare)
            case .draft: return .init(id: key, title: "New thread", icon: .squarePen)
            case .settings: return .init(id: key, title: "Settings", icon: .settings)
            case .pullRequests: return .init(id: key, title: "Pull requests", icon: .gitPullRequestArrow)
            case .usage: return .init(id: key, title: "Usage", icon: .chartNoAxesColumn)
            }
        }
        strip.selected = activeKey
    }

    private func select(_ key: String) {
        guard key != current().map(Self.key), let route = open.first(where: { Self.key($0) == key }) else { return }
        show(route)
    }

    /// Shows `route` the way back and forward do, recording it as a new navigation.
    private func show(_ route: RouteHistory.Route) {
        if !history.apply(route) {
            open.removeAll { Self.key($0) == Self.key(route) }
            sync()
            return
        }
        history.record(current())
    }

    private func close(_ key: String) {
        guard let i = open.firstIndex(where: { Self.key($0) == key }) else { return }
        let wasActive = key == current().map(Self.key)
        open.remove(at: i)
        if wasActive {
            if open.isEmpty { sidebar?.actions.newThread() } else { show(open[min(i, open.count - 1)]) }
        }
        sync()
    }
}
