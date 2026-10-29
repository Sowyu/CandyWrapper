import AppKit
import DesignSystem
import T3Protocol

/// `Schema.Option` on the wire: `{_tag: "Some", value}` or `{_tag: "None"}`.
func optionValue(_ json: JSONValue?) -> JSONValue? {
    guard let json else { return nil }
    switch json["_tag"]?.stringValue {
    case "Some": return json["value"]
    case "None": return nil
    default: return json == .null ? nil : json
    }
}

/// One discovered tool or host (`VcsDiscoveryItem`, `SourceControlProviderDiscoveryItem`, contracts sourceControl.ts).
public struct SourceControlDiscoveryItem: Equatable, Sendable {
    public var kind: String
    public var label: String
    public var executable: String?
    public var status: String
    public var version: String?
    public var installHint: String
    public var implemented: Bool
    /// Hosts only: `{status, account?, detail?, accounts?}`.
    public var auth: JSONValue?
    public var isProvider: Bool { auth != nil }

    public init(_ json: JSONValue, provider: Bool) {
        kind = json["kind"]?.stringValue ?? ""
        label = json["label"]?.stringValue ?? kind
        executable = optionValue(json["executable"])?.stringValue
        status = json["status"]?.stringValue ?? "missing"
        version = optionValue(json["version"])?.stringValue
        installHint = json["installHint"]?.stringValue ?? ""
        implemented = json["implemented"]?.boolValue ?? true
        auth = provider ? (json["auth"] ?? .object([:])) : nil
    }

    public static func list(_ result: JSONValue) -> (vcs: [SourceControlDiscoveryItem], providers: [SourceControlDiscoveryItem]) {
        ((result["versionControlSystems"]?.arrayValue ?? []).map { .init($0, provider: false) },
         (result["sourceControlProviders"]?.arrayValue ?? []).map { .init($0, provider: true) })
    }

    var notReady: Bool { !isProvider && !implemented }
    var authStatus: String? { auth?["status"]?.stringValue }

    /// 3824 SourceControlSettings.tsx:98-109 (#22778).
    var dot: NSColor {
        if notReady { return Themed.color(\.mutedForeground, 0.35) }
        if isProvider { return status == "available" && authStatus == "authenticated" ? Themed.color(\.success) : Themed.color(\.mutedForeground, 0.35) }
        return status == "available" ? Themed.color(\.success) : Themed.color(\.warning)
    }

    /// The switch's checked state (`enabled`).
    var enabled: Bool { isProvider ? status == "available" && authStatus == "authenticated" : status == "available" && implemented }

    /// `itemSummary`.
    public var summary: String {
        if notReady { return "Support for \(label) is coming soon." }
        if status != "available" { return "Not available on this server: \(installHint)" }
        guard let auth else { return "Available" }
        let detail = optionValue(auth["detail"])?.stringValue
        switch auth["status"]?.stringValue {
        case "authenticated":
            var s = "Authenticated"
            if let account = optionValue(auth["account"])?.stringValue { s += " as \(account)" }
            if let detail { s += " · \(detail)" }
            return s
        case "unauthenticated":
            if executable == nil { return "Available. \(installHint)" }
            if auth["accounts"]?.arrayValue?.contains(where: { $0["authenticated"]?.boolValue == true }) == true {
                return detail ?? "Every \(label) host is turned off."
            }
            return "\(label) is not authenticated on this server. Sign in or configure credentials using the \(executable ?? "") tool on the server host to enable change request features."
        default:
            return "Could not verify \(label). \(detail ?? installHint)"
        }
    }

    var badge: String? { notReady ? "Coming Soon" : authStatus == "unauthenticated" ? "Not authenticated" : nil }

    var icon: IconDefinition? {
        switch kind {
        case "github": IconName.brandGitHub.definition
        case "gitlab": IconName.brandGitLab.definition
        case "forgejo": IconName.brandForgejo.definition
        case "git": IconName.brandGit.definition
        // ponytail: Azure DevOps, Bitbucket and Jujutsu glyphs are not in the icon set; their rows show the dot alone
        default: nil
        }
    }
}

/// Settings > Source Control (SourceControlSettings.tsx, ProjectDefaultsSettings.tsx with
/// `category="source-control"`, BranchNamingSettings.tsx, SourceControlWritingSettings.tsx, GitHubTokenSettings.tsx).
public final class SourceControlSettingsView: ScopedSettingsPage {
    private let discoveryEnabled: Bool
    private var discovery: (vcs: [SourceControlDiscoveryItem], providers: [SourceControlDiscoveryItem])?
    private var discoveryError: String?
    private var scanning = false
    private var scannedEnvironment: String?
    private let vcsSection = SettingsSectionView(title: "Version Control", rows: [])
    private let providersSection = SettingsSectionView(title: "Source Control Providers", rows: [])
    private let emptySection = SettingsSectionView(title: "Server environment", rows: [])
    private let scanButton = ButtonView(nil, icon: .refreshCw, variant: .ghostMuted, size: .iconXs)
    private var expanded: Set<String> = []
    private var branchRows: [SettingsRowView] = []

    public init(context: SettingsPageContext, discoveryEnabled: Bool = true) {
        self.discoveryEnabled = discoveryEnabled
        super.init(context: context)
        scanButton.setAccessibilityLabel("Rescan server environment")
        _ = TooltipController.attach(to: scanButton, text: "Rescan Git and hosting integrations")
        scanButton.action = { [weak self] in self?.scan() }
        anchors["source-control"] = vcsSection
        if discoveryEnabled {
            body = [repositoriesSection(), emptySection, vcsSection, providersSection, textGenerationSection()]
            binder.add { [weak self] in self?.updateDiscovery() }
        } else { body = [textGenerationSection()] }
    }

