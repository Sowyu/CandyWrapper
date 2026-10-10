import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// What the sidebar's row actions, thread menu, Add project and utility buttons do. Every command
/// goes to the thread's or project's own environment (`Environments.dispatch` with the scoped id).
/// Sources: apps/web/src/components/Sidebar.tsx (attemptSettle and friends, handleThreadContextMenu),
/// apps/web/src/hooks/useThreadActions.ts, client-runtime state/threadCommands.ts.
@MainActor
final class SidebarCommands {
    private weak var sidebar: SidebarContentView?
    private weak var window: NSWindow?
    private weak var layout: SidebarLayoutView?
    private let environments: Environments
    private let threads: ThreadController
    let ledger = ThreadUndoLedger()
    private var undoExpiry: DispatchWorkItem?
    /// One settle and one snooze per thread at a time (Sidebar.tsx:3314-3317, 4173).
    private var settling: Set<ThreadId> = []
    private var snoozing: Set<ThreadId> = []
    private var utilityPage: UtilityPlaceholderView?
    private var utilityKind: UtilityPage?
    private var pickingFolder = false

    /// Thread menu items this client does not have yet.
    // ponytail: no Rename, New thread on branch, Delete, Custom snooze or Project settings; add them with inline rename, branch drafts, worktree cleanup, the custom snooze dialog and the settings pages (M7)
    static let unbuiltMenuItems: Set<String> = ["rename", "new-thread-on-branch", "delete", "snooze:custom", "project-settings"]

    init(sidebar: SidebarContentView, window: NSWindow, layout: SidebarLayoutView, environments: Environments, threads: ThreadController) {
        self.sidebar = sidebar
        self.window = window
        self.layout = layout
        self.environments = environments
        self.threads = threads
        sidebar.actions.settle = { [weak self] in self?.settle($0) }
        sidebar.actions.unsettle = { [weak self] in self?.unsettle($0) }
        sidebar.actions.snooze = { [weak self] id, anchor in self?.showSnoozeMenu(id, anchor: anchor) }
        sidebar.actions.unsnooze = { [weak self] in self?.unsnooze($0) }
        sidebar.actions.unpin = { [weak self] in self?.unpin($0) }
        sidebar.actions.contextMenu = { [weak self] id, event, view in self?.showThreadMenu(id, event: event, view: view) }
        sidebar.actions.undo = { [weak self] in self?.ledger.undoLatest() }
        sidebar.actions.addProject = { [weak self] in self?.addProject() }
        sidebar.actions.openPullRequests = { [weak self] in self?.openUtilityPage(.pullRequests) }
        sidebar.actions.openUsage = { [weak self] in self?.openUtilityPage(.usage) }
        sidebar.actions.back = { [weak self] in self?.closeUtilityPage() }
        ledger.onChange = { [weak self] in self?.undoNoticeChanged() }
    }

    /// Thread lifecycle keybindings for the open thread (_chat.tsx:84-93, ChatView.tsx:8000-8063).
    func registerShortcuts(_ shortcuts: Shortcuts, modelPickerOpen: @escaping () -> Bool) {
        // `thread.undo` (Mod+Z outside editable fields by default) only consumes the key when there
        // is something to undo, and never on repeat or with the model picker open (_chat.tsx:84-93).
        shortcuts.on("thread.undo") { [weak self] call in
            guard let self, !call.isRepeat, !modelPickerOpen(), self.sidebar?.window != nil else { return false }
            return self.ledger.undoLatest()
        }
        // `thread.settle` settles the open thread, or unsettles a settled one.
        shortcuts.on("thread.settle") { [weak self] _ in
            guard let self, self.threads.panel.window != nil else { return false }
            if let id = self.threads.openThreadId, let thread = self.shell(id) {
                if thread.settledOverride == .settled { self.unsettle(id) } else { self.settle(id) }
            }
            return true
        }
        // `thread.pin` pins the open thread, or unpins a pinned one.
        shortcuts.on("thread.pin") { [weak self] _ in
            guard let self, self.threads.panel.window != nil else { return false }
            if let id = self.threads.openThreadId, let thread = self.shell(id) {
                if thread.pinnedAt != nil { self.unpin(id) } else { self.pin(id) }
            }
            return true
        }
        // `thread.copyReference`: the thread ID (`resolveThreadReferenceCopyTarget`, shared/threadReference.ts:13-40).
        // ponytail: never the PR link; read the thread's current pull request with WP7.5
        shortcuts.on("thread.copyReference") { [weak self] call in
            guard let self, self.threads.panel.window != nil else { return false }
            if !call.isRepeat { self.copyThreadReference() }
            return true
        }
        shortcuts.on("usage.open") { [weak self] _ in
            self?.openUtilityPage(.usage)
            return true
        }
    }

