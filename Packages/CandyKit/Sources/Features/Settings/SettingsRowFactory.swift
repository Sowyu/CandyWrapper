import AppKit
import DesignSystem
import T3Protocol

/// Base of the General and Appearance pages: builds T3's settings rows bound to the context, with the
/// reset arrow, the inheritance indicator and the inert state of server rows (settingsLayout.tsx `SettingsRow`).
public class SettingsPageBase: SettingsStackView {
    let context: SettingsPageContext
    let binder = SettingsBinder()
    /// After a change of height (a row appeared), for the page to lay out again.
    public var onHeightChange: (() -> Void)?

    init(context: SettingsPageContext) {
        self.context = context
        super.init(frame: .zero)
    }

    /// The page was opened (again): pages that query the server load fresh data.
    public func didShow() {}

    /// Re-reads every control after the client settings, a server config or the scope changed.
    public func refresh() {
        binder.refresh()
        needsLayout = true
        onHeightChange?()
    }

    var client: ClientSettings { context.client }
    var server: ServerSettingsValues { context.scope.values }

    /// A row with T3's search anchor and title (`searchableSetting(id)`).
    func row(_ id: String?, title: String? = nil, detail: String? = nil, control: NSView? = nil) -> SettingsRowView {
        let r = SettingsRowView(title: title ?? id.map(SettingsSearch.title) ?? "", detail: detail, control: control)
        if let id { anchors[id] = r }
        return r
    }

    func section(_ id: String?, _ title: String, _ rows: [any SettingsGroupRow]) -> SettingsSectionView {
        let s = SettingsSectionView(title: title, rows: rows)
        if let id { anchors[id] = s }
        return s
    }

    // MARK: Client rows

    /// A client switch with the reset arrow when it differs from the default.
    func clientSwitch(_ id: String, _ detail: String, key: String, reset: String? = nil, label: String? = nil,
                      read: ((ClientSettings) -> Bool)? = nil, write: ((Bool) -> [String: JSONValue])? = nil) -> SettingsRowView {
        let sw = SwitchView(isOn: false)
        sw.setAccessibilityLabel(label ?? SettingsSearch.title(id))
        let r = row(id, detail: detail, control: sw)
        let slot = reset.map { ResetSlot(label: $0) }
        r.accessories = slot.map { [$0] } ?? [ResetSlot(label: "")]
        slot?.action = { [weak self] in self?.context.writeClient?([key: ClientSettings.fields[key]!.defaultValue]) }
        sw.onChange = { [weak self] on in self?.context.writeClient?(write?(on) ?? [key: .bool(on)]) }
        binder.add { [weak self, weak sw] in
            guard let self else { return }
            sw?.isOn = read?(self.client) ?? self.client.bool(key)
            slot?.isShown = !self.client.isDefault(key)
        }
        return r
    }

    /// A client select of literal values.
    func clientSelect(_ id: String, _ detail: String?, key: String, options: [(value: String, label: String)], width: CGFloat?,
                      reset: String? = nil, hideIndicator: Bool = true, label: String? = nil) -> SettingsRowView {
        let select = settingsSelect(options.map(\.label), width: width, hideIndicator: hideIndicator)
        select.setAccessibilityLabel(label ?? SettingsSearch.title(id))
        let r = row(id, detail: detail, control: select)
        let slot = reset.map { ResetSlot(label: $0) }
        r.accessories = slot.map { [$0] } ?? [ResetSlot(label: "")]
        slot?.action = { [weak self] in self?.context.writeClient?([key: ClientSettings.fields[key]!.defaultValue]) }
        select.onChange = { [weak self] i in self?.context.writeClient?([key: .string(options[i].value)]) }
        binder.add { [weak self, weak select, weak r] in
            guard let self else { return }
            select?.selectedIndex = options.firstIndex { $0.value == self.client.string(key) }
            slot?.isShown = !self.client.isDefault(key)
            r?.needsLayout = true
        }
        return r
    }

    // MARK: Server rows

    /// Wires a server row's inheritance indicator, reset arrow and inert state.
    func bindServerRow(_ r: SettingsRowView, keys: [String], reset: String?, isDefault: (() -> Bool)? = nil,
                       resetPatch: (() -> [String: JSONValue])? = nil, extra: [NSView] = []) -> ResetSlot {
        let inheritance = InheritanceButton()
        let slot = ResetSlot(label: reset ?? "")
        r.accessories = extra + [inheritance, slot]
        inheritance.onOpen = { [weak self] trigger in self?.showChain(keys: keys, from: trigger) }
        let scoped = keys.filter(ProjectSettings.isScoped)
        slot.action = { [weak self] in
            guard let self else { return }
            if self.context.scope.isProjectScope, !scoped.isEmpty {
                self.context.clearServer?(scoped)
            } else {
                self.context.patchServer(resetPatch?() ?? Dictionary(uniqueKeysWithValues: keys.map { ($0, ServerSettingsValues.fields[$0]?.defaultValue ?? .null) }))
            }
        }
        binder.add { [weak self, weak r] in
            guard let self else { return }
            let scope = self.context.scope
            let inh = scope.inheritance(keys)
            inheritance.state = inh.state
            inheritance.summary = inh.summary
            inheritance.isHidden = scope.connected.isEmpty
            let inert = scope.inertReason(for: keys)
            if scope.isProjectScope, !scoped.isEmpty {
                // `SettingResetButton tooltip="Reset to inherited value"` while the project overrides it or the
                // targets disagree (settingsLayout.tsx:361); a t3.json value has no override to clear.
                let source = scope.source(scoped)
                slot.isShown = (source == nil || source == .project) && inert == nil
                slot.tooltip = "Reset to inherited value"
            } else {
                let changed = !(isDefault?() ?? keys.allSatisfy { self.server.isDefault($0) })
                slot.isShown = reset != nil && changed && inert == nil
                slot.tooltip = "Reset to default"
            }
            r?.inertReason = inert
        }
        return slot
    }

