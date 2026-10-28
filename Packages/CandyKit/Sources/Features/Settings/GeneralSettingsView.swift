import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Settings > General (SettingsPanels.tsx `GeneralSettingsPanel`, ProjectDefaultsSettings.tsx with
/// `category="general"`, NotificationSettings.tsx). Rows, copy and order are T3's; values come from the
/// context and changes go through it (client keys to this device, server keys to the scope's environments).
public final class GeneralSettingsView: SettingsPageBase {
    private let sentence: SettingsScopeSentenceView
    private let boundary = SettingsNoticeView("")
    private var autoSettleRows: [SettingsRowView] = []
    private var daysRow: SettingsRowView?
    private var legacy: SettingsFoldedSectionView?
    var usesBoundary = true

    public init(context: SettingsPageContext, groups: Set<String>? = nil) {
        sentence = SettingsScopeSentenceView(context: context)
        super.init(context: context)
        var items: [NSView & SettingsGroupRow] = [sentence, boundary]
        if groups?.contains("project-defaults") != false { items.append(newThreadsSection()) }
        if groups?.contains("organization") != false { items.append(organizationSection()) }
        if groups?.contains("behavior") != false { items.append(behaviorSection()) }
        if groups?.contains("projects-and-threads") != false { items.append(projectsSection()) }
        if groups?.contains("confirmations") != false { items.append(confirmationsSection()) }
        if groups?.contains("text-generation") != false { items.append(textGenerationSection()) }
        if groups?.contains("about") != false { items.append(aboutSection()) }
        if groups?.contains("Diagnostics") != false { items.append(diagnosticsSection()) }
        if groups?.contains("legacy-features") != false {
            let legacy = legacySection()
            self.legacy = legacy
            items.append(legacy)
        }
        self.items = items
        binder.add { [weak self] in
            guard let self else { return }
            self.sentence.refresh()
            let message = self.usesBoundary ? self.context.scope.boundaryMessage : nil
            self.boundary.isHidden = message == nil
            self.boundary.message = message ?? ""
            // The scope boundary replaces the page body with its notice.
            for item in self.items.dropFirst(2) { item.isHidden = message != nil }
        }
    }

    override var scopeItems: [NSView] { [sentence, boundary] }

    /// Unfolds Legacy features for a search jump to one of its rows (`LEGACY_FEATURE_TARGET_IDS`).
    public override func anchor(_ id: String) -> NSView? {
        if ["legacy-plan-mode", "legacy-context-window-indicator", "legacy-sidebar"].contains(id) { legacy?.isOpen = true; onHeightChange?() }
        return super.anchor(id)
    }

    /// "Compact idle threads" (SettingsPanels.tsx:973-1020, `scopedIdleCompaction` scopedSettings.ts:149-155): targets
    /// compare by the mode each resolves to, and "Never" is offered only when every target can store it.
    private func idleCompactionRow() -> SettingsRowView {
        let modes = ServerSettingsValues.idleCompactionModes
        let select = settingsSelect(modes.map(\.label), width: 224)
        select.setAccessibilityLabel("Compact idle threads")
        let r = row("compact-idle-threads",
                    detail: "When to compact an idle Claude thread over 200,000 tokens: after you return, just before its prompt cache expires, or never. Each Claude provider can override this.",
                    control: select)
        _ = bindServerRow(r, keys: ["idleCompaction", "compactIdleThreads"], reset: "compact idle threads",
                          isDefault: { [weak self] in self?.server.globalIdleCompaction == "onReturn" },
                          resetPatch: { ["idleCompaction": .string("onReturn")] })
        select.onChange = { [weak self] i in self?.context.patchServer(["idleCompaction": .string(modes[i].value)]) }
        binder.add { [weak self, weak select] in
            guard let self, let select else { return }
            let targets = self.context.scope.targets
            let resolved = Set(targets.map(\.settings.globalIdleCompaction))
            select.placeholder = self.context.scope.connected.isEmpty ? "Unavailable" : "Mixed"
            select.selectedIndex = resolved.count > 1 ? nil : modes.firstIndex { $0.value == self.server.globalIdleCompaction }
            // A server from before modes has only the on/off switch, so it cannot store "Never".
            select.disabledOptions = targets.allSatisfy(\.settings.readsIdleCompactionModes) ? [] : [modes.count - 1]
        }
        return r
    }

    // MARK: New threads (ProjectDefaultsSettings.tsx:252-385)

    private func newThreadsSection() -> SettingsSectionView {
        let model = SettingsModelPickerControl(context: context, key: "defaultModelSelection")
        let modelRow = row("default-model", title: "Model", detail: "Default model for new threads. Projects can override it.", control: model)
        _ = bindServerRow(modelRow, keys: ["defaultModelSelection"], reset: "default model", resetPatch: { ["defaultModelSelection": .null] })
        binder.add { [weak self, weak modelRow, weak model] in
            guard let self else { return }
            model?.refresh()
            let scope = self.context.scope
            let mixed = scope.isMixed(["defaultModelSelection"])
            let overridden = scope.isProjectScope && scope.source(["defaultModelSelection"]) == .project
            modelRow?.status = scope.connected.isEmpty || mixed || overridden || self.server["defaultModelSelection"] != .null ? nil : "Automatic"
        }

        let modes = RuntimeMode.all.map { (value: $0.rawValue, label: ComposerPickers.modes[$0]!.label) }
        let (permissions, permissionSelect) = serverSelect("default-permissions", "Default permissions for new threads. Projects can override them.",
                                                           key: "defaultRuntimeMode", options: modes, width: nil, reset: "default permissions",
                                                           label: "Default permissions")
        permissionSelect.optionDetails = RuntimeMode.all.map { ComposerPickers.modes[$0]!.description }
        binder.add { [weak self, weak permissionSelect] in
            guard let self, let select = permissionSelect else { return }
            let mode = RuntimeMode(rawValue: self.server.string("defaultRuntimeMode"))
            let mixed = self.context.scope.isMixed(["defaultRuntimeMode"])
            select.leading = mixed ? nil : IconView(name: (ComposerPickers.modes[mode] ?? ComposerPickers.modes[.fullAccess]!).icon, size: 14,
                                                     strokeColor: Themed.color(\.mutedForeground))
        }

        let (workspace, _) = serverSelect("new-threads", "Where new threads start. Projects and their t3.json can override it.",
                                          key: "defaultThreadEnvMode", options: [("local", "Current checkout"), ("worktree", "New worktree")],
                                          width: nil, reset: nil, label: "Default workspace",
                                          current: { $0["defaultThreadEnvMode"].stringValue ?? "local" })
        workspace.title = "Workspace"
        resetToNull(workspace, key: "defaultThreadEnvMode", label: "default workspace")

        let (submodules, _) = serverSelect("worktree-submodules", "How new worktrees populate git submodules. Projects and their t3.json can override it.",
                                           key: "worktreeSubmodules", options: [("recursive", "Recursive"), ("top-level", "Top level only"), ("none", "Skip")],
                                           width: nil, reset: nil, label: "Worktree submodules",
                                           current: { $0["worktreeSubmodules"].stringValue ?? "recursive" })
        resetToNull(submodules, key: "worktreeSubmodules", label: "worktree submodules")
        // ProjectDefaultsSettings.tsx: the same rows describe the project's own value at a project scope.
        projectScopeDetails([(modelRow, "Model for new threads in this project.", "Default model for new threads. Projects can override it."),
                             (permissions, "Permissions for new threads in this project.", "Default permissions for new threads. Projects can override them."),
                             (workspace, "Where new threads in this project start.", "Where new threads start. Projects and their t3.json can override it."),
                             (submodules, "How new worktrees in this project populate git submodules.",
                              "How new worktrees populate git submodules. Projects and their t3.json can override it.")])
        return section("project-defaults", "New threads", [modelRow, permissions, workspace, submodules])
    }

    /// File-backed keys reset to null (inherit), not to a value. At a project scope the row's own reset clears the override.
    func resetToNull(_ r: SettingsRowView, key: String, label: String) {
        guard let slot = r.accessories.last as? ResetSlot else { return }
        slot.button.setAccessibilityLabel("Reset \(label) to default")
        slot.action = { [weak self] in
            guard let self else { return }
            if self.context.scope.isProjectScope { self.context.clearServer?([key]) } else { self.context.patchServer([key: .null]) }
        }
        binder.add { [weak self] in
            guard let self, !self.context.scope.isProjectScope else { return }
            slot.isShown = self.server[key] != .null && self.context.scope.inertReason == nil
        }
    }

    // MARK: Organization (SettingsPanels.tsx:2265-2482)

    private func organizationSection() -> SettingsSectionView {
        let grouping = clientSwitch("project-grouping", "Combine matching repositories across environments.", key: "sidebarProjectGroupingMode",
                                    reset: "project grouping", read: { $0.string("sidebarProjectGroupingMode") != "separate" },
                                    write: { on in
                                        // `projectGroupingModeFromToggle` with the remembered mode.
                                        let last = UserDefaults.standard.string(forKey: "settings.lastEnabledProjectGroupingMode") == "repository_path"
                                            ? "repository_path" : "repository"
                                        if !on {
                                            let current = ClientSettingsStore.shared.current.string("sidebarProjectGroupingMode")
                                            if current != "separate" { UserDefaults.standard.set(current, forKey: "settings.lastEnabledProjectGroupingMode") }
                                        }
                                        return ["sidebarProjectGroupingMode": .string(on ? last : "separate")]
                                    })
        let order = clientSelect("project-order", "Order of projects in the sidebar project picker and command palette.", key: "sidebarProjectSortOrder",
                                 options: [("updated_at", "Last user message"), ("created_at", "Created at"), ("manual", "Manual")], width: 176,
                                 reset: "project order")
        let options = snoozeOptionsRow()
        let resume = serverSwitch("auto-resume-limited-threads",
                                  "Resume usage-limit stops at the reported reset time. Each thread can cancel its scheduled continuation.",
                                  key: "autoResumeLimitedThreads", reset: nil)
        let snooze = serverSwitch("snooze-limited-threads",
                                  "Snooze usage-limit stops until the reported reset time. Combine with auto-resume to continue when they wake.",
                                  key: "snoozeLimitedThreads", reset: nil)
        // SettingsPanels.tsx:973-1020, before the auto-settle rows.
        let compact = idleCompactionRow()
        let merged = serverSwitch("auto-settle-merged-threads",
                                  "Settle a thread when its pull request merges. Closed pull requests still settle automatically.",
                                  key: "sidebarAutoSettleOnMerge", reset: "auto-settle on merge")
        let inactive = serverSwitch("auto-settle-inactive-threads", "Sidebar threads with no activity for this long settle automatically.",
                                    key: "sidebarAutoSettleAfterDays", reset: "auto-settle",
                                    read: { $0["sidebarAutoSettleAfterDays"] != .null },
                                    write: { on in ["sidebarAutoSettleAfterDays": on ? .number(3) : .null] })
        let keep = serverSwitch("auto-settle-keep-pull-requests", "Inactivity does not settle threads with a pull request. Merge and close still do.",
                                key: "sidebarAutoSettleKeepPullRequests", reset: "keep threads with pull requests", label: "Keep threads with a PR")
        // 3669 keeps this row out of settings search (SettingsPanels.tsx:1104-1105), so the title is set here.
        keep.title = "Keep threads with a PR"
        binder.add { [weak self, weak keep] in
            keep?.isHidden = self?.context.scope.allSupport("threadAutoSettlementScope") != true || self?.server["sidebarAutoSettleAfterDays"] == .null
        }
        let days = InputView(placeholder: "", text: "", size: .sm)
        days.frame.size = NSSize(width: 96, height: 28)
        days.setAccessibilityLabel("Days of inactivity before auto-settle")
        let daysRow = row(nil, title: SettingsSearch.title("days-before-auto-settle"), detail: "Any new activity un-settles a thread automatically.", control: days)
        _ = bindServerRow(daysRow, keys: ["sidebarAutoSettleAfterDays"], reset: nil)
        // `AutoSettleDaysInput`: commits whole numbers 1 to 90 as typed, snaps back on blur.
        days.onChange = { [weak self, weak days] text in
            guard let self, days?.state.focused == true, let n = Int(text.trimmingCharacters(in: .whitespaces)), (1...90).contains(n),
                  self.server["sidebarAutoSettleAfterDays"].intValue != n else { return }
            self.context.patchServer(["sidebarAutoSettleAfterDays": .number(Double(n))])
        }
        days.onCommit = { [weak self, weak days] _ in
            guard let self else { return }
            days?.text = self.server["sidebarAutoSettleAfterDays"].intValue.map(String.init) ?? ""
        }
        autoSettleRows = [merged, inactive]
        self.daysRow = daysRow
        binder.add { [weak self, weak days, weak daysRow, weak merged, weak inactive] in
            guard let self else { return }
            let supported = self.context.scope.allSupport("threadAutoSettlement")
            merged?.isHidden = !supported
            inactive?.isHidden = !supported
            daysRow?.isHidden = !supported || self.server["sidebarAutoSettleAfterDays"] == .null
            if let days, !days.state.focused { days.text = self.server["sidebarAutoSettleAfterDays"].intValue.map(String.init) ?? "" }
        }
        let s = section("organization", "Organization", [grouping, order, options, resume, snooze, compact, merged, inactive, daysRow, keep])
        binder.add { [weak s] in
            guard let s else { return }
            // Hidden rows leave the card, like T3's conditional rendering.
            s.group.rows = s.group.rows
        }
        return s
    }

    func addWorkingShelfRow() {
        guard let organization = anchors["organization"] as? SettingsSectionView else { return }
        let working = clientSwitch("working-shelf", "Fold working and monitoring threads into a Working section. They return to the top of the inbox when they need you.", key: "sidebarWorkingShelfEnabled", title: "Working section")
        organization.group.rows.insert(working, at: min(2, organization.group.rows.count))
    }

    private func snoozeOptionsRow() -> SettingsRowView {
        let editor = SnoozePresetsEditor()
        let r = row("snooze-options", title: "Snooze options",
            detail: "Choices in every snooze menu, listed soonest first. Weekdays mean the next one after today.")
        r.footer = editor
        _ = bindServerRow(r, keys: ["snoozePresets"], reset: "snooze options")
        editor.onChange = { [weak self] values in
            guard let self, self.context.scope.allStore("snoozePresets"), self.context.scope.canWrite else { return }
            self.context.patchServer(["snoozePresets": .array(values.map(\.json))])
        }
        editor.onHeightChange = { [weak self] in self?.onHeightChange?() }
        binder.add { [weak self, weak editor, weak r] in
            guard let self else { return }
            r?.isHidden = !self.context.scope.allStore("snoozePresets")
            editor?.refresh(SnoozePresetSetting.decode(self.server["snoozePresets"]),
                sourceKey: self.context.scope.targets.map { $0.environmentId + ":" + ($0.projectId ?? "") }.joined(separator: "\n"),
                failureRevision: self.context.serverWriteFailureRevision)
        }
        return r
    }

    // MARK: Behavior (SettingsPanels.tsx:2484-3043)

    private func behaviorSection() -> SettingsSectionView {
        let notificationsDetail = "System alerts when a thread finishes, fails, or needs input or approval. Applies to this device while T3 Code is open."
        let modes = ThreadNotificationMode.allCases
        let notifications = clientSelect("thread-notifications", notificationsDetail, key: "notificationMode",
                                         options: modes.map { ($0.rawValue, $0.label) }, width: 224)
        // NotificationSettings.tsx:31-66: a mode with system alerts asks for permission before it is saved, and a
        // refusal keeps the old mode with T3's message in place of the description.
        if let select = notifications.control as? SelectView {
            select.onChange = { [weak self, weak select, weak notifications] i in
                guard let self else { return }
                guard let choose = self.context.chooseNotificationMode else {
                    self.context.writeClient?(["notificationMode": .string(modes[i].rawValue)])
                    return
                }
                notifications?.detail = notificationsDetail
                select?.isEnabled = false
                Task { @MainActor in
                    let message = await choose(modes[i])
                    select?.isEnabled = true
                    notifications?.detail = message ?? notificationsDetail
                    // A refused mode leaves the select on the stored one.
                    select?.selectedIndex = modes.firstIndex { $0.rawValue == self.client.string("notificationMode") }
                    notifications?.needsLayout = true
                }
            }
        }
        let inApp = clientSwitch("in-app-notifications",
                                 "Show a toast when another thread finishes, fails, or needs input or approval while this app has focus.",
                                 key: "inAppNotificationsEnabled")
        let time = clientSelect("time-format", "System default follows your browser or OS clock preference.", key: "timestampFormat",
                                options: [("locale", "System default"), ("12-hour", "12-hour"), ("24-hour", "24-hour")], width: 160,
                                reset: "time format", label: "Timestamp format")
        let (streaming, _) = serverSelect("response-streaming", nil, key: "responseStreamingMode",
                                          options: [("turn", "Wait for the full response"), ("paragraph", "Show finished paragraphs")], width: 224,
                                          reset: "response streaming")
        binder.add { [weak self, weak streaming] in
            guard let self else { return }
            streaming?.detail = self.context.scope.isMixed(["responseStreamingMode"]) ? "The selected targets use different streaming modes."
                : self.server.string("responseStreamingMode") == "turn" ? "Text appears once the agent finishes its turn."
                : "Each paragraph or code block appears as soon as it is complete."
        }
        let whitespace = clientSwitch("hide-whitespace-changes", "Set whether the diff panel ignores whitespace-only edits by default.",
                                      key: "diffIgnoreWhitespace", reset: "diff whitespace changes", label: "Hide whitespace changes by default")
        let fileState = clientSelect("default-diff-file-state", "Start with files expanded or collapsed when opening diffs or a pull request's Code tab.",
                                     key: "diffFilesCollapsed", options: [("expanded", "Expanded"), ("collapsed", "Collapsed")], width: 160,
                                     reset: "default diff file state")
        rebindBoolSelect(fileState, key: "diffFilesCollapsed", trueValue: "collapsed", options: ["expanded", "collapsed"])
        let layout = clientSelect("diff-layout", "Show diffs stacked or side by side. The toggle in the diff toolbar changes this too.", key: "diffLayout",
                                  options: [("stacked", "Stacked"), ("split", "Split")], width: 160, reset: "diff layout")
        let proactive = clientSwitch("proactive-panels", "Open linked pull requests first. Otherwise, open Changes for edits to at least 3 files or 50 lines.",
                                     key: "proactivePanelsEnabled", reset: "proactive panels")
        let skills = clientSwitch("skills-in-slash-menu", "Also include skills in the / command menu. Skills always appear when you type $.",
                                  key: "showSkillsInSlashMenu", reset: "skills in slash menu")
        let rich = clientSwitch("composer-rich-text", "Show formatted Markdown as you type.", key: "composerRichTextEnabled", reset: "rich text composer")
        let collapse = clientSwitch("composer-collapse",
                                    "Rest the composer of an existing thread into a single line when you scroll the conversation. Focus the composer or start typing to expand it again.",
                                    key: "composerCollapseOnScroll", reset: "collapse composer on scroll")
        let send = clientSelect("send-shortcut", "Choose when Enter sends a prompt or inserts a new line", key: "sendShortcut",
                                options: [("enter", "Enter"), ("mod-enter-multiline", "⌘ + Enter for multiline prompts"), ("mod-enter", "⌘ + Enter always")],
                                width: nil, reset: "send shortcut", hideIndicator: false)
        let followUp = clientSelect("follow-up-behavior", nil, key: "followUpBehavior", options: [("queue", "Queue"), ("steer", "Steer")], width: nil,
                                    reset: "follow-up behavior", hideIndicator: false)
        binder.add { [weak self, weak followUp] in
            guard let self else { return }
            let shortcut = self.client.string("sendShortcut")
            followUp?.detail = "Queue follow-ups while the agent runs or steer the current run. " + (shortcut == "mod-enter-multiline"
                ? "Press ⌘ + Enter for single-line prompts or ⌘ + Shift + Enter for multiline prompts to do the opposite for one message."
                : "Press ⌘\(shortcut == "mod-enter" ? " + Shift" : "") + Enter to do the opposite for one message.")
        }
        let updates = serverSwitch("provider-update-checks", "Check installed provider CLIs for newer available versions.",
                                   key: "enableProviderUpdateChecks", reset: "provider update checks", label: "Check provider versions")
        let continueRow = serverSwitch("continue-threads-after-server-update",
                                       "Automatically resume interrupted threads after an update, crash, or machine restart on the selected environments.",
                                       key: "continueThreadsAfterServerUpdate", reset: "continue threads after restarts")
        binder.add { [weak self, weak continueRow] in
            guard let self, let continueRow else { return }
            let supported = self.context.scope.allSupport("threadRestartContinuation")
            continueRow.status = supported ? nil : "All selected connected environments must support restart continuation."
            (continueRow.control as? SwitchView)?.isEnabled = supported
            if !supported { (continueRow.accessories.last as? ResetSlot)?.isShown = false }
        }
        // CandyWrapper's own: the menu bar item (Capy's "Show in menu bar", general-D4mfTeHV.js in its renderer).
        let menuBar = clientSwitch("menu-bar", "Keep the CandyWrapper icon and recent threads in the menu bar.", key: "menuBarItemEnabled",
                                   reset: "menu bar icon", title: "Show in menu bar")
        return section("behavior", "Behavior", [notifications, inApp, time, streaming, whitespace, fileState, layout, proactive, skills, rich, collapse,
                                                send, followUp, updates, continueRow, backgroundActivityRow(), menuBar])
    }

    /// A select over a boolean client key.
    private func rebindBoolSelect(_ r: SettingsRowView, key: String, trueValue: String, options: [String]) {
        guard let select = r.control as? SelectView else { return }
        select.onChange = { [weak self] i in self?.context.writeClient?([key: .bool(options[i] == trueValue)]) }
        binder.add { [weak self, weak select] in
            guard let self else { return }
            select?.selectedIndex = options.firstIndex(of: self.client.bool(key) ? trueValue : options.first { $0 != trueValue }!)
        }
    }

    /// Background activity (SettingsPanels.tsx:2950-3041): the profile select, a gear for Advanced, and the dialog.
    private func backgroundActivityRow() -> SettingsRowView {
        let labels = ["balanced": "Balanced", "performance": "Performance", "battery-saver": "Battery saver", "advanced": "Advanced"]
        let descriptions = ["balanced": "Pauses probes for idle clients, locked hosts, or low power mode.",
                            "performance": "Allows scoped background probes while any subscribed client remains connected.",
                            "battery-saver": "Also pauses background probes when the host or client is on battery."]
        let values = ["balanced", "performance", "battery-saver", "advanced"]
        let select = settingsSelect(values.map { labels[$0]! }, width: 160)
        select.setAccessibilityLabel("Background activity profile")
        let gear = ButtonView(nil, icon: .settings, variant: .outline, size: .iconSm)
        gear.setAccessibilityLabel("Configure advanced background activity")
        _ = TooltipController.attach(to: gear, text: "Configure background activity")
        let group = SettingsControlGroup([select, gear])
        let r = row("background-activity", detail: "", control: group)
        let info = ButtonView(nil, icon: .info, variant: .ghostMuted, size: .iconMicro)
        info.iconSize = 14
        let policy = "This shared policy gates background work such as Git refreshes and provider health probes after their individual intervals elapse."
        info.setAccessibilityLabel("Background policy details")
        _ = TooltipController.attach(to: info, text: policy, delay: 0.2)
        _ = bindServerRow(r, keys: ["backgroundActivity"], reset: "background activity",
                          isDefault: { [weak self] in !(self.map { BackgroundActivity.isChanged($0.server) } ?? false) },
                          resetPatch: { ["backgroundActivity": BackgroundActivity.defaultSettings] }, extra: [info])
        select.onChange = { [weak self] i in
            guard let self else { return }
            let value = values[i]
            if value == "advanced" {
                if self.context.scope.isEnvironmentScope { self.openBackgroundActivityDialog() }
                self.binder.refresh()
                return
            }
            self.context.patchServer(["backgroundActivity": BackgroundActivity.profileSettings(value)])
        }
        gear.action = { [weak self] in self?.openBackgroundActivityDialog() }
        binder.add { [weak self, weak select, weak gear, weak r, weak group] in
            guard let self, let select else { return }
            let option = BackgroundActivity.profileOption(self.server)
            let mixed = self.context.scope.isMixed(["backgroundActivity"])
            select.placeholder = "Mixed"
            select.selectedIndex = mixed ? nil : values.firstIndex(of: option)
            select.options = values.map { $0 == "advanced" && !self.context.scope.isEnvironmentScope ? "Advanced (one environment)" : labels[$0]! }
            select.disabledOptions = self.context.scope.isEnvironmentScope ? [] : [3]
            if !mixed, let i = select.selectedIndex { select.options[i] = labels[values[i]]! }
            gear?.isHidden = !(option == "advanced" && self.context.scope.isEnvironmentScope)
            group?.invalidateIntrinsicContentSize()
            let resolved = BackgroundActivity.resolveServer(self.server)
            r?.detail = option == "advanced" ? "Uses custom intervals. Shared policy: \(labels[resolved.profile]!)." : descriptions[resolved.profile]
        }
        return r
    }

    private func openBackgroundActivityDialog() {
        let dialog = BackgroundActivityDialog.make(context: context)
        _ = context.presentDialog?(dialog)
    }

    // MARK: Projects & threads, Confirmations

    private func projectsSection() -> SettingsSectionView {
        let origin = serverSwitch("start-from-origin", "Uses the latest commit of the base branch’s tracked remote branch, even if its name differs. Otherwise uses the same-named branch on origin. Uses your local branch if that remote branch is missing.",
                                  key: "newWorktreesStartFromOrigin", reset: "new worktrees start from remote",
                                  label: "Start new worktrees from remote by default")
        let input = InputView(placeholder: "~/", text: "", size: .sm)
        input.frame.size = NSSize(width: 288, height: 28)
        input.setAccessibilityLabel("Add project base directory")
        let base = row("add-project-starts-in", detail: "Leave empty to use \"~/\" when the Add Project browser opens.", control: input)
        _ = bindServerRow(base, keys: ["addProjectBaseDirectory"], reset: "add project base directory")
        // `DraftInput`: commits on Return or blur.
        input.onCommit = { [weak self] text in
            guard let self, !self.context.scope.isMixed(["addProjectBaseDirectory"]) || !text.isEmpty else { return }
            let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if next != self.server.string("addProjectBaseDirectory") { self.context.patchServer(["addProjectBaseDirectory": .string(next)]) }
        }
        binder.add { [weak self, weak input] in
            guard let self, let input, !input.state.focused else { return }
            let mixed = self.context.scope.isMixed(["addProjectBaseDirectory"])
            input.text = mixed ? "" : self.server.string("addProjectBaseDirectory")
            input.placeholder = mixed ? "Mixed" : "~/"
        }
        return section("projects-and-threads", "Projects & threads", [origin, base])
    }

    private func confirmationsSection() -> SettingsSectionView {
        let unpin = clientSwitch("unpin-confirmation", "Ask before unpinning a thread from the pinned section.", key: "confirmThreadUnpin",
                                 reset: "unpin confirmation", label: "Confirm thread unpinning")
        let archive = clientSwitch("archive-confirmation", "Require a second click on the inline archive action before a thread is archived.",
                                   key: "confirmThreadArchive", reset: "archive confirmation", label: "Confirm thread archiving")
        let delete = clientSwitch("delete-confirmation", "Ask before deleting a thread and its chat history.", key: "confirmThreadDelete",
                                  reset: "delete confirmation", label: "Confirm thread deletion")
        // ponytail: the quit shortcut stores its mode; Cmd+Q's hold and double press come with WP7.8 (desktop parts)
        let quit = clientSelect("quit-confirmation", "Hold mode also quits on two quick presses.", key: "confirmQuit",
                                options: [("direct", "Direct"), ("hold", "Hold"), ("double-click", "Double press")], width: 160,
                                reset: "quit shortcut behavior", label: "Quit shortcut behavior")
        return section("confirmations", "Confirmations", [unpin, archive, delete, quit])
    }

    // MARK: Text generation, About, Diagnostics, Legacy

    private func textGenerationSection() -> SettingsSectionView {
        let picker = SettingsModelPickerControl(context: context, key: "textGenerationModelSelection")
        let r = row("text-generation-model",
                    detail: "Used for thread titles and other generated text on connected devices with this provider. Source control can override it.",
                    control: picker)
        _ = bindServerRow(r, keys: ["textGenerationModelSelection"], reset: "text generation model")
        binder.add { [weak picker] in picker?.refresh() }
        return section("text-generation", "Text generation", [r, threadTitleInstructionsRow()])
    }

    /// ThreadTitleInstructionsSettings.tsx (51273020db): a 4-row textarea that saves on blur when edited.
    private func threadTitleInstructionsRow() -> SettingsRowView {
        let key = "threadTitleInstructions"
        let placeholder = "Keep titles to a few words. Lead with the main subject."
        let field = TextareaView(placeholder: placeholder, size: .default)
        field.setAccessibilityLabel("Thread title instructions")
        let r = row(nil, title: "Thread title instructions", detail: "Appended to the prompt for new and regenerated thread titles.")
        anchors["thread-title-instructions"] = r
        r.footer = TextareaFooter(field)
        _ = bindServerRow(r, keys: [key], reset: "thread title instructions",
                          isDefault: { [weak self] in self.map { !$0.context.scope.isMixed([key]) && $0.server.string(key).isEmpty } ?? true },
                          resetPatch: { [key: .string("")] })
        var edited = false
        field.onChange = { [weak self] _ in edited = true; self?.onHeightChange?() }
        onBlur(field) { [weak self] text in
            guard let self else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited, self.context.scope.isMixed([key]) || value != self.server.string(key) {
                self.context.patchServer([key: .string(value)])
            }
            edited = false
        }
        binder.add { [weak self, weak r] in
            // Servers before Nightly 3553 can't store title instructions (51273020db).
            r?.isHidden = self?.context.scope.allStore(key) != true
        }
        binder.add { [weak self, weak field] in
            guard let self, let field, !field.state.focused else { return }
            let mixed = self.context.scope.isMixed([key])
            field.text = mixed ? "" : self.server.string(key)
            field.placeholder = mixed ? "Mixed. Enter instructions to apply to all selected targets." : placeholder
        }
        return r
    }

    private func aboutSection() -> SettingsSectionView {
        // AboutVersionSection (SettingsPanels.tsx:280-496).
        let check = ButtonView("Check for Updates", variant: .outline, size: .sm)
        let checkTip = TooltipController.attach(to: check, text: "")
        check.action = { [weak self] in self?.context.updateButton?() }
        let version = VersionTitleView()
        let versionRow = row("app-version", title: "Version", detail: "Current version of the application.", control: check)
        versionRow.accessories = [version]
        binder.add { [weak self, weak check, weak versionRow] in
            guard let self, let check, let versionRow else { return }
            version.version = self.context.appVersion
            let update = self.context.update
            let look = DesktopUpdateLogic.settingsButton(update)
            if check.title != look.label { check.title = look.label; versionRow.needsLayout = true }
            check.isEnabled = !look.disabled && !self.context.updateActionPending
            checkTip.text = update.map(DesktopUpdateLogic.buttonTooltip) ?? ""
            if versionRow.detail != look.description { versionRow.detail = look.description }
        }
        let runtimeButton = ButtonView("Check for Updates", variant: .outline, size: .sm)
        let runtimeTip = TooltipController.attach(to: runtimeButton, text: "")
        let runtimeVersion = VersionTitleView()
        let runtimeRow = row(nil, title: "Server runtime", detail: "", control: runtimeButton)
        runtimeRow.accessories = [runtimeVersion]
        runtimeButton.action = { [weak self] in self?.context.runtimeUpdateButton?() }
        binder.add { [weak self, weak runtimeRow, weak runtimeButton] in
            guard let self, let runtimeRow, let runtimeButton else { return }
            let state = context.runtimeUpdate
            runtimeRow.isHidden = state == nil
            runtimeVersion.version = state?.currentVersion ?? ""
            let look = DesktopUpdateLogic.settingsButton(state)
            runtimeButton.title = look.label
            runtimeButton.isEnabled = !look.disabled
            let tooltip = state.map(DesktopUpdateLogic.buttonTooltip) ?? ""
            if runtimeTip.text != tooltip { runtimeTip.hide(); runtimeTip.text = tooltip }
            runtimeRow.detail = state.map(DesktopUpdateLogic.buttonTooltip) ?? ""
            runtimeRow.needsLayout = true
        }
        let track = settingsSelect(["Stable", "Nightly"], width: 160)
        track.setAccessibilityLabel("Update track")
        track.onChange = { [weak self] index in
            let channel: DesktopUpdateState.Channel = index == 0 ? .latest : .nightly
            guard let self, channel != self.context.update?.channel else { return }
            self.context.setUpdateTrack?(channel)
        }
        binder.add { [weak self, weak track] in
            guard let self, let track else { return }
            // `updateState?.channel ?? "latest"` (:286).
            let index = (self.context.update?.channel ?? .latest) == .nightly ? 1 : 0
            if track.selectedIndex != index { track.selectedIndex = index }
            track.isEnabled = !self.context.changingUpdateTrack
        }
        let trackRow = row("update-track", title: "Update track", detail: "Use stable releases or nightly builds. Switch back anytime.", control: track)
        let policy = ButtonView("View policy", variant: .outline, size: .sm)
        policy.action = { [weak self] in self?.context.openURL?(URL(string: "https://t3.codes/privacy")!) }
        let privacy = row("privacy-policy", detail: "How we handle your data, including the anonymous usage data T3 Code collects.", control: policy)
        let mobile = row("nightly-mobile-beta", title: "Mobile app", detail: "Nightly needs the beta app. The App Store and Google Play versions cannot connect.", control: NightlyMobileBetaView())
        return section("about", "About", [versionRow, runtimeRow, trackRow, mobile, privacy])
    }

    private func diagnosticsSection() -> SettingsSectionView {
        let diag = ButtonView("View diagnostics", variant: .outline, size: .sm)
        diag.action = { [weak self] in self?.context.openSection?(.diagnostics) }
        let diagnostics = row("diagnostics", detail: "", control: diag)
        binder.add { [weak self, weak diagnostics] in
            guard let self else { return }
            diagnostics?.detail = self.context.scope.isEnvironmentScope ? "Inspect processes, resource use, and logs on this environment."
                : "Inspect processes, resource use, and logs on one environment at a time."
        }
        let lic = ButtonView("View licenses", variant: .outline, size: .sm)
        lic.action = { [weak self] in self?.context.openSection?(.licenses) }
        let licenses = row("open-source-licenses", detail: "Notices for dependencies, assets, and optional tools used by T3 Code.", control: lic)
        return section(nil, "Diagnostics", [diagnostics, licenses])
    }

    private func legacySection() -> SettingsFoldedSectionView {
        let plan = clientSwitch("legacy-plan-mode", "Restore Build/Plan, /plan, /default, and Shift+Tab. Off uses build mode.", key: "planModeEnabled")
        let meter = clientSwitch("legacy-context-window-indicator", "Shows context window usage as a circular indicator in the composer.",
                                 key: "contextWindowMeterEnabled")
        for r in [plan, meter] { r.accessories = [] }
        let folded = SettingsFoldedSectionView(title: "Legacy features", rows: [plan, meter])
        folded.onToggle = { [weak self] in self?.onHeightChange?() }
        anchors["legacy-features"] = folded
        return folded
    }
}

/// `AboutVersionTitle`'s version code after the title (`text-2xs font-medium text-muted-foreground`), baseline aligned.
final class VersionTitleView: DSView {
    private let label = LabelView("", font: DSFont.mono(11, weight: .medium), color: Themed.color(\.mutedForeground))
    var version = "" { didSet { label.text = version; needsLayout = true } }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); label.lineHeight = 16; addSubview(label) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 2, y: 3, width: max(0, superview.map { $0.bounds.width - frame.minX } ?? 200), height: 16)
    }
}