    /// "Copy thread ID" for the open thread; nothing on a draft. Returns the copied value.
    @discardableResult
    func copyThreadReference() -> String? {
        guard let id = threads.openThreadId else { return nil }
        copy(id.localId.rawValue, title: "Thread ID copied")
        return id.localId.rawValue
    }

    /// The value `thread.copyReference` copies, nil when there is none.
    var threadReference: String? { threads.openThreadId?.localId.rawValue }

    var isUsagePageOpen: Bool { utilityPage != nil && utilityKind == .usage }

    // MARK: Lookup

    private var snapshot: ShellSnapshot? { sidebar?.snapshot }
    func shell(_ id: ThreadId) -> ThreadShell? { snapshot?.threads.first { $0.id == id } }
    private var nowMs: Int64 { TimestampFormat.nowMs() }

    private func toast(_ title: String, _ message: String?, _ kind: ToastQueue.Kind) {
        threads.panel.toasts.show(ToastView(title: title, message: message, kind: kind))
    }

    /// `stackedThreadToast` with the server's message, else T3's fallback.
    private func fail(_ title: String, _ error: Error) {
        let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription
        toast(title, message ?? "An error occurred.", .error)
    }

    /// Runs one command for an undo; reports a failure under `title`.
    private func attempt(_ title: String, _ work: () async throws -> Void) async -> Bool {
        do { try await work(); return true } catch { fail(title, error); return false }
    }

    // MARK: Lifecycle commands (useThreadActions.ts:658-976)

    func settle(_ id: ThreadId) {
        guard !settling.contains(id), let thread = shell(id) else { return }
        settling.insert(id)
        let navigate = planForwardNavigation(id)
        let wokeAt = SidebarModel.threadWokeAt(SidebarThread(thread), nowMs: nowMs)
        // Settling drops the pin and the snooze on the server, so Undo puts them back too.
        let pinKey = thread.pinnedAt != nil ? thread.pinOrderKey : nil
        let wasPinned = thread.pinnedAt != nil
        let snoozedUntil = thread.snoozedUntil
        ledger.invalidate("pin", id.rawValue)
        ledger.invalidate("snooze", id.rawValue)
        let claim = ledger.begin("settle", id.rawValue)
        Task {
            defer { settling.remove(id) }
            do {
                try await environments.dispatch(id, ThreadCommands.settle(id.localId), optimistic: .settle)
            } catch {
                ledger.finish(claim)
                fail("Failed to settle thread", error)
                return
            }
            if let wokeAt { sidebar?.state.localVisits[id] = wokeAt }
            showUndo(.settled, claim) { [weak self] in
                guard let self else { return }
                let title = "Failed to undo settle"
                guard await self.attempt(title, { try await self.environments.dispatch(id, ThreadCommands.unsettle(id.localId), optimistic: .unsettle) }) else { return }
                if wasPinned {
                    guard await self.attempt(title, { try await self.environments.dispatch(id, ThreadCommands.pin(id.localId, orderKey: pinKey), optimistic: .pin(orderKey: pinKey)) }) else { return }
                }
                if let snoozedUntil {
                    _ = await self.attempt(title, { try await self.environments.dispatch(id, ThreadCommands.snooze(id.localId, until: snoozedUntil.raw), optimistic: .snooze(until: snoozedUntil)) })
                }
            }
            // Only move on if the user is still on the settled thread.
            if threads.openThreadId == id, shell(id)?.settledOverride == .settled { navigate?() }
        }
    }

