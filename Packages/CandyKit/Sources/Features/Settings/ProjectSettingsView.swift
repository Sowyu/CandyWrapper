import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Settings > Project (ProjectsSettings.tsx, ProjectSettingsPanel.tsx, ProjectDefaultsSettings.tsx with
/// `category="project"`, ProjectActionsSettings.tsx): the selected project's name, icon, new-thread
/// defaults, actions, checkouts and removal. Only listed while a project is picked in the scope sentence.
public final class ProjectSettingsView: ScopedSettingsPage {
    private let notice = SettingsNoticeView("")
    private var scopeNotice: SettingsScopeNoticeView?
    private let info = AlertView(nil, message: "Can't find a setting? Keep this project picked above and hop to any other settings page.",
                                 icon: .info, variant: .info)
    private var overview: SettingsGroupView!
    private let permissionNote = SettingsGroupNote("")
    private let nameInput = InputView(placeholder: "", text: "", size: .sm)
    private var nameEdited = false
    private var iconRow: SettingsRowView!
    private let favicon = ProjectMonogramView()
    private var defaults: SettingsSectionView!
    private var actions: SettingsSectionView!
    private var checkouts: SettingsSectionView!
    private var danger: SettingsSectionView!
    private let dangerButton = ButtonView("Remove project", icon: .trash2, variant: .destructiveOutline, size: .sm)
    private let addAction = ButtonView("Add action", icon: .plus, variant: .outline, size: .xs)
    private var savingActions = false
    /// The open Add/Edit Action dialog.
    private var openEditor: ProjectActionEditor?
    /// The project the page shows, so a new selection rebuilds the name field.
    private var shownKey: String?
    private let importAction = ButtonView("Import scripts", icon: .chevronDown, variant: .ghost, size: .xs).menuTrigger()
    private var projectFileContents: String?
    private var projectFileKey: String?
    private var projectFileTask: Task<Void, Never>?

    public init(context: SettingsPageContext) {
        super.init(context: context)
        usesBoundary = false
        gap = 24
        // `ProjectSettingsPanel`'s states: no project, a missing one, a missing checkout.
        notice.isHidden = true
        overview = buildOverview()
        defaults = buildDefaults()
        actions = buildActions()
        checkouts = SettingsSectionView(title: "Checkouts", rows: [])
        danger = buildDanger()
        body = [notice, info, overview, defaults, actions, checkouts, danger]
        binder.add { [weak self] in self?.update() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            projectFileTask?.cancel(); projectFileTask = nil; projectFileContents = nil; projectFileKey = nil
        } else { loadProjectFile() }
    }

    private var group: SettingsScopeProject? { context.scope.group }
    private var members: [SettingsScopeProject.Member] { context.scope.members }

    /// Members whose environment lets this connection operate (`useEnvironmentsWithScope`, approximated by
    /// a connected environment that lets it write settings).
    private var canEditGroup: Bool {
        let envs = Dictionary(context.scope.environments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return !members.isEmpty && members.allSatisfy { envs[$0.environmentId]?.connected == true && envs[$0.environmentId]?.canWrite == true }
    }

    private func update() {
        let scope = context.scope
        var message: String?
        var choices: [(String, @MainActor () -> Void)]?
        switch scope.kind {
        case .project: break
        case .unavailable(let m): message = scope.selection.project == nil ? m : (scope.projects.isEmpty ? "Add a project from the sidebar to configure it here." : m)
        default:
            // `SettingsScopeNotice target="project"`.
            choices = scope.projects.map { p in (p.displayName, { [weak self] in
                self?.context.selectScope?(SettingsScopeSelection(machine: nil, project: p.key)) }) }
        }
        if let choices {
            let n = SettingsScopeNoticeView("Choose a project to manage its name, icon, checkouts and actions.", choices: choices)
            scopeNotice = n
            body = [n]
            return
        }
        if scopeNotice != nil {
            scopeNotice = nil
            body = [notice, info, overview, defaults, actions, checkouts, danger]
        }
        notice.message = message ?? ""
        setHidden(notice, message == nil)
        for item in [info, overview, defaults, actions, checkouts, danger] as [NSView & SettingsGroupRow] { setHidden(item, message != nil) }
        guard message == nil, let group else { return }
        let members = self.members
        let hasOtherMembers = members.count < group.members.count
        let representative = members.first { m in scope.connected.contains { $0.id == m.environmentId } } ?? members[0]

        loadProjectFile()

        // Overview.
        permissionNote.message = members.count > 1 ? "Shared settings require permission to change every checkout in this group."
            : "This connection cannot change this project."
        permissionNote.isHidden = canEditGroup
        if shownKey != group.key || !nameInput.state.focused {
            nameInput.text = group.displayName
            nameEdited = false
        }
        shownKey = group.key
        nameInput.isEnabled = canEditGroup
        chooseIconButton?.isEnabled = canEditGroup
        chooseFileButton?.isEnabled = canEditGroup
        favicon.source = ProjectIconSource(title: representative.title, workspaceRoot: representative.workspaceRoot,
                                           faviconPath: representative.faviconPath, override: ProjectIconSource.override(representative.projectIcon))
        favicon.source?.environmentId = representative.environmentId
        iconRow.detail = Self.iconDescription(representative)
        if let slot = iconRow.accessories.last as? ResetSlot {
            slot.isShown = members.contains { $0.faviconPath != nil || ($0.projectIcon ?? .null) != .null } && canEditGroup
        }
        overview.rows = overview.rows

        // Checkouts.
        checkouts.group.rows = members.map { m in
            let remove = ButtonView("Remove", variant: .outline, size: .sm)
            remove.setAccessibilityLabel("Remove checkout \(m.workspaceRoot)")
            remove.isEnabled = scope.environments.first { $0.id == m.environmentId }?.connected == true
            remove.action = { [weak self] in self?.confirmRemove([m]) }
            return SettingsRowView(title: m.environmentLabel ?? "Environment", detail: m.workspaceRoot, control: remove)
        }
        setHidden(checkouts, members.count < 2)

        // Danger.
        let row = danger.group.rows.first as? SettingsRowView
        row?.title = hasOtherMembers ? "Remove checkout" : members.count > 1 ? "Remove this project everywhere" : "Remove project"
        row?.detail = hasOtherMembers
            ? "Deletes the selected machine's checkout entries and their threads. Other machines and files on disk are not touched."
            : members.count > 1
                ? "Deletes all \(members.count) checkout entries and their threads on every machine. Files on disk are not touched."
                : "Deletes the project entry and its threads. Files on disk are not touched."
        dangerButton.title = hasOtherMembers ? "Remove checkout" : members.count > 1 ? "Remove all entries" : "Remove project"
        dangerButton.isEnabled = canEditGroup
        row?.needsLayout = true
        updateActions()
    }

    private weak var chooseIconButton: ButtonView?
    private weak var chooseFileButton: ButtonView?

    /// "Choose file" (ProjectSettingsPanel.tsx:527-535, 577-588): the image picker over the representative's
    /// checkout; a pick writes `{faviconPath: path, projectIcon: null}` to every member. A file on this Mac may
    /// be picked when every member lives on the primary environment (`pickProjectFavicon`, :196-204).
    private func chooseIconFile() {
        guard canEditGroup, let group, let representative = members.first(where: { m in context.scope.connected.contains { $0.id == m.environmentId } }) ?? members.first
        else { return }
        let external = context.scope.primaryId.map { primary in members.allSatisfy { $0.environmentId == primary } } ?? false
        context.chooseIconFile?(representative.environmentId, representative.workspaceRoot, group.displayName, external) { [weak self] path in
            guard let self else { return }
            self.context.updateProject?(self.members, ["faviconPath": .string(path), "projectIcon": .null], "Failed to update project icon")
        }
    }

    /// "Choose icon" (ProjectSettingsPanel.tsx:515-525, 589-598): the picker over the representative's icon;
    /// Save writes `{faviconPath: null, projectIcon}` to every member.
    private func chooseIcon() {
        guard canEditGroup, let window, let representative = members.first else { return }
        ProjectIconPickerDialog.present(in: window, current: representative.projectIcon, projectName: representative.title) { [weak self] icon in
            guard let self else { return }
            self.context.updateProject?(self.members, ["faviconPath": .null, "projectIcon": icon], "Failed to update project icon")
        }
    }

    /// The Project icon row's description (ProjectSettingsPanel.tsx:500-510).
    static func iconDescription(_ m: SettingsScopeProject.Member) -> String {
        let icon = m.projectIcon
        switch icon?["kind"]?.stringValue {
        case "lucide": return "\(icon?["name"]?.stringValue ?? "") · \(icon?["color"]?.stringValue ?? "")"
        case "monogram": return "\(icon?["text"]?.stringValue ?? "") · \(icon?["color"]?.stringValue ?? "")"
        case "emoji": return icon?["emoji"]?.stringValue ?? ""
        default: return m.faviconPath ?? "Automatic"
        }
    }

    // MARK: Overview

    private func buildOverview() -> SettingsGroupView {
        nameInput.frame.size = NSSize(width: 256, height: 28)
        nameInput.setAccessibilityLabel("Project name")
        nameInput.onChange = { [weak self] _ in self?.nameEdited = true }
        nameInput.onCommit = { [weak self] text in self?.rename(text) }
        let nameRow = SettingsRowView(title: "Name", detail: "The shared name for this project group in the sidebar and thread lists.", control: nameInput)

        // `ProjectFavicon className="size-6"`: the 16pt monogram drawn at 24.
        favicon.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        favicon.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        let chooseIcon = ButtonView("Choose icon", variant: .outline, size: .sm)
        chooseIcon.setAccessibilityLabel("Choose a project icon")
        chooseIcon.action = { [weak self] in self?.chooseIcon() }
        self.chooseIconButton = chooseIcon
        let chooseFile = ButtonView("Choose file", variant: .outline, size: .sm)
        chooseFile.setAccessibilityLabel("Choose a project icon file")
        chooseFile.action = { [weak self] in self?.chooseIconFile() }
        self.chooseFileButton = chooseFile
        let controls = SettingsControlGroup([FixedSizeBox(favicon, size: NSSize(width: 24, height: 24)), chooseIcon, chooseFile])
        iconRow = SettingsRowView(title: "Project icon", detail: "Automatic", control: controls)
        let reset = ResetSlot(label: "project icon")
        reset.action = { [weak self] in
            guard let self else { return }
            self.context.updateProject?(self.members, ["faviconPath": .null, "projectIcon": .null], "Failed to update project icon")
        }
        iconRow.accessories = [reset]
        nameRow.accessories = []
        permissionNote.isHidden = true
        let g = headless("project-overview", [permissionNote, nameRow, iconRow])
        return g
    }

    /// `renameGroup`: an empty name warns; an unedited or unchanged name sends nothing.
    private func rename(_ text: String) {
        let wasEdited = nameEdited
        nameEdited = false
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty || wasEdited else { return }
        if title.isEmpty {
            context.toast?("Project title cannot be empty", nil, .warning)
            nameInput.text = group?.displayName ?? ""
            return
        }
        guard members.contains(where: { $0.title != title }) else { return }
        context.updateProject?(members, ["title": .string(title)], "Failed to rename project")
    }

    // MARK: New threads (ProjectDefaultsSettings.tsx category="project")

    private func buildDefaults() -> SettingsSectionView {
        let model = SettingsModelPickerControl(context: context, key: "defaultModelSelection")
        let modelRow = row("default-model", title: "Model", detail: "Model for new threads in this project.", control: model)
        _ = bindServerRow(modelRow, keys: ["defaultModelSelection"], reset: "default model", resetPatch: { ["defaultModelSelection": .null] })
        binder.add { [weak self, weak model, weak modelRow] in
            guard let self else { return }
            model?.refresh()
            // `status`: "Automatic" while nothing picks a model, unless the project overrides it.
            let scope = self.context.scope
            let unset = !scope.isMixed(["defaultModelSelection"]) && scope.source(["defaultModelSelection"]) != .project
                && self.server["defaultModelSelection"] == .null
            modelRow?.status = !scope.connected.isEmpty && unset ? "Automatic" : nil
        }
        let (workspace, _) = serverSelect("new-threads", "Where new threads in this project start.", key: "defaultThreadEnvMode",
                                          options: [("local", "Current checkout"), ("worktree", "New worktree")], width: nil, reset: nil,
                                          label: "Default workspace", current: { $0["defaultThreadEnvMode"].stringValue ?? "local" })
        workspace.title = "Workspace"
        let s = SettingsSectionView(title: "New threads", rows: [modelRow, workspace])
        anchors["project-defaults"] = s
        return s
    }

    // MARK: Actions (ProjectActionsSettings.tsx)

    private func buildActions() -> SettingsSectionView {
        importAction.isHidden = true
        importAction.action = { [weak self] in self?.showImportScripts() }
        addAction.iconSize = 14
        addAction.action = { [weak self] in self?.openEditor(nil) }
        let header = SettingsRowView(title: "Actions", detail: "Commands that run in this project's checkout or its worktree, with optional shortcuts.",
                                     control: SettingsControlGroup([importAction, addAction], gap: 6))
        _ = bindServerRow(header, keys: ["defaultProjectScripts"], reset: "Actions")
        // `onResetOverride`: back to the environment's list, with the shortcuts that leaves behind.
        if let slot = header.accessories.last as? ResetSlot {
            slot.action = { [weak self] in self?.persist(transform: { _ in nil }, scriptId: nil, keybinding: nil) }
        }
        let s = SettingsSectionView(title: "Actions", rows: [header])
        anchors["project-actions"] = s
        return s
    }

    private var actionTargets: [ProjectActionsLogic.Target] {
        let scope = context.scope
        let byId = Dictionary(scope.connected.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return members.compactMap { m in
            guard let e = byId[m.environmentId], let s = e.settings, e.capabilities.contains("projectSettingsOverrides") else { return nil }
            let others = scope.projects.flatMap(\.members).filter { $0.environmentId == m.environmentId && $0.projectId != m.projectId }
                .map { (id: $0.projectId, scripts: $0.scripts) }
            return ProjectActionsLogic.Target(environmentId: e.id, settings: s, keybindings: context.configs[e.id]?.keybindings ?? [],
                                              projectId: m.projectId, projectScripts: m.scripts, otherProjects: others)
        }
    }

    private var shownScripts: [ProjectScript] { ProjectScript.list(context.scope.values["defaultProjectScripts"]) }

    private func updateActions() {
        guard let header = actions.group.rows.first else { return }
        let targets = context.scope.targets
        let scripts = shownScripts
        let mixed = targets.contains { ProjectScript.list($0.settings["defaultProjectScripts"]) != scripts }
        addAction.isEnabled = !savingActions && context.scope.canWrite && !targets.isEmpty
        let keybindings = context.scope.target.flatMap { context.configs[$0.environmentId]?.keybindings } ?? []
        var rows: [any SettingsGroupRow] = [header]
        if mixed {
            rows.append(SettingsRowView(title: "Different actions across environments",
                                        detail: "Choose one environment to edit its list. Adding an action here adds it on every selected environment."))
        } else if scripts.isEmpty {
            rows.append(SettingsGroupNote("No actions configured."))
        } else {
            for script in scripts {
                let r = ProjectActionRowView(script: script, shortcut: ProjectScripts.command(script.id).flatMap { command in
                    Keymap.merged(withServer: keybindings).label(for: command) })
                r.edit.isEnabled = !savingActions && context.scope.canWrite
                r.edit.action = { [weak self] in self?.openEditor(script) }
                rows.append(r)
            }
        }
        if let contents = projectFileContents, ProjectActionsLogic.validatedFileScripts(contents) == nil {
            rows.append(SettingsRowView(title: "t3.json is invalid", detail: "A t3.json exists in this checkout but fails to parse, so every action and icon it declares is ignored. Check the JSON syntax and icon values."))
        }
        importAction.isHidden = ProjectActionsLogic.importableScripts(projectFileContents ?? "", existing: scripts).isEmpty
        importAction.isEnabled = !savingActions && context.scope.canWrite && !targets.isEmpty
        actions.group.rows = rows
    }

    private func loadProjectFile() {
        guard window != nil, let member = members.first, let request = context.request else { return }
        let key = member.environmentId + ":" + member.workspaceRoot
        guard projectFileKey != key else { return }
        projectFileKey = key; projectFileContents = nil
        projectFileTask?.cancel()
        projectFileTask = Task { [weak self] in
            let reply = try? await request(member.environmentId, "projects.readFile", .object(["cwd": .string(member.workspaceRoot), "relativePath": .string("t3.json")]))
            guard !Task.isCancelled, let self, self.projectFileKey == key else { return }
            self.projectFileContents = reply?["truncated"]?.boolValue == true ? nil : reply?["contents"]?.stringValue
            self.updateActions(); self.onHeightChange?()
        }
    }

    private func showImportScripts() {
        let inputs = ProjectActionsLogic.importableScripts(projectFileContents ?? "", existing: shownScripts)
        let items = inputs.map { input in
            var item = MenuItem(input.name, icon: ProjectScriptIcon.name(input.icon))
            item.action = { [weak self] in
                guard let self else { return }
                let id = ProjectActionsLogic.newId(input.name, targets: self.actionTargets)
                self.persist(transform: { ProjectScripts.applySubmit($0, id: id, isNew: true, input: input) }, scriptId: id, keybinding: nil)
            }
            return item
        }
        MenuPopupView.show(items, from: importAction, placement: .dropdown)
    }

    private func openEditor(_ script: ProjectScript?) {
        let keybindings = context.scope.target.flatMap { context.configs[$0.environmentId]?.keybindings } ?? []
        let editor = ProjectActionEditor(script: script, keybinding: script.flatMap { ProjectActionsLogic.keybindingValue(keybindings, command: ProjectScripts.command($0.id)) })
        guard let host = context.presentDialog?(editor.dialog) else { return }
        // The dialog lives as long as its host; keep the editor that drives it until then.
        openEditor = editor
        let previous = host.onDismiss
        host.onDismiss = { [weak self] in
            previous?()
            self?.openEditor = nil
        }
        editor.onCancel = { [weak host] in host?.close() }
        editor.onSubmit = { [weak self, weak host, weak editor] input in
            guard let self, let editor else { return }
            let targets = self.actionTargets
            let id = script?.id ?? ProjectActionsLogic.newId(input.name, targets: targets)
            editor.isSaving = true
            self.persist(transform: { ProjectScripts.applySubmit($0, id: id, isNew: script == nil, input: input) },
                         scriptId: id, keybinding: input.keybinding) { error in
                editor.isSaving = false
                if let error { editor.error = error } else { host?.close() }
            }
        }
        editor.onDelete = { [weak self, weak host] in
            guard let self, let script else { return }
            host?.close()
            self.context.confirm?("Delete action \"\(script.name)\"?\nThis action cannot be undone.", true) { [weak self] in
                self?.persist(transform: { $0.filter { $0.id != script.id } }, scriptId: script.id, keybinding: "")
            }
        }
    }

    /// `persist`: one write per environment, then its shortcut changes; a failure stops the rest.
    private func persist(transform: @escaping ([ProjectScript]) -> [ProjectScript]?, scriptId: String?, keybinding: String?,
                         done: ((String?) -> Void)? = nil) {
        let targets = actionTargets
        guard !savingActions, !targets.isEmpty else {
            context.toast?("Actions not saved", "No available machine, or another action change is saving.", .error)
            done?("No available machine, or another action change is saving.")
            return
        }
        guard context.scope.canWrite else {
            context.toast?("Failed to save project actions", "This connection cannot change environment settings.", .error)
            done?("This connection cannot change environment settings.")
            return
        }
        let writes = ProjectActionsLogic.plan(targets, transform: transform, scriptId: scriptId, keybinding: keybinding)
        savingActions = true
        updateActions()
        Task { [weak self] in
            let error = await self?.context.saveActions?(writes) ?? nil
            guard let self else { return }
            self.savingActions = false
            if let error { self.context.toast?("Failed to save project actions", error, .error) }
            self.updateActions()
            done?(error)
        }
    }

    // MARK: Danger

    private func buildDanger() -> SettingsSectionView {
        dangerButton.iconSize = 14
        dangerButton.action = { [weak self] in guard let self else { return }; self.confirmRemove(self.members) }
        let r = SettingsRowView(title: "Remove project", detail: "", control: dangerButton)
        return SettingsSectionView(title: "Danger", rows: [r])
    }

    /// `removeMembers`: the native confirm with T3's lines, then `project.delete {force}` per member.
    private func confirmRemove(_ chosen: [SettingsScopeProject.Member]) {
        guard let group, !chosen.isEmpty else { return }
        let threads = chosen.reduce(0) { $0 + (context.threadCount?($1.environmentId, $1.projectId) ?? 0) }
        let hasOtherMembers = members.count < group.members.count
        let message = ProjectRemoval.message(members: chosen, allMembers: members, hasOtherMembers: hasOtherMembers, groupName: group.displayName,
                                             threadCount: threads)
        let leave = chosen.count == members.count && !hasOtherMembers
        context.confirm?(message, true) { [weak self] in self?.context.deleteProjects?(chosen, leave) }
    }
}

/// The removal prompt (ProjectSettingsPanel.tsx `removeMembers`).
public enum ProjectRemoval {
    public static func message(members: [SettingsScopeProject.Member], allMembers: [SettingsScopeProject.Member], hasOtherMembers: Bool,
                               groupName: String, threadCount: Int) -> String {
        let isWholeGroup = members.count == allMembers.count
        let kind = hasOtherMembers || !isWholeGroup ? "checkout" : "project"
        let single = members.count == 1 ? members[0] : nil
        let label = single?.title ?? groupName
        var lines = [threadCount > 0
            ? "Remove \(kind) \"\(label)\" and delete its \(threadCount) thread\(threadCount == 1 ? "" : "s")?"
            : "Remove \(kind) \"\(label)\"?"]
        if let single {
            lines.append("Path: \(single.workspaceRoot)")
            if let env = single.environmentLabel { lines.append("Environment: \(env)") }
        } else {
            lines.append("This removes \(members.count) grouped project entries.")
        }
        lines.append(threadCount > 0 ? "This permanently clears conversation history for those threads and any archived threads."
                     : "This permanently clears any archived conversation history.")
        lines.append(isWholeGroup && !hasOtherMembers ? "This removes only the project entries, not the files on disk."
                     : "Other entries in this grouped project are unaffected.")
        lines.append("This action cannot be undone.")
        return lines.joined(separator: "\n")
    }
}

/// A fixed-size slot for a view whose own frame differs (the scaled favicon).
final class FixedSizeBox: DSView {
    let size: NSSize
    init(_ view: NSView, size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(view)
    }
    override var intrinsicContentSize: NSSize { size }
}

/// One action (ProjectActionsList.tsx): icon, name and role badges over the mono command; the shortcut and an
/// edit button that shows at once on hover or keyboard focus (`group py-2`, ProjectActionsList.tsx:59-62).
final class ProjectActionRowView: DSView, SettingsGroupRow, FocusWithinObserver {
    let edit = ButtonView(nil, icon: .settings, variant: .ghostMuted, size: .iconXs)
    private let icon: IconView
    private let name = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastForeground))
    private let command = LabelView("", font: DSFont.mono(12), color: Themed.color(\.contrastMutedForeground, 0.8))
    private var badges: [RoleBadge] = []
    private let shortcut = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { edit.alphaValue = hovered || focusWithin ? 1 : 0 } }
    private var focusWithin = false { didSet { edit.alphaValue = hovered || focusWithin ? 1 : 0 } }
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused }

    init(script: ProjectScript, shortcut label: String?) {
        icon = IconView(name: Self.icon(script.icon), size: 16, strokeColor: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        name.text = script.name
        name.lineHeight = 20
        command.text = script.command
        command.lineHeight = 18
        shortcut.text = label ?? ""
        shortcut.lineHeight = 16
        shortcut.isHidden = label == nil
        edit.iconSize = 14
        edit.setAccessibilityLabel("Edit \(script.name)")
        edit.alphaValue = 0
        if script.runOnWorktreeCreate { badges.append(RoleBadge("setup")) }
        if script.runOnSettle == true { badges.append(RoleBadge("on settle")) }
        if script.previewUrl != nil { badges.append(RoleBadge("preview · desktop only")) }
        for v in [icon, name, command, shortcut, edit] as [NSView] + badges { addSubview(v) }
    }

    /// `ScriptIcon`.
    static func icon(_ id: String) -> IconName { ProjectScriptIcon.name(id) }

    // `py-2`: 8 + 20 + 4 + 18 + 8.
    func height(forWidth width: CGFloat) -> CGFloat { 58 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func layout() {
        super.layout()
        let w = bounds.width
        edit.frame = NSRect(x: w - 16 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
        var right = edit.frame.minX - 8
        if !shortcut.isHidden {
            let sw = ceil(shortcut.textWidth) + 1
            shortcut.frame = NSRect(x: right - sw, y: (bounds.height - 16) / 2, width: sw, height: 16)
            right = shortcut.frame.minX - 32
        } else { right -= 24 }
        icon.frame = NSRect(x: 16, y: 10, width: 16, height: 16)
        var x: CGFloat = 16 + 16 + 8
        let nw = min(ceil(name.textWidth) + 1, max(0, right - x))
        name.frame = NSRect(x: x, y: 8, width: nw, height: 20)
        x += nw + 8
        for b in badges {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: 8 + (20 - s.height) / 2, width: s.width, height: s.height)
            x += s.width + 8
        }
        command.frame = NSRect(x: 16, y: 32, width: max(0, right - 16), height: 18)
    }

    /// `rounded-sm border border-border/60 px-1.5 py-px text-2xs text-muted-foreground`.
    final class RoleBadge: BoxView {
        private let label = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
        init(_ text: String) {
            super.init(frame: .zero)
            label.text = text
            label.lineHeight = 14
            addSubview(label)
            var style = BoxStyle()
            style.radius = 4
            style.border = Themed.color(\.border, 0.6)
            boxStyle = style
        }
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1 + 12 + 2, height: 18) }
        override func layout() { super.layout(); label.frame = NSRect(x: 7, y: 2, width: bounds.width - 14, height: 14) }
    }
}

/// `ScriptIcon` (ProjectScriptsControl.tsx): a project action's glyph by its icon id.
public enum ProjectScriptIcon {
    public static func name(_ id: String) -> IconName {
        switch id {
        case "test": .flaskConical
        case "lint": .listChecks
        case "configure": .wrench
        case "build": .hammer
        case "debug": .bug
        default: .play
        }
    }
}
