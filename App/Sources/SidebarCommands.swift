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
    private var utilityPage: NSView? { didSet { navigationGeneration += 1 } }
    private(set) var navigationGeneration = 0
    /// The Pull Requests page, made on first open and kept for the session (its panel is session state).
    private lazy var pullRequestsPage: PullRequestsPageController = {
        let c = PullRequestsPageController(sidebar: sidebar!, environments: environments, capabilities: threads.pullRequests.capabilities)
        c.onAddProject = { [weak self] in self?.addProject() }
        c.container.onEscape = { [weak self] in self?.goBack() }
        return c
    }()
    private var usageModal: AppRouteModalView?
    private var recordUsageModalClose = true
    private var utilityKind: UtilityPage?
    private var usageStorage: UsageController?
    private var usage: UsageController {
        if let usageStorage { return usageStorage }
        let c = UsageController(environments: environments, composer: threads.composer, window: window)
        c.page.onEscape = { [weak self] in self?.goBack() }
        usageStorage = c
        return c
    }
    /// A utility page opened or closed (route history).
    var onRouteChange: (() -> Void)?
    /// Leaves Settings before a utility page shows (both replace the main area; T3 routes between them).
    var closeSettings: () -> Void = {}
    /// Opens Settings at a search item's row, as the palette does.
    var openSettingsItem: (@MainActor (SettingsSearchItem) -> Void)?
    /// Share with guest, for the thread menu.
    var guestShare: GuestShareController?
    /// `useEscapeToGoBack` on Usage and Pull Requests: the previous route, false when there is none.
    var historyBack: () -> Bool = { false }
    var closePalette: () -> Void = {}
    /// The open utility page, nil on the thread view.
    var openUtilityKind: UtilityPage? { usageModal != nil ? .usage : utilityPage == nil ? nil : utilityKind }

    /// `/projects/$projectKey` for a group key, set by the app.
    var openProjectSettings: (String) -> Void = { _ in }

    /// Redesign's own thread menu rows (the Orchestrator's Keep out) and what choosing one does; true when handled.
    var extraMenuItems: (ThreadId) -> [ThreadMenuItem] = { _ in [] }
    var performExtra: (String, ThreadId) -> Bool = { _, _ in false }

    /// Thread menu items this client does not have yet.
    static let unbuiltMenuItems: Set<String> = []

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
        sidebar.actions.acknowledgeWake = { [weak self] id in
            guard let self, let thread = self.shell(id), let wake = SidebarModel.threadWokeAt(self.presented(thread), nowMs: self.nowMs) else { return }
            self.threads.acknowledgeWake(id, at: wake)
        }
        sidebar.actions.contextMenu = { [weak self] id, event, view in self?.showThreadMenu(id, event: event, view: view) }
        sidebar.actions.pin = { [weak self] in self?.pin($0) }
        sidebar.actions.archive = { [weak self] in self?.archive($0) }
        sidebar.actions.moreMenu = { [weak self] id, button in
            guard let event = NSApp.currentEvent else { return }
            self?.showThreadMenu(id, event: event, view: button, from: button)
        }
        sidebar.actions.undo = { [weak self] in self?.ledger.undoLatest() }
        sidebar.actions.addProject = { [weak self] in self?.addProject() }
        sidebar.actions.openPullRequests = { [weak self] in self?.openUtilityPage(.pullRequests) }
        sidebar.actions.openUsage = { [weak self] in self?.openUtilityPage(.usage) }
        sidebar.actions.back = { [weak self] in self?.closeUtilityPage() }
        sidebar.actions.rename = { [weak self] id, title, original in self?.commitRename(id, title: title, original: original) }
        // A row, draft row, search result or file drop is a route change in T3 (`navigateToThread`,
        // Sidebar.tsx:3144-3160): it leaves Usage or Pull Requests in the same click.
        let openThread = sidebar.actions.openThread
        sidebar.actions.openThread = { [weak self] id in self?.leavingUtilityPage { openThread(id) } }
        let openDraft = sidebar.actions.openDraft
        sidebar.actions.openDraft = { [weak self] id in self?.leavingUtilityPage { openDraft(id) } }
        let dropFiles = sidebar.actions.dropFiles
        sidebar.actions.dropFiles = { [weak self] id, urls in self?.leavingUtilityPage { dropFiles(id, urls) } }
        sidebar.list.canSortThread = { [weak self] id in
            guard let self, self.sidebar?.state.usesProjectFolders != true, let caps = self.capabilities(id) else { return false }
            return caps.contains("threadPinning") && caps.contains("threadPinReorder")
        }
        sidebar.list.canSortDrop = { [weak self] id, from, target in self?.planSortDrop(id, from: from, target) != nil }
        sidebar.list.onSortDrop = { [weak self] id, from, target in self?.sortDrop(id, from: from, target) }
        ledger.onChange = { [weak self] in self?.undoNoticeChanged() }
    }

    private func capabilities(_ id: ThreadId) -> Set<String>? {
        id.environmentId.flatMap { threads.composer.config($0)?.capabilities }
    }

    /// `SidebarThreadDropPlan` (Sidebar.logic.ts:226-255).
    private enum SortDropPlan {
        case reorderPinned([(id: ThreadId, key: String)])
        case pin(orderKey: String?, extra: [(id: ThreadId, key: String)])
        /// `assignments` is empty when the inbox is time-ordered (Working beta).
        case moveActive([(id: ThreadId, key: String)])
        case settle
    }

    /// `planSidebarThreadDrop` (Sidebar.logic.ts:304-410), nil for `none`.
    private func planSortDrop(_ id: ThreadId, from source: SidebarSection, _ target: SidebarDropTarget) -> SortDropPlan? {
        guard let thread = shell(id), let sidebar, let caps = capabilities(id) else { return nil }
        let activeSettled = thread.settledOverride == .settled
        if !caps.contains("threadSettlement") && (target.section == .settled || activeSettled) { return nil }
        func displayed(_ section: SidebarSection) -> [ThreadId] {
            sidebar.shownItems.compactMap { if case .row(let r) = $0, r.section == section { r.id } else { nil } }
        }
        // Rows whose server cannot store an order are never written; keyless ones leave the plan, keyed
        // ones stay as bounds.
        func arrange(_ order: [ThreadId], pinned: Bool) -> [(id: ThreadId, key: String)]? {
            let capability = pinned ? "threadPinReorder" : "threadActiveReorder"
            func writable(_ t: ThreadId) -> Bool { capabilities(t)?.contains(capability) == true }
            guard writable(id) else { return nil }
            let keys = Dictionary((snapshot?.threads ?? []).compactMap { t in (pinned ? t.pinOrderKey : t.activeOrderKey).map { (t.id, $0) } },
                                  uniquingKeysWith: { a, _ in a })
            let assignments = PinOrderKey.assignments(order: order.filter { writable($0) || keys[$0] != nil }, keys: keys, moved: id)
            return assignments.allSatisfy { writable($0.id) } ? assignments : nil
        }
        switch target.section {
        case .active:
            // Threads can enter a time-ordered inbox, but not be arranged inside it.
            if sidebar.state.workingShelfEnabled { return source == .active ? nil : .moveActive([]) }
            if source == .active && target.activeOrder == displayed(.active) { return nil }
            return arrange(target.activeOrder, pinned: false).map { .moveActive($0) }
        case .settled:
            return source == .settled ? nil : .settle
        case .pinned:
            // Dropped back where it started: nothing to write.
            if source == .pinned && target.pinnedOrder == displayed(.pinned) { return nil }
            guard let assignments = arrange(target.pinnedOrder, pinned: true) else { return nil }
            if source == .pinned { return assignments.isEmpty ? nil : .reorderPinned(assignments) }
            // A thread already pinned under a snooze or settle keeps its key on `thread.pin` (the server's
            // re-pin ignores orderKey, Orchestrator.ts:2849-2858), so its key goes out once, as a reorder.
            if thread.pinnedAt != nil { return .pin(orderKey: nil, extra: assignments) }
            return .pin(orderKey: assignments.first { $0.id == id }?.key, extra: assignments.filter { $0.id != id })
        case .working, .snoozed:
            return nil
        }
    }

    /// `handleThreadDragEnd` (Sidebar.tsx:3999-4160). A drag expresses unpin intent without the menu's confirmation.
    private func sortDrop(_ id: ThreadId, from source: SidebarSection, _ target: SidebarDropTarget) {
        guard let thread = shell(id), let plan = planSortDrop(id, from: source, target) else { return }
        if case .settle = plan { return settle(id) }
        // Hold the order the drop showed until the writes finish (T3 holds it until the keys land).
        // ponytail: released when the last write returns; read the landed keys like T3 if a slow echo reorders rows
        var hold: (section: SidebarSection, order: [ThreadId])?
        switch plan {
        case .moveActive(let a) where !a.isEmpty: hold = (.active, target.activeOrder)
        case .pin, .reorderPinned: hold = (.pinned, target.pinnedOrder)
        default: break
        }
        sidebar?.state.heldOrder = hold
        Task { [weak self] in
            guard let self else { return }
            defer { if self.sidebar?.state.heldOrder?.order == hold?.order { self.sidebar?.state.heldOrder = nil } }
            var writes: [(id: ThreadId, key: String)] = []
            var pinned = true
            do {
                switch plan {
                case .settle: return
                case .moveActive(let assignments):
                    pinned = false
                    writes = assignments
                    if thread.pinnedAt != nil { try await environments.dispatch(id, ThreadCommands.unpin(id.localId), optimistic: .unpin) }
                    if thread.settledOverride == .settled { try await environments.dispatch(id, ThreadCommands.unsettle(id.localId), optimistic: .unsettle) }
                    if source == .snoozed { try await environments.dispatch(id, ThreadCommands.unsnooze(id.localId), optimistic: .unsnooze) }
                case .pin(let orderKey, let extra):
                    writes = extra
                    let key = thread.pinnedAt != nil ? nil : orderKey ?? PinOrderKey.topOfPinnedRun(snapshot?.threads ?? [])
                    try await environments.dispatch(id, ThreadCommands.pin(id.localId, orderKey: key), optimistic: .pin(orderKey: key))
                    // ponytail: a failed key write stops the loop with earlier keys landed, as T3 does
                    // (Sidebar.tsx:4130-4150); each landed key is a valid placement. Roll back if mixed orders show up
                case .reorderPinned(let assignments):
                    writes = assignments
                }
                // Stop on failure; each key written is a valid placement.
                for assignment in writes {
                    try await environments.dispatch(assignment.id, ThreadCommands.reorder(assignment.id.localId, pinned: pinned, orderKey: assignment.key),
                                                    optimistic: .reorder(pinned: pinned, orderKey: assignment.key))
                }
            } catch {
                fail(pinned ? "Failed to reorder pinned threads" : "Failed to reorder active threads", error)
            }
        }
    }

    /// Thread lifecycle keybindings for the open thread (_chat.tsx:84-93, ChatView.tsx:8000-8063).
    func registerShortcuts(_ shortcuts: Shortcuts, modelPickerOpen: @escaping () -> Bool) {
        // `thread.undo` (Mod+Z outside editable fields by default, and inside them right after an action, see
        // `Shortcuts.run`) only consumes the key when there is something to undo, and never on repeat or with the
        // model picker open (`ThreadUndoShortcut`, AppSidebarLayout.tsx:264-317 in 3473).
        shortcuts.on("thread.undo") { [weak self] call in
            guard let self, !call.isRepeat, !modelPickerOpen(), self.sidebar?.window != nil, !self.isUsagePageOpen else { return false }
            return self.ledger.undoLatest()
        }
        // `thread.settle` settles the open thread and moves to the next one like the sidebar's Settle button, or
        // unsettles a settled one (ChatView.tsx:8104-8116, settleAndAdvance.ts, T3 3105 6edd44f40).
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
        // `thread.copyReference`: the PR the panel shows, else the thread's current PR link, else the
        // thread ID (`resolveThreadReferenceCopyTarget`, shared/threadReference.ts:13-40).
        shortcuts.on("thread.copyReference") { [weak self] call in
            guard let self, self.threads.panel.window != nil else { return false }
            if !call.isRepeat { self.copyThreadReference() }
            return true
        }
        // `usage.open` closes the palette on the way (CommandPalette.tsx:567-572).
        shortcuts.on("usage.open") { [weak self] _ in
            self?.closePalette()
            self?.openUtilityPage(.usage)
            return true
        }
        // The page's own keys, only while it is open (`usagePageOpen`); not while typing or in the model picker.
        for command in UsagePageOptions.metrics.map(\.command) + UsagePageOptions.windows.map(\.command) {
            shortcuts.on(command) { [weak self] call in
                guard let self, self.isUsagePageOpen, !call.isRepeat, !modelPickerOpen(),
                      !Shortcuts.editableFocused(in: self.window), self.window?.attachedSheet == nil,
                      (self.window?.firstResponder as? NSView).map({ $0 === self.window?.contentView || $0.isDescendant(of: self.usage.page) }) ?? true else { return false }
                return self.usage.handle(command)
            }
        }
    }

    /// "Copy PR link" or "Copy thread" for the open thread; nothing on a draft. Returns the copied value.
    @discardableResult
    func copyThreadReference() -> String? {
        guard let target = threadReferenceTarget else { return nil }
        if target.write(to: .general) { toast(target.title, target.description, .success) }
        return target.value
    }

    /// What `thread.copyReference` copies, nil when there is none.
    var threadReferenceTarget: ThreadReferenceClipboard? {
        guard let id = threads.openThreadId, let env = id.environmentId else { return nil }
        let target = threads.pullRequests.copyReferenceTarget(threadId: id.localId.rawValue)
        let title = sidebar?.snapshot?.threads.first { $0.id == id }?.title ?? id.localId.rawValue
        return ThreadReferenceClipboard(threadId: id.localId.rawValue, title: title, environmentId: env,
                                        pullRequestURL: target.value == id.localId.rawValue ? nil : target.value,
                                        pullRequestTitle: target.title)
    }

    /// The value `thread.copyReference` copies, nil when there is none.
    var threadReference: String? { threadReferenceTarget?.value }

    var isUsagePageOpen: Bool { usageModal != nil }
    var isUtilityPageOpen: Bool { usageModal != nil || utilityPage != nil }

    /// The route's thread (`routeThreadKey`): none while Usage or Pull Requests shows, so parking or
    /// deleting the thread behind the page moves nothing (Sidebar.tsx:2494, 3318-3346).
    private var routeThreadId: ThreadId? { utilityPage == nil && usageModal == nil ? threads.openThreadId : nil }

    // MARK: Lookup

    private var snapshot: ShellSnapshot? { sidebar?.snapshot }
    func shell(_ id: ThreadId) -> ThreadShell? { snapshot?.threads.first { $0.id == id } }
    /// The thread as the sidebar presents it, with what its hidden subagents wait on (T3 f4df794777).
    func presented(_ thread: ThreadShell) -> SidebarThread {
        SidebarThread(thread, pendingSubagentRequest: PendingSubagentRequests.byThread(snapshot?.threads ?? [])[thread.id])
    }
    private var nowMs: Int64 { TimestampFormat.nowMs() }

    /// `checkThreadOperations` (Sidebar.tsx:315-326): every thread must be on a connection that may change it.
    private func checkThreadOperations(_ threads: [ThreadShell]) -> Bool {
        if threads.allSatisfy({ environments.canOperate($0.id.environmentId) }) { return true }
        toast("Thread action unavailable", "This connection cannot change one or more selected threads.", .error)
        return false
    }

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

    func settle(_ id: ThreadId, navigates: Bool = true) {
        guard !settling.contains(id), let thread = shell(id) else { return }
        settling.insert(id)
        let navigate = navigates ? planForwardNavigation(id) : nil
        let wokeAt = SidebarModel.threadWokeAt(presented(thread), nowMs: nowMs)
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
            if routeThreadId == id, shell(id)?.settledOverride == .settled { navigate?() }
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
        guard let picked = SnoozePresets.pick(shown: [preset], id: preset.id, now: Date(), presets: snoozeSettings(id)) else {
            toast("Could not snooze thread", "That snooze time has passed. Choose another time.", .warning)
            return
        }
        snooze(id, until: picked.snoozedUntil)
    }

    private func snoozeSettings(_ id: ThreadId) -> [SnoozePresetSetting] {
        SnoozePresetSetting.decode(id.environmentId.flatMap { threads.composer.config($0)?.settings.raw["snoozePresets"] })
    }

    /// A command failure this client words itself, with T3's text.
    struct CommandMessage: LocalizedError { let errorDescription: String? }

    /// `performSnooze`; `leaving` are the other threads snoozing in the same batch, which forward
    /// navigation skips. Returns the failure, nil on success or when the thread is already snoozing.
    @discardableResult
    private func performSnooze(_ id: ThreadId, until wake: Date, leaving: Set<ThreadId> = [], reportFailure: Bool = true) async -> Error? {
        guard !snoozing.contains(id), let thread = shell(id) else { return nil }
        let presented = self.presented(thread)
        guard SidebarModel.canSnooze(presented, nowMs: nowMs) else {
            let error = CommandMessage(errorDescription: "This thread is waiting on you. Respond to the pending request before snoozing it.")
            if reportFailure { fail("Failed to snooze thread", error) }
            return error
        }
        snoozing.insert(id)
        defer { snoozing.remove(id) }
        let navigate = planForwardNavigation(id, leaving: leaving)
        let claim = ledger.begin("snooze", id.rawValue)
        let until = T3Timestamp(wake)
        do {
            try await environments.dispatch(id, ThreadCommands.snooze(id.localId, until: until.raw), optimistic: .snooze(until: until))
        } catch {
            ledger.finish(claim)
            if reportFailure { fail("Failed to snooze thread", error) }
            return error
        }
        showUndo(.snoozed, claim) { [weak self] in
            guard let self else { return }
            _ = await self.attempt("Failed to wake thread", { try await self.environments.dispatch(id, ThreadCommands.unsnooze(id.localId), optimistic: .unsnooze) })
        }
        if routeThreadId == id, let now = shell(id), SidebarModel.effectiveSnoozed(self.presented(now), nowMs: nowMs) { navigate?() }
        return nil
    }

    private func snooze(_ id: ThreadId, until wake: Date) {
        Task { await performSnooze(id, until: wake) }
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

    /// `confirmAndUnpinThread` (useThreadActions.ts:844-864): asks first when `confirmThreadUnpin` is on
    /// (`requestThreadUnpinConfirmation`, :173-191).
    func unpin(_ id: ThreadId) {
        guard ClientSettingsStore.shared.current.bool("confirmThreadUnpin") else { return performUnpin(id) }
        let title = shell(id)?.title ?? "this thread"
        confirm("Unpin thread \"\(title)\"?\nThis will move the thread out of your pinned section.") { [weak self] in self?.performUnpin(id) }
    }

    /// `api.dialogs.confirm` as `ConfirmDialogHost` draws it: the question line is the title, the rest the
    /// description, Cancel and Confirm (destructive for the `destructive` variant).
    private func confirm(_ message: String, destructive: Bool = false, then action: @escaping () -> Void) {
        guard let window else { return }
        let copy = ConfirmCopy.resolve(message)
        let dialog = DialogView(kind: .alertDialog, title: copy.title, message: copy.description ?? "")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: destructive ? .destructive : .default)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host] in
            host?.close()
            action()
        }
    }

    private func performUnpin(_ id: ThreadId) {
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

    /// Archive refuses a running provider; Undo unarchives and reopens the thread if it was open. With
    /// `confirmThreadArchive` on, the context menu asks first (Sidebar.tsx:4772-4778).
    private func archive(_ id: ThreadId) {
        guard let thread = shell(id) else { return }
        if ClientSettingsStore.shared.current.bool("confirmThreadArchive") {
            confirm("Archive thread \"\(thread.title)\"?") { [weak self] in self?.performArchive(id) }
        } else {
            performArchive(id)
        }
    }

    private func performArchive(_ id: ThreadId) {
        guard let thread = shell(id) else { return }
        guard SidebarModel.runtimeCanArchive(SidebarModel.shellRuntime(thread)) else {
            toast("Failed to archive thread", "Cannot archive while the provider is active.", .error)
            return
        }
        let wasOpen = routeThreadId == id
        let project = snapshot?.projects.first { $0.id == thread.projectId }
        let wokeAt = SidebarModel.threadWokeAt(presented(thread), nowMs: nowMs)
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
    private func planForwardNavigation(_ id: ThreadId, leaving: Set<ThreadId> = []) -> (() -> Void)? {
        guard routeThreadId == id, let sidebar else { return nil }
        let rows: [SidebarRowModel] = sidebar.shownItems.compactMap { if case .row(let r) = $0 { r } else { nil } }
        let project = shell(id).flatMap { t in snapshot?.projects.first { $0.id == t.projectId } }
        if let index = rows.firstIndex(where: { $0.id == id }),
           let next = (rows[(index + 1)...] + rows[..<index]).first(where: { $0.action == .settle && !leaving.contains($0.id) }) {
            return { [weak self] in self?.threads.open(next.id) }
        }
        return { [weak self] in self?.threads.newThread(in: project) }
    }

    // MARK: Snooze menu (Sidebar.tsx:573-640)

    private func showSnoozeMenu(_ id: ThreadId, anchor: NSView) {
        // Presets resolve when the menu opens, so "In 1 hour" counts from the click.
        var items = SnoozePresets.resolve(now: Date(), presets: snoozeSettings(id)).map { preset in
            MenuItem(preset.label, shortcut: preset.whenLabel) { [weak self] in self?.snooze(id, preset) }
        }
        items.append(.separator)
        items.append(MenuItem("Custom…") { [weak self] in
            self?.requestCustomSnooze { wake in self?.snooze(id, until: wake) }
        })
        MenuPopupView.show(items, from: anchor, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    // MARK: Thread menu (Sidebar.tsx:4566-4840)

    /// `anchor` (in `view`) places the menu's top left there instead of at the pointer.
    /// Under Dither, `button` (the row's ⋯) places the menu under itself.
    func showThreadMenu(_ id: ThreadId, event: NSEvent, view: NSView, anchor: NSPoint? = nil, rename: (() -> Void)? = nil, from button: NSView? = nil) {
        guard let thread = shell(id), let sidebar else { return }
        if rename == nil, button == nil, sidebar.selectedThreadIds.contains(id) {
            showSelectionMenu(event: event, view: view)
            return
        }
        let presented = self.presented(thread)
        let row = sidebar.shownItems.lazy.compactMap { if case .row(let r) = $0, r.id == id { r } else { nil } }.first
        let group = snapshot.flatMap { s in
            SidebarModel.buildProjectGroups(s.projects, preferredEnvironmentId: sidebar.state.environments.primaryId)
                .first { $0.memberProjectIds.contains(thread.projectId) }
        }
        let presets = SnoozePresets.resolve(now: Date(), presets: snoozeSettings(id))
        var state = ThreadActionMenu.State()
        state.canOperate = environments.canOperate(thread.id.environmentId)
        // ponytail: every capability reads as supported; gate per environment from its descriptor when an old server shows up
        state.branch = thread.branch
        state.projectFilter = rename == nil ? group.map { (label: $0.label, isActive: sidebar.state.projectScopeKeys.contains($0.key)) } : nil
        state.isPinned = thread.pinnedAt != nil
        state.isSettled = rename == nil ? row?.section == .settled : thread.settledOverride == .settled
        state.isSnoozed = SidebarModel.effectiveSnoozed(presented, nowMs: nowMs)
        state.autoSettleEnabled = thread.autoSettleDisabledAt == nil
        state.canSnoozeNow = SidebarModel.canSnooze(presented, nowMs: nowMs)
        state.isRegeneratingTitle = thread.titleRegeneration != nil
        state.isRunning = !SidebarModel.runtimeCanArchive(presented.runtime)
        state.snoozePresets = presets
        state.canShareWithGuest = guestShare?.canShare(thread.id.environmentId) ?? false
        var items = ThreadActionMenu.removing(Self.unbuiltMenuItems, from: ThreadActionMenu.items(state))
        if ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) { items += extraMenuItems(id) }
        let choose: @MainActor (String) -> Void = { [weak self, weak sidebar] choice in
            if choice == "rename", let rename { rename(); return }
            if self?.performExtra(choice, id) == true { return }
            if choice == "open-new-tab" { sidebar?.onOpenInNewTab?(id); return }
            self?.perform(choice, id: id, thread: thread, group: group, presets: presets)
        }
        if ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) {
            // Dither (after Capy): the themed menu with icons and key hints. The thread header's menu has no new tab to offer.
            let built = DitherThreadMenu.items(items, presets: presets, openInNewTab: rename == nil && sidebar.onOpenInNewTab != nil, choose: choose)
            let point = anchor ?? view.convert(event.locationInWindow, from: nil)
            DitherThreadMenu.show(built, from: button, in: view, at: point)
            return
        }
        let menu = Self.nativeMenu(items, choose: choose)
        if let anchor { menu.popUp(positioning: nil, at: anchor, in: view) } else { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    }

    private func perform(_ choice: String, id: ThreadId, thread: ThreadShell, group: SidebarModel.ProjectGroup?, presets: [SnoozePreset]) {
        if ThreadActionMenu.requiresOperate(choice), !checkThreadOperations([thread]) { return }
        if choice == "snooze:custom" {
            requestCustomSnooze { [weak self] wake in self?.snooze(id, until: wake) }
            return
        }
        if choice.hasPrefix("snooze:") {
            if let preset = presets.first(where: { "snooze:\($0.id)" == choice }) { snooze(id, preset) }
            return
        }
        switch choice {
        case "rename": sidebar?.startRename(id)
        case "project-settings": if let group { openProjectSettings(group.key) }
        case "new-thread-on-branch": newThreadOnBranch(thread)
        case "delete": confirmDelete(id)
        case "filter-by-project":
            // The way back to all projects is picking the scoped project again.
            if let group, let sidebar { sidebar.toggleProjectScope(group.key) }
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
        case "copy-thread":
            guard let env = id.environmentId else { return }
            let target = ThreadReferenceClipboard(threadId: id.localId.rawValue, title: thread.title, environmentId: env)
            if target.write(to: .general) { toast(target.title, target.description, .success) }
        case "copy-thread-id":
            copy(id.localId.rawValue, title: "Thread ID copied")
        case "archive": archive(id)
        case "share-guest": if let window { guestShare?.present(id, in: window) }
        default: break
        }
    }

    // MARK: Rename, delete, custom snooze, branch threads (Sidebar.tsx:3261-3290, 4650-4830)

    /// `commitThreadRename`: an empty title warns, an unchanged one does nothing.
    private func commitRename(_ id: ThreadId, title: String, original: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            toast("Thread title cannot be empty", nil, .warning)
            return
        }
        guard trimmed != original else { return }
        simple(id, ThreadCommands.rename(id.localId, title: trimmed), failure: "Failed to rename thread")
    }

    /// `requestCustomSnooze`: the custom snooze dialog; `then` runs with the chosen wake time.
    private func requestCustomSnooze(then: @escaping @MainActor (Date) -> Void) {
        guard let window else { return }
        var edit: (@MainActor () -> Void)?
        if let item = SettingsSearch.item("snooze-options"), let open = openSettingsItem { edit = { open(item) } }
        SidebarCustomSnoozeDialog.present(in: window, editOptions: edit) { wake in if let wake { then(wake) } }
    }

    /// "New thread on <branch>": the thread's worktree when it has one, else its branch on the local
    /// checkout, never from origin.
    private func newThreadOnBranch(_ thread: ThreadShell) {
        guard let project = snapshot?.projects.first(where: { $0.id == thread.projectId }) else { return }
        threads.newThread(in: project)
        threads.composer.updateDraft { d in
            d.branch = thread.branch
            d.worktreePath = thread.worktreePath
            d.envMode = thread.worktreePath == nil ? .local : .worktree
            d.startFromOrigin = false
        }
    }

    /// The thread menu's Delete: confirms when `confirmThreadDelete` is on (the default).
    private func confirmDelete(_ id: ThreadId) {
        guard let thread = shell(id) else { return }
        let run: @MainActor () -> Void = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                if case .failure(let error) = await self.deleteThread(id) { self.fail("Failed to delete thread", error) }
            }
        }
        guard ClientSettingsStore.shared.current.bool("confirmThreadDelete"), let window else { return run() }
        ConfirmCopy.present("Delete thread \"\(thread.title)\"?\nThis permanently clears conversation history for this thread.",
                            destructive: true, in: window) { yes in if yes { run() } }
    }

    private enum DeleteOutcome { case deleted, skipped, failure(Error) }

    /// `deleteThread` (useThreadActions.ts:440-640): offers to remove a worktree only this thread used,
    /// deletes, moves the open thread to the project's newest other thread, then removes the worktree.
    // ponytail: stops the provider only for the open thread (its projection holds the sessions); fetch the projection if a stale session lingers after deleting a running background thread
    private func deleteThread(_ id: ThreadId, deleting: Set<ThreadId> = []) async -> DeleteOutcome {
        guard let thread = shell(id), let env = id.environmentId else { return .skipped }
        let all = (snapshot?.threads ?? []).filter { $0.id.environmentId == env }
        let surviving = all.filter { $0.id == id || !deleting.contains($0.id) }
        let project = snapshot?.projects.first { $0.id == thread.projectId }
        let config = threads.composer.config(env)
        var orphan = SidebarModel.orphanedWorktreePath(surviving, threadId: id)
        if let path = orphan, environments.hasPartialShell(env) {
            // T3 67c3afbd58, orchestrationV2.ts:3494-3498: omitted children still own worktrees.
            let owners = try? await environments.worktreeThreadIds(env, path: path)
            if owners?.subtracting(deleting.union([id])).isEmpty != true { orphan = nil }
        }
        let scratchRoot = config?.scratchWorkspaceRoot.map(SidebarModel.normalizeProjectPath)
        let isScratch = project.map { scratchRoot == SidebarModel.normalizeProjectPath($0.workspaceRoot) } ?? false
        var removeWorktree = false
        if let orphan, project != nil, !isScratch {
            let settings = ServerSettingsValues(config?.settings.raw ?? .null)
            let automatic = ProjectSettings.worktreeCleanup(settings, projectId: thread.projectId.localId.rawValue)["worktreeOnDelete"]?.boolValue ?? false
            if !automatic, let window {
                removeWorktree = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    ConfirmCopy.present("This thread is the only one linked to this worktree:\n\(SidebarModel.worktreeDisplayName(orphan))\n\nDelete the worktree too?",
                                        destructive: true, in: window) { done.resume(returning: $0) }
                }
            }
        }
        if threads.openThreadId == id, SidebarModel.shellRuntime(thread) != nil {
            try? await threads.composer.stopSessions(thread)
        }
        let order = SidebarModel.SortOrder(rawValue: ClientSettingsStore.shared.current.string("sidebarThreadSortOrder")) ?? .updatedAt
        let fallback = SidebarModel.fallbackThreadAfterDelete(all, deleted: id, deleting: deleting, order: order)
        let wasOpen = routeThreadId == id
        do { try await environments.dispatch(id, ThreadCommands.delete(id.localId)) } catch { return .failure(error) }
        sidebar?.deselect([id])
        if wasOpen, routeThreadId == id {
            if let fallback { threads.open(fallback) } else { threads.newThread(in: project) }
        }
        guard removeWorktree, let orphan, let project else { return .deleted }
        if environments.hasPartialShell(env) {
            guard let owners = try? await environments.worktreeThreadIds(env, path: orphan),
                  owners.isEmpty else { return .deleted }
        }
        do {
            _ = try await environments.request(env, "vcs.removeWorktree",
                                               .object(["cwd": .string(project.workspaceRoot), "path": .string(orphan), "force": .bool(true)]))
        } catch {
            let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription ?? "An error occurred."
            toast("Failed to delete worktree", "Could not remove \(SidebarModel.worktreeDisplayName(orphan)). \(message)", .error)
            return .deleted
        }
        do {
            _ = try await environments.request(env, "vcs.refreshStatus", .object(["cwd": .string(project.workspaceRoot)]))
        } catch {
            fail("Worktree deleted, but Git status refresh failed", error)
        }
        return .deleted
    }

    // MARK: Multi-select (Sidebar.tsx:4242-4510)

    private func showSelectionMenu(event: NSEvent, view: NSView) {
        guard let sidebar else { return }
        // Only threads with a row now: selections can outlive their rows (settled paging, deletes elsewhere).
        let rowIds = Set(sidebar.shownItems.compactMap { if case .row(let r) = $0 { r.id } else { nil } })
        let selected = (snapshot?.threads ?? []).filter { sidebar.selectedThreadIds.contains($0.id) && rowIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        let ms = nowMs
        let pinned = selected.filter { $0.pinnedAt != nil }
        let settling = selected.filter { $0.settledOverride != .settled }
        let regeneratable = selected.filter { $0.titleRegeneration == nil }
        // ponytail: a selection across machines snoozes with the first one's options; split per environment if users mix them
        let presets = SnoozePresets.resolve(now: Date(), presets: snoozeSettings(selected[0].id))
        let requests = PendingSubagentRequests.byThread(snapshot?.threads ?? [])
        // ponytail: every environment reads as supporting pins, snooze and title regeneration; gate per descriptor for old servers
        let items = ThreadActionMenu.bulkItems(count: selected.count, pinnedCount: pinned.count, settlingCount: settling.count,
                                               canSnooze: selected.allSatisfy { SidebarModel.canSnooze(SidebarThread($0, pendingSubagentRequest: requests[$0.id]), nowMs: ms) },
                                               titleSupportedCount: selected.count, titleActionableCount: regeneratable.count,
                                               canOperate: selected.allSatisfy { environments.canOperate($0.id.environmentId) },
                                               snoozePresets: presets)
        let menu = Self.nativeMenu(items) { [weak self] choice in
            self?.performBulk(choice, selected: selected, pinned: pinned, settling: settling, regeneratable: regeneratable, presets: presets)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func performBulk(_ choice: String, selected: [ThreadShell], pinned: [ThreadShell], settling: [ThreadShell],
                             regeneratable: [ThreadShell], presets: [SnoozePreset]) {
        let ids = selected.map(\.id)
        if choice != "mark-unread", !checkThreadOperations(choice == "settle" ? settling : selected) { return }
        if choice.hasPrefix("snooze:") {
            let snoozeAll: @MainActor (Date) -> Void = { [weak self] wake in
                guard let self else { return }
                self.sidebar?.clearSelection()
                Task {
                    var done = 0
                    var failures: [Error] = []
                    for id in ids {
                        if let error = await self.performSnooze(id, until: wake, leaving: Set(ids), reportFailure: false) { failures.append(error) } else { done += 1 }
                    }
                    guard let first = failures.first else { return }
                    let n = failures.count
                    self.fail(done > 0 ? "Failed to snooze \(n) thread\(n == 1 ? "" : "s")" : "Failed to snooze threads", first)
                }
            }
            if choice == "snooze:custom" {
                requestCustomSnooze(then: snoozeAll)
            } else if let preset = presets.first(where: { "snooze:\($0.id)" == choice }) {
                snoozeAll(preset.snoozedUntil)
            }
            return
        }
        switch choice {
        case "unpin":
            for t in pinned { unpin(t.id) }
            sidebar?.clearSelection()
        case "settle":
            for t in settling where shell(t.id)?.settledOverride != .settled { settle(t.id) }
            sidebar?.clearSelection()
        case "regenerate-title":
            Task {
                for t in regeneratable {
                    do { try await environments.dispatch(t.id, ThreadCommands.regenerateTitle(t.id.localId)) } catch {
                        fail("Failed to regenerate thread titles", error)
                        return
                    }
                }
                sidebar?.clearSelection()
            }
        case "mark-unread":
            for id in ids { simple(id, ThreadCommands.markUnread(id.localId), failure: nil) }
            sidebar?.clearSelection()
        case "delete":
            let run: @MainActor () -> Void = { [weak self] in
                Task { [weak self] in
                    guard let self else { return }
                    var deleted = Set<ThreadId>()
                    var firstFailure: Error?
                    for id in ids {
                        switch await self.deleteThread(id, deleting: deleted.union([id])) {
                        case .deleted, .skipped: deleted.insert(id)
                        case .failure(let error): if firstFailure == nil { firstFailure = error }
                        }
                    }
                    if let firstFailure { self.fail("Failed to delete threads", firstFailure) }
                    self.sidebar?.deselect(Array(deleted))
                }
            }
            guard ClientSettingsStore.shared.current.bool("confirmThreadDelete"), let window else { return run() }
            let n = ids.count
            ConfirmCopy.present("Delete \(n) thread\(n == 1 ? "" : "s")?\nThis permanently clears conversation history for these threads.",
                                destructive: true, in: window) { yes in if yes { run() } }
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
        NativeItemContextMenu.make(items, choose: choose)
    }

    // MARK: Add project (CommandPalette.tsx:2370-2516, 3228-3330)

    /// Add project opens the command palette's add-project flow (`openCommandPalette({open: "add-project"})`).
    var openAddProject: () -> Void = {}

    func addProject() { openAddProject() }

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

    enum UtilityPage { case pullRequests, usage, orchestrator }

    /// The Orchestrator's pane left the main area (Redesign).
    var onOrchestratorHidden: () -> Void = {}

    /// Settings floats over the current utility page; only a floating Usage gives way.
    func prepareForSettings() {
        recordUsageModalClose = false
        usageModal?.close(animated: false)
    }

    /// Pull Requests and Redesign's Orchestrator replace the thread panel; Usage floats above the current route.
    func openUtilityPage(_ page: UtilityPage, view custom: NSView? = nil) {
        guard let layout, let sidebar else { return }
        closeSettings()
        if page == .usage, let window {
            if usageModal != nil { return }
            // Usage floats over the route that opened it, including Pull Requests.
            usage.page.header.isRouteModal = true
            recordUsageModalClose = true
            let host = AppRouteModalView.present(label: "Usage", content: usage.page, in: window)
            usageModal = host
            usage.page.header.close.action = { [weak host] in host?.close() }
            host.onDismiss = { [weak self] in
                guard let self else { return }
                self.usageStorage?.didHide()
                self.usageStorage = nil
                self.usageModal = nil
                self.navigationGeneration += 1
                if self.recordUsageModalClose { self.onRouteChange?() }
            }
            usage.didShow()
            navigationGeneration += 1
            onRouteChange?()
            return
        }
        if let usageModal { recordUsageModalClose = false; usageModal.close(animated: false) }
        let view: NSView = custom ?? pullRequestsPage.container
        if utilityKind == .pullRequests && page != .pullRequests { pullRequestsPage.didHide() }
        if utilityKind == .orchestrator && utilityPage != nil && page != .orchestrator { onOrchestratorHidden() }
        utilityPage?.removeFromSuperview()
        threads.panel.removeFromSuperview()
        layout.mainContent = view
        utilityPage = view
        utilityKind = page
        // Clears the active row and draft while the page shows. The Orchestrator opens like a thread: the sidebar
        // keeps its list, buttons and footer, and its own row shows it's open.
        sidebar.isOnUtilityPage = page != .orchestrator
        sidebar.showsOtherPage = page == .orchestrator
        if page == .pullRequests {
            pullRequestsPage.didShow()
            window?.makeFirstResponder(pullRequestsPage.container)
        }
        onRouteChange?()
    }

    /// Back (`navigateToMainApp`): the thread panel returns as it was. `record` false leaves the route
    /// history to the navigation that follows.
    func closeUtilityPage(record: Bool = true) {
        if let usageModal { recordUsageModalClose = record; usageModal.close(animated: record); return }
        guard let layout, let page = utilityPage else { return }
        if utilityKind == .pullRequests { pullRequestsPage.didHide() }
        let wasOrchestrator = utilityKind == .orchestrator
        page.removeFromSuperview()
        utilityPage = nil
        utilityKind = nil
        layout.mainContent = threads.panel
        sidebar?.isOnUtilityPage = false
        sidebar?.showsOtherPage = false
        sidebar?.state.activeThreadId = threads.openThreadId
        threads.composer.syncSidebarDrafts()
        threads.focusComposerOnReturn()
        if wasOrchestrator { onOrchestratorHidden() }
        if record { onRouteChange?() }
    }

    /// Runs a navigation to a thread or draft; from a utility page the page closes first and the
    /// history gets one entry, the destination.
    private func leavingUtilityPage(_ navigate: () -> Void) {
        guard usageModal != nil || utilityPage != nil else { return navigate() }
        closeUtilityPage(record: false)
        navigate()
        onRouteChange?()
    }

    /// Escape on Usage or Pull Requests (`useNavigateBack`): history back, else the thread view.
    private func goBack() {
        if !historyBack() { closeUtilityPage() }
    }
}
