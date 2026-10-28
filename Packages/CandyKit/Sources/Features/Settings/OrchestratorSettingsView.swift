import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's Orchestrator tab (docs/orchestrator.md, "The Orchestrator settings tab"), shown only while the toggle is on.
/// Everything on it lives in `OrchestratorStore`, CandyWrapper's own defaults; nothing goes to the server's settings.
public final class OrchestratorSettingsView: SettingsPageBase {
    private var store: OrchestratorStore { .shared }
    private var config: OrchestratorConfig { store.config }
    private var observer: Int?
    private let models = OrchestratorModelsList()

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        items = [orchestratorSection(), modelsSection(), promptSection(), notebookSection()]
        observer = store.observe { [weak self] in self?.refresh() }
        actionsObserver = store.observeActions { [weak self] in self?.refresh() }
    }

    private var actionsObserver: Int?

    isolated deinit {
        observer.map { OrchestratorStore.shared.removeObserver($0) }
        actionsObserver.map { OrchestratorStore.shared.removeObserver($0) }
    }

    // MARK: Machine and limits

    /// The machines the composer's Run on offers.
    private var machines: [SettingsScopeEnvironment] { context.scope.environments }
    private var machineId: String? { config.environmentId ?? context.scope.primaryId ?? machines.first?.id }
    private var projects: [SettingsScopeProject.Member] {
        context.scope.projects.flatMap(\.members).filter { $0.environmentId == machineId }
    }

    private func orchestratorSection() -> SettingsSectionView {
        let nameInput = InputView(placeholder: "Orchestrator", text: config.name, size: .sm)
        nameInput.frame.size = NSSize(width: 200, height: 28)
        nameInput.setAccessibilityLabel("Orchestrator name")
        nameInput.onChange = { [weak self] text in self?.store.update { $0.name = text } }
        let nameRow = row(nil, title: "Name", detail: "What it's called in the sidebar, its chat and its brief. A rename goes out as an updated brief with your next message.",
                          control: nameInput)
        binder.add { [weak self, weak nameInput] in
            guard let self, let nameInput, !nameInput.state.focused, nameInput.text != self.config.name else { return }
            nameInput.text = self.config.name
        }
        let start = ButtonView("Start", variant: .outline, size: .sm)
        start.action = { [weak self] in self?.store.actions.start?() }
        let status = row(nil, title: "Status", detail: nil, control: start)
        binder.add { [weak self, weak status, weak start] in
            guard let self else { return }
            status?.detail = self.store.actions.status?() ?? "Not started"
            let running = self.machineId.flatMap { self.config.machines[$0] } != nil
            start?.title = running ? "Open" : "Start"
            start?.isEnabled = self.machineId.map { id in self.machines.contains { $0.id == id && $0.connected } } ?? false
        }

        let machine = settingsSelect([], width: 200, hideIndicator: false)
        machine.setAccessibilityLabel("Machine")
        let machineRow = row(nil, title: "Machine", detail: "Where its thread runs. It keeps working there while CandyWrapper is closed, and it manages only that machine's threads.",
                             control: machine)
        machine.onChange = { [weak self] i in
            guard let self, self.machines.indices.contains(i) else { return }
            let id = self.machines[i].id
            self.store.update { $0.environmentId = id; $0.homeProjectId = nil }
        }
        binder.add { [weak self, weak machine] in
            guard let self, let machine else { return }
            machine.options = self.machines.map { $0.connected ? $0.label : "\($0.label) (offline)" }
            machine.selectedIndex = self.machines.firstIndex { $0.id == self.machineId }
        }

        let project = settingsSelect([], width: 200, hideIndicator: false)
        project.setAccessibilityLabel("Project")
        let projectRow = row(nil, title: "Home project", detail: "The project its own thread sits in. It still sees and works in every project.", control: project)
        project.onChange = { [weak self] i in
            guard let self, self.projects.indices.contains(i) else { return }
            let id = self.projects[i].projectId
            self.store.update { $0.homeProjectId = id }
        }
        binder.add { [weak self, weak project] in
            guard let self, let project else { return }
            let list = self.projects
            project.options = list.map(\.title)
            project.selectedIndex = list.firstIndex { $0.projectId == self.config.homeProjectId } ?? (list.isEmpty ? nil : 0)
            project.placeholder = list.isEmpty ? "No projects" : "Choose"
        }

        let limits = Array(1...8)
        let crew = choiceRow("Worker limit", "How many workers it runs at once.", labels: limits.map { "\($0)" },
                             read: { limits.firstIndex(of: $0.crewLimit) }, write: { c, i in c.crewLimit = limits[i] })
        let askChoices = [0, 5, 10, 15, 30]
        let ask = choiceRow("Ask first", "It asks you before prompting a thread you wrote in this recently.",
                            labels: askChoices.map { $0 == 0 ? "Never" : "\($0) minutes" },
                            read: { askChoices.firstIndex(of: $0.askFirstMinutes) }, write: { c, i in c.askFirstMinutes = askChoices[i] })
        let closedChoices: [Int?] = [nil, 15, 30, 60, 120]
        let closed = choiceRow("While closed", "A scheduled task on its machine wakes it to check every thread. It's off while CandyWrapper is open.",
                               labels: ["Off", "Every 15 minutes", "Every 30 minutes", "Every hour", "Every 2 hours"],
                               read: { c in closedChoices.firstIndex { $0 == c.closedCheckMinutes } }, write: { c, i in c.closedCheckMinutes = closedChoices[i] })
        // The helper relays all the time and keeps the check off, so the setting rests while it's connected. It keeps
        // its value and comes back when the helper stops.
        binder.add { [weak self, weak closed] in
            let handled = self?.helperHandles == true
            closed?.inertReason = handled ? Self.helperHandled : nil
            closed?.status = handled ? Self.helperHandled : nil
        }
        let picker = OrchestratorBotPicker()
        picker.onPick = { [weak self] identity in
            self?.store.update { $0.botShape = identity.shape.rawValue; $0.botColor = identity.color.rawValue }
        }
        binder.add { [weak self, weak picker] in if let self { picker?.identity = self.config.bot } }
        let lookRow = row(nil, title: "Look", detail: "Its bot's shape and colour, in the sidebar and its chat. The pumpkin is always orange.")
        lookRow.footer = picker
        var rows = [nameRow, lookRow, status, machineRow, projectRow, crew, ask, closed]
        if store.actions.helper != nil { rows.append(helperRow()) }
        return section(nil, "Orchestrator", rows)
    }

    /// The CandyWrapper Helper (docs/orchestrator-helper.md): its state, and one button to install, update or reinstall
    /// it on the Orchestrator's machine, with Remove once it's there.
    private func helperRow() -> SettingsRowView {
        let primary = ButtonView("Install", variant: .outline, size: .sm)
        primary.action = { [weak self] in self?.store.actions.installHelper?() }
        let remove = ButtonView("Remove", variant: .ghost, size: .sm)
        remove.action = { [weak self] in self?.store.actions.removeHelper?() }
        let buttons = ButtonPair(primary, remove)
        let r = row(nil, title: "Helper", detail: nil, control: buttons)
        binder.add { [weak self, weak r, weak primary, weak remove, weak buttons] in
            guard let state = self?.store.actions.helper?() else { return }
            r?.detail = state.status
            primary?.title = state.primary
            primary?.isEnabled = state.canRun
            remove?.isHidden = !state.installed
            remove?.isEnabled = state.canRun
            // The row sizes its control from the intrinsic width, so it lays out again when Remove comes or goes.
            buttons?.invalidateIntrinsicContentSize()
            r?.needsLayout = true
        }
        return r
    }

    static let helperHandled = "Handled by the Helper while it's running."
    /// The helper is connected on the Orchestrator's machine, so it relays instead of this Mac and its schedule.
    var helperHandles: Bool { store.actions.helper?()?.connected == true }

    private func choiceRow(_ title: String, _ detail: String, labels: [String], read: @escaping (OrchestratorConfig) -> Int?,
                           write: @escaping (inout OrchestratorConfig, Int) -> Void) -> SettingsRowView {
        let select = settingsSelect(labels, width: 180, hideIndicator: false)
        select.setAccessibilityLabel(title)
        select.onChange = { [weak self] i in self?.store.update { write(&$0, i) } }
        binder.add { [weak self, weak select] in
            guard let self else { return }
            select?.selectedIndex = read(self.config)
        }
        return row(nil, title: title, detail: detail, control: select)
    }

    // MARK: Models

    private func modelsSection() -> SettingsSectionView {
        let add = ButtonView("Add model", icon: .plus, variant: .ghost, size: .sm)
        add.action = { [weak self] in self?.editModel(nil) }
        models.onEdit = { [weak self] row in self?.editModel(row) }
        models.onChange = { [weak self] rows in self?.store.update { $0.models = rows } }
        models.onHeightChange = { [weak self] in self?.onHeightChange?() }
        binder.add { [weak self] in
            guard let self else { return }
            let catalog = self.catalog
            self.models.set(self.config.models, catalog: catalog, connected: !catalog.entries.isEmpty)
        }
        let s = section(nil, "Models", [models])
        s.headerAction = add
        return s
    }

    /// The machine's live catalog, the same one the composer's model picker reads.
    var catalog: ProviderCatalog {
        guard let id = machineId else { return ProviderCatalog([]) }
        return ProviderCatalog(context.configs[id]?.providers ?? [], settings: machines.first { $0.id == id }?.settings, projectId: nil)
    }

    private func editModel(_ row: OrchestratorModelRow?) {
        let editor = OrchestratorModelEditor(row: row, catalog: catalog, isOnly: config.models.isEmpty) { [weak self] saved in
            self?.store.update { c in
                if saved.isDefault { for i in c.models.indices { c.models[i].isDefault = false } }
                if let i = c.models.firstIndex(where: { $0.id == saved.id }) { c.models[i] = saved } else { c.models.append(saved) }
                if !c.models.contains(where: \.isDefault), !c.models.isEmpty { c.models[0].isDefault = true }
            }
        }
        editor.present(context)
    }

    // MARK: Prompt and notebook

    private func promptSection() -> SettingsSectionView {
        let reset = ButtonView("Reset to default", variant: .outline, size: .sm)
        reset.action = { [weak self] in
            self?.context.confirm?("Reset the Orchestrator's prompt to the default? Your edits are lost.", true) {
                OrchestratorStore.shared.update { $0.prompt = OrchestratorBrief.defaultPrompt }
            }
        }
        let editor = OrchestratorTextEditor(placeholder: "The Orchestrator's prompt")
        editor.onChange = { [weak self] text in self?.store.update { $0.prompt = text } }
        editor.onHeightChange = { [weak self] in self?.onHeightChange?() }
        let r = row(nil, title: "System prompt",
                    detail: "Sent as the first message of its thread. It can use {{name}}, {{machine}}, {{projects}}, {{bots}}, {{models}} and {{crewLimit}}. An edit goes out as an updated brief with your next message.",
                    control: reset)
        r.footer = editor
        binder.add { [weak self, weak reset] in
            guard let self else { return }
            editor.text = self.config.prompt
            reset?.isEnabled = self.config.prompt != OrchestratorBrief.defaultPrompt
        }
        return section(nil, "Prompt", [r])
    }

    private func notebookSection() -> SettingsSectionView {
        let details = [
            "rules": "How you want it to work. It adds your corrections here.",
            "crew-rules": "Rules every worker gets in its first prompt.",
            "plan": "Each goal, its steps and which thread owns each.",
            "digest": "Its last report.",
        ]
        let titles = ["rules": "Rules", "crew-rules": "Worker rules", "plan": "Plan", "digest": "Digest"]
        let rows = OrchestratorNotebook.names.map { name -> SettingsRowView in
            let editor = OrchestratorTextEditor(placeholder: "Empty")
            editor.onChange = { [weak self] text in self?.store.update { $0.notebook[name] = text } }
            editor.onHeightChange = { [weak self] in self?.onHeightChange?() }
            let r = row(nil, title: titles[name] ?? name, detail: details[name])
            r.footer = editor
            binder.add { [weak self] in if let self { editor.text = self.config.notebook[name] } }
            return r
        }
        return section(nil, "Notebook", rows)
    }
}

