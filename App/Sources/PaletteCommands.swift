import AppKit
import UniformTypeIdentifiers
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The command palette's entries and open state (apps/web/src/components/CommandPalette.tsx). The
/// `Features` controller renders and routes keys; this class knows what the app can do.
@MainActor
final class PaletteCommands {
    private(set) weak var window: NSWindow?
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let threads: ThreadController
    private let commands: SidebarCommands
    private let settings: SettingsController
    private var overlay: CommandPaletteOverlay?
    /// The add-project flows (environment, sources, browse, clone, New project).
    private lazy var addProjectFlow = PaletteAddProjectFlow(palette: self, environments: environments, threads: threads, commands: commands)
    /// Share with guest's availability and dialog.
    var guestShare: GuestShareController?
    /// The open palette's controller.
    var controller: CommandPaletteController? { overlay?.controller }
    /// Thread message search (`useThreadSearch`, state/queries.ts:75-101): a word of 3+ letters, 200 ms debounce.
    private var search: (query: String, matches: [ThreadSearchMatch])?
    private var searchTask: Task<Void, Never>?
    private var triageTask: Task<Void, Never>?
    private var pendingQuery: String?
    private var searchConnections: [String: Int] = [:]
    /// When the palette opened: titles and messages rank against it, so rows don't reorder as time passes.
    private var openedAt = 0.0
    /// Go to file's server results (`useProjectFilePickerQuery`): the query they answer.
    private var picker: (query: String, entries: [ProjectEntry]?)?
    private var pickerTask: Task<Void, Never>?
    /// A prompt link's "You don't have owner/name" toast.
    private var linkToast: Int?

    init(window: NSWindow, sidebar: SidebarContentView, environments: Environments, threads: ThreadController,
         commands: SidebarCommands, settings: SettingsController) {
        self.window = window
        self.sidebar = sidebar
        self.environments = environments
        self.threads = threads
        self.commands = commands
        self.settings = settings
        searchConnections = environments.connectedGenerations
        _ = environments.observe { [weak self] in
            guard let self else { return }
            let connected = self.environments.connectedGenerations
            let reconnected = connected.contains { self.searchConnections[$0.key] != $0.value }
            self.searchConnections = connected
            if reconnected, self.isOpen, let query = self.pendingQuery ?? self.search?.query { self.searchMessages(query) }
        }
    }

