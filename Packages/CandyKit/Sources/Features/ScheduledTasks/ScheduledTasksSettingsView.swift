import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// One environment's live task list (`scheduledTasks.subscribe`).
public enum ScheduledTaskListLoad: Equatable, Sendable {
    case loading
    case loaded([ScheduledTask])
    case failed(String)
}

/// `matchesScheduledTaskScope`: tasks of the scope's environments, and at a project scope only the selected checkouts' tasks.
public enum ScheduledTaskScope {
    public static func matches(_ scope: SettingsScopeState, environmentId: String, projectId: String) -> Bool {
        if case .unavailable = scope.kind { return false }
        guard scope.environmentIds.contains(environmentId) else { return false }
        if scope.isProjectScope { return scope.members.contains { $0.environmentId == environmentId && $0.projectId == projectId } }
        return true
    }
}

/// Settings > Scheduled Tasks (ScheduledTasksSettings.tsx): "Scheduled tasks" with New task, then per environment
/// the task rows (title, prompt, schedule and next run, last run badge, enable switch, the actions menu).
public final class ScheduledTasksSettingsView: ScopedSettingsPage {
    private let list = ScheduledTasksListView()
    /// A task to open once its list arrives (`taskId` from the thread automations panel).
    public var linkedTask: (environmentId: String, taskId: String)?
    private var busy: Set<String> = []

    public init(context: SettingsPageContext) {
        super.init(context: context)
        list.newTask.action = { [weak self] in self?.openEditor(environmentId: nil, task: nil) }
        body = [list]
        anchors["scheduled-tasks"] = list
        binder.add { [weak self] in self?.update() }
    }

    public override func didShow() { context.watchScheduledTasks?(true) }

    private func update() {
        let scope = context.scope
        let environments = scope.environments.filter { scope.environmentIds.contains($0.id) }
        let defaultEnv = scope.representative
        list.newTask.isEnabled = defaultEnv != nil
        let nowMs = TimestampFormat.nowMs()
        if case .unavailable(let message) = scope.kind {
            list.sections = [SettingsSectionView(title: "Unavailable selection", rows: [SettingsRowView(title: message)])]
        } else if environments.isEmpty {
            let empty = EmptyView(title: "No environments available", message: "Connect an environment to manage scheduled tasks.", icon: .clock3)
            list.sections = [UsageEmptyRow(empty)]
        } else {
            list.sections = environments.map { env in
                var rows: [any SettingsGroupRow] = []
                let connected = env.connected && env.settings != nil
                switch context.scheduledTasks[env.id] {
                case _ where !connected:
                    rows = [SettingsRowView(title: "Environment disconnected", detail: "Reconnect \(env.label) to view its scheduled tasks.")]
                case .failed(let error):
                    rows = [SettingsRowView(title: "Could not load scheduled tasks", detail: error)]
                case .loaded(let all):
                    let tasks = all.filter { ScheduledTaskScope.matches(scope, environmentId: env.id, projectId: $0.projectId) }
                    if let link = linkedTask, link.environmentId == env.id {
                        if let t = tasks.first(where: { $0.id == link.taskId }) {
                            linkedTask = nil
                            DispatchQueue.main.async { [weak self] in self?.openEditor(environmentId: env.id, task: t) }
                        } else {
                            rows.append(SettingsRowView(title: "Task unavailable", detail: "This task no longer exists or is outside the selected project scope."))
                        }
                    }
                    if tasks.isEmpty {
                        rows.append(SettingsRowView(title: "No scheduled tasks", detail: "No tasks match this environment and project selection."))
                    } else {
                        rows += tasks.map { taskRow(env.id, $0, nowMs: nowMs) }
                    }
                default:
                    rows = [SettingsRowView(title: "Loading scheduled tasks…")]
                }
                // `hideTitle` with one environment: the card alone.
                if environments.count <= 1 { return SettingsGroupView(rows: rows) as NSView & SettingsGroupRow }
                let s = SettingsSectionView(title: env.label, rows: rows)
                let icon = IconView(name: EnvironmentMachineGlyph.icon(env.machine), size: 14, strokeColor: Themed.color(\.foreground, 0.7))
                icon.frame.size = NSSize(width: 14, height: 14)
                s.icon = icon
                return s as NSView & SettingsGroupRow
            }
        }
    }

    private func taskRow(_ env: String, _ t: ScheduledTask, nowMs: Int64) -> NSView & SettingsGroupRow {
        let toggle = SwitchView(isOn: t.enabled)
        toggle.setAccessibilityLabel("Enable \(t.title)")
        toggle.isEnabled = !busy.contains(t.id)
        toggle.onChange = { [weak self] _ in self?.act(env, t, "scheduledTasks.setEnabled", .object(["id": .string(t.id), "enabled": .bool(!t.enabled)])) }
        let more = ButtonView(nil, icon: .ellipsis, variant: .ghost, size: .iconSm).menuTrigger()
        more.setAccessibilityLabel("Actions for \(t.title)")
        more.isEnabled = !busy.contains(t.id)
        more.action = { [weak self, weak more] in
            guard let self, let more else { return }
            var items = [MenuItem("Edit", icon: .pencil) { [weak self] in self?.openEditor(environmentId: env, task: t) }]
            if t.schedule.isWebhook {
                items.append(MenuItem("Deliveries", icon: .inbox) { [weak self] in self?.openDeliveries(env, t) })
            } else {
                items.append(MenuItem("Run now", icon: .play) { [weak self] in self?.act(env, t, "scheduledTasks.runNow", .object(["id": .string(t.id)])) })
            }
            items.append(.separator)
            items.append(MenuItem("Delete", icon: .trash2) { [weak self] in self?.act(env, t, "scheduledTasks.delete", .object(["id": .string(t.id)])) })
            MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
        }
        let controls = DSView()
        controls.addSubview(toggle)
        controls.addSubview(more)
        let ts = toggle.intrinsicContentSize
        controls.frame.size = NSSize(width: ts.width + 8 + 28, height: 28)
        toggle.frame = NSRect(x: 0, y: (28 - ts.height) / 2, width: ts.width, height: ts.height)
        more.frame = NSRect(x: ts.width + 8, y: 0, width: 28, height: 28)
        let row = SettingsRowView(title: t.title, detail: nil, control: UsageFixedSizeView(controls))
        row.detailView = ScheduledTaskDetailView(task: t, nowMs: nowMs)
        return row
    }

    /// `act`: toggle, run or delete, with T3's failure toast.
    private func act(_ env: String, _ t: ScheduledTask, _ method: String, _ payload: JSONValue) {
        guard let request = context.request, !busy.contains(t.id) else { return }
        busy.insert(t.id)
        update()
        Task { [weak self] in
            do { _ = try await request(env, method, payload) } catch {
                self?.context.toast?("Could not update scheduled task", ScheduledTaskErrorText.message(error), .error)
            }
            self?.busy.remove(t.id)
            self?.refresh()
        }
    }

