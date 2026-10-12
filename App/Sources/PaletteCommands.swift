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
    /// The open palette's controller.
    var controller: CommandPaletteController? { overlay?.controller }
    /// Thread message search (`useThreadSearch`, state/queries.ts:75-101): 2+ characters, 200 ms debounce.
    private var search: (query: String, matches: [ThreadId: ThreadSearchMatch])?
    private var searchTask: Task<Void, Never>?
    private var pendingQuery: String?
    /// Go to file's server results (`useProjectFilePickerQuery`): the query they answer.
    private var picker: (query: String, entries: [ProjectEntry]?)?
    private var pickerTask: Task<Void, Never>?

    init(window: NSWindow, sidebar: SidebarContentView, environments: Environments, threads: ThreadController,
         commands: SidebarCommands, settings: SettingsController) {
        self.window = window
        self.sidebar = sidebar
        self.environments = environments
        self.threads = threads
        self.commands = commands
        self.settings = settings
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
        CommandPaletteController.Source(
            rootGroups: { [weak self] in self?.rootGroups() ?? [] },
            projectItems: { [weak self] in self?.projectSearchItems() ?? [] },
            threadItems: { [weak self] query in self?.threadItems(query: query) ?? [] },
            threadSearchPending: { [weak self] query in self?.pendingQuery == query.trimmingCharacters(in: .whitespaces) },
            settingsItems: { [weak self] query in self?.settingsItems(query) ?? [] })
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
        var groups = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: envs.primaryId)
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
                                        title: target.title.hasPrefix("PR") ? "Copy PR link" : "Copy thread ID", description: target.value,
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
        let recent = threadItems(query: nil, limit: PaletteSearch.recentThreadLimit)
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

    /// `scratchEnvironmentId`: the current machine if it offers a scratch folder, else with no current
    /// machine the one machine that does.
    func scratchEnvironmentId(_ current: String?) -> String? {
        if let current { return scratchRoot(current) != nil ? current : nil }
        let offering = environments.environmentIds.filter { scratchRoot($0) != nil }
        return offering.count == 1 ? offering[0] : nil
    }

    /// The open thread's or draft's machine, else the primary (`scratchTargetEnvironmentId`).
    var scratchTargetEnvironmentId: String? {
        scratchEnvironmentId(threads.composer.targetEnvironmentId ?? environments.primaryId)
    }

    private func isScratch(_ project: ProjectShell) -> Bool {
        guard let env = project.id.environmentId, let root = threads.composer.config(env)?.scratchWorkspaceRoot else { return false }
        return SidebarModel.normalizeProjectPath(root) == SidebarModel.normalizeProjectPath(project.workspaceRoot)
    }

    /// `startScratchThread`: `projects.ensureScratch`, wait for the project in the shell (10 s), then a draft in it.
    func startScratchThread(_ env: String) {
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
            } catch {
                let message = (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription
                self.threads.panel.toasts.show(ToastView(title: "Could not start without a project", message: message ?? "An error occurred.", kind: .error))
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

    /// `buildThreadActionItems` over every unarchived thread, newest first, with message matches for `query`;
    /// `limit` keeps the newest only, as its `input.limit` does (CommandPalette.logic.ts:337).
    // ponytail: text description and match line; T3 draws the project favicon, provider icon, status pill and highlighted match
    private func threadItems(query: String?, limit: Int? = nil) -> [PaletteEntry] {
        guard let snapshot else { return [] }
        let open = threads.openThreadId
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let matches = query.flatMap { q in search.flatMap { $0.query == q.trimmingCharacters(in: .whitespaces) ? $0.matches : nil } } ?? [:]
        let ms = nowMs
        // Sort positions, not the large shells themselves.
        let all = snapshot.threads
        let live = all.indices.filter { all[$0].archivedAt == nil }
        let keys = live.map { SidebarModel.getThreadSortTimestamp(all[$0], .updatedAt) }
        let order = keys.indices.sorted { keys[$0] > keys[$1] }.map { live[$0] }
        return (limit.map { Array(order.prefix($0)) } ?? order)
            .map { index in
                let thread = all[index]
                let projectTitle = projects[thread.projectId]?.title
                var parts = [projectTitle, locationLabel(thread.id.environmentId)].compactMap { $0 }
                if thread.id == open { parts.append("Current thread") }
                let match = matches[thread.id].map { ($0.source == "user" ? "You: " : "Agent: ") + $0.snippet }
                let stamp = (thread.latestUserMessageAt ?? thread.updatedAt).raw
                let id = thread.id
                var entry = PaletteEntry(value: "thread:\(thread.id.rawValue)",
                                    searchTerms: [thread.title, projectTitle ?? "", thread.branch ?? "", matches[thread.id]?.snippet ?? "", thread.id.localId.rawValue],
                                    title: thread.title, description: parts.joined(separator: " \u{00B7} "), match: match,
                                    timestamp: TimestampFormat.formatRelativeTimeLabel(stamp, nowMs: ms),
                                    searchRecency: Int64(SidebarModel.getThreadSortTimestamp(thread, .updatedAt)), icon: .messageSquare,
                                    action: .run({ [weak self] in self?.openThread(id) }, keepOpen: false))
                if let m = matches[thread.id] { entry.matchIsUser = m.source == "user"; entry.matchQuery = query }
                return entry
            }
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
        guard trimmed.count >= 2, !query.hasPrefix(">") else { pendingQuery = nil; return }
        pendingQuery = trimmed
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let found = await self.environments.searchThreads(trimmed) ?? []
            guard !Task.isCancelled, self.pendingQuery == trimmed else { return }
            var byThread: [ThreadId: ThreadSearchMatch] = [:]
            for m in found where (m.source == "user" || m.source == "assistant") && byThread[m.threadId] == nil { byThread[m.threadId] = m }
            self.search = (trimmed, byThread)
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

    private func newThread(in project: ProjectShell) {
        showThreadView()
        threads.newThread(in: project)
    }

    /// The sidebar's new-thread button (`handleNewThreadClick`): one project or Shift creates at once,
    /// several open "New thread in..." (`openCommandPalette({open: "new-thread-in"})`).
    func newThreadFromSidebar(shift: Bool) {
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
        let cards = [ThemeCardDefinition.standard] + (ThemeDefinition.builtIns + lib.customThemes).map(ThemeCardDefinition.init)
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