    func unsettle(_ id: ThreadId) {
        ledger.invalidate("settle", id.rawValue)
        Task {
            do { try await environments.dispatch(id, ThreadCommands.unsettle(id.localId), optimistic: .unsettle) } catch {
                fail("Failed to un-settle thread", error)
            }
        }
    }

    private func unsnooze(_ id: ThreadId) {
        ledger.invalidate("snooze", id.rawValue)
        Task {
            do { try await environments.dispatch(id, ThreadCommands.unsnooze(id.localId), optimistic: .unsnooze) } catch {
                fail("Failed to wake thread", error)
            }
        }
    }

    private func snooze(_ id: ThreadId, _ preset: SnoozePreset) {
        guard !snoozing.contains(id), let thread = shell(id) else { return }
        let presented = SidebarThread(thread)
        // The server's own rule, checked first so the menu fails without a round trip.
        guard SidebarModel.canSnooze(presented, nowMs: nowMs) else {
            toast("Failed to snooze thread", "This thread is waiting on you. Respond to the pending request before snoozing it.", .error)
            return
        }
        snoozing.insert(id)
        let navigate = planForwardNavigation(id)
        let claim = ledger.begin("snooze", id.rawValue)
        let until = T3Timestamp(preset.snoozedUntil)
        Task {
            defer { snoozing.remove(id) }
            do {
                try await environments.dispatch(id, ThreadCommands.snooze(id.localId, until: until.raw), optimistic: .snooze(until: until))
            } catch {
                ledger.finish(claim)
                fail("Failed to snooze thread", error)
                return
            }
            showUndo(.snoozed, claim) { [weak self] in
                guard let self else { return }
                _ = await self.attempt("Failed to wake thread", { try await self.environments.dispatch(id, ThreadCommands.unsnooze(id.localId), optimistic: .unsnooze) })
            }
            if threads.openThreadId == id, let now = shell(id), SidebarModel.effectiveSnoozed(SidebarThread(now), nowMs: nowMs) { navigate?() }
        }
    }

    /// Fresh pins go to the top of the pinned run, ahead of every keyed pin in any environment.
    func pin(_ id: ThreadId, orderKey: String? = nil) {
        ledger.invalidate("pin", id.rawValue)
        let key = orderKey ?? PinOrderKey.topOfPinnedRun(snapshot?.threads ?? [])
        Task {
            do { try await environments.dispatch(id, ThreadCommands.pin(id.localId, orderKey: key), optimistic: .pin(orderKey: key)) } catch {
                fail("Failed to pin thread", error)
            }
        }
    }

    /// `confirmAndUnpinThread` without the confirm (`confirmThreadUnpin` defaults to off).
    // ponytail: no unpin confirmation; read confirmThreadUnpin once client settings exist (M7)
    func unpin(_ id: ThreadId) {
        let orderKey = shell(id)?.pinOrderKey
        let claim = ledger.begin("pin", id.rawValue)
        Task {
            do {
                try await environments.dispatch(id, ThreadCommands.unpin(id.localId), optimistic: .unpin)
            } catch {
                ledger.finish(claim)
                fail("Failed to unpin thread", error)
                return
            }
            showUndo(.unpinned, claim) { [weak self] in
                guard let self else { return }
                _ = await self.attempt("Failed to undo unpin", {
                    try await self.environments.dispatch(id, ThreadCommands.pin(id.localId, orderKey: orderKey), optimistic: .pin(orderKey: orderKey))
                })
            }
        }
    }

