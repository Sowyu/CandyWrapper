import AppKit
import DesignSystem
import Features
import T3Protocol
import T3Store

/// The command palette's entries and open state (apps/web/src/components/CommandPalette.tsx). The
/// `Features` controller renders and routes keys; this class knows what the app can do.
@MainActor
final class PaletteCommands {
    private weak var window: NSWindow?
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let threads: ThreadController
    private let commands: SidebarCommands
    private let settings: SettingsController
    private var overlay: CommandPaletteOverlay?
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
        // `chat.new`: with several projects the palette's project chooser, else a draft for the open
        // thread's project (_chat.tsx:121-140). `chat.newLocal` skips the chooser.
        shortcuts.on(["chat.new", "chat.newLocal"]) { [weak self] call in
            guard let self, self.sidebar?.snapshot?.projects.isEmpty == false else { return false }
            if call.command == "chat.new", self.projectGroups().count > 1 { self.open(newThreadIn: true) } else { self.newThreadFromContext() }
            return true
        }
        // `filePicker.toggle` (`ToggleMode "files"`, CommandPalette.tsx:440-450, 574-580).
        shortcuts.on("filePicker.toggle") { [weak self] call in
            guard let self, !call.isRepeat else { return true }
            if self.overlay?.controller.mode?.name == "files" { self.close() } else { self.openFilePicker() }
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
            if controller?.mode?.name == "files" { self?.searchFiles(query) } else { self?.searchMessages(query) }
        }
        overlay.onDismiss = { [weak self, weak overlay] in if self?.overlay === overlay { self?.overlay = nil } }
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
        pickerTask?.cancel()
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
            threadSearchPending: { [weak self] query in self?.pendingQuery == query.trimmingCharacters(in: .whitespaces) })
    }

    private var snapshot: ShellSnapshot? { sidebar?.snapshot }
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
        // ponytail: no "New thread without a project", "Find in current thread", PR, restart session,
        // project search, New project, theme and project settings entries; each lands with its work package
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
        actions.append(PaletteEntry(value: "action:open-file-picker", searchTerms: ["go to file", "open file", "file picker", "find file", "quick open"],
                                    title: "Go to file", icon: .fileSearch, shortcutCommand: "filePicker.toggle",
                                    action: .run({ [weak self] in self?.openFilePicker() }, keepOpen: true)))
        actions.append(PaletteEntry(value: "action:add-project", searchTerms: ["add project", "folder", "directory", "browse", "clone", "remote",
                                                                                "repository", "repo", "git", "github", "gitlab", "forgejo", "bitbucket",
                                                                                "azure", "devops", "url", "environment"],
                                    title: "Add project", icon: .folderPlus,
                                    action: .run({ [weak self] in self?.commands.addProject() }, keepOpen: false)))
        actions.append(PaletteEntry(value: "action:change-appearance", searchTerms: ["change appearance", "light", "dark", "system", "mode", "toggle"],
                                    title: "Change appearance", icon: .monitor, shortcutCommand: "appearance.cycle",
                                    action: .submenu(appearancePage())))
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
        var result = [PaletteGroup(value: "actions", label: "Actions", items: actions)]
        let recent = Array(threadItems(query: nil).prefix(PaletteSearch.recentThreadLimit))
        if !recent.isEmpty { result.append(PaletteGroup(value: "recent-threads", label: "Recent Threads", items: recent)) }
        return result
    }

    /// "New thread in..." (`projectThreadItems`): one entry per project group, `thread.jump.N` on the first nine.
    private func newThreadInPage() -> PalettePage? {
        let groups = projectGroups()
        guard !groups.isEmpty else { return nil }
        let current = threads.composer.activeProjectId
        let items = groups.map { group in
            PaletteEntry(value: "new-thread-in:\(group.key)", searchTerms: [group.label, group.representative.title, group.representative.workspaceRoot]
                            + group.members.flatMap { [$0.title, $0.workspaceRoot] } + [locationLabel(group.representative.id.environmentId)],
                         title: group.label, description: projectDescription(group), icon: .folder,
                         action: .run({ [weak self] in
                             // The open thread's own member when it is in this group, else the group's project.
                             let member = current.flatMap { id in group.members.first { $0.id == id } } ?? group.representative
                             self?.newThread(in: member)
                         }, keepOpen: false))
        }
        return PalettePage(addonIcon: .squarePen, groups: [PaletteGroup(value: "projects", label: "Projects", items: PaletteSearch.enumerate(items))])
    }

    /// `projectSearchItems`: opens the group's latest thread, else a draft (`openProjectFromSearch`).
    private func projectSearchItems() -> [PaletteEntry] {
        projectGroups().map { group in
            PaletteEntry(value: "project:\(group.key)", searchTerms: projectSearchTerms(group), title: group.label,
                         description: projectDescription(group), icon: .folder,
                         action: .run({ [weak self] in self?.openProject(group) }, keepOpen: false))
        }
    }

    /// `buildThreadActionItems` over every unarchived thread, newest first, with message matches for `query`.
    // ponytail: text description and match line; T3 draws the project favicon, provider icon, status pill and highlighted match
    private func threadItems(query: String?) -> [PaletteEntry] {
        guard let snapshot else { return [] }
        let open = threads.openThreadId
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let matches = query.flatMap { q in search.flatMap { $0.query == q.trimmingCharacters(in: .whitespaces) ? $0.matches : nil } } ?? [:]
        let ms = nowMs
        return snapshot.threads.filter { $0.archivedAt == nil }
            .sorted { SidebarModel.getThreadSortTimestamp($0, .updatedAt) > SidebarModel.getThreadSortTimestamp($1, .updatedAt) }
            .map { thread in
                let projectTitle = projects[thread.projectId]?.title
                var parts = [projectTitle, locationLabel(thread.id.environmentId)].compactMap { $0 }
                if thread.id == open { parts.append("Current thread") }
                let match = matches[thread.id].map { ($0.source == "user" ? "You: " : "Agent: ") + $0.snippet }
                let stamp = (thread.latestUserMessageAt ?? thread.updatedAt).raw
                let id = thread.id
                return PaletteEntry(value: "thread:\(thread.id.rawValue)",
                                    searchTerms: [thread.title, projectTitle ?? "", thread.branch ?? "", matches[thread.id]?.snippet ?? "", thread.id.localId.rawValue],
                                    title: thread.title, description: parts.joined(separator: " \u{00B7} "), match: match,
                                    timestamp: TimestampFormat.formatRelativeTimeLabel(stamp, nowMs: ms),
                                    searchRecency: Int64(SidebarModel.getThreadSortTimestamp(thread, .updatedAt)), icon: .messageSquare,
                                    action: .run({ [weak self] in self?.openThread(id) }, keepOpen: false))
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

    /// Leaves Settings or a utility page so the thread view shows.
    private func showThreadView() {
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
        settings.close()
        commands.openUtilityPage(page)
    }

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

    private static let key = "appearance.mode"

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var icon: IconName { switch self { case .system: .monitor; case .light: .sun; case .dark: .moon } }

    static var current: AppearanceMode { UserDefaults.standard.string(forKey: key).flatMap(AppearanceMode.init) ?? .system }

    /// Posted after `apply` (the Appearance page follows it).
    static let didChange = Notification.Name("CandyWrapperAppearanceModeDidChange")

    @MainActor func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        Self.applySaved()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    @MainActor static func applySaved() {
        switch current {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