    // MARK: Dialogs

    func openEditor(environmentId: String?, task: ScheduledTask?) {
        guard let env = environmentId ?? context.scope.representative?.id else { return }
        let editor = ScheduledTaskEditor(context: context, environmentId: env, task: task)
        editor.present()
    }

    private func openDeliveries(_ env: String, _ t: ScheduledTask) {
        ScheduledTaskDeliveriesDialog(context: context, environmentId: env, task: t).present()
    }
}

/// Errors from the server read as their `message` (`squashAtomCommandFailure`).
enum ScheduledTaskErrorText {
    static func message(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }
}

/// The machine glyph of an environment section (`EnvironmentMachineIcon`).
enum EnvironmentMachineGlyph {
    static func icon(_ machine: String) -> IconName {
        switch machine {
        case "laptop", "mac-mini", "mac-studio", "desktop": .monitor
        case "cloud": .cloud
        default: .server
        }
    }
}

/// `Empty` in a page body.
final class UsageEmptyRow: DSView, SettingsGroupRow {
    let empty: EmptyView
    init(_ empty: EmptyView) { self.empty = empty; super.init(frame: .zero); addSubview(empty) }
    func height(forWidth width: CGFloat) -> CGFloat { empty.intrinsicContentSize.height }
    override func layout() { super.layout(); empty.frame = bounds }
}

/// The page's plain section: the "Scheduled tasks" header with New task, then the environment sections `space-y-8`.
final class ScheduledTasksListView: DSView, SettingsGroupRow {
    private let title = LabelView("Scheduled tasks", font: DSFont.ui(14), color: Themed.color(\.foreground, 0.7))
    let newTask = ButtonView("New task", icon: .plus, variant: .ghostMuted, size: .xs)
    var sections: [NSView & SettingsGroupRow] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; sections.forEach(addSubview); needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineHeight = 20
        newTask.iconSize = 12
        addSubview(title)
        addSubview(newTask)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        28 + 10 + sections.reduce(0) { $0 + $1.height(forWidth: width) } + 32 * CGFloat(max(0, sections.count - 1))
    }

    override func layout() {
        super.layout()
        // The section header's `px-3 sm:px-4`.
        title.frame = NSRect(x: 16, y: 4, width: 200, height: 20)
        let s = newTask.intrinsicContentSize
        newTask.frame = NSRect(x: bounds.width - 16 - s.width, y: (28 - s.height) / 2, width: s.width, height: s.height)
        var y: CGFloat = 38
        for sec in sections {
            let h = sec.height(forWidth: bounds.width)
            sec.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 32
        }
    }
}

/// A task row's description and status: the prompt (two lines), then `schedule · Next run in 5m`, the last run
/// badge and its error (`flex flex-wrap items-center gap-2`).
final class ScheduledTaskDetailView: DSView {
    private let prompt = TextBlockView()
    private let status: LabelView
    private let badge: BadgeView?
    private let error: LabelView?

