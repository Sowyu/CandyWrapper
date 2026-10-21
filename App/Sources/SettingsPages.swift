import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// Settings pages: routing, settings search jumps, the scope, and the writes. Client settings go to
/// `ClientSettingsStore`; server settings go to every connected environment in the scope through
/// `server.updateSettings {patch}`, or into each selected project's override entry at a project scope;
/// keybindings through `server.upsertKeybinding` and `server.removeKeybinding` (useScopedSettings.ts,
/// scopedSettings.ts, KeybindingsSettings.tsx:1390-1460); projects through `projects.mutate`.
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
        c.clearServer = { [weak self] keys in
            guard let self else { return }
            self.run(self.pageContext.scope.planClear(keys))
        }
        c.request = { [weak self] env, method, payload in
            guard let self else { throw CancellationError() }
            return try await self.environments.request(env, method, payload)
        }
        c.subscribe = { [weak self] env, method, payload, receive in
            self?.environments.session(env)?.supervisor.subscribe(method, payload: { payload }, handler: { event in
                guard case .value(let value) = event else { return }
                await receive(value)
            })
        }
        c.applySettings = { [weak self] env, raw in self?.composer?.applySettings(env, raw) }
        c.confirm = { [weak self] message, _, action in
            let copy = ConfirmCopy.resolve(message)
            self?.confirm(copy.title, copy.description ?? "", then: action)
        }
        c.modelPreferences = { [weak self] env in self?.composer?.modelPreferences(env) ?? ([], .object([:])) }
        c.toggleFavorite = { [weak self] env, id, model in self?.composer?.toggleModelFavorite(env, id, model) }
        c.writeModelPreferences = { [weak self] env, instanceId, hidden, order in
            self?.composer?.writeModelPreferences(env, instanceId: instanceId, hidden: hidden, order: order)
        }
        c.openSection = { [weak self] section in self?.show(section) }
        c.chooseNotificationMode = { [weak self] mode in await self?.chooseNotificationMode?(mode) }
        c.closeSettings = { [weak self] in self?.close() }
        c.copy = { [weak self] text, title in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.toast(title, nil, .success)
        }
        c.updateProject = { [weak self] members, fields, title in self?.updateProject(members, fields, failureTitle: title) }
        c.chooseIconFile = { [weak self] env, cwd, name, external, onSelect in
            self?.chooseIconFile?(env, cwd, name, external, onSelect)
        }
        c.deleteProjects = { [weak self] members, leave in self?.deleteProjects(members, leave: leave) }
        c.threadCount = { [weak self] env, projectId in
            self?.environments.snapshot(env)?.threads.filter { $0.projectId.rawValue == projectId && $0.archivedAt == nil }.count ?? 0
        }
        c.subscribeProviderAuth = { [weak self] env, instance, receive in
            guard let supervisor = self?.environments.session(env)?.supervisor else { return nil }
            return supervisor.subscribe("provider.auth.subscribe", payload: { .object(["instanceId": .string(instance)]) }) { event in
                if case .value(let state) = event { await receive(state) }
            }
        }
        c.subscribeResourceTelemetry = { [weak self] env, receive in
            guard let supervisor = self?.environments.session(env)?.supervisor else { return nil }
            return supervisor.subscribe("subscribeResourceTelemetry", payload: { .object([:]) }) { event in
                if case .value(let state) = event { await receive(state) }
            }
        }
        c.saveActions = { [weak self] writes in await self?.saveActions(writes) }
        c.watchScheduledTasks = { [weak self] _ in self?.updateScheduledTaskWatch() }
        c.httpBaseURL = { [weak self] env in self?.environments.routeInUse(env) }
        _ = ScheduledTasksStore.shared.observe { [weak self] in
            guard let self, self.isOpen, self.section == .scheduledTasks else { return }
            self.refreshPages()
        }
        clientObserver = ClientSettingsStore.shared.observe { [weak self] _ in self?.refreshPages() }
        composer?.onConfigChange = { [weak self] _ in self?.refreshPages() }
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
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
        // `WorkspacePageContainer` widths: Connections and Providers are "wide", Diagnostics "expanded".
        page.containerWidth = [.connections, .providers].contains(section) ? 1024 : section == .diagnostics ? 1152 : 896
        let view: (NSView & SettingsGroupRow)
        switch section {
        case .general: view = generalPage()
        case .appearance: view = appearancePage()
        case .keybindings: view = keybindingsView()
        case .connections: view = connectionsPage
        default: view = extraPage(section)
        }
        if page.page !== view { page.page = view; page.scrollToTop() }
        refreshPages()
        extraPages[section]?.didShow()
        updateLinkPoll()
        onRouteChange?()
    }

    /// A search result: open its page, then scroll its anchor into view and pulse it.
    func jump(to item: SettingsSearchItem) {
        show(item.to.isAvailable ? item.to : section)
        guard item.to.isAvailable else { return }
        let target: NSView? = switch item.to {
        case .general: general?.anchor(item.anchor)
        case .appearance: appearance?.anchor(item.anchor)
        case .keybindings: keybindingsPage?.anchor(item.anchor)
        default: extraPages[item.to]?.anchor(item.anchor)
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

    /// The WP7.7b pages, built on first open.
    private func extraPage(_ section: SettingsSection) -> SettingsPageBase {
        if let existing = extraPages[section] { return existing }
        let c = pageContext
        let v: SettingsPageBase = switch section {
        case .projects: ProjectSettingsView(context: c)
        case .providers: ProvidersSettingsView(context: c)
        case .integrations: IntegrationsSettingsView(context: c)
        case .sourceControl: SourceControlSettingsView(context: c)
        case .storage: StorageSettingsView(context: c)
        case .archive: ArchiveSettingsView(context: c)
        case .diagnostics: DiagnosticsSettingsView(context: c)
        case .licenses: SettingsOpenSourceLicensesView(context: c)
        case .scheduledTasks: ScheduledTasksSettingsView(context: c)
        default: SnapShotSettingsView(context: c)
        }
        v.onHeightChange = { [weak self] in self?.page.pageChanged() }
        extraPages[section] = v
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
        default: extraPages[section]?.refresh()
        }
        nav.showsProject = pageContext.scope.selection.project != nil
        updateScheduledTaskWatch()
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
                                     projects: projectGroups(), projectFiles: projectFiles)
        loadProjectFiles(c.scope.members)
        c.providers = c.scope.representative.flatMap { composer?.config($0.id)?.providers } ?? []
        c.configs = Dictionary(uniqueKeysWithValues: ids.compactMap { id in composer?.config(id).map { (id, $0) } })
        let primary = environments.primaryId.flatMap { composer?.config($0) }
        c.serverKeybindings = primary?.keybindings ?? []
        c.keybindingsConfigPath = primary?.keybindingsConfigPath
        c.scheduledTasks = ScheduledTasksStore.shared.lists
    }

    /// `useMemberProjectFiles` (SettingsScopeContext.tsx:20-55): each selected checkout's t3.json, so file-backed
    /// settings show the file as a tier. A failed read counts as no file; the page refreshes when one lands.
    private func loadProjectFiles(_ members: [SettingsScopeProject.Member]) {
        for m in members {
            let key = m.physicalKey
            guard projectFiles[key] == nil, !projectFileLoads.contains(key), environments.state(m.environmentId)?.status == .connected else { continue }
            projectFileLoads.insert(key)
            Task { [weak self] in
                let reply = try? await self?.environments.request(m.environmentId, "projects.readFile",
                                                                   .object(["cwd": .string(m.workspaceRoot), "relativePath": .string(T3ProjectFile.fileName)]))
                guard let self, self.projectFileLoads.contains(key) else { return }
                let contents = reply?["truncated"]?.boolValue == true ? nil : reply?["contents"]?.stringValue
                self.projectFiles[key] = .some(contents.flatMap(T3ProjectFile.parse))
                self.refreshPages()
            }
        }
    }

    /// `useSettingsProjectGroups`: the sidebar's logical projects over every environment, by display name.
    private func projectGroups() -> [SettingsScopeProject] {
        var projects: [ProjectShell] = []
        for id in environments.environmentIds {
            projects += (environments.snapshot(id)?.projects ?? []).map { EnvironmentScope.scope($0, id) }
        }
        return SidebarModel.buildProjectGroups(projects, preferredEnvironmentId: environments.primaryId).map { g in
            SettingsScopeProject(key: g.key, displayName: g.label, members: g.members.map { p in
                let env = p.id.environmentId ?? ""
                return SettingsScopeProject.Member(
                    environmentId: env, projectId: EnvironmentScope.localId(of: p.id.rawValue), title: p.title, workspaceRoot: p.workspaceRoot,
                    environmentLabel: environments.label(env), faviconPath: p.faviconPath, projectIcon: p.projectIcon,
                    scripts: p.scripts.compactMap(ProjectScript.init),
                    legacy: ProjectSettings.Legacy(defaultModelSelection: p.defaultModelSelection.flatMap { try? JSONValue(encoding: $0) },
                                                   defaultThreadEnvMode: p.defaultThreadEnvMode))
            }, icon: ProjectIconSource(g.representative))
        }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// A shell changed: projects, their scripts and thread counts follow.
    func shellChanged() {
        guard isOpen else { return }
        refreshPages()
    }

    /// `useAvailableSettingsSearchItems` for this client.
    func searchAvailability() -> SettingsSearchAvailability {
        var a = SettingsSearchAvailability()
        a.hasEnvironment = !environments.environmentIds.isEmpty
        a.hasThreadAutoSettlement = environments.environmentIds.contains { composer?.config($0)?.capabilities.contains("threadAutoSettlement") == true }
        a.hasCloudPublicConfig = t3.loaded
        return a
    }

    // MARK: Writes

    private func writeServer(_ patch: [String: JSONValue]) { run(pageContext.scope.plan(patch)) }

    /// `useRunScopedPlan`: one `server.updateSettings` per target; the reply's settings apply at once.
    private func run(_ plan: (writes: [SettingsScopeState.Write], unavailableReason: String?)) {
        if let reason = plan.unavailableReason {
            toast("Setting not saved", reason, .warning)
            return
        }
        Task {
            var failures: [String] = [], saved: [String] = []
            for w in plan.writes {
                do {
                    let previous = composer?.config(w.environmentId)?.settings.raw
                    let result = try await environments.request(w.environmentId, "server.updateSettings", .object(["patch": .object(w.patch)]))
                    composer?.applySettings(w.environmentId, result)
                    // An older server drops a key it does not know and still succeeds (scopedSettings.ts, 8ac4b97da).
                    if let previous, !SettingsScopeState.droppedKeys(w.patch, previous: previous, saved: result).isEmpty {
                        failures.append("Could not save on \(w.label): This environment does not support this setting. Update T3 Code on it.")
                        continue
                    }
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

    // MARK: Projects (ProjectSettingsPanel.tsx)

    /// `updateAllMembers`: `project.update` on every member in turn; a failure names its environment when
    /// the group spans several and stops there.
    private func updateProject(_ members: [SettingsScopeProject.Member], _ fields: [String: JSONValue], failureTitle: String) {
        if let offline = members.first(where: { environments.state($0.environmentId)?.status != .connected }) {
            toast(failureTitle, "Connect \(offline.environmentLabel ?? "the selected environment") and try again.", .error)
            return
        }
        Task {
            for m in members {
                var o = fields
                o["type"] = .string("project.update")
                o["commandId"] = .string(ThreadCommands.newCommandId())
                o["projectId"] = .string(m.projectId)
                do {
                    _ = try await environments.request(m.environmentId, "projects.mutate", .object(o))
                } catch {
                    toast(members.count > 1 ? "\(failureTitle) on \(m.environmentLabel ?? "the current environment")" : failureTitle,
                          Self.rpcMessage(error, fallback: "An error occurred."), .error)
                    return
                }
            }
        }
    }

    /// `removeMembers` after the confirm: `project.delete {force: true}` per member; the whole project goes back
    /// to the thread view.
    private func deleteProjects(_ members: [SettingsScopeProject.Member], leave: Bool) {
        Task {
            for m in members {
                do {
                    _ = try await environments.request(m.environmentId, "projects.mutate", .object([
                        "type": .string("project.delete"), "commandId": .string(ThreadCommands.newCommandId()),
                        "projectId": .string(m.projectId), "force": .bool(true),
                    ]))
                } catch {
                    toast("Failed to remove \"\(m.title)\"", Self.rpcMessage(error, fallback: "An error occurred."), .error)
                    return
                }
            }
            if leave {
                // `waitForProjectRemoval` (state/entities.ts, T3 3105 11fd54fcb): the delete returns before the shell
                // stream drops the project, and the thread view would open a new draft in it meanwhile. 5 s at most.
                // ponytail: checks the snapshot every 50 ms for those few seconds; observe the shell store if this grows callers
                for _ in 0..<100 where members.contains(where: { m in
                    environments.snapshot(m.environmentId)?.projects.contains { $0.id.rawValue == m.projectId } == true
                }) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                scopeSelection = SettingsScopeSelection(machine: scopeSelection.machine, project: nil)
                close()
            } else {
                refreshPages()
            }
        }
    }

    /// `persist`: each environment's settings write, then its shortcut changes. The first failure stops the rest.
    func saveActions(_ writes: [ProjectActionsLogic.Write]) async -> String? {
        for w in writes {
            do {
                let result = try await environments.request(w.environmentId, "server.updateSettings", .object(["patch": .object(w.patch)]))
                composer?.applySettings(w.environmentId, result)
                for op in w.bindings {
                    let reply: JSONValue
                    switch op {
                    case .upsert(let target, let replace):
                        reply = try await environments.request(w.environmentId, "server.upsertKeybinding", KeybindingsLogic.upsertPayload(target, replace: replace))
                    case .remove(let target):
                        reply = try await environments.request(w.environmentId, "server.removeKeybinding", target.json)
                    }
                    composer?.applyKeybindings(w.environmentId, Keymap.decodeRules(reply["keybindings"]))
                }
            } catch {
                return Self.rpcMessage(error, fallback: "An error occurred.")
            }
        }
        refreshPages()
        return nil
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
    private func openKeybindingsFile() {
        guard let path = pageContext.keybindingsConfigPath, let env = environments.primaryId,
              let config = pageContext.configs[env],
              let editor = OpenInEditors.preferred(available: config.availableEditors, last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey)) else { return }
        Task { [weak self] in
            do { _ = try await self?.environments.request(env, "shell.openInEditor", OpenInEditors.launchInput(cwd: path, editor: editor)) }
            catch { self?.toast("Unable to open keybindings file", "\(error)", .error) }
        }
    }

    // MARK: Restore device defaults (SettingsPanels.tsx `useSettingsRestore`)

    /// The labels of every changed setting, in T3's order.
    func changedSettingLabels() -> [String] {
        let c = ClientSettingsStore.shared.current
        let s = pageContext.scope.values
        func client(_ key: String, _ label: String) -> [String] { c.isDefault(key) ? [] : [label] }
        func server(_ key: String, _ label: String) -> [String] { s.isDefault(key) ? [] : [label] }
        let themes = ThemeLibrary.shared
        var labels: [String] = themes.preference == "system" ? [] : ["Theme"]
        labels += themes.appearanceMode == "system" ? [] : ["Follow system"]
        labels += themes.halves.light == nil && themes.halves.dark == nil ? [] : ["Theme mix"]
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
        labels += server("defaultThreadEnvMode", "New thread mode") + server("newWorktreesStartFromOrigin", "New worktrees start from remote")
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
        let themes = ThemeLibrary.shared
        if themes.preference != "system" { themes.setTheme("system") }
        themes.clearThemeHalves()
        if themes.appearanceMode != "system" { AppearanceMode.system.apply() }
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

    /// `/` outside a text field, and Mod+F from anywhere, focus the settings search (SettingsSidebarNav.tsx:141-181
    /// in 2994, f769e01e2). A shortcut recorder keeps both keys.
    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.onKey { [weak self] event in
            guard let self, self.isOpen, self.modal == nil else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let find = flags == [.command] && chars == "f"
            let slash = flags.isDisjoint(with: [.command, .control, .option]) && event.charactersIgnoringModifiers == "/"
                && !Shortcuts.editableFocused(in: self.window)
            guard find || slash else { return false }
            if self.window?.firstResponder is ShortcutCaptureResponder { return false }
            self.nav.focusSearch()
            return true
        }
    }
}

extension SettingsController {
    /// Settings follows the scope's task lists while Scheduled Tasks is open.
    func updateScheduledTaskWatch() {
        let ids = isOpen && section == .scheduledTasks ? Set(pageContext.scope.environmentIds) : []
        ScheduledTasksStore.shared.watch("settings", ids)
    }

    /// `/projects/$projectKey`, which redirects to `/settings/projects?project=<key>` (routes/projects.$projectKey.tsx).
    func openProject(_ key: String) {
        open()
        scopeSelection = SettingsScopeSelection(machine: nil, project: key)
        show(.projects)
    }

    /// Opens Scheduled Tasks for an environment, and a task's editor once its list arrives (the thread automations panel).
    func openScheduledTasks(environmentId: String, taskId: String?) {
        open()
        show(.scheduledTasks)
        if let taskId, let page = extraPages[.scheduledTasks] as? ScheduledTasksSettingsView {
            page.linkedTask = (environmentId, taskId)
            refreshPages()
        }
    }
}
