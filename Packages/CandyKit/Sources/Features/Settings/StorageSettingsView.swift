import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Settings > Storage (StorageSettings.tsx): worktree location and cleanup rules, artifact and log
/// retention. At a project scope only the worktree cleanup policy (Inherit, Off, Custom) and its rules show.
/// From 2994 (`storageCleanupRun`) the "keep worktrees when" rule and the Cleanup section with the last run.
public final class StorageSettingsView: ScopedSettingsPage {
    private let notice = SettingsNoticeView("")
    private var worktrees: SettingsSectionView!
    private var artifacts: SettingsSectionView!
    private var locationRow: SettingsRowView!
    private var modeRow: SettingsRowView!
    private var keepRow: SettingsRowView!
    private var settledRow: SettingsRowView!
    private var ruleRows: [SettingsRowView] = []
    private var cleanup: SettingsSectionView!
    private var deleteRow: SettingsRowView!
    private let deleteButton = ButtonView("Delete now", variant: .outline, size: .sm)
    private let lastRun = CleanupLastRunView()
    /// The latest report per environment from `server.getStorageCleanupReport`; a key with nil means no run yet.
    private var reports: [String: StorageCleanupReport?] = [:]
    private var reportTasks: [String: Task<Void, Never>] = [:]
    private var deleting = false
    private var databaseTasks: [String: Task<Void, Never>] = [:]
    private var databaseRows: [String: SettingsRowView] = [:]
    private var databaseOrder: [String] = []
    /// `database-storage-notice-dismissed` (DatabaseStorageNotice.tsx:24-28): one list of dismissed environment ids.
    private static let dismissedKey = "database-storage-notice-dismissed"
    private var databaseSection: SettingsSectionView?


    public init(context: SettingsPageContext) {
        super.init(context: context)
        worktrees = buildWorktrees()
        artifacts = buildArtifacts()
        cleanup = buildCleanup()
        body = [notice, worktrees, artifacts, cleanup]
        // Redesign splits this page in two; both halves keep the capability notice.
        anchors["storage-notice"] = notice
        binder.add { [weak self] in self?.update() }
    }

