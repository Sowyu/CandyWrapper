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

    /// `AddTrackedFolderDialog`: a path field that starts at the project folder's parent.
    // ponytail: takes a typed absolute path; T3 also lists the folder's subfolders to click through, add the browse list if users miss it
    private func openAdd(_ m: SettingsScopeProject.Member) {
        let dialog = DialogView(title: "Add folder", message: "Track a repository or folder anywhere on this project's machine.")
        let label = LabelView()
        label.text = "Folder path"
        label.font = DSFont.ui(14, weight: .medium)
        label.frame.size.height = 16
        let input = InputView(placeholder: "/path/to/repository", text: ((m.workspaceRoot as NSString).deletingLastPathComponent as String) + "/", size: .default, font: .mono)
        input.setAccessibilityLabel("Folder path")
        input.frame.size.height = 36
        dialog.panelContent = [label, input]
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Add folder")
        dialog.footerButtons = [cancel, ok]
        dialog.initialFocus = input
        guard let host = context.presentDialog?(dialog) else { return }
        dialog.onClose = { [weak host] in host?.close() }
        cancel.action = { [weak host] in host?.close() }
        let submit: @MainActor @Sendable () -> Void = { [weak self, weak host, weak input] in
            guard let self, let text = input?.text, let folder = Self.resolve(text), !self.saving.contains(m.physicalKey) else { return }
            self.save(m, track: folder, failure: "Failed to add folder") { host?.close() }
        }
        ok.isEnabled = Self.resolve(input.text) != nil
        input.onChange = { [weak ok] text in ok?.isEnabled = Self.resolve(text) != nil }
        input.onSubmit = submit
        ok.action = submit
    }
}
