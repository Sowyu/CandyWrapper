import AgentConfig
import AppKit
import DesignSystem

/// Redesign's Connectors tab (docs/connectors.md): the MCP servers and skills Claude and Codex use on each machine,
/// read and changed in their own config files through `ConnectorsStore`. CandyWrapper's own; T3 has no such page.
public final class ConnectorsSettingsView: SettingsPageBase {
    private var store: ConnectorsStore { .shared }
    private var observer: Int?
    private let picker = ConnectorsPickerRow()
    private let serversSection: SettingsSectionView
    private let skillsSection: SettingsSectionView
    private let note = ConnectorsNoteRow()
    /// The machine picked, nil for every machine.
    private var machine: String?
    private var machineIds: [String] = []
    /// The rows on screen, rebuilt only when what they show changed.
    private var shown: (rows: ConnectorRows, busy: Bool, machine: String?)?

    public override init(context: SettingsPageContext) {
        serversSection = SettingsSectionView(title: "MCP servers", rows: [])
        skillsSection = SettingsSectionView(title: "Skills", rows: [])
        super.init(context: context)
        let add = ButtonView("Add server", icon: .plus, variant: .outline, size: .xs)
        add.setAccessibilityLabel("Add an MCP server")
        add.action = { [weak self] in self?.presentAdd() }
        serversSection.headerAction = add
        picker.onSelect = { [weak self] i in
            guard let self else { return }
            self.machine = i == 0 ? nil : self.machineIds[safe: i - 1]
            self.rebuild()
        }
        gap = 24
        items = [picker, serversSection, skillsSection, note]
        observer = store.observe { [weak self] in self?.rebuild() }
        binder.add { [weak self] in self?.rebuild() }
    }

    isolated deinit { observer.map { ConnectorsStore.shared.removeObserver($0) } }

    public override func didShow() {
        store.load(connected.map(\.id), force: true)
    }

    private var connected: [SettingsScopeEnvironment] { context.scope.environments.filter(\.connected) }