/// A textarea that sizes to its text up to the textarea's cap, for a row's footer. It keeps what you type while the
/// store echoes it back.
final class OrchestratorTextEditor: DSView, SettingsGroupRow {
    private let input: TextareaView
    var onChange: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    private var lastHeight: CGFloat = 0

    init(placeholder: String) {
        input = TextareaView(placeholder: placeholder)
        super.init(frame: .zero)
        addSubview(input)
        input.setAccessibilityLabel(placeholder)
        input.onChange = { [weak self] t in
            self?.onChange?(t)
            self?.heightMayChange()
        }
    }

    var text: String {
        get { input.text }
        set { if input.text != newValue, !input.state.focused { input.text = newValue; heightMayChange() } }
    }

    private func heightMayChange() {
        let h = input.intrinsicContentSize.height
        if h != lastHeight { lastHeight = h; onHeightChange?() }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        input.setFrameSize(NSSize(width: width, height: input.frame.height))
        return input.intrinsicContentSize.height
    }

    override func layout() {
        super.layout()
        input.frame = NSRect(x: 0, y: 0, width: bounds.width, height: input.intrinsicContentSize.height)
    }
}

/// The Models list: one line per row with its model, options and "use when", a warning when the catalog lacks the
/// model, and Edit, Make default, Up, Down and Delete in its menu.
final class OrchestratorModelsList: DSView, SettingsGroupRow {
    private var rows: [OrchestratorModelRow] = []
    private var views: [OrchestratorModelRowView] = []
    private let empty = TextBlockView()
    var onEdit: ((OrchestratorModelRow) -> Void)?
    var onChange: (([OrchestratorModelRow]) -> Void)?
    var onHeightChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.text = "No models yet. The Orchestrator uses the thread's default model."
        empty.font = DSFont.ui(13)
        empty.color = Themed.color(\.mutedForeground)
        addSubview(empty)
    }

    func set(_ rows: [OrchestratorModelRow], catalog: ProviderCatalog, connected: Bool) {
        self.rows = rows
        views.forEach { $0.removeFromSuperview() }
        views = rows.enumerated().map { i, r in
            let entry = catalog.entry(ProviderInstanceId(rawValue: r.instanceId))
            let model = entry?.model(r.model)
            let v = OrchestratorModelRowView(row: r, modelName: model.map { ModelNames.display($0) } ?? r.model,
                                             provider: entry?.displayName ?? r.instanceId, driver: entry?.driver,
                                             missing: connected && model == nil)
            v.onMenu = { [weak self] anchor in self?.menu(i, anchor) }
            v.onClick = { [weak self] in self?.onEdit?(r) }
            addSubview(v)
            return v
        }
        empty.isHidden = !rows.isEmpty
        needsLayout = true
        onHeightChange?()
    }

    private func menu(_ i: Int, _ anchor: NSView) {
        var items: [MenuItem] = [MenuItem("Edit", icon: .squarePen) { [weak self] in if let self { self.onEdit?(self.rows[i]) } }]
        if !rows[i].isDefault {
            items.append(MenuItem("Make default", icon: .check) { [weak self] in
                guard let self else { return }
                self.onChange?(self.rows.enumerated().map { j, r in var r = r; r.isDefault = j == i; return r })
            })
        }
        if i > 0 { items.append(MenuItem("Move up", icon: .arrowUp) { [weak self] in self?.move(i, by: -1) }) }
        if i < rows.count - 1 { items.append(MenuItem("Move down", icon: .arrowDown) { [weak self] in self?.move(i, by: 1) }) }
        items.append(.separator)
        items.append(MenuItem("Delete", icon: .trash2, destructive: true) { [weak self] in
            guard let self else { return }
            var next = self.rows
            let removed = next.remove(at: i)
            if removed.isDefault, !next.isEmpty { next[0].isDefault = true }
            self.onChange?(next)
        })
        MenuPopupView.show(items, from: anchor, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    private func move(_ i: Int, by d: Int) {
        var next = rows
        next.swapAt(i, i + d)
        onChange?(next)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        rows.isEmpty ? 56 : views.reduce(0) { $0 + $1.height(forWidth: width) }
    }

    override func layout() {
        super.layout()
        empty.frame = NSRect(x: 16, y: 18, width: max(0, bounds.width - 32), height: 20)
        var y: CGFloat = 0
        for v in views {
            let h = v.height(forWidth: bounds.width)
            v.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }
}

final class OrchestratorModelRowView: ControlView {
    private let title = LabelView()
    private let model = LabelView()
    private let useWhen = TextBlockView()
    private let more = ButtonView(icon: .ellipsis, variant: .ghost, size: .iconSm)
    private var icon: NSView?
    var onMenu: ((NSView) -> Void)?
    var onClick: (() -> Void)?

    init(row: OrchestratorModelRow, modelName: String, provider: String, driver: String?, missing: Bool) {
        super.init(frame: .zero)
        title.text = row.isDefault ? "\(row.label) · default" : row.label
        title.font = DSFont.ui(14, weight: .medium)
        title.lineHeight = 20
        let options = row.options.map { o in o.value.string ?? (o.value.bool == true ? "\(o.id) on" : "\(o.id) off") }.joined(separator: ", ")
        model.text = [missing ? "\(modelName) is not in this machine's catalog, so the brief leaves it out" : modelName, options].filter { !$0.isEmpty }.joined(separator: " · ")
        model.font = DSFont.ui(12)
        model.lineHeight = 16
        model.color = missing ? Themed.color(\.warning) : Themed.color(\.mutedForeground)
        useWhen.text = [row.useWhen, row.notes].filter { !$0.isEmpty }.joined(separator: " ")
        useWhen.font = DSFont.ui(12)
        useWhen.lineHeight = 16
        useWhen.color = Themed.color(\.mutedForeground, 0.8)
        if let driver {
            let i = ProviderIcon.make(driver: driver, displayName: provider, size: 16, color: Themed.color(\.contrastMutedForeground))
            icon = i
            addSubview(i)
        }
        for v in [title, model, useWhen, more] as [NSView] { addSubview(v) }
        more.setAccessibilityLabel("Model actions")
        more.action = { [weak self] in if let self { self.onMenu?(self.more) } }
        action = { [weak self] in self?.onClick?() }
        setAccessibilityLabel("\(row.label), \(modelName)")
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        12 + 20 + 16 + (useWhen.text.isEmpty ? 0 : 2 + useWhen.height(forWidth: width - 48 - 44)) + 12
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 16 + 24, w = max(0, bounds.width - x - 44)
        icon?.frame = NSRect(x: 16, y: 14, width: 16, height: 16)
        title.frame = NSRect(x: x, y: 12, width: w, height: 20)
        model.frame = NSRect(x: x, y: 32, width: w, height: 16)
        useWhen.frame = NSRect(x: x, y: 50, width: w, height: useWhen.height(forWidth: w))
        more.frame = NSRect(x: bounds.width - 16 - 24, y: 12, width: 24, height: 24)
    }
}

/// The dialog that adds or edits a Models row: label, a model from the machine's live catalog, that model's own
/// options, "Use when", notes and the default mark.
@MainActor
final class OrchestratorModelEditor {
    private var row: OrchestratorModelRow
    private let catalog: ProviderCatalog
    private let onSave: (OrchestratorModelRow) -> Void
    private let dialog: DialogView
    private let form = OrchestratorModelForm()
    private var host: ModalHost?
    static var live: [ObjectIdentifier: OrchestratorModelEditor] = [:]

    init(row: OrchestratorModelRow?, catalog: ProviderCatalog, isOnly: Bool, onSave: @escaping (OrchestratorModelRow) -> Void) {
        let first = catalog.entries.first { $0.isSelectable }
        self.row = row ?? OrchestratorModelRow(label: "", instanceId: first?.id.rawValue ?? "", model: first?.defaultModel ?? first?.models.first?.slug ?? "",
                                               isDefault: isOnly)
        self.catalog = catalog
        self.onSave = onSave
        dialog = DialogView(title: row == nil ? "Add model" : "Edit model",
                            message: "Pick a model from this machine's catalog and say when the Orchestrator should use it.")
        dialog.maxWidth = 520
        let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
        let save = ButtonView(row == nil ? "Add model" : "Save", size: .sm)
        dialog.footerButtons = [cancel, save]
        dialog.panelContent = [form]
        cancel.action = { [weak self] in self?.host?.close() }
        save.action = { [weak self] in self?.save() }
        form.editor = self
        form.rebuild()
    }

    var draft: OrchestratorModelRow {
        get { row }
        set { row = newValue }
    }

    var entry: ProviderInstanceEntry? { catalog.entry(ProviderInstanceId(rawValue: row.instanceId)) }
    var model: ServerProviderModel? { entry?.model(row.model) }
    var descriptors: [ProviderOptionDescriptor] { ModelTraits.descriptors(model, selections: row.options) }

    func present(_ context: SettingsPageContext) {
        guard let h = context.presentDialog?(dialog) else { return }
        host = h
        let key = ObjectIdentifier(self)
        Self.live[key] = self
        let previous = h.onDismiss
        h.onDismiss = { previous?(); OrchestratorModelEditor.live[key] = nil }
    }

    func pickModel(from trigger: NSView) {
        guard let popupHost = trigger.popupHost else { return }
        let view = ModelPickerView(catalog: catalog, favorites: [], active: ProviderInstanceId(rawValue: row.instanceId), activeModel: row.model)
        var popup: OpenPopup?
        view.onSelect = { [weak self] id, slug in
            guard let self else { return }
            if let popup { popupHost.close(popup) }
            self.row.instanceId = id.rawValue
            self.row.model = slug
            self.row.options = []
            if self.row.label.isEmpty { self.row.label = self.model.map { ModelNames.display($0) } ?? slug }
            self.form.rebuild()
            self.dialog.panelContent = [self.form]
        }
        popup = popupHost.open(PickerPopupView(view), trigger: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .end),
                               motion: .popover)
        trigger.window?.makeFirstResponder(view.search)
    }

    func pick(_ descriptor: ProviderOptionDescriptor, _ value: ProviderOptionValue) {
        row.options = ModelTraits.pick(descriptors, id: descriptor.id, value: value) ?? []
    }

    private func save() {
        row.label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.label.isEmpty { row.label = model.map { ModelNames.display($0) } ?? row.model }
        guard !row.model.isEmpty else { return }
        onSave(row)
        host?.close()
    }
}

final class OrchestratorModelForm: DSView {
    weak var editor: OrchestratorModelEditor?
    private var rows: [(view: NSView, height: CGFloat)] = []

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.reduce(0) { $0 + $1.height } + 16 * CGFloat(max(0, rows.count - 1)))
    }

    func rebuild() {
        rows.forEach { $0.view.removeFromSuperview() }
        rows = []
        guard let e = editor else { return }
        let label = InputView(placeholder: "Heavy work", text: e.draft.label)
        label.onChange = { [weak e] t in e?.draft.label = t }
        rows.append((ScheduledTaskFieldView("Label", hint: nil, control: label, controlHeight: 32), 22 + 32))

        let picker = ComposerControlView()
        picker.tintsIcon = false
        if let entry = e.entry {
            picker.title = e.model.map(ModelNames.trigger) ?? e.draft.model
            picker.icon = ProviderIcon.make(driver: entry.driver, displayName: entry.displayName, size: 16, color: Themed.color(\.contrastMutedForeground))
        } else {
            picker.title = e.draft.model.isEmpty ? "Choose a model" : e.draft.model
        }
        picker.action = { [weak e, weak picker] in if let picker { e?.pickModel(from: picker) } }
        rows.append((ScheduledTaskFieldView("Model", hint: e.entry?.displayName, control: UsageLeadingView(picker), controlHeight: 28), 22 + 28))

        for d in e.descriptors {
            switch d.type {
            case .select:
                let select = SelectView(options: d.options.map(\.label), size: .sm)
                select.fitsContent = true
                select.selectedIndex = d.options.firstIndex { $0.id == ModelTraits.currentValue(d)?.string }
                select.onChange = { [weak e] i in e?.pick(d, .string(d.options[i].id)) }
                rows.append((ScheduledTaskFieldView(d.label, hint: nil, control: UsageLeadingView(select), controlHeight: 28), 22 + 28))
            case .boolean:
                let sw = SwitchView(isOn: ModelTraits.currentValue(d)?.bool ?? false)
                sw.onChange = { [weak e] on in e?.pick(d, .bool(on)) }
                rows.append((ScheduledTaskFieldView(d.label, hint: nil, control: UsageLeadingView(sw), controlHeight: 24), 22 + 24))
            default: break
            }
        }

        let useWhen = TextareaView(placeholder: "Hard tasks: tricky bugs, concurrency, security…", text: e.draft.useWhen)
        useWhen.onChange = { [weak e] t in e?.draft.useWhen = t }
        rows.append((ScheduledTaskFieldView("Use when", hint: nil, control: useWhen, controlHeight: 66), 22 + 66))
        let notes = TextareaView(placeholder: "Slower, but catches subtle bugs.", text: e.draft.notes)
        notes.onChange = { [weak e] t in e?.draft.notes = t }
        rows.append((ScheduledTaskFieldView("Notes", hint: "optional", control: notes, controlHeight: 50), 22 + 50))
        let isDefault = SwitchView(isOn: e.draft.isDefault)
        isDefault.onChange = { [weak e] on in e?.draft.isDefault = on }
        let defaultRow = ScheduledTaskSwitchRow("Default", detail: "Used when nothing else fits, and by the Orchestrator's own thread.", control: isDefault)
        rows.append((defaultRow, defaultRow.height(forWidth: 472)))
        rows.forEach { addSubview($0.view) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows {
            r.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: r.height)
            y += r.height + 16
        }
    }
}

