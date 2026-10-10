import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The open thread's terminal drawer (ChatView.tsx `PersistentThreadTerminalDrawer`,
/// ThreadTerminalDrawer.tsx) and the sidebar's terminal indicator.
///
/// The drawer keeps T3's per-thread state (open, height, terminals) and talks to the thread's
/// environment: `terminal.open` for a new terminal, `terminal.attach` while it shows (a snapshot
/// with the server's retained history, then live output), `terminal.write` and `terminal.resize`
/// from the view, `terminal.close` when the user closes it or the shell exits. Closing the drawer
/// or leaving the thread ends the attach stream and releases the view: the server keeps the PTY
/// and up to 5,000 lines, and the next open replays them. So a hidden drawer costs no memory,
/// drawing, timers or socket traffic.
///
/// The indicator comes from `subscribeTerminalMetadata`, one stream per connected environment.
@MainActor
final class TerminalController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private var states: [String: TerminalDrawerState]
    private var threadId: ThreadId?
    private var attachment: Attachment?
    private var metadata: [String: (session: ShellSession, task: Task<Void, Never>, activity: TerminalActivity)] = [:]
    private var modal: ModalHost?

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
            writer?.cancel()
            outbox.finish()
        }
    }

    init(panel: ThreadPanelView, sidebar: SidebarContentView?, environments: Environments) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        states = Self.loadStates()
        panel.onTerminalToggle = { [weak self] in self?.toggle() }
        panel.terminalDrawer.actions.onAction = { [weak self] action in self?.perform(action) }
        panel.terminalDrawer.emptyButton.action = { [weak self] in self?.newTerminal() }
        panel.terminalDrawer.onDrag = { [weak self] start, delta, ended in self?.drag(start: start, delta: delta, ended: ended) }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
            let window = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let own = self.panel.window, ObjectIdentifier(own) == window else { return }
                self.windowResized()
            }
        }
    }

    // MARK: Thread and environment changes

    /// The panel shows `id` (nil: a draft or nothing). Drafts get no drawer.
    // ponytail: no drawer on draft threads; T3 opens one against the draft's project. Add when drafts can run scripts
    func show(_ id: ThreadId?) {
        guard id != threadId else { return }
        detach()
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
        if let attachment, attachment.threadId.environmentId == environmentId { detach() }
        refresh()
    }

    // MARK: Shortcuts

    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.on("terminal.toggle") { [weak self] call in
            guard let self, self.threadId != nil, self.panel.window != nil else { return false }
            if !call.isRepeat { self.toggle() }
            return true
        }
        shortcuts.on("terminal.close") { [weak self] call in
            guard let self, self.isFocused, let id = self.attachment?.terminalId else { return false }
            if !call.isRepeat { self.confirmClose(id) }
            return true
        }
        shortcuts.on("terminal.new") { [weak self] call in
            guard let self, self.isFocused else { return false }
            if !call.isRepeat { self.newTerminal() }
            return true
        }
        // T3's terminal key overrides (keybindings.ts `terminalNavigationShortcutData`,
        // `terminalDeleteShortcutData`, `isTerminalClearShortcut`): sent as input, never typed.
        shortcuts.onKey { [weak self] event in
            guard let self, self.isFocused, let data = Self.keyData(event) else { return false }
            self.send(data)
            return true
        }
    }

    /// `terminalFocus`.
    var isFocused: Bool { attachment?.surface.isFocused ?? false }

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

    /// Puts the panel and the attach stream in line with the open thread's state.
    private func refresh() {
        let state = state
        let shown = threadId != nil && state.open
        panel.setTerminal(open: shown, height: TerminalDrawerState.clampHeight(state.height, windowHeight: windowHeight))
        updateLabels()
        guard shown, let threadId, let terminalId = state.resolvedActiveId else {
            detach()
            panel.terminalDrawer.surface = nil
            return
        }
        if attachment?.terminalId == terminalId, attachment?.threadId == threadId { return }
        attach(threadId, terminalId)
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
        if state.open { attachment?.surface.focus() } else { focusComposer() }
    }

    /// `createNewTerminal`: the lowest free `term-N` (counting the server's terminals for the
    /// thread), opened on the server, then attached.
    // ponytail: one terminal shows at a time; T3's split groups and the terminal list (more than
    // one terminal) are not drawn. New Terminal replaces the shown one; the others keep running.
    private func newTerminal() {
        guard let threadId, let launch = launch(threadId), let shell = environments.session(threadId.environmentId) else { return }
        let known = metadata[threadId.environmentId ?? ""]?.activity.terminalIds(threadId: threadId.localId.rawValue) ?? []
        var state = state
        let terminalId = TerminalLabels.nextId(state.terminalIds + known)
        state.ensure(terminalId)
        self.state = state
        let payload = TerminalRPC.openInput(threadId: threadId.localId.rawValue, terminalId: terminalId, launch: launch)
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request(TerminalRPC.open, payload: payload)
            } catch {
                self?.panel.toasts.show(ToastView(title: "Could not open terminal", message: "\(error)", kind: .error))
            }
        }
        refresh()
        attachment?.surface.focus()
    }

    private func perform(_ action: TerminalActionCluster.Action) {
        switch action {
        case .new, .split, .splitVertical: newTerminal()
        case .close: if let id = attachment?.terminalId { confirmClose(id) }
        }
    }

    /// `confirmTerminalClose`, then `closeTerminal`.
    private func confirmClose(_ terminalId: String) {
        guard let window = panel.window, modal == nil else { return }
        let label = TerminalLabels.label(terminalId, summary: summary(terminalId))
        let dialog = DialogView(kind: .alertDialog, title: "Close terminal \"\(label)\"?",
                                message: "This stops the running process and clears its history.")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in
            host?.close()
            self?.close(terminalId)
        }
    }

    /// `closeTerminal` (ChatView.tsx:1265-1295): `terminal.close` with `deleteHistory`, falling back
    /// to typing `exit` when the close fails; the drawer drops the terminal at once.
    private func close(_ terminalId: String) {
        guard let threadId, let shell = environments.session(threadId.environmentId) else { return }
        let local = threadId.localId.rawValue
        Task {
            do {
                _ = try await shell.supervisor.request(TerminalRPC.close, payload: TerminalRPC.closeInput(threadId: local, terminalId: terminalId, deleteHistory: true))
            } catch {
                _ = try? await shell.supervisor.request(TerminalRPC.write, payload: TerminalRPC.writeInput(threadId: local, terminalId: terminalId, data: "exit\n"))
            }
        }
        var state = state
        state.close(terminalId)
        self.state = state
        if attachment?.terminalId == terminalId { detach() }
        refresh()
        if state.open { attachment?.surface.focus() } else { focusComposer() }
    }

    private func focusComposer() { panel.composer.focus() }

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
    private func launch(_ threadId: ThreadId) -> TerminalRPC.Launch? {
        guard let snapshot = sidebar?.snapshot,
              let thread = snapshot.threads.first(where: { $0.id == threadId }) ?? snapshot.archivedThreads.first(where: { $0.id == threadId }),
              let project = snapshot.projects.first(where: { $0.id == thread.projectId }) else { return nil }
        let worktree = thread.worktreePath.flatMap { $0.isEmpty ? nil : $0 }
        return TerminalRPC.Launch(projectRoot: project.workspaceRoot, worktreePath: worktree)
    }

    private func attach(_ threadId: ThreadId, _ terminalId: String) {
        detach()
        guard let shell = environments.session(threadId.environmentId), let launch = launch(threadId) else {
            panel.terminalDrawer.surface = nil
            return
        }
        let surface = TerminalSurfaceView()
        let attachment = Attachment(threadId: threadId, terminalId: terminalId, surface: surface)
        self.attachment = attachment
        panel.terminalDrawer.surface = surface
        let local = threadId.localId.rawValue
        surface.onInput = { [weak self] data in self?.send(data) }
        surface.onResize = { [weak self, weak attachment] cols, rows in
            guard let self, let attachment, attachment === self.attachment else { return }
            self.resize(attachment, cols: cols, rows: rows)
        }
        surface.onLink = { [weak self] link in self?.openLink(link, cwd: launch.cwd) }
        let supervisor = shell.supervisor
        attachment.writer = Task { [ops = attachment.ops] in
            for await (tag, payload) in ops {
                _ = try? await supervisor.request(tag, payload: payload)
            }
        }
        let payload = TerminalRPC.attachInput(threadId: local, terminalId: terminalId, launch: launch)
        attachment.stream = supervisor.subscribe(TerminalRPC.attach, payload: { payload }, handler: { [weak self] event in
            guard case .value(let json) = event, let item = TerminalAttachEvent(json: json) else { return }
            await MainActor.run { self?.apply(item, to: attachment) }
        })
    }

    private func detach() {
        attachment?.end()
        attachment = nil
    }

    private func apply(_ event: TerminalAttachEvent, to attachment: Attachment) {
        guard attachment === self.attachment else { return }
        let outcome = attachment.model.apply(event)
        for action in outcome.actions { attachment.surface.apply(action) }
        if outcome.resendSize { attachment.sentGrid = nil; attachment.surface.resendSize() }
        if outcome.sessionEnded {
            // `onSessionExited` runs on the next tick, after the message shows.
            let terminalId = attachment.terminalId
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attachment === attachment else { return }
                self.close(terminalId)
            }
        }
    }

    private func send(_ data: String) {
        guard let attachment else { return }
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

    /// `handleLinkActivate`: URLs open in the browser, paths in the default app.
    // ponytail: URLs skip T3's built-in preview (WP7.6) and paths open with the default app, not the
    // preferred editor; route both there when the preview panel and editor picker land
    private func openLink(_ link: String, cwd: String) {
        if link.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            return
        }
        let path = link.hasPrefix("/") ? link : (cwd as NSString).appendingPathComponent(link)
        let file = path.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        NSWorkspace.shared.open(URL(fileURLWithPath: file))
    }

    // MARK: Labels

    private func summary(_ terminalId: String) -> TerminalSummary? {
        guard let threadId else { return nil }
        return metadata[threadId.environmentId ?? ""]?.activity.summary(threadId: threadId.localId.rawValue, terminalId: terminalId)
    }

    /// The cluster's tooltips with the current shortcut labels (`splitTerminalActionLabel`...).
    private func updateLabels() {
        let context = KeybindingContext(["terminalFocus": true, "terminalOpen": true])
        let label = { (title: String, command: String) -> String in
            ActiveKeymap.label(for: command, context: context).map { "\(title) (\($0))" } ?? title
        }
        let new = label("New Terminal", "terminal.new")
        panel.terminalDrawer.actions.setLabels(split: label("Split Terminal Horizontally", "terminal.split"),
                                               splitVertical: label("Split Terminal Vertically", "terminal.splitVertical"),
                                               new: new, close: label("Close Terminal", "terminal.close"))
        panel.terminalDrawer.emptyButton.title = new
    }

    // MARK: Metadata

    private func subscribeMetadata(_ environmentId: String, _ session: ShellSession) {
        let task = session.supervisor.subscribe(TerminalRPC.metadata, payload: { .object([:]) }, handler: { [weak self] event in
            guard case .value(let json) = event, let item = TerminalMetadataEvent(json: json) else { return }
            await MainActor.run {
                guard let self, self.metadata[environmentId]?.session === session else { return }
                if self.metadata[environmentId]?.activity.apply(item) == true { self.publishActivity() }
            }
        })
        metadata[environmentId] = (session, task, TerminalActivity())
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