    private func rebuild() {
        let machines = connected
        let ids = machines.map(\.id)
        if ids != machineIds {
            machineIds = ids
            picker.titles = ["Every machine"] + machines.map(\.label)
            if let m = machine, !ids.contains(m) { machine = nil }
            store.load(ids)
        }
        picker.selected = machine.flatMap { ids.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        picker.isHidden = machines.count < 2

        let targets = machines.filter { machine == nil || $0.id == machine }
        let rows = ConnectorRows(targets.map { ($0.id, $0.label, store.states[$0.id] ?? .loading) }, prefixProblems: machine == nil && machines.count > 1)
        let busy = targets.contains { store.busy.contains($0.id) }
        if let shown, shown.rows == rows, shown.busy == busy, shown.machine == machine { return }
        shown = (rows, busy, machine)

        let loading = targets.contains { store.states[$0.id] == nil || store.states[$0.id] == .loading }
        let unavailable = store.actions.unavailable?()
        serversSection.headerAction?.isHidden = unavailable != nil || targets.isEmpty

        var serverRows: [any SettingsGroupRow] = []
        if let unavailable {
            serverRows.append(message(unavailable, error: true))
        } else if targets.isEmpty {
            serverRows.append(message("No machine is connected.", error: false))
        }
        serverRows += rows.problems.map { message($0, error: true) }
        serverRows += rows.servers.filter { $0.name != "t3-code" }.map { serverRow($0, busy: busy) }
        if loading, rows.servers.isEmpty, unavailable == nil { serverRows.append(message("Reading the config…", error: false)) }
        serverRows.append(t3Row())
        serversSection.group.rows = serverRows

        var skillRows: [any SettingsGroupRow] = rows.skills.map { skillRow($0, busy: busy) }
        if skillRows.isEmpty { skillRows.append(message(loading ? "Reading the config…" : "No skills in ~/.claude/skills or ~/.agents/skills.", error: false)) }
        skillsSection.group.rows = skillRows
        note.text = "Changes apply to new threads." + (machine == nil && machines.count > 1 ? " Every machine changes all connected machines at once." : "")
        needsLayout = true
        onHeightChange?()
    }

    // MARK: Rows

    private func message(_ text: String, error: Bool) -> SettingsRowView {
        let r = SettingsRowView(title: "", detail: text)
        r.detailIsError = error
        return r
    }

    private func serverRow(_ item: ConnectorRows.Item, busy: Bool) -> SettingsRowView {
        let controls = ConnectorControls(item: item, busy: busy)
        controls.onAgent = { [weak self] agent in
            self?.store.apply(item.changes(to: item.isOn(agent) != true, agent: agent, skill: false))
        }
        controls.onSwitch = { [weak self] on in self?.store.apply(item.changes(to: on, skill: false)) }
        let r = SettingsRowView(title: item.name, detail: item.detail, control: controls)
        let remove = ButtonView(nil, icon: .trash2, variant: .ghostMuted, size: .iconXs)
        remove.setAccessibilityLabel("Remove \(item.name)")
        remove.isEnabled = !busy
        remove.action = { [weak self] in self?.confirmRemove(item) }
        r.accessories = [remove]
        return r
    }

    private func skillRow(_ item: ConnectorRows.Item, busy: Bool) -> SettingsRowView {
        let controls = ConnectorControls(item: item, busy: busy)
        controls.onAgent = { [weak self] agent in
            self?.store.apply(item.changes(to: item.isOn(agent) != true, agent: agent, skill: true))
        }
        controls.onSwitch = { [weak self] on in self?.store.apply(item.changes(to: on, skill: true)) }
        return SettingsRowView(title: item.name, detail: item.detail.isEmpty ? nil : item.detail, control: controls)
    }

    /// T3 adds its own server to every thread at run time; it's in no config file and can't be turned off.
    private func t3Row() -> SettingsRowView {
        let lock = LabelView("Always on", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        lock.frame.size = NSSize(width: lock.intrinsicContentSize.width, height: 16)
        let r = SettingsRowView(title: "t3-code", detail: "Added by T3 to every thread", control: lock)
        r.isDisabled = true
        return r
    }

    private func confirmRemove(_ item: ConnectorRows.Item) {
        let removals = item.removals()
        let agents = item.agents.map(\.label).joined(separator: " and ")
        let machines = removals.count > 1 ? " on \(removals.count) machines" : ""
        context.confirm?("Remove \(item.name)?\nIts entry goes from \(agents)'s config\(machines). Turn it off instead to keep it.", true) { [weak self] in
            self?.store.apply(removals)
        }
    }

    private func presentAdd() {
        let targets = machine.map { [$0] } ?? machineIds
        let (dialog, form) = AddConnectorDialog.make()
        guard let host = context.presentDialog?(dialog) else { return }
        form.onCancel = { [weak host] in host?.close() }
        form.onSubmit = { [weak self, weak host, weak form] server in
            guard let self else { return }
            if let clash = targets.first(where: { id in
                if case .loaded(let s) = self.store.states[id] { s.servers.contains { $0.name == server.name && server.agents.contains($0.agent) } } else { false }
            }) {
                form?.error = "\(server.name) already exists on \(self.connected.first { $0.id == clash }?.label ?? clash)."
                return
            }
            host?.close()
            self.store.apply(Dictionary(uniqueKeysWithValues: targets.map { ($0, [.addServer(server)]) }))
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The machine picker over the lists: Every machine, then each connected machine.
final class ConnectorsPickerRow: DSView, SettingsGroupRow {
    private var group: ToggleGroupView?
    var onSelect: ((Int) -> Void)?
    var titles: [String] = [] {
        didSet {
            guard titles != oldValue else { return }
            group?.removeFromSuperview()
            let g = ToggleGroupView(variant: .segmented, items: titles.map { ($0, nil) }, selected: selected)
            g.setAccessibilityLabel("Machine")
            // A segmented control always keeps one item: pressing the pressed one again leaves it pressed.
            g.onChange = { [weak self, weak g] i in
                guard let self else { return }
                if let i { self.selected = i; self.onSelect?(i) } else { g?.selectedIndex = self.selected }
            }
            addSubview(g)
            group = g
            needsLayout = true
        }
    }
    var selected = 0 { didSet { if group?.selectedIndex != selected { group?.selectedIndex = selected } } }

    func height(forWidth width: CGFloat) -> CGFloat { isHidden ? 0 : 32 }

    override func layout() {
        super.layout()
        guard let group else { return }
        let size = group.intrinsicContentSize
        group.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width), height: size.height)
    }
}

/// The muted line under the lists.
final class ConnectorsNoteRow: DSView, SettingsGroupRow {
    private let label = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    var text: String {
        get { label.text }
        set { label.text = newValue; needsLayout = true }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { label.height(forWidth: width) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: label.height(forWidth: bounds.width))
    }
}

/// A row's agent chips and its switch. A chip per agent that has the entry; clicking one turns that agent's copy
/// on or off. A struck-through chip is off, a faint one differs between machines.
final class ConnectorControls: DSView {
    private var chips: [(ConfigAgent, AgentChip)] = []
    private let toggle = SwitchView(isOn: false)
    var onAgent: ((ConfigAgent) -> Void)?
    var onSwitch: ((Bool) -> Void)?

    init(item: ConnectorRows.Item, busy: Bool) {
        super.init(frame: .zero)
        for agent in item.agents {
            let chip = AgentChip(agent.label)
            chip.state3 = item.isOn(agent)
            chip.isEnabled = !busy
            chip.action = { [weak self] in self?.onAgent?(agent) }
            chip.setAccessibilityLabel("\(agent.label): \(item.isOn(agent) == false ? "off" : "on")")
            addSubview(chip)
            chips.append((agent, chip))
        }
        let on = item.isOn
        toggle.isMixed = on == nil
        toggle.isOn = on == true
        toggle.isEnabled = !busy
        toggle.setAccessibilityLabel(item.name)
        toggle.onChange = { [weak self, weak toggle] value in
            // A mixed switch turns everything on, as T3's scoped switches do.
            self?.onSwitch?(toggle?.isMixed == true ? true : value)
        }
        addSubview(toggle)
        frame.size = intrinsicContentSize
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let chipsW = chips.reduce(0) { $0 + $1.1.intrinsicContentSize.width + 6 }
        let sw = toggle.intrinsicContentSize
        return NSSize(width: chipsW + (chips.isEmpty ? 0 : 8) + sw.width, height: max(20, sw.height))
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (_, chip) in chips {
            let s = chip.intrinsicContentSize
            chip.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x += s.width + 6
        }
        let sw = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: bounds.width - sw.width, y: (bounds.height - sw.height) / 2, width: sw.width, height: sw.height)
    }
}

/// "Claude" or "Codex" in a small rounded tag (11pt, 1px by 7px, 5pt corners), a button.
final class AgentChip: ControlView {
    private let label: LabelView
    private let strike = CALayer()
    /// On, off (struck through) or mixed between machines (faint).
    var state3: Bool? = true { didSet { needsDisplay = true } }

    init(_ text: String) {
        label = LabelView(text, font: DSFont.ui(11, weight: .medium), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        scalesWhenPressed = false
        addSubview(label)
        layer?.addSublayer(strike)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.intrinsicContentSize.width) + 14, height: 18) }

    override func layout() {
        super.layout()
        let w = ceil(label.intrinsicContentSize.width)
        label.frame = NSRect(x: 7, y: (bounds.height - 14) / 2, width: w, height: 14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strike.frame = NSRect(x: 6, y: floor(bounds.height / 2), width: w + 2, height: 1)
        CATransaction.commit()
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        let hover = state.hoverOrPressed && state.enabled
        layer?.backgroundColor = Themed.color(light: \.foreground, hover ? 0.10 : 0.06, dark: \.foreground, hover ? 0.14 : 0.08).cgColor(in: self)
        let off = state3 == false
        label.color = Themed.color(\.foreground, off ? 0.4 : state3 == nil ? 0.6 : 0.82)
        strike.backgroundColor = Themed.color(\.foreground, 0.45).cgColor(in: self)
        strike.isHidden = !off
    }
}