    /// The environment discovery inspects (the representative, `environment`).
    private var environmentId: String? { context.scope.representative?.id }

    public override func refresh() {
        if discoveryEnabled, environmentId != scannedEnvironment { discovery = nil; discoveryError = nil; scannedEnvironment = environmentId; scan() }
        super.refresh()
    }

    /// `server.discoverSourceControl` on the representative environment.
    func scan() {
        guard discoveryEnabled, let env = environmentId, !scanning, let request = context.request else { return }
        scanning = true
        updateDiscovery()
        Task { [weak self] in
            do {
                let result = try await request(env, "server.discoverSourceControl", .object([:]))
                guard let self, self.environmentId == env else { return }
                self.discovery = SourceControlDiscoveryItem.list(result)
                self.discoveryError = nil
            } catch {
                self?.discoveryError = "\(error)"
            }
            self?.scanning = false
            self?.refresh()
        }
    }

    // MARK: Repositories (ProjectDefaultsSettings.tsx category="source-control")

    private func repositoriesSection() -> SettingsSectionView {
        let pull = serverSwitch("automatic-pull", "", key: "defaultAutoPull", reset: "default automatic pull", label: "Default automatic pull")
        let credits = serverSwitch("remove-agent-credits-on-merge",
                                   "Remove recognized agent credit lines from merge and squash messages on hosts that support it, keeping human co-authors. Includes auto-merge. Excludes merge queues, stack merges, and existing commits.",
                                   key: "removeAgentCreditsOnMerge", reset: "agent credit removal", label: "Remove agent credits when merging")
        (credits.accessories.last as? ResetSlot)?.tooltip = "Keep agent credits"
        let methods: [(value: String, label: String)] = [("last", "Last selected"), ("merge", "Merge commit"), ("squash", "Squash and merge"),
                                                          ("rebase", "Rebase and merge")]
        let (merge, mergeSelect) = serverSelect("pull-request-merge-method", "", key: "pullRequestMergeMethod", options: methods, width: nil,
                                                reset: "default merge method", label: "Default pull request merge method",
                                                current: { $0["pullRequestMergeMethod"].stringValue ?? "last" })
        mergeSelect.onChange = { [weak self] i in
            self?.context.patchServer(["pullRequestMergeMethod": i == 0 ? .null : .string(methods[i].value)])
        }
        binder.add { [weak self, weak pull, weak merge] in
            guard let self else { return }
            let project = self.context.scope.isProjectScope
            pull?.detail = project ? "Keeps this project's default branch current when the checkout has no local changes or commits."
                : "Keeps the default branch current when the checkout has no local changes or commits. Projects can override it."
            merge?.detail = project ? "Pull requests in this project start with this method."
                : "Pull requests start with this method. Last selected reuses whatever you chose most recently on this device."
            // `Reset to last selected` while a method is set.
            (merge?.accessories.last as? ResetSlot)?.tooltip = project ? "Reset to inherited value" : "Reset to last selected"
        }
        (pull.accessories.last as? ResetSlot)?.tooltip = "Reset automatic pull to off"
        return section("source-control-defaults", "Repositories", [pull, credits, merge])
    }

    // MARK: Discovery

    private func updateDiscovery() {
        scanButton.isEnabled = !scanning
        let hasEnvironment = environmentId != nil
        let aggregate = context.scope.environmentIds.count != 1 && context.scope.connected.count > 1
        let suffix = aggregate ? " · \(context.scope.representative?.label ?? "")" : ""
        let vcs = discovery?.vcs ?? [], providers = discovery?.providers ?? []
        let has = !vcs.isEmpty || !providers.isEmpty
        if !hasEnvironment {
            emptySection.title = "Server environment"
            emptySection.headerAction = nil
            emptySection.group.rows = [SettingsGroupNote("Connect an environment to inspect its version control tools and hosting integrations.")]
            anchors["source-control"] = emptySection
        } else if !has {
            emptySection.title = "Server environment"
            let empty = EmptyView(title: discovery == nil && scanning ? "Scanning the server environment" : discoveryError != nil ? "Could not scan the server environment" : "Nothing detected yet",
                                  message: discoveryError ?? "Install Git on the server, add optional hosting integrations or credentials your workspace needs, then rescan.",
                                  icon: .gitPullRequestArrow)
            let scan = ButtonView("Scan", icon: .refreshCw, variant: .outline, size: .sm)
            scan.isEnabled = !scanning
            scan.action = { [weak self] in self?.scan() }
            empty.content = scan
            emptySection.group.rows = [empty]
            anchors["source-control"] = emptySection
        }
        setHidden(emptySection, hasEnvironment && has)
        setHidden(vcsSection, !has || vcs.isEmpty)
        setHidden(providersSection, !has || providers.isEmpty)
        guard has else { return }
        vcsSection.title = "Version Control\(suffix)"
        vcsSection.headerAction = vcs.isEmpty ? nil : scanButton
        providersSection.title = vcs.isEmpty ? "Source Control Providers\(suffix)" : "Source Control Providers"
        providersSection.headerAction = vcs.isEmpty ? scanButton : nil
        anchors["source-control"] = vcs.isEmpty ? providersSection : vcsSection
        vcsSection.group.rows = vcs.map { item in discoveryRow(item, details: item.kind == "git" ? fetchIntervalView() : nil) }
        let env = environmentId!
        let rescan: () -> Void = { [weak self] in self?.scan() }
        providersSection.group.rows = providers.map { item in
            switch item.kind {
            case "bitbucket":
                return discoveryRow(item, details: BitbucketCredentialsView(context: context, environmentId: env, onSaved: rescan))
            case "github":
                // The token shows even without gh: a saved token is how GitHub works without the CLI.
                let accounts = item.status == "available"
                    ? GitHubAccountsView(context: context, environmentId: env,
                                         accounts: (item.auth?["accounts"]?.arrayValue ?? []).compactMap(GitHubDiscoveredAccount.init), onSaved: rescan)
                    : nil
                return discoveryRow(item, details: GitHubDetailsView(token: GitHubTokenView(context: context, environmentId: env, onSaved: rescan), accounts: accounts))
            default:
                return discoveryRow(item, details: nil)
            }
        }
        if let gitRow = vcsSection.group.rows.first(where: { ($0 as? SourceControlDiscoveryRow)?.item.kind == "git" }) { anchors["git-fetch-interval"] = gitRow }
        // One search item per host with settings, `source-control-host-<kind>` (settingsSearch.ts:115-145 at 3669).
        for row in providersSection.group.rows {
            if let kind = (row as? SourceControlDiscoveryRow)?.item.kind { anchors[Self.hostSearchPrefix + kind] = row }
        }
    }