    init(task t: ScheduledTask, nowMs: Int64) {
        let when = !t.enabled ? "Paused" : t.schedule.isWebhook ? "Listening"
            : t.nextRunAt != nil ? "Next run \(ScheduledTaskLogic.relativeLabel(t.nextRunAt, nowMs: nowMs))" : "Not scheduled"
        status = LabelView("\(ScheduledTaskLogic.scheduleLabel(t.schedule)) · \(when)", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        status.lineHeight = 16
        badge = t.lastRunStatus == "never" ? nil : BadgeView(t.lastRunStatus, variant: BadgeView.Variant(rawValue: ScheduledTaskLogic.statusTone(t.lastRunStatus)) ?? .outline)
        error = t.lastRunError.map { e in let l = LabelView(e, font: DSFont.ui(12), color: Themed.color(\.destructive)); l.lineHeight = 16; return l }
        super.init(frame: .zero)
        prompt.text = t.prompt
        prompt.font = DSFont.ui(12)
        prompt.lineHeight = 18
        prompt.color = Themed.color(\.mutedForeground, 0.8)
        prompt.maxLines = 2
        for v in [prompt, status] as [NSView] { addSubview(v) }
        badge.map(addSubview)
        error.map(addSubview)
        frame.size = NSSize(width: 576, height: promptHeight(576) + 6 + 18)
    }

    private func promptHeight(_ w: CGFloat) -> CGFloat { min(36, prompt.height(forWidth: min(576, w))) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let h = promptHeight(newSize.width) + 6 + 18
        if abs(frame.height - h) > 0.5 { super.setFrameSize(NSSize(width: newSize.width, height: h)) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let ph = promptHeight(w)
        prompt.frame = NSRect(x: 0, y: 0, width: min(576, w), height: ph)
        var x: CGFloat = 0
        let y = ph + 6
        let sw = min(ceil(status.textWidth) + 1, w)
        status.frame = NSRect(x: 0, y: y + 1, width: sw, height: 16)
        x = sw + 8
        if let badge {
            let s = badge.intrinsicContentSize
            badge.frame = NSRect(x: x, y: y + (18 - s.height) / 2, width: s.width, height: s.height)
            x += s.width + 8
        }
        error?.frame = NSRect(x: x, y: y + 1, width: max(0, w - x), height: 16)
    }
}

// MARK: - Editor

/// `ScheduledTaskEditorDialog`: Runs on, Name, Project and Workspace, base branch or checkout path, Prompt,
/// Model, the schedule (At a time with weekdays, Every interval, On webhook with URL, age limit and signature),
/// Enabled; Cancel and Create or Save task.
@MainActor
final class ScheduledTaskEditor {
    let context: SettingsPageContext
    var environmentId: String
    let task: ScheduledTask?
    var draft: ScheduledTaskDraft
    private var host: ModalHost?
    private let dialog: DialogView
    private let form = ScheduledTaskFormView()
    private let submit: ButtonView
    private let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
    private var saving = false

    init(context: SettingsPageContext, environmentId: String, task: ScheduledTask?) {
        self.context = context
        self.environmentId = environmentId
        self.task = task
        draft = task.map(ScheduledTaskLogic.draft) ?? ScheduledTaskDraft()
        dialog = DialogView(title: task == nil ? "New task" : "Edit task",
                            message: "Run a prompt automatically — on an interval, at a fixed time, or when a webhook is called.")
        dialog.maxWidth = 576
        submit = ButtonView(task == nil ? "Create task" : "Save task", size: .sm)
        if task == nil { draft.projectId = projects.first?.projectId ?? "" }
        dialog.panelContent = [form]
        dialog.footerButtons = [cancel, submit]
        form.editor = self
        cancel.action = { [weak self] in self?.host?.close() }
        submit.action = { [weak self] in self?.save() }
        form.rebuild()
        context.observe { [weak self] in self?.liveChanged() }
    }

    var environments: [SettingsScopeEnvironment] { context.scope.connected }
    var environment: SettingsScopeEnvironment? { context.scope.environments.first { $0.id == environmentId } }
    var connected: Bool { environment.map { $0.connected && $0.settings != nil } ?? false }
    var load: ScheduledTaskListLoad? { context.scheduledTasks[environmentId] }

    var projects: [SettingsScopeProject.Member] {
        context.scope.projects.flatMap(\.members).filter { $0.environmentId == environmentId
            && ScheduledTaskScope.matches(context.scope, environmentId: environmentId, projectId: $0.projectId) }
    }

    var selectedProjectId: String { draft.projectId.isEmpty ? projects.first?.projectId ?? "" : draft.projectId }

    /// The live task, so a rotated URL shows without reopening; nil once the list says it is gone.
    var liveTask: ScheduledTask? {
        if case .loaded(let tasks) = load { return tasks.first { $0.id == draft.editingId } }
        return task
    }

    var editingTaskMissing: Bool {
        guard draft.editingId != nil, case .loaded(let tasks) = load else { return false }
        return !tasks.contains { $0.id == draft.editingId }
    }

    var providers: [ServerProvider] { context.configs[environmentId]?.providers ?? [] }
    /// The picked project's provider switches apply (ScheduledTasksSettings.tsx:828-832, 2994).
    var catalog: ProviderCatalog { ProviderCatalog(providers, settings: environment?.settings, projectId: selectedProjectId.isEmpty ? nil : selectedProjectId) }

    /// The picked model, else `scheduledTaskDefaultModel`: the project's or environment's default when available,
    /// else the catalog's default model.
    var activeSelection: (instanceId: String, model: String)? {
        if let s = ScheduledTaskLogic.splitModelKey(draft.modelKey) { return s }
        let catalog = self.catalog
        let available = catalog.entries.filter { $0.isSelectable }
        let settings = environment?.settings
        let member = projects.first { $0.projectId == selectedProjectId }
        let configured = settings.map { ProjectSettings.resolve($0, projectId: member?.projectId, legacy: member?.legacy).settings["defaultModelSelection"] }
        for sel in [configured, settings?["defaultModelSelection"]] {
            if let id = sel?["instanceId"]?.stringValue, let model = sel?["model"]?.stringValue,
               available.contains(where: { $0.id.rawValue == id && $0.models.first { $0.slug == model }?.isLegacy != true }) {
                return (id, model)
            }
        }
        for entry in available { if let m = entry.defaultModel ?? entry.models.first?.slug { return (entry.id.rawValue, m) } }
        return nil
    }

    /// Open dialogs keep their controller alive; the views hold it only weakly.
    static var live: [ObjectIdentifier: AnyObject] = [:]

    func present() {
        guard let h = context.presentDialog?(dialog) else { return }
        host = h
        let key = ObjectIdentifier(self)
        Self.live[key] = self
        let previous = h.onDismiss
        h.onDismiss = { previous?(); ScheduledTaskEditor.live[key] = nil }
        refreshFooter()
        DispatchQueue.main.async { [weak self] in self?.form.focusName() }
    }

    private func liveChanged() {
        guard host != nil else { return }
        form.refreshLive()
        refreshFooter()
    }

    func refreshFooter() {
        let loaded: Bool = { if case .loaded = load { return true }; return false }()
        submit.isEnabled = !saving && !editingTaskMissing && connected && loaded
        cancel.isEnabled = !saving
        submit.title = task == nil ? "Create task" : "Save task"
    }

    func changed() {
        form.rebuild()
        dialog.panelContent = [form]
        refreshFooter()
    }

    func selectEnvironment(_ id: String) {
        environmentId = id
        draft.projectId = ""
        draft.modelKey = ""
        draft.baseModelSelection = nil
        draft.baseRef = "main"
        draft.startFromOrigin = true
        draft.existingWorktreePath = ""
        context.watchScheduledTasks?(true)
        changed()
    }

    private func report(_ e: ScheduledTaskLogic.ValidationError) { context.toast?(e.copy.title, e.copy.description, .error) }

    private func save() {
        guard !saving, !editingTaskMissing, connected, let request = context.request else { return }
        let input = ScheduledTaskLogic.upsertInput(draft, projectId: selectedProjectId, projectExists: projects.contains { $0.projectId == selectedProjectId },
                                                   selection: activeSelection, storedSecret: liveTask?.webhook?.hasSecret == true)
        switch input {
        case .failure(let e): report(e)
        case .success(let payload):
            saving = true
            refreshFooter()
            let env = environmentId
            Task { [weak self] in
                do {
                    _ = try await request(env, "scheduledTasks.upsert", payload)
                    self?.host?.close()
                } catch {
                    self?.saving = false
                    self?.refreshFooter()
                    self?.context.toast?("Could not save scheduled task", ScheduledTaskErrorText.message(error), .error)
                }
            }
        }
    }

    func rotate() {
        guard let t = liveTask, let request = context.request, let window = dialog.window else { return }
        let confirm = DialogView(kind: .alertDialog, title: "Rotate this webhook URL?", message: "The current URL stops working.")
        let no = ButtonView("Cancel", variant: .outline)
        let yes = ButtonView("Confirm", variant: .destructive)
        confirm.footerButtons = [no, yes]
        let h = ModalHost.present(confirm, in: window)
        no.action = { [weak h] in h?.close() }
        yes.action = { [weak self, weak h] in
            h?.close()
            guard let self else { return }
            let env = self.environmentId
            Task { [weak self] in
                do { _ = try await request(env, "scheduledTasks.rotateWebhookToken", .object(["id": .string(t.id)])) } catch {
                    self?.context.toast?("Could not rotate webhook URL", ScheduledTaskErrorText.message(error), .error)
                }
            }
        }
    }
}

/// The editor's form: fields stacked `space-y-5`, each a label over its control (`Field`).
final class ScheduledTaskFormView: DSView {
    weak var editor: ScheduledTaskEditor?
    private var rows: [(view: NSView, height: CGFloat)] = []
    private var nameInput: InputView?
    private var webhookField: ScheduledTaskWebhookField?
    /// `DialogPanel` scrolls once the popup reaches the viewport (`max-h-[calc(100dvh-2rem)]` less header and footer).
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true)
    private var contentHeight: CGFloat { rows.reduce(0) { $0 + $1.height } + 20 * CGFloat(max(0, rows.count - 1)) }
    var maxHeight: CGFloat {
        let host: NSWindow? = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        let available: CGFloat = host?.contentView?.bounds.height ?? 900
        // The popup keeps 16pt from the window edges; its header and footer take about 220pt.
        return max(200, available - 32 - 200)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Inside a dialog: no titlebar inset.
        scroll.scrollView.automaticallyAdjustsContentInsets = false
        scroll.scrollView.contentInsets = NSEdgeInsets()
        addSubview(scroll)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: min(contentHeight, maxHeight)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }


    func focusName() { nameInput.map { window?.makeFirstResponder($0) } }

    /// Only the parts that follow the live list.
    func refreshLive() { webhookField?.refresh() }

    private func field(_ label: String, hint: String? = nil, _ control: NSView, height: CGFloat) -> (NSView, CGFloat) {
        (ScheduledTaskFieldView(label, hint: hint, control: control, controlHeight: height), 22 + height)
    }

    private func text(_ s: String, color: NSColor, size: CGFloat = 14) -> (NSView, CGFloat) {
        let t = TextBlockView()
        t.text = s; t.font = DSFont.ui(size); t.lineHeight = size == 14 ? 20 : 16; t.color = color
        return (t, t.height(forWidth: 528))
    }

    private var baseBranchTask: Task<Void, Never>?
    private func showBaseBranch(from trigger: NSView) {
        guard let e = editor, let request = e.context.request,
              let project = e.projects.first(where: { $0.projectId == e.selectedProjectId }) else { return }
        let picker = BranchPickerView()
        picker.selectedValue = e.draft.baseRef
        picker.startFromOrigin = e.draft.startFromOrigin
        picker.onStartFromOrigin = { [weak e] in e?.draft.startFromOrigin = $0 }
        let popup = picker.present(from: trigger, placement: .dropdown)
        picker.onPick = { [weak e, weak trigger, weak popup] value in
            e?.draft.baseRef = value
            (trigger as? ButtonView)?.title = value
            if let popup { trigger?.popupHost?.close(popup) }
        }
        var query = "", cursor: Int?, refs: [VcsRef] = []
        let environmentId = e.environmentId, cwd = project.workspaceRoot
        popup?.onClose = { [weak self] in self?.baseBranchTask?.cancel(); self?.baseBranchTask = nil }
        func load(_ next: Int?, picker: BranchPickerView) {
            self.baseBranchTask?.cancel()
            picker.statusText = next == nil ? "Loading refs..." : "Loading more refs..."
            let sanitized = BranchToolbarLogic.sanitizeNewRefName(query)
            self.baseBranchTask = Task { [weak picker] in
                do {
                    let json = try await request(environmentId, VcsRPC.listRefs, VcsRPC.listRefsInput(cwd: cwd, query: sanitized, cursor: next))
                    guard !Task.isCancelled, let picker, picker.window != nil else { return }
                    let page = try json.decode(as: VcsListRefsResult.self)
                    if next == nil { refs = [] }
                    var known = Set(refs.map(\.name))
                    refs += page.refs.filter { known.insert($0.name).inserted }
                    cursor = page.nextCursor
                    picker.rows = refs.map { BranchPickerView.Row(value: $0.name, title: $0.name, badge: $0.isRemote == true ? "Remote" : nil) }
                    picker.hasNextPage = cursor != nil
                    picker.statusText = cursor == nil ? nil : "Showing \(refs.count) of \(page.totalCount) refs"
                } catch { if !Task.isCancelled { picker?.statusText = String(describing: error) } }
            }
        }
        picker.onQuery = { [weak picker] value in guard let picker else { return }; query = value; load(nil, picker: picker) }
        picker.onLoadMore = { [weak picker] in if let cursor, let picker { load(cursor, picker: picker) } }
        load(nil, picker: picker)
    }

    func rebuild() {
        guard let e = editor else { return }
        rows.forEach { $0.view.removeFromSuperview() }
        rows = []
        webhookField = nil
        var d = e.draft
        if !e.connected { rows.append(text("Reconnect this environment before saving.", color: Themed.color(\.destructive))) }
        // Runs on.
        let envs = e.environments
        let envSelect = SelectView(options: envs.map(\.label), selected: envs.firstIndex { $0.id == e.environmentId }, placeholder: e.environment?.label ?? "Unavailable environment", size: .sm)
        envSelect.isEnabled = e.task == nil
        envSelect.onChange = { [weak e] i in e?.selectEnvironment(envs[i].id) }
        rows.append(field("Runs on", envSelect, height: 28))
        if case .failed(let error) = e.load { rows.append(text(error, color: Themed.color(\.destructive))) }
        if e.editingTaskMissing { rows.append(text("This scheduled task no longer exists.", color: Themed.color(\.destructive), size: 12)) }
        // Name.
        let name = InputView(placeholder: "e.g. Check for Sentry issues", text: d.title)
        name.onChange = { [weak e] t in e?.draft.title = t }
        nameInput = name
        rows.append(field("Name", name, height: 32))
        // Project and Workspace, side by side.
        let projects = e.projects
        let project = SelectView(options: projects.map(\.title), selected: projects.firstIndex { $0.projectId == e.selectedProjectId }, placeholder: "Select a project", size: .sm)
        project.onChange = { [weak e] i in e?.draft.projectId = projects[i].projectId; e?.changed() }
        let modes: [ScheduledTaskDraft.WorkspaceMode] = [.worktree, .root, .existingWorktree]
        let workspace = SelectView(options: modes.map(ScheduledTaskLogic.workspaceLabel), selected: modes.firstIndex(of: d.workspaceMode), size: .sm)
        workspace.onChange = { [weak e] i in e?.draft.workspaceMode = modes[i]; e?.changed() }
        let pair = ScheduledTaskPairView(field("Project", project, height: 28), field("Workspace", workspace, height: 28))
        rows.append((pair, 50))
        if d.workspaceMode == .worktree {
            let base = ButtonView(d.baseRef.isEmpty ? "Select branch" : d.baseRef, icon: .gitBranch, variant: .outline, size: .sm)
            base.action = { [weak self, weak base] in if let base { self?.showBaseBranch(from: base) } }
            rows.append(field("Base branch", base, height: 28))
        } else if d.workspaceMode == .existingWorktree {
            let path = InputView(placeholder: "/path/to/checkout", text: d.existingWorktreePath)
            path.onChange = { [weak e] t in e?.draft.existingWorktreePath = t }
            rows.append(field("Checkout path", path, height: 32))
        }
        // Prompt.
        let prompt = TextareaView(placeholder: "What should the agent do each time this runs?", text: d.prompt)
        prompt.onChange = { [weak e] t in e?.draft.prompt = t }
        rows.append(field("Prompt", prompt, height: max(66, min(256, prompt.intrinsicContentSize.height))))
        // Model.
        let model = ScheduledTaskModelPicker(editor: e)
        rows.append(field("Model", UsageLeadingView(model), height: 28))
        // Schedule.
        if case .interval(let ms) = e.task?.schedule, ms < ScheduledTaskLogic.minIntervalMs {
            rows.append(text("This task uses a legacy interval below one minute. Saving updates it to at least one minute.", color: Themed.color(\.mutedForeground)))
        }
        let scheduleModes: [ScheduledTaskDraft.ScheduleMode] = [.fixed, .interval, .webhook]
        let toggle = ToggleGroupView(variant: .segmented, items: [("At a time", nil), ("Every interval", nil), ("On webhook", nil)],
                                     selected: scheduleModes.firstIndex(of: d.scheduleMode))
        toggle.setAccessibilityLabel("Schedule type")
        toggle.onChange = { [weak e, weak toggle] i in
            guard let e else { return }
            guard let i else { toggle?.selectedIndex = scheduleModes.firstIndex(of: e.draft.scheduleMode); return }
            e.draft.scheduleMode = scheduleModes[i]
            if scheduleModes[i] == .webhook, e.draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                e.draft.prompt = ScheduledTaskLogic.defaultWebhookPrompt
            }
            e.changed()
        }
        let scheduleHeader = ScheduledTaskInlineRow([FormLabel.make("Schedule")], trailing: [toggle])
        rows.append((scheduleHeader, 32))
        switch d.scheduleMode {
        case .webhook:
            let w = ScheduledTaskWebhookField(editor: e)
            webhookField = w
            rows.append((w, w.height))
            rows.append(text("Each request runs the prompt. Use {{body.path}}, {{headers.name}}, {{query.name}}, {{body}} or {{request}} in the prompt; only what it names reaches the agent.",
                             color: Themed.color(\.mutedForeground), size: 12))
            let age = InputView(placeholder: "Run every request", text: d.maxDeliveryAgeMinutes)
            age.onChange = { [weak e] t in e?.draft.maxDeliveryAgeMinutes = t }
            rows.append(field("Skip requests older than", hint: "minutes, optional", age, height: 32))
            let sig = SwitchView(isOn: d.signatureEnabled)
            sig.onChange = { [weak e] on in e?.draft.signatureEnabled = on; e?.changed() }
            rows.append(switchRow("Require signature", "Reject requests without a valid HMAC-SHA256 signature of the body.", sig))
            if d.signatureEnabled {
                let header = InputView(text: d.signatureHeader)
                header.onChange = { [weak e] t in e?.draft.signatureHeader = t }
                let prefix = InputView(placeholder: "None", text: d.signaturePrefix)
                prefix.onChange = { [weak e] t in e?.draft.signaturePrefix = t }
                let encoding = SelectView(options: ["hex", "base64"], selected: d.signatureEncoding == "base64" ? 1 : 0, size: .sm)
                encoding.onChange = { [weak e] i in e?.draft.signatureEncoding = i == 1 ? "base64" : "hex" }
                let secret = SecureInputView()
                secret.placeholder = e.liveTask?.webhook?.hasSecret == true ? "Unchanged" : "Shared secret"
                secret.onChange = { [weak e] t in e?.draft.signatureSecret = t }
                rows.append((ScheduledTaskPairView(field("Header", header, height: 32), field("Prefix", prefix, height: 32)), 54))
                rows.append((ScheduledTaskPairView(field("Encoding", encoding, height: 28), field("Secret", secret, height: 32)), 54))
            }
        case .fixed:
            let time = InputView(placeholder: "09:00", text: d.timeOfDay)
            time.onChange = { [weak e] t in e?.draft.timeOfDay = t }
            let days = ScheduledTaskWeekdaysView(selected: d.weekdays) { [weak e] set in e?.draft.weekdays = set }
            let runAt = LabelView("Run at", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastForeground))
            runAt.lineHeight = 16
            let on = LabelView("on", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            on.lineHeight = 16
            time.frame.size.width = 128
            let timeRow = ScheduledTaskInlineRow([runAt, ScheduledTaskSized(time, width: 128), on, days], trailing: [])
            timeRow.gapAfter = [2: 12]
            rows.append((timeRow, 32))
        case .interval:
            let every = InputView(text: d.intervalMinutes)
            every.onChange = { [weak e] t in e?.draft.intervalMinutes = t }
            let runEvery = LabelView("Run every", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastForeground))
            runEvery.lineHeight = 16
            let minutes = LabelView("minutes", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            minutes.lineHeight = 16
            rows.append((ScheduledTaskInlineRow([runEvery, ScheduledTaskSized(every, width: 96), minutes], trailing: []), 32))
        }
        let enabled = SwitchView(isOn: d.enabled)
        enabled.onChange = { [weak e] on in e?.draft.enabled = on }
        rows.append(switchRow("Enabled", "Disabled tasks stay saved but do not run.", enabled))
        d = e.draft
        rows.forEach { document.addSubview($0.view) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func switchRow(_ title: String, _ detail: String, _ control: SwitchView) -> (NSView, CGFloat) {
        let v = ScheduledTaskSwitchRow(title, detail: detail, control: control)
        return (v, v.height(forWidth: 528))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        var y: CGFloat = 0
        for r in rows {
            r.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: r.height)
            y += r.height + 20
        }
    }
}

/// Two fields side by side (`grid gap-3 sm:grid-cols-2`).
final class ScheduledTaskPairView: DSView {
    private let a: (NSView, CGFloat), b: (NSView, CGFloat)
    init(_ a: (NSView, CGFloat), _ b: (NSView, CGFloat)) {
        self.a = a; self.b = b
        super.init(frame: .zero)
        addSubview(a.0); addSubview(b.0)
    }
    override func layout() {
        super.layout()
        let w = (bounds.width - 12) / 2
        a.0.frame = NSRect(x: 0, y: 0, width: w, height: a.1)
        b.0.frame = NSRect(x: w + 12, y: 0, width: w, height: b.1)
    }
}

/// A fixed-width control in an inline row.
final class ScheduledTaskSized: DSView {
    let content: NSView
    let width: CGFloat
    init(_ content: NSView, width: CGFloat) { self.content = content; self.width = width; super.init(frame: .zero); addSubview(content) }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: content.intrinsicContentSize.height) }
    override func layout() { super.layout(); content.frame = bounds }
}