    var isOpen: Bool { overlay != nil }
    /// The hidden "Toggle performance HUD" entry's action.
    var togglePerformanceHUD: (@MainActor () -> Void)?

    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.paletteOpen = { [weak self] in self?.isOpen ?? false }
        // `commandPalette.toggle` (`ToggleMode "command"`): closes an open palette.
        shortcuts.on("commandPalette.toggle") { [weak self] _ in
            guard let self else { return false }
            if self.isOpen { self.close() } else { self.open() }
            return true
        }
        // `appearance.cycle`: System, Light, Dark, with a short toast (CommandPalette.tsx:532-549).
        shortcuts.on("appearance.cycle") { [weak self] call in
            if !call.isRepeat { self?.cycleAppearance() }
            return true
        }
        // `theme.select` (CommandPalette.tsx:550-556).
        shortcuts.on("theme.select") { [weak self] call in
            if !call.isRepeat { self?.openChangeTheme() }
            return true
        }
        // `chat.new`: with several projects the palette's project chooser, else a draft for the open
        // thread's project (_chat.tsx:121-140). `chat.newLocal` skips the chooser.
        // These live in `ChatRouteGlobalShortcuts` (_chat.tsx), so Settings and Usage, which sit outside
        // the `_chat` layout, ignore them; Pull Requests (`_chat.pull-requests`) keeps them.
        shortcuts.on(["chat.new", "chat.newLocal"]) { [weak self] call in
            guard let self, self.onChatRoute, self.sidebar?.snapshot?.projects.isEmpty == false else { return false }
            if call.command == "chat.new", self.projectGroups().count > 1 { self.open(newThreadIn: true) } else { self.newThreadFromContext() }
            return true
        }
        // `chat.newWithoutProject`: a draft in the scratch project of the machine in use (_chat.tsx:116-125).
        shortcuts.on("chat.newWithoutProject") { [weak self] _ in
            guard let self, self.onChatRoute, let env = self.scratchTargetEnvironmentId else { return false }
            self.startScratchThread(env)
            return true
        }
        // `filePicker.toggle` (`ToggleMode "files"`, CommandPalette.tsx:440-450, 574-580).
        shortcuts.on("filePicker.toggle") { [weak self] call in
            guard let self, !call.isRepeat else { return true }
            if self.overlay?.controller.mode?.name == "files" { self.close() } else { self.openFilePicker() }
            return true
        }
        // `projectSearch.toggle` (`ToggleMode "content"`).
        shortcuts.on("projectSearch.toggle") { [weak self] call in
            guard let self, !call.isRepeat else { return true }
            if self.overlay?.controller.mode?.name == "content" { self.close() } else { self.openContentSearch() }
            return true
        }
        // The palette input's own commands (CommandPalette.tsx:3090-3122).
        shortcuts.paletteCommand = { [weak self] call in
            guard let self, let controller = self.overlay?.controller else { return false }
            if call.command == "thread.copyReference" {
                if self.commands.threadReference != nil { self.close(); self.commands.copyThreadReference() }
                return true
            }
            return controller.handleJump(call.command)
        }
    }

    // MARK: Open and close

    func open(newThreadIn: Bool = false) {
        guard let window, overlay == nil else { return }
        let controller = CommandPaletteController(source: makeSource())
        let overlay = CommandPaletteOverlay(controller: controller)
        controller.onClose = { [weak self] in self?.close() }
        controller.onQueryChange = { [weak self, weak controller] query in
            switch controller?.mode?.name {
            case "files": self?.searchFiles(query)
            case "project-favicon": self?.searchFavicons(query)
            default: self?.searchMessages(query)
            }
        }
        overlay.onDismiss = { [weak self, weak overlay] in if self?.overlay === overlay { self?.overlay = nil } }
        // A path typed anywhere browses folders on the add-project machine (`isBrowsing`).
        controller.browse = { [weak self] query in self?.addProjectFlow.browseMode(query) }
        self.overlay = overlay
        if newThreadIn, let page = newThreadInPage() { controller.push(page) }
        overlay.present(in: window)
    }

    /// Go to file (ProjectFilePicker.tsx): the palette in "files" mode.
    func openFilePicker() {
        if overlay == nil { open() }
        guard let controller = overlay?.controller else { return }
        picker = nil
        controller.onLeaveMode = { [weak controller] in controller?.setMode(nil) }
        controller.setMode(filesMode())
        searchFiles("")
    }

    private func filesMode() -> CommandPaletteController.Mode {
        CommandPaletteController.Mode(name: "files", placeholder: "Search files\u{2026}", footerActionLabel: "Open file") { [weak self] query in
            guard let self, let files = self.threads.files, let project = files.pickerProjectName else {
                return ([], "Open a project to search its files.")
            }
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            guard let picker = self.picker, picker.query == query else {
                return ([], searching ? "Searching workspace files\u{2026}" : "Indexing workspace files\u{2026}")
            }
            guard let entries = picker.entries else { return ([], "Unable to search workspace files.") }
            let highlight = !FilePicker.normalize(picker.query).isEmpty
            let items = FilePicker.matches(entries, query: picker.query).map { match in
                var entry = PaletteEntry(value: "file:\(match.path)", searchTerms: [match.name, match.path], title: match.name,
                                         description: match.path, icon: .file,
                                         action: .run({ [weak self] in self?.threads.files.openFile(match.path, line: nil) }, keepOpen: false))
                entry.glyph = FileTypeIcon.icon(for: match.path)
                if highlight { entry.titleHighlights = match.nameMatches; entry.descriptionHighlights = match.pathMatches }
                return entry
            }
            return (items.isEmpty ? [] : [PaletteGroup(value: "project-files", label: project, items: items)],
                    searching ? "No matching files." : "No files found.")
        }
    }

    // MARK: Project icon file

    /// The open "Choose project icon" picker: its checkout, group name and what a pick does.
    private var favicon: (environmentId: String, cwd: String, projectName: String, onSelect: (String) -> Void)?
    private var faviconPicker: (query: String, entries: [ProjectEntry]?, error: String?)?
    private var pickingFaviconFile = false

    /// `ProjectFaviconPickerDialog` (settings/ProjectFaviconPickerDialog.tsx:30-142): the palette over the
    /// checkout's image files (`projects.searchEntries` with `kind: "file"`, `imageOnly: true`, 200 results,
    /// an empty query lists recent files). Enter selects; "Open in Finder" picks any image on this Mac when
    /// every checkout of the group is on the primary environment (ProjectSettingsPanel.tsx:196-204).
    func openProjectFaviconPicker(environmentId: String, cwd: String, projectName: String, external: Bool, onSelect: @escaping (String) -> Void) {
        if overlay == nil { open() }
        guard let controller = overlay?.controller else { return }
        favicon = (environmentId, cwd, projectName, onSelect)
        faviconPicker = nil
        controller.onLeaveMode = { [weak self] in self?.close() }
        var mode = CommandPaletteController.Mode(name: "project-favicon", placeholder: "Search image files\u{2026}",
                                                 footerActionLabel: "Select icon") { [weak self] query in
            guard let self, let favicon = self.favicon else { return ([], "") }
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            // `emptyMessage`: the error, then pending, then no results.
            guard let picker = self.faviconPicker, picker.query == query else {
                return ([], searching ? "Searching project files\u{2026}" : "Indexing project files\u{2026}")
            }
            if let error = picker.error { return ([], error) }
            let highlight = !FilePicker.normalize(picker.query).isEmpty
            let items = FilePicker.matches(picker.entries ?? [], query: picker.query).map { match in
                var entry = PaletteEntry(value: "project-favicon:\(match.path)", searchTerms: [match.name, match.path], title: match.name,
                                         description: match.path, icon: .file,
                                         action: .run({ favicon.onSelect(match.path) }, keepOpen: false))
                entry.glyph = FileTypeIcon.icon(for: match.path)
                if highlight { entry.titleHighlights = match.nameMatches; entry.descriptionHighlights = match.pathMatches }
                return entry
            }
            return (items.isEmpty ? [] : [PaletteGroup(value: "project-favicon-files", label: favicon.projectName, items: items)],
                    searching ? "No matching image files." : "No image files found.")
        }
        mode.escapeLabel = "Close"
        if external {
            let finder = ButtonView("Open in Finder", variant: .ghostMuted, size: .xs)
            finder.action = { [weak self, weak finder] in self?.pickFaviconFile(cwd: cwd, button: finder) }
            mode.footerTrailing = finder
        }
        controller.setMode(mode)
        controller.view.setAccessibilityLabel("Choose project icon")
        searchFavicons("")
    }

    /// 120 ms debounce like Go to file; the server filters to image files.
    private func searchFavicons(_ query: String) {
        pickerTask?.cancel()
        guard let favicon, let shell = environments.session(favicon.environmentId) else { return }
        pickerTask = Task { [weak self] in
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let payload: JSONValue = .object(["cwd": .string(favicon.cwd),
                                              "query": .string(String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))),
                                              "limit": .number(Double(FilePicker.resultLimit)), "kind": .string("file"), "imageOnly": .bool(true)])
            var result: (String, [ProjectEntry]?, String?)
            do {
                let reply = try await shell.supervisor.request("projects.searchEntries", payload: payload)
                result = (query, FilesController.entries(reply), nil)
            } catch {
                result = (query, nil, (error as? RPCClientError)?.typedError?.fields["message"]?.stringValue ?? "Unable to search project files.")
            }
            guard !Task.isCancelled, let self else { return }
            self.pickerTask = nil
            self.faviconPicker = result
            if self.overlay?.controller.mode?.name == "project-favicon", self.overlay?.controller.query == query { self.overlay?.controller.refresh() }
        }
    }

    /// `onPickExternal`: the system file picker at the checkout, filtered to T3's image types.
    private func pickFaviconFile(cwd: String, button: ButtonView?) {
        guard !pickingFaviconFile, let window, let favicon else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FilePreviewKind.imageExtensions.compactMap { UTType(filenameExtension: String($0.dropFirst())) }
        panel.directoryURL = URL(fileURLWithPath: cwd)
        pickingFaviconFile = true
        button?.isEnabled = false
        panel.beginSheetModal(for: window) { [weak self, weak button] response in
            MainActor.assumeIsolated {
                self?.pickingFaviconFile = false
                button?.isEnabled = true
                guard response == .OK, let url = panel.url else { return }
                self?.close()
                favicon.onSelect(url.path)
            }
        }
    }

    // MARK: Search project contents

    private var contentTask: Task<Void, Never>?

    /// `ProjectContentSearchDialog`: the palette in "content" mode with its own body.
    func openContentSearch() {
        if overlay == nil { open() }
        guard let controller = overlay?.controller else { return }
        controller.onLeaveMode = { [weak self, weak controller] in
            self?.contentTask?.cancel()
            controller?.view.input.isEnabled = true
            controller?.view.setAccessibilityLabel("Command palette")
            controller?.setMode(nil)
        }
        let body = ContentSearchView()
        guard let target = threads.files.workspaceTarget else {
            // `EmptyContentSearchDialog`: the input is disabled.
            body.apply(matches: [], status: .idle, empty: "Open a project to search its files.")
            body.accessory.isHidden = true
            controller.setMode(.init(name: "content", placeholder: "Search project contents\u{2026}", footerActionLabel: "Open file",
                                     custom: .init(view: body, onQuery: { _ in }, onCommand: { _ in true })))
            controller.view.input.isEnabled = false
            return
        }
        var query = ""
        let run = { [weak self, weak body] in
            guard let self, let body else { return }
            self.contentTask?.cancel()
            let q = query
            // Whitespace is significant in content queries; it only decides whether the input is blank.
            guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                body.canOpen = true
                body.apply(matches: [], status: .idle, empty: "Type to search across your project.")
                return
            }
            body.canOpen = false
            body.apply(matches: body.matches, status: .pending, empty: body.matches.isEmpty ? "Type to search across your project." : body.emptyMessage)
            let options = body.options
            self.contentTask = Task { [weak self, weak body] in
                try? await Task.sleep(for: ProjectContentSearchResult.debounce)
                guard !Task.isCancelled, let self else { return }
                do {
                    guard let result = try await self.threads.files.searchContents(q, options: options), !Task.isCancelled, let body else { return }
                    let files = Set(result.matches.map(\.path)).count
                    body.canOpen = true
                    body.apply(matches: result.matches,
                               status: options.useRegex && result.regexFallbackError != nil ? .invalidRegex
                                   : .results(count: result.matches.count, truncated: result.truncated, files: files),
                               empty: "No results found.")
                } catch {
                    guard !Task.isCancelled, let body else { return }
                    let message = (error as? RPCClientError)?.typedError?.fields["message"]?.stringValue ?? "\(error)"
                    body.canOpen = false
                    body.apply(matches: [], status: .error(message), empty: message)
                }
            }
        }
        body.onOptionsChange = { _ in run() }
        body.onOpen = { [weak self] match in
            self?.close()
            self?.threads.files.openFile(match.path, line: match.lineNumber)
        }
        controller.setMode(.init(name: "content", placeholder: "Search in \(target.projectName)", footerActionLabel: "Open file",
                                 custom: .init(view: body, accessory: body.accessory,
                                               onQuery: { text in query = text; run() },
                                               onCommand: { [weak body] selector in body?.handleCommand(selector) ?? false })))
        controller.view.setAccessibilityLabel("Search file contents in \(target.projectName)")
    }

    /// 120 ms debounce, 200 files, an empty query lists recent files.
    private func searchFiles(_ query: String) {
        pickerTask?.cancel()
        pickerTask = Task { [weak self] in
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let self else { return }
            let entries = await self.threads.files.searchFiles(query)
            guard !Task.isCancelled else { return }
            self.pickerTask = nil
            self.picker = (query, entries)
            if self.overlay?.controller.mode?.name == "files", self.overlay?.controller.query == query { self.overlay?.controller.refresh() }
        }
    }

    func close() {
        addProjectFlow.reset()
        favicon = nil
        faviconPicker = nil
        pickerTask?.cancel()
        contentTask?.cancel()
        searchTask?.cancel()
        search = nil
        pendingQuery = nil
        let closing = overlay
        overlay = nil
        closing?.close()
    }

    // MARK: Entries

    private func makeSource() -> CommandPaletteController.Source {
        openedAt = Double(nowMs)
        return CommandPaletteController.Source(
            rootGroups: { [weak self] in self?.rootGroups() ?? [] },
            projectItems: { [weak self] in self?.projectSearchItems() ?? [] },
            threadItems: { [weak self] query in self?.threadItems(query: query) ?? [] },
            threadSearchPending: { [weak self] query in self?.pendingQuery == query.trimmingCharacters(in: .whitespaces) },
            settingsItems: { [weak self] query in self?.settingsItems(query) ?? [] },
            threadMessageItems: { [weak self] query in self?.threadMessageItems(query) ?? [] },
            now: openedAt)
    }

    var snapshot: ShellSnapshot? { sidebar?.snapshot }
    private var nowMs: Int64 { TimestampFormat.nowMs() }
    private var envs: SidebarEnvironments { sidebar?.state.environments ?? SidebarEnvironments() }

    private func locationLabel(_ environmentId: String?) -> String {
        guard let environmentId else { return "Remote" }
        if environmentId == envs.primaryId { return "Local" }
        return environments.label(environmentId) ?? "Remote"
    }

    /// Project groups with the open thread's group first (`pickerProjects`).
    private func projectGroups() -> [SidebarModel.ProjectGroup] {
        guard let snapshot else { return [] }
        // `projectGroups` in the `sidebarProjectSortOrder` order (CommandPalette.tsx:955-963), then the
        // contextual project first (`buildSidebarProjectPickerEntries`, sidebarProjectGrouping.ts:168-175).
        let order = SidebarProjectOrder.sortOrder
        let built = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: envs.primaryId)
        // Manual reads the stored order (CommandPaletteLookups.ts:73-83).
        var groups = order == .manual ? SidebarModel.orderProjectGroups(built, projects: snapshot.projects, preferred: SidebarProjectOrder.stored)
            : SidebarModel.sortLogicalProjectsForSidebar(built, threads: snapshot.threads, order: order)
        if let current = threads.composer.activeProjectId, let i = groups.firstIndex(where: { $0.memberProjectIds.contains(current) }), i > 0 {
            groups.insert(groups.remove(at: i), at: 0)
        }
        return groups
    }

    /// `ProjectSearchDescription`: "<location> · <root>" for one project, the machine labels for a group.
    private func projectDescription(_ group: SidebarModel.ProjectGroup) -> String {
        if group.members.count > 1 {
            var labels: [String] = []
            for m in group.members where !labels.contains(locationLabel(m.id.environmentId)) { labels.append(locationLabel(m.id.environmentId)) }
            return labels.joined(separator: " \u{00B7} ")
        }
        return "\(locationLabel(group.representative.id.environmentId)) \u{00B7} \(group.representative.workspaceRoot)"
    }

    private func projectSearchTerms(_ group: SidebarModel.ProjectGroup) -> [String] {
        [group.label, group.representative.title, group.representative.workspaceRoot]
            + group.members.flatMap { [$0.title, $0.workspaceRoot, locationLabel($0.id.environmentId)] }
    }

    /// `buildRootGroups`: Actions, then Recent Threads.
    private func rootGroups() -> [PaletteGroup] {
        var actions: [PaletteEntry] = []
        let groups = projectGroups()
        if !groups.isEmpty {
            let current = threads.composer.activeProjectId
            if let current, let group = groups.first(where: { $0.memberProjectIds.contains(current) }) {
                actions.append(PaletteEntry(value: "action:new-thread", searchTerms: ["new thread", "chat", "create", "draft"],
                                            title: "New thread in ", titleEmphasis: group.label, icon: .squarePen, shortcutCommand: "chat.new",
                                            action: .run({ [weak self] in self?.newThreadFromContext() }, keepOpen: false)))
            }
            if let page = newThreadInPage() {
                actions.append(PaletteEntry(value: "action:new-thread-in", searchTerms: ["new thread", "project", "pick", "choose", "select"],
                                            title: "New thread in...", icon: .squarePen, action: .submenu(page)))
            }
        }
        if let env = scratchTargetEnvironmentId {
            actions.append(PaletteEntry(value: "action:new-thread-without-project",
                                        searchTerms: ["new thread", "no project", "without project", "none", "chat"],
                                        title: "New thread without a project", icon: .messageSquareDashed,
                                        shortcutCommand: "chat.newWithoutProject",
                                        action: .run({ [weak self] in self?.startScratchThread(env) }, keepOpen: false)))
        }
        if let env = triageEnvironment, supportsTriage(env) {
            actions.append(PaletteEntry(value: "action:triage", searchTerms: ["triage", "bug", "issue", "report", "broken", "debug", "help", "support"],
                                        title: "Triage an issue", description: "An agent investigates a T3 Code problem and helps file an issue", icon: .bug,
                                        action: .run({ [weak self] in self?.startTriage(env) }, keepOpen: false)))
        }
        if let id = threads.openThreadId, let env = id.environmentId,
           threads.composer.config(env)?.capabilities.contains("threadFind") == true {
            actions.append(PaletteEntry(value: "find-current-thread", searchTerms: ["find", "search", "messages", "plans"],
                                        title: "Find in current thread", icon: .textSearch, shortcutCommand: "chat.find",
                                        action: .run({ [weak self] in
                                            self?.showThreadView()
                                            self?.threads.composer.openThreadFind()
                                        }, keepOpen: false)))
        }
        if let target = commands.threadReferenceTarget {
            actions.append(PaletteEntry(value: "action:copy-thread-reference", searchTerms: ["copy", "pull request", "pr link", "thread id", "reference"],
                                        title: "Copy " + target.title.replacingOccurrences(of: " copied", with: "").replacingOccurrences(of: "Thread ID", with: "thread ID"), description: target.value,
                                        icon: .link, shortcutCommand: "thread.copyReference",
                                        action: .run({ [weak self] in self?.commands.copyThreadReference() }, keepOpen: false)))
        }
        // "Link pull request to thread" and "Show linked pull requests" (CommandPalette.tsx:1963-1990).
        if let id = threads.openThreadId, let env = id.environmentId {
            let prs = threads.pullRequests!
            let multiple = prs.capabilities.has(env, "threadPullRequests")
            if multiple || prs.capabilities.has(env, "threadPullRequestLinking") {
                actions.append(PaletteEntry(value: "action:link-pull-request", searchTerms: ["link", "pull request", "pr", "attach", "stack"],
                                            title: "Link pull request to thread", icon: .link2,
                                            action: .run({ [weak prs] in DispatchQueue.main.async { prs?.openLinkDialog() } }, keepOpen: false)))
                if multiple {
                    let links = sidebar?.snapshot?.threads.first { $0.id == id }?.pullRequests ?? []
                    var show = PaletteEntry(value: "action:open-thread-pull-requests", searchTerms: ["pull requests", "linked", "stack", "prs"],
                                            title: "Show linked pull requests", icon: .link2,
                                            action: .run({ [weak self] in self?.threads.panel.mutatePanel { $0.open(.pullRequests); return [] } }, keepOpen: false))
                    show.isDisabled = ThreadPullRequests.visible(links).isEmpty
                    actions.append(show)
                }
            }
        }
        // "Share with guest" (CommandPalette.tsx:1373-1385 at 3669), where the thread's environment offers it.
        if let id = threads.openThreadId, let guestShare, guestShare.canShare(id.environmentId) {
            actions.append(PaletteEntry(value: "action:share-thread-with-guest", searchTerms: ["share", "guest", "invite", "link", "teammate"],
                                        title: "Share with guest", icon: .userPlus,
                                        action: .run({ [weak self, weak guestShare] in
                                            DispatchQueue.main.async { if let window = self?.window { guestShare?.present(id, in: window) } }
                                        }, keepOpen: false)))
        }
        // "Restart agent session" (CommandPalette.tsx:1993-2036).
        if let id = threads.openThreadId, let thread = sidebar?.snapshot?.threads.first(where: { $0.id == id }) {
            actions.append(PaletteEntry(value: "action:restart-agent-session",
                                        searchTerms: ["restart", "reset", "reload", "agent", "session", "skills", "plugins", "mcp"],
                                        title: "Restart agent session", icon: .rotateCcw,
                                        action: .run({ [weak self] in self?.restartAgentSession(thread) }, keepOpen: false)))
        }
        actions.append(PaletteEntry(value: "action:open-file-picker", searchTerms: ["go to file", "open file", "file picker", "find file", "quick open"],
                                    title: "Go to file", icon: .fileSearch, shortcutCommand: "filePicker.toggle",
                                    action: .run({ [weak self] in self?.openFilePicker() }, keepOpen: true)))
        actions.append(PaletteEntry(value: "action:search-project-contents",
                                    searchTerms: ["search project", "find in files", "grep", "content search", "text search"],
                                    title: "Search project contents", icon: .textSearch, shortcutCommand: "projectSearch.toggle",
                                    action: .run({ [weak self] in self?.openContentSearch() }, keepOpen: true)))
        if !addProjectFlow.newProjectOptions.isEmpty {
            actions.append(PaletteEntry(value: "action:new-project", searchTerms: ["new project", "create project", "empty", "repository", "repo", "git init"],
                                        title: "New project", icon: .folderGit2,
                                        action: .run({ [weak self] in self?.addProjectFlow.startNewProjectFromRoot() }, keepOpen: true)))
        }
        actions.append(PaletteEntry(value: "action:add-project", searchTerms: ["add project", "folder", "directory", "browse", "clone", "remote",
                                                                                "repository", "repo", "git", "github", "gitlab", "forgejo", "bitbucket",
                                                                                "azure", "devops", "url", "environment"],
                                    title: "Add project", icon: .folderPlus,
                                    action: .run({ [weak self] in self?.addProjectFlow.open() }, keepOpen: true)))
        actions.append(PaletteEntry(value: "action:change-theme", searchTerms: ["change theme", "appearance", "colors", "palette"],
                                    title: "Change theme", icon: .palette, shortcutCommand: "theme.select",
                                    action: .submenu(themePage())))
        actions.append(PaletteEntry(value: "action:change-appearance", searchTerms: ["change appearance", "light", "dark", "system", "mode", "toggle"],
                                    title: "Change appearance", icon: .monitor, shortcutCommand: "appearance.cycle",
                                    action: .submenu(appearancePage())))
        actions.append(PaletteEntry(value: "action:theme-editor", searchTerms: ["theme", "appearance", "colors", "palette", "customize"],
                                    title: "Toggle theme editor", icon: .palette, shortcutCommand: "themeEditor.toggle",
                                    action: .run({ ThemeEditorController.shared.toggle(initialAppearance: ThemeLibrary.shared.resolvedAppearance) },
                                                 keepOpen: false)))
        if sidebar?.showsPullRequests == true {
            actions.append(PaletteEntry(value: "action:pull-requests", searchTerms: ["pull requests", "prs", "pr", "github", "review", "merge", "branch"],
                                        title: "Open pull requests", icon: .gitPullRequestArrow,
                                        action: .run({ [weak self] in self?.openUtility(.pullRequests) }, keepOpen: false)))
        }
        actions.append(PaletteEntry(value: "action:usage", searchTerms: ["usage", "use", "tokens", "cost", "spend", "limits", "stats", "analytics"],
                                    title: "Open usage", icon: .chartNoAxesColumn, shortcutCommand: "usage.open",
                                    action: .run({ [weak self] in self?.openUtility(.usage) }, keepOpen: false)))
        actions.append(PaletteEntry(value: "action:settings", searchTerms: ["settings", "preferences", "configuration", "keybindings"],
                                    title: "Open settings", icon: .settings,
                                    action: .run({ [weak self] in self?.commands.closeUtilityPage(); self?.settings.open() }, keepOpen: false)))
        // "Project settings" for the open thread's or draft's group, else the first (CommandPalette.tsx:2264-2300).
        if let group = contextualProjectGroup() {
            actions.append(PaletteEntry(value: "action:project-settings",
                                        searchTerms: ["project", "settings", "name", "icon", "scripts", "model", "workspace", "grouping",
                                                      "checkout", "remove", "t3.json"],
                                        title: "Project settings", description: group.label, icon: .folder,
                                        action: .run({ [weak self] in self?.openProjectSettings(group.key) }, keepOpen: false)))
        }
        var result = [PaletteGroup(value: "actions", label: "Actions", items: actions)]
        // Building all 1,500 entries to keep 12 cost 9 ms a keystroke (docs/research/m10-load-2026-10-12.md).
        let recent = threadItems(query: nil, recentLimit: PaletteSearch.recentThreadLimit)
        if !recent.isEmpty { result.append(PaletteGroup(value: "recent-threads", label: "Recent Threads", items: recent)) }
        return result
    }

    /// "New thread in..." (`projectThreadItems`): one entry per project group, `thread.jump.N` on the first nine.
    private func newThreadInPage() -> PalettePage? {
        let all = projectGroups()
        guard !all.isEmpty else { return nil }
        // The no-project home shows once, as the "No project" item.
        let groups = all.filter { !isScratch($0.representative) }
        let current = threads.composer.activeProjectId
        var items = groups.map { group in
            var entry = PaletteEntry(value: "new-thread-in:\(group.key)", searchTerms: [group.label, group.representative.title, group.representative.workspaceRoot]
                            + group.members.flatMap { [$0.title, $0.workspaceRoot] } + [locationLabel(group.representative.id.environmentId)],
                         title: group.label, description: projectDescription(group), icon: .folder,
                         action: .run({ [weak self] in
                             // The open thread's own member when it is in this group, else the group's project.
                             let member = current.flatMap { id in group.members.first { $0.id == id } } ?? group.representative
                             self?.newThread(in: member)
                         }, keepOpen: false))
            entry.projectIcon = ProjectIconSource(group.representative)
            return entry
        }
        items = PaletteSearch.enumerate(items)
        if let env = scratchTargetEnvironmentId {
            // "No project" right after the current project, first when the current thread has none; it keeps
            // its own shortcut so the projects' mod+1..9 hold (CommandPalette.tsx:1388-1408).
            let index = all.first.map(\.representative).map(isScratch) == true ? 0 : min(1, items.count)
            items.insert(PaletteEntry(value: "new-thread-in:no-project", searchTerms: ["no project", "without project", "none"],
                                      title: "No project", icon: .messageSquareDashed, shortcutCommand: "chat.newWithoutProject",
                                      action: .run({ [weak self] in self?.startScratchThread(env) }, keepOpen: false)), at: index)
        }
        return PalettePage(addonIcon: .squarePen, groups: [PaletteGroup(value: "projects", label: "Projects", items: items)])
    }

    // MARK: Threads without a project (useScratchProject.ts)

    /// The environment's scratch folder while it is connected (`availableScratchWorkspaceRoot`).
    private func scratchRoot(_ env: String) -> String? {
        guard environments.state(env)?.status == .connected else { return nil }
        return threads.composer.config(env)?.scratchWorkspaceRoot
    }

    /// `scratchEnvironmentId` (useScratchProject.ts:51-60 at 3814): the primary machine wins when it offers a scratch
    /// folder, then `fallback` when it does, else the one machine that does.
    func scratchEnvironmentId(_ fallback: String?) -> String? {
        if let primary = environments.primaryId, scratchRoot(primary) != nil { return primary }
        if let fallback, scratchRoot(fallback) != nil { return fallback }
        let offering = environments.environmentIds.filter { scratchRoot($0) != nil }
        return offering.count == 1 ? offering[0] : nil
    }

    /// The open thread's or draft's machine, else the primary (`scratchTargetEnvironmentId`).
    var scratchTargetEnvironmentId: String? {
        scratchEnvironmentId(threads.composer.targetEnvironmentId ?? environments.primaryId)
    }

    private func isScratch(_ project: ProjectShell) -> Bool { threads.composer.isScratch(project) }

    /// `startScratchThread`: `projects.ensureScratch`, wait for the project in the shell (10 s), then a draft in it.
    func startScratchThread(_ env: String, then opened: (@MainActor () -> Void)? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.environments.request(env, "projects.ensureScratch", .object([:]))
                guard let localId = reply["projectId"]?.stringValue else { throw SidebarCommands.CommandMessage(errorDescription: "An error occurred.") }
                let id = ProjectId(EnvironmentScope.key(env, localId))
                var project: ProjectShell?
                for _ in 0..<100 {
                    project = self.sidebar?.snapshot?.projects.first { $0.id == id }
                    if project != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let project else { throw SidebarCommands.CommandMessage(errorDescription: "The scratch project did not load.") }
                self.newThread(in: project)
                opened?()
            } catch {
                let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription
                self.threads.panel.toasts.show(ToastView(title: "Could not start without a project", message: message ?? "An error occurred.", kind: .error))
            }
        }
    }

    private func supportsTriage(_ env: String) -> Bool {
        threads.composer.config(env)?.capabilities.contains("triage") == true
            && environments.authSession(env)?.grants(AuthScopes.orchestrationOperate) == true
    }

    private var triageEnvironment: String? {
        TriageLogic.environment(onScreen: threads.composer.targetEnvironmentId, primary: environments.primaryId,
                               connected: environments.environmentIds.filter { environments.state($0)?.status == .connected },
                               supports: supportsTriage)
    }

    /// T3 3814 hooks/useStartTriage.ts:38-106. Never send the RPC to an older runtime.
    private func startTriage(_ env: String) {
        guard triageTask == nil, supportsTriage(env) else { return }
        let route = (threads.composer.navigationGeneration, settings.navigationGeneration, commands.navigationGeneration)
        var pendingToast: Int?
        let pending = DispatchWorkItem { [weak self] in
            pendingToast = self?.threads.panel.toasts.show(ToastView(title: "Starting triage…", kind: .loading), timeout: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: pending)
        triageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                pending.cancel()
                if let pendingToast { threads.panel.toasts.dismiss(pendingToast) }
                triageTask = nil
            }
            do {
                guard threads.composer.config(env)?.scratchWorkspaceRoot != nil else {
                    throw SidebarCommands.CommandMessage(errorDescription: "This machine cannot start threads without a project.")
                }
                try await TriageLogic.prepare(supported: supportsTriage(env), prepare: {
                    let client: JSONValue = .object(["label": .string("CandyWrapper"), "deviceType": .string("desktop"),
                        "os": .string("macOS"), "appVersion": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")])
                    let reply = try await environments.request(env, "server.prepareTriage", .object(["client": client]))
                    guard let prompt = reply["prompt"]?.stringValue else { throw SidebarCommands.CommandMessage(errorDescription: "The server returned no triage prompt.") }
                    return prompt
                }, scratch: {
                    let reply = try await environments.request(env, "projects.ensureScratch", .object([:]))
                    guard let local = reply["projectId"]?.stringValue else { throw SidebarCommands.CommandMessage(errorDescription: "The server returned no scratch project.") }
                    let id = ProjectId(EnvironmentScope.key(env, local))
                    for _ in 0..<100 {
                        if sidebar?.snapshot?.projects.contains(where: { $0.id == id }) == true { return id }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw SidebarCommands.CommandMessage(errorDescription: "The scratch project did not load.")
                }, stillHere: {
                    route == (threads.composer.navigationGeneration, settings.navigationGeneration, commands.navigationGeneration)
                }, show: { id, prompt in
                    guard let project = sidebar?.snapshot?.projects.first(where: { $0.id == id }) else { return }
                    newThread(in: project)
                    threads.composer.seedTriagePrompt(prompt)
                })
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription ?? "An error occurred."
                threads.panel.toasts.show(ToastView(title: "Could not start triage",
                    message: message + " Run npx t3 triage in a terminal on that machine instead.", kind: .error,
                    actionTitle: "Copy command", action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TriageLogic.cliCommand, forType: .string)
                    }), timeout: 0)
            }
        }
    }

    /// `projectSearchItems`: opens the group's latest thread, else a draft (`openProjectFromSearch`).
    private func projectSearchItems() -> [PaletteEntry] {
        projectGroups().map { group in
            var entry = PaletteEntry(value: "project:\(group.key)", searchTerms: projectSearchTerms(group), title: group.label,
                                     description: projectDescription(group), icon: .folder,
                                     action: .run({ [weak self] in self?.openProject(group) }, keepOpen: false))
            entry.projectIcon = ProjectIconSource(group.representative)
            return entry
        }
    }

    /// `buildThreadActionItems` (CommandPalette.logic.ts:384-457) over every unarchived thread but subagents, which
    /// `filter` ranks. `recentLimit` keeps the most recently used instead, without the open thread
    /// (CommandPalette.tsx:909-920).
    // ponytail: text description and pull request badge; T3 draws the project favicon, provider icon and status pill
    private func threadItems(query: String?, recentLimit: Int? = nil) -> [PaletteEntry] {
        guard let snapshot else { return [] }
        let open = threads.openThreadId
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ms = nowMs
        let several = environments.environmentIds.count > 1
        var all = snapshot.threads.filter { $0.archivedAt == nil && !SidebarModel.isSidebarSubagentThread($0) }
        var subjects = all.map { thread in
            PaletteScoring.threadSearchSubject(thread, projectTitle: projects[thread.projectId]?.title,
                                               environmentLabel: several ? locationLabel(thread.id.environmentId) : nil)
        }
        if let recentLimit {
            let order = all.indices.filter { all[$0].id != open }
                .sorted { PaletteScoring.threadRecentUse(subjects[$0]) > PaletteScoring.threadRecentUse(subjects[$1]) }
                .prefix(recentLimit)
            all = order.map { all[$0] }
            subjects = order.map { subjects[$0] }
        }
        return zip(all, subjects).map { thread, subject in
            var parts = [subject.projectTitle, locationLabel(thread.id.environmentId)].compactMap { $0 }
            if thread.id == open { parts.append("Current thread") }
            let stamp = (thread.latestUserMessageAt ?? thread.updatedAt).raw
            let id = thread.id
            var entry = PaletteEntry(value: "thread:\(thread.id.rawValue)", searchTerms: [thread.title], title: thread.title,
                                     description: parts.joined(separator: " \u{00B7} "),
                                     timestamp: TimestampFormat.formatRelativeTimeLabel(stamp, nowMs: ms), icon: .messageSquare,
                                     action: .run({ [weak self] in self?.pickThread(id, query: query) }, keepOpen: false))
            entry.threadSearch = subject
            // Last in its group: picking the thread already open does nothing.
            entry.secondary = thread.id == open
            if let query {
                entry.pullRequestBadge = SidebarPullRequestBadge.search(thread, query: query)
                entry.pullRequestBadgeSettled = thread.settledOverride == .settled
            }
            return entry
        }
    }

    /// `threadMessageItems` (CommandPaletteThreadItems.tsx:199-240): threads whose messages match, by
    /// `rankMessageMatches`, skipping threads whose titles match. The snippet replaces the project line, and the
    /// timestamp is the matching message's.
    // ponytail: rows don't hold their places as `nextShownOrder` does, since every environment answers before any show; port it if results stream per machine
    private func threadMessageItems(_ query: String) -> [PaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let search, search.query == trimmed else { return [] }
        let items = Dictionary(threadItems(query: query).map { ($0.value, $0) }, uniquingKeysWith: { a, _ in a })
        let item = { (m: ThreadSearchMatch) in items["thread:\(m.threadId.rawValue)"] }
        let ranked = PaletteScoring.rankMessageMatches(search.matches, quality: \.quality, hits: \.hits, messageCreatedAt: { $0.messageCreatedAt?.raw },
                                                       subjectOf: { item($0)?.threadSearch },
                                                       normalizedQuery: PaletteScoring.foldSearchQuery(trimmed), now: openedAt,
                                                       withoutTitleMatches: true)
        var seen = Set<String>()
        let ms = nowMs
        return ranked.compactMap { m -> PaletteEntry? in
            guard var entry = item(m), seen.insert(entry.value).inserted else { return nil }
            entry.description = nil
            if let created = m.messageCreatedAt { entry.timestamp = TimestampFormat.formatRelativeTimeLabel(created.raw, nowMs: ms) }
            entry.match = (m.isUser ? "You: " : "Agent: ") + m.snippet
            entry.matchIsUser = m.isUser
            entry.matchQuery = trimmed
            // `ThreadRowContext`: the project and machine beside the title, since the snippet takes their line.
            entry.note = [entry.threadSearch?.projectTitle, entry.threadSearch?.environmentLabel].compactMap { $0 }.joined(separator: " \u{00B7} ")
            // Opens the thread with find on the word at the matched message, so it is in view.
            let id = m.threadId, find = PaletteScoring.findQuery(snippet: m.snippet, query: trimmed), start = m.messageId
            entry.action = .run({ [weak self] in
                self?.pickThread(id, query: query)
                self?.threads.composer.openThreadFind(id, query: find, startEntryId: start)
            }, keepOpen: false)
            return entry
        }.prefix(PaletteScoring.paletteMessageLimit).map { $0 }
    }

    /// `settingsSearchItems` (CommandPalette.tsx:2310-2331): "Settings · <section>", opening the page at the row.
    private func settingsItems(_ query: String) -> [PaletteEntry] {
        hiddenItems(query) + SettingsSearch.search(query, in: SettingsSearch.available(settings.searchAvailability())).map { item in
            var entry = PaletteEntry(value: "setting:\(item.id)", searchTerms: [item.title, item.to.label] + item.searchTerms,
                                     title: item.title, description: "Settings \u{00B7} \(item.to.label)", icon: .settings,
                                     action: .run({ [weak self] in
                                         self?.commands.closeUtilityPage()
                                         self?.settings.open()
                                         self?.settings.jump(to: item)
                                     }, keepOpen: false))
            entry.secondary = item.flags.contains(.secondary)
            return entry
        }
    }

    /// Entries T3 doesn't have, so they stay out of the default list and show only for a query
    /// containing "hud".
    private func hiddenItems(_ query: String) -> [PaletteEntry] {
        guard let toggle = togglePerformanceHUD, query.lowercased().contains("hud") else { return [] }
        return [PaletteEntry(value: "action:performance-hud", searchTerms: ["performance hud", "hud"], title: "Toggle performance HUD",
                             icon: .chartNoAxesColumn, action: .run({ toggle() }, keepOpen: false))]
    }

    /// The open thread's or draft's project group, else the first group (`contextualProjectGroup`).
    private func contextualProjectGroup() -> SidebarModel.ProjectGroup? {
        let groups = snapshot.map { SidebarModel.buildProjectGroups($0.projects, preferredEnvironmentId: envs.primaryId) } ?? []
        if let current = threads.composer.activeProjectId, let group = groups.first(where: { $0.memberProjectIds.contains(current) }) { return group }
        return groups.first
    }

    /// `/projects/$projectKey`: the Project settings page scoped to the group.
    func openProjectSettings(_ key: String) {
        commands.closeUtilityPage()
        settings.openProject(key)
    }

    /// Stops the thread's provider sessions so the next message starts a fresh one, then refreshes the
    /// provider for the thread's cwd (CommandPalette.tsx:1999-2033). Failures toast "Unable to run command".
    private func restartAgentSession(_ thread: ThreadShell) {
        let project = snapshot?.projects.first { $0.id == thread.projectId }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.threads.composer.restartAgentSession(thread, cwd: thread.worktreePath ?? project?.workspaceRoot)
            } catch {
                let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription
                self.threads.panel.toasts.show(ToastView(title: "Unable to run command", message: message ?? "An unexpected error occurred.", kind: .error))
            }
        }
    }

    // MARK: Message search

    private func searchMessages(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Two characters at least (threadSearch.ts:17). Without a word of three letters only machines that leave
        // older settled threads out of the shell are asked, for titles (`searchThreads`).
        guard !query.hasPrefix(">"), trimmed.utf16.count >= SidebarModel.threadSearchMinLength else { pendingQuery = nil; return }
        pendingQuery = trimmed
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let found = await self.environments.searchThreads(trimmed)
            guard !Task.isCancelled, self.pendingQuery == trimmed else { return }
            // Failed reads retain the last answer; a reconnect retries it (runtime.ts:724-752, 3814).
            if let found { self.search = (trimmed, found.filter { $0.source == "user" || $0.source == "assistant" }) }
            self.pendingQuery = nil
            self.overlay?.controller.refresh()
        }
    }

    // MARK: Actions

    /// `openCommandPalette({open: "add-project"})`: the palette straight into Add project (the sidebar's
    /// button, the empty list's button, the no-projects hero).
    func openAddProject() {
        if overlay == nil { open() }
        guard let controller else { return }
        controller.setMode(nil)
        addProjectFlow.open()
    }

    /// Settings > Connections, where a machine gets added (`/settings/connections`).
    func openConnections() {
        commands.closeUtilityPage()
        settings.open()
        settings.show(.connections)
    }

    /// Leaves Settings or a utility page so the thread view shows.
    func showThreadView() {
        settings.close()
        commands.closeUtilityPage()
    }

    private func openThread(_ id: ThreadId) {
        showThreadView()
        threads.open(id)
    }

    /// `runThread` (CommandPaletteThreadItems.tsx:166-191): a pick from search sends its open with the query, so
    /// the server records it, and the thread view then skips its own open. The open thread is no pick.
    private func pickThread(_ id: ThreadId, query: String?) {
        let query = query ?? ""
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !query.hasPrefix(">"), id != threads.openThreadId,
           let shell = snapshot?.threads.first(where: { $0.id == id }) {
            _ = ThreadOpenLog.claim(id, now: Double(nowMs))
            if !shell.lastVisitedAt.isAbsent, !shell.opens.isAbsent {
                let visit = ThreadCommands.visit(id.localId, visitedAt: shell.updatedAt, opened: true,
                                                 searchQuery: PaletteScoring.pickedQuery(query))
                Task { _ = try? await self.environments.dispatch(id, visit) }
            }
        }
        openThread(id)
    }

    private func newThread(in project: ProjectShell) {
        showThreadView()
        threads.newThread(in: project)
    }

    /// The sidebar's new-thread button (`handleNewThreadClick`): one project or Shift creates at once,
    /// several open "New thread in..." (`openCommandPalette({open: "new-thread-in"})`).
    /// Dither skips the palette and opens a draft with no project, picked later from the project chip (Capy's).
    /// `opened` runs once the draft shows; Dither's scratch draft opens a moment later, after `projects.ensureScratch`.
    func newThreadFromSidebar(shift: Bool, then opened: (@MainActor () -> Void)? = nil) {
        if ThemeRuntime.isDither(dark: NSApp.effectiveAppearance.isDark), let env = scratchTargetEnvironmentId {
            startScratchThread(env, then: opened)
            return
        }
        defer { opened?() }
        if shift || projectGroups().count <= 1 { newThreadFromContext(); return }
        if let controller = overlay?.controller, let page = newThreadInPage() { controller.setMode(nil); controller.push(page); return }
        open(newThreadIn: true)
    }

    /// `startNewThreadFromContext`: the open thread's or draft's project, else the first.
    private func newThreadFromContext() {
        showThreadView()
        threads.newThread()
    }

    private func openProject(_ group: SidebarModel.ProjectGroup) {
        let members = Set(group.memberProjectIds)
        let latest = (snapshot?.threads ?? []).filter { $0.archivedAt == nil && members.contains($0.projectId) }
            .max { SidebarModel.getThreadSortTimestamp($0, .updatedAt) < SidebarModel.getThreadSortTimestamp($1, .updatedAt) }
        if let latest { openThread(latest.id) } else { newThread(in: group.representative) }
    }

    private func openUtility(_ page: SidebarCommands.UtilityPage) {
        commands.openUtilityPage(page)
    }

    /// A route under T3's `_chat` layout: a thread, a draft or Pull Requests, not Settings or Usage.
    private var onChatRoute: Bool { !settings.isOpen && !commands.isUsagePageOpen }

    // MARK: Appearance

    private func appearancePage() -> PalettePage {
        let current = AppearanceMode.current
        let items = AppearanceMode.allCases.map { mode in
            PaletteEntry(value: "appearance:\(mode.rawValue)", searchTerms: [mode.label, "appearance", "mode"], title: mode.label,
                         icon: mode.icon, note: mode == current ? "Current" : nil,
                         action: .run({ mode.apply() }, keepOpen: false))
        }
        return PalettePage(addonIcon: .monitor, groups: [PaletteGroup(value: "appearance", label: "Change appearance", items: items)])
    }

    /// "Change theme" (CommandPalette.tsx:2122-2165): the standard look, the built-ins and saved themes. A
    /// one-appearance theme takes its side of the mix.
    // ponytail: no preview circles beside the titles; PaletteEntry has no trailing view slot, add one if missed
    private func themePage() -> PalettePage {
        let lib = ThemeLibrary.shared
        let current = lib.ownerCard(lib.resolvedAppearance)
        let cards = [ThemeCardDefinition.standard] + (ThemeDefinition.pickerBuiltIns + lib.customThemes).map(ThemeCardDefinition.init)
        let items = cards.map { card in
            PaletteEntry(value: card.id.map { "theme:palette:\($0)" } ?? "theme:standard", searchTerms: [card.label, "theme", "appearance"],
                         title: card.label, description: card.previews.count == 1 ? "For \(card.previews[0].mode.rawValue) mode" : nil,
                         icon: .palette, note: current == card.id ? "Current" : nil,
                         action: .run({
                             if card.previews.count == 1, let id = card.id { lib.setThemeHalf(card.previews[0].mode, id) } else { lib.setTheme(card.id ?? lib.appearanceMode) }
                         }, keepOpen: false))
        }
        return PalettePage(addonIcon: .palette, groups: [PaletteGroup(value: "themes", label: "Change theme", items: items)])
    }

    /// `theme.select`: the palette on its Change theme page.
    func openChangeTheme() {
        if overlay == nil { open() }
        overlay?.controller.push(themePage())
    }

    private func cycleAppearance() {
        let next: AppearanceMode = switch AppearanceMode.current { case .system: .light; case .light: .dark; case .dark: .system }
        next.apply()
        threads.panel.toasts.show(ToastView(title: "Appearance: \(next.label)"), timeout: 1.5)
    }
}