    private func discoveryRow(_ item: SourceControlDiscoveryItem, details: (NSView & SettingsGroupRow)?) -> SourceControlDiscoveryRow {
        let row = SourceControlDiscoveryRow(item: item, details: details)
        row.isExpanded = expanded.contains(item.kind)
        row.onToggle = { [weak self, weak row] in
            guard let self, let row else { return }
            // `CollapsibleContent` (SourceControlSettings.tsx:356): the details slide open over 200 ms.
            CollapseMotion.run(in: row) {
                if self.expanded.remove(item.kind) == nil { self.expanded.insert(item.kind) }
                row.isExpanded = self.expanded.contains(item.kind)
                self.needsLayout = true
                self.onHeightChange?()
            }
        }
        return row
    }

    /// Opens a discovery row (a settings search jump to the git fetch interval or the GitHub token).
    public override func anchor(_ id: String) -> NSView? {
        let host = id.hasPrefix(Self.hostSearchPrefix) ? String(id.dropFirst(Self.hostSearchPrefix.count)) : nil
        if id == "git-fetch-interval" { expanded.insert("git") }
        if let host { expanded.insert(host) }
        if id == "git-fetch-interval" || host != nil { updateDiscovery(); onHeightChange?() }
        return super.anchor(id)
    }

    /// `sourceControlHostSettingsSearchId` (settingsSearch.ts:115).
    static let hostSearchPrefix = "source-control-host-"

    /// `GitFetchIntervalSettings`: seconds, step 5, the shared policy note, and a reset to the profile's interval.
    private func fetchIntervalView() -> IntervalDetailView {
        let v = IntervalDetailView(title: "Git fetch interval", detail: "Refresh remote branches in the background. Set to 0 to avoid automatic Git prompts.",
                                   policy: "This interval is configured for Git only. The shared Background activity policy still decides whether Git refreshes may run when the timer fires. Custom intervals appear as Advanced in General settings.",
                                   step: 5)
        let s = server
        let seconds = (BackgroundActivity.resolveServer(s).automaticGitFetchInterval / 1000).rounded()
        let preset = (BackgroundActivity.presets[BackgroundActivity.baseProfile(s["backgroundActivity"])]!.automaticGitFetchInterval / 1000).rounded()
        v.field.value = seconds
        v.reset.isShown = seconds != preset
        v.field.onChange = { [weak self] value in
            guard let self else { return }
            let ms = BackgroundActivity.normalizeIntervalSeconds(value) * 1000
            self.context.patchServer(["backgroundActivity": BackgroundActivity.overrideSettings(self.server, ["automaticGitFetchInterval": .number(ms)])])
        }
        v.reset.action = { [weak self] in
            guard let self else { return }
            var ba = BackgroundActivity.overrideSettings(self.server, [:])
            if case .object(var o) = ba, case .object(var overrides)? = o["overrides"] {
                overrides.removeValue(forKey: "automaticGitFetchInterval")
                o["overrides"] = .object(overrides)
                ba = .object(o)
            }
            self.context.patchServer(["backgroundActivity": ba])
        }
        v.inertReason = context.scope.inertReason(for: ["backgroundActivity"])
        return v
    }

    // MARK: Text generation (SourceControlWritingSettings.tsx, BranchNamingSettings.tsx)

