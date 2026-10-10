import AppKit
import DesignSystem
import T3Protocol

/// Settings > Storage (StorageSettings.tsx): worktree location and cleanup rules, artifact and log
/// retention. At a project scope only the worktree cleanup policy (Inherit, Off, Custom) and its rules show.
public final class StorageSettingsView: ScopedSettingsPage {
    private let notice = SettingsNoticeView("")
    private var worktrees: SettingsSectionView!
    private var artifacts: SettingsSectionView!
    private var locationRow: SettingsRowView!
    private var modeRow: SettingsRowView!
    private var ruleRows: [SettingsRowView] = []

    public init(context: SettingsPageContext) {
        super.init(context: context)
        worktrees = buildWorktrees()
        artifacts = buildArtifacts()
        body = [notice, worktrees, artifacts]
        binder.add { [weak self] in self?.update() }
    }

    private var isProject: Bool { context.scope.isProjectScope }

    /// Effective storage values: `storageCleanup` with the resolved worktree rules on top.
    private func settings(_ s: ServerSettingsValues) -> [String: JSONValue] {
        var o = s["storageCleanup"].objectValue ?? [:]
        for (k, v) in ProjectSettings.worktreeCleanup(s, projectId: nil) { o[k] = v }
        return o
    }

    /// `projectMode`: the project's own policy, else inherit.
    private func mode(_ t: SettingsScopeState.Target?) -> String {
        guard let t, t.sources["worktreeCleanup"] == .project else { return "inherit" }
        return t.settings["worktreeCleanup"]["mode"]?.stringValue ?? "inherit"
    }

    private func update() {
        let scope = context.scope
        // Capability notices (`SettingsScopeNotice`).
        var message: String?
        if isProject, scope.connected.contains(where: { !$0.capabilities.contains("projectWorktreeCleanup") }) {
            message = "Update the selected machines to configure project worktree cleanup."
        } else if scope.connected.contains(where: { !$0.capabilities.contains("storageCleanup") }) {
            message = "Update the selected environments to use storage cleanup, or choose a machine that supports it."
        }
        notice.message = message ?? ""
        setHidden(notice, message == nil)
        let m = mode(scope.target)
        let mixedModes = scope.targets.contains { mode($0) != m }
        setHidden(worktrees, message != nil)
        setHidden(artifacts, message != nil || isProject)
        locationRow.isHidden = isProject || scope.connected.contains { !$0.capabilities.contains("worktreesDirectory") }
        modeRow.isHidden = !isProject
        modeRow.detail = m == "off" ? "Keep this project's worktrees until you delete them manually."
            : m == "custom" ? "Use these rules for this project." : "Use each machine's worktree cleanup settings."
        if let select = modeRow.control as? SelectView {
            select.placeholder = "Mixed"
            select.selectedIndex = mixedModes ? nil : ["inherit", "off", "custom"].firstIndex(of: m)
        }
        for r in ruleRows { r.isHidden = isProject && (mixedModes || m != "custom") }
        worktrees.group.rows = worktrees.group.rows
    }

    /// `ruleStatus`: "Mixed across selected machines" when targets disagree.
    private func status(_ key: String) -> String? {
        let mine = settings(server)[key]
        return context.scope.targets.contains { settings($0.settings)[key] != mine } ? "Mixed across selected machines" : nil
    }

    private func updateWorktree(_ patch: [String: JSONValue]) {
        if isProject {
            context.patchServer(["worktreeCleanup": .object(["mode": .string("custom"), "rules": .object(patch)])])
        } else {
            context.patchServer(["storageCleanup": .object(patch)])
        }
    }

    private func buildWorktrees() -> SettingsSectionView {
        // `WorktreesDirectoryRow`: commits on blur when edited.
        let input = InputView(placeholder: "Default", text: "", size: .sm)
        input.frame.size = NSSize(width: 256, height: 28)
        input.setAccessibilityLabel("Worktree location")
        locationRow = row("storage-worktrees-location",
                          detail: "Folder where new worktrees are created, on any drive, such as D:\\worktrees or ~/worktrees. Existing worktrees stay where they are. Leave empty to use the T3 home folder.",
                          control: input)
        _ = bindServerRow(locationRow, keys: ["worktreesDirectory"], reset: "worktree location",
                          isDefault: { [weak self] in
                              guard let self else { return true }
                              return !self.context.scope.isMixed(["worktreesDirectory"]) && self.server.string("worktreesDirectory").isEmpty
                          }, resetPatch: { ["worktreesDirectory": .string("")] })
        var edited = false
        input.onChange = { _ in edited = true }
        input.onCommit = { [weak self] text in
            guard let self else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited, self.context.scope.isMixed(["worktreesDirectory"]) || value != self.server.string("worktreesDirectory") {
                self.context.patchServer(["worktreesDirectory": .string(value)])
            }
            edited = false
        }
        binder.add { [weak self, weak input] in
            guard let self, let input, !input.state.focused else { return }
            let mixed = self.context.scope.isMixed(["worktreesDirectory"])
            input.text = mixed ? "" : self.server.string("worktreesDirectory")
            input.placeholder = mixed ? "Mixed" : "Default"
        }

        let modeSelect = settingsSelect(["Inherit", "Off", "Custom"], width: nil)
        modeSelect.setAccessibilityLabel("Automatic worktree cleanup")
        modeRow = row(nil, title: "Automatic worktree cleanup", detail: "", control: modeSelect)
        _ = bindServerRow(modeRow, keys: ["worktreeCleanup"], reset: nil)
        modeSelect.onChange = { [weak self] i in
            guard let self else { return }
            switch i {
            case 0: self.context.clearServer?(["worktreeCleanup"])
            case 1: self.context.patchServer(["worktreeCleanup": .object(["mode": .string("off")])])
            default: self.context.patchServer(["worktreeCleanup": .object(["mode": .string("custom"), "rules": .object([:])])])
            }
        }

        let onDelete = ruleSwitch("Delete worktrees with deleted threads",
                                  "Remove unused worktrees when active or archived threads are deleted. Worktrees with local changes are kept.", key: "worktreeOnDelete")
        let inactive = retentionRow("Delete inactive worktrees",
                                    "Remove worktrees after their threads have been inactive for this many days. Branches and thread history are kept.",
                                    key: "worktreeAfterDays", worktree: true)
        let merged = ruleSwitch("Delete merged worktrees",
                                "Remove worktrees whose pull request is merged and whose commits are included in the default branch.", key: "worktreeOnMerge")
        let unchanged = ruleSwitch("Delete unchanged worktrees", "Remove worktrees with no commits beyond the default branch.", key: "worktreeUnchanged")
        ruleRows = [onDelete, inactive, merged, unchanged]
        return section("storage-worktrees", "Worktrees", [locationRow, modeRow] + ruleRows)
    }

