import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The open thread's project actions (ProjectScriptsControl.tsx with `displayMode="panel"`, ChatView.tsx
/// `runProjectScript` and the `script.<id>.run` keybindings, ChatView.tsx:8253-8259): the details card's
/// scripts row runs the primary action, its chevron lists every action, and each action's shortcut
/// runs it in the thread's terminal.
@MainActor
final class ProjectScriptsController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private weak var composer: ComposerController?
    private let terminal: TerminalController
    private var threadId: ThreadId?
    private var scripts: [ProjectScript] = []
    /// Settings, Project: where actions are added and edited.
    var saveActions: (([ProjectActionsLogic.Write]) async -> String?)?
    private var editor: ProjectActionEditor?
    var openProjectSettings: ((String) -> Void)?
    /// `useT3ProjectFileScripts`: the scripts of the workspace's `t3.json`, keyed by environment and cwd.
    private var fileScripts: (key: String, scripts: [T3ProjectFile.Script])?
    private var fileTask: Task<Void, Never>?
    /// `projects.readFile` on an environment; nil when unreadable.
    var readFile: ((_ environmentId: String, _ cwd: String, _ path: String) async -> (contents: String, truncated: Bool)?)?
    /// The script's checked-in t3.json counterparts not yet imported (`importableScripts`).
    private var importable: [T3ProjectFile.Script] {
        T3ProjectFile.importable(fileScripts?.scripts ?? [], existing: scripts)
    }

    init(panel: ThreadPanelView, sidebar: SidebarContentView, composer: ComposerController, terminal: TerminalController) {
        self.panel = panel
        self.sidebar = sidebar
        self.composer = composer
        self.terminal = terminal
        panel.lazyDetailsCard.configure { [weak self] card in
            card.scripts.primary.action = { [weak self] in
                guard let self, let primary = ProjectScripts.primary(self.scripts) else { self?.openMenu(); return }
                self.terminal.runScript(primary)
            }
            card.scripts.secondary.action = { [weak self] in self?.openMenu() }
            card.addScript.action = { [weak self] in self?.openEditor(nil) }
        }
        composer.configObservers.append { [weak self] _ in self?.refresh() }
    }

    func show(_ id: ThreadId?) {
        threadId = id
        refresh()
    }

    /// The project's actions after a shell or config change.
    func refresh() {
        guard let threadId, let env = threadId.environmentId, let project = project(threadId) else {
            scripts = []
            panel.lazyDetailsCard.set(\.scriptsRow, nil)
            return
        }
        let settings = ServerSettingsValues(composer?.config(env)?.settings.raw ?? .null)
        scripts = ProjectScripts.resolve(settings, projectId: project.id.localId.rawValue, projectScripts: ProjectScript.list(.array(project.scripts)))
        loadProjectFile(env, cwd: thread(threadId)?.worktreePath ?? project.workspaceRoot)
        // ProjectScriptsControl.tsx:269-300, 372-375: "Actions" while only a settle action or t3.json imports exist.
        panel.lazyDetailsCard.set(\.scriptsRow, ProjectScripts.primary(scripts).map { .run(name: $0.name, icon: ProjectScriptIcon.name($0.icon)) }
            ?? (scripts.isEmpty && importable.isEmpty ? .add : .actions))
    }

    /// `useT3ProjectFileState` (hooks/useT3ProjectFileScripts.ts:31-53): `t3.json` at the workspace root; a missing,
    /// truncated or invalid file offers nothing.
    // ponytail: read once per workspace while it is open; T3's file query refreshes on its cache policy. Re-read on focus if edits to t3.json go unseen
    private func loadProjectFile(_ env: String, cwd: String) {
        let key = env + "\u{0}" + cwd
        guard fileScripts?.key != key else { return }
        // A workspace read in the last 5 minutes isn't read again on a thread switch: T3's file query
        // atom stays cached that long after its last reader goes (client-runtime state/runtime.ts:543).
        let now = ContinuousClock.now
        recentFiles = recentFiles.filter { now - $0.value.at < Self.fileReuse }
        if let hit = recentFiles[key] {
            fileScripts = (key, hit.scripts)
            return
        }
        fileScripts = (key, [])
        fileTask?.cancel()
        fileTask = Task { [weak self] in
            guard let read = self?.readFile else { return }
            let reply = await read(env, cwd, T3ProjectFile.fileName)
            guard !Task.isCancelled, let self, self.fileScripts?.key == key else { return }
            let scripts = reply.flatMap { $0.truncated ? nil : T3ProjectFile.parse($0.contents) }?.scripts ?? []
            self.recentFiles[key] = (ContinuousClock.now, scripts)
            guard !scripts.isEmpty else { return }
            self.fileScripts = (key, scripts)
            self.refresh()
        }
    }
    private var recentFiles: [String: (at: ContinuousClock.Instant, scripts: [T3ProjectFile.Script])] = [:]
    private static let fileReuse: Duration = .seconds(5 * 60)

    private func project(_ threadId: ThreadId) -> ProjectShell? {
        guard let snapshot = sidebar?.snapshot, let thread = thread(threadId) else { return nil }
        return snapshot.projects.first { $0.id == thread.projectId }
    }

    private func thread(_ threadId: ThreadId) -> ThreadShell? {
        sidebar?.snapshot?.threads.first { $0.id == threadId }
    }

    func registerShortcuts(_ shortcuts: Shortcuts) {
        // `script.<id>.run`: the open thread's action with that id.
        shortcuts.on(prefix: "script.") { [weak self] call in
            guard let self, self.threadId != nil, let id = ProjectScripts.scriptId(fromCommand: call.command),
                  let script = self.scripts.first(where: { $0.id == id }) else { return false }
            if !call.isRepeat { self.terminal.runScript(script) }
            return true
        }
    }

    /// The chevron's menu: every action with its roles and shortcut, then "Add project script".
    private func openMenu() {
        let split = panel.detailsCard.scripts
        let context = KeybindingContext([:])
        var items = scripts.map { script -> MenuItem in
            var item = MenuItem(ProjectScripts.menuLabel(script), icon: ProjectScriptIcon.name(script.icon),
                                shortcut: ProjectScripts.command(script.id).flatMap { ActiveKeymap.label(for: $0, context: context) })
            item.action = { [weak self] in self?.terminal.runScript(script) }
            item.accessoryWidth = 24
            item.accessory = { [weak self] in
                let button = ButtonView(nil, icon: .settings, variant: .ghost, size: .iconXs)
                button.action = { [weak self] in self?.openEditor(script) }
                button.toolTip = "Edit action"
                return button
            }
            return item
        }
        // "From t3.json" (ProjectScriptsControl.tsx:169-188): each importable script with the download glyph.
        let imports = importable
        if !imports.isEmpty {
            if !scripts.isEmpty { items.append(.separator) }
            items.append(.label("From t3.json"))
            for fileScript in imports {
                var item = MenuItem(fileScript.name, icon: ProjectScriptIcon.name(fileScript.icon ?? "play"))
                item.badge = IconName.download.definition
                item.badgeTooltip = "Import"
                item.action = { [weak self] in self?.importFileScript(fileScript) }
                items.append(item)
            }
        }
        var add = MenuItem("Add project script", icon: .plus)
        add.action = { [weak self] in self?.openEditor(nil) }
        items.append(add)
        MenuPopupView.show(items, from: split.secondary, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none),
                           minimumWidth: split.bounds.width, anchorRect: split.convert(split.bounds, to: split.secondary))
    }

    /// `importFileScript`: adds the script as a new action; a failure reopens the add form prefilled with the error.
    private func importFileScript(_ fileScript: T3ProjectFile.Script) {
        guard let saveActions, let target = actionsTarget() else { return }
        // A new action has no shortcut to clear, so T3's `keybinding: null` (write scope only) changes nothing here.
        let input = T3ProjectFile.importInput(fileScript, canWriteSettings: false)
        let id = ProjectActionsLogic.newId(input.name, targets: [target])
        let writes = ProjectActionsLogic.plan([target], transform: { ProjectScripts.applySubmit($0, id: id, isNew: true, input: input) },
                                              scriptId: id, keybinding: input.keybinding)
        Task { [weak self] in
            if let error = await saveActions(writes) {
                self?.openEditor(nil, prefill: input, error: error)
            } else {
                self?.refresh()
            }
        }
    }

    private func actionsTarget() -> ProjectActionsLogic.Target? {
        guard let threadId, let project = project(threadId), let env = threadId.environmentId, let config = composer?.config(env) else { return nil }
        return ProjectActionsLogic.Target(environmentId: env, settings: ServerSettingsValues(config.settings.raw),
            keybindings: config.keybindings, projectId: project.id.localId.rawValue, projectScripts: ProjectScript.list(.array(project.scripts)),
            otherProjects: (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env && $0.id != project.id }
                .map { ($0.id.localId.rawValue, ProjectScript.list(.array($0.scripts))) })
    }

    private func openEditor(_ script: ProjectScript?, prefill: ProjectScriptInput? = nil, error: String? = nil) {
        guard let threadId, project(threadId) != nil, let env = threadId.environmentId,
              let config = composer?.config(env), let window = panel.window, let target = actionsTarget() else { return }
        let editor = ProjectActionEditor(script: script, keybinding: script.flatMap {
            ProjectActionsLogic.keybindingValue(config.keybindings, command: ProjectScripts.command($0.id))
        }, prefill: prefill)
        editor.error = error
        self.editor = editor
        let host = ModalHost.present(editor.dialog, in: window)
        editor.dialog.onClose = { [weak host] in host?.close() }
        host.onDismiss = { [weak self] in self?.editor = nil }
        editor.onCancel = { [weak host] in host?.close() }
        editor.onSubmit = { [weak self, weak editor, weak host] input in
            guard let self, let editor, let saveActions = self.saveActions else { return }
            let id = script?.id ?? ProjectActionsLogic.newId(input.name, targets: [target])
            let writes = ProjectActionsLogic.plan([target], transform: { ProjectScripts.applySubmit($0, id: id, isNew: script == nil, input: input) },
                scriptId: id, keybinding: input.keybinding)
            editor.isSaving = true
            Task { [weak self, weak editor, weak host] in
                let error = await saveActions(writes)
                editor?.isSaving = false
                if let error { editor?.error = error } else { host?.close(); self?.refresh() }
            }
        }
        editor.onDelete = { [weak self, weak editor, weak host] in
            guard let self, let script, let saveActions = self.saveActions, let window = self.panel.window else { return }
            let confirm = DialogView(kind: .alertDialog, title: "Delete action \"\(script.name)\"?", message: "This action cannot be undone.")
            let cancel = ButtonView("Cancel", variant: .outline)
            let delete = ButtonView("Delete", variant: .destructive)
            confirm.footerButtons = [cancel, delete]
            let confirmation = ModalHost.present(confirm, in: window)
            cancel.action = { [weak confirmation] in confirmation?.close() }
            delete.action = { [weak self, weak editor, weak host, weak confirmation] in
                confirmation?.close()
                let writes = ProjectActionsLogic.plan([target], transform: { $0.filter { $0.id != script.id } }, scriptId: script.id, keybinding: "")
                editor?.isSaving = true
                Task { [weak self, weak editor, weak host] in
                    let error = await saveActions(writes)
                    editor?.isSaving = false
                    if let error { editor?.error = error } else { host?.close(); self?.refresh() }
                }
            }
        }
    }
}