    /// Archive refuses a running provider; Undo unarchives and reopens the thread if it was open.
    // ponytail: no archive confirmation; read confirmThreadArchive once client settings exist (M7)
    private func archive(_ id: ThreadId) {
        guard let thread = shell(id) else { return }
        guard SidebarModel.runtimeCanArchive(SidebarModel.shellRuntime(thread)) else {
            toast("Failed to archive thread", "Cannot archive while the provider is active.", .error)
            return
        }
        let wasOpen = threads.openThreadId == id
        let project = snapshot?.projects.first { $0.id == thread.projectId }
        let wokeAt = SidebarModel.threadWokeAt(SidebarThread(thread), nowMs: nowMs)
        let claim = ledger.begin("archive", id.rawValue)
        Task {
            do { try await environments.dispatch(id, ThreadCommands.archive(id.localId)) } catch {
                ledger.finish(claim)
                fail("Failed to archive thread", error)
                return
            }
            if let wokeAt { sidebar?.state.localVisits[id] = wokeAt }
            showUndo(.archived, claim) { [weak self] in
                guard let self else { return }
                guard await self.attempt("Failed to undo archive", { try await self.environments.dispatch(id, ThreadCommands.unarchive(id.localId)) }) else { return }
                if wasOpen { self.threads.open(id) }
            }
            if wasOpen { threads.newThread(in: project) }
        }
    }

    private func simple(_ id: ThreadId, _ payload: JSONValue, update: OptimisticThreadUpdate? = nil, failure: String?) {
        Task {
            do { try await environments.dispatch(id, payload, optimistic: update) } catch {
                if let failure { fail(failure, error) }
            }
        }
    }

    // MARK: Undo notice

