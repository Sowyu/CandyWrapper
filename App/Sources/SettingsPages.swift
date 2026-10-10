import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// Settings > General, Appearance and Keybindings: page routing, settings search jumps, the scope, and the
/// writes. Client settings go to `ClientSettingsStore`; server settings go to every connected environment in
/// the scope through `server.updateSettings {patch}`; keybindings through `server.upsertKeybinding` and
/// `server.removeKeybinding` (useScopedSettings.ts, KeybindingsSettings.tsx:1390-1460).
extension SettingsController {
    func setUpPageContext() {
        let c = pageContext
        c.writeClient = { patch in ClientSettingsStore.shared.update(patch) }
        c.writeServer = { [weak self] patch in self?.writeServer(patch) }
        c.setAppearanceMode = { mode in AppearanceMode(rawValue: mode)?.apply() }
        c.selectScope = { [weak self] selection in
            guard let self else { return }
            self.scopeSelection = selection
            self.refreshPages()
        }
        c.saveKeybinding = { [weak self] target, replace in self?.saveKeybinding(target, replace: replace) }
        c.removeKeybinding = { [weak self] row in self?.removeKeybinding(row) }
        c.openKeybindingsFile = { [weak self] in self?.openKeybindingsFile() }
        c.openURL = { url in NSWorkspace.shared.open(url) }
        c.toast = { [weak self] title, message, kind in self?.toast(title, message, kind) }
        c.presentDialog = { [weak self] dialog in
            guard let self, let window = self.window, self.modal == nil else { return nil }
            let host = ModalHost.present(dialog, in: window)
            host.onDismiss = { [weak self] in self?.modal = nil }
            dialog.onClose = { [weak host] in host?.close() }
            self.modal = host
            return host
        }
        c.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        clientObserver = ClientSettingsStore.shared.observe { [weak self] _ in self?.refreshPages() }
        composer?.onConfigChange = { [weak self] _ in self?.refreshPages() }
        NotificationCenter.default.addObserver(forName: AppearanceMode.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPages() }
        }
    }

    // MARK: Pages

    /// Opens a page (`handleSectionClick`).
    func show(_ section: SettingsSection) {
        guard section.isAvailable else { return }
        self.section = section
        nav.selected = section
        page.header.section = section
        page.header.restore.isHidden = section != .general
        let view: (NSView & SettingsGroupRow)
        switch section {
        case .general: view = generalPage()
        case .appearance: view = appearancePage()
        case .keybindings: view = keybindingsView()
        default: view = connectionsPage
        }
        if page.page !== view { page.page = view; page.scrollToTop() }
        refreshPages()
    }

    /// A search result: open its page, then scroll its anchor into view and pulse it.
    func jump(to item: SettingsSearchItem) {
        show(item.to.isAvailable ? item.to : section)
        guard item.to.isAvailable else { return }
        let target: NSView? = switch item.to {
        case .general: general?.anchor(item.anchor)
        case .appearance: appearance?.anchor(item.anchor)
        case .keybindings: keybindingsPage?.anchor(item.anchor)
        default: nil
        }
        page.pageChanged()
        if let target { page.reveal(target) }
        window?.makeFirstResponder(page)
    }

    private func generalPage() -> GeneralSettingsView {
        if let general { return general }
        let v = GeneralSettingsView(context: pageContext)
        v.onHeightChange = { [weak self] in self?.page.pageChanged() }
        general = v
        return v
    }

    private func appearancePage() -> AppearanceSettingsView {
        if let appearance { return appearance }
        let v = AppearanceSettingsView(context: pageContext)
        v.onHeightChange = { [weak self] in self?.page.pageChanged() }
        appearance = v
        return v
    }

    private func keybindingsView() -> KeybindingsSettingsView {
        if let keybindingsPage { return keybindingsPage }
        let v = KeybindingsSettingsView(context: pageContext)
        v.onHeightChange = { [weak self] in self?.page.pageChanged() }
        keybindingsPage = v
        return v
    }

    /// Rebuilds the context from the stores and refreshes the open page.
    func refreshPages() {
        guard isOpen else { return }
        updateContext()
        nav.searchItems = SettingsSearch.available(searchAvailability())
        switch section {
        case .general: general?.refresh()
        case .appearance: appearance?.refresh()
        case .keybindings: keybindingsPage?.refresh()
        default: break
        }
        pageContext.didChange()
        page.header.restore.isEnabled = !changedSettingLabels().isEmpty
        page.pageChanged()
    }

    private func updateContext() {
        let c = pageContext
        c.client = ClientSettingsStore.shared.current
        c.appearanceMode = AppearanceMode.current.rawValue
        let ids = environments.environmentIds
        let scoped = ids.map { id -> SettingsScopeEnvironment in
            let config = composer?.config(id)
            let state = environments.state(id)
            return SettingsScopeEnvironment(
                id: id, label: environments.label(id) ?? id,
                displayURL: environments.routeInUse(id).map(EnvironmentRowStatus.displayURL),
                machine: environments.machine(id) ?? "server", connected: state?.status == .connected,
                settings: config.map { ServerSettingsValues($0.settings.raw) }, capabilities: config?.capabilities ?? [],
                // `settings:write`; unknown until the session loads, and the server refuses a write it doesn't allow.
                canWrite: hosts[id]?.session.map { $0.grants(AuthScopes.settingsWrite) } ?? true)
        }
        c.scope = SettingsScopeState(selection: scopeSelection, environments: scoped, primaryId: environments.primaryId,
                                     projects: projectGroups())
        c.providers = c.scope.representative.flatMap { composer?.config($0.id)?.providers } ?? []
        let primary = environments.primaryId.flatMap { composer?.config($0) }
        c.serverKeybindings = primary?.keybindings ?? []
        c.keybindingsConfigPath = primary?.keybindingsConfigPath
    }

    /// The project picker lists the sidebar's project groups by name.
    private func projectGroups() -> [SettingsScopeProject] {
        guard let snapshot = environments.primaryId.flatMap({ environments.snapshot($0) }) else { return [] }
        var seen = Set<String>()
        return snapshot.projects.compactMap { p in
            seen.insert(p.title).inserted ? SettingsScopeProject(key: p.id.rawValue, displayName: p.title) : nil
        }
    }

    /// `useAvailableSettingsSearchItems` for this client.
    private func searchAvailability() -> SettingsSearchAvailability {
        var a = SettingsSearchAvailability()
        a.hasEnvironment = !environments.environmentIds.isEmpty
        a.hasThreadAutoSettlement = environments.environmentIds.contains { composer?.config($0)?.capabilities.contains("threadAutoSettlement") == true }
        a.hasCloudPublicConfig = t3.loaded
        return a
    }

    // MARK: Writes

    /// `useRunScopedPlan`: one `server.updateSettings` per target; the reply's settings apply at once.
    private func writeServer(_ patch: [String: JSONValue]) {
        let plan = pageContext.scope.plan(patch)
        if let reason = plan.unavailableReason {
            toast("Setting not saved", reason, .warning)
            return
        }
        Task {
            var failures: [String] = [], saved: [String] = []
            for w in plan.writes {
                do {
                    let result = try await environments.request(w.environmentId, "server.updateSettings", .object(["patch": .object(w.patch)]))
                    composer?.applySettings(w.environmentId, result)
                    saved.append(w.label)
                } catch {
                    failures.append("Could not save on \(w.label): \(Self.rpcMessage(error, fallback: "The save failed. Try reconnecting and saving again."))")
                }
            }
            guard !failures.isEmpty else { return }
            toast(saved.isEmpty ? "Setting not saved" : "Setting saved on some environments",
                  (failures + (saved.isEmpty ? [] : ["Saved on \(saved.joined(separator: ", "))."])).joined(separator: "\n"), .error)
        }
    }

    private static func rpcMessage(_ error: Error, fallback: String) -> String {
        if let e = error as? RPCClientError { return e.description }
        if let e = error as? LocalizedError, let text = e.errorDescription, !text.isEmpty { return text }
        return fallback
    }

    /// `saveKeybinding`: the upsert goes to every connected target; the first failure shows a toast.
    private func saveKeybinding(_ target: KeybindingTarget, replace: KeybindingTarget?) {
        let targets = pageContext.scope.connected
        guard !targets.isEmpty, pageContext.scope.canWrite else { return }
        keybindingsPage?.savingCommand = target.command
        let payload = KeybindingsLogic.upsertPayload(target, replace: replace)
        Task {
            var failure: Error?
            for t in targets {
                do {
                    let result = try await environments.request(t.id, "server.upsertKeybinding", payload)
                    composer?.applyKeybindings(t.id, Keymap.decodeRules(result["keybindings"]))
                } catch { failure = failure ?? error }
            }
            keybindingsPage?.savingCommand = nil
            if let failure {
                toast("Unable to save keybinding", Self.rpcMessage(failure, fallback: "The keybinding was not saved."), .error)
            } else {
                keybindingsPage?.hideNewRow()
            }
            refreshPages()
        }
    }

    private func removeKeybinding(_ row: KeybindingRow) {
        let targets = pageContext.scope.connected
        guard !targets.isEmpty, pageContext.scope.canWrite else { return }
        keybindingsPage?.savingCommand = row.command
        Task {
            var failure: Error?
            for t in targets {
                do {
                    let result = try await environments.request(t.id, "server.removeKeybinding", KeybindingsLogic.removeInput(row).json)
                    composer?.applyKeybindings(t.id, Keymap.decodeRules(result["keybindings"]))
                } catch { failure = failure ?? error }
            }
            keybindingsPage?.savingCommand = nil
            if let failure { toast("Unable to remove keybinding", Self.rpcMessage(failure, fallback: "The keybinding was not removed."), .error) }
            refreshPages()
        }
    }

    /// "Open keybindings.json" (`openInPreferredEditor`): the file is on the primary environment's machine.
    // ponytail: opens the path on this Mac, which is right for the local server; a remote primary needs T3's open-in-editor RPC
    private func openKeybindingsFile() {
        guard let path = pageContext.keybindingsConfigPath else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            toast("Unable to open keybindings file", "The keybindings file was not opened.", .error)
        }
    }

    // MARK: Restore device defaults (SettingsPanels.tsx `useSettingsRestore`)

    /// The labels of every changed setting, in T3's order.
    func changedSettingLabels() -> [String] {
        let c = ClientSettingsStore.shared.current
        let s = pageContext.scope.values
        func client(_ key: String, _ label: String) -> [String] { c.isDefault(key) ? [] : [label] }
        func server(_ key: String, _ label: String) -> [String] { s.isDefault(key) ? [] : [label] }
        var labels: [String] = AppearanceMode.current == .system ? [] : ["Theme"]
        labels += client("appearanceContrast", "Contrast") + client("glassOpacity", "Glass opacity") + client("diffColorScheme", "Diff colors")
        labels += client("chatWidth", "Chat width") + client("panelAnimationDurationMs", "Panel animations")
        labels += client("environmentIdentificationMode", "Environment identification") + client("timestampFormat", "Time format")
        labels += client("notificationMode", "Thread notifications") + client("inAppNotificationsEnabled", "In-app notifications")
        labels += client("sidebarThreadPreviewCount", "Visible threads") + client("sidebarProjectGroupingMode", "Project Grouping")
        labels += client("sidebarProjectSortOrder", "Project order") + client("sidebarWorkingShelfEnabled", "Working section")
        labels += server("sidebarAutoSettleAfterDays", "Auto-settle inactive threads") + server("sidebarAutoSettleOnMerge", "Auto-settle merged threads")
        labels += server("autoResumeLimitedThreads", "Auto-resume limited threads") + server("snoozeLimitedThreads", "Snooze limited threads")
        labels += client("wordWrap", "Word wrap") + client("persistComposerContextStrip", "Composer context")
        for (family, size, label) in [("fontFamilySans", "fontSizeInterface", "Interface font"), ("fontFamilyComposer", "fontSizePrompt", "Prompt font"),
                                      ("fontFamilyCode", "fontSizeCode", "Code font"), ("fontFamilyTerminal", "fontSizeTerminal", "Terminal font")]
        where !c.isDefault(family) || !c.isDefault(size) { labels.append(label) }
        labels += client("diffFilesCollapsed", "Default diff file state") + client("diffIgnoreWhitespace", "Diff whitespace changes")
        labels += client("diffLayout", "Diff layout") + client("proactivePanelsEnabled", "Proactive panels")
        labels += client("showSkillsInSlashMenu", "Show skills in slash menu") + client("composerCollapseOnScroll", "Collapse composer on scroll")
        labels += client("composerRichTextEnabled", "Rich text composer") + client("sendShortcut", "Send shortcut")
        labels += client("followUpBehavior", "Follow-up behavior") + client("contextWindowMeterEnabled", "Context window indicator")
        labels += server("responseStreamingMode", "Response streaming") + server("enableProviderUpdateChecks", "Provider update checks")
        labels += server("continueThreadsAfterServerUpdate", "Continue threads after restarts")
        labels += BackgroundActivity.isChanged(s) ? ["Background activity"] : []
        labels += server("defaultThreadEnvMode", "New thread mode") + server("newWorktreesStartFromOrigin", "New worktrees start from origin")
        labels += server("addProjectBaseDirectory", "Add project base directory")
        labels += client("confirmThreadUnpin", "Unpin confirmation") + client("confirmThreadArchive", "Archive confirmation")
        labels += client("confirmThreadDelete", "Delete confirmation") + client("confirmQuit", "Quit shortcut")
        labels += server("textGenerationModelSelection", "Text generation model")
        return labels
    }

    /// The confirm dialog, then every changed setting back to its default.
    func confirmRestoreDefaults() {
        let labels = changedSettingLabels()
        guard !labels.isEmpty, let window, modal == nil else { return }
        let dialog = DialogView(kind: .alertDialog, title: "Restore default settings?", message: "This will reset: \(labels.joined(separator: ", ")).")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Confirm", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in host?.close(); self?.restoreDefaults() }
    }

    private func restoreDefaults() {
        if AppearanceMode.current != .system { AppearanceMode.system.apply() }
        let clientKeys = ["appearanceContrast", "glassOpacity", "diffColorScheme", "chatWidth", "panelAnimationDurationMs", "environmentIdentificationMode",
                          "timestampFormat", "notificationMode", "inAppNotificationsEnabled", "sidebarThreadPreviewCount", "sidebarProjectGroupingMode",
                          "sidebarProjectSortOrder", "sidebarWorkingShelfEnabled", "wordWrap", "persistComposerContextStrip", "fontFamilySans",
                          "fontSizeInterface", "fontFamilyComposer", "fontSizePrompt", "fontFamilyCode", "fontSizeCode", "fontFamilyTerminal",
                          "fontSizeTerminal", "diffFilesCollapsed", "diffIgnoreWhitespace", "diffLayout", "proactivePanelsEnabled",
                          "showSkillsInSlashMenu", "composerCollapseOnScroll", "composerRichTextEnabled", "sendShortcut", "followUpBehavior",
                          "contextWindowMeterEnabled", "confirmThreadUnpin", "confirmThreadArchive", "confirmThreadDelete", "confirmQuit"]
        ClientSettingsStore.shared.update(Dictionary(uniqueKeysWithValues: clientKeys.map { ($0, ClientSettings.fields[$0]!.defaultValue) }))
        let s = pageContext.scope.values
        var patch: [String: JSONValue] = [:]
        for key in ["sidebarAutoSettleAfterDays", "sidebarAutoSettleOnMerge", "autoResumeLimitedThreads", "snoozeLimitedThreads", "responseStreamingMode",
                    "enableProviderUpdateChecks", "continueThreadsAfterServerUpdate", "defaultThreadEnvMode", "newWorktreesStartFromOrigin",
                    "addProjectBaseDirectory", "textGenerationModelSelection"] where !s.isDefault(key) {
            patch[key] = ServerSettingsValues.fields[key]!.defaultValue
        }
        if BackgroundActivity.isChanged(s) { patch["backgroundActivity"] = BackgroundActivity.defaultSettings }
        if !patch.isEmpty { writeServer(patch) }
    }

    // MARK: Keys

    /// `/` focuses the settings search; Mod+F focuses the Keybindings search (SettingsSidebarNav.tsx:139-167,
    /// KeybindingsSettings.tsx:1345-1366).
    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.onKey { [weak self] event in
            guard let self, self.isOpen, self.modal == nil else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if flags == [.command], chars == "f", self.section == .keybindings, let page = self.keybindingsPage {
                page.focusSearch()
                return true
            }
            guard flags.isEmpty, chars == "/", !Shortcuts.editableFocused(in: self.window) else { return false }
            if self.window?.firstResponder is ShortcutCaptureResponder { return false }
            self.nav.focusSearch()
            return true
        }
    }
}
