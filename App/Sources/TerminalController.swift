import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store
import os

/// The open thread's terminals: the drawer under the chat (ChatView.tsx `PersistentThreadTerminalDrawer`,
/// ThreadTerminalDrawer.tsx), terminal tabs in the right panel (`PersistentThreadTerminalPanel`,
/// ChatView.tsx:1365-1530) and the sidebar's terminal indicator.
///
/// The drawer keeps T3's per-thread state (open, height, terminals and split groups); a terminal
/// tab keeps its terminals in its `RightPanelSurface`. Both talk to the thread's environment:
/// `terminal.open` for a new terminal, `terminal.attach` while it shows (a snapshot with the
/// server's retained history, then live output), `terminal.write` and `terminal.resize` from the
/// view, `terminal.close` when the user closes it or the shell exits. Every pane on screen is its
/// own SwiftTerm view with its own attach stream. A pane that leaves the screen (another group, a
/// hidden drawer, another tab, another thread) ends its stream and releases its view: the server
/// keeps the PTY and up to 5,000 lines, and the next attach replays them. So hidden terminals cost
/// no memory, drawing, timers or socket traffic.
///
/// The indicator comes from `subscribeTerminalMetadata`, one stream per connected environment.
@MainActor
final class TerminalController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private var states: [String: TerminalDrawerState]
    private var threadId: ThreadId?
    private let drawerHost: Host
    private let panelHost: Host
    private var metadata: [String: (session: ShellSession, task: Task<Void, Never>, activity: TerminalActivity)] = [:]
    private var modal: ModalHost?
    private var resizeObserver: NSObjectProtocol?
    isolated deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }
    /// "Add to chat" from a terminal: the composer inserts the excerpt chip.
    var onAddToChat: ((ComposerContext.TerminalSelection) -> Void)?

    /// One attached terminal: its view, the attach stream and an ordered outbox for writes and resizes.
    @MainActor
    private final class Attachment {
        let threadId: ThreadId
        let terminalId: String
        let surface: TerminalSurfaceView
        var model = TerminalSessionModel()
        var stream: Task<Void, Never>?
        var writer: Task<Void, Never>?
        let outbox: AsyncStream<(String, JSONValue)>.Continuation
        let ops: AsyncStream<(String, JSONValue)>
        /// The last grid sent, so a repeated size is not sent again.
        var sentGrid: (Int, Int)?

        init(threadId: ThreadId, terminalId: String, surface: TerminalSurfaceView) {
            self.threadId = threadId; self.terminalId = terminalId; self.surface = surface
            (ops, outbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        }

        func end() {
            stream?.cancel()
            stream = nil
            writer?.cancel()
            writer = nil
            outbox.finish()
        }
    }

    /// Where terminals show: the drawer or the active terminal tab. Each owns the panes it shows.
    @MainActor
    private final class Host {
        private let lazyView: LazyView<TerminalDrawerView>
        var attachments: [String: Attachment] = [:]
        init(_ lazyView: LazyView<TerminalDrawerView>) { self.lazyView = lazyView }
        /// The view, built now if it isn't yet.
        var view: TerminalDrawerView { lazyView.view }
        var loaded: TerminalDrawerView? { lazyView.loaded }

        var focused: Attachment? { attachments.values.first { $0.surface.isFocused } }

        func detachAll() {
            for a in attachments.values { a.end() }
            attachments = [:]
        }
    }

    init(panel: ThreadPanelView, sidebar: SidebarContentView?, environments: Environments) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        drawerHost = Host(panel.lazyTerminalDrawer)
        panelHost = Host(LazyView { [unowned panel] in panel.terminalPanel })
        states = Self.loadStates()
        panel.onTerminalToggle = { [weak self] in self?.toggle() }
        panel.lazyTerminalDrawer.configure { [weak self] drawer in self?.wireDrawer(drawer) }
        let tab = panel.terminalPanel
        tab.actions.onAction = { [weak self] action in self?.perform(action, inPanel: true) }
        tab.list.onAction = { [weak self] action in self?.perform(action, inPanel: true) }
        tab.list.onActivate = { [weak self] id in self?.activatePanelTerminal(id) }
        tab.list.onClose = { [weak self] id in self?.confirmClose([id]) { self?.closePanelTerminal(id) } }
        tab.emptyButton.action = { [weak self] in self?.addTerminalSurface() }
        panel.onAddTerminal = { [weak self] in self?.addTerminalSurface() }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
            let window = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let own = self.panel.window, ObjectIdentifier(own) == window else { return }
                self.windowResized()
            }
        }
    }

    /// The drawer's wiring and labels, when it is first built.
    private func wireDrawer(_ drawer: TerminalDrawerView) {
        drawer.actions.onAction = { [weak self] action in self?.perform(action, inPanel: false) }
        drawer.list.onAction = { [weak self] action in self?.perform(action, inPanel: false) }
        drawer.list.onActivate = { [weak self] id in self?.activate(id) }
        drawer.list.onClose = { [weak self] id in self?.confirmClose([id]) { self?.close(id) } }
        drawer.emptyButton.action = { [weak self] in self?.newTerminal() }
        drawer.onDrag = { [weak self] start, delta, ended in self?.drag(start: start, delta: delta, ended: ended) }
        updateLabels(state)
    }

    // MARK: Thread and environment changes

    /// The panel shows `id` (nil: a draft or nothing). Drafts get no drawer.
    // ponytail: no drawer on draft threads; T3 opens one against the draft's project. Add when drafts can run scripts
    func show(_ id: ThreadId?) {
        guard id != threadId else { return }
        drawerHost.detachAll()
        panelHost.detachAll()
        threadId = id
        refresh()
    }

    /// An environment's session started, was replaced or ended.
    func sessionChanged(_ environmentId: String) {
        let session = environments.session(environmentId)
        if metadata[environmentId]?.session !== session {
            metadata[environmentId]?.task.cancel()
            metadata[environmentId] = nil
            if let session { subscribeMetadata(environmentId, session) }
            publishActivity()
        }
        if threadId?.environmentId == environmentId {
            drawerHost.detachAll()
            panelHost.detachAll()
        }
        refresh()
    }

    /// The right panel's state changed (tab picked, opened or closed): the terminal tab follows.
    func panelChanged() { refresh() }

    /// Terminal tabs closed from the tab strip: their terminals stop on the server
    /// (`cleanupRightPanelSurfaces`, ChatView.tsx:6069-6105).
    func panelTerminalsClosed(_ surfaces: [TerminalPanelSurface]) {
        for surface in surfaces { for id in surface.terminalIds { stopOnServer(id) } }
    }

    /// Asks before a terminal tab closes from its tab (`closeRightPanelSurface`, ChatView.tsx:6150-6180).
    func confirmCloseSurface(_ surface: TerminalPanelSurface, then close: @escaping () -> Void) {
        let ordered = [surface.activeTerminalId] + surface.terminalIds.filter { $0 != surface.activeTerminalId }
        confirmClose(ordered, then: close)
    }

    // MARK: Shortcuts

    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.on("terminal.toggle") { [weak self] call in
            guard let self, self.threadId != nil, self.panel.window != nil else { return false }
            if !call.isRepeat { self.toggle() }
            return true
        }
        // ChatView.tsx:8103-8165: the focused terminal's owner takes the command.
        shortcuts.on(["terminal.split", "terminal.splitVertical", "terminal.new", "terminal.close"]) { [weak self] call in
            guard let self, self.isFocused else { return false }
            guard !call.isRepeat else { return true }
            let inPanel = self.panelHost.focused != nil
            let action: TerminalActionCluster.Action = switch call.command {
            case "terminal.split": .split
            case "terminal.splitVertical": .splitVertical
            case "terminal.new": .new
            default: .close
            }
            self.perform(action, inPanel: inPanel)
            return true
        }
        // T3's terminal key overrides (keybindings.ts `terminalNavigationShortcutData`,
        // `terminalDeleteShortcutData`, `isTerminalClearShortcut`): sent as input, never typed.
        shortcuts.onKey { [weak self] event in
            guard let self, let focused = self.focusedAttachment, let data = Self.keyData(event) else { return false }
            self.send(data, to: focused)
            return true
        }
    }

    private var focusedAttachment: Attachment? { drawerHost.focused ?? panelHost.focused }

    /// `terminalFocus`.
    var isFocused: Bool { focusedAttachment != nil }

    /// The bytes T3 sends for Cmd/Option+Left/Right, Cmd+Backspace and Ctrl+L/Cmd+K on macOS.
    static func keyData(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 123, 124: // left, right
            guard !flags.contains(.shift) else { return nil }
            let left = event.keyCode == 123
            if flags == .option { return left ? "\u{1b}b" : "\u{1b}f" }
            if flags == .command { return left ? "\u{01}" : "\u{05}" }
            return nil
        case 51: // backspace
            return flags == .command ? "\u{15}" : nil
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "l", flags == .control { return "\u{0c}" }
            if key == "k", flags == .command { return "\u{0c}" }
            return nil
        }
    }

    // MARK: Drawer state

    private var state: TerminalDrawerState {
        get { threadId.flatMap { states[$0.rawValue] } ?? TerminalDrawerState() }
        set {
            guard let threadId else { return }
            states[threadId.rawValue] = newValue == TerminalDrawerState() ? nil : newValue
            Self.saveStates(states)
        }
    }

    private var windowHeight: CGFloat { panel.window?.contentView?.bounds.height ?? panel.bounds.height }

    /// Puts both hosts and their attach streams in line with the open thread's state.
    private func refresh() {
        let state = state
        let shown = threadId != nil && state.open
        panel.setTerminal(open: shown, height: TerminalDrawerState.clampHeight(state.height, windowHeight: windowHeight))
        panel.terminalAvailable = threadId.flatMap(launch) != nil
        updateLabels(state)
        if shown, let threadId, let active = state.resolvedActiveId {
            let list = state.hasTerminalList ? TerminalListModel.make(state, label: label, closeShortcut: shortcut("terminal.close")) : nil
            sync(drawerHost, threadId, ids: state.visibleTerminalIds, direction: state.visibleSplitDirection, activeId: active, list: list)
        } else {
            sync(drawerHost, nil, ids: [], direction: .horizontal, activeId: "", list: nil)
        }
        let surface = panel.panelState.isOpen ? panel.panelState.active?.terminal : nil
        if let surface, let threadId {
            var tabState = TerminalDrawerState(open: true, terminalIds: surface.terminalIds, activeTerminalId: surface.activeTerminalId,
                                               terminalGroups: [TerminalGroup(id: "terminal:" + surface.resourceId, terminalIds: surface.terminalIds,
                                                                              splitDirection: surface.splitDirection)])
            tabState = tabState.normalized
            let list = tabState.hasTerminalList ? TerminalListModel.make(tabState, label: label, closeShortcut: shortcut("terminal.close")) : nil
            sync(panelHost, threadId, ids: surface.terminalIds, direction: surface.splitDirection, activeId: surface.activeTerminalId, list: list)
        } else {
            sync(panelHost, nil, ids: [], direction: .horizontal, activeId: "", list: nil)
        }
        updateTabTitles()
    }

    /// Attaches the panes `ids` in `host` and detaches the rest.
    private func sync(_ host: Host, _ threadId: ThreadId?, ids: [String], direction: TerminalGroup.Direction, activeId: String, list: TerminalListModel?) {
        for (id, a) in host.attachments where !ids.contains(id) || a.threadId != threadId {
            a.end()
            host.attachments[id] = nil
        }
        guard let threadId else {
            host.loaded?.show([], direction: direction, activeId: "", list: nil)
            return
        }
        var panes: [(id: String, surface: TerminalSurfaceView)] = []
        for id in ids {
            if host.attachments[id] == nil, let a = attach(threadId, id, host: host) { host.attachments[id] = a }
            if let a = host.attachments[id] { panes.append((id, a.surface)) }
        }
        host.view.show(panes, direction: direction, activeId: activeId, list: list)
        host.view.actions.setSplitLimitReached(ids.count >= TerminalDrawerState.maxPerGroup)
        host.view.list.setSplitLimitReached(ids.count >= TerminalDrawerState.maxPerGroup)
    }

    private func focusActive(_ host: Host, _ id: String?) {
        guard let id, let a = host.attachments[id] else { return }
        // A new view enters the window on the next layout pass.
        DispatchQueue.main.async { a.surface.focus() }
    }

    /// WorktreeSetupCard's Open terminal selects the already-created script terminal.
    func openExistingSetupTerminal(_ id: String) {
        guard threadId != nil else { return }
        var state = state
        if !state.terminalIds.contains(id) { state.newTerminal(id) }
        state.open = true; state.activate(id)
        self.state = state; refresh(); focusActive(drawerHost, id)
    }

    /// `toggleTerminalVisibility` (ChatView.tsx:4781-4830): opening a thread with no terminals
    /// opens `term-1` on the server first.
    func toggle() {
        guard threadId != nil else { return }
        var state = state
        if !state.open && state.terminalIds.isEmpty {
            newTerminal()
            return
        }
        state.open.toggle()
        self.state = state
        refresh()
        if state.open { focusActive(drawerHost, state.resolvedActiveId) } else { focusComposer() }
    }

    /// The lowest free `term-N` for the thread: the drawer's, the tabs' and the server's terminals.
    private func allocateTerminalId(_ threadId: ThreadId) -> String {
        let known = metadata[threadId.environmentId ?? ""]?.activity.terminalIds(threadId: threadId.localId.rawValue) ?? []
        return TerminalLabels.nextId(state.terminalIds + Array(panel.panelState.panelTerminalIds) + known)
    }

    /// `terminal.open` for a new terminal at the thread's launch location.
    private func openOnServer(_ threadId: ThreadId, _ terminalId: String) {
        guard let launch = launch(threadId), let shell = environments.session(threadId.environmentId) else { return }
        let payload = TerminalRPC.openInput(threadId: threadId.localId.rawValue, terminalId: terminalId, launch: launch)
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request(TerminalRPC.open, payload: payload)
            } catch {
                self?.panel.toasts.show(ToastView(title: "Could not open terminal", message: "\(error)", kind: .error))
            }
        }
    }

    /// `createNewTerminal`, `splitTerminal` and `splitTerminalVertical` (ChatView.tsx:1167-1250, 4831-4870).
    private func newTerminal(split direction: TerminalGroup.Direction? = nil) {
        guard let threadId, launch(threadId) != nil, environments.session(threadId.environmentId) != nil else { return }
        var state = state
        if direction != nil, state.hasReachedSplitLimit { return }
        let terminalId = allocateTerminalId(threadId)
        if let direction { state.split(terminalId, direction: direction) } else { state.newTerminal(terminalId) }
        self.state = state
        openOnServer(threadId, terminalId)
        refresh()
        focusActive(drawerHost, terminalId)
    }

    private func perform(_ action: TerminalActionCluster.Action, inPanel: Bool) {
        if inPanel {
            switch action {
            case .split: splitPanelTerminal(.horizontal)
            case .splitVertical: splitPanelTerminal(.vertical)
            case .new: addTerminalSurface()
            case .close:
                if let id = panel.panelState.active?.terminal?.activeTerminalId { confirmClose([id]) { [weak self] in self?.closePanelTerminal(id) } }
            }
            return
        }
        switch action {
        case .split: newTerminal(split: .horizontal)
        case .splitVertical: newTerminal(split: .vertical)
        case .new: newTerminal()
        case .close: if let id = state.resolvedActiveId { confirmClose([id]) { [weak self] in self?.close(id) } }
        }
    }

    /// `activateTerminal`: a list row, a group header or a click in a pane.
    private func activate(_ terminalId: String) {
        var state = state
        state.activate(terminalId)
        guard state != self.state else { return }
        self.state = state
        refresh()
        focusActive(drawerHost, terminalId)
    }

    /// `confirmTerminalClose` (lib/terminalCloseConfirm.ts:16-36): one terminal asks by name, several list them.
    private func confirmClose(_ terminalIds: [String], then close: @escaping () -> Void) {
        guard let window = panel.window, modal == nil, !terminalIds.isEmpty else { return }
        let labels = terminalIds.map(label)
        let title = labels.count == 1 ? "Close terminal \"\(labels[0])\"?" : "Close \(labels.count) terminals?"
        let message = labels.count == 1 ? "This stops the running process and clears its history."
            : "This stops their running processes and clears their histories: \(labels.map { "\"\($0)\"" }.joined(separator: ", "))."
        let dialog = DialogView(kind: .alertDialog, title: title, message: message)
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host] in
            host?.close()
            close()
        }
    }

    /// `terminal.close` with `deleteHistory`, falling back to typing `exit` when the close fails.
    private func stopOnServer(_ terminalId: String) {
        guard let threadId, let shell = environments.session(threadId.environmentId) else { return }
        let local = threadId.localId.rawValue
        Task {
            do {
                _ = try await shell.supervisor.request(TerminalRPC.close, payload: TerminalRPC.closeInput(threadId: local, terminalId: terminalId, deleteHistory: true))
            } catch {
                _ = try? await shell.supervisor.request(TerminalRPC.write, payload: TerminalRPC.writeInput(threadId: local, terminalId: terminalId, data: "exit\n"))
            }
        }
    }

    /// `closeTerminal` (ChatView.tsx:1265-1295): the drawer drops the terminal at once.
    private func close(_ terminalId: String) {
        guard threadId != nil else { return }
        stopOnServer(terminalId)
        var state = state
        state.close(terminalId)
        self.state = state
        refresh()
        if state.open { focusActive(drawerHost, state.resolvedActiveId) } else { focusComposer() }
    }

    private func focusComposer() { panel.composer.focus() }

    // MARK: Project scripts (ChatView.tsx:4956-5100)

    /// `runProjectScript`: the drawer opens on the active terminal, or a new one (120 x 30) when that
    /// one runs a command; `terminal.open`, then the command and Return.
    /// A script's command reached its terminal (the preview URL opens then).
    var onScriptStarted: ((ProjectScript) -> Void)?

    func runScript(_ script: ProjectScript) {
        guard let threadId, let launch = launch(threadId), let shell = environments.session(threadId.environmentId) else { return }
        var state = state
        let known = metadata[threadId.environmentId ?? ""]?.activity.terminalIds(threadId: threadId.localId.rawValue) ?? []
        let base = state.resolvedActiveId ?? known.first ?? "term-1"
        let busy = summary(base)?.hasRunningSubprocess == true
        let terminalId = busy ? allocateTerminalId(threadId) : base
        if busy || !state.terminalIds.contains(terminalId) { state.newTerminal(terminalId) } else { state.activate(terminalId); state.open = true }
        self.state = state
        refresh()
        focusActive(drawerHost, terminalId)
        var payload = TerminalRPC.openInput(threadId: threadId.localId.rawValue, terminalId: terminalId, launch: launch)
        if busy, case .object(var o) = payload {
            o["cols"] = .number(120)
            o["rows"] = .number(30)
            payload = .object(o)
        }
        let local = threadId.localId.rawValue
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request(TerminalRPC.open, payload: payload)
                _ = try await shell.supervisor.request(TerminalRPC.write, payload: TerminalRPC.writeInput(threadId: local, terminalId: terminalId, data: script.command + "\r"))
                self?.onScriptStarted?(script)
            } catch {
                self?.panel.toasts.show(ToastView(title: "Failed to run script \"\(script.name)\".", message: (error as? RPCClientError)?.typedError?.message, kind: .error))
            }
        }
    }

    // MARK: Terminal tabs (ChatView.tsx:5895-6010)

    /// `addTerminalSurface`: a new tab with a new terminal.
    private func addTerminalSurface() {
        guard let threadId, launch(threadId) != nil, environments.session(threadId.environmentId) != nil else { return }
        let terminalId = allocateTerminalId(threadId)
        panel.mutatePanel { $0.openTerminal(terminalId); return [] }
        openOnServer(threadId, terminalId)
        focusActive(panelHost, terminalId)
    }

    /// `splitPanelTerminal`: another terminal in the active tab, at most four.
    private func splitPanelTerminal(_ direction: TerminalGroup.Direction) {
        guard let threadId, let surface = panel.panelState.active?.terminal, let surfaceId = panel.panelState.activeSurfaceId,
              surface.terminalIds.count < TerminalDrawerState.maxPerGroup else { return }
        let terminalId = allocateTerminalId(threadId)
        panel.mutatePanel { $0.splitTerminal(surfaceId, terminalId: terminalId, direction: direction); return [] }
        openOnServer(threadId, terminalId)
        focusActive(panelHost, terminalId)
    }

    private func activatePanelTerminal(_ terminalId: String) {
        guard let surfaceId = panel.panelState.activeSurfaceId, panel.panelState.active?.terminal?.activeTerminalId != terminalId else { return }
        panel.mutatePanel { $0.activateTerminal(surfaceId, terminalId: terminalId); return [] }
        focusActive(panelHost, terminalId)
    }

    /// `closePanelTerminal`: the tab's last terminal closes the tab.
    private func closePanelTerminal(_ terminalId: String) {
        guard let surfaceId = panel.panelState.activeSurfaceId else { return }
        stopOnServer(terminalId)
        panel.mutatePanel { $0.closeTerminal(surfaceId, terminalId: terminalId); return [] }
        focusActive(panelHost, panel.panelState.active?.terminal?.activeTerminalId)
    }

    /// Each terminal tab's title: the server's label for its active terminal.
    private func updateTabTitles() {
        var titles: [String: String] = [:]
        for surface in panel.panelState.surfaces {
            guard let t = surface.terminal else { continue }
            titles[surface.id] = label(t.activeTerminalId)
        }
        if panel.terminalTitles != titles { panel.terminalTitles = titles }
    }

    // MARK: Height

    private func drag(start: CGFloat, delta: CGFloat, ended: Bool) {
        let height = TerminalDrawerState.clampHeight(start + delta, windowHeight: windowHeight)
        panel.setTerminal(open: true, height: height)
        if ended {
            var state = state
            state.height = height
            self.state = state
        }
    }

    private func windowResized() {
        guard threadId != nil, state.open else { return }
        panel.setTerminal(open: true, height: TerminalDrawerState.clampHeight(state.height, windowHeight: windowHeight))
    }

    // MARK: Attach

    /// Where the thread's terminals start: its worktree or its project's root.
    func launch(_ threadId: ThreadId) -> TerminalRPC.Launch? {
        guard let snapshot = sidebar?.snapshot,
              let thread = snapshot.threads.first(where: { $0.id == threadId }) ?? snapshot.archivedThreads.first(where: { $0.id == threadId }),
              let project = snapshot.projects.first(where: { $0.id == thread.projectId }) else { return nil }
        let worktree = thread.worktreePath.flatMap { $0.isEmpty ? nil : $0 }
        return TerminalRPC.Launch(projectRoot: project.workspaceRoot, worktreePath: worktree)
    }

    private func attach(_ threadId: ThreadId, _ terminalId: String, host: Host) -> Attachment? {
        guard let shell = environments.session(threadId.environmentId), let launch = launch(threadId) else { return nil }
        let surface = TerminalSurfaceView()
        let attachment = Attachment(threadId: threadId, terminalId: terminalId, surface: surface)
        let local = threadId.localId.rawValue
        surface.onInput = { [weak self, weak attachment] data in
            guard let self, let attachment else { return }
            self.send(data, to: attachment)
        }
        surface.onResize = { [weak self, weak attachment, weak host] cols, rows in
            guard let self, let attachment, host?.attachments[terminalId] === attachment else { return }
            self.resize(attachment, cols: cols, rows: rows)
        }
        surface.onLink = { [weak self, weak surface] link in
            guard let surface else { return }
            self?.openLink(link, cwd: launch.cwd, threadId: threadId, surface: surface)
        }
        surface.onFocus = { [weak self, weak host] in
            guard let self, let host else { return }
            if host === self.panelHost { self.activatePanelTerminal(terminalId) } else if self.state.activeTerminalId != terminalId { self.activate(terminalId) }
        }
        surface.onAddToChat = { [weak self] text, start, end in
            guard let self else { return }
            let selection = ComposerContext.TerminalSelection(terminalId: terminalId, terminalLabel: self.label(terminalId),
                                                              lineStart: start, lineEnd: end, text: text)
            if let normalized = selection.normalized { self.onAddToChat?(normalized) }
        }
        let supervisor = shell.supervisor
        attachment.writer = Task { [ops = attachment.ops] in
            for await (tag, payload) in ops {
                _ = try? await supervisor.request(tag, payload: payload)
            }
        }
        // An unanswered first attach retries unchanged so it can still open the shell. Once a reply arrived,
        // resubscribing sends `resume` (client-runtime/src/state/terminal.ts:47-58).
        let payload = TerminalRPC.attachInput(threadId: local, terminalId: terminalId, launch: launch)
        let resumed = TerminalRPC.attachInput(threadId: local, terminalId: terminalId, launch: launch, resume: true)
        let replied = OSAllocatedUnfairLock(initialState: false)
        attachment.stream = supervisor.subscribe(TerminalRPC.attach, payload: { replied.withLock { $0 } ? resumed : payload }, handler: { [weak self, weak host, weak attachment] event in
            guard case .value(let json) = event else { return }
            replied.withLock { $0 = true }
            guard let item = TerminalAttachEvent(json: json) else { return }
            await MainActor.run {
                guard let self, let host, let attachment else { return }
                self.apply(item, to: attachment, in: host)
            }
        })
        return attachment
    }

    private func apply(_ event: TerminalAttachEvent, to attachment: Attachment, in host: Host) {
        guard host.attachments[attachment.terminalId] === attachment else { return }
        let outcome = attachment.model.apply(event)
        for action in outcome.actions { attachment.surface.apply(action) }
        if outcome.resendSize { attachment.sentGrid = nil; attachment.surface.resendSize() }
        if outcome.sessionEnded {
            // `onSessionExited` runs on the next tick, after the message shows.
            let terminalId = attachment.terminalId
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host, host.attachments[terminalId] === attachment else { return }
                if host === self.panelHost {
                    guard let surfaceId = self.panel.panelState.activeSurfaceId else { return }
                    self.panel.mutatePanel { $0.closeTerminal(surfaceId, terminalId: terminalId); return [] }
                } else {
                    self.close(terminalId)
                }
            }
        }
    }

    private func send(_ data: String, to attachment: Attachment) {
        let local = attachment.threadId.localId.rawValue
        for chunk in TerminalRPC.writeChunks(data) {
            attachment.outbox.yield((TerminalRPC.write, TerminalRPC.writeInput(threadId: local, terminalId: attachment.terminalId, data: chunk)))
        }
    }

    private func resize(_ attachment: Attachment, cols: Int, rows: Int) {
        guard attachment.model.canResize, attachment.sentGrid.map({ $0 != (cols, rows) }) ?? true else { return }
        attachment.sentGrid = (cols, rows)
        let local = attachment.threadId.localId.rawValue
        attachment.outbox.yield((TerminalRPC.resize, TerminalRPC.resizeInput(threadId: local, terminalId: attachment.terminalId, cols: cols, rows: rows)))
    }

    /// `handleLinkActivate` (ThreadTerminalDrawer.tsx:939-990): URLs open in the browser panel or the browser.
    /// Paths resolve against the terminal's folder (`resolvePathLinkTarget`) and open in the preferred editor
    /// on the thread's machine (`useOpenInPreferredEditor`); a failure prints in the terminal.
    var openBrowserLink: ((URL) -> Bool)?
    /// The editors an environment's server reports (`serverConfig.availableEditors`).
    var availableEditors: ((String) -> [String]?)?
    private func openLink(_ link: String, cwd: String, threadId: ThreadId, surface: TerminalSurfaceView) {
        if TerminalLinks.isURL(link) {
            if let url = URL(string: link), openBrowserLink?(url) != true { NSWorkspace.shared.open(url) }
            return
        }
        guard let env = threadId.environmentId else { return }
        let target = FileLinks.resolveAgainst(link, cwd: cwd)
        let defaults = UserDefaults.standard
        guard let editor = OpenInEditors.preferred(available: availableEditors?(env) ?? [], last: defaults.string(forKey: OpenInEditors.lastEditorKey)) else {
            surface.apply(.message("No available editor can open \(target) in environment \(env)."))
            return
        }
        // `resolveAndPersistPreferredEditor` keeps the editor it picked.
        defaults.set(editor, forKey: OpenInEditors.lastEditorKey)
        Task { [weak self, weak surface] in
            do {
                _ = try await self?.environments.request(env, "shell.openInEditor", OpenInEditors.launchInput(cwd: target, editor: editor))
            } catch {
                surface?.apply(.message((error as? RPCClientError)?.typedError?.fields["message"]?.stringValue ?? "Unable to open path"))
            }
        }
    }

    // MARK: Labels

    private func summary(_ terminalId: String) -> TerminalSummary? {
        guard let threadId else { return nil }
        return metadata[threadId.environmentId ?? ""]?.activity.summary(threadId: threadId.localId.rawValue, terminalId: terminalId)
    }

    /// `resolveTerminalSessionLabel`: the server's label, else "Terminal N".
    private func label(_ terminalId: String) -> String { TerminalLabels.label(terminalId, summary: summary(terminalId)) }

    private func shortcut(_ command: String) -> String? {
        ActiveKeymap.label(for: command, context: KeybindingContext(["terminalFocus": true, "terminalOpen": true]))
    }

    /// The tooltips with the current shortcut labels (`splitTerminalActionLabel`...).
    private func updateLabels(_ state: TerminalDrawerState) {
        let label = { (title: String, command: String) -> String in
            self.shortcut(command).map { "\(title) (\($0))" } ?? title
        }
        let max = TerminalDrawerState.maxPerGroup
        let limitDrawer = state.hasReachedSplitLimit
        let limitPanel = (panel.panelState.active?.terminal?.terminalIds.count ?? 0) >= max
        let new = label("New Terminal", "terminal.new"), close = label("Close Terminal", "terminal.close")
        for (view, limit) in [(panel.lazyTerminalDrawer.loaded, limitDrawer), (panel.terminalPanel, limitPanel)] {
            guard let view else { continue }
            let split = limit ? "Split Terminal Horizontally (max \(max) per group)" : label("Split Terminal Horizontally", "terminal.split")
            let vertical = limit ? "Split Terminal Vertically (max \(max) per group)" : label("Split Terminal Vertically", "terminal.splitVertical")
            view.actions.setLabels(split: split, splitVertical: vertical, new: new, close: close)
            view.list.setLabels(split: split, splitVertical: vertical, new: new, close: close)
            view.emptyButton.title = new
        }
    }

    // MARK: Metadata

    private func subscribeMetadata(_ environmentId: String, _ session: ShellSession) {
        let task = session.supervisor.subscribe(TerminalRPC.metadata, payload: { .object([:]) }, handler: { [weak self] event in
            guard case .value(let json) = event, let item = TerminalMetadataEvent(json: json) else { return }
            await MainActor.run {
                guard let self, self.metadata[environmentId]?.session === session else { return }
                let before = self.metadata[environmentId]?.activity
                if self.metadata[environmentId]?.activity.apply(item) == true { self.publishActivity() }
                // A label change (the running command) renames list rows and tab titles.
                if self.threadId?.environmentId == environmentId, self.metadata[environmentId]?.activity != before { self.relabel() }
            }
        })
        metadata[environmentId] = (session, task, TerminalActivity())
    }

    /// Only the labels changed: the list and tab titles, no attach work.
    private func relabel() {
        let state = state
        if state.open, state.hasTerminalList {
            panel.lazyTerminalDrawer.loaded?.list.apply(TerminalListModel.make(state, label: label, closeShortcut: shortcut("terminal.close")))
        }
        if let surface = panel.panelState.active?.terminal, surface.terminalIds.count > 1 {
            let tab = TerminalDrawerState(open: true, terminalIds: surface.terminalIds, activeTerminalId: surface.activeTerminalId,
                                          terminalGroups: [TerminalGroup(id: "terminal:" + surface.resourceId, terminalIds: surface.terminalIds,
                                                                         splitDirection: surface.splitDirection)]).normalized
            panel.terminalPanel.list.apply(TerminalListModel.make(tab, label: label, closeShortcut: shortcut("terminal.close")))
        }
        updateTabTitles()
    }

    private func publishActivity() {
        var processes: [ThreadId: Int] = [:]
        for (environmentId, entry) in metadata {
            for (thread, count) in entry.activity.runningThreads {
                processes[ThreadId(EnvironmentScope.key(environmentId, thread))] = count
            }
        }
        if sidebar?.state.terminalProcesses != processes { sidebar?.state.terminalProcesses = processes }
    }

    // MARK: Persistence

    /// `t3code:terminal-ui-state` in T3; per scoped thread id here, defaults left out.
    private static let statesKey = "thread.terminalDrawer"

    private static func loadStates() -> [String: TerminalDrawerState] {
        guard let data = UserDefaults.standard.data(forKey: statesKey),
              let states = try? JSONDecoder().decode([String: TerminalDrawerState].self, from: data) else { return [:] }
        return states
    }

    private static func saveStates(_ states: [String: TerminalDrawerState]) {
        // ponytail: every thread's entry is kept until the environment goes; prune by age if the list grows large
        UserDefaults.standard.set(try? JSONEncoder().encode(states), forKey: statesKey)
    }

    /// A removed environment's drawers go with it.
    func environmentRemoved(_ environmentId: String) {
        states = states.filter { !$0.key.hasPrefix(environmentId + ":") }
        Self.saveStates(states)
    }
}
