import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The right panel's tabs per thread and its file surfaces (rightPanelStore.ts, closedViewStore.ts,
/// FileBrowserPanel.tsx, FilePreviewPanel.tsx, ProjectFilePicker.tsx). Talks to the thread's
/// environment through `projects.listEntries`, `projects.searchEntries`, `projects.readFile`,
/// `projects.writeFile` and `assets.createUrl` (packages/contracts/src/project.ts:250-520).
@MainActor
final class FilesController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    /// Opens another thread (Mod+Shift+T restoring a tab that closed elsewhere).
    var openThread: ((ThreadId) -> Void)?
    /// The panel's state or thread changed: the pull request surfaces follow.
    var onSync: (() -> Void)?

    private var threadId: ThreadId?
    private var states: [String: RightPanelState] = [:]
    private var order: [String] = []
    private var closed = ClosedPanelTabs()

    /// The open thread's workspace: environment, cwd and project title.
    private struct Workspace: Equatable {
        var environmentId: String
        var threadId: ThreadId
        var cwd: String
        var projectName: String
    }
    private var workspace: Workspace?
    private var searchTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    /// Unsaved and saving edits per `cwd\0path` (`optimisticFileAtom`).
    private var buffers: [String: Buffer] = [:]
    private final class Buffer {
        var edited: String?
        var coordinator: FileSaveCoordinator?
    }
    /// Read results per `cwd\0path`, dropped on refresh.
    private var reads: [String: FileSurfaceView.Content] = [:]

    static let statesKey = "rightPanel.states.v1"
    static let closedKey = "rightPanel.closed.v1"
    static let legacyOpenKey = "thread.rightPanelOpen"

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        load()
        panel.onPanelChange = { [weak self] state, closed in self?.panelChanged(state, closed: closed) }
        let files = panel.filesPanel
        files.onLoad = { [weak self] dirs in self?.loadDirectories(dirs) }
        files.onSearch = { [weak self] query in self?.searchTree(query) }
        files.onOpenFile = { [weak self] path in self?.openFile(path, line: nil) }
        files.onRefresh = { [weak self] in self?.refreshTree() }
        files.treeView.onDragPayload = { path in FileMentions.serialize(path) }
        let surface = panel.fileSurface
        surface.onEdit = { [weak self] text in self?.edited(text) }
        surface.onOpenFile = { [weak self] path in self?.openFile(path, line: nil) }
        surface.browseDirectory = { [weak self] dir in await self?.listDirectory(dir) }
        surface.fetchData = { url in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 else { return nil }
            return data
        }
        surface.onExplorerChange = { [weak self] _ in self?.panel.filesPanel.treeView.selectedPath = self?.activeFilePath }
        surface.onNeedsReload = { [weak self] in self?.showActiveFile(force: true) }
    }

    // MARK: Persistence

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.statesKey),
           let saved = try? JSONDecoder().decode([String: RightPanelState].self, from: data) {
            states = saved
            order = Array(saved.keys)
        } else if let open = d.stringArray(forKey: Self.legacyOpenKey) {
            // Before tabs the panel was the diff alone, open or closed per thread.
            for id in open { states[id] = RightPanelState(isOpen: true, activeSurfaceId: "diff", surfaces: [.diff]); order.append(id) }
        }
        if let data = d.data(forKey: Self.closedKey), let c = try? JSONDecoder().decode(ClosedPanelTabs.self, from: data) { closed = c }
    }

    private func save() {
        // ponytail: newest 200 threads; T3 keeps every thread's entry
        if order.count > 200 { for key in order.prefix(order.count - 200) { states[key] = nil }; order.removeFirst(order.count - 200) }
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(states), forKey: Self.statesKey)
        d.set(try? JSONEncoder().encode(closed), forKey: Self.closedKey)
    }

    private func store(_ state: RightPanelState, for key: String) {
        order.removeAll { $0 == key }
        if state.isEmpty { states[key] = nil } else { states[key] = state; order.append(key) }
        save()
    }

    // MARK: Thread

    /// The panel follows the open thread (nil on a draft, where it stays closed).
    func show(_ id: ThreadId?) {
        flushEdits()
        threadId = id
        updateWorkspace()
        panel.setPanelState(id.flatMap { states[$0.rawValue] } ?? RightPanelState())
        syncSurfaces()
    }

    /// The shell changed: the thread's worktree or project may have moved.
    func shellChanged() {
        let before = workspace
        updateWorkspace()
        if before != workspace { syncSurfaces() }
    }

    private func updateWorkspace() {
        let old = workspace
        guard let id = threadId, let env = id.environmentId,
              let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }),
              let project = sidebar?.snapshot?.projects.first(where: { $0.id == thread.projectId }) else {
            workspace = nil
            panel.filesAvailable = false
            return
        }
        workspace = Workspace(environmentId: env, threadId: id, cwd: thread.worktreePath ?? project.workspaceRoot, projectName: project.title)
        panel.filesAvailable = true
        if old?.cwd != workspace?.cwd || old?.environmentId != workspace?.environmentId {
            panel.filesPanel.model = FileTreeModel()
            panel.filesPanel.searchField.input.text = ""
            reads = [:]
        }
    }

    private func panelChanged(_ state: RightPanelState, closed removed: [RightPanelSurface]) {
        guard let key = threadId?.rawValue else { return }
        for surface in removed {
            closed.remember(surface, threadKey: key)
            if let path = surface.filePath { flushEdits(path: path) }
        }
        store(state, for: key)
        syncSurfaces()
    }

    /// Loads what the active surface needs.
    private func syncSurfaces() {
        onSync?()
        guard let active = panel.panelState.active, panel.panelState.isOpen else { return }
        switch active.kind {
        case .files:
            panel.filesPanel.treeView.selectedPath = nil
            ensureTree()
        case .file:
            showActiveFile(force: false)
            ensureTree()
        case .diff, .pullRequest, .pullRequests:
            break
        }
    }

    private var activeFilePath: String? { panel.panelState.active?.filePath }

    // MARK: Opening

    /// `openFile` from the tree, breadcrumbs, the picker and chat links (`path:line`).
    func openFile(_ path: String, line: Int?) {
        guard threadId != nil, workspace != nil else { return }
        let relative = workspaceRelative(path)
        panel.mutatePanel { $0.openFile(relative, line: line); return [] }
    }

    /// A chat file chip (ChatMarkdown.tsx `fileLinkChip`): the panel path at its line.
    func openLink(_ meta: FileLinkMeta) {
        guard let path = meta.panelPath else { return }
        openFile(path, line: meta.line)
    }

    private func workspaceRelative(_ path: String) -> String {
        guard let cwd = workspace?.cwd, path.hasPrefix("/") else { return path }
        if path == cwd { return "." }
        return path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
    }

    // MARK: Tree

    private func ensureTree() {
        let files = panel.filesPanel
        if !files.model.ready, !files.model.loading.contains("") { loadDirectories([""]) }
        if let path = activeFilePath, !path.hasPrefix("/") {
            var model = files.model
            let need = model.reveal(path)
            files.model = model
            files.treeView.selectedPath = path
            if need.isEmpty { files.treeView.scrollToRow(path) } else { loadDirectories(need, reveal: path) }
        }
    }

    private func loadDirectories(_ dirs: [String], reveal: String? = nil) {
        guard let ws = workspace, let shell = environments.session(ws.environmentId) else { return }
        var model = panel.filesPanel.model
        model.loading.formUnion(dirs)
        panel.filesPanel.model = model
        Task { [weak self] in
            // `useDirectoryEntries` runs four listings at a time; folders here load in order.
            for dir in dirs {
                let entries = await Self.list(shell.supervisor, cwd: ws.cwd, directory: dir)
                guard let self, self.workspace == ws else { return }
                var model = self.panel.filesPanel.model
                model.loading.remove(dir)
                if let entries { model.setChildren(entries, of: dir) }
                self.panel.filesPanel.errorText = entries == nil && dir.isEmpty ? "Unable to load folder." : nil
                self.panel.filesPanel.model = model
            }
            if let reveal, let self { self.panel.filesPanel.treeView.scrollToRow(reveal) }
        }
    }

    private func listDirectory(_ dir: String) async -> [ProjectEntry]? {
        guard let ws = workspace, let shell = environments.session(ws.environmentId) else { return nil }
        return await Self.list(shell.supervisor, cwd: ws.cwd, directory: dir)
    }

    nonisolated static func list(_ supervisor: ConnectionSupervisor, cwd: String, directory: String) async -> [ProjectEntry]? {
        let reply = try? await supervisor.request("projects.listEntries", payload: .object(["cwd": .string(cwd), "directoryPath": .string(directory)]))
        return reply.map(entries)
    }

    nonisolated static func entries(_ reply: JSONValue) -> [ProjectEntry] {
        guard case .array(let list)? = reply["entries"] else { return [] }
        return list.compactMap { e in
            e["path"]?.stringValue.map { ProjectEntry(path: $0, isDirectory: e["kind"]?.stringValue == "directory", ignored: e["ignored"] == .bool(true)) }
        }
    }

    private func refreshTree() {
        let dirs = [""] + panel.filesPanel.model.directoryPaths.filter { panel.filesPanel.model.directories[$0] != nil }
        reads = [:]
        loadDirectories(dirs)
        let query = panel.filesPanel.searchField.input.text
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { searchTree(query) }
        if panel.panelState.active?.kind == .file { showActiveFile(force: true) }
    }

    /// The tree's path search (`useProjectPathSearch`, 120 ms debounce, 200 results).
    private func searchTree(_ query: String) {
        searchTask?.cancel()
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !trimmed.isEmpty, let ws = workspace, let shell = environments.session(ws.environmentId) else {
            panel.filesPanel.searchPending = false
            return
        }
        panel.filesPanel.searchPending = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let reply = try? await shell.supervisor.request("projects.searchEntries", payload: .object(
                ["cwd": .string(ws.cwd), "query": .string(trimmed), "limit": .number(200)]))
            guard !Task.isCancelled, let self else { return }
            self.panel.filesPanel.setSearchResults(reply.map(Self.entries) ?? [], query: query, truncated: reply?["truncated"] == .bool(true))
        }
    }

    /// The picker's server search: an empty query returns recent files (`useProjectFilePickerQuery`).
    func searchFiles(_ query: String) async -> [ProjectEntry]? {
        guard let ws = workspace, let shell = environments.session(ws.environmentId) else { return nil }
        let reply = try? await shell.supervisor.request("projects.searchEntries", payload: .object(
            ["cwd": .string(ws.cwd), "query": .string(String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))),
             "limit": .number(Double(FilePicker.resultLimit)), "kind": .string("file")]))
        return reply.map(Self.entries)
    }

    var pickerProjectName: String? { workspace?.projectName }

    // MARK: File tab

    private func key(_ path: String) -> String { (workspace?.cwd ?? "") + "\u{0}" + path }

    private func showActiveFile(force: Bool) {
        guard case .file(let path, let line, _)? = panel.panelState.active, let ws = workspace else { return }
        let surface = panel.fileSurface
        surface.projectName = ws.projectName
        surface.cwd = ws.cwd
        let samePath = surface.path == path
        surface.show(path: path, revealLine: line)
        panel.filesPanel.treeView.selectedPath = path.hasPrefix("/") ? nil : path
        if samePath, !force, case .loading = surface.content {} else if samePath, !force { return }
        fileTask?.cancel()
        let k = key(path)
        if let edited = buffers[k]?.edited, !surface.wantsAsset {
            surface.setContent(.text(edited, truncated: false, byteLength: edited.utf8.count, editable: true))
            return
        }
        if !force, let cached = reads[k] { surface.setContent(cached); return }
        guard let shell = environments.session(ws.environmentId) else { return }
        let wantsAsset = surface.wantsAsset
        fileTask = Task { [weak self] in
            let content: FileSurfaceView.Content
            if wantsAsset {
                content = await Self.asset(shell, threadId: ws.threadId, cwd: ws.cwd, path: path)
            } else {
                content = await Self.read(shell.supervisor, cwd: ws.cwd, path: path)
            }
            guard !Task.isCancelled, let self, self.activeFilePath == path, self.workspace == ws else { return }
            if case .text = content { self.reads[k] = content }
            if case .failure(_, _, _) = content, Self.isDirectoryFailure(content) {
                self.panel.fileSurface.setContent(.directory)
                return
            }
            self.panel.fileSurface.setContent(content)
        }
    }

    nonisolated static func isDirectoryFailure(_ content: FileSurfaceView.Content) -> Bool {
        if case .failure(let message, _, _) = content { return message == filePreviewReadErrorMessage(failure: "path_not_file", operation: nil, message: "") }
        return false
    }

    nonisolated static func read(_ supervisor: ConnectionSupervisor, cwd: String, path: String) async -> FileSurfaceView.Content {
        do {
            let reply = try await supervisor.request("projects.readFile", payload: .object(["cwd": .string(cwd), "relativePath": .string(path)]))
            let text = reply["contents"]?.stringValue ?? ""
            let truncated = reply["truncated"] == .bool(true)
            var bytes = text.utf8.count
            if case .number(let n)? = reply["byteLength"] { bytes = Int(n) }
            return .text(text, truncated: truncated, byteLength: bytes, editable: !truncated && !path.hasPrefix("/"))
        } catch let error as RPCClientError {
            let typed = error.typedError
            let message = filePreviewReadErrorMessage(failure: typed?.fields["failure"]?.stringValue,
                                                      operation: typed?.fields["operation"]?.stringValue, message: error.description)
            let attempted = typed?.fields["resolvedPath"]?.stringValue ?? typed?.fields["operationPath"]?.stringValue
            return .failure(message, attemptedPath: attempted, cwd: path.hasPrefix("/") ? nil : (typed?.fields["cwd"]?.stringValue ?? cwd))
        } catch {
            return .failure("\(error)", attemptedPath: nil, cwd: nil)
        }
    }

    /// `assets.createUrl` with a `workspace-file` resource (filePreviewMode.ts `workspaceAssetResource`).
    nonisolated static func asset(_ shell: ShellSession, threadId: ThreadId, cwd: String, path: String) async -> FileSurfaceView.Content {
        let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
        let inside = absolute.hasPrefix(cwd + "/")
        let kind = FilePreviewKind.of(path)
        let tag = inside && kind != .audio && kind != .video ? "workspace-file" : "media-file"
        let resource: JSONValue = .object(["_tag": .string(tag), "threadId": .string(threadId.localId.rawValue), "path": .string(absolute)])
        guard let reply = try? await shell.supervisor.request("assets.createUrl", payload: .object(["resource": resource])),
              let relative = reply["relativeUrl"]?.stringValue,
              let url = URL(string: relative, relativeTo: shell.http.baseURL)?.absoluteURL else {
            return .failure(kind == .image ? "Unable to load workspace image." : kind == .audio ? "Unable to load audio." : "Unable to load file preview.", attemptedPath: nil, cwd: nil)
        }
        return .asset(url)
    }

    // MARK: Saving

    /// An edit in the file tab: kept as the file's unsaved contents and autosaved after 500 ms
    /// (`useFileSaveCoordinator`). Writes need `filesystem:write`; the server refuses otherwise.
    private func edited(_ text: String) {
        guard let path = activeFilePath, let ws = workspace else { return }
        let k = key(path)
        let buffer = buffers[k] ?? Buffer()
        buffers[k] = buffer
        buffer.edited = text
        reads[k] = nil
        if buffer.coordinator == nil {
            buffer.coordinator = FileSaveCoordinator(
                persist: { [weak self] contents in
                    guard let shell = self?.environments.session(ws.environmentId) else { return false }
                    do {
                        _ = try await shell.supervisor.request("projects.writeFile", payload: .object(
                            ["cwd": .string(ws.cwd), "relativePath": .string(path), "contents": .string(contents)]))
                        return true
                    } catch {
                        self?.panel.toasts.show(ToastView(title: "Could not save \(path)", message: "\(error)", kind: .error))
                        return false
                    }
                },
                onPendingChange: { _ in },
                // `confirmProjectFileQueryData`: a newer unsaved edit keeps the file pending.
                onConfirmed: { [weak self, weak buffer] contents in
                    guard let buffer, buffer.edited == contents else { return false }
                    buffer.edited = nil
                    self?.reads[k] = .text(contents, truncated: false, byteLength: contents.utf8.count, editable: true)
                    return true
                })
        }
        buffer.coordinator?.change(text)
    }

    /// Writes pending edits now (a tab closes, the thread changes).
    private func flushEdits(path: String? = nil) {
        for (k, buffer) in buffers where path == nil || k == key(path!) {
            guard let coordinator = buffer.coordinator, coordinator.hasUnsaved else { continue }
            coordinator.dispose()
            buffer.coordinator = nil
            buffers[k] = buffers[k]?.edited == nil ? nil : buffers[k]
        }
    }

    // MARK: Shortcuts

    func registerShortcuts(_ shortcuts: Shortcuts) {
        // `rightPanel.close`: the active tab; with nothing open the key keeps its native meaning.
        shortcuts.on("rightPanel.close") { [weak self] call in
            guard let self, self.panel.window != nil, !self.panel.isDraft, self.panel.rightPanelOpen else { return false }
            if !call.isRepeat { self.panel.closeRightPanel() }
            return true
        }
        // `rightPanel.new`: the + menu.
        shortcuts.on("rightPanel.new") { [weak self] call in
            guard let self, self.panel.rightPanelOpen, !self.panel.isDraft else { return false }
            if !call.isRepeat { self.panel.showAddSurfaceMenu() }
            return true
        }
        // `view.reopenClosed` (ReopenClosedViewShortcut.tsx).
        shortcuts.on("view.reopenClosed") { [weak self] call in
            guard let self else { return false }
            if !call.isRepeat { self.reopenClosed() }
            return true
        }
        // The launcher's letters, outside typing contexts (`surfaceShortcutActionForKey`).
        shortcuts.onKey { [weak self] event in
            guard let self, self.panel.rightPanelOpen, self.panel.panelState.activeSurfaceId == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !Shortcuts.editableFocused(in: event.window), let chars = event.charactersIgnoringModifiers else { return false }
            return self.panel.launcherKey(chars)
        }
    }

    private func reopenClosed() {
        let snapshot = sidebar?.snapshot
        let current = threadId?.rawValue
        let entry = closed.popNext(threadExists: { key in snapshot?.threads.contains { $0.id.rawValue == key } ?? false },
                                   panel: { [states, panel] key in key == current ? panel.panelState : states[key] ?? RightPanelState() })
        save()
        guard let entry else { return }
        if entry.threadKey == current {
            panel.mutatePanel { ClosedPanelTabs.restore(entry.surface, into: &$0); return [] }
        } else {
            var state = states[entry.threadKey] ?? RightPanelState()
            ClosedPanelTabs.restore(entry.surface, into: &state)
            store(state, for: entry.threadKey)
            openThread?(ThreadId(entry.threadKey))
        }
    }

    /// A removed environment's threads lose their panel state and closed tabs.
    func environmentRemoved(_ environmentId: String) {
        let prefix = environmentId + ":"
        for key in states.keys where key.hasPrefix(prefix) { states[key] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
        closed.removeThreads { $0.hasPrefix(prefix) }
        save()
    }
}

/// `serializeComposerFileLink` for a tree row: `[name](path)` (composerMentionFromTreePath).
enum FileMentions {
    static func serialize(_ treePath: String) -> String? {
        var path = treePath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        return ComposerInlineTokens.fileLink(path)
    }
}