    private func textGenerationSection() -> SettingsSectionView {
        let modes: [(value: String, label: String)] = [("static", "Static prefix"), ("semantic", "Semantic prefix"), ("custom", "Custom instructions")]
        let (naming, _) = serverSelect("worktree-branch-naming", "Choose how new worktree branches are named from your first message.",
                                       key: "branchNamingMode", options: modes, width: nil, reset: "branch naming")
        let prefix = InputView(placeholder: "No prefix", text: "", size: .sm)
        prefix.frame.size = NSSize(width: 224, height: 28)
        prefix.setAccessibilityLabel("Branch prefix")
        let prefixRow = row(nil, title: "Branch prefix", detail: "For example, t3 or t3/ produces t3/add-search. Leave empty for no prefix.", control: prefix)
        _ = bindServerRow(prefixRow, keys: ["branchNamePrefix"], reset: "branch prefix")
        var prefixEdited = false
        prefix.onChange = { _ in prefixEdited = true }
        prefix.onCommit = { [weak self] text in
            guard let self else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if prefixEdited, self.context.scope.isMixed(["branchNamePrefix"]) || value != self.server.string("branchNamePrefix") {
                self.context.patchServer(["branchNamePrefix": .string(value)])
            }
            prefixEdited = false
        }
        let instructions = TextareaView(placeholder: "Use julius/ followed by the issue ID and a short description.", size: .default)
        instructions.setAccessibilityLabel("Branch naming instructions")
        let instructionsRow = row(nil, title: "Branch naming instructions",
                                  detail: "Appended to the naming prompt. The model returns the complete branch name; no prefix or suffix is added.")
        instructionsRow.footer = TextareaFooter(instructions)
        _ = bindServerRow(instructionsRow, keys: ["branchNameInstructions"], reset: "branch naming instructions")
        var instructionsEdited = false
        instructions.onChange = { [weak self] _ in instructionsEdited = true; self?.onHeightChange?() }
        onBlur(instructions) { [weak self] text in
            guard let self else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if instructionsEdited, self.context.scope.isMixed(["branchNameInstructions"]) || value != self.server.string("branchNameInstructions") {
                self.context.patchServer(["branchNameInstructions": .string(value)])
            }
            instructionsEdited = false
        }
        binder.add { [weak self, weak naming, weak prefixRow, weak instructionsRow, weak prefix, weak instructions] in
            guard let self else { return }
            let scope = self.context.scope
            let modeMixed = scope.isMixed(["branchNamingMode"])
            let mode = self.server.string("branchNamingMode")
            naming?.status = !modeMixed && mode == "semantic"
                ? "The model chooses a prefix that describes the work, such as feat/add-search, fix/login-timeout, or refactor/auth." : nil
            prefixRow?.isHidden = modeMixed || mode != "static"
            instructionsRow?.isHidden = modeMixed || mode != "custom"
            if let prefix, !prefix.state.focused {
                let mixed = scope.isMixed(["branchNamePrefix"])
                prefix.text = mixed ? "" : self.server.string("branchNamePrefix")
                prefix.placeholder = mixed ? "Mixed" : "No prefix"
            }
            if let instructions, !instructions.state.focused {
                let mixed = scope.isMixed(["branchNameInstructions"])
                instructions.text = mixed ? "" : self.server.string("branchNameInstructions")
                instructions.placeholder = mixed ? "Mixed. Enter instructions to apply to all selected targets."
                    : "Use julius/ followed by the issue ID and a short description."
            }
        }

        // Writing style: one object; each control reads its own field.
        let styleModes: [(value: String, label: String, description: String)] = [
            ("repo_conventions", "Repository conventions", "In each project, matches recent change descriptions and change request titles."),
            ("conventional_commits", "Conventional Commits", "Use Conventional Commit prefixes and keep change request text concise."),
            ("custom", "Custom instructions", "Use your instructions for change descriptions and change requests in every project."),
        ]
        let styleSelect = settingsSelect(styleModes.map(\.label), width: 224)
        styleSelect.setAccessibilityLabel("Source control writing style")
        let styleRow = row("source-control-writing-style", detail: "", control: styleSelect)
        let defaults = ServerSettingsValues.fields["sourceControlWritingStyle"]!.defaultValue
        _ = bindServerRow(styleRow, keys: ["sourceControlWritingStyle"], reset: "source control writing style",
                          isDefault: { [weak self] in
                              guard let self else { return true }
                              let style = self.server["sourceControlWritingStyle"]
                              return !self.fieldMixed("mode") && !self.fieldMixed("customInstructions")
                                  && style["mode"] == defaults["mode"] && style["customInstructions"] == defaults["customInstructions"]
                          },
                          resetPatch: { ["sourceControlWritingStyle": .object(["mode": defaults["mode"]!, "customInstructions": defaults["customInstructions"]!])] })
        let custom = TextareaView(placeholder: "Keep titles concise. Use short bullet points in descriptions.", size: .default)
        custom.setAccessibilityLabel("Custom source control writing instructions")
        custom.onChange = { [weak self] _ in self?.onHeightChange?() }
        onBlur(custom) { [weak self] text in
            guard let self else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != self.server["sourceControlWritingStyle"]["customInstructions"]?.stringValue {
                self.context.patchServer(["sourceControlWritingStyle": .object(["customInstructions": .string(value)])])
            }
        }
        let customFooter = TextareaFooter(custom)
        let mixedInstructions = SettingsWritingInstructionsView()
        mixedInstructions.onApply = { [weak self] text in
            self?.context.patchServer(["sourceControlWritingStyle": .object(["mode": .string("custom"), "customInstructions": .string(text)])])
        }
        mixedInstructions.onHeightChange = { [weak self] in self?.onHeightChange?() }
        styleSelect.onChange = { [weak self, weak custom] i in
            guard let self else { return }
            var patch: [String: JSONValue] = ["mode": .string(styleModes[i].value)]
            if let custom, self.server["sourceControlWritingStyle"]["mode"]?.stringValue == "custom" {
                patch["customInstructions"] = .string(custom.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            self.context.patchServer(["sourceControlWritingStyle": .object(patch)])
        }
        binder.add { [weak self, weak styleRow, weak styleSelect, weak custom] in
            guard let self, let styleRow, let styleSelect else { return }
            let style = self.server["sourceControlWritingStyle"]
            let mode = style["mode"]?.stringValue ?? "repo_conventions"
            let modeMixed = self.fieldMixed("mode")
            styleSelect.placeholder = "Mixed"
            styleSelect.selectedIndex = modeMixed ? nil : styleModes.firstIndex { $0.value == mode }
            styleRow.detail = styleModes.first { $0.value == mode }?.description
            if modeMixed || self.fieldMixed("customInstructions") { styleRow.footer = mixedInstructions }
            else { styleRow.footer = mode == "custom" ? customFooter : nil }
            if let custom, !custom.state.focused { custom.text = style["customInstructions"]?.stringValue ?? "" }
        }

        let templates = SwitchView(isOn: true)
        templates.setAccessibilityLabel("Follow change request templates")
        let templatesRow = row("follow-change-request-templates", detail: "Use the repository's template for change request descriptions when available.",
                               control: templates)
        _ = bindServerRow(templatesRow, keys: ["sourceControlWritingStyle"], reset: "change request templates",
                          isDefault: { [weak self] in
                              guard let self else { return true }
                              return !self.fieldMixed("followChangeRequestTemplates")
                                  && self.server["sourceControlWritingStyle"]["followChangeRequestTemplates"] == defaults["followChangeRequestTemplates"]
                          },
                          resetPatch: { ["sourceControlWritingStyle": .object(["followChangeRequestTemplates": .bool(true)])] })
        templates.onChange = { [weak self] on in
            self?.context.patchServer(["sourceControlWritingStyle": .object(["followChangeRequestTemplates": .bool(on)])])
        }
        binder.add { [weak self, weak templates] in
            guard let self, let templates else { return }
            let mixed = self.fieldMixed("followChangeRequestTemplates")
            templates.isMixed = mixed
            templates.isOn = !mixed && (self.server["sourceControlWritingStyle"]["followChangeRequestTemplates"]?.boolValue ?? true)
        }

        // Writer model: off uses the text generation model; on shows the picker.
        let writerSwitch = SwitchView(isOn: false)
        writerSwitch.setAccessibilityLabel("Use a separate source control writer model")
        let writerPicker = SettingsModelPickerControl(context: context, key: "sourceControlWriterModelSelection")
        let writerGroup = SettingsControlGroup([writerPicker, writerSwitch])
        let writerRow = row("source-control-writer-model",
                            detail: "Model for source control text and branch or bookmark names. Off uses the environment's text generation model.",
                            control: writerGroup)
        _ = bindServerRow(writerRow, keys: ["sourceControlWriterModelSelection"], reset: nil)
        writerSwitch.onChange = { [weak self] on in
            guard let self else { return }
            self.context.patchServer(["sourceControlWriterModelSelection": on ? self.server["textGenerationModelSelection"] : .null])
        }
        binder.add { [weak self, weak writerSwitch, weak writerPicker, weak writerGroup] in
            guard let self, let writerSwitch, let writerPicker else { return }
            let uses = self.server["sourceControlWriterModelSelection"] != .null
            writerSwitch.isOn = uses
            writerPicker.isHidden = !uses
            writerPicker.refresh()
            writerGroup?.invalidateIntrinsicContentSize()
        }
        let s = section("source-control-text-generation", "Text generation",
                        [naming, prefixRow, instructionsRow, styleRow, templatesRow, writerRow] + reviewGuideRows())
        binder.add { [weak s] in s?.group.rows = s?.group.rows ?? [] }
        return s
    }

    /// Review guides, a server beta (SourceControlWritingSettings.tsx:439-570 at 3105): the switch, then while it's on
    /// the model (picker, traits from e688034b5, switch) and the instructions. CW has no Guide tab itself.
    private func reviewGuideRows() -> [SettingsRowView] {
        let enabled = SwitchView(isOn: false)
        enabled.setAccessibilityLabel("Review guides")
        let enabledRow = row("review-guides",
                             detail: "Adds a Guide tab to pull requests: an agent writes a tour of the change, stop by stop, with the calls a maintainer should make.",
                             control: enabled)
        _ = bindServerRow(enabledRow, keys: ["reviewGuidesEnabled"], reset: nil)
        enabled.onChange = { [weak self] on in self?.context.patchServer(["reviewGuidesEnabled": .bool(on)]) }

        let modelSwitch = SwitchView(isOn: false)
        modelSwitch.setAccessibilityLabel("Use a separate review guide model")
        let picker = SettingsModelPickerControl(context: context, key: "reviewGuideModelSelection")
        let group = SettingsControlGroup([picker, modelSwitch])
        let modelRow = row("review-guide-model",
                           detail: "Model that reads a pull request to write its review guide. It reads the change itself over many steps, so a stronger model helps. Off uses the source control writer model.",
                           control: group)
        _ = bindServerRow(modelRow, keys: ["reviewGuideModelSelection"], reset: nil)
        modelSwitch.onChange = { [weak self] on in
            guard let self else { return }
            // On starts from the writer model with its options (`activeSelection`).
            let writer = self.server["sourceControlWriterModelSelection"]
            self.context.patchServer(["reviewGuideModelSelection": on ? (writer != .null ? writer : self.server["textGenerationModelSelection"]) : .null])
        }

        let instructions = TextareaView(placeholder: "", size: .default)
        instructions.setAccessibilityLabel("Review guide instructions")
        let instructionsRow = row("review-guide-instructions",
                                  detail: "Your preferences for review guides: what to show first, dwell on, or skip. The guide's format and coverage stay the same.")
        instructionsRow.footer = TextareaFooter(instructions)
        _ = bindServerRow(instructionsRow, keys: ["reviewGuideInstructions"], reset: "review guide instructions")
        var edited = false
        instructions.onChange = { [weak self] _ in edited = true; self?.onHeightChange?() }
        onBlur(instructions) { [weak self] text in
            guard let self else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited, self.context.scope.isMixed(["reviewGuideInstructions"]) || value != self.server.string("reviewGuideInstructions") {
                self.context.patchServer(["reviewGuideInstructions": .string(value)])
            }
            edited = false
        }

        binder.add { [weak self, weak enabled, weak modelSwitch, weak picker, weak group, weak modelRow, weak instructionsRow, weak instructions] in
            guard let self, let enabled, let modelSwitch, let picker else { return }
            let scope = self.context.scope
            let enabledMixed = scope.isMixed(["reviewGuidesEnabled"])
            enabled.isMixed = enabledMixed
            enabled.isOn = !enabledMixed && self.server.bool("reviewGuidesEnabled")
            let shown = enabledMixed || enabled.isOn
            modelRow?.isHidden = !shown
            instructionsRow?.isHidden = !shown
            let modelMixed = scope.isMixed(["reviewGuideModelSelection"])
            let uses = self.server["reviewGuideModelSelection"] != .null
            modelSwitch.isMixed = modelMixed
            modelSwitch.isOn = !modelMixed && uses
            picker.isHidden = !(uses || modelMixed)
            picker.refresh()
            group?.invalidateIntrinsicContentSize()
            if let instructions, !instructions.state.focused {
                let mixed = scope.isMixed(["reviewGuideInstructions"])
                instructions.text = mixed ? "" : self.server.string("reviewGuideInstructions")
                instructions.placeholder = mixed ? "Mixed. Enter instructions to apply to all selected targets."
                    : "Show service interfaces before implementations. Skip test files unless they change behavior. Keep summaries to two sentences."
            }
        }
        return [enabledRow, modelRow, instructionsRow]
    }

    private func fieldMixed(_ field: String) -> Bool {
        let targets = context.scope.targets
        guard let first = targets.first else { return false }
        return targets.contains { $0.settings["sourceControlWritingStyle"][field] != first.settings["sourceControlWritingStyle"][field] }
    }
}

/// Runs `handler` with the text when the field loses focus (`onBlur`).
@MainActor
func onBlur(_ field: FieldView, _ handler: @escaping @MainActor (String) -> Void) {
    var focused = false
    field.onStateChange = { [weak field] state in
        if focused && !state.focused, let field { handler(field.text) }
        focused = state.focused
    }
}

/// A row's textarea (`mt-3 max-w-2xl pb-3.5`).
final class TextareaFooter: DSView, SettingsGroupRow {
    let textarea: TextareaView
    init(_ textarea: TextareaView) {
        self.textarea = textarea
        super.init(frame: .zero)
        addSubview(textarea)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        textarea.setFrameSize(NSSize(width: min(672, width), height: textarea.frame.height))
        return textarea.intrinsicContentSize.height + 14
    }
    override func layout() {
        super.layout()
        let w = min(672, bounds.width)
        textarea.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height - 14)
    }
}

/// A source control discovery row (SourceControlSettings.tsx `DiscoveryItemRow`): the mark with its status
/// dot, label, version, badge and summary; the details toggle and a disabled availability switch; the details below.
final class SourceControlDiscoveryRow: DSView, SettingsGroupRow {
    let item: SourceControlDiscoveryItem
    private let mark: NSView
    private let dot = CALayer()
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let version = LabelView("", font: DSFont.mono(12), color: Themed.color(\.mutedForeground))
    private var badge: BadgeView?
    private let summary = TextBlockView()
    private let toggle = ButtonView(nil, icon: .chevronDown, variant: .ghostMuted, size: .iconXs)
    private let availability = SwitchView(isOn: false)
    private let details: (NSView & SettingsGroupRow)?
    /// `first:rounded-t-xl last:rounded-b-xl transition-colors hover:bg-muted/20` (SourceControlSettings.tsx:307).
    private let hoverFill = CALayer()
    private var hover: HoverGroup?
    var onToggle: (() -> Void)?
    var isExpanded = false {
        didSet { details?.isHidden = !isExpanded; toggle.setIconRotation(isExpanded ? 180 : 0); toggle.setAccessibilityExpanded(isExpanded); needsLayout = true }
    }

