import AppKit
import Features
import SpaceModel

/// Space in the window (docs/space.md "Sidebar and navigation"): the sidebar's Space row and mode, page and Trash
/// tabs, and ⌘N and ⌘P while Space mode shows. With the switch off or outside Redesign none of it exists: no
/// sidebar view, no pane, no store reads. Space data stays in this app; no agent, thread or Orchestrator path reads it.
@MainActor
final class SpaceController {
    let store: SpacePageStore
    private let settings = SpaceSettings.shared
    private weak var sidebar: SidebarContentView?
    private weak var commands: SidebarCommands?
    /// The pane on screen, made when it shows and dropped when it hides.
    private var pageView: SpacePagePlaceholderView?
    private var trashView: SpaceTrashView?
    /// What the Space pane shows now, nil while it is hidden.
    private(set) var route: RouteHistory.Route?

    init(sidebar: SidebarContentView, commands: SidebarCommands, store: SpacePageStore = InMemorySpacePageStore()) {
        self.sidebar = sidebar
        self.commands = commands
        self.store = store
        sidebar.actions.openSpace = { [weak self] in self?.enterMode() }
        commands.onSpaceHidden = { [weak self] in self?.paneHidden() }
        settings.observe { [weak self] in self?.sync() }
        sync()
    }

    /// Follows the switch and the theme: Space's sidebar exists only while both allow it.
    func sync() {
        guard let sidebar else { return }
        if settings.isActive {
            if sidebar.space == nil {
                let view = SpaceSidebarView(store: store, settings: settings)
                view.actions.back = { [weak self] in self?.leaveMode() }
                view.actions.openPage = { [weak self] id in self?.open(.spacePage(id.rawValue)) }
                view.actions.openTrash = { [weak self] in self?.open(.spaceTrash) }
                view.actions.trashed = { [weak self] _ in self?.pageTrashed() }
                sidebar.space = view
            }
            sidebar.spaceMode = settings.sidebarMode
            sidebar.space?.selectedPage = selectedPage
        } else if sidebar.space != nil {
            // Off closes Space tabs and leaves Space mode; the stored mode stays for when it comes back.
            if route != nil { commands?.closeUtilityPage() }
            sidebar.space = nil
        }
    }

    var isModeShown: Bool { sidebar?.space != nil && sidebar?.spaceMode == true }

    /// The Space row: the sidebar shows Space, and with no Space tab showing the last page opens.
    func enterMode() {
        settings.sidebarMode = true
        sync()
        guard route == nil else { return }
        let last = settings.lastPage.flatMap { store.isLive($0) ? $0 : nil }
        let first = SpaceTree.children(of: nil, in: store.pages).first
        open(.spacePage((last ?? first)?.rawValue ?? ""))
    }

    /// "‹ Threads": Space tabs stay open.
    func leaveMode() {
        settings.sidebarMode = false
        sync()
    }

    /// ⌘N in Space mode.
    func newPage() { sidebar?.space?.newPage(in: nil) }

    /// ⌘P in Space mode.
    func focusSearch() { sidebar?.space?.focusSearch() }

    /// Shows a Space route in the main area. False when the page is gone or Space is off.
    @discardableResult
    func open(_ route: RouteHistory.Route) -> Bool {
        guard settings.isActive, let commands else { return false }
        let view: NSView
        switch route {
        case .spacePage(let raw):
            let id = raw.isEmpty ? nil : try? PageID(raw)
            if !raw.isEmpty && !(id.map(store.isLive) ?? false) { return false }
            trashView = nil
            let page = pageView ?? SpacePagePlaceholderView(store: store)
            page.onNewPage = { [weak self] in self?.enterMode(); self?.newPage() }
            page.show(id)
            pageView = page
            view = page
            if let id { settings.lastPage = id }
        case .spaceTrash:
            pageView = nil
            let trash = trashView ?? SpaceTrashView(store: store)
            trashView = trash
            view = trash
        default: return false
        }
        self.route = route
        sidebar?.space?.selectedPage = selectedPage
        commands.openUtilityPage(.space, view: view)
        return true
    }

    private var selectedPage: PageID? {
        if case .spacePage(let raw)? = route { return try? PageID(raw) }
        return nil
    }

    /// The tab's title and whether it's Trash.
    func tabTitle(_ route: RouteHistory.Route) -> String {
        switch route {
        case .spaceTrash: return "Trash"
        case .spacePage(let raw):
            guard let id = try? PageID(raw), let r = store.pages[id] else { return "Space" }
            return r.title.isEmpty ? "Untitled" : r.title
        default: return ""
        }
    }

    /// Whether a Space tab can still show; tabs of trashed or deleted pages close.
    func routeExists(_ route: RouteHistory.Route) -> Bool {
        guard settings.isActive else { return false }
        if case .spacePage(let raw) = route, !raw.isEmpty { return (try? PageID(raw)).map(store.isLive) ?? false }
        return true
    }

    /// The open page, or one above it, went to Trash: its tab shows "No pages yet".
    private func pageTrashed() {
        if selectedPage.map({ !store.isLive($0) }) == true { open(.spacePage("")) }
    }

    private func paneHidden() {
        route = nil
        pageView = nil
        trashView = nil
        sidebar?.space?.selectedPage = nil
    }
}