/// A view kept at its intrinsic width at the start of its frame.
final class UsageLeadingView: DSView {
    let content: NSView
    init(_ content: NSView) { self.content = content; super.init(frame: .zero); addSubview(content) }
    override func layout() {
        super.layout()
        let s = content.intrinsicContentSize
        content.frame = NSRect(x: 0, y: 0, width: min(bounds.width, s.width), height: bounds.height)
    }
}

/// Items in a row `gap-2` centered vertically; `trailing` items sit at the end.
final class ScheduledTaskInlineRow: DSView {
    private let leading: [NSView], trailing: [NSView]
    /// A wider gap after a leading item (`gap-3` between the time group and the weekdays).
    var gapAfter: [Int: CGFloat] = [:]
    init(_ leading: [NSView], trailing: [NSView]) {
        self.leading = leading; self.trailing = trailing
        super.init(frame: .zero)
        (leading + trailing).forEach(addSubview)
    }
    private func size(_ v: NSView) -> NSSize {
        if let l = v as? LabelView { return NSSize(width: ceil(l.textWidth) + 1, height: 16) }
        let s = v.intrinsicContentSize
        return NSSize(width: s.width > 0 ? s.width : 120, height: s.height > 0 ? s.height : 28)
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (i, v) in leading.enumerated() {
            let s = size(v)
            v.frame = NSRect(x: x, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            x += s.width + (gapAfter[i] ?? 8)
        }
        var r = bounds.width
        for v in trailing.reversed() {
            let s = size(v)
            r -= s.width
            v.frame = NSRect(x: r, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            r -= 8
        }
        // A lone leading field before trailing items takes the space left.
        if leading.count == 1, !trailing.isEmpty, !(leading[0] is LabelView) {
            leading[0].frame.size.width = max(0, r - 4)
        }
    }
}

/// Days to run: `ToggleGroup multiple variant="outline" size="sm"`, Monday first, joined; the last day stays on.
final class ScheduledTaskWeekdaysView: DSView {
    private var selected: Set<Int>
    private let onChange: (Set<Int>) -> Void
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }
    private let font = DSFont.ui(14, weight: .medium)
    private var tracking: NSTrackingArea?

    init(selected: Set<Int>, onChange: @escaping (Set<Int>) -> Void) {
        self.selected = selected
        self.onChange = onChange
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Days to run")
    }

    override var wantsUpdateLayer: Bool { false }

    /// Each toggle: `h-7 min-w-7 px-[5px]` around its two letters; only the group's outer edges keep a border
    /// (`border-s-0` and `border-e-0` inside), so neighbours butt together.
    private func frames() -> [CGRect] {
        let n = ScheduledTaskLogic.weekdayOrder.count
        var x: CGFloat = 0
        return ScheduledTaskLogic.weekdayOrder.enumerated().map { i, day in
            let borders: CGFloat = (i == 0 ? 1 : 0) + (i == n - 1 ? 1 : 0)
            let w = max(28, ceil(UsageText.width(ScheduledTaskLogic.weekdayShort[day], font)) + 10 + borders)
            let r = CGRect(x: x, y: 0, width: w, height: 28)
            x += w
            return r
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: frames().last?.maxX ?? 0, height: 28) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func index(_ event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return frames().firstIndex { p.x >= $0.minX && p.x < $0.maxX }
    }

    override func mouseMoved(with event: NSEvent) { hover = index(event) }
    override func mouseExited(with event: NSEvent) { hover = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(event) else { return }
        let day = ScheduledTaskLogic.weekdayOrder[i]
        var next = selected
        if next.contains(day) { next.remove(day) } else { next.insert(day) }
        // The last day stays on (`if (values.length === 0) return`).
        guard !next.isEmpty else { return }
        selected = next
        needsDisplay = true
        onChange(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.isDark
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = CGPath(roundedRect: outer, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        // `border-input bg-background shadow-xs/5`, `dark:bg-input/32`.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: Themed.black(0.05).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor((dark ? Themed.color(\.input, 0.32) : WindowGlass.paneFill).cgColor(in: self))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        for (i, r) in frames().enumerated() {
            let day = ScheduledTaskLogic.weekdayOrder[i]
            let pressed = selected.contains(day)
            if pressed || hover == i {
                let fill: NSColor = pressed ? (dark ? Themed.color(\.input) : Themed.color(\.input, 0.64))
                    : dark ? Themed.color(\.input, 0.64) : Themed.color(\.accent)
                ctx.setFillColor(fill.cgColor(in: self))
                ctx.fill(r)
            }
            UsageText.draw(ctx, ScheduledTaskLogic.weekdayShort[day], font: font,
                           color: Themed.color(pressed ? \.accentForeground : \.foreground), in: CGRect(x: r.minX, y: 4, width: r.width, height: 20),
                           lineHeight: 20, align: .center)
        }
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(Themed.color(\.input).cgColor(in: self))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

/// The model trigger: the composer's control opening the model picker over this environment's providers.
final class ScheduledTaskModelPicker: DSView {
    let button = ComposerControlView()
    private weak var editor: ScheduledTaskEditor?
    private weak var popup: OpenPopup?

    init(editor: ScheduledTaskEditor) {
        self.editor = editor
        super.init(frame: .zero)
        button.tintsIcon = false
        button.action = { [weak self] in self?.open() }
        addSubview(button)
        refresh()
    }

    private var catalog: ProviderCatalog { editor?.catalog ?? ProviderCatalog([]) }

    func refresh() {
        guard let editor else { return }
        if let sel = editor.activeSelection, let entry = catalog.entry(ProviderInstanceId(rawValue: sel.instanceId)) {
            button.title = entry.models.first { $0.slug == sel.model }.map(ModelNames.trigger) ?? sel.model
            button.icon = ProviderIcon.make(driver: entry.driver, displayName: entry.displayName, size: 16, color: Themed.color(\.contrastMutedForeground))
        } else {
            button.title = "No providers available"
            button.icon = nil
        }
        button.isEnabled = editor.connected
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: button.intrinsicContentSize.width, height: 28) }
    override func layout() { super.layout(); button.frame = bounds }

    private func open() {
        guard let editor, let host = button.popupHost, let sel = editor.activeSelection else { return }
        let view = ModelPickerView(catalog: catalog, favorites: [], active: ProviderInstanceId(rawValue: sel.instanceId), activeModel: sel.model)
        view.onSelect = { [weak self] id, model in
            guard let self else { return }
            if let popup = self.popup { self.button.popupHost?.close(popup) }
            self.editor?.draft.modelKey = "\(id.rawValue):\(model)"
            self.refresh()
            self.superview?.needsLayout = true
        }
        popup = host.open(PickerPopupView(view), trigger: button, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .end),
                          motion: .popover)
        button.window?.makeFirstResponder(view.search)
    }
}

/// `WebhookEndpointField`: the URL with Copy and Rotate and the note on who can reach it; before the first
/// save, "The URL appears after you save."
final class ScheduledTaskWebhookField: DSView {
    private weak var editor: ScheduledTaskEditor?
    private let input = InputView()
    private let copy = ButtonView("Copy", icon: .copy, variant: .outline, size: .sm)
    private let rotate = ButtonView("Rotate", variant: .outline, size: .sm)
    private let note = TextBlockView()
    private let placeholder = TextBlockView()
    private var address = ""

    init(editor: ScheduledTaskEditor) {
        self.editor = editor
        super.init(frame: .zero)
        input.setAccessibilityLabel("Webhook URL")
        // ponytail: the URL field takes edits that go nowhere; T3's is readOnly. Add a readOnly flag to FieldView if it confuses
        note.font = DSFont.ui(12); note.lineHeight = 16; note.color = Themed.color(\.mutedForeground)
        placeholder.font = DSFont.ui(14); placeholder.lineHeight = 20; placeholder.color = Themed.color(\.mutedForeground)
        placeholder.text = "The URL appears after you save."
        for v in [input, copy, rotate, note, placeholder] as [NSView] { addSubview(v) }
        copy.action = { [weak self] in
            guard let self, let e = self.editor else { return }
            e.context.copy?(self.address, "Webhook URL copied")
            self.copy.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copy.title = "Copy" }
        }
        rotate.action = { [weak self] in self?.editor?.rotate() }
        refresh()
    }

    private var endpoint: ScheduledTaskWebhookEndpoint? { editor?.liveTask?.webhook }

    var height: CGFloat { endpoint == nil ? 20 : 32 + (note.text.isEmpty ? 0 : 6 + 16) }

    func refresh() {
        guard let e = editor, let ep = endpoint else {
            for v in [input, copy, rotate, note] as [NSView] { v.isHidden = true }
            placeholder.isHidden = false
            return
        }
        placeholder.isHidden = true
        let a = ScheduledTaskLogic.webhookAddress(ep, httpBaseURL: e.context.httpBaseURL?(e.environmentId))
        address = a.address
        input.text = a.address
        copy.isEnabled = a.copyable
        note.text = a.note ?? ""
        for v in [input, copy, rotate] as [NSView] { v.isHidden = false }
        note.isHidden = a.note == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        placeholder.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        let rw = rotate.intrinsicContentSize.width, cw = copy.intrinsicContentSize.width
        rotate.frame = NSRect(x: bounds.width - rw, y: 2, width: rw, height: 28)
        copy.frame = NSRect(x: rotate.frame.minX - 8 - cw, y: 2, width: cw, height: 28)
        input.frame = NSRect(x: 0, y: 0, width: max(0, copy.frame.minX - 8), height: 32)
        note.frame = NSRect(x: 0, y: 38, width: bounds.width, height: 16)
    }
}

// MARK: - Deliveries

/// `WebhookDeliveriesDialog`: recent requests (outcome badge, method, when, empty placeholders), and one
/// request's detail: outcome, the prompt it produced, headers, query and body. Refresh, Back and Done.
@MainActor
final class ScheduledTaskDeliveriesDialog {
    let context: SettingsPageContext
    let environmentId: String
    let task: ScheduledTask
    private let dialog: DialogView
    private let body = ScheduledTaskDeliveriesBody()
    private let refresh = ButtonView("Refresh", variant: .outline, size: .sm)
    private let back = ButtonView("Back", variant: .outline, size: .sm)
    private let done = ButtonView("Done", size: .sm)
    private var host: ModalHost?
    private var deliveries: [ScheduledTaskWebhookDelivery]?
    private var selected: ScheduledTaskWebhookDelivery?
    private var selectedId: String?
    private var error: String?

    init(context: SettingsPageContext, environmentId: String, task: ScheduledTask) {
        self.context = context
        self.environmentId = environmentId
        self.task = task
        dialog = DialogView(title: "Deliveries · \(task.title)", message: "Recent requests to this task's webhook URL.")
        dialog.maxWidth = 672
        dialog.panelContent = [body]
        refresh.action = { [weak self] in self?.load() }
        back.action = { [weak self] in self?.selectedId = nil; self?.selected = nil; self?.render() }
        done.action = { [weak self] in self?.host?.close() }
        body.onSelect = { [weak self] id in self?.open(id) }
    }

    func present() {
        host = context.presentDialog?(dialog)
        if let h = host {
            let key = ObjectIdentifier(self)
            ScheduledTaskEditor.live[key] = self
            let previous = h.onDismiss
            h.onDismiss = { previous?(); ScheduledTaskEditor.live[key] = nil }
        }
        render()
        load()
    }

    private func load() {
        guard let request = context.request else { return }
        refresh.isEnabled = false
        let env = environmentId, id = task.id
        Task { [weak self] in
            do {
                let r = try await request(env, "scheduledTasks.listWebhookDeliveries", .object(["id": .string(id)]))
                self?.deliveries = (r["deliveries"]?.arrayValue ?? []).compactMap(ScheduledTaskWebhookDelivery.init(json:))
                self?.error = nil
            } catch { self?.error = ScheduledTaskErrorText.message(error) }
            self?.refresh.isEnabled = true
            self?.render()
        }
    }

    private func open(_ deliveryId: String) {
        guard let request = context.request else { return }
        selectedId = deliveryId
        selected = nil
        render()
        let env = environmentId, id = task.id
        Task { [weak self] in
            do {
                let r = try await request(env, "scheduledTasks.getWebhookDelivery", .object(["id": .string(id), "deliveryId": .string(deliveryId)]))
                self?.selected = r["delivery"].flatMap(ScheduledTaskWebhookDelivery.init(json:))
            } catch { self?.error = ScheduledTaskErrorText.message(error) }
            self?.render()
        }
    }

    private func render() {
        let nowMs = TimestampFormat.nowMs()
        if let d = selected { body.showDetail(d, nowMs: nowMs) }
        else if selectedId != nil { body.showMessage(error ?? "Loading delivery…", error: error != nil) }
        else if let error { body.showMessage(error, error: true) }
        else if let list = deliveries { list.isEmpty ? body.showMessage("No requests yet.", error: false) : body.showList(list, nowMs: nowMs) }
        else { body.showMessage("Loading deliveries…", error: false) }
        dialog.footerButtons = [selectedId != nil ? back : refresh, done]
        dialog.panelContent = [body]
        host?.needsLayout = true
    }
}

final class ScheduledTaskDeliveriesBody: DSView {
    var onSelect: ((String) -> Void)?
    private var parts: [(NSView, CGFloat)] = []

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: parts.reduce(0) { $0 + $1.1 } + 16 * CGFloat(max(0, parts.count - 1))) }