    /// A server switch (`ScopedSwitch`): mixed targets show the mixed state; clicking it turns it on everywhere.
    func serverSwitch(_ id: String, _ detail: String, key: String, reset: String?, label: String? = nil,
                      read: ((ServerSettingsValues) -> Bool)? = nil, write: ((Bool) -> [String: JSONValue])? = nil) -> SettingsRowView {
        let sw = SwitchView(isOn: false)
        sw.setAccessibilityLabel(label ?? SettingsSearch.title(id))
        let r = row(id, detail: detail, control: sw)
        _ = bindServerRow(r, keys: [key], reset: reset)
        sw.onChange = { [weak self, weak sw] on in
            guard let self else { return }
            let value = sw?.isMixed == true ? true : on
            self.context.patchServer(write?(value) ?? [key: .bool(value)])
        }
        binder.add { [weak self, weak sw] in
            guard let self, let sw else { return }
            let mixed = self.context.scope.isMixed([key])
            sw.isMixed = mixed
            sw.isOn = mixed ? false : (read?(self.server) ?? self.server.bool(key))
        }
        return r
    }

    /// A server select; mixed targets show "Mixed".
    func serverSelect(_ id: String, _ detail: String?, key: String, options: [(value: String, label: String)], width: CGFloat?,
                      reset: String?, label: String? = nil, current: ((ServerSettingsValues) -> String?)? = nil) -> (SettingsRowView, SelectView) {
        let select = settingsSelect(options.map(\.label), width: width)
        select.setAccessibilityLabel(label ?? SettingsSearch.title(id))
        let r = row(id, detail: detail, control: select)
        _ = bindServerRow(r, keys: [key], reset: reset)
        select.onChange = { [weak self] i in self?.context.patchServer([key: .string(options[i].value)]) }
        binder.add { [weak self, weak select] in
            guard let self, let select else { return }
            let mixed = self.context.scope.isMixed([key])
            let value = current?(self.server) ?? self.server.string(key)
            select.placeholder = self.context.scope.connected.isEmpty ? "Unavailable" : "Mixed"
            select.selectedIndex = mixed ? nil : options.firstIndex { $0.value == value }
        }
        return (r, select)
    }

    /// Rows whose description names the project at a project scope (ProjectDefaultsSettings.tsx `isProjectScope`).
    func projectScopeDetails(_ rows: [(SettingsRowView, String, String)]) {
        binder.add { [weak self] in
            guard let self else { return }
            let project = self.context.scope.isProjectScope
            for (row, inProject, otherwise) in rows { row.detail = project ? inProject : otherwise }
        }
    }

    // MARK: Inheritance chain

