import AppKit
import DesignSystem
import Features
import T3Protocol
import T3Store

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
    /// Opens a new-thread draft and calls back once it shows, which can be after a server round trip.
    private let newThread: (@escaping @MainActor () -> Void) -> Void
    private var list = DitherTabList()
    /// Set only while + or Cmd-click navigates, so the route it shows lands in a new tab.
    private var opensNewTab = false

    init(layout: SidebarLayoutView, sidebar: SidebarContentView, history: RouteHistory,
         current: @escaping () -> RouteHistory.Route?, newThread: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.strip = layout.tabStrip
        self.layout = layout
        self.sidebar = sidebar
        self.history = history
        self.current = current
        self.newThread = newThread
        sidebar.onListChange = { [weak self] in self?.sync() }
        history.onChange = { [weak self] in self?.sync() }
        strip.onSelect = { [weak self] key in self?.select(key) }
        strip.onClose = { [weak self] key in self?.close(key) }
        strip.onMove = { [weak self] key, index in
            self?.list.move(key, to: index)
            self?.sync()
        }
        strip.onNew = { [weak self] in self?.openNewThreadTab() }
        sidebar.onOpenInNewTab = { [weak self, weak sidebar] id in self?.inNewTab { sidebar?.actions.openThread(id) } }
        layout.backButton.action = { [weak history] in history?.back() }
        layout.forwardButton.action = { [weak history] in history?.forward() }
        sync()
    }

    private func inNewTab(_ navigate: () -> Void) {
        opensNewTab = true
        defer { opensNewTab = false; sync() }
        navigate()
    }

    func sync() {
        layout.backButton.isEnabled = history.canGoBack
        layout.forwardButton.isEnabled = history.canGoForward
        guard let sidebar else { return }
        if let active = current() {
            let changed = list.selectedKey != DitherTabList.key(active)
            list.shown(active, newTab: opensNewTab && changed)
            if changed { opensNewTab = false }
        }
        // Tabs of threads that were archived or deleted close, once the sidebar has threads to compare with.
        if let threads = sidebar.snapshot?.threads {
            list.prune { route in
                guard case .thread(let id) = route else { return true }
                return threads.contains { $0.id == id && $0.archivedAt == nil }
            }
        }
        let threads = sidebar.snapshot?.threads ?? []
        // The sidebar's status, so a tab's grid follows its row: subagents waiting on the user count for their parent.
        let requests = list.tabs.contains { if case .thread = $0 { true } else { false } } ? PendingSubagentRequests.byThread(threads) : [:]
        strip.tabs = list.tabs.map { route in
            let key = DitherTabList.key(route)
            switch route {
            case .thread(let id):
                let shell = threads.first { $0.id == id }
                let title = shell?.title ?? ""
                let status = shell.map { SidebarModel.resolveSidebarThreadStatus(SidebarThread($0, pendingSubagentRequest: requests[id])) }
                let activity: DitherTabStripView.Tab.Activity? = status == .working ? .working : status == .waiting ? .waiting : nil
                return .init(id: key, title: title.isEmpty ? "Untitled" : title, icon: .messageSquare, activity: activity)
            case .draft: return .init(id: key, title: "New thread", icon: .squarePen)
            case .settings: return .init(id: key, title: "Settings", icon: .settings)
            case .pullRequests: return .init(id: key, title: "Pull requests", icon: .gitPullRequestArrow)
            case .usage: return .init(id: key, title: "Usage", icon: .chartNoAxesColumn)
            case .orchestrator: return .init(id: key, title: "Orchestrator", icon: .workflow)
            }
        }
        strip.selected = list.selectedKey
    }

    private func select(_ key: String) {
        opensNewTab = false
        guard list.select(key) != nil else { return }
        showSelected()
    }

    private func close(_ key: String) {
        opensNewTab = false
        if list.close(key) { showSelected() } else { sync() }
    }

    /// Shows the selected tab's route as one navigation. A route that no longer exists (a deleted thread, a sent
    /// draft) closes its tab and the next one shows; with no tab left, a new thread opens.
    private func showSelected() {
        while let route = list.selectedRoute {
            if history.go(route) { return sync() }
            list.close(DitherTabList.key(route))
        }
        openNewThreadTab()
    }

    /// The draft can open after a server round trip, so the flag waits for it instead of ending with the call.
    private func openNewThreadTab() {
        opensNewTab = true
        newThread { [weak self] in self?.opensNewTab = false; self?.sync() }
    }
}