    private func reset() { parts.forEach { $0.0.removeFromSuperview() }; parts = [] }
    private func add(_ v: NSView, _ h: CGFloat) { addSubview(v); parts.append((v, h)); invalidateIntrinsicContentSize(); needsLayout = true }

    private func paragraph(_ s: String, color: NSColor) -> (NSView, CGFloat) {
        let t = TextBlockView()
        t.text = s; t.font = DSFont.ui(14); t.lineHeight = 20; t.color = color
        return (t, t.height(forWidth: 624))
    }

    func showMessage(_ s: String, error: Bool) {
        reset()
        let p = paragraph(s, color: Themed.color(error ? \.destructive : \.mutedForeground))
        add(p.0, p.1)
    }

    func showList(_ list: [ScheduledTaskWebhookDelivery], nowMs: Int64) {
        reset()
        let v = ScheduledTaskDeliveryListView(list, nowMs: nowMs) { [weak self] id in self?.onSelect?(id) }
        add(v, CGFloat(list.count) * 37)
    }

    func showDetail(_ d: ScheduledTaskWebhookDelivery, nowMs: Int64) {
        reset()
        let head = ScheduledTaskInlineRow([BadgeView(ScheduledTaskLogic.outcomeLabel(d.outcome), variant: BadgeView.Variant(rawValue: ScheduledTaskLogic.outcomeTone(d.outcome)) ?? .error),
                                           plain("\(d.method) · \(ScheduledTaskLogic.relativeLabel(d.receivedAt, nowMs: nowMs))", Themed.color(\.foreground))]
                                          + (d.signatureVerified ? [plain("Signature verified", Themed.color(\.mutedForeground))] : []), trailing: [])
        add(head, 20)
        if let e = d.error { let p = paragraph(e, color: Themed.color(\.destructive)); add(p.0, p.1) }
        block("Prompt sent to the agent", d.renderedPrompt ?? "No run was started for this request.")
        if !d.missingFields.isEmpty { let p = paragraph("Empty placeholders: \(d.missingFields.joined(separator: ", "))", color: Themed.color(\.mutedForeground)); add(p.0, p.1) }
        block("Headers", d.headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        if !d.query.isEmpty { block("Query", d.query) }
        block(d.bodyTruncated ? "Body (truncated)" : "Body", d.body.isEmpty ? "(empty)" : d.body)
    }

    private func plain(_ s: String, _ c: NSColor) -> LabelView { let l = LabelView(s, font: DSFont.ui(14), color: c); l.lineHeight = 20; return l }

    /// `DeliveryBlock`: a label over a `bg-muted rounded-md p-2 text-xs` pre, at most 256pt.
    private func block(_ title: String, _ text: String) {
        let v = DSView()
        let l = FormLabel.make(title)
        let box = BoxView()
        var s = BoxStyle(); s.radius = 6; s.fill = Themed.color(\.muted); box.boxStyle = s
        let t = TextBlockView()
        t.text = text; t.font = DSFont.mono(12); t.lineHeight = 16; t.color = Themed.color(\.foreground)
        let th = min(256 - 16, t.height(forWidth: 624 - 16))
        v.addSubview(l); v.addSubview(box); box.addSubview(t)
        l.frame = NSRect(x: 0, y: 0, width: 400, height: 16)
        box.frame = NSRect(x: 0, y: 20, width: 624, height: th + 16)
        box.autoresizingMask = [.width]
        box.clipsToBounds = true
        t.frame = NSRect(x: 8, y: 8, width: 624 - 16, height: th)
        t.autoresizingMask = [.width]
        add(v, 20 + th + 16)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for p in parts {
            p.0.frame = NSRect(x: 0, y: y, width: bounds.width, height: p.1)
            y += p.1 + 16
        }
    }
}

/// The delivery rows (`divide-y`, `py-2`, hover `bg-accent/40`).
final class ScheduledTaskDeliveryListView: DSView {
    private var rows: [ScheduledTaskInlineRow] = []
    private let ids: [String]
    private let onSelect: (String) -> Void
    private var hover: Int? { didSet { needsDisplay = true } }

