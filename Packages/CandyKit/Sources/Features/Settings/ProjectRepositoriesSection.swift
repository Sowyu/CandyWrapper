import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Projects > Repositories (5258 settings/ProjectRepositoriesSettings.tsx, #35925): per checkout, the folders the
/// project tracks, read from disk with `workspace.listFolders`, plus the folders a `.code-workspace` file names
/// (`workspace.scanFolders`). Add and Remove send `project.update` with `trackFolders` or `untrackFolders`, so the
/// server merges them into its own list.
@MainActor
final class ProjectRepositoriesSection {
    /// `PROJECT_TRACKED_FOLDERS_MAX` (contracts project.ts:50).
    static let maxFolders = 128

    private struct Listing {
        var folders: [WorkspaceFolder]?
        var scanned: [WorkspaceScannedFolder] = []
        var error: String?
        var pending = true
    }

    let section = SettingsSectionView(title: "Repositories", rows: [])
    private let context: SettingsPageContext
    private var listings: [String: Listing] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var saving: Set<String> = []
    var onChange: (() -> Void)?

    init(context: SettingsPageContext) { self.context = context }

    /// `FOLDER_STATE_LABELS`.
    static func stateLabel(_ state: String) -> String {
        switch state { case "git": "Git repository"; case "missing": "Missing"; default: "Folder" }
    }

    /// `trackedFolderDisplayPath`: relative to the project folder when inside it, absolute otherwise.
    static func displayPath(_ path: String, workspaceRoot: String) -> String {
        let root = workspaceRoot.hasSuffix("/") ? String(workspaceRoot.dropLast()) : workspaceRoot
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// `suggestedTrackedFolders` (client-runtime state/projectTrackedFolders.ts:12-23): a `.code-workspace` file's
    /// folders the project does not track yet, each once.
    static func suggested(_ paths: [String], scanned: [WorkspaceScannedFolder]) -> [WorkspaceScannedFolder] {
        var seen = Set(paths)
        return scanned.filter { $0.source == "code-workspace" && seen.insert($0.path).inserted }
    }

    /// `resolveTrackedFolderInput` without a listing: only an absolute path is safe to send. The name is its last
    /// component, at most 128 characters.
    static func resolve(_ query: String) -> (path: String, name: String)? {
        var path = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = String((path as NSString).lastPathComponent.prefix(128)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "/" else { return nil }
        return (path, name)
    }

    func cancel() { tasks.values.forEach { $0.cancel() }; tasks = [:]; listings = [:] }

    /// Rebuilds the rows for `members`; returns false when no checkout has a folder to show (scratch projects).
    func update(_ members: [SettingsScopeProject.Member], isScratch: Bool) -> Bool {
        guard !isScratch, !members.isEmpty else { section.group.rows = []; return false }
        var rows: [any SettingsGroupRow] = []
        for m in members {
            let env = context.scope.environments.first { $0.id == m.environmentId }
            let connected = env?.connected == true
            if connected, listings[m.physicalKey] == nil { load(m) }
            let listing = listings[m.physicalKey] ?? Listing(folders: nil, pending: false)
            // Until the disk listing lands, the project's own list (no state badges).
            let folders: [(name: String, path: String, state: String, discovered: Bool?)] = listing.folders?.map { ($0.name, $0.path, $0.state, $0.discovered) }
                ?? m.trackedFolders.map { ($0.name, $0.path, "", $0.discovered) }
            let disabled = env?.canWrite != true || !connected || saving.contains(m.physicalKey) || listing.pending
            let add = ButtonView("Add folder", icon: .plus, variant: .outline, size: .xs)
            add.isEnabled = !disabled && folders.count < Self.maxFolders
            add.action = { [weak self] in self?.openAdd(m) }
            rows.append(SettingsRowView(title: m.environmentLabel ?? "Environment", detail: m.workspaceRoot, control: add))
            if folders.isEmpty {
                rows.append(SettingsGroupNote("Repositories inside this folder are part of the project as soon as they are there. Add a folder to bring in one from somewhere else."))
            }
            for f in folders {
                var remove: ButtonView?
                // A repository inside the project folder is there for as long as it is on disk.
                if f.discovered != true {
                    let b = ButtonView("Remove", variant: .ghost, size: .xs)
                    b.setAccessibilityLabel("Remove \(f.name) from the project")
                    b.isEnabled = !disabled
                    b.action = { [weak self] in self?.save(m, untrack: f.path, failure: "Failed to remove folder") }
                    remove = b
                }
                let row = SettingsRowView(title: f.name, detail: Self.displayPath(f.path, workspaceRoot: m.workspaceRoot), control: remove)
                if !f.state.isEmpty {
                    row.accessories = [BadgeView(Self.stateLabel(f.state), variant: f.state == "missing" ? .warning : .outline, size: .sm)]
                }
                rows.append(row)
            }
            for s in Self.suggested(folders.map(\.path), scanned: listing.scanned) {
                let b = ButtonView("Add", variant: .ghost, size: .xs)
                b.setAccessibilityLabel("Add \(s.name) to the project")
                b.isEnabled = !disabled
                b.action = { [weak self] in self?.save(m, track: (s.path, s.name), failure: "Failed to add folder") }
                let row = SettingsRowView(title: s.name, detail: Self.displayPath(s.path, workspaceRoot: m.workspaceRoot), control: b)
                row.accessories = [BadgeView("In workspace file", variant: .outline, size: .sm)]
                rows.append(row)
            }
            if let error = listing.error { rows.append(SettingsGroupNote(error, color: Themed.color(\.warningForeground), size: 12)) }
        }
        section.group.rows = rows
        return true
    }

    private func load(_ m: SettingsScopeProject.Member) {
        guard let request = context.request else { return }
        let key = m.physicalKey
        listings[key] = Listing(folders: listings[key]?.folders, scanned: listings[key]?.scanned ?? [], pending: true)
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            var listing = Listing(pending: false)
            do {
                let list = try await request(m.environmentId, WorkspaceRPC.listFolders, WorkspaceRPC.project(ProjectId(m.projectId)))
                listing.folders = try list.decode(as: WorkspaceListFoldersResult.self).folders
            } catch { listing.error = String(describing: error) }
            // The scan only offers a workspace file's folders; a failure there just offers none.
            if let scan = try? await request(m.environmentId, WorkspaceRPC.scanFolders, WorkspaceRPC.scanInput(workspaceRoot: m.workspaceRoot)),
               let result = try? scan.decode(as: WorkspaceScanFoldersResult.self) { listing.scanned = result.folders }
            guard !Task.isCancelled, let self else { return }
            self.listings[key] = listing
            self.onChange?()
        }
    }

    /// One folder in or out (`save`); the list is read again after.
    private func save(_ m: SettingsScopeProject.Member, track: (path: String, name: String)? = nil, untrack: String? = nil,
                      failure: String, done: (@MainActor () -> Void)? = nil) {
        guard let request = context.request else { return }
        let key = m.physicalKey
        saving.insert(key)
        onChange?()
        var o = WorkspaceRPC.trackFoldersFields(track: track.map { [$0] } ?? [], untrack: untrack.map { [$0] } ?? [])
        o["type"] = .string("project.update")
        o["commandId"] = .string(ThreadCommands.newCommandId())
        o["projectId"] = .string(m.projectId)
        Task { [weak self] in
            var failed = false
            do { _ = try await request(m.environmentId, "projects.mutate", .object(o)) } catch {
                failed = true
                self?.context.toast?(failure, String(describing: error), .error)
            }
            guard let self else { return }
            self.saving.remove(key)
            if !failed { done?(); self.load(m) }
            self.onChange?()
        }
    }

    /// `AddTrackedFolderDialog` (5258 ProjectRepositoriesSettings.tsx:252-381): the path field in the header, starting at
    /// the project folder's parent, and under it the folders `filesystem.browse` lists for the typed directory.
    private func openAdd(_ m: SettingsScopeProject.Member) {
        let dialog = DialogView(title: "Add folder", message: "Track a repository or folder anywhere on this project's machine.")
        let field = FolderPathFieldView(query: TrackedFolderBrowse.initialQuery(workspaceRoot: m.workspaceRoot))
        dialog.headerContent = field
        let browser = TrackedFolderBrowserView()
        dialog.panelContent = [browser]
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Add folder")
        dialog.footerButtons = [cancel, ok]
        dialog.initialFocus = field.input
        guard let host = context.presentDialog?(dialog) else { return }
        dialog.onClose = { [weak host] in host?.close() }
        cancel.action = { [weak host] in host?.close() }
        let browse = FolderBrowseState(request: context.request, environmentId: m.environmentId, cwd: m.workspaceRoot)
        var folder: (path: String, name: String)?
        var picks: [String] = []
        let refresh: @MainActor () -> Void = { [weak self, weak field, weak browser, weak ok, weak dialog] in
            guard let self, let field, let browser else { return }
            let view = browse.view(for: field.input.text)
            folder = view.folder
            picks = view.picks
            browser.set(titles: view.titles, status: view.status)
            ok?.isEnabled = folder != nil && !self.saving.contains(m.physicalKey)
            browser.invalidateIntrinsicContentSize()
            dialog?.needsLayout = true
            dialog?.superview?.needsLayout = true
        }
        browse.onChange = refresh
        browser.onPick = { [weak field] index in
            guard let field, picks.indices.contains(index) else { return }
            field.input.text = picks[index]
            field.input.moveCaretToEnd()
        }
        field.input.onChange = { _ in refresh() }
        let submit: @MainActor @Sendable () -> Void = { [weak self, weak host] in
            guard let self, let folder, !self.saving.contains(m.physicalKey) else { return }
            self.save(m, track: folder, failure: "Failed to add folder") { host?.close() }
        }
        field.input.onSubmit = submit
        ok.action = submit
        refresh()
    }
}

/// `Label` and the mono path `Input` in the dialog header (`flex flex-col gap-2 pt-1`).
final class FolderPathFieldView: DSView {
    private let label = LabelView("Folder path", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    let input: InputView

    init(query: String) {
        input = InputView(placeholder: "/path/to/repository", text: query, size: .default, font: .mono)
        super.init(frame: .zero)
        label.lineHeight = 18
        input.setAccessibilityLabel("Folder path")
        addSubview(label)
        addSubview(input)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4 + 18 + 8 + 32) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 18)
        input.frame = NSRect(x: 0, y: 30, width: bounds.width, height: 32)
    }
}

/// The browse listings of one Add folder dialog, by directory, each read once (`filesystem.browse` with the
/// project folder as `cwd`).
@MainActor
final class FolderBrowseState {
    enum Listing { case loading, loaded(parent: String, entries: [PaletteAddProjectPaths.Entry]), failed(String) }

    struct View {
        var titles: [String] = []
        /// The query each row puts in the field.
        var picks: [String] = []
        var status: TrackedFolderBrowserView.Status = .none
        var folder: (path: String, name: String)?
    }

    private let request: ((String, String, JSONValue) async throws -> JSONValue)?
    private let environmentId: String
    private let cwd: String
    private var listings: [String: Listing] = [:]
    var onChange: (@MainActor () -> Void)?

    init(request: ((String, String, JSONValue) async throws -> JSONValue)?, environmentId: String, cwd: String) {
        self.request = request; self.environmentId = environmentId; self.cwd = cwd
    }

    /// Seeds a listing, for tests.
    func set(_ directory: String, _ listing: Listing) { listings[directory] = listing }

    func view(for query: String) -> View {
        let path = TrackedFolderBrowse.path(query, canBrowse: request != nil)
        var out = View()
        if let parent = path.parentPath { out.titles.append(".."); out.picks.append(parent) }
        var listed: String?
        var exact: String?
        if path.isBrowsing, !path.directoryPath.isEmpty {
            switch listing(path.directoryPath) {
            case .loading: out.status = .loading
            case .failed(let message): out.status = .error(message)
            case .loaded(let parent, let entries):
                listed = parent
                let filtered = PaletteAddProjectPaths.filter(entries, query: path.filterQuery)
                exact = filtered.exact?.fullPath
                for e in filtered.visible.prefix(TrackedFolderBrowse.limit) {
                    out.titles.append(e.name)
                    out.picks.append(PaletteAddProjectPaths.appendSegment(path.directoryPath, e.name))
                }
                let hidden = filtered.visible.count - TrackedFolderBrowse.limit
                if hidden > 0 { out.status = .more(hidden) }
            }
        } else if request == nil {
            out.status = .cannotBrowse
        }
        out.folder = TrackedFolderBrowse.resolve(query: query, listedDirectory: listed, exactEntry: exact)
        return out
    }

    private func listing(_ directory: String) -> Listing {
        if let listing = listings[directory] { return listing }
        listings[directory] = .loading
        let payload: JSONValue = .object(["partialPath": .string(directory), "cwd": .string(cwd)])
        let env = environmentId
        Task { [weak self, request] in
            let next: Listing
            do {
                guard let request else { return }
                let result = try await request(env, "filesystem.browse", payload)
                let entries = (result["entries"]?.arrayValue ?? []).compactMap { e -> PaletteAddProjectPaths.Entry? in
                    guard let name = e["name"]?.stringValue, let full = e["fullPath"]?.stringValue else { return nil }
                    return .init(name: name, fullPath: full)
                }
                next = .loaded(parent: result["parentPath"]?.stringValue ?? directory, entries: entries)
            } catch {
                next = .failed(String(describing: error))
            }
            guard let self else { return }
            self.listings[directory] = next
            self.onChange?()
        }
        return .loading
    }
}
