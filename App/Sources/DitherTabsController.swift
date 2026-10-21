import AppKit
import DesignSystem
import Features
import T3Protocol

/// Dither's tab strip model (after Capy): the threads opened in this window, newest last, plus the new-thread page
/// while it shows. It follows the sidebar's active thread and draft, and keeps tabs only for this run.
@MainActor
final class DitherTabsController {
    private let strip: DitherTabStripView
    private weak var sidebar: SidebarContentView?
    private var open: [String] = []
    static let newTab = "new-thread"
    // ponytail: eight tabs, the oldest unselected one drops first; make it a setting if people keep more open
    static let limit = 8

    init(strip: DitherTabStripView, sidebar: SidebarContentView) {
        self.strip = strip
        self.sidebar = sidebar
        sidebar.onListChange = { [weak self] in self?.sync() }
        strip.onSelect = { [weak self] id in self?.select(id) }
        strip.onClose = { [weak self] id in self?.close(id) }
        strip.onNew = { [weak sidebar] in sidebar?.actions.newThread() }
        sync()
    }

    private var activeId: String {
        sidebar?.state.activeThreadId?.rawValue ?? Self.newTab
    }

    private func sync() {
        guard let sidebar else { return }
        let active = activeId
        if !open.contains(active) {
            // One new-thread tab at most; a thread opened while it is the selected tab takes its place.
            if let i = open.firstIndex(of: Self.newTab), active != Self.newTab, strip.selected == Self.newTab { open[i] = active }
            else { open.append(active) }
            while open.count > Self.limit, let drop = open.firstIndex(where: { $0 != active }) { open.remove(at: drop) }
        }
        let threads = sidebar.snapshot?.threads ?? []
        open.removeAll { id in id != Self.newTab && id != active && !threads.contains { $0.id.rawValue == id } }
        strip.tabs = open.map { id in
            if id == Self.newTab { return .init(id: id, title: "New thread", icon: .squarePen) }
            let title = threads.first { $0.id.rawValue == id }?.title ?? "Thread"
            return .init(id: id, title: title.isEmpty ? "Untitled" : title, icon: .messageSquare)
        }
        strip.selected = active
    }

    private func select(_ id: String) {
        guard let sidebar, id != activeId else { return }
        if id == Self.newTab { sidebar.actions.newThread(); return }
        if let thread = sidebar.snapshot?.threads.first(where: { $0.id.rawValue == id }) { sidebar.actions.openThread(thread.id) }
    }

    private func close(_ id: String) {
        guard let i = open.firstIndex(of: id) else { return }
        let wasActive = id == activeId
        open.remove(at: i)
        if wasActive {
            if open.isEmpty { sidebar?.actions.newThread() } else { select(open[min(i, open.count - 1)]) }
        }
        sync()
    }
}
