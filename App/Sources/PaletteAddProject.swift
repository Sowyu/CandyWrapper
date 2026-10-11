import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The command palette's add-project flows (CommandPalette.tsx:1545-1840, 2370-2990, 3228-3500): the
/// environment step, the sources (New project, Local folder, Git URL, the source control hosts), the
/// folder browser on `filesystem.browse`, the clone steps and New project's name step.
@MainActor
final class PaletteAddProjectFlow {
    private weak var palette: PaletteCommands?
    private let environments: Environments
    private let threads: ThreadController
    private let commands: SidebarCommands
    /// `addProjectEnvironmentId`: the machine the open add-project view works on.
    private var environmentId: String?
    /// `filesystem.browse` results by `env|directory|cwd`; a nil result is in flight.
    private var browseCache: [String: BrowseState] = [:]
    private var clone: CloneStep?
    private var newProject: (environmentId: String, sourcesEnvironmentId: String?)?
    private var publishesToGitHub = false
    private var busy = false
    private var pickingFolder = false
    /// `server.discoverSourceControl` per environment: `nil` while loading.
    private var discovery: [String: JSONValue?] = [:]

    enum BrowseState { case loading, loaded(parent: String, entries: [PaletteAddProjectPaths.Entry]), failed(String) }

    enum CloneStep {
        case repository(environmentId: String, source: String)
        case confirm(environmentId: String, source: String, input: String, repository: JSONValue?, remoteUrl: String)
        var environmentId: String {
            switch self { case .repository(let e, _), .confirm(let e, _, _, _, _): e }
        }
        var source: String {
            switch self { case .repository(_, let s), .confirm(_, let s, _, _, _): s }
        }
    }

    static let providerSources = ["github", "gitlab", "forgejo", "bitbucket", "azure-devops"]

    init(palette: PaletteCommands, environments: Environments, threads: ThreadController, commands: SidebarCommands) {
        self.palette = palette
        self.environments = environments
        self.threads = threads
        self.commands = commands
    }

    private var controller: CommandPaletteController? { palette?.controller }

    /// The palette closed: every step starts over next time.
    func reset() {
        environmentId = nil
        clone = nil
        newProject = nil
        publishesToGitHub = false
        busy = false
        browseCache = [:]
    }

    // MARK: Environments

    struct Option { let id: String; let label: String; let isPrimary: Bool; let machine: String }

    /// `addProjectEnvironmentOptions`: connected machines, this device first, then by label.
    var options: [Option] {
        environments.environmentIds.filter { environments.state($0)?.status == .connected }.map { id in
            let primary = id == environments.primaryId
            let label = environments.label(id)?.trimmingCharacters(in: .whitespaces) ?? ""
            let generic = ["local", "local environment"].contains(label.lowercased())
            return Option(id: id, label: primary ? (label.isEmpty || generic ? "This device" : label) : (label.isEmpty ? id : label),
                          isPrimary: primary, machine: environments.machine(id) ?? "server")
        }.sorted { l, r in l.isPrimary != r.isPrimary ? l.isPrimary : l.label.localizedCompare(r.label) == .orderedAscending }
    }

    private var defaultEnvironmentId: String? { options.first?.id }
    private var browseEnvironmentId: String? { environmentId ?? defaultEnvironmentId }

    /// `buildEnvironmentItem`.
    private func environmentEntry(_ o: Option, value: String, run: @escaping @MainActor (String) -> Void) -> PaletteEntry {
        var entry = PaletteEntry(value: value, searchTerms: [o.label, o.id, o.isPrimary ? "this device" : ""], title: o.label,
                                 description: o.isPrimary ? "This device" : o.id, icon: .server,
                                 action: .run({ run(o.id) }, keepOpen: true))
        entry.glyph = (EnvironmentMachineIcon.definition(o.machine), Themed.color(\.contrastIconMuted))
        return entry
    }

    /// `openAddProjectFlow`: no machine opens Connections, several ask which, one goes to its sources.
    func open() {
        guard let controller else { return }
        let options = self.options
        if options.isEmpty {
            palette?.close()
            palette?.openConnections()
            return
        }
        if options.count > 1 || defaultEnvironmentId == nil {
            controller.push(PalettePage(addonIcon: .folderPlus, groups: [PaletteGroup(value: "environments", label: "Environments", items: options.map {
                environmentEntry($0, value: "action:add-project:environment:\($0.id)") { [weak self] id in self?.startSources(id) }
            })]))
            return
        }
        startSources(options[0].id)
    }

    // MARK: Sources