    deinit { reportTasks.values.forEach { $0.cancel() }; databaseTasks.values.forEach { $0.cancel() } }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncReports()
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
        settledRow.isHidden = settledRow.isHidden || !scope.connected.allSatisfy { $0.capabilities.contains("settledWorktreeCleanup") }
        // StorageSettings.tsx:572-575: the keep rule needs `storageCleanupRun` on every connected environment.
        keepRow.isHidden = (isProject && (mixedModes || m != "custom")) || !scope.connected.allSatisfy { $0.capabilities.contains("storageCleanupRun") }
        worktrees.group.rows = worktrees.group.rows
        setHidden(cleanup, message != nil || isProject || supported.isEmpty)
        syncReports()
        updateCleanup()
    }

    // MARK: Cleanup (StorageSettings.tsx:231-404)

    /// Connected environments that can run cleanup and report on it.
    private var supported: [SettingsScopeEnvironment] { context.scope.connected.filter { $0.capabilities.contains("storageCleanupRun") } }

    /// Follows each supported environment's report stream while the page shows; drops the rest.
    private func syncReports() {
        syncDatabases()
        let want = window == nil || isProject ? [] : Set(supported.map(\.id))
        for (id, task) in reportTasks where !want.contains(id) {
            task.cancel()
            reportTasks[id] = nil
            reports[id] = nil
        }
        for id in want where reportTasks[id] == nil {
            reportTasks[id] = context.subscribe?(id, "server.getStorageCleanupReport", .object([:])) { [weak self] value in
                guard let self, self.reportTasks[id] != nil else { return }
                self.reports[id] = .some(StorageCleanupReport(json: value))
                self.updateCleanup()
            }
        }
    }

    private func syncDatabases() {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let environments = window == nil || isProject ? [] : context.scope.connected.filter {
            $0.capabilities.contains("databaseStorage") && !dismissed.contains($0.id)
        }
        databaseOrder = environments.map(\.id)
        let want = Set(environments.map(\.id))
        for (id, task) in databaseTasks where !want.contains(id) {
            task.cancel(); databaseTasks[id] = nil; databaseRows[id] = nil
        }
        for environment in environments where databaseTasks[environment.id] == nil {
            let id = environment.id, label = environment.label
            databaseTasks[id] = context.subscribe?(id, "server.getDatabaseStorage", .object([:])) { [weak self] value in
                guard let self, self.databaseTasks[id] != nil else { return }
                if let status = try? value.decode(as: DatabaseStorageStatus.self), status.recommendsCompaction {
                    let copy = ButtonView("Copy command", variant: .outline, size: .xs)
                    copy.action = { [weak copy] in
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(status.compactCommand, forType: .string)
                        copy?.title = "Copied"
                    }
                    // ponytail: the command shows as plain detail text, not a mono `code` block; add a mono detail view if it reads wrong
                    let row = self.row(nil, title: String(format: "%.1f GiB on %@", status.reclaimableBytes / 1_073_741_824, label),
                                       detail: status.compactCommand, control: copy)
                    let dismiss = ButtonView("Dismiss", variant: .ghost, size: .xs)
                    dismiss.action = { [weak self] in
                        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []) + [id], forKey: Self.dismissedKey)
                        self?.databaseTasks.removeValue(forKey: id)?.cancel(); self?.databaseRows[id] = nil
                        self?.rebuildDatabaseBody()
                    }
                    row.accessories = [dismiss]
                    self.databaseRows[id] = row
                } else { self.databaseRows[id] = nil }
                self.rebuildDatabaseBody()
            }
        }
        rebuildDatabaseBody()
    }

    private func rebuildDatabaseBody() {
        // DatabaseStorageNotice.tsx:34-80: one Database section, a header row, then a row per machine.
        let rows = databaseOrder.compactMap { databaseRows[$0] }
        if rows.isEmpty { databaseSection = nil } else {
            let header = row(nil, title: "Reclaim freed database space",
                             detail: "Old history is cleaned up automatically, but these databases still hold the freed space. Run the command on each machine to return it to disk; it pauses and restarts the background service. Quit the desktop app first if it hosts the environment.")
            databaseSection = section("storage-database", "Database", [header] + rows)
        }
        body = [notice] + (databaseSection.map { [$0] } ?? []) + [worktrees, artifacts, cleanup]
    }

    /// `hasRules` (StorageSettings.tsx:265-283): any retention or worktree rule on, at the environment or in a custom project policy.
    private var hasRules: Bool {
        func enabled(_ r: [String: JSONValue]) -> Bool {
            (r["worktreeAfterDays"].map { $0 != .null } ?? false) || (r["worktreeSettledAfterDays"].map { $0 != .null } ?? false) || r["worktreeOnMerge"]?.boolValue == true
                || r["worktreeOnDelete"]?.boolValue == true || r["worktreeUnchanged"]?.boolValue == true
        }
        return supported.contains { e in
            guard let s = e.settings else { return false }
            let storage = s["storageCleanup"]
            if storage["browserArtifactsAfterDays"].map({ $0 != .null }) ?? false { return true }
            if storage["logsAfterDays"].map({ $0 != .null }) ?? false { return true }
            if enabled(ProjectSettings.worktreeCleanup(s, projectId: nil)) { return true }
            return (s["projectSettingsOverrides"].objectValue ?? [:]).values.contains { o in
                o["worktreeCleanup"]?["mode"]?.stringValue == "custom" && enabled(o["worktreeCleanup"]?["rules"]?.objectValue ?? [:])
            }
        }
    }

    private func updateCleanup() {
        guard cleanup != nil else { return }
        let envs = supported
        let multi = envs.count > 1
        let nowMs = TimestampFormat.nowMs()
        // ponytail: the "Last run 3m ago" label refreshes with the page, not on T3's 60 s tick; add a tick if it looks stale
        let lines = envs.map { e -> String in
            let text: String
            switch reports[e.id] {
            case .some(.some(let r)):
                let failed = r.failed > 0 ? " \(r.failed) \(r.failed == 1 ? "item" : "items") couldn't be removed." : ""
                text = "Last run \(TimestampFormat.formatRelativeTimeLabel(r.finishedAt, nowMs: nowMs)). \(StorageCleanupReport.formatBytes(r.bytesFreed)) recovered.\(failed)"
            case .some(.none): text = "Cleanup hasn't run yet."
            case .none: text = "Loading last run…"
            }
            return (multi ? "\(e.label): " : "") + text
        }
        let rules = hasRules
        deleteRow.detail = rules ? lines.joined(separator: "\n") : "Turn on a cleanup rule to use this."
        deleteButton.title = deleting ? "Deleting…" : "Delete now"
        deleteButton.isEnabled = !deleting && rules && envs.contains(where: \.canWrite)
        deleteRow.needsLayout = true

        let labeled = context.scope.connected.count > 1
        let shown = envs.compactMap { e in reports[e.id].flatMap { $0 }.map { (e, $0) } }
        lastRun.isHidden = shown.isEmpty
        lastRun.summary = shown.map { e, r in
            (labeled ? "\(e.label): " : "") + "\(r.removed) removed, \(r.kept) kept" + (r.failed > 0 ? ", \(r.failed) failed" : "")
        }.joined(separator: " · ")
        lastRun.results = shown.flatMap { e, r in CleanupLastRunView.rows(r, environmentLabel: e.label) }
        cleanup.group.rows = cleanup.group.rows
        onHeightChange?()
    }

    /// `deleteNow`: runs cleanup on every supported environment this connection may write, toasting failures.
    private func deleteNow() {
        guard !deleting, let request = context.request else { return }
        let targets = supported.filter(\.canWrite)
        guard !targets.isEmpty else { return }
        deleting = true
        updateCleanup()
        var remaining = targets.count
        for e in targets {
            Task { @MainActor [weak self] in
                do {
                    let value = try await request(e.id, "server.runStorageCleanup", .object([:]))
                    if let report = StorageCleanupReport(json: value) {
                        if self?.reportTasks[e.id] != nil { self?.reports[e.id] = .some(report) }
                        if let failure = report.entries.first(where: { $0.outcome == "failed" }) {
                            self?.context.toast?("Cleanup failed on \(e.label)", failure.reason, .error)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    self?.context.toast?("Could not run cleanup on \(e.label)", "\(error)", .error)
                }
                remaining -= 1
                if remaining == 0 { self?.deleting = false }
                self?.updateCleanup()
            }
        }
    }

    private func buildCleanup() -> SettingsSectionView {
        deleteButton.action = { [weak self] in self?.deleteNow() }
        deleteRow = row("storage-delete-now", detail: "", control: deleteButton)
        lastRun.onHeightChange = { [weak self] in self?.onHeightChange?() }
        anchors["storage-cleanup-last-run"] = lastRun
        // `SettingsSection variant="plain"`: the Delete now card and the folded Last run card, `space-y-1`.
        let s = SettingsSectionView(title: "Cleanup", rows: [SettingsGroupView(rows: [deleteRow]), lastRun], variant: .plain)
        anchors["storage-cleanup"] = s
        return s
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
        settledRow = retentionRow("Delete settled worktrees",
            "Remove worktrees this many days after their thread settles. Set 0 days to remove them at the next cleanup. Branches and thread history are kept.",
            key: "worktreeSettledAfterDays", worktree: true)
        ruleRows = [onDelete, inactive, settledRow, merged, unchanged]
        keepRow = keepWhenRow()
        return section("storage-worktrees", "Worktrees", [locationRow, modeRow] + ruleRows + [keepRow])
    }

    /// "Keep worktrees with local changes" (StorageSettings.tsx:572-614): a select of `WorktreeKeepWhen`, "Mixed" when targets disagree.
    private func keepWhenRow() -> SettingsRowView {
        let cases = WorktreeKeepWhen.allCases
        let select = settingsSelect(cases.map(\.label), width: nil)
        select.placeholder = "Mixed"
        select.setAccessibilityLabel("Keep worktrees with local changes")
        let r = row("storage-worktree-keep-when", detail: "", control: select)
        r.accessories = [ResetSlot(label: "")]
        select.onChange = { [weak self] i in self?.updateWorktree(["worktreeKeepWhen": .string(cases[i].rawValue)]) }
        binder.add { [weak self, weak select, weak r] in
            guard let self else { return }
            let keep = self.settings(self.server)["worktreeKeepWhen"]?.stringValue.flatMap(WorktreeKeepWhen.init(rawValue:)) ?? .uncommittedChanges
            let mixed = self.status("worktreeKeepWhen")
            select?.selectedIndex = mixed == nil ? cases.firstIndex(of: keep) : nil
            r?.detail = keep.detail
            r?.status = mixed
            r?.inertReason = self.isProject ? nil : self.context.scope.inertReason
            r?.needsLayout = true
        }
        return r
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
        let control = RetentionControl(label: title, minimum: key == "worktreeSettledAfterDays" ? 0 : 1)
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

    init(label: String, minimum: Double = 1) {
        super.init(frame: .zero)
        field.range = minimum...3650
        field.setAccessibilityLabel("\(label) in days")
        toggle.setAccessibilityLabel(label)
        off.lineHeight = 16
        // ponytail: the days field commits on every step and edit; T3 commits on blur. Debounce if the server churns
        field.onChange = { [weak self] v in self?.onChange?(Int(min(3650, max(minimum, v.rounded())))) }
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
