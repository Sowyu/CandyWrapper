import AppKit
import DesignSystem
import T3Protocol

/// One of CandyWrapper's own experimental features. Each keeps its switch in its own store, under the key it always had.
@MainActor
public struct ExperimentalToggle {
    /// The search anchor, `SettingsSearchItem.id`.
    public let id: String
    public let title: String
    public let detail: String
    /// Works only in Redesign: while Redesign is off the switch is disabled and says so.
    public var needsRedesign = false
    public let isOn: () -> Bool
    public let set: (Bool) -> Void
    /// Calls back when the stored value changes elsewhere, such as a sync from another device. Returns the unsubscribe.
    public let observe: (@escaping @MainActor () -> Void) -> () -> Void
}

/// Settings > Beta (BetaSettingsPanel.tsx at 3669, LabsSettingsPanel.tsx at 4928): features still settling in, each off
/// until turned on here. T3's rows come first; CandyWrapper's own experiments follow in a group of their own, which
/// replaced the separate Experimental page in round 3.
/// Working section moved here from General; Guest links is new. Signed out of T3 Connect, Guest links offers
/// Sign in in place of its switch (`GuestLinksRowWithSignIn`), but only once the account has loaded.
public final class BetaSettingsView: SettingsPageBase {
    /// CandyWrapper's own experiments, one entry each. Redesign has its own page.
    public static let candyToggles: [ExperimentalToggle] = [
        ExperimentalToggle(id: "thread-tabs", title: "Tabs", detail: "A tab strip at the top of the window for open threads and other pages. ⌘-click a thread to open it in a new tab.", needsRedesign: true, isOn: { ThreadTabsSetting.isOn }, set: { ThreadTabsSetting.set($0) }, observe: { ThreadTabsSetting.observe($0) }),
    ]
    private var unsubscribe: [() -> Void] = []