/// The Orchestrator's look, after Grok Bot's "Create New Bot" sheet: a big preview, then every shape in the current
/// colour, then the colour dots.
final class OrchestratorBotPicker: DSView, SettingsGroupRow {
    var identity = BotIdentity.orchestrator { didSet { if identity != oldValue { refresh() } } }
    var onPick: ((BotIdentity) -> Void)?
    private let preview = BotView(identity: .orchestrator, size: 72)
    private var shapes: [OrchestratorBotCell] = []
    private var colors: [OrchestratorColorDot] = []
    static let cell: CGFloat = 36, dot: CGFloat = 22, gap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(preview)
        shapes = BotShape.allCases.map { shape in
            let c = OrchestratorBotCell(BotIdentity(shape: shape, color: identity.color))
            c.setAccessibilityLabel(shape.name)
            c.action = { [weak self] in
                guard let self else { return }
                self.onPick?(BotIdentity(shape: shape, color: self.identity.color))
            }
            addSubview(c)
            return c
        }
        colors = BotColor.allCases.map { color in
            let d = OrchestratorColorDot(color)
            d.action = { [weak self] in
                guard let self else { return }
                self.onPick?(BotIdentity(shape: self.identity.shape, color: color))
            }
            addSubview(d)
            return d
        }
        refresh()
    }

    private func refresh() {
        preview.identity = identity
        for (shape, cell) in zip(BotShape.allCases, shapes) {
            cell.identity = BotIdentity(shape: shape, color: identity.color)
            cell.isSelected = shape == identity.shape
        }
        for (color, dot) in zip(BotColor.allCases, colors) {
            dot.isSelected = color == identity.color
            // The pumpkin keeps its orange.
            dot.isEnabled = identity.shape != .pumpkin
        }
    }

    private func columns(_ width: CGFloat) -> Int { max(1, Int((width - 72 - 20 + Self.gap) / (Self.cell + Self.gap))) }

    func height(forWidth width: CGFloat) -> CGFloat {
        let rows = (shapes.count + columns(width) - 1) / columns(width)
        return max(72, CGFloat(rows) * (Self.cell + Self.gap) - Self.gap + 12 + Self.dot)
    }

    override func layout() {
        super.layout()
        preview.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        let x0: CGFloat = 72 + 20, cols = columns(bounds.width)
        for (i, c) in shapes.enumerated() {
            c.frame = NSRect(x: x0 + CGFloat(i % cols) * (Self.cell + Self.gap), y: CGFloat(i / cols) * (Self.cell + Self.gap),
                             width: Self.cell, height: Self.cell)
        }
        let rows = (shapes.count + cols - 1) / cols
        let y = CGFloat(rows) * (Self.cell + Self.gap) - Self.gap + 12
        for (i, d) in colors.enumerated() {
            d.frame = NSRect(x: x0 + 7 + CGFloat(i) * (Self.dot + 8), y: y, width: Self.dot, height: Self.dot)
        }
    }
}