    private func buildArtifacts() -> SettingsSectionView {
        let browser = retentionRow("Delete old browser artifacts",
                                   "Delete saved browser captures after this many days. Older capture links will no longer open.",
                                   key: "browserArtifactsAfterDays", worktree: false)
        let logs = retentionRow("Delete old rotated logs", "Delete inactive rotated log files after this many days. Current logs are kept.",
                                key: "logsAfterDays", worktree: false)
        return section("storage-artifacts", "Artifacts and logs", [browser, logs])
    }

    /// A rule switch: server-scoped (inert when the scope can't write) outside a project scope.
    private func ruleSwitch(_ title: String, _ detail: String, key: String) -> SettingsRowView {
        let sw = SwitchView(isOn: false)
        sw.setAccessibilityLabel(title)
        let r = row(nil, title: title, detail: detail, control: sw)
        r.accessories = [ResetSlot(label: "")]
        sw.onChange = { [weak self] on in self?.updateWorktree([key: .bool(on)]) }
        binder.add { [weak self, weak sw, weak r] in
            guard let self else { return }
            sw?.isOn = self.settings(self.server)[key]?.boolValue ?? false
            r?.status = self.status(key)
            r?.inertReason = self.isProject ? nil : self.context.scope.inertReason
        }
        return r
    }

    /// `RetentionControl`: days 1 to 3650 beside a switch (on starts at 8); "Off" when off.
    private func retentionRow(_ title: String, _ detail: String, key: String, worktree: Bool) -> SettingsRowView {
        let control = RetentionControl(label: title)
        let r = row(nil, title: title, detail: detail, control: control)
        r.accessories = [ResetSlot(label: "")]
        control.onChange = { [weak self] value in
            guard let self else { return }
            let v: JSONValue = value.map { .number(Double($0)) } ?? .null
            if worktree { self.updateWorktree([key: v]) } else { self.context.patchServer(["storageCleanup": .object([key: v])]) }
        }
        binder.add { [weak self, weak control, weak r] in
            guard let self else { return }
            control?.value = self.settings(self.server)[key]?.intValue
            r?.status = self.status(key)
            r?.inertReason = self.isProject && worktree ? nil : self.context.scope.inertReason
            r?.needsLayout = true
        }
        return r
    }
}

/// `RetentionControl` (StorageSettings.tsx:87-145): a number field with "days" while on, "Off" while off,
/// and the switch.
final class RetentionControl: DSView {
    let field = NumberFieldView(value: 8, size: .sm)
    private let off = LabelView("Off", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let toggle = SwitchView(isOn: false)
    var onChange: ((Int?) -> Void)?
    var value: Int? {
        didSet {
            field.isHidden = value == nil
            off.isHidden = value != nil
            if let value { field.value = Double(value) }
            toggle.isOn = value != nil
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    init(label: String) {
        super.init(frame: .zero)
        field.range = 1...3650
        field.setAccessibilityLabel("\(label) in days")
        toggle.setAccessibilityLabel(label)
        off.lineHeight = 16
        // ponytail: the days field commits on every step and edit; T3 commits on blur. Debounce if the server churns
        field.onChange = { [weak self] v in self?.onChange?(Int(min(3650, max(1, v.rounded())))) }
        toggle.onChange = { [weak self] on in self?.onChange?(on ? 8 : nil) }
        for v in [field, off, toggle] as [NSView] { addSubview(v) }
        value = nil
    }

    override var intrinsicContentSize: NSSize {
        let s = toggle.intrinsicContentSize
        return NSSize(width: (value == nil ? ceil(off.textWidth) + 1 : 128) + 12 + s.width, height: 28)
    }

    override func layout() {
        super.layout()
        let s = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: bounds.width - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        field.frame = NSRect(x: 0, y: 0, width: 128, height: 28)
        off.frame = NSRect(x: 0, y: 6, width: ceil(off.textWidth) + 1, height: 16)
    }
}