    init(_ list: [ScheduledTaskWebhookDelivery], nowMs: Int64, onSelect: @escaping (String) -> Void) {
        ids = list.map(\.id)
        self.onSelect = onSelect
        super.init(frame: .zero)
        rows = list.map { d in
            func l(_ s: String, _ c: NSColor) -> LabelView { let x = LabelView(s, font: DSFont.ui(14), color: c); x.lineHeight = 20; return x }
            var items: [NSView] = [BadgeView(ScheduledTaskLogic.outcomeLabel(d.outcome), variant: BadgeView.Variant(rawValue: ScheduledTaskLogic.outcomeTone(d.outcome)) ?? .error),
                                   l(d.method, Themed.color(\.foreground)), l(ScheduledTaskLogic.relativeLabel(d.receivedAt, nowMs: nowMs), Themed.color(\.mutedForeground))]
            if !d.missingFields.isEmpty {
                items.append(l("\(d.missingFields.count) empty placeholder\(d.missingFields.count == 1 ? "" : "s")", Themed.color(\.mutedForeground)))
            }
            let r = ScheduledTaskInlineRow(items, trailing: [])
            addSubview(r)
            return r
        }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
    }

    override var wantsUpdateLayer: Bool { false }
    override func layout() { super.layout(); for (i, r) in rows.enumerated() { r.frame = NSRect(x: 0, y: CGFloat(i) * 37 + 8, width: bounds.width, height: 20) } }
    override func mouseMoved(with event: NSEvent) { hover = Int(convert(event.locationInWindow, from: nil).y / 37) }
    override func mouseExited(with event: NSEvent) { hover = nil }
    override func mouseUp(with event: NSEvent) {
        let i = Int(convert(event.locationInWindow, from: nil).y / 37)
        if i >= 0, i < ids.count { onSelect(ids[i]) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let h = hover, h < rows.count {
            ctx.setFillColor(Themed.color(\.accent, 0.4).cgColor(in: self))
            ctx.fill(CGRect(x: 0, y: CGFloat(h) * 37, width: bounds.width, height: 36))
        }
        ctx.setFillColor(Themed.color(\.border).cgColor(in: self))
        for i in 1..<max(1, rows.count) { ctx.fill(CGRect(x: 0, y: CGFloat(i) * 37 - 1, width: bounds.width, height: 1)) }
    }
}

/// `Field`: a label (and a hint at its end) 6pt over its control, all at the field's width.
final class ScheduledTaskFieldView: DSView {
    private let label: LabelView
    private let hint: LabelView?
    let control: NSView
    private let controlHeight: CGFloat
    init(_ text: String, hint: String?, control: NSView, controlHeight: CGFloat) {
        label = FormLabel.make(text)
        self.hint = hint.map { h in
            let l = LabelView(h, font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.8))
            l.lineHeight = 16
            l.alignment = .right
            return l
        }
        self.control = control
        self.controlHeight = controlHeight
        super.init(frame: .zero)
        addSubview(label)
        self.hint.map(addSubview)
        addSubview(control)
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: ceil(label.textWidth) + 1, height: 16)
        hint?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        control.frame = NSRect(x: 0, y: 22, width: bounds.width, height: controlHeight)
    }
}

/// A label and its description beside a switch (`flex items-center justify-between gap-4`).
final class ScheduledTaskSwitchRow: DSView {
    private let title: LabelView
    private let detail = TextBlockView()
    private let control: SwitchView
    init(_ text: String, detail d: String, control: SwitchView) {
        title = FormLabel.make(text)
        self.control = control
        super.init(frame: .zero)
        detail.text = d; detail.font = DSFont.ui(14); detail.lineHeight = 20; detail.color = Themed.color(\.mutedForeground)
        for v in [title, detail, control] as [NSView] { addSubview(v) }
    }
    func height(forWidth width: CGFloat) -> CGFloat { 20 + detail.height(forWidth: max(0, width - 16 - control.intrinsicContentSize.width)) }
    override func layout() {
        super.layout()
        let s = control.intrinsicContentSize
        let tw = max(0, bounds.width - 16 - s.width)
        title.frame = NSRect(x: 0, y: 0, width: tw, height: 16)
        detail.frame = NSRect(x: 0, y: 20, width: tw, height: detail.height(forWidth: tw))
        control.frame = NSRect(x: bounds.width - s.width, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
    }
}