/// `LegacyFeaturesSection`: a "Legacy features" trigger with a chevron that unfolds a settings card.
final class SettingsFoldedSectionView: DSView, SettingsGroupRow {
    private let header = FoldHeaderButton()
    let group: SettingsGroupView
    var title: String { header.title }
    var onToggle: (() -> Void)?
    var isOpen = false { didSet { header.isOpen = isOpen; group.isHidden = !isOpen; needsLayout = true } }

    init(title: String, rows: [any SettingsGroupRow]) {
        group = SettingsGroupView(rows: rows)
        super.init(frame: .zero)
        header.title = title
        // `CollapsiblePanel` (SettingsPanels.tsx:2127): the card slides open over 200 ms.
        header.action = { [weak self] in
            guard let self else { return }
            CollapseMotion.run(in: self) { self.isOpen.toggle(); self.onToggle?() }
        }
        addSubview(header)
        group.isHidden = true
        addSubview(group)
    }

    func height(forWidth width: CGFloat) -> CGFloat { 32 + (isOpen ? 10 + group.height(forWidth: width) : 0) }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        if isOpen { group.frame = NSRect(x: 0, y: 42, width: bounds.width, height: group.height(forWidth: bounds.width)) }
    }

    /// `CollapsibleTrigger` (`min-h-8 px-4 gap-2`): the title turns `foreground` on hover; the chevron rotates open.
    final class FoldHeaderButton: ControlView {
        private let label = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground, 0.7))
        private let chevron = IconView(name: .chevronRight, size: 16)
        var title = "" { didSet { label.text = title; needsLayout = true } }
        /// `transition-transform duration-200`, `rotate-90` when open (SettingsPanels.tsx:2125).
        var isOpen = false { didSet { chevron.setRotation(isOpen ? 90 : 0, motion: .ease(0.2)); setAccessibilityExpanded(isOpen) } }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            transitions = [.color] // the title's `transition-colors` (SettingsPanels.tsx:2122)
            label.lineHeight = 20
            addSubview(label)
            addSubview(chevron)
            chevron.strokeColor = Themed.color(\.mutedForeground)
            setAccessibilityRole(.button)
        }
        override func stateDidChange(from old: State) {
            super.stateDidChange(from: old)
            label.color = Themed.color(\.foreground, state.hoverOrPressed ? 1 : 0.7)
        }
        override func layout() {
            super.layout()
            let w = ceil(label.textWidth) + 1
            label.frame = NSRect(x: 16, y: 6, width: w, height: 20)
            chevron.frame = NSRect(x: 16 + w + 8, y: 8, width: 16, height: 16)
        }
    }
}