    init(item: SourceControlDiscoveryItem, details: (NSView & SettingsGroupRow)?) {
        self.item = item
        self.details = details
        if let icon = item.icon {
            mark = IconView(definition: icon, size: 18, color: Themed.color(\.foreground, 0.8))
        } else {
            mark = DSView()
        }
        super.init(frame: .zero)
        alphaValue = item.notReady ? 0.8 : 1
        hoverFill.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(hoverFill)
        hover = HoverGroup(self) { [weak self] _ in self?.restyleHover(transitioning: true) }
        addSubview(mark)
        dot.cornerRadius = 4
        dot.backgroundColor = item.dot.cgColor
        if item.icon != nil {
            dot.borderWidth = 2
            dot.borderColor = Themed.color(\.background).cgColor
        }
        layer?.addSublayer(dot)
        label.text = item.label
        label.lineHeight = 20
        version.text = item.version ?? ""
        version.lineHeight = 16
        version.isHidden = item.version == nil
        if let b = item.badge {
            let v = BadgeView(b, variant: b == "Not authenticated" && !ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? .secondary : .warning, size: .sm)
            badge = v
            addSubview(v)
        }
        summary.text = item.summary
        summary.font = DSFont.ui(12)
        summary.lineHeight = 18
        summary.color = Themed.color(\.mutedForeground, 0.8)
        toggle.iconSize = 14
        toggle.setAccessibilityLabel("Toggle \(item.label) details")
        toggle.action = { [weak self] in self?.onToggle?() }
        toggle.isHidden = details == nil
        availability.isOn = item.enabled
        availability.isEnabled = false
        availability.setAccessibilityLabel("\(item.label) availability")
        availability.isHidden = item.notReady
        for v in [label, version, summary, toggle, availability] as [NSView] { addSubview(v) }
        details.map(addSubview)
        details?.isHidden = true
    }