    private func showUndo(_ action: ThreadUndoLedger.Action, _ claim: ThreadUndoLedger.Claim, undo: @escaping @MainActor () async -> Void) {
        ledger.show(action, claim: claim, undo: undo)
        undoExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.ledger.expireAll() } }
        undoExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func undoNoticeChanged() {
        sidebar?.undoNoticeText = ledger.notice.map { ThreadUndoLedger.text($0.action, count: $0.count) }
    }

    // MARK: Navigation

    /// `planForwardNavigation` (Sidebar.tsx:3318-3346): parking the open thread moves to the next card
    /// in list order (wrapping), else a draft in its project. Nil when the thread is not the open one.
    private func planForwardNavigation(_ id: ThreadId) -> (() -> Void)? {
        guard threads.openThreadId == id, let sidebar else { return nil }
        let rows: [SidebarRowModel] = sidebar.list.items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        let project = shell(id).flatMap { t in snapshot?.projects.first { $0.id == t.projectId } }
        if let index = rows.firstIndex(where: { $0.id == id }),
           let next = (rows[(index + 1)...] + rows[..<index]).first(where: { $0.action == .settle }) {
            return { [weak self] in self?.threads.open(next.id) }
        }
        return { [weak self] in self?.threads.newThread(in: project) }
    }

    // MARK: Snooze menu (Sidebar.tsx:573-640)

    private func showSnoozeMenu(_ id: ThreadId, anchor: NSView) {
        // Presets resolve when the menu opens, so "In 1 hour" counts from the click.
        let items = SnoozePresets.resolve(now: Date()).map { preset in
            MenuItem(preset.label, shortcut: preset.whenLabel) { [weak self] in self?.snooze(id, preset) }
        }
        MenuPopupView.show(items, from: anchor, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    // MARK: Thread menu (Sidebar.tsx:4566-4840)

    private func showThreadMenu(_ id: ThreadId, event: NSEvent, view: NSView) {
        guard let thread = shell(id), let sidebar else { return }
        let presented = SidebarThread(thread)
        let row = sidebar.list.items.lazy.compactMap { if case .row(let r) = $0, r.id == id { r } else { nil } }.first
        let group = snapshot.flatMap { s in
            SidebarModel.buildProjectGroups(s.projects, preferredEnvironmentId: sidebar.state.environments.primaryId)
                .first { $0.memberProjectIds.contains(thread.projectId) }
        }
        let presets = SnoozePresets.resolve(now: Date())
        var state = ThreadActionMenu.State()
        // ponytail: every capability reads as supported; gate per environment from its descriptor when an old server shows up
        state.branch = thread.branch
        state.projectFilter = group.map { (label: $0.label, isActive: sidebar.state.projectScopeKey == $0.key) }
        state.isPinned = thread.pinnedAt != nil
        state.isSettled = row?.section == .settled
        state.isSnoozed = row?.section == .snoozed
        state.autoSettleEnabled = thread.autoSettleDisabledAt == nil
        state.canSnoozeNow = SidebarModel.canSnooze(presented, nowMs: nowMs)
        state.isRegeneratingTitle = thread.titleRegeneration != nil
        state.isRunning = !SidebarModel.runtimeCanArchive(presented.runtime)
        state.snoozePresets = presets
        let items = ThreadActionMenu.removing(Self.unbuiltMenuItems, from: ThreadActionMenu.items(state))
        let menu = Self.nativeMenu(items) { [weak self] choice in
            self?.perform(choice, id: id, thread: thread, group: group, presets: presets)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func perform(_ choice: String, id: ThreadId, thread: ThreadShell, group: SidebarModel.ProjectGroup?, presets: [SnoozePreset]) {
        if choice.hasPrefix("snooze:") {
            if let preset = presets.first(where: { "snooze:\($0.id)" == choice }) { snooze(id, preset) }
            return
        }
        switch choice {
        case "filter-by-project":
            // The way back to all projects is picking the scoped project again.
            if let group, let sidebar { sidebar.setProjectScope(sidebar.state.projectScopeKey == group.key ? nil : group.key) }
        case "settle": settle(id)
        case "unsettle": unsettle(id)
        case "unsnooze": unsnooze(id)
        case "pin": pin(id)
        case "unpin": unpin(id)
        case "auto-settle:enabled", "auto-settle:disabled":
            let on = choice == "auto-settle:enabled"
            simple(id, ThreadCommands.setAutoSettle(id.localId, enabled: on), update: .setAutoSettle(on), failure: "Failed to update auto-settle")
        case "regenerate-title":
            guard thread.titleRegeneration == nil else { return }
            simple(id, ThreadCommands.regenerateTitle(id.localId), failure: "Failed to regenerate thread title")
        case "mark-unread":
            // ponytail: server-side only; servers without visited tracking need T3's local marker
            simple(id, ThreadCommands.markUnread(id.localId), failure: nil)
        case "copy-path":
            let project = snapshot?.projects.first { $0.id == thread.projectId }
            guard let path = thread.worktreePath ?? project?.workspaceRoot else {
                toast("Path unavailable", "This thread does not have a workspace path to copy.", .error)
                return
            }
            copy(path, title: "Path copied")
        case "copy-branch":
            if let branch = thread.branch { copy(branch, title: "Branch copied") }
        case "copy-thread-id":
            copy(id.localId.rawValue, title: "Thread ID copied")
        case "archive": archive(id)
        default: break
        }
    }

    private func copy(_ text: String, title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(title, text, .success)
    }

    /// Electron's context menu template (apps/desktop/src/electron/ElectronMenu.ts:142-190): a separator
    /// before `separatorBefore` items, checkbox items for `checked`, submenus for children.
    static func nativeMenu(_ items: [ThreadMenuItem], choose: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separatorBefore, menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
            let native = ClosureMenuItem(title: item.label, action: nil, keyEquivalent: "")
            native.isEnabled = !item.disabled
            if let checked = item.checked { native.state = checked ? .on : .off }
            if item.children.isEmpty {
                native.handler = { choose(item.id) }
            } else {
                native.submenu = nativeMenu(item.children, choose: choose)
            }
            menu.addItem(native)
        }
        return menu
    }

    // MARK: Add project (CommandPalette.tsx:2370-2516, 3228-3330)

    /// T3 opens the command palette's add-project view; its "Open in Finder" footer is the desktop folder
    /// picker on the primary environment. The project lands in that environment.
    // ponytail: the folder picker only; the palette's browse, clone and new-project flows and the environment picker come with the command palette (M7)
    func addProject() {
        guard !pickingFolder, let window else { return }
        guard let env = environments.primaryId, environments.session(env) != nil else {
            let label = environments.primaryId.flatMap { environments.label($0) } ?? "The selected environment"
            toast("Environment unavailable", "\(label) is not connected.", .error)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        pickingFolder = true
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pickingFolder = false
                guard response == .OK, let url = panel.url else { return }
                self?.addProject(path: url.path, environmentId: env)
            }
        }
    }

    /// `handleAddProjectForEnvironment`: an existing project opens its latest unsettled thread or a
    /// draft; a new one is created with `project.create`, then a draft opens in it.
    func addProject(path: String, environmentId env: String) {
        let projects = (snapshot?.projects ?? []).filter { $0.id.environmentId == env }
        if let existing = ProjectCommands.existing(projects, workspaceRoot: path) {
            let latest = (snapshot?.threads ?? []).filter { $0.projectId == existing.id }
                .max { SidebarModel.getThreadSortTimestamp($0, .updatedAt) < SidebarModel.getThreadSortTimestamp($1, .updatedAt) }
            if let latest, latest.settledOverride != .settled { threads.open(latest.id) } else { threads.newThread(in: existing) }
            return
        }
        let projectId = ProjectId(UUID().uuidString.lowercased())
        Task {
            do {
                let result = try await environments.request(env, "projects.mutate", ProjectCommands.create(projectId: projectId, workspaceRoot: path))
                let created = try result.decode(as: ProjectShell.self)
                threads.newThread(in: EnvironmentScope.scope(created, env))
            } catch {
                fail("Failed to add project", error)
            }
        }
    }

    // MARK: Pull Requests and Usage

    enum UtilityPage { case pullRequests, usage }

    /// T3 routes to `/pull-requests` and `/usage`: the page replaces the thread panel and the sidebar
    /// footer shows Back.
    // ponytail: a placeholder page; build the pull request list and usage pages in M7
    func openUtilityPage(_ page: UtilityPage) {
        guard let layout, let sidebar else { return }
        let view = UtilityPlaceholderView(page == .pullRequests ? "Pull Requests" : "Usage",
                                          icon: page == .pullRequests ? .gitPullRequestArrow : .chartNoAxesColumn)
        utilityPage?.removeFromSuperview()
        threads.panel.removeFromSuperview()
        layout.main.addSubview(view)
        utilityPage = view
        utilityKind = page
        sidebar.isOnUtilityPage = true
        layout.needsLayout = true
    }

    /// Back (`navigateToMainApp`): the thread panel returns as it was.
    func closeUtilityPage() {
        guard let layout, let page = utilityPage else { return }
        page.removeFromSuperview()
        utilityPage = nil
        utilityKind = nil
        layout.main.addSubview(threads.panel)
        sidebar?.isOnUtilityPage = false
        layout.needsLayout = true
    }
}

/// An NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    var handler: (@MainActor () -> Void)? {
        didSet { target = self; action = #selector(run) }
    }
    @objc private func run() { handler?() }
}

/// The main area while Pull Requests or Usage is open: the page title and a note that the page is not
/// built yet. The top strip drags the window like T3's header.
final class UtilityPlaceholderView: DSView {
    private let drag = TopbarDragView()
    private let empty: EmptyView

    init(_ title: String, icon: IconName) {
        empty = EmptyView(title: title, message: "This page is not in CandyWrapper yet.", icon: icon)
        super.init(frame: .zero)
        addSubview(drag)
        addSubview(empty)
    }

    override func layout() {
        super.layout()
        drag.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 52)
        let size = empty.intrinsicContentSize
        let w = min(bounds.width - 32, max(size.width, 320))
        let h = size.height > 0 ? size.height : 200
        empty.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
