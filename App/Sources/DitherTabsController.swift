import AppKit
import DesignSystem
import Features
import T3Protocol

/// Dither's tab strip and history buttons (after Capy). Each tab shows one route from the window's `RouteHistory`: a
/// thread, the new-thread draft, Settings, Pull requests or Usage. Like Capy and a browser, navigating shows the new
/// route in the current tab; + and Cmd-click open a new one, and a route already open in another tab switches there.
/// Back and forward step through the history. Tabs last for this run only.
@MainActor
final class DitherTabsController {
    private let strip: DitherTabStripView
    private let layout: SidebarLayoutView
    private weak var sidebar: SidebarContentView?
    private let history: RouteHistory
    private let current: () -> RouteHistory.Route?
    /// The tabs in strip order and the one showing.
    private var tabs: [RouteHistory.Route] = []
    private var selected = 0
    /// The next navigation lands in a new tab (+ or Cmd-click).
    private var opensNewTab = false
    // ponytail: twelve tabs, the oldest unselected one drops first; make it a setting if people keep more open
    static let limit = 12

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
        strip.onNew = { [weak self, weak sidebar] in
            self?.opensNewTab = true
            sidebar?.actions.newThread()
        }
        sidebar.onOpenInNewTab = { [weak self, weak sidebar] id in
            self?.opensNewTab = true
            sidebar?.actions.openThread(id)
        }
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
        if let active = current() {
            let key = Self.key(active)
            if let i = tabs.firstIndex(where: { Self.key($0) == key }) {
                // Already open: that tab shows, holding the latest Settings section or draft.
                tabs[i] = active
                selected = i
            } else if tabs.isEmpty || opensNewTab {
                tabs.insert(active, at: tabs.isEmpty ? 0 : selected + 1)
                selected = tabs.isEmpty ? 0 : min(selected + 1, tabs.count - 1)
                while tabs.count > Self.limit, let drop = tabs.indices.first(where: { $0 != selected }) {
                    tabs.remove(at: drop)
                    if drop < selected { selected -= 1 }
                }
            } else {
                tabs[min(selected, tabs.count - 1)] = active
            }
            opensNewTab = false
        }
        let threads = sidebar.snapshot?.threads ?? []
        let activeKey = tabs.indices.contains(selected) ? Self.key(tabs[selected]) : nil
        // Tabs of threads that were archived or deleted close.
        tabs.removeAll { route in
            guard case .thread(let id) = route, Self.key(route) != activeKey else { return false }
            return !threads.contains { $0.id == id && $0.archivedAt == nil }
        }
        if let activeKey, let i = tabs.firstIndex(where: { Self.key($0) == activeKey }) { selected = i }
        strip.tabs = tabs.map { route in
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
        guard let i = tabs.firstIndex(where: { Self.key($0) == key }), i != selected || current().map(Self.key) != key else { return }
        selected = i
        show(tabs[i])
    }

    /// Shows `route` in the selected tab the way back and forward do, recording it as a navigation.
    private func show(_ route: RouteHistory.Route) {
        if !history.apply(route) {
            tabs.removeAll { Self.key($0) == Self.key(route) }
            selected = max(0, min(selected, tabs.count - 1))
            sync()
            return
        }
        history.record(current())
    }

    private func close(_ key: String) {
        guard let i = tabs.firstIndex(where: { Self.key($0) == key }) else { return }
        let wasSelected = i == selected
        tabs.remove(at: i)
        if i < selected || (wasSelected && selected == tabs.count) { selected = max(0, selected - 1) }
        if wasSelected {
            if tabs.isEmpty { sidebar?.actions.newThread() } else { show(tabs[selected]) }
        }
        sync()
    }
}