    private func restyleHover(transitioning: Bool) {
        let color = hover?.hovered == true ? Themed.color(\.muted, 0.2).cgColor(in: self) : nil
        Motion.transitioning(transitioning ? .background : []) { Motion.setBackground(hoverFill, color) }
    }

    private var controlsWidth: CGFloat { (toggle.isHidden ? 0 : 24 + 8) + (availability.isHidden ? 0 : availability.intrinsicContentSize.width) }

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = width - 32 - controlsWidth - 12
        let top = 12 + max(20, 20) + 4 + summary.height(forWidth: textWidth) + 12
        guard isExpanded, let details else { return top }
        return top + 4 + details.height(forWidth: width - 32) + 16
    }

    override func layout() {
        super.layout()
        let rows = (superview as? SettingsGroupView)?.rows ?? []
        var corners: CACornerMask = []
        if rows.first === self { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if rows.last === self { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverFill.frame = bounds
        hoverFill.cornerRadius = corners.isEmpty ? 0 : 12
        hoverFill.maskedCorners = corners
        CATransaction.commit()
        let w = bounds.width
        let textWidth = w - 32 - controlsWidth - 12
        let summaryH = summary.height(forWidth: textWidth)
        let headerH = 12 + 20 + 4 + summaryH + 12
        var x: CGFloat = 16
        if item.icon != nil {
            mark.frame = NSRect(x: x + 1, y: 13, width: 18, height: 18)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: x - 2 - 2, y: 12 - 2 - 2, width: 8 + 4, height: 8 + 4)
            dot.cornerRadius = 6
            CATransaction.commit()
            x += 20 + 8
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: x, y: 18, width: 8, height: 8)
            CATransaction.commit()
            x += 8 + 8
        }
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: x, y: 12, width: lw, height: 20)
        x += lw + 8
        if !version.isHidden {
            let vw = min(ceil(version.textWidth) + 1, max(0, 16 + textWidth - x))
            version.frame = NSRect(x: x, y: 14, width: vw, height: 16)
            x += vw + 8
        }
        if let badge {
            let s = badge.intrinsicContentSize
            badge.frame = NSRect(x: x, y: 12 + (20 - s.height) / 2, width: s.width, height: s.height)
        }
        summary.frame = NSRect(x: 16, y: 36, width: textWidth, height: summaryH)
        var cx = w - 16
        if !availability.isHidden {
            let s = availability.intrinsicContentSize
            cx -= s.width
            availability.frame = NSRect(x: cx, y: (headerH - s.height) / 2, width: s.width, height: s.height)
            cx -= 8
        }
        if !toggle.isHidden { toggle.frame = NSRect(x: cx - 24, y: (headerH - 24) / 2, width: 24, height: 24) }
        if isExpanded, let details {
            details.frame = NSRect(x: 16, y: headerH + 4, width: w - 32, height: details.height(forWidth: w - 32))
        }
    }

    override func updateLayer() {
        super.updateLayer()
        restyleHover(transitioning: false)
        if item.badge == "Not authenticated" { badge?.variant = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? .warning : .secondary }
        dot.backgroundColor = item.dot.cgColor(in: self)
        if item.icon != nil { dot.borderColor = Themed.color(\.background).cgColor(in: self) }
    }
}

