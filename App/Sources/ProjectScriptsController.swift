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
    var openProjectSettings: ((String) -> Void)?

    init(panel: ThreadPanelView, sidebar: SidebarContentView, composer: ComposerController, terminal: TerminalController) {
        self.panel = panel
        self.sidebar = sidebar
        self.composer = composer
        self.terminal = terminal
        let card = panel.detailsCard
        card.scripts.primary.action = { [weak self] in
            guard let self, let primary = ProjectScripts.primary(self.scripts) else { self?.openMenu(); return }
            self.terminal.runScript(primary)
        }
        card.scripts.secondary.action = { [weak self] in self?.openMenu() }
        card.addScript.action = { [weak self] in self?.openSettings() }
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
            panel.detailsCard.scriptsRow = nil
            return
        }
        let settings = ServerSettingsValues(composer?.config(env)?.settings.raw ?? .null)
        scripts = ProjectScripts.resolve(settings, projectId: project.id.localId.rawValue, projectScripts: ProjectScript.list(.array(project.scripts)))
        panel.detailsCard.scriptsRow = ProjectScripts.primary(scripts).map { .run(name: $0.name, icon: ProjectScriptIcon.name($0.icon)) }
            ?? (scripts.isEmpty ? .add : .actions)
    }

    private func project(_ threadId: ThreadId) -> ProjectShell? {
        guard let snapshot = sidebar?.snapshot, let thread = snapshot.threads.first(where: { $0.id == threadId }) else { return nil }
        return snapshot.projects.first { $0.id == thread.projectId }
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
    // ponytail: the gear on each row and "Add project script" open Settings, Project, where T3 opens the
    // action editor in place, and t3.json imports are not listed; port ProjectScriptEditorDialog here if that matters
    private func openMenu() {
        let split = panel.detailsCard.scripts
        let context = KeybindingContext([:])
        var items = scripts.map { script -> MenuItem in
            var item = MenuItem(ProjectScripts.menuLabel(script), icon: ProjectScriptIcon.name(script.icon),
                                shortcut: ProjectScripts.command(script.id).flatMap { ActiveKeymap.label(for: $0, context: context) })
            item.action = { [weak self] in self?.terminal.runScript(script) }
            return item
        }
        var add = MenuItem("Add project script", icon: .plus)
        add.action = { [weak self] in self?.openSettings() }
        items.append(add)
        MenuPopupView.show(items, from: split.secondary, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none),
                           minimumWidth: split.bounds.width, anchorRect: split.convert(split.bounds, to: split.secondary))
    }

    private func openSettings() {
        guard let threadId, let project = project(threadId), let projects = sidebar?.snapshot?.projects,
              let group = SidebarModel.buildProjectGroups(projects).first(where: { $0.memberProjectIds.contains(project.id) }) else { return }
        openProjectSettings?(group.key)
    }
}