    /// `SettingInheritance`'s popover: per environment, the environment value and the built-in default,
    /// the effective one checked.
    func showChain(keys: [String], from trigger: NSView) {
        guard let key = keys.first else { return }
        let stack = ChainView()
        let scope = context.scope
        for t in scope.targets {
            guard let e = scope.environments.first(where: { $0.id == t.environmentId }), let s = e.settings else { continue }
            // `settingInheritanceLayers` (SettingInheritance.tsx:80-136): the project override, the environment's
            // value, the checkout's t3.json for file-backed keys, the built-in default.
            let source = ProjectSettings.isScoped(key) ? t.sources[key] ?? .environment : .environment
            let set = !s.isDefault(key)
            let fileBacked = ProjectSettings.fileBacked[key]
            var layers: [(label: String, value: String, effective: Bool, set: Bool)] = []
            if t.projectId != nil, ProjectSettings.isScoped(key) {
                layers.append(("Project", source == .project ? Self.format(key, t.settings[key]) : "Inherits", source == .project, source == .project))
            }
            layers.append((t.label, set ? Self.format(key, s[key]) : "Inherits", source == .environment && set, set))
            if fileBacked != nil, t.projectId != nil {
                layers.append(("t3.json", source == .t3json ? Self.format(key, t.settings[key]) : "Inherits", source == .t3json, source == .t3json))
            }
            // A file-backed key's built-in is what the resolver fills in, not the null the schema decodes to.
            let builtIn = fileBacked.map { JSONValue.string($0) } ?? ServerSettingsValues.fields[key]?.defaultValue ?? .null
            layers.append(("Default", Self.format(key, builtIn), source == .environment && !set, true))
            stack.add(header: scope.environmentLabel(e), machine: e.machine, layers: layers)
        }
        let pop = PopoverView(content: stack, padding: .none, width: .md)
        _ = pop.show(from: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4))
    }

    /// `formatValue` (SettingInheritance.tsx) for the keys these pages show.
    static func format(_ key: String, _ value: JSONValue) -> String {
        switch value {
        case .null:
            switch key {
            case "pullRequestMergeMethod": return "Last selected"
            case "sourceControlWriterModelSelection": return "Text generation model"
            case "sidebarAutoSettleAfterDays": return "Never"
            case "defaultModelSelection": return "Automatic"
            case "defaultThreadEnvMode", "worktreeSubmodules": return "Inherit"
            default: return "Not set"
            }
        case .bool(let b): return b ? "On" : "Off"
        case .number(let n):
            let i = abs(n) < 9e15 ? Int(n) : 0
            return key == "sidebarAutoSettleAfterDays" ? "\(i) \(i == 1 ? "day" : "days")" : "\(i)"
        case .string(let s):
            if key == "defaultThreadEnvMode" { return s == "worktree" ? "New worktree" : "Current checkout" }
            if key == "worktreeSubmodules" { return ["recursive": "Recursive", "top-level": "Top level only", "none": "Skip"][s] ?? s }
            if key == "pullRequestMergeMethod" { return ["merge": "Merge commit", "squash": "Squash and merge", "rebase": "Rebase and merge"][s] ?? s }
            return s.isEmpty ? "Empty" : s
        case .array(let a): return "\(a.count) \(a.count == 1 ? "item" : "items")"
        case .object(let o):
            if let model = o["model"]?.stringValue { return model }
            if let mode = o["mode"]?.stringValue {
                return ["repo_conventions": "Repository conventions", "conventional_commits": "Conventional Commits", "custom": "Custom instructions"][mode] ?? mode
            }
            return "Custom"
        }
    }
}

/// The inheritance popover body (`divide-y`, sections `px-3 py-2.5`).
final class ChainView: DSView {
    private var blocks: [(header: [NSView], rows: [(DSView, LabelView, LabelView, IconView?)])] = []
    private var dividers: [CALayer] = []

    func add(header: String, machine: String, layers: [(label: String, value: String, effective: Bool, set: Bool)]) {
        let glyph = EnvironmentMachineIcon.view(machine, size: 14, color: Themed.color(\.mutedForeground))
        let title = LabelView(header, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
        title.lineHeight = 16
        [glyph, title].forEach(addSubview)
        var rows: [(DSView, LabelView, LabelView, IconView?)] = []
        for l in layers {
            let bg = DSView()
            bg.layer?.cornerRadius = 6
            bg.layer?.backgroundColor = l.effective ? Themed.color(\.foreground, 0.06).cgColor(in: self) : nil
            let name = LabelView(l.label, font: DSFont.ui(14, weight: l.effective ? .medium : .regular),
                                 color: l.effective ? Themed.color(\.foreground) : Themed.color(\.mutedForeground))
            let value = LabelView(l.value, font: DSFont.ui(14), color: l.effective ? Themed.color(\.foreground)
                                  : l.set ? Themed.color(\.mutedForeground) : Themed.color(\.mutedForeground, 0.6))
            name.lineHeight = 20; value.lineHeight = 20
            let check = l.effective ? IconView(name: .check, size: 14, strokeColor: Themed.color(\.primary)) : nil
            addSubview(bg)
            [name, value].forEach(addSubview)
            check.map(addSubview)
            rows.append((bg, name, value, check))
        }
        blocks.append(([glyph, title], rows))
        if blocks.count > 1 {
            let d = CALayer()
            d.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
            layer?.addSublayer(d)
            dividers.append(d)
        }
    }

    override var intrinsicContentSize: NSSize {
        var h = CGFloat(dividers.count)
        for block in blocks { h += 42 + CGFloat(block.rows.count) * 28 }
        return NSSize(width: 320, height: h)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (i, block) in blocks.enumerated() {
            if i > 0 { dividers[i - 1].frame = CGRect(x: 0, y: y, width: bounds.width, height: 1); y += 1 }
            y += 10
            block.header[0].frame = NSRect(x: 12, y: y + 1, width: 14, height: 14)
            block.header[1].frame = NSRect(x: 32, y: y, width: bounds.width - 44, height: 16)
            y += 22
            for (bg, name, value, check) in block.rows {
                bg.frame = NSRect(x: 12, y: y, width: bounds.width - 24, height: 28)
                let vw = min(128, ceil(value.textWidth) + 1)
                check?.frame = NSRect(x: bounds.width - 12 - 8 - 14, y: y + 7, width: 14, height: 14)
                value.frame = NSRect(x: bounds.width - 12 - 8 - 14 - 6 - vw, y: y + 4, width: vw, height: 20)
                name.frame = NSRect(x: 20, y: y + 4, width: max(0, value.frame.minX - 12 - 20), height: 20)
                y += 28
            }
            y += 10
        }
    }
}
