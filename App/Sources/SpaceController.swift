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
    private let reminders: SpaceReminderController
    private var remindersEnabled: Bool?
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
        reminders = SpaceReminderController(store: store)
        if let persistent = store as? PersistentSpacePageStore {
            persistent.onFailure = { [weak self] in self?.showStorageFailure() }
            persistent.onSavingChange = { [weak self, weak persistent] in
                self?.sidebar?.space?.storageStatus = persistent?.failure != nil ? "Not saved" : persistent?.isSaving == true ? "Saving…" : "This Mac"
            }
        }
        reminders.openPage = { [weak self] id in
            guard let self else { return }
            NSApp.activate()
            self.window?.makeKeyAndOrderFront(nil)
            self.enterMode()
            self.open(.spacePage(id.rawValue))
        }
        reminders.flush = { [weak store] in try await (store as? PersistentSpacePageStore)?.flush() }
        reminders.onFailure = { [weak self] _ in self?.showReminderFailure() }
        sidebar.actions.openSpace = { [weak self] in self?.enterMode() }
        commands.onSpaceHidden = { [weak self] in self?.paneHidden() }
        settings.observe { [weak self] in self?.sync() }
        sync()
    }

    /// Follows the switch and the theme: Space's sidebar exists only while both allow it.
    func sync() {
        let shouldRemind = settings.isActive && (store as? PersistentSpacePageStore)?.isOpen != false && lifecycle == nil
        // Keep OS-owned reminders during an enabled launch while the encrypted copy opens.
        // Only an actual switch/theme-off transition withdraws them before planning can resume.
        if (!settings.isActive || shouldRemind), remindersEnabled != shouldRemind {
            remindersEnabled = shouldRemind
            reminders.setEnabled(shouldRemind)
        }
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
                view.actions.openHistory = { [weak self] id in
                    if self?.open(.spacePage(id.rawValue)) == true { self?.pageView?.showHistory() }
                }
                view.actions.trashed = { [weak self] _ in self?.pageTrashed() }
                sidebar.space = view
            }
            sidebar.spaceMode = settings.sidebarMode
            sidebar.space?.selectedPage = selectedPage
        } else {
            if let sheet = recoverySheet, let window = sheet.window.sheetParent { window.endSheet(sheet.window, returnCode: .alertSecondButtonReturn) }
            // Typing still waiting for its flush goes in while the pane and the store are both still there.
            pageView?.commitTyping()
            if sidebar.space != nil {
                // Off closes Space tabs and leaves Space mode; the stored mode stays for when it comes back.
                if route != nil { commands?.closeUtilityPage() }
                sidebar.space = nil
            }
            if let persistent = store as? PersistentSpacePageStore, persistent.isOpen, lifecycle == nil {
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
                let blobs = SpaceLocalBlobs(local: setup.local, keys: setup.keys)
                blobs.onFailure = { [weak self] title, text in self?.showAlert(title, text) }
                self.blobs = blobs
                if settings.isActive, let recovery = setup.recoveryKey {
                    let saved = await showRecovery(recovery)
                    if saved { try await Task.detached { try setup.acknowledgeRecovery() }.value }
                    else { settings.enabled = false }
                }
            } catch {
                showStorageFailure()
                settings.enabled = false
            }
            #if DEBUG
            seedReminderFixtureIfRequested()
            #endif
            lifecycle = nil
            sync()
            if settings.isActive, settings.sidebarMode { enterMode() }
        }
    }

    #if DEBUG
    /// An isolated UI check, never available in the user's bundle or a release build.
    private func seedReminderFixtureIfRequested() {
        guard Bundle.main.bundleIdentifier?.hasPrefix("dev.candywrapper.test.") == true,
              ProcessInfo.processInfo.arguments.contains("--space-reminder-fixture"),
              settings.isActive, store.pages.isEmpty else { return }
        let parent = store.createPage(title: "Reminder check")
        if var record = store.pages[parent], let order = try? OrderKey.between(nil, nil) {
            record.fields[FieldID.done] = FieldDefinition(name: "Done", type: .checkbox, order: order)
            store.put([parent: record])
        }
        let item = store.createPage(in: parent, title: "Check the Space reminder")
        // UTC keeps this check two minutes ahead during a repeated DST hour too.
        let zone = TimeZone(secondsFromGMT: 0)!
        guard let point = try? DatePoint.from(Date().addingTimeInterval(120), in: zone),
              let due = try? DateValue(start: point, tz: zone.identifier, remind: .before(0)),
              var record = store.pages[item] else { return }
        record.props[FieldID.due] = .date(due)
        record.props[FieldID.done] = .checkbox(false)
        store.put([item: record])
        settings.lastPage = parent
        settings.sidebarMode = true
    }
    #endif

    /// The key shows for writing down only. It never goes to the pasteboard, which any process of this user can read.
    private func showRecovery(_ key: String) async -> Bool {
        guard let window, settings.isActive else { return false }
        let alert = NSAlert()
        alert.messageText = "Write down your Space recovery key"
        alert.informativeText = "Space stays encrypted on this Mac, with no sync. Write this key on paper or save it in your password manager by typing it in. If you lose this Mac and this key, your pages cannot be recovered."
        let field = NSTextField(wrappingLabelWithString: key)
        field.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        field.frame = NSRect(x: 0, y: 0, width: 440, height: 65)
        alert.accessoryView = field
        alert.addButton(withTitle: "I saved it")
        alert.addButton(withTitle: "Turn Space off")
        recoverySheet = alert
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        recoverySheet = nil
        return response == .alertFirstButtonReturn
    }

    private func showReminderFailure() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Space could not update reminders"
        alert.informativeText = "Your items are kept. Check notification permissions and reopen Space to try again."
        alert.beginSheetModal(for: window)
    }

    func reminderResponse(_ response: SpaceReminderResponse) async {
        // A notification can launch the app before the encrypted copy finishes opening.
        while let lifecycle { await lifecycle.value }
        await reminders.respond(to: response)
    }

    func refreshReminders() { reminders.refresh() }

    private func showStorageFailure() {
        showAlert("Space could not open or save on this Mac",
                  "Your encrypted copy and key have been kept. Recent edits may not be saved. Check available disk space and Keychain access, then reopen Space.")
    }

    private func showAlert(_ title: String, _ text: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window)
    }

    var hasPendingWrites: Bool {
        pageView?.commitTyping()
        guard let persistent = store as? PersistentSpacePageStore else { return reminders.hasPendingWork }
        return persistent.isSaving || persistent.failure != nil || reminders.hasPendingWork
    }
    func flush() async -> Bool {
        pageView?.commitTyping()
        do {
            try await (store as? PersistentSpacePageStore)?.flush()
            await reminders.prepareToQuit()
            return true
        }
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
            pageView?.commitTyping()
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
        pageView?.commitTyping()
        pageView = nil
        trashView = nil
        sidebar?.space?.selectedPage = nil
    }
}
