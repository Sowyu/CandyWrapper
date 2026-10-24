import AppKit
import Features
import SpaceModel
import SpaceCrypto
import SpaceLocal

/// Space in the window (docs/space.md "Sidebar and navigation"): the sidebar's Space row and mode, page and Trash
/// tabs, and ⌘N and ⌘P while Space mode shows. With the switch off or outside Redesign none of it exists: no
/// sidebar view, no pane, no store reads. Space data stays in this app; no agent, thread or Orchestrator path reads it.
@MainActor
final class SpaceController {
    let store: SpaceDocumentStore
    /// Page images through the local copy's blob cache, once the copy is open.
    private var blobs: SpaceLocalBlobs?
    private var lifecycle: Task<Void, Never>?
    private var recoverySheet: NSAlert?
    private let settings = SpaceSettings.shared
    private weak var window: NSWindow?
    private weak var sidebar: SidebarContentView?
    private weak var commands: SidebarCommands?
    /// The pane on screen, made when it shows and dropped when it hides.
    private var pageView: SpacePageView?
    private var trashView: SpaceTrashView?
    /// What the Space pane shows now, nil while it is hidden.
    private(set) var route: RouteHistory.Route?

    init(sidebar: SidebarContentView, commands: SidebarCommands, window: NSWindow, store: SpaceDocumentStore = PersistentSpacePageStore()) {
        self.window = window
        self.sidebar = sidebar
        self.commands = commands
        self.store = store
        if let persistent = store as? PersistentSpacePageStore {
            persistent.onFailure = { [weak self] in self?.showStorageFailure() }
            persistent.onSavingChange = { [weak self, weak persistent] in
                self?.sidebar?.space?.storageStatus = persistent?.failure != nil ? "Not saved" : persistent?.isSaving == true ? "Saving…" : "This Mac"
            }
        }
        sidebar.actions.openSpace = { [weak self] in self?.enterMode() }
        commands.onSpaceHidden = { [weak self] in self?.paneHidden() }
        settings.observe { [weak self] in self?.sync() }
        sync()
    }

    /// Follows the switch and the theme: Space's sidebar exists only while both allow it.
    func sync() {
        guard let sidebar else { return }
        if settings.isActive {
            if let persistent = store as? PersistentSpacePageStore, !persistent.isOpen || lifecycle != nil {
                if lifecycle == nil { startLocalStore(persistent) }
                return
            }
            if sidebar.space == nil {
                let view = SpaceSidebarView(store: store, settings: settings)
                let persistent = store as? PersistentSpacePageStore
                view.storageStatus = persistent?.failure != nil ? "Not saved" : persistent?.isSaving == true ? "Saving…" : "This Mac"
                view.actions.back = { [weak self] in self?.leaveMode() }
                view.actions.openPage = { [weak self] id in self?.open(.spacePage(id.rawValue)) }
                view.actions.openTrash = { [weak self] in self?.open(.spaceTrash) }
                view.actions.trashed = { [weak self] _ in self?.pageTrashed() }
                sidebar.space = view
            }
            sidebar.spaceMode = settings.sidebarMode
            sidebar.space?.selectedPage = selectedPage
        } else {
            if let sheet = recoverySheet, let window = sheet.window.sheetParent { window.endSheet(sheet.window, returnCode: .alertThirdButtonReturn) }
            if sidebar.space != nil {
                // Off closes Space tabs and leaves Space mode; the stored mode stays for when it comes back.
                if route != nil { commands?.closeUtilityPage() }
                sidebar.space = nil
            }
            if let persistent = store as? PersistentSpacePageStore, persistent.isOpen, lifecycle == nil {
                pageView?.commitTyping()
                pageView = nil
                blobs = nil
                lifecycle = Task { [weak self] in
                    do { try await persistent.close() }
                    catch { self?.showStorageFailure() }
                    self?.lifecycle = nil
                    if self?.settings.isActive == true { self?.sync() }
                }
            }
        }
    }

    private func startLocalStore(_ persistent: PersistentSpacePageStore) {
        lifecycle = Task { [weak self] in
            guard let self else { return }
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
                    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.candywrapper.app", isDirectory: true)
                let setup = try await persistent.open(applicationSupport: support, keyStore: SpaceKeyStore())
                blobs = SpaceLocalBlobs(local: setup.local, keys: setup.keys)
                if settings.isActive, let recovery = setup.recoveryKey {
                    let saved = await showRecovery(recovery)
                    if saved { try await Task.detached { try setup.acknowledgeRecovery() }.value }
                    else { settings.enabled = false }
                }
            } catch {
                showStorageFailure()
                settings.enabled = false
            }
            lifecycle = nil
            sync()
            if settings.isActive, settings.sidebarMode { enterMode() }
        }
    }

    private func showRecovery(_ key: String) async -> Bool {
        guard let window else { return false }
        while settings.isActive {
            let alert = NSAlert()
            alert.messageText = "Save your Space recovery key"
            alert.informativeText = "Space stays encrypted on this Mac, with no sync. Keep this key somewhere safe. If you lose this Mac and this key, your pages cannot be recovered."
            let field = NSTextField(wrappingLabelWithString: key)
            field.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
            field.isSelectable = true
            field.frame = NSRect(x: 0, y: 0, width: 440, height: 65)
            alert.accessoryView = field
            alert.addButton(withTitle: "I saved it")
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Turn Space off")
            recoverySheet = alert
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            recoverySheet = nil
            if response == .alertFirstButtonReturn { return true }
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.prepareForNewContents(with: [.currentHostOnly])
                NSPasteboard.general.setString(key, forType: .string)
            } else { return false }
        }
        return false
    }

    private func showStorageFailure() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Space could not open or save on this Mac"
        alert.informativeText = "Your encrypted copy and key have been kept. Recent edits may not be saved. Check available disk space and Keychain access, then reopen Space."
        alert.beginSheetModal(for: window)
    }

    var hasPendingWrites: Bool {
        pageView?.commitTyping()
        guard let persistent = store as? PersistentSpacePageStore else { return false }
        return persistent.isSaving || persistent.failure != nil
    }
    func flush() async -> Bool {
        pageView?.commitTyping()
        do { try await (store as? PersistentSpacePageStore)?.flush(); return true }
        catch { showStorageFailure(); return false }
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
        guard settings.isActive, (store as? PersistentSpacePageStore)?.isOpen != false, lifecycle == nil, let commands else { return false }
        let view: NSView
        switch route {
        case .spacePage(let raw):
            let id = raw.isEmpty ? nil : try? PageID(raw)
            if !raw.isEmpty && !(id.map(store.isLive) ?? false) { return false }
            trashView = nil
            let page = pageView ?? SpacePageView(store: store, blobs: blobs)
            page.onNewPage = { [weak self] in self?.enterMode(); self?.newPage() }
            page.onOpenPage = { [weak self] id in self?.open(.spacePage(id.rawValue)) }
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