/// The model picker trigger of the Model and Text generation rows (`ProviderModelPicker` with
/// `SETTINGS_PICKER_TRIGGER_CLASSNAME`): the composer's trigger look, opening the composer's model picker.
final class SettingsModelPickerControl: DSView {
    let button = ComposerControlView()
    private let traits = ComposerControlView(icon: IconView(name: .brain, size: 16)).menuTrigger()
    private let context: SettingsPageContext
    private let key: String
    private weak var popup: OpenPopup?

    init(context: SettingsPageContext, key: String) {
        self.context = context
        self.key = key
        super.init(frame: .zero)
        button.tintsIcon = false
        button.action = { [weak self] in self?.open() }
        addSubview(button)
        addSubview(traits)
        traits.action = { [weak self] in self?.openTraits() }
    }

    /// At a project scope the project's provider switches apply (ProjectDefaultsSettings.tsx:66-72, 2994).
    private var catalog: ProviderCatalog {
        let target = context.scope.target
        let settings = target.flatMap { t in context.scope.environments.first { $0.id == t.environmentId }?.settings }
        return ProviderCatalog(context.providers, settings: settings, projectId: target?.projectId)
    }

    /// The selection shown: the setting, else the first ready provider's default (`resolveDefaultProviderModelSelection`).
    private var selection: (ProviderInstanceEntry, String)? {
        let raw = context.scope.values[key]
        if let id = raw["instanceId"]?.stringValue, let model = raw["model"]?.stringValue, let entry = catalog.entry(ProviderInstanceId(rawValue: id)) {
            return (entry, model)
        }
        for entry in catalog.entries where entry.isSelectable {
            if let model = entry.defaultModel ?? entry.models.first?.slug { return (entry, model) }
        }
        return nil
    }