/// T3's appearance mode (`APPEARANCE_OPTIONS`, CommandPalette.tsx:453-457), kept on this Mac like
/// T3's client settings.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var icon: IconName { switch self { case .system: .monitor; case .light: .sun; case .dark: .moon } }

    @MainActor static var current: AppearanceMode { AppearanceMode(rawValue: ThemeLibrary.shared.appearanceMode) ?? .system }

    /// Posted after `apply` (the Appearance page follows it).
    static let didChange = Notification.Name("CandyWrapperAppearanceModeDidChange")

    @MainActor func apply() {
        ThemeLibrary.shared.setAppearanceMode(rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

// MARK: - Prompt links (promptLinks/NewThreadLinkView.tsx and ThreadLinkPrompt.tsx in T3 3105)

extension PaletteCommands {
    /// A prompt link: a thread link puts its prompt in that thread's composer; a `/new` link opens a draft in the
    /// project its repository names, else without a project, or the thread behind its pull request. Nothing is sent.
    func openPromptLink(_ link: PromptLinks.Link, attempt: Int = 0) {
        switch link {
        case .thread(let env, let local, let prompt):
            showThreadView()
            threads.open(ThreadId(EnvironmentScope.key(env, local)))
            switch prompt {
            case .failure(let failure): linkError("Could not open the linked prompt", failure.message)
            case .success(let prompt?): threads.composer.placeLinkedPrompt(prompt)
            case .success(nil): break
            }
        case .newThread(.failure(let failure)):
            linkError("Could not open the link", failure.message)
        case .newThread(.success(let new)):
            // A cold launch from a link: the projects come with the first shell (`allReachableShellsLiveAtom`).
            // ponytail: waits for any shell, not every machine's; wait per environment if links land on the wrong machine
            if snapshot == nil, attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.openPromptLink(link, attempt: attempt + 1) }
                return
            }
            openNewThreadLink(new)
        }
    }

    private func openNewThreadLink(_ link: PromptLinks.NewThread) {
        let all = snapshot?.threads ?? []
        if case .pullRequest(let pr, let prompt) = link, let thread = PromptLinks.thread(in: all, for: pr) {
            showThreadView()
            threads.open(thread.id)
            if let prompt { threads.composer.placeLinkedPrompt(prompt) }
            return
        }
        let repository: PromptLinks.Repository? = switch link {
        case .new(_, let repository, _, _): repository
        case .pullRequest(let pr, _): pr.repository
        }
        guard let repository else { openLinkWithoutProject(link); return }
        let projects = SidebarModel.sortProjectsForSidebar((snapshot?.projects ?? []).filter { !isScratch($0) }, threads: all, order: .updatedAt)
        guard let project = PromptLinks.project(in: projects, for: repository) else { offerClone(repository, link: link); return }
        newThread(in: project)
        if case .pullRequest(let pr, let prompt) = link {
            // T3 asks before it checks out (PullRequestLinkCheckout); here the checkout dialog asks, with the pull request filled in.
            if let prompt { threads.composer.placeLinkedPrompt(prompt) }
            DispatchQueue.main.async { [weak self] in self?.threads.git.openPullRequestDialog(pr.url) }
            return
        }
        placeLinkDraft(link)
    }

    /// The draft that just opened takes the link's model and prompt (`openDraft`).
    private func placeLinkDraft(_ link: PromptLinks.NewThread, extra: String? = nil) {
        var notes: [String] = []
        var prompt: PromptLinks.Prompt?
        switch link {
        case .new(let p, _, let provider, let model):
            prompt = p
            if let provider, let note = threads.composer.pickLinkedModel(provider: provider, model: model) { notes.append(note) }
        case .pullRequest(_, let p): prompt = p
        }
        let text = [prompt?.text, extra].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        threads.composer.placeLinkedPrompt(PromptLinks.Prompt(text: text, hiddenCharacters: prompt?.hiddenCharacters ?? 0), notes: notes)
    }

    /// The machine the user worked on last (`lastActiveEnvironmentId`).
    private var lastActiveEnvironmentId: String? {
        (snapshot?.threads ?? []).max { ($0.updatedAt.epochMs ?? 0) < ($1.updatedAt.epochMs ?? 0) }?.id.environmentId ?? environments.primaryId
    }

    /// `openWithoutProject`: "No project" on the machine the user last worked on.
    private func openLinkWithoutProject(_ link: PromptLinks.NewThread) {
        guard let env = scratchEnvironmentId(lastActiveEnvironmentId) ?? scratchEnvironmentId(nil) else {
            linkError("Could not open the link", "None of your machines can start a thread without a project right now.")
            return
        }
        // Without its repository, a pull request link still says which one it meant.
        let extra: String? = if case .pullRequest(let pr, _) = link { pr.url } else { nil }
        startScratchThread(env) { [weak self] in self?.placeLinkDraft(link, extra: extra) }
    }

    /// "You don't have owner/name" (NewThreadLinkView.tsx:286-300), as a toast: clone it, or start without a project.
    private func offerClone(_ repository: PromptLinks.Repository, link: PromptLinks.NewThread) {
        let name = "\(repository.owner)/\(repository.name)"
        let toast = ToastView(title: "You don't have \(name)", message: "Clone it to work on it here, or start without a project.", kind: .info,
                              actionTitle: "Clone \(name)", action: { [weak self] in
                                  self?.dismissLinkToast()
                                  self?.cloneLinkRepository(repository, link: link)
                              }, secondaryTitle: "Use without project", secondaryAction: { [weak self] in
                                  self?.dismissLinkToast()
                                  self?.openLinkWithoutProject(link)
                              })
        dismissLinkToast()
        linkToast = threads.panel.toasts.show(toast, timeout: 0)
    }

    private func dismissLinkToast() {
        if let id = linkToast { threads.panel.toasts.dismiss(id) }
        linkToast = nil
    }

    /// `cloneRepository`: `projectClone.start` into the machine's new-projects folder, then the draft, which waits for the clone.
    private func cloneLinkRepository(_ repository: PromptLinks.Repository, link: PromptLinks.NewThread) {
        guard let env = lastActiveEnvironmentId, let config = threads.composer.config(env), let root = config.newProjectsRoot,
              config.capabilities.contains("projectCloneTracking") else {
            linkError("Could not open the link", "This machine cannot clone from a link. Update it, or clone the repository from the command palette.")
            return
        }
        let projectId = UUID().uuidString.lowercased()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.environments.request(env, "projectClone.start", .object([
                    "projectId": .string(projectId), "title": .string(repository.name), "createdAt": .string(T3Timestamp(Date()).raw),
                    "remoteUrl": .string("https://github.com/\(repository.owner)/\(repository.name).git"),
                    "destinationPath": .string(PaletteAddProjectPaths.cloneDestinationPath(root, repository.name)),
                ]))
            } catch {
                let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription
                self.linkError("Clone failed", message ?? "An error occurred.")
                return
            }
            let id = ProjectId(EnvironmentScope.key(env, projectId))
            for _ in 0..<50 {
                if let project = self.snapshot?.projects.first(where: { $0.id == id }) {
                    // A pull request checks out from the cloned repository, which is not there yet.
                    if case .pullRequest = link {
                        self.linkError("Cloning \(repository.owner)/\(repository.name)", "Open this link again when the clone finishes.", kind: .info)
                        return
                    }
                    self.newThread(in: project)
                    self.placeLinkDraft(link)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.linkError("Could not open the link", "The clone started, but its project did not appear.")
        }
    }

    private func linkError(_ title: String, _ message: String, kind: ToastQueue.Kind = .error) {
        threads.panel.toasts.show(ToastView(title: title, message: message, kind: kind))
    }
}