    private func startSources(_ env: String) {
        guard environments.state(env)?.status == .connected else {
            toast("Environment unavailable", "\(environments.label(env) ?? "The selected environment") is not connected.")
            return
        }
        environmentId = env
        clone = nil
        loadDiscovery(env)
        controller?.push(PalettePage(addonIcon: .folderPlus, groups: [], mode: sourcesMode(env)))
    }

    private func newProjectsRoot(_ env: String?) -> String? { env.flatMap { threads.composer.config($0)?.newProjectsRoot } }

    private func sourcesMode(_ env: String) -> CommandPaletteController.Mode {
        var mode = CommandPaletteController.Mode(name: "add-project-sources", placeholder: "Search...", footerActionLabel: "Select") { [weak self] query in
            guard let self else { return ([], "") }
            let groups = PaletteSearch.filter([PaletteGroup(value: "sources:\(env)", label: "Sources", items: self.sourceItems(env))],
                                              query: query, isInSubmenu: true, projectItems: [], threadItems: [])
            return (groups, "No matching commands, projects, or threads.")
        }
        mode.autoHighlight = true
        return mode
    }

    /// `buildAddProjectSourceGroups`.
    private func sourceItems(_ env: String) -> [PaletteEntry] {
        var items: [PaletteEntry] = []
        if newProjectsRoot(env) != nil {
            items.append(PaletteEntry(value: "action:add-project:\(env):new", searchTerms: ["new project", "create", "empty", "repository", "git init"],
                                      title: "New project", description: "Start a new Git repository from a name", icon: .folderGit2,
                                      action: .run({ [weak self] in self?.startNewProject(env, sourcesEnvironmentId: env) }, keepOpen: true)))
        }
        items.append(PaletteEntry(value: "action:add-project:\(env):local", searchTerms: ["local", "folder", "directory", "browse"],
                                  title: "Local folder", description: "Browse a folder on disk", icon: .folderPlus,
                                  action: .run({ [weak self] in self?.startBrowse(env) }, keepOpen: true)))
        let readiness = self.readiness(env)
        let providers = Self.providerSources.sorted { l, r in
            let lr = readiness[l]?.ready ?? false, rr = readiness[r]?.ready ?? false
            return lr != rr ? lr : Self.sourceLabel(l) < Self.sourceLabel(r)
        }
        for source in ["url"] + providers {
            let label = Self.sourceLabel(source)
            let title = source == "url" ? "Git URL" : "\(label) repository"
            let description = source == "url" ? "Clone from a remote URL" : "Clone \(label) \(Self.sourcePathHint(source))"
            let ready = readiness[source]?.ready ?? (source == "url")
            var entry = PaletteEntry(value: "action:add-project:\(env):\(source)\(ready ? "" : ":not-ready")",
                                     searchTerms: ["clone", "remote", "repository", "repo", "git", label] + (ready ? [] : ["setup required"]),
                                     title: title, description: description, icon: .link,
                                     action: .run({ [weak self] in self?.startClone(env, source: source) }, keepOpen: true))
            if let glyph = Self.sourceGlyph(source) { entry.glyph = (glyph, Themed.color(\.contrastIconMuted)) }
            if !ready {
                entry.isDisabled = true
                entry.note = "Setup Required"
                entry.noteIsWarning = true
            }
            items.append(entry)
        }
        return items
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "github": "GitHub"
        case "forgejo": "Forgejo / Gitea"
        case "gitlab": "GitLab"
        case "bitbucket": "Bitbucket"
        case "azure-devops": "Azure DevOps"
        default: "Git URL"
        }
    }

    static func sourcePathHint(_ source: String) -> String {
        switch source {
        case "forgejo", "github": "owner/repo"
        case "gitlab": "group/project"
        case "bitbucket": "workspace/repository"
        case "azure-devops": "project/repository"
        default: "URL"
        }
    }

    // ponytail: no Bitbucket or Azure DevOps glyphs in the icon set; those rows show the link icon
    static func sourceGlyph(_ source: String) -> IconDefinition? {
        switch source {
        case "github": IconName.brandGitHub.definition
        case "gitlab": IconName.brandGitLab.definition
        case "forgejo": IconName.brandForgejo.definition
        default: nil
        }
    }

    /// `buildAddProjectRemoteSourceReadiness`.
    private func readiness(_ env: String) -> [String: (ready: Bool, hint: String?)] {
        let unavailable = (ready: false, hint: Optional("Provider status unavailable. Open Settings -> Source Control and rescan."))
        var out: [String: (ready: Bool, hint: String?)] = ["url": (true, nil)]
        guard case .some(.some(let result)) = discovery[env] else {
            for s in Self.providerSources { out[s] = unavailable }
            return out
        }
        let providers = SourceControlDiscoveryItem.list(result).providers
        for s in Self.providerSources {
            guard let p = providers.first(where: { $0.kind == s }) else { out[s] = unavailable; continue }
            if p.status != "available" { out[s] = (false, p.installHint); continue }
            if p.auth?["status"]?.stringValue == "unauthenticated" {
                out[s] = (false, p.auth?["detail"]?.stringValue ?? "\(p.label) is not authenticated. Open Settings -> Source Control for setup guidance.")
                continue
            }
            out[s] = (true, nil)
        }
        return out
    }

    private func loadDiscovery(_ env: String) {
        guard discovery[env] == nil else { return }
        discovery[env] = .some(nil)
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.environments.request(env, "server.discoverSourceControl", .object([:]))
            self.discovery[env] = .some(result)
            self.controller?.refresh()
        }
    }

    // MARK: Browse (`isBrowsing`)

    /// The query's browse mode: a path typed at the root, in a submenu or as the clone destination.
    func browseMode(_ query: String) -> CommandPaletteController.Mode? {
        guard browseEnvironmentId != nil, PaletteAddProjectPaths.isBrowseQuery(query) else { return nil }
        return makeBrowseMode(cloneDestination: false)
    }

    private var currentProjectCwd: (environmentId: String, cwd: String)? {
        guard let id = threads.composer.activeProjectId, let env = id.environmentId,
              let project = palette?.snapshot?.projects.first(where: { $0.id == id }) else { return nil }
        return (env, project.workspaceRoot)
    }

    /// `currentProjectCwdForBrowse`: the open thread's project folder when it is on the browsed machine.
    private var browseCwd: String? {
        guard let env = browseEnvironmentId, let current = currentProjectCwd, current.environmentId == env else { return nil }
        return current.cwd
    }

    private var pinnedCloneName: String {
        guard case .confirm(_, _, let input, let repository, let remoteUrl)? = clone else { return "" }
        _ = input
        return PaletteAddProjectPaths.cloneDirectoryName(repository?["nameWithOwner"]?.stringValue ?? remoteUrl)
    }

    private func browseKey(_ env: String, _ dir: String) -> String { "\(env)|\(dir)|\(browseCwd ?? "")" }

    /// `filesystem.browse` for a directory, once; the palette refreshes when it lands.
    @discardableResult
    private func load(_ dir: String, env: String) -> BrowseState? {
        let key = browseKey(env, dir)
        if let state = browseCache[key] { return state }
        browseCache[key] = .loading
        var payload: [String: JSONValue] = ["partialPath": .string(dir)]
        if let cwd = browseCwd { payload["cwd"] = .string(cwd) }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.environments.request(env, "filesystem.browse", .object(payload))
                let entries = (result["entries"]?.arrayValue ?? []).compactMap { e -> PaletteAddProjectPaths.Entry? in
                    guard let name = e["name"]?.stringValue, let full = e["fullPath"]?.stringValue else { return nil }
                    return .init(name: name, fullPath: full)
                }
                self.browseCache[key] = .loaded(parent: result["parentPath"]?.stringValue ?? dir, entries: entries)
            } catch {
                self.browseCache[key] = .failed(Self.message(error))
            }
            self.controller?.refresh()
        }
        return .loading
    }

    private struct BrowseView {
        var groups: [PaletteGroup] = []
        var status: String?
        var empty = ""
        var resolvedPath = ""
        var willCreate = false
        var canSubmit = false
    }

    /// Everything a browse query shows and what Enter would add.
    private func browseView(_ query: String, cloneDestination: Bool) -> BrowseView {
        var v = BrowseView()
        guard let env = browseEnvironmentId else { return v }
        let relativeNeedsProject = PaletteAddProjectPaths.isExplicitRelative(query.trimmingCharacters(in: .whitespaces)) && browseCwd == nil
        let dir = PaletteAddProjectPaths.directoryPath(query)
        let filter = PaletteAddProjectPaths.hasTrailingSeparator(query) ? "" : PaletteAddProjectPaths.leafSegment(query)
        var state: BrowseState?
        if !relativeNeedsProject, !dir.isEmpty { state = load(dir, env: env) }
        var entries: [PaletteAddProjectPaths.Entry] = []
        var exact: PaletteAddProjectPaths.Entry?
        var loadedParent: String?
        switch state {
        case .loaded(let parent, let all)?:
            loadedParent = parent
            let pinned = cloneDestination ? pinnedCloneName : ""
            (entries, exact) = pinned.isEmpty ? PaletteAddProjectPaths.filter(all, query: filter)
                : PaletteAddProjectPaths.filterPinned(all, query: filter, pinned: pinned)
        case .failed(let message)?: v.status = message
        case .loading?: v.status = "Loading folders..."
        case nil: break
        }
        var items: [PaletteEntry] = []
        if !relativeNeedsProject, PaletteAddProjectPaths.canNavigateUp(dir) {
            items.append(PaletteEntry(value: "browse:up", searchTerms: [query, ".."], title: "..", icon: .cornerLeftUp,
                                      action: .run({ [weak self] in self?.browseUp(query, cloneDestination: cloneDestination) }, keepOpen: true)))
        }
        for e in entries {
            items.append(PaletteEntry(value: "browse:\(e.fullPath)", searchTerms: [query, e.fullPath, e.name], title: e.name, icon: .folder,
                                      action: .run({ [weak self] in self?.browseTo(e.name, query: query, cloneDestination: cloneDestination) }, keepOpen: true)))
        }
        if !relativeNeedsProject {
            v.groups = [PaletteGroup(value: "directories", label: cloneDestination ? "Select where to clone" : "Directories", items: items)]
        }
        if case .loaded? = state { v.status = nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        v.resolvedPath = PaletteAddProjectPaths.hasTrailingSeparator(query) ? (loadedParent ?? trimmed) : (exact?.fullPath ?? trimmed)
        let loaded: Bool = { if case .loaded? = state { return true } else { return false } }()
        v.canSubmit = !relativeNeedsProject && environments.state(env)?.status == .connected
        v.willCreate = v.canSubmit && loaded && !trimmed.isEmpty
            && (PaletteAddProjectPaths.hasTrailingSeparator(query) ? false : exact == nil)
        v.empty = relativeNeedsProject ? "Relative paths require an active project."
            : cloneDestination ? "Choose a destination path and press Enter to clone."
            : v.willCreate ? "Press Enter to create this folder and add it as a project." : "No matching commands, projects, or threads."
        return v
    }

    private func makeBrowseMode(cloneDestination: Bool) -> CommandPaletteController.Mode {
        let inSubmenu = controller?.isInSubmenu ?? false
        let placeholder = inSubmenu || cloneDestination ? "Enter path (e.g. ~/projects/my-app)" : "Enter project path (e.g. ~/projects/my-app)"
        var mode = CommandPaletteController.Mode(name: "browse", placeholder: placeholder, footerActionLabel: "Select") { [weak self] query in
            guard let self else { return ([], "") }
            let v = self.browseView(query, cloneDestination: cloneDestination)
            if v.groups.first?.items.isEmpty ?? true, v.status == nil { return ([], v.empty) }
            return (v.groups.filter { !$0.items.isEmpty }, v.empty)
        }
        mode.status = { [weak self] query in
            guard let self else { return nil }
            let v = self.browseView(query, cloneDestination: cloneDestination)
            return v.status
        }
        mode.autoHighlight = false
        mode.startIcon = .folderPlus
        mode.onSubmit = { [weak self] query, highlighted, flags in
            guard let self else { return false }
            let isBrowseRow = highlighted?.value.hasPrefix("browse:") ?? false
            guard !isBrowseRow || flags.contains(.command) else { return false }
            let v = self.browseView(query, cloneDestination: cloneDestination)
            guard v.canSubmit else { return true }
            if cloneDestination { self.submitClone(destination: v.resolvedPath) } else { self.addProject(v.resolvedPath) }
            return true
        }
        mode.footerLabel = { highlighted in highlighted?.value.hasPrefix("browse:") == true ? "Select" : nil }
        mode.accessory = submitButton { [weak self] in
            guard let self, let query = self.controller?.query else { return ("Add", "Enter", false) }
            let v = self.browseView(query, cloneDestination: cloneDestination)
            let highlightedBrowse = self.controller?.highlightedItemValue?.hasPrefix("browse:") ?? false
            let title = cloneDestination ? (self.busy ? "Cloning" : v.willCreate && !highlightedBrowse ? "Create & Clone" : "Clone")
                : (v.willCreate && !highlightedBrowse ? "Create & Add" : "Add")
            return (title, highlightedBrowse ? "\u{2318} Enter" : "Enter", v.canSubmit && !(cloneDestination && self.busy))
        } action: { [weak self] in
            guard let self, let query = self.controller?.query else { return }
            let v = self.browseView(query, cloneDestination: cloneDestination)
            guard v.canSubmit else { return }
            if cloneDestination { self.submitClone(destination: v.resolvedPath) } else { self.addProject(v.resolvedPath) }
        }
        if browseEnvironmentId == environments.primaryId {
            let open = ButtonView("Open in Finder", variant: .ghostMuted, size: .xs)
            open.action = { [weak self] in self?.openInFinder() }
            mode.footerTrailing = open
        }
        return mode
    }

    private func browseTo(_ name: String, query: String, cloneDestination: Bool) {
        let pinned = cloneDestination ? pinnedCloneName : ""
        let next = pinned.isEmpty ? PaletteAddProjectPaths.appendSegment(query, name)
            : PaletteAddProjectPaths.cloneDestinationBrowsePath(directory: PaletteAddProjectPaths.directoryPath(query), selected: name, cloneName: pinned)
        controller?.replaceQuery(next)
    }

    private func browseUp(_ query: String, cloneDestination: Bool) {
        guard let parent = PaletteAddProjectPaths.parentPath(PaletteAddProjectPaths.directoryPath(query)) else { return }
        controller?.replaceQuery(PaletteAddProjectPaths.cloneDestinationPath(parent, cloneDestination ? pinnedCloneName : nil))
    }

    /// `getAddProjectInitialQueryForEnvironment`: the `addProjectBaseDirectory` setting as a folder, else `~/`.
    private func initialQuery(_ env: String) -> String {
        let base = threads.composer.config(env)?.settings.raw["addProjectBaseDirectory"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? "~/" : PaletteAddProjectPaths.ensureDirectoryPath(base)
    }

    private func startBrowse(_ env: String) {
        environmentId = env
        clone = nil
        let query = initialQuery(env)
        load(PaletteAddProjectPaths.directoryPath(query), env: env)
        controller?.push(PalettePage(addonIcon: .folderPlus, groups: [], initialQuery: query))
    }

    /// `handleAddProject` on the browsed machine.
    private func addProject(_ rawPath: String) {
        guard let env = browseEnvironmentId else { return }
        guard environments.state(env)?.status == .connected else {
            toast("Environment unavailable", "\(environments.label(env) ?? "The selected environment") is not connected.")
            return
        }
        let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
        if PaletteAddProjectPaths.isWindowsAbsolute(trimmed), threads.composer.config(env)?.platformOS != "win32" {
            toast("Failed to add project", "Windows-style paths are only supported on Windows.")
            return
        }
        if PaletteAddProjectPaths.isExplicitRelative(trimmed), browseCwd == nil {
            toast("Failed to add project", "Relative paths require an active project.")
            return
        }
        let cwd = PaletteAddProjectPaths.resolveForDispatch(rawPath, cwd: browseCwd)
        guard !cwd.isEmpty else { return }
        palette?.close()
        palette?.showThreadView()
        commands.addProject(path: cwd, environmentId: env)
    }

    /// "Open in Finder": the system folder picker on this machine, then the same add.
    private func openInFinder() {
        guard !pickingFolder, let window = palette?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let query = controller?.query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let dir = PaletteAddProjectPaths.resolveForDispatch(PaletteAddProjectPaths.directoryPath(query), cwd: browseCwd)
            panel.directoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        pickingFolder = true
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pickingFolder = false
                guard response == .OK, let url = panel.url else { return }
                self?.addProject(url.path)
            }
        }
    }

    // MARK: Clone

    private func startClone(_ env: String, source: String) {
        environmentId = env
        clone = .repository(environmentId: env, source: source)
        var mode = CommandPaletteController.Mode(name: "clone-repository",
                                                 placeholder: source == "url" ? "Paste a Git clone URL" : "Enter \(Self.sourcePathHint(source))",
                                                 footerActionLabel: source == "url" ? "Continue" : "Lookup") { _ in
            ([], source == "url" ? "Enter a Git clone URL and press Enter to continue." : "Enter a repository path and press Enter to look it up.")
        }
        mode.autoHighlight = false
        mode.onSubmit = { [weak self] query, _, _ in self?.submitRepository(query); return true }
        mode.accessory = submitButton { [weak self] in
            let label = source == "url" ? "Continue" : "Lookup"
            let query = self?.controller?.query.trimmingCharacters(in: .whitespaces) ?? ""
            return (self?.busy == true ? "Working" : label, "Enter", !query.isEmpty && self?.busy != true)
        } action: { [weak self] in
            guard let query = self?.controller?.query else { return }
            self?.submitRepository(query)
        }
        controller?.push(PalettePage(addonIcon: .link, groups: [], initialQuery: "", mode: mode))
    }

    private func submitRepository(_ query: String) {
        guard case .repository(let env, let source)? = clone, !busy else { return }
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        guard environments.state(env)?.status == .connected else {
            toast("Environment unavailable", "\(environments.label(env) ?? "The selected environment") is not connected.")
            return
        }
        guard source != "url" else {
            confirmClone(env: env, source: source, input: raw, repository: nil, remoteUrl: PaletteAddProjectPaths.normalizePastedCloneUrl(raw),
                         name: PaletteAddProjectPaths.cloneDirectoryName(raw))
            return
        }
        busy = true
        controller?.refresh()
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.controller?.refresh() }
            do {
                let repo = try await self.environments.request(env, "sourceControl.lookupRepository",
                                                               .object(["provider": .string(source), "repository": .string(raw)]))
                guard case .repository(let e, _)? = self.clone, e == env else { return }
                // `getDefaultCloneUrl`: HTTPS for GitHub and Forgejo, SSH for the rest.
                let provider = repo["provider"]?.stringValue ?? source
                let url = (provider == "github" || provider == "forgejo" ? repo["url"] : repo["sshUrl"])?.stringValue ?? raw
                self.confirmClone(env: env, source: source, input: raw, repository: repo, remoteUrl: url,
                                  name: PaletteAddProjectPaths.cloneDirectoryName(repo["nameWithOwner"]?.stringValue))
            } catch {
                self.toast("Repository lookup failed", Self.message(error))
            }
        }
    }

    /// The destination step: the browser with the repository folder pinned to the path.
    private func confirmClone(env: String, source: String, input: String, repository: JSONValue?, remoteUrl: String, name: String) {
        clone = .confirm(environmentId: env, source: source, input: input, repository: repository, remoteUrl: remoteUrl)
        var mode = makeBrowseMode(cloneDestination: true)
        let browse = mode.results
        // The repository row over the folders (CommandPalette.tsx:3531-3544).
        let context = PaletteEntry(value: "clone:repository", searchTerms: [], title: repository?["nameWithOwner"]?.stringValue ?? input,
                                   description: repository?["url"]?.stringValue ?? remoteUrl, icon: .link, action: .run({}, keepOpen: true))
        var header = context
        header.isStatic = true
        if let glyph = Self.sourceGlyph(source) { header.glyph = (glyph, Themed.color(\.contrastIconMuted)) }
        mode.results = { query in
            let (groups, empty) = browse(query)
            return ([PaletteGroup(value: "repository", label: "Repository", items: [header])] + groups, empty)
        }
        mode.status = nil
        let query = PaletteAddProjectPaths.cloneDestinationPath(initialQuery(env), name)
        load(PaletteAddProjectPaths.directoryPath(query), env: env)
        controller?.pop()
        controller?.push(PalettePage(addonIcon: .link, groups: [], initialQuery: query, mode: mode))
    }

    private func submitClone(destination raw: String) {
        guard case .confirm(let env, _, _, _, let remoteUrl)? = clone, !busy else { return }
        guard environments.state(env)?.status == .connected else {
            toast("Environment unavailable", "\(environments.label(env) ?? "The selected environment") is not connected.")
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if PaletteAddProjectPaths.isWindowsAbsolute(trimmed), threads.composer.config(env)?.platformOS != "win32" {
            toast("Clone failed", "Windows-style paths are only supported on Windows.")
            return
        }
        if PaletteAddProjectPaths.isExplicitRelative(trimmed), browseCwd == nil {
            toast("Clone failed", "Relative paths require an active project.")
            return
        }
        let destination = PaletteAddProjectPaths.resolveForDispatch(trimmed, cwd: browseCwd)
        guard !destination.isEmpty else { return }
        busy = true
        controller?.refresh()
        let tracked = threads.composer.config(env)?.capabilities.contains("projectCloneTracking") == true
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            if !tracked {
                // Older servers only clone while the request waits; the project is added afterwards.
                do {
                    let result = try await self.environments.request(env, "sourceControl.cloneRepository",
                                                                     .object(["remoteUrl": .string(remoteUrl), "destinationPath": .string(destination)]))
                    self.addProject(result["cwd"]?.stringValue ?? destination)
                } catch {
                    self.controller?.refresh()
                    self.toast("Clone failed", Self.message(error))
                }
                return
            }
            // The server makes the project and clones in the background; progress shows elsewhere.
            let projectId = UUID().uuidString.lowercased()
            do {
                _ = try await self.environments.request(env, "projectClone.start", .object([
                    "projectId": .string(projectId), "title": .string(PaletteAddProjectPaths.inferTitle(destination)),
                    "createdAt": .string(T3Timestamp(Date()).raw), "remoteUrl": .string(remoteUrl), "destinationPath": .string(destination),
                ]))
            } catch {
                self.controller?.refresh()
                self.toast("Clone failed", Self.message(error))
                return
            }
            self.palette?.close()
            await self.openWhenLoaded(ProjectId(EnvironmentScope.key(env, projectId)), timeout: 3)
        }
    }

    /// `waitForProject` then a draft in it; without the project after `timeout`, the palette stays closed.
    private func openWhenLoaded(_ id: ProjectId, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let project = palette?.snapshot?.projects.first(where: { $0.id == id }) {
                palette?.showThreadView()
                threads.newThread(in: project)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        toast("Failed to open project", "It will appear in the sidebar once this client catches up.")
    }

    // MARK: New project

    /// The machines New project can use: connected, with a `newProjectsRoot`.
    var newProjectOptions: [Option] { options.filter { newProjectsRoot($0.id) != nil } }

    /// "New project" from the root: this device first.
    func startNewProjectFromRoot() {
        if let first = newProjectOptions.first { startNewProject(first.id, sourcesEnvironmentId: nil) }
    }

    private func startNewProject(_ env: String, sourcesEnvironmentId: String?) {
        environmentId = env
        clone = nil
        newProject = (env, sourcesEnvironmentId)
        publishesToGitHub = false
        loadDiscovery(env)
        var mode = CommandPaletteController.Mode(name: "new-project", placeholder: "Project name", footerActionLabel: "Create") { [weak self] query in
            (self?.newProjectGroups(query) ?? [], "")
        }
        mode.autoHighlight = false
        mode.onSubmit = { [weak self] query, highlighted, _ in
            guard highlighted == nil else { return false }
            self?.submitNewProject(query)
            return true
        }
        mode.footerLabel = { highlighted in
            highlighted == nil ? "Create" : highlighted?.value == "new-project:github" ? "Toggle" : "Select"
        }
        mode.accessory = submitButton { [weak self] in
            guard let self else { return ("Create", "Enter", false) }
            let name = self.controller?.query.trimmingCharacters(in: .whitespaces) ?? ""
            return (self.busy ? "Creating" : "Create", "Enter", !name.isEmpty && !self.busy)
        } action: { [weak self] in
            guard let query = self?.controller?.query else { return }
            self?.submitNewProject(query)
        }
        controller?.push(PalettePage(addonIcon: .folderGit2, groups: [], initialQuery: "", mode: mode))
    }

    /// `getNewProjectGitHubTarget`: GitHub ready on that machine, with its account when known.
    private func gitHubTarget(_ env: String) -> (account: String?, ready: Bool) {
        guard readiness(env)["github"]?.ready == true, case .some(.some(let result)) = discovery[env] else { return (nil, false) }
        let github = SourceControlDiscoveryItem.list(result).providers.first { $0.kind == "github" }
        return (github?.auth?["account"]?.stringValue, true)
    }

    private func newProjectGroups(_ query: String) -> [PaletteGroup] {
        guard let flow = newProject else { return [] }
        let name = query.trimmingCharacters(in: .whitespaces)
        var groups: [PaletteGroup] = []
        // The preview row (CommandPalette.tsx:3512-3529).
        if let root = newProjectsRoot(flow.environmentId) {
            let options = newProjectOptions
            let showMachines = options.count > 1 || (!options.contains { $0.id == flow.environmentId } && !options.isEmpty)
            let machineLabel = showMachines ? options.first { $0.id == flow.environmentId }?.label ?? environments.label(flow.environmentId) : nil
            let path = PaletteAddProjectPaths.newProjectPathPreview(root: root, name: name)
            var preview = PaletteEntry(value: "new-project:preview", searchTerms: [], title: name.isEmpty ? "New project" : name,
                                       description: (name.isEmpty ? "Goes in \(root)" : "Creates \(path)") + (machineLabel.map { " on \($0)" } ?? ""),
                                       icon: .folderGit2, action: .run({}, keepOpen: true))
            preview.isStatic = true
            groups.append(PaletteGroup(value: "new-project-preview", label: "", items: [preview]))
            if showMachines {
                groups.append(PaletteGroup(value: "new-project-machines", label: "Environments", items: options.map { o in
                    var entry = environmentEntry(o, value: "new-project:environment:\(o.id)") { [weak self] id in
                        self?.newProject?.environmentId = id
                        self?.environmentId = id
                        self?.loadDiscovery(id)
                        self?.controller?.refresh()
                    }
                    entry.isDisabled = busy
                    if o.id == flow.environmentId { entry.trailingIcon = .check }
                    return entry
                }))
            }
            let target = gitHubTarget(flow.environmentId)
            if target.ready {
                var github = PaletteEntry(value: "new-project:github", searchTerms: [], title: "Create private repository on GitHub",
                                          description: name.isEmpty ? target.account ?? "Your GitHub account"
                                              : Self.gitHubRepository(account: target.account, workspaceRoot: path),
                                          icon: .link, action: .run({ [weak self] in
                                              self?.publishesToGitHub.toggle()
                                              self?.controller?.refresh()
                                          }, keepOpen: true))
                github.glyph = (IconName.brandGitHub.definition, Themed.color(\.contrastIconMuted))
                github.trailingCheckbox = publishesToGitHub
                groups.append(PaletteGroup(value: "new-project-options", label: "Options", items: [github]))
            }
        }
        var existing = PaletteEntry(value: "new-project:existing", searchTerms: [], title: "Add existing project",
                                    description: "Open a folder or clone a repository", icon: .folderPlus,
                                    action: .run({ [weak self] in self?.showExistingSources(flow.environmentId) }, keepOpen: true))
        existing.trailingIcon = .chevronRight
        groups.append(PaletteGroup(value: "new-project-existing", label: "", items: [existing]))
        return groups
    }

    /// `getNewProjectGitHubRepository`: `owner/folder`, or the folder alone.
    static func gitHubRepository(account: String?, workspaceRoot: String) -> String {
        let folder = workspaceRoot.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return account.map { "\($0)/\(folder)" } ?? folder
    }

    /// "Add existing project": the sources for the chosen machine, in place of the name step.
    private func showExistingSources(_ env: String) {
        let sourcesEnv = newProject?.sourcesEnvironmentId
        newProject = nil
        controller?.pop()
        if sourcesEnv == env { return }
        if sourcesEnv != nil { controller?.pop() }
        startSources(env)
    }

    private func submitNewProject(_ query: String) {
        guard let flow = newProject, !busy else { return }
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, environments.state(flow.environmentId)?.status == .connected else { return }
        busy = true
        controller?.refresh()
        let env = flow.environmentId
        let github = publishesToGitHub ? gitHubTarget(env) : (nil, false)
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            let result: JSONValue
            do {
                result = try await self.environments.request(env, "projects.createNew", .object(["name": .string(name)]))
            } catch {
                self.controller?.refresh()
                self.toast("Could not create the project", Self.message(error))
                return
            }
            self.palette?.close()
            let root = result["workspaceRoot"]?.stringValue ?? ""
            if let commitError = result["commitError"]?.stringValue {
                self.toast("Created \(name) without a first commit", "\(commitError) The project is in \(root).", kind: .warning)
            } else {
                self.toast("Created \(name)", root, kind: .success)
            }
            if github.1 { self.publish(env: env, workspaceRoot: root, account: github.0) }
            guard let local = result["projectId"]?.stringValue else { return }
            await self.openWhenLoaded(ProjectId(EnvironmentScope.key(env, local)), timeout: 10)
        }
    }

    /// `publishToGitHub`: a private repository named after the folder.
    private func publish(env: String, workspaceRoot: String, account: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.environments.request(env, "sourceControl.publishRepository", .object([
                    "cwd": .string(workspaceRoot), "provider": .string("github"),
                    "repository": .string(Self.gitHubRepository(account: account, workspaceRoot: workspaceRoot)), "visibility": .string("private"),
                ]))
                self.toast("Published to GitHub", result["repository"]?["nameWithOwner"]?.stringValue, kind: .success)
            } catch {
                self.toast("Could not create the GitHub repository", "\(Self.message(error)) Use Publish Repository in the Git menu to try again.")
            }
        }
    }

    // MARK: Shared

    /// The input's submit button: an outline `xs` button with its `Enter` key (`inputAccessory`).
    private func submitButton(_ state: @escaping @MainActor () -> (title: String, key: String, enabled: Bool),
                              action: @escaping @MainActor () -> Void) -> NSView {
        let button = PaletteSubmitAccessory(state: state)
        button.button.action = action
        return button
    }

    private func toast(_ title: String, _ message: String?, kind: ToastQueue.Kind = .error) {
        threads.panel.toasts.show(ToastView(title: title, message: message, kind: kind))
    }

    static func message(_ error: Error) -> String {
        (error as? RPCClientError)?.typedError?.message ?? (error as? LocalizedError)?.errorDescription ?? "An error occurred."
    }
}

/// The palette input's submit control: `Button variant="outline" size="xs"` holding its label and a
/// `Kbd`, refreshed from the flow's state before each draw.
@MainActor
final class PaletteSubmitAccessory: DSView {
    let button = ButtonView("Add", variant: .outline, size: .xs)
    private let keys = KbdGroupView(keys: ["Enter"])
    private let state: @MainActor () -> (title: String, key: String, enabled: Bool)
    private var shownKey = "Enter"

    init(state: @escaping @MainActor () -> (title: String, key: String, enabled: Bool)) {
        self.state = state
        super.init(frame: .zero)
        button.accessory = keys
        addSubview(button)
        sync()
    }

    /// Reads the flow's state; the palette calls `refresh` on every query change, which lays this out.
    func sync() {
        let s = state()
        if button.title != s.title { button.title = s.title }
        button.isEnabled = s.enabled
        if s.key != shownKey {
            shownKey = s.key
            let next = KbdGroupView(keys: [s.key])
            button.accessory = next
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { button.intrinsicContentSize }

    override func layout() {
        sync()
        super.layout()
        button.frame = bounds
    }
}