    func refresh() {
        if context.scope.connected.isEmpty {
            button.title = "Connect an environment"
            button.icon = nil
        } else if context.scope.isMixed([key]) {
            button.title = "Mixed"
            button.icon = nil
        } else if let (entry, slug) = selection {
            button.title = entry.models.first { $0.slug == slug }.map { ModelNames.trigger($0, driver: entry.driver) } ?? slug
            button.icon = ProviderIcon.make(driver: entry.driver, displayName: entry.displayName, size: 16, color: Themed.color(\.contrastMutedForeground))
        } else {
            button.title = "No providers available"
            button.icon = nil
        }
        traits.isHidden = descriptors.isEmpty || context.scope.isMixed([key]) || context.scope.connected.isEmpty
        traits.title = ModelTraits.triggerLabel(descriptors, ultrathink: false, provider: selection?.0.driver)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private var descriptors: [ProviderOptionDescriptor] {
        guard let (entry, slug) = selection else { return [] }
        let raw = context.scope.values[key]
        let selected = try? raw.decode(as: ModelSelection.self)
        return ModelTraits.descriptors(entry.model(slug), selections: selected?.options.flatMap { try? $0.decode(as: [ProviderOptionSelection].self) }).map { descriptor in
            var d = descriptor
            d.options.removeAll { d.promptInjectedValues?.contains($0.id) == true }
            return d
        }
    }

    private func openTraits() {
        guard let host = traits.popupHost, let (entry, slug) = selection else { return }
        let ds = descriptors
        var rows: [PickerMenuEntry] = []
        for d in ds {
            if !rows.isEmpty { rows.append(.separator) }
            rows.append(.label(d.label))
            let choices: [(String, ProviderOptionValue)] = d.type == .boolean
                ? [("On", .bool(true)), ("Off", .bool(false))]
                : d.options.map { ($0.label, .string($0.id)) }
            for (label, value) in choices {
                rows.append(.option(label, checked: ModelTraits.currentValue(d) == value) { [weak self] in
                    guard let self else { return }
                    let selection = ModelSelection(instanceId: entry.id, model: slug, options: ModelTraits.pick(ds, id: d.id, value: value).flatMap { try? JSONValue(encoding: $0) })
                    guard let json = try? JSONValue(encoding: selection) else { return }
                    self.context.patchServer([self.key: json])
                    if let popup = self.popup { self.traits.popupHost?.close(popup) }
                })
            }
        }
        let menu = PickerMenuView(entries: rows, style: .menu, minimumWidth: 158)
        popup = host.open(PickerPopupView(menu), trigger: traits, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4), motion: .popover)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: button.intrinsicContentSize.width + (traits.isHidden ? 0 : traits.intrinsicContentSize.width + 6), height: 28)
    }
    override func layout() {
        super.layout()
        button.frame = NSRect(x: 0, y: 0, width: button.intrinsicContentSize.width, height: 28)
        traits.frame = NSRect(x: button.frame.maxX + 6, y: 0, width: traits.intrinsicContentSize.width, height: 28)
    }

    private func open() {
        guard let host = button.popupHost, let (entry, slug) = selection else { return }
        let view = ModelPickerView(catalog: catalog, favorites: [], active: entry.id, activeModel: slug)
        view.onSelect = { [weak self] id, model in
            guard let self else { return }
            if let popup = self.popup { self.button.popupHost?.close(popup) }
            let value = (try? JSONValue(encoding: ModelSelection(instanceId: id, model: model))) ?? .null
            self.context.patchServer([self.key: value])
        }
        popup = host.open(PickerPopupView(view), trigger: button, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .end),
                          motion: .popover)
        button.window?.makeFirstResponder(view.search)
    }
}