    static let deviceReadOnlyReason = "Saved on this device. Select All projects to change it."
    static let guestDetail = "Share a thread with a guest who watches it live in a browser and sends messages you approve. Needs T3 Connect: sign in and link this machine in Sharing & access. Turning it off stops every guest link."
    static let linkedDetail = "Let agents here work on your other machines, and theirs here. Turn it on for each machine, then link them in Connections. While off, nothing new starts over a link; running tasks finish."
    static let guestSignedOutDetail = "Share a thread with a guest who watches it live in a browser and sends messages you approve. Sign in to T3 Connect to use guest links."

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        // LabsSettingsPanel.tsx:31-51 (4928): the legacy sidebar opt-in is gone (#33131).
        let folders = clientSwitch("boring-sidebar",
            "Group sidebar threads into project folders. Pinned threads stay on top, and Snoozed and Settled stay below the folders.",
            key: "boringSidebarEnabled", label: "Boring sidebar (group by project)", title: "Boring sidebar (group by project)")
        // Redesign names the row for what it does; T3's label stays in the default themes.
        let redesign = ThemeRuntime.isDither(dark: false) || ThemeRuntime.isDither(dark: true)
        if redesign { folders.title = "Project folders in the sidebar" }
        // `BoringSidebarMultilineRow` (LabsSettingsPanel.tsx:54-80 at 4928, #26463), shown while the boring sidebar is on.
        let multiline = clientSwitch("boring-sidebar-multiline",
            "In the boring sidebar, show folder threads on two lines: the title, then the branch, pull request, and agent.",
            key: "boringSidebarMultilineRows", label: "Two-line folder rows", title: "Two-line folder rows")
        if redesign { multiline.detail = "Show folder threads on two lines: the title, then the branch, pull request, and agent." }
        binder.add { [weak self, weak folders, weak multiline] in
            guard let self, let folders, let multiline else { return }
            multiline.isHidden = !self.context.client.bool("boringSidebarEnabled")
            // `devicePreference` (#42884, LabsSettingsPanel.tsx:64, :93, settingsLayout.tsx:384, :476-477).
            let inert = self.context.scope.isProjectScope ? Self.deviceReadOnlyReason : nil
            for r in [folders, multiline] where r.inertReason != inert { r.inertReason = inert }
        }
        let guest = serverSwitch("guest-links", Self.guestDetail, key: "guestSharingEnabled", reset: nil, label: "Guest links")
        guest.title = "Guest links"
        // T3's copy names the Connections group for links and its Sharing & access page for guests (LabsSettingsPanel.tsx at 3814).
        let connections: (title: String, action: @MainActor () -> Void) = ("Connections", { [weak self] in self?.context.openSection?(.connections) })
        let access: (title: String, action: @MainActor () -> Void) = ("Sharing & access", { [weak self] in self?.context.openSection?(.access) })
        // Kept aside, so the row can swap between the switch and Sign in.
        let toggle = guest.control
        let signIn = ButtonView("Sign in", variant: .outline, size: .sm)
        signIn.action = { [weak self] in self?.context.signInToConnect?() }
        binder.add { [weak self, weak guest] in
            guard let self, let guest else { return }
            // Servers before Nightly 3655 have no guest links (settings.ts:1166).
            guest.isHidden = !self.context.scope.allStore("guestSharingEnabled")
            let signedOut = self.context.connectSignedOut
            guest.detail = signedOut ? Self.guestSignedOutDetail : Self.guestDetail
            guest.detailLink = signedOut ? nil : access
            let control = signedOut ? signIn : toggle
            if guest.control !== control { guest.control = control }
        }
        // `LinkedEnvironmentsRow` (LabsSettingsPanel.tsx:101-128 at 3814), per environment like Guest links.
        let linked = serverSwitch("linked-environments-beta", Self.linkedDetail, key: "linkedEnvironmentsEnabled", reset: nil, label: "Linked environments")
        linked.title = "Linked environments"
        linked.detailLink = connections
        binder.add { [weak self, weak linked] in
            guard let self, let linked else { return }
            // Servers before Nightly 3814 can't link (settings.ts:1209, environment.ts:139-142).
            linked.isHidden = !self.context.scope.allStore("linkedEnvironmentsEnabled")
        }
        // `PromptSuggestionsRow` (LabsSettingsPanel.tsx:189-213, #28047): the composer shows the provider's predicted next
        // message. Servers before 4928 don't store the key, so the row waits for one that does.
        let suggestions = serverSwitch("prompt-suggestions-beta",
            "Show a predicted next message in the empty composer after a Claude or Codex turn. Tab uses it. Each is an extra cached request on your plan. Needs Codex 0.165+. Claude threads update on restart.",
            key: "promptSuggestionsEnabled", reset: nil, label: "Suggest next prompt")
        binder.add { [weak self, weak suggestions] in
            guard let self, let suggestions else { return }
            suggestions.isHidden = !self.context.scope.allStore("promptSuggestionsEnabled")
        }
        let (workflows, skippedRuns) = workflowRows()
        let feedback = agentFeedbackRow()
        // #33131 removed the Legacy features section: plan mode and the context window indicator.
        items = [section("beta", "Beta", [folders, multiline, guest, linked, workflows, skippedRuns, suggestions, feedback]), candySection()]
        binder.refresh()
    }

    isolated deinit { unsubscribe.forEach { $0() } }

    static let agentFeedbackModes: [(value: String, label: String, detail: String)] = [
        ("off", "Off", "Agents send no feedback to the T3 team."),
        ("on-request", "When I ask", "When you ask, agents show you a short report about T3 Code and send it to the T3 team if you approve."),
        ("auto", "Automatic", "Agents also report T3 Code problems they hit on their own, such as a T3 tool that failed."),
    ]

    /// `AgentFeedbackRow` (5258 LabsSettingsPanel.tsx:398-468): only when every connected machine in scope has
    /// `agentFeedback`, never at a project scope. The server sends reports through its analytics service
    /// (FeedbackStore.ts:208), which servers CandyWrapper starts keep off, so the settings controller drops the
    /// capability for those and the row stays hidden there (docs/decisions.md, 2026-11-25).
    private func agentFeedbackRow() -> SettingsRowView {
        let modes = Self.agentFeedbackModes
        let (row, select) = serverSelect("agent-feedback", nil, key: "agentFeedback", options: modes.map { ($0.value, $0.label) },
                                         width: 160, reset: nil, label: "Agent feedback",
                                         current: { $0["agentFeedback"].objectValue?["mode"]?.stringValue ?? "off" })
        select.onChange = { [weak self] i in self?.context.patchServer(["agentFeedback": .object(["mode": .string(modes[i].value)])]) }
        binder.add { [weak self, weak row] in
            guard let self, let row else { return }
            row.isHidden = self.context.scope.isProjectScope || !self.context.scope.allSupport("agentFeedback")
            let mode = self.server["agentFeedback"].objectValue?["mode"]?.stringValue ?? "off"
            row.detail = self.context.scope.isMixed(["agentFeedback"]) ? "The selected machines use different agent feedback modes."
                : modes.first { $0.value == mode }?.detail ?? modes[0].detail
        }
        return row
    }

    static let workflowsDetail = "Run multi-step workflows from files in the workflows folder of this server's T3 home. Open them from the command palette. While off, nothing in that folder runs; runs wait until it is on again."

    /// `WorkflowsRow` and `WorkflowSkippedRunsRow` (5258 LabsSettingsPanel.tsx:212-290, e414cfd4be #38882, c6162da7ec
    /// #42353). Servers before 5258 don't store the switch, so it waits for one that does; the number shows only
    /// while workflows are on.
    private func workflowRows() -> (SettingsRowView, SettingsRowView) {
        let workflows = serverSwitch("workflows-beta", Self.workflowsDetail, key: "workflowsEnabled", reset: nil, label: "Workflows")
        // A plain `w-24` field: T3's `NumberField` here has no steppers, and commits on Enter or blur.
        let field = InputView(placeholder: "", text: "", size: .sm)
        field.frame.size = NSSize(width: 96, height: 28)
        field.setAccessibilityLabel("Skipped runs kept")
        let kept = row("workflow-skipped-runs",
                       detail: "How many skipped runs each workflow keeps in its history. Older skipped runs are deleted; runs that did something are always kept.",
                       control: field)
        _ = bindServerRow(kept, keys: ["workflowSkippedRunsKept"], reset: "skipped runs kept")
        field.onCommit = { [weak self, weak field] text in
            guard let self else { return }
            let mixed = self.context.scope.isMixed(["workflowSkippedRunsKept"])
            if let n = Int(text.trimmingCharacters(in: .whitespaces)) {
                let value = min(max(n, 0), 10_000)
                if mixed || self.server["workflowSkippedRunsKept"].intValue != value {
                    self.context.patchServer(["workflowSkippedRunsKept": .number(Double(value))])
                }
            }
            field?.text = mixed ? "" : self.server["workflowSkippedRunsKept"].intValue.map(String.init) ?? "500"
        }
        binder.add { [weak self, weak workflows, weak kept, weak field] in
            guard let self, let workflows, let kept, let field else { return }
            workflows.isHidden = !self.context.scope.allStore("workflowsEnabled")
            kept.isHidden = workflows.isHidden || !self.server.bool("workflowsEnabled")
            let mixed = self.context.scope.isMixed(["workflowSkippedRunsKept"])
            field.placeholder = mixed ? "Mixed" : ""
            if !field.state.focused { field.text = mixed ? "" : self.server["workflowSkippedRunsKept"].intValue.map(String.init) ?? "500" }
        }
        return (workflows, kept)
    }

    private func candySection() -> SettingsSectionView {
        let rows = Self.candyToggles.map { toggle in
            let sw = SwitchView(isOn: toggle.isOn())
            sw.setAccessibilityLabel(toggle.title)
            sw.onChange = { on in toggle.set(on) }
            let r = row(toggle.id, title: toggle.title, detail: toggle.detail, control: sw)
            binder.add { [weak sw, weak r] in
                sw?.isOn = toggle.isOn()
                let blocked = toggle.needsRedesign && !ThemeLibrary.shared.isRedesignOn
                sw?.isEnabled = !blocked
                r?.detail = blocked ? "\(toggle.detail) Needs Redesign." : toggle.detail
            }
            unsubscribe.append(toggle.observe { [weak self] in self?.refresh() })
            return r
        }
        return section("candywrapper-experiments", "CandyWrapper experiments", rows)
    }
}