final class OrchestratorBotCell: ControlView {
    private let bot: BotView
    var identity: BotIdentity { get { bot.identity } set { bot.identity = newValue } }
    var isSelected = false { didSet { needsDisplay = true; setAccessibilityValue(isSelected ? "selected" : nil) } }

    init(_ identity: BotIdentity) {
        bot = BotView(identity: identity, size: 24)
        super.init(frame: .zero)
        addSubview(bot)
    }

    override func layout() {
        super.layout()
        bot.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = Themed.color(\.primary).cgColor(in: self)
        layer?.backgroundColor = (isSelected || state.hoverOrPressed ? Themed.color(\.secondary) : NSColor.clear).cgColor(in: self)
    }
}

final class OrchestratorColorDot: ControlView {
    let color: BotColor
    var isSelected = false { didSet { needsDisplay = true; setAccessibilityValue(isSelected ? "selected" : nil) } }

    init(_ color: BotColor) {
        self.color = color
        super.init(frame: .zero)
        setAccessibilityLabel("\(color)".capitalized)
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let c = color.rgb
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: state.enabled ? 1 : 0.35).cgColor
        // A ring outside the dot marks the pick, a faint one shows hover.
        layer?.borderWidth = isSelected ? 2.5 : state.hoverOrPressed ? 1.5 : 0
        layer?.borderColor = (isSelected ? Themed.color(\.foreground) : Themed.color(\.foreground, 0.4)).cgColor(in: self)
    }
}

/// Two buttons side by side as one row control; a hidden second one takes no room.
private final class ButtonPair: NSView {
    private let first: ButtonView
    private let second: ButtonView
    private let gap: CGFloat = 8

    init(_ first: ButtonView, _ second: ButtonView) {
        self.first = first
        self.second = second
        super.init(frame: .zero)
        addSubview(first)
        addSubview(second)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let a = first.intrinsicContentSize, b = second.intrinsicContentSize
        return second.isHidden ? a : NSSize(width: a.width + gap + b.width, height: max(a.height, b.height))
    }

    override func layout() {
        let a = first.intrinsicContentSize, b = second.intrinsicContentSize
        first.frame = NSRect(x: 0, y: (bounds.height - a.height) / 2, width: a.width, height: a.height)
        second.frame = NSRect(x: a.width + gap, y: (bounds.height - b.height) / 2, width: b.width, height: b.height)
    }
}