/// An interval field inside a row's details (`GitFetchIntervalSettings`, the health check row's control):
/// the title with the policy info and reset, the description, then the number field and "seconds".
final class IntervalDetailView: DSView, SettingsGroupRow {
    private let title = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let detail = TextBlockView()
    private let info = ButtonView(nil, icon: .info, variant: .ghostMuted, size: .iconMicro)
    let reset = ResetSlot(label: "fetch interval")
    let field: NumberFieldView
    private let unit = LabelView("seconds", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    var inertReason: String? { didSet { field.isEnabled = inertReason == nil; field.toolTip = inertReason } }

    init(title text: String, detail description: String, policy: String, step: Double) {
        field = NumberFieldView(value: 0, size: .sm)
        super.init(frame: .zero)
        field.step = step
        field.range = 0 ... .infinity
        field.setAccessibilityLabel("Automatic Git fetch interval in seconds")
        title.text = text
        title.lineHeight = 16
        detail.text = description
        detail.font = DSFont.ui(12)
        detail.lineHeight = 18
        detail.color = Themed.color(\.mutedForeground)
        info.iconSize = 14
        info.setAccessibilityLabel("Background policy details")
        _ = TooltipController.attach(to: info, text: policy, delay: 0.2)
        unit.lineHeight = 16
        for v in [title, detail, info, reset, field, unit] as [NSView] { addSubview(v) }
    }

    func height(forWidth width: CGFloat) -> CGFloat { max(20 + 4 + detail.height(forWidth: max(0, width - 128 - 8 - 56 - 12)), 28) }

    override func layout() {
        super.layout()
        let w = bounds.width
        unit.frame = NSRect(x: w - ceil(unit.textWidth) - 1, y: 6, width: ceil(unit.textWidth) + 1, height: 16)
        field.frame = NSRect(x: unit.frame.minX - 8 - 128, y: 0, width: 128, height: 28)
        let tw = ceil(title.textWidth) + 1
        title.frame = NSRect(x: 0, y: 2, width: tw, height: 16)
        info.frame = NSRect(x: tw + 4, y: 0, width: 20, height: 20)
        reset.frame = NSRect(x: tw + 4 + 20 + 4, y: 0, width: 20, height: 20)
        let dw = max(0, field.frame.minX - 12)
        detail.frame = NSRect(x: 0, y: 24, width: dw, height: detail.height(forWidth: dw))
    }
}

/// `GitHubTokenSettings`: a write-only token per host in the server's secret store. The saved token never
/// comes back; only which hosts have one.
final class GitHubTokenView: DSView, SettingsGroupRow {
    private let intro = TextBlockView()
    private let create = ButtonView("Create a token", variant: .link, size: .xs)
    private let hostLabel = LabelView("Host", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let tokenLabel = LabelView("Token", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    let host = InputView(placeholder: "github.com", text: "github.com", size: .sm)
    let token = SecureInputView(placeholder: "Not set")
    private let saved = TextBlockView()
    let remove = ButtonView("Remove", variant: .outline, size: .xs)
    let save = ButtonView("Save", size: .xs)
    private let context: SettingsPageContext
    private let environmentId: String
    private let onSaved: () -> Void
    private var saving = false { didSet { sync() } }

    init(context: SettingsPageContext, environmentId: String, onSaved: @escaping () -> Void) {
        self.context = context
        self.environmentId = environmentId
        self.onSaved = onSaved
        super.init(frame: .zero)
        intro.text = "A token saved here is used before GH_TOKEN and the gh login, so GitHub works without the GitHub CLI. Give it read and write access to pull requests and contents."
        intro.font = DSFont.ui(12)
        intro.lineHeight = 18
        intro.color = Themed.color(\.mutedForeground)
        create.trailingIcon = .externalLink
        create.action = { [weak self] in
            guard let self else { return }
            let h = self.normalizedHost.isEmpty ? "github.com" : self.normalizedHost
            if let url = URL(string: "https://\(h)/settings/personal-access-tokens/new") { self.context.openURL?(url) }
        }
        hostLabel.lineHeight = 16
        tokenLabel.lineHeight = 16
        host.setAccessibilityLabel("Host")
        token.setAccessibilityLabel("Token")
        saved.font = DSFont.ui(12)
        saved.lineHeight = 16
        saved.color = Themed.color(\.mutedForeground)
        host.onChange = { [weak self] _ in self?.sync() }
        token.onChange = { [weak self] _ in self?.sync() }
        token.onSubmit = { [weak self] in self?.submit() }
        save.action = { [weak self] in self?.submit() }
        remove.action = { [weak self] in guard let self else { return }; self.write(self.normalizedHost, "") }
        for v in [intro, create, hostLabel, tokenLabel, host, token, saved, remove, save] as [NSView] { addSubview(v) }
        sync()
    }

    private var normalizedHost: String { host.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var tokens: [String: JSONValue] { context.configs[environmentId]?.settings.sourceControlHost("github")?["tokens"]?.objectValue ?? [:] }

    private func sync() {
        let isSaved = !(tokens[normalizedHost]?.stringValue ?? "").isEmpty
        token.placeholder = isSaved ? "Stored secret, enter a new value to replace" : "Not set"
        let hosts = tokens.filter { !($0.value.stringValue ?? "").isEmpty }.map(\.key).sorted()
        saved.text = hosts.isEmpty ? "No token saved; the server uses GH_TOKEN or the gh login." : "Saved for \(hosts.joined(separator: ", "))."
        remove.isHidden = !isSaved
        remove.isEnabled = !saving
        save.isEnabled = !normalizedHost.isEmpty && !token.text.trimmingCharacters(in: .whitespaces).isEmpty && !saving
        host.isEnabled = !saving
        token.isEnabled = !saving
        needsLayout = true
    }

    private func submit() {
        let draft = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !draft.isEmpty else { return }
        write(normalizedHost, draft)
    }

    /// `server.updateSettings` with the whole tokens map, on this environment only. Saved tokens go
    /// back as the redaction marker, which both shapes keep. 2994 drops a host left out of the map
    /// (settings.ts:1600-1604); the old `github` key merged per host.
    private func write(_ target: String, _ value: String) {
        guard let request = context.request, !saving, let settings = context.configs[environmentId]?.settings else { return }
        saving = true
        let env = environmentId
        var next = tokens
        next[target] = .string(value)
        let patch = settings.sourceControlHostPatch("github", ["tokens": .object(next)])
        Task { [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", .object(["patch": patch]))
                self?.context.applySettings?(env, result)
                self?.token.text = ""
                self?.onSaved()
            } catch {
                self?.context.toast?("Setting not saved", "\(error)", .error)
            }
            self?.saving = false
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat { intro.height(forWidth: width) + 2 + 20 + 12 + 22 + 28 + 12 + 24 }

    override func layout() {
        super.layout()
        let w = bounds.width
        let ih = intro.height(forWidth: w)
        intro.frame = NSRect(x: 0, y: 0, width: w, height: ih)
        // ponytail: "Create a token" sits under the paragraph rather than inline at its end
        let cw = create.intrinsicContentSize.width
        create.frame = NSRect(x: 0, y: ih + 2, width: cw, height: 20)
        var y = ih + 2 + 20 + 12
        hostLabel.frame = NSRect(x: 0, y: y, width: 192, height: 16)
        tokenLabel.frame = NSRect(x: 192 + 12, y: y, width: w - 204, height: 16)
        y += 22
        host.frame = NSRect(x: 0, y: y, width: 192, height: 28)
        token.frame = NSRect(x: 192 + 12, y: y - 2, width: w - 204, height: 32)
        y += 28 + 12
        let sw = save.intrinsicContentSize.width
        save.frame = NSRect(x: w - sw, y: y, width: sw, height: 24)
        var right = w - sw - 8
        if !remove.isHidden {
            let rw = remove.intrinsicContentSize.width
            remove.frame = NSRect(x: right - rw, y: y, width: rw, height: 24)
            right -= rw + 12
        }
        saved.frame = NSRect(x: 0, y: y + 4, width: max(0, right), height: 16)
    }
}
