import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Settings > Providers logic (ProviderSettingsPanel.tsx, ProviderInstanceCard.tsx, ProviderModelsSection.tsx,
/// providerStatus.ts, providerDriverMeta.ts).
public enum ProvidersLogic {
    /// `providerClients` in presentation order: driver, label, whether it has a default instance.
    public static let drivers: [(driver: String, label: String, hasDefault: Bool)] = [
        ("codex", "Codex", true), ("claudeAgent", "Claude", true), ("cursor", "Cursor", true), ("grok", "Grok", true),
        ("opencode", "OpenCode", true), ("antigravity", "Antigravity", true), ("muse", "Muse Code", true), ("pi", "Pi", true),
        ("acpRegistry", "ACP Registry", false),
    ]

    public static func label(_ driver: String) -> String? { drivers.first { $0.driver == driver }?.label }

    /// One card in the list (`InstanceRow`).
    public struct Row: Equatable, Sendable {
        public var instanceId: String
        public var instance: JSONValue
        public var driver: String
        public var isDefault: Bool
        public var isDirty: Bool
        public var enabled: Bool { ProjectSettings.providerInstanceEnabled(instance) }
    }

    /// `rows`: each driver's default slot (Codex and Claude always; others when configured or enabled), then its
    /// other instances, then instances of drivers this build doesn't ship. Cursor shows only when the server has it.
    public static func rows(settings: ServerSettingsValues, providers: [ServerProvider], target: String? = nil) -> [Row] {
        let configured = settings["providerInstances"].objectValue ?? [:]
        let visible = drivers.filter { $0.driver != "cursor" || providers.contains { $0.instanceId.rawValue == "cursor" } }
        var byDriver: [String: [(String, JSONValue)]] = [:]
        for (id, instance) in configured.sorted(by: { $0.key < $1.key }) {
            byDriver[instance["driver"]?.stringValue ?? "", default: []].append((id, instance))
        }
        var rows: [Row] = []
        for d in visible {
            let explicit = configured[d.driver]
            let effective = explicit ?? .object(["driver": .string(d.driver)])
            let isDirty = explicit != nil
            if (d.hasDefault || isDirty) && (d.driver == "codex" || d.driver == "claudeAgent" || isDirty
                                             || ProjectSettings.providerInstanceEnabled(effective) || d.driver == target) {
                rows.append(Row(instanceId: d.driver, instance: effective, driver: d.driver, isDefault: true, isDirty: isDirty))
            }
            for (id, instance) in byDriver[d.driver] ?? [] where id != d.driver {
                rows.append(Row(instanceId: id, instance: instance, driver: d.driver, isDefault: false, isDirty: true))
            }
        }
        let known = Set(visible.map(\.driver))
        for (driver, list) in byDriver.sorted(by: { $0.key < $1.key }) where !known.contains(driver) {
            for (id, instance) in list {
                rows.append(Row(instanceId: id, instance: instance, driver: driver, isDefault: visible.contains { $0.driver == id }, isDirty: true))
            }
        }
        return rows
    }

    /// `getProviderSummary`.
    public static func summary(_ p: ServerProvider?) -> (headline: String, detail: String?) {
        guard let p else { return ("Checking provider status", "Waiting for the server to report installation and authentication details.") }
        if !p.enabled || p.status.rawValue == "disabled" {
            return ("Disabled", p.message ?? "This provider is installed but disabled for new sessions in T3 Code.")
        }
        if !p.installed { return ("Not found", p.message ?? "CLI not detected on PATH.") }
        let authLabel = p.auth?["label"]?.stringValue ?? p.auth?["type"]?.stringValue
        switch p.auth?["status"]?.stringValue {
        case "unauthenticated": return (authLabel.map { "Not authenticated · \($0)" } ?? "Not authenticated", p.message)
        default: break
        }
        if p.status.rawValue == "warning" { return ("Needs attention", p.message ?? "The provider is installed, but the server could not fully verify it.") }
        if p.status.rawValue == "error" { return ("Unavailable", p.message ?? "The provider failed its startup checks.") }
        if p.auth?["status"]?.stringValue == "authenticated" { return (authLabel.map { "Authenticated · \($0)" } ?? "Authenticated", p.message) }
        return ("Available", p.message)
    }

    /// `getProviderVersionLabel`.
    public static func versionLabel(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        if let m = version.firstMatch(of: /^agy_acp_server_(\d{4})(\d{2})(\d{2})_\d+(?:_(\w+))?$/) {
            return "\(m.1)-\(m.2)-\(m.3)" + (m.4.map { " \($0)" } ?? "")
        }
        return version.first?.isNumber == true ? "v\(version)" : version
    }

    /// The custom models in an instance's config (`readConfigCustomModels`): a string or `{slug, name?}`.
    public static func customModels(_ instance: JSONValue) -> [(slug: String, name: String, raw: JSONValue)] {
        (instance["config"]?["customModels"]?.arrayValue ?? []).compactMap { entry in
            if let s = entry.stringValue { return (s, s, entry) }
            guard let slug = entry["slug"]?.stringValue else { return nil }
            return (slug, entry["name"]?.stringValue ?? slug, entry)
        }
    }

    public struct DisplayModel: Equatable, Sendable {
        public var slug: String
        public var name: String
        public var isCustom: Bool
        public var capabilities: [String]
    }

    /// `deriveProviderModelsForDisplay` then `groupModelsForDisplay`: favorites, visible, hidden; each in the
    /// saved order, then the server's.
    public static func displayModels(live: [ServerProviderModel], custom: [(slug: String, name: String, raw: JSONValue)],
                                     favorites: Set<String>, hidden: Set<String>, order: [String]) -> [DisplayModel] {
        var models = live.filter { !$0.isCustom }.map { DisplayModel(slug: $0.slug, name: $0.name, isCustom: false, capabilities: capabilities($0)) }
        models += custom.map { c in
            DisplayModel(slug: c.slug, name: c.name, isCustom: true, capabilities: live.first { $0.slug == c.slug }.map(capabilities) ?? [])
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let original = Dictionary(models.enumerated().map { ($1.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = models.sorted { l, r in
            let lf = favorites.contains(l.slug), rf = favorites.contains(r.slug)
            if lf != rf { return lf }
            switch (rank[l.slug], rank[r.slug]) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return original[l.slug]! < original[r.slug]!
            }
        }
        func isHidden(_ m: DisplayModel) -> Bool { !m.isCustom && hidden.contains(m.slug) }
        return sorted.filter { favorites.contains($0.slug) } + sorted.filter { !favorites.contains($0.slug) && !isHidden($0) }
            + sorted.filter { !favorites.contains($0.slug) && isHidden($0) }
    }

    /// `describeModelCapabilities`.
    static func capabilities(_ m: ServerProviderModel) -> [String] {
        let d = m.optionDescriptors
        var labels: [String] = []
        if d.contains(where: { $0.id == "fastMode" || ($0.id == "serviceTier" && $0.type == .select && $0.options.contains { $0.id == "fast" || $0.label == "Fast" }) }) {
            labels.append("Fast mode")
        }
        if d.contains(where: { $0.id == "thinking" }) { labels.append("Thinking") }
        if d.contains(where: { $0.type == .select && ["reasoningEffort", "effort", "reasoning", "variant"].contains($0.id) }) { labels.append("Reasoning") }
        return labels
    }

    /// `handleAdd`'s validation: nil when the slug can be added.
    public static func customModelError(_ input: String, live: [DisplayModel], custom: [String]) -> String? {
        let slug = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty { return "Enter a model slug." }
        if live.contains(where: { !$0.isCustom && $0.slug == slug }) { return "That model is already built in." }
        if slug.count > 256 { return "Model slugs must be 256 characters or less." }
        if custom.contains(slug) { return "That custom model is already saved." }
        return nil
    }

    /// `nextHiddenModelsForBulkToggle`: hide every built-in model, or show them all when all are hidden.
    public static func bulkToggle(_ models: [DisplayModel], hidden: [String]) -> [String] {
        let builtIn = models.filter { !$0.isCustom }.map(\.slug)
        if builtIn.allSatisfy(hidden.contains) { return hidden.filter { !builtIn.contains($0) } }
        var seen = Set<String>()
        return (hidden + builtIn).filter { seen.insert($0).inserted }
    }

    /// Runtime fields per driver (each driver's settings schema, `providerSettingsForm` annotations, in `order`).
    public struct Field: Sendable { public var key, title, detail, placeholder: String; public var secret = false; public var options: [(String, String)] = []; public var defaultValue = "" }
    public static func fields(_ driver: String, config: JSONValue? = nil) -> [Field] {
        func binary(_ name: String, _ detail: String) -> Field { Field(key: "binaryPath", title: "Binary path", detail: detail, placeholder: name) }
        switch driver {
        case "codex": return [binary("codex", "Path to the Codex binary used by this instance."),
                              Field(key: "homePath", title: "CODEX_HOME path", detail: "Custom Codex home and config directory.", placeholder: "~/.codex"),
                              Field(key: "shadowHomePath", title: "Shadow home path",
                                    detail: "Account-specific Codex home. Keeps auth.json separate while sharing state from CODEX_HOME.",
                                    placeholder: "~/.codex-t3/personal"),
                              Field(key: "launchArgs", title: "Launch arguments", detail: "Additional CLI arguments passed to codex app-server on session start.",
                                    placeholder: "")]
        case "claudeAgent": return [binary("claude", "Path to the Claude binary used by this instance."),
                                    Field(key: "homePath", title: "CLAUDE_CONFIG_DIR path",
                                          detail: "Custom Claude home and config directory. Keeps .claude.json and .claude separate.", placeholder: "~/.claude"),
                                    Field(key: "autoCompactWindow", title: "Auto-compact after",
                                          detail: "Compact after 100,000 to 1,000,000 tokens. Leave empty to use Claude's default.", placeholder: "e.g. 300000"),
                                    Field(key: "launchArgs", title: "Launch arguments", detail: "Additional CLI arguments passed on session start.",
                                          placeholder: "e.g. --chrome")]
        case "grok": return [binary("grok", "Path to the Grok CLI binary.")]
        case "muse": return [binary("muse", "Path to the Muse Code binary on this environment. Sign in with muse login on that host.")]
        case "pi": return [binary("pi", "Path to the Pi coding agent binary."),
                           Field(key: "launchArgs", title: "Launch arguments", detail: "Additional CLI arguments passed to pi --mode rpc on session start.", placeholder: "")]
        case "opencode": return [binary("opencode", "Path to the OpenCode binary."),
                                 Field(key: "serverUrl", title: "Server URL", detail: "Leave blank to let T3 Code spawn the server when needed.",
                                       placeholder: "http://127.0.0.1:4096"),
                                 Field(key: "serverPassword", title: "Server password", detail: "Stored in plain text on disk.", placeholder: "Optional", secret: true)]
        case "antigravity": return [
            Field(key: "authMethod", title: "Sign-in method", detail: "Google accounts use your subscription; API keys and Agent Platform bill usage.", placeholder: "", options: [("oauth-personal", "Google account"), ("oauth-business", "Gemini Enterprise"), ("gemini-api-key", "Gemini API key"), ("agent-platform", "Agent Platform (Vertex AI)")], defaultValue: "oauth-personal"),
            Field(key: "apiKey", title: "API key", detail: "Gemini or Vertex AI express key. Stored in plain text.", placeholder: "Optional", secret: true),
            Field(key: "gcpProject", title: "GCP project", detail: "Required for Gemini Enterprise. Agent Platform uses it when no API key is set.", placeholder: "my-project-id"),
            Field(key: "gcpLocation", title: "GCP location", detail: "Region for Gemini Enterprise or Agent Platform.", placeholder: "us-central1"),
            binary("Automatic", "Custom ACP executable. Leave empty to select automatically.")]
        case "acpRegistry":
            let local = config?["source"]?.stringValue == "local"
            return [Field(key: "source", title: "ACP source", detail: "", placeholder: "", options: [("registry", "ACP Registry"), ("local", "Local command")], defaultValue: "registry"),
                Field(key: "agentId", title: "Registry agent ID", detail: "Agent identifier from the official ACP Registry, for example 'devin'.", placeholder: "devin"),
                Field(key: "commandPath", title: "Executable override", detail: "Executable on this environment. For registry agents, this overrides the distribution executable while keeping its arguments and environment.", placeholder: "Registry default"),
                Field(key: "authMethodId", title: "Authentication method", detail: "Optional ACP authentication method ID. By default, the first agent-managed method is selected.", placeholder: "auto")].filter { !local || ["source", "commandPath"].contains($0.key) }
        default: return []
        }
    }

    /// `nextProviderConfigWithFieldValue` with `clearWhenEmpty: "omit"`: an empty value drops the key.
    public static func config(_ instance: JSONValue, set key: String, to value: String) -> JSONValue {
        var o = instance.objectValue ?? [:]
        var config = o["config"]?.objectValue ?? [:]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !(o["driver"]?.stringValue == "antigravity" && key == "binaryPath") && !(o["driver"]?.stringValue == "acpRegistry" && key == "agentId") { config.removeValue(forKey: key) } else { config[key] = .string(trimmed) }
        if config.isEmpty { o.removeValue(forKey: "config") } else { o["config"] = .object(config) }
        return .object(o)
    }
}

/// Settings > Providers (ProviderSettingsPanel.tsx `EnvironmentProviderSettings`): one environment's provider
/// instances as a list beside the selected instance's editor, then the health check interval.
public final class ProvidersSettingsView: ScopedSettingsPage {
    private let placeholder = SettingsNoticeView("")
    private let providers = ProvidersSectionView()
    private var healthRow: SettingsRowView!
    private let health = NumberFieldView(value: 300, size: .sm)
    private var selected: String?
    private var refreshing = false
    private var expandedModelAdd: Set<String> = []
    /// Per instance: the variables the rows last matched or published, and the rows (`ProviderEnvironmentSection` state).
    private var environmentDrafts: [String: (published: [ProviderEnvironmentLogic.Variable], rows: [ProviderEnvironmentLogic.Draft])] = [:]
    private var environmentDraftId = 0
    /// Instances with an update request in flight (`updatingProviderInstanceIds`).
    private var updatingInstances: Set<String> = []
    /// The instance the editor was built for.
    private var editorInstance: String?
    private let usageProviders = SettingsSectionView(title: "Usage providers", rows: [])
    private let addHub = ButtonView("Add hub", icon: .plus, variant: .outline, size: .xs)
    private var updatingCursor = false

    public init(context: SettingsPageContext) {
        super.init(context: context)
        sentence.singleEnvironment = true
        anchors["providers"] = providers
        healthRow = buildHealth()
        anchors["usage-providers"] = usageProviders
        addHub.iconSize = 12
        usageProviders.headerAction = addHub
        addHub.action = { [weak self] in self?.openAddHub() }
        body = [placeholder, providers, usageProviders, section(nil, "Advanced", [healthRow])]
        providers.add.action = { [weak self] in self?.openAddProvider() }
        providers.addRow.action = { [weak self] in self?.openAddProvider() }
        providers.refresh.action = { [weak self] in self?.refreshProviders() }
        binder.add { [weak self] in self?.update() }
    }

    /// `selectSingleEnvironmentScope`: the chosen environment, else the primary, else the first connected.
    var environment: SettingsScopeEnvironment? {
        let scope = context.scope
        if let machine = scope.selection.machine { return scope.environments.first { $0.id == machine && $0.connected && $0.settings != nil } }
        let ids = scope.environmentIds
        let candidates = scope.environments.filter { ids.contains($0.id) }
        return candidates.first { $0.id == scope.primaryId && $0.connected } ?? candidates.first { $0.connected && $0.settings != nil }
    }

    private func update() {
        let scope = context.scope
        sentence.impliedMachine = environment?.id
        sentence.refresh()
        guard let env = environment, let settings = env.settings else {
            placeholder.message = scope.selection.machine != nil ? "Reconnect \(scope.label) to set up its providers." : "Connect an environment to set up its providers."
            setHidden(placeholder, false)
            setHidden(providers, true)
            for item in body.dropFirst(2) { setHidden(item, true) }
            return
        }
        setHidden(placeholder, true)
        setHidden(providers, false)
        for item in body.dropFirst(2) { setHidden(item, false) }
        let live = context.configs[env.id]?.providers ?? []
        let rows = ProvidersLogic.rows(settings: settings, providers: live)
        let chosen = rows.first { $0.instanceId == selected } ?? rows.first
        providers.add.isEnabled = env.canWrite
        providers.addRow.isEnabled = env.canWrite
        providers.refresh.isEnabled = !refreshing
        let last = live.map { $0.checkedAt ?? "" }.max()
        providers.setChecked(refreshing ? "Refreshing providers" : last.map { iso -> String in
            let label = TimestampFormat.formatRelativeTimeLabel(iso, nowMs: TimestampFormat.nowMs())
            return label.isEmpty ? "Checked unavailable" : "Checked \(label)"
        })
        providers.list = rows.map { row in
            let p = live.first { $0.instanceId.rawValue == row.instanceId }
            let item = ProviderListRow(row: row, provider: p)
            item.isSelected = row.instanceId == chosen?.instanceId
            item.onSelect = { [weak self] in self?.selected = row.instanceId; self?.refresh() }
            item.toggle.isEnabled = env.canWrite
            item.toggle.onChange = { [weak self] on in self?.setEnabled(row, on, env: env.id) }
            let name = row.instance["displayName"]?.stringValue ?? ProvidersLogic.label(row.driver) ?? row.driver
            item.advisory = advisoryButton(row, provider: p, readOnly: !env.canWrite, displayName: name, micro: true)
            if updatingInstances.contains(row.instanceId) || ProviderVersionAdvisoryLogic.isUpdating(p) {
                item.updateProgress = (ProviderVersionAdvisoryLogic.isUpdating(p) ? p?.updateState?.message : nil) ?? "Starting update"
            }
            return item
        }
        if let chosen {
            // A server echo arriving while a field of the same editor has focus would drop what is being typed
            // (T3's inputs keep their draft across renders). Keep that editor; its writes read the live instance.
            let editing = editorInstance == chosen.instanceId && providers.editor?.isFirstResponderInside == true
            if !editing {
                providers.editor = editor(chosen, provider: live.first { $0.instanceId.rawValue == chosen.instanceId }, env: env)
                editorInstance = chosen.instanceId
            }
        } else {
            providers.editor = nil
            editorInstance = nil
        }
        providers.needsLayout = true
        // Health check interval: the resolved value against the profile's preset.
        let s = ServerSettingsValues(.object(settings.raw))
        let seconds = (BackgroundActivity.resolveServer(s).providerHealthRefreshInterval / 1000).rounded()
        let preset = (BackgroundActivity.presets[BackgroundActivity.resolveServer(s).profile]!.providerHealthRefreshInterval / 1000).rounded()
        if !health.isFirstResponderInside { health.value = seconds }
        (healthRow.accessories.last as? ResetSlot)?.isShown = seconds != preset && env.canWrite
        health.isEnabled = env.canWrite
        updateUsageProviders(env, settings: s)
    }

    private func openAddProvider() {
        guard let env = environment, env.canWrite, let window else { return }
        let ids = Set(env.settings?["providerInstances"].objectValue?.keys.map { $0 } ?? [])
        let dialog = ProviderAddWizardView(context: context, environment: env.id, label: env.label, existing: ids)
        let host = ModalHost.present(dialog, in: window)
        dialog.close = { [weak host] in host?.close() }
        dialog.onCreated = { [weak self] id in self?.selected = id; self?.refresh() }
    }

    // MARK: Usage providers (UsageProviderSettings.tsx)

    /// The Cursor Keychain switch on a Mac server, then one row per CLIProxyAPI hub with Remove, or "No hubs configured."
    private func updateUsageProviders(_ env: SettingsScopeEnvironment, settings: ServerSettingsValues) {
        addHub.isHidden = !env.canWrite
        var rows: [any SettingsGroupRow] = []
        if context.configs[env.id]?.platformOS == "darwin" {
            let toggle = SwitchView(isOn: settings["cursorKeychainUsageEnabled"].boolValue == true)
            toggle.setAccessibilityLabel("Cursor account usage")
            toggle.isEnabled = env.canWrite && !updatingCursor
            toggle.onChange = { [weak self] on in self?.setCursorUsage(on, env: env.id) }
            rows.append(row("cursor-keychain-usage", title: "Cursor account usage",
                            detail: "Read your existing Cursor CLI login from macOS Keychain to show account history and monthly limits. macOS may ask you to allow access.",
                            control: toggle))
        }
        let sources = (settings["usageLimitSources"].objectValue ?? [:]).sorted { $0.key < $1.key }
        if sources.isEmpty {
            rows.append(SettingsRowView(title: "No hubs configured."))
        } else {
            for (id, source) in sources {
                let url = source["url"]?.stringValue ?? ""
                let label = source["label"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? url
                let enabled = source["enabled"]?.boolValue ?? true
                let remove = ButtonView("Remove", variant: .ghost, size: .xs)
                remove.isHidden = !env.canWrite
                remove.action = { [weak self] in self?.confirmRemoveHub(id: id, label: label, env: env.id) }
                rows.append(SettingsRowView(title: label, detail: "CLI Proxy" + (enabled ? "" : " · Disabled") + (label != url ? " · \(url)" : ""), control: remove))
            }
        }
        usageProviders.group.rows = rows
    }

    private func setCursorUsage(_ on: Bool, env: String) {
        guard let request = context.request else { return }
        updatingCursor = true
        Task { [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", .object(["patch": .object(["cursorKeychainUsageEnabled": .bool(on)])]))
                self?.context.applySettings?(env, result)
                _ = try? await request(env, "server.refreshProviders", .object([:]))
            } catch {
                self?.context.toast?("Could not update Cursor account usage", "\(error)", .error)
            }
            self?.updatingCursor = false
            self?.refresh()
        }
    }

    /// Removing a hub deletes its stored management key, so it asks first.
    private func confirmRemoveHub(id: String, label: String, env: String) {
        guard let window else { return }
        let d = DialogView(kind: .alertDialog, title: "Remove \(label)?",
                           message: "The hub's management key is deleted from this server. Its accounts leave the Limits view; the hub itself is untouched. Add it again with the URL and key to bring them back.")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Remove hub", variant: .destructive)
        d.footerButtons = [cancel, ok]
        let host = ModalHost.present(d, in: window)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak self, weak host] in
            host?.close()
            self?.writeHubPatch(env, .object([id: .null]))
        }
    }

    private func writeHubPatch(_ env: String, _ sources: JSONValue) {
        guard let request = context.request else { return }
        Task { [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", .object(["patch": .object(["usageLimitSources": sources])]))
                self?.context.applySettings?(env, result)
            } catch {
                self?.context.toast?("Could not update usage providers", "\(error)", .error)
            }
        }
    }

    /// `AddUsageLimitSourceDialog`: Hub URL, Management key and an optional Label; the key goes to that server only.
    private func openAddHub() {
        guard let env = environment, let window else { return }
        let d = DialogView(title: "Add a CLIProxyAPI hub",
                           message: "Show the quota of every account the hub pools, next to the providers on \(env.label). The key stays on that server.")
        d.maxWidth = 448
        let url = InputView(placeholder: "https://hub.example.ts.net:8318")
        let key = SecureInputView()
        let label = InputView(placeholder: "Defaults to the hub's host name")
        d.panelContent = [UsageHubFormView([("Hub URL", url), ("Management key", key), ("Label (optional)", label)])]
        let cancel = ButtonView("Cancel", variant: .outline)
        let add = ButtonView("Add hub")
        add.isEnabled = false
        d.footerVariant = .bare
        d.footerButtons = [cancel, add]
        let host = ModalHost.present(d, in: window)
        let validate: @MainActor (String) -> Void = { _ in
            add.isEnabled = !url.text.trimmingCharacters(in: .whitespaces).isEmpty && !key.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        url.onChange = validate
        key.onChange = validate
        cancel.action = { [weak host] in host?.close() }
        add.action = { [weak self, weak host] in
            let u = url.text.trimmingCharacters(in: .whitespaces)
            var entry: [String: JSONValue] = ["kind": .string("cliproxy"), "url": .string(u),
                                              "managementKey": .string(key.text.trimmingCharacters(in: .whitespaces)), "enabled": .bool(true)]
            let l = label.text.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { entry["label"] = .string(l) }
            host?.close()
            self?.writeHubPatch(env.id, .object([UsageHubLogic.sourceId(u): .object(entry)]))
        }
        DispatchQueue.main.async { window.makeFirstResponder(url) }
    }

    // MARK: Writes

    /// `server.updateSettings` with a `providerInstanceMutation` (usePersistEnvironmentProviderInstanceMutation).
    private func mutate(_ env: String, _ mutation: JSONValue, patch: [String: JSONValue] = [:], failure: String) {
        guard let request = context.request else { return }
        Task { [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", .object(["patch": .object(patch), "providerInstanceMutation": mutation]))
                self?.context.applySettings?(env, result)
            } catch {
                self?.context.toast?(failure, "\(error)", .error)
            }
        }
    }

    private func upsert(_ row: ProvidersLogic.Row, _ next: JSONValue, env: String, patch: [String: JSONValue] = [:]) {
        mutate(env, .object(["operation": .string("upsert"), "instanceId": .string(row.instanceId), "instance": next]), patch: patch,
               failure: "Could not update provider instance")
    }

    /// `onUpdate` with `enabled`: disabling the text generation instance resets that model to the default.
    private func setEnabled(_ row: ProvidersLogic.Row, _ on: Bool, env: String) {
        var o = row.instance.objectValue ?? [:]
        o["enabled"] = .bool(on)
        var patch: [String: JSONValue] = [:]
        let settings = environment?.settings
        if !on, row.enabled, settings?["textGenerationModelSelection"]["instanceId"]?.stringValue == row.instanceId {
            patch["textGenerationModelSelection"] = ServerSettingsValues.fields["textGenerationModelSelection"]!.defaultValue
        }
        upsert(row, .object(o), env: env, patch: patch)
    }

    private func refreshProviders() {
        guard let env = environment?.id, let request = context.request, !refreshing else { return }
        refreshing = true
        refresh()
        Task { [weak self] in
            _ = try? await request(env, "server.refreshProviders", .object(["refreshModels": .bool(true)]))
            self?.refreshing = false
            self?.refresh()
        }
    }

    private func buildHealth() -> SettingsRowView {
        health.step = 30
        health.range = 0 ... .infinity
        health.frame.size = NSSize(width: 128, height: 28)
        health.setAccessibilityLabel("Provider health check interval in seconds")
        let unit = LabelView("seconds", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        unit.lineHeight = 16
        unit.frame.size = NSSize(width: ceil(unit.textWidth) + 1, height: 16)
        let r = row("provider-health-check-interval", detail: "Refresh provider status, versions, and models in the background. Set to 0 to disable.",
                    control: SettingsControlGroup([health, unit]))
        let info = ButtonView(nil, icon: .info, variant: .ghostMuted, size: .iconMicro)
        info.iconSize = 14
        info.setAccessibilityLabel("Background policy details")
        _ = TooltipController.attach(to: info, text: "This interval is configured here, then the shared Background activity policy decides whether provider probes may run when the timer fires. Custom intervals appear as Advanced in General settings.", delay: 0.2)
        let reset = ResetSlot(label: "provider health check interval")
        r.accessories = [info, reset]
        health.onChange = { [weak self] value in self?.writeHealth(.number(BackgroundActivity.normalizeIntervalSeconds(value) * 1000)) }
        reset.action = { [weak self] in self?.writeHealth(nil) }
        return r
    }

    /// The interval goes to the page's environment only (`useUpdateEnvironmentSettings`).
    private func writeHealth(_ ms: JSONValue?) {
        guard let env = environment, let settings = env.settings, let request = context.request else { return }
        var ba = BackgroundActivity.overrideSettings(settings, ms.map { ["providerHealthRefreshInterval": $0] } ?? [:])
        if ms == nil, case .object(var o) = ba, case .object(var overrides)? = o["overrides"] {
            overrides.removeValue(forKey: "providerHealthRefreshInterval")
            o["overrides"] = .object(overrides)
            ba = .object(o)
        }
        Task { [weak self] in
            do {
                let result = try await request(env.id, "server.updateSettings", .object(["patch": .object(["backgroundActivity": ba])]))
                self?.context.applySettings?(env.id, result)
            } catch {
                self?.context.toast?("Setting not saved", "\(error)", .error)
            }
        }
    }

    // MARK: Editor

    private func editor(_ row: ProvidersLogic.Row, provider: ServerProvider?, env: SettingsScopeEnvironment) -> ProviderEditorView {
        let displayName = row.instance["displayName"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? ProvidersLogic.label(row.driver) ?? row.driver
        let e = ProviderEditorView()
        let readOnly = !env.canWrite
        // Writes start from the instance as the server has it now: the editor can outlive an echo while a field has focus.
        let current: @MainActor () -> JSONValue = { [weak self] in self?.liveInstance(row.instanceId) ?? row.instance }
        // Header: title, icon, version, reset (dirty default) or delete (other instances).
        let header = SettingsSectionView(title: displayName, rows: [])
        header.icon = ProviderIcon.make(driver: row.driver, displayName: displayName, size: 16, color: Themed.color(\.foreground, 0.8))
        var actions: [NSView] = []
        if let v = ProvidersLogic.versionLabel(provider?.version) {
            let code = LabelView(v, font: DSFont.mono(12), color: Themed.color(\.mutedForeground))
            code.lineHeight = 16
            code.frame.size = NSSize(width: ceil(code.textWidth) + 1, height: 16)
            actions.append(code)
        }
        if let advisory = advisoryButton(row, provider: provider, readOnly: readOnly, displayName: displayName) { actions.append(advisory) }
        if row.isDefault && row.isDirty {
            let reset = ResetSlot(label: "\(ProvidersLogic.label(row.driver) ?? row.driver) provider settings")
            reset.isShown = !readOnly
            reset.frame.size = NSSize(width: 20, height: 20)
            reset.action = { [weak self] in
                self?.mutate(env.id, .object(["operation": .string("remove"), "instanceId": .string(row.instanceId)]), failure: "Could not reset provider instance")
            }
            actions.append(reset)
        } else if !row.isDefault {
            let delete = ButtonView(nil, icon: .trash2, variant: .ghostDestructive, size: .iconXs)
            delete.setAccessibilityLabel("Delete instance \(row.instanceId)")
            delete.isEnabled = !readOnly
            delete.action = { [weak self] in
                self?.mutate(env.id, .object(["operation": .string("remove"), "instanceId": .string(row.instanceId)]), failure: "Could not delete provider instance")
            }
            actions.append(delete)
        }
        let signIn = ButtonView("Sign in", variant: .outline, size: .xs)
        signIn.isEnabled = !readOnly && row.enabled && provider?.installed == true
        signIn.action = { [weak self] in
            guard let self else { return }
            let terminal = ComposerProviderAuthTerminal(context: self.context, environment: env.id, instance: row.instanceId)
            let dialog = DialogView(title: "Sign in to " + displayName)
            dialog.maxWidth = 680
            dialog.panelContent = [terminal]
            if let host = self.context.presentDialog?(dialog) {
                let previous = host.onDismiss
                host.onDismiss = { [weak dialog, weak terminal] in previous?(); terminal?.close(); dialog?.panelContent = [] }
            }
        }
        actions.append(signIn)
        header.headerAction = actions.isEmpty ? nil : SettingsControlGroup(actions, gap: 6)
        let name = InputView(placeholder: ProvidersLogic.label(row.driver) ?? "Instance label", text: row.instance["displayName"]?.stringValue ?? "", size: .sm)
        name.frame.size = NSSize(width: 224, height: 28)
        name.setAccessibilityLabel("Display name")
        name.isEnabled = !readOnly
        name.onCommit = { [weak self] text in
            var o = current().objectValue ?? [:]
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t != (o["displayName"]?.stringValue ?? "") else { return }
            if t.isEmpty { o.removeValue(forKey: "displayName") } else { o["displayName"] = .string(t) }
            self?.upsert(row, .object(o), env: env.id)
        }
        // `ProviderAccentColorPicker layout="inline"` before the name, committing 120 ms after the last change.
        let accent = ProviderAccentColorButton(displayName: displayName, color: row.instance["accentColor"]?.stringValue) { [weak self] color in
            var o = current().objectValue ?? [:]
            guard color != ProviderEnvironmentLogic.accentColor(o["accentColor"]?.stringValue) else { return }
            if let color { o["accentColor"] = .string(color) } else { o.removeValue(forKey: "accentColor") }
            self?.upsert(row, .object(o), env: env.id)
        }
        accent.isEnabled = !readOnly
        let nameControl = SettingsControlGroup([accent, name], gap: 8)
        nameControl.frame.size = NSSize(width: 28 + 8 + 224, height: 28)
        let nameRow = SettingsRowView(title: "Display name", control: nameControl)
        nameRow.status = statusLine(row, provider)
        header.group.rows = [nameRow]
        var sections: [NSView & SettingsGroupRow] = [header]

        if row.driver == "codex" {
            let addAccount = ButtonView("Add ChatGPT account", variant: .outline, size: .sm)
            addAccount.isEnabled = !readOnly
            addAccount.action = { [weak self] in
                guard let self, let window = self.window else { return }
                let dialog = ProviderCodexAccountDialog(context: self.context, environment: env.id)
                let host = ModalHost.present(dialog, in: window)
                dialog.close = { [weak host] in host?.close() }
                dialog.onCreated = { [weak self] id in self?.selected = id; self?.refresh() }
            }
            sections.append(SettingsSectionView(title: "ChatGPT", rows: [SettingsRowView(title: "Accounts", control: addAccount)]))
            if row.instance["config"]?["setupMode"]?.stringValue == "managed" {
                let runtime = ProviderCodexRuntimeView(context: context, environment: env.id, instance: row.instanceId, readOnly: readOnly)
                runtime.onHeightChange = { [weak self] in self?.onHeightChange?() }
                sections.append(SettingsSectionView(title: "Runtime", rows: [runtime]))
            }
        }
        if provider?.setup?["canAuthenticate"]?.boolValue == true || row.driver == "acpRegistry" {
            let auth = ProviderAuthenticationView(context: context, environment: env.id, label: env.label,
                instance: row.instanceId, provider: provider, readOnly: readOnly)
            auth.onHeightChange = { [weak self] in self?.onHeightChange?() }
            sections.append(SettingsSectionView(title: "Setup", rows: [auth]))
        }

        if row.driver == "acpRegistry", let provider, provider.nativeSessions?["canList"]?.boolValue == true {
            let sessions = ProviderAcpSessionsView(context: context, environment: env.id, instance: row.instanceId, provider: provider, readOnly: readOnly)
            sessions.onHeightChange = { [weak self] in self?.onHeightChange?() }
            sections.append(SettingsSectionView(title: "Sessions", rows: [sessions]))
        }

        // Setup: drivers with a dedicated variable field (Cursor's API key).
        let envFields = ProviderEnvironmentLogic.fields(row.driver)
        let variables = ProviderEnvironmentLogic.variables(row.instance)
        if !envFields.isEmpty {
            sections.append(SettingsSectionView(title: "Setup", rows: envFields.map { f in
                let control = ProviderEnvironmentFieldControl(field: f, variable: variables.first { $0.name == f.name }, enabled: !readOnly,
                    commit: { [weak self] value in
                        self?.upsert(row, ProviderEnvironmentLogic.instance(current(), environment: ProviderEnvironmentLogic.setting(ProviderEnvironmentLogic.variables(current()), field: f, to: value)), env: env.id)
                    },
                    remove: { [weak self] in
                        self?.upsert(row, ProviderEnvironmentLogic.instance(current(), environment: ProviderEnvironmentLogic.variables(current()).filter { $0.name != f.name }), env: env.id)
                    })
                return SettingsRowView(title: f.label, detail: f.detail, control: control)
            }))
        }

        let fields = ProvidersLogic.fields(row.driver, config: row.instance["config"])
        if !fields.isEmpty {
            let rows: [any SettingsGroupRow] = fields.map { f in
                let saved = row.instance["config"]?[f.key]?.stringValue ?? f.defaultValue
                let control: NSView
                if !f.options.isEmpty {
                    let select = settingsSelect(f.options.map { $0.1 }, width: 224)
                    select.selectedIndex = f.options.firstIndex { $0.0 == saved }
                    select.isEnabled = !readOnly
                    select.setAccessibilityLabel(f.title)
                    select.onChange = { [weak self] index in
                        self?.upsert(row, ProvidersLogic.config(current(), set: f.key, to: f.options[index].0), env: env.id)
                    }
                    control = select
                } else if f.secret {
                    let input = SecureInputView(placeholder: f.placeholder)
                    input.text = saved
                    input.frame.size = NSSize(width: 224, height: 32)
                    input.isEnabled = !readOnly
                    input.onSubmit = { [weak self, weak input] in
                        guard let input else { return }
                        self?.upsert(row, ProvidersLogic.config(current(), set: f.key, to: input.text), env: env.id)
                    }
                    control = input
                } else {
                    let input = InputView(placeholder: f.placeholder, text: saved, size: .sm)
                    input.frame.size = NSSize(width: 224, height: 28)
                    input.isEnabled = !readOnly
                    input.setAccessibilityLabel(f.title)
                    input.onCommit = { [weak self] text in
                        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != saved else { return }
                        self?.upsert(row, ProvidersLogic.config(current(), set: f.key, to: text), env: env.id)
                    }
                    control = input
                }
                return SettingsRowView(title: f.title, detail: f.detail, control: control)
            }
            sections.append(SettingsSectionView(title: "Runtime", rows: rows))
        }

        if row.driver == "acpRegistry", row.instance["config"]?["source"]?.stringValue == "local" {
            let args = SettingsProviderArgumentsView((row.instance["config"]?["commandArgs"]?.arrayValue ?? []).compactMap(\.stringValue), enabled: !readOnly) { [weak self] values in
                var instance = current().objectValue ?? [:]
                var config = instance["config"]?.objectValue ?? [:]
                config["commandArgs"] = .array(values.map(JSONValue.string)); instance["config"] = .object(config)
                self?.upsert(row, .object(instance), env: env.id)
            }
            args.onHeightChange = { [weak self] in self?.onHeightChange?() }
            sections.append(SettingsSectionView(title: "Command", rows: [args]))
        }

        // Environment: the generic variables, without the ones a Setup field owns.
        let owned = Set(envFields.map(\.name))
        let generic = variables.filter { !owned.contains($0.name) }
        let list = ProviderEnvironmentVariablesView(rows: envDrafts(row.instanceId, generic), enabled: !readOnly)
        list.onRowsChange = { [weak self] rows in
            guard let self else { return }
            self.environmentDrafts[row.instanceId] = (generic, rows)
            guard let published = ProviderEnvironmentLogic.publish(rows) else { return }
            self.environmentDrafts[row.instanceId] = (published, rows)
            let dedicated = ProviderEnvironmentLogic.variables(current()).filter { owned.contains($0.name) }
            self.upsert(row, ProviderEnvironmentLogic.instance(current(), environment: dedicated + published), env: env.id)
        }
        let addVariable = ButtonView("Add variable", icon: .plus, variant: .outline, size: .sm)
        addVariable.iconSize = 12
        addVariable.isEnabled = !readOnly
        addVariable.frame.size = addVariable.intrinsicContentSize
        addVariable.action = { [weak self] in
            guard let self else { return }
            self.environmentDraftId += 1
            self.environmentDrafts[row.instanceId] = (generic, list.rows + [ProviderEnvironmentLogic.Draft(id: self.environmentDraftId)])
            self.refresh()
            self.onHeightChange?()
        }
        let variablesRow = SettingsRowView(title: "Variables", detail: "API keys, base URLs, and other per-instance CLI settings.", control: SettingsControlGroup([addVariable]))
        variablesRow.footer = list.rows.isEmpty ? nil : list
        sections.append(SettingsSectionView(title: "Environment", rows: [variablesRow]))

        // Models: favorites, visibility and order on this device; custom models on the environment.
        let prefs = context.client["providerModelPreferences"][row.instanceId]
        let hidden = (prefs?["hiddenModels"]?.arrayValue ?? []).compactMap(\.stringValue)
        let order = (prefs?["modelOrder"]?.arrayValue ?? []).compactMap(\.stringValue)
        let favorites = Set(context.favorites.filter { $0.provider.rawValue == row.instanceId }.map(\.model))
        let custom = ProvidersLogic.customModels(row.instance)
        let models = ProvidersLogic.displayModels(live: provider?.models ?? [], custom: custom, favorites: favorites, hidden: Set(hidden), order: order)
        let modelsView = ProviderModelsView(models: models, favorites: favorites, hidden: Set(hidden), driver: row.driver, canManage: !readOnly)
        modelsView.builtinModels = provider?.models ?? []
        modelsView.addOpen = expandedModelAdd.contains(row.instanceId)
        modelsView.onAddOpen = { [weak self] open in
            if open { self?.expandedModelAdd.insert(row.instanceId) } else { self?.expandedModelAdd.remove(row.instanceId) }
            self?.onHeightChange?()
        }
        modelsView.onFavorite = { [weak self] slug in self?.context.toggleFavorite?(ProviderInstanceId(rawValue: row.instanceId), slug); self?.refresh() }
        modelsView.onHidden = { [weak self] next in self?.writePreferences(row.instanceId, hidden: next, order: order) }
        modelsView.onOrder = { [weak self] next in self?.writePreferences(row.instanceId, hidden: hidden, order: next) }
        modelsView.onAdd = { [weak self] slug in
            var o = current().objectValue ?? [:]
            var config = o["config"]?.objectValue ?? [:]
            config["customModels"] = .array(custom.map(\.raw) + [.string(slug)])
            o["config"] = .object(config)
            self?.expandedModelAdd.remove(row.instanceId)
            self?.upsert(row, .object(o), env: env.id)
        }
        modelsView.customDefinitions = Dictionary(uniqueKeysWithValues: custom.map { ($0.slug, $0.raw) })
        modelsView.onEdit = { [weak self] definition in
            var o = row.instance.objectValue ?? [:]
            var config = o["config"]?.objectValue ?? [:]
            config["customModels"] = .array(custom.map { $0.slug == definition["slug"]?.stringValue ? definition : $0.raw })
            o["config"] = .object(config)
            self?.upsert(row, .object(o), env: env.id)
        }
        modelsView.onRemove = { [weak self] slug in
            var o = current().objectValue ?? [:]
            var config = o["config"]?.objectValue ?? [:]
            config["customModels"] = .array(custom.filter { $0.slug != slug }.map(\.raw))
            o["config"] = .object(config)
            self?.upsert(row, .object(o), env: env.id)
            self?.writePreferences(row.instanceId, hidden: hidden, order: order.filter { $0 != slug })
        }
        modelsView.onHeightChange = { [weak self] in self?.onHeightChange?() }
        sections.append(SettingsSectionView(title: "Models", rows: [modelsView]))
        e.sections = sections
        return e
    }

    private func liveInstance(_ id: String) -> JSONValue? {
        guard let env = environment, let settings = env.settings else { return nil }
        return ProvidersLogic.rows(settings: settings, providers: context.configs[env.id]?.providers ?? []).first { $0.instanceId == id }?.instance
    }

    /// The version advisory button, or nil when the provider is current. `Update now` runs `server.updateProvider`;
    /// `Install vX` passes the compatibility advisory's recommended version.
    private func advisoryButton(_ row: ProvidersLogic.Row, provider p: ServerProvider?, readOnly: Bool, displayName: String, micro: Bool = false) -> ButtonView? {
        guard let p, let presentation = ProviderVersionAdvisoryLogic.presentation(p, enabled: row.enabled) else { return nil }
        let updating = updatingInstances.contains(row.instanceId) || ProviderVersionAdvisoryLogic.isUpdating(p)
        let progress = updating ? ((ProviderVersionAdvisoryLogic.isUpdating(p) ? p.updateState?.message : nil) ?? "Starting update") : nil
        let problem = !updating && (p.updateState?.status == "failed" || p.updateState?.status == "unchanged") ? p.updateState?.message : nil
        var run: (@MainActor () -> Void)?
        if !readOnly, let env = environment?.id {
            if presentation.targetVersion != nil {
                if ProviderVersionAdvisoryLogic.canInstallRecommended(p) { run = { [weak self] in self?.runUpdate(env, p, target: presentation.targetVersion) } }
            } else if ProviderVersionAdvisoryLogic.canUpdate(p) {
                run = { [weak self] in if !updating { self?.runUpdate(env, p, target: nil) } }
            }
        }
        let b = providerVersionAdvisoryButton(presentation, updating: updating, progress: progress, problem: problem, run: run, micro: micro) { [weak self] command in
            self?.context.copy?(command, "\(displayName) update command copied")
        }
        b.frame.size = micro ? NSSize(width: 20, height: 20) : NSSize(width: 24, height: 24)
        return b
    }

    private func runUpdate(_ env: String, _ p: ServerProvider, target: String?) {
        guard let request = context.request, !updatingInstances.contains(p.instanceId.rawValue) else { return }
        updatingInstances.insert(p.instanceId.rawValue)
        refresh()
        var input: [String: JSONValue] = ["provider": .string(p.driver), "instanceId": .string(p.instanceId.rawValue)]
        if let target { input["targetVersion"] = .string(target) }
        Task { [weak self] in
            do {
                _ = try await request(env, "server.updateProvider", .object(input))
            } catch {
                self?.context.toast?("Could not update \(ProvidersLogic.label(p.driver) ?? p.driver)", "\(error)", .error)
            }
            self?.updatingInstances.remove(p.instanceId.rawValue)
            self?.refresh()
        }
    }

    /// The rows to show: the page's drafts while what they last published still matches the server (T3 keeps
    /// its draft rows until the environment changes from elsewhere), else fresh rows from the server.
    private func envDrafts(_ instanceId: String, _ server: [ProviderEnvironmentLogic.Variable]) -> [ProviderEnvironmentLogic.Draft] {
        if let held = environmentDrafts[instanceId], held.published == server { return held.rows }
        let rows = server.map { v -> ProviderEnvironmentLogic.Draft in environmentDraftId += 1; return .init(id: environmentDraftId, v) }
        environmentDrafts[instanceId] = (server, rows)
        return rows
    }

    /// `providerModelPreferences[instanceId]`, dropped when both lists are empty.
    private func writePreferences(_ instanceId: String, hidden: [String], order: [String]) {
        var all = context.client["providerModelPreferences"].objectValue ?? [:]
        func unique(_ a: [String]) -> [String] { var s = Set<String>(); return a.filter { !$0.isEmpty && s.insert($0).inserted } }
        let h = unique(hidden), o = unique(order)
        if h.isEmpty && o.isEmpty { all.removeValue(forKey: instanceId) } else {
            all[instanceId] = .object(["hiddenModels": .array(h.map(JSONValue.string)), "modelOrder": .array(o.map(JSONValue.string))])
        }
        context.writeClient?(["providerModelPreferences": .object(all)])
    }

    /// The editor's status line: "Authenticated as <email> · <label>", else the summary headline and detail.
    private func statusLine(_ row: ProvidersLogic.Row, _ p: ServerProvider?) -> String {
        guard row.enabled else { return "Disabled" }
        let summary = ProvidersLogic.summary(p)
        if p?.auth?["status"]?.stringValue == "authenticated", let email = p?.auth?["email"]?.stringValue, !email.isEmpty {
            let label = p?.auth?["label"]?.stringValue ?? p?.auth?["type"]?.stringValue
            // ponytail: the email stays masked; T3 reveals it on click (RedactedSensitiveText). Add the toggle if users ask for it
            return "Authenticated as \(String(repeating: "•", count: 8))" + (label.map { " · \($0)" } ?? "")
                + (summary.detail.map { " · \($0)" } ?? "")
        }
        return summary.headline + (summary.detail.map { " · \($0)" } ?? "")
    }
}

extension NSView {
    /// Whether the window's first responder is this view or inside it (a focused field).
    var isFirstResponderInside: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}

/// The Providers section: its header (title, the add button, "Checked …" refresh) over the card that holds
/// the instance list (`17rem`, `bg-muted/10`, `border-r`) beside the editor.
final class ProvidersSectionView: DSView, SettingsGroupRow {
    private let title = LabelView("Providers", font: DSFont.ui(14), color: Themed.color(\.contrastForeground, 0.7))
    let add = ButtonView(nil, icon: .plus, variant: .ghostMuted, size: .iconXs)
    let refresh = ButtonView("", icon: .refreshCw, variant: .ghostMuted, size: .xs)
    private let card = BoxView()
    private let listFill = CALayer()
    private let divider = CALayer()
    let addRow = SidebarStyleAddRow()
    var list: [ProviderListRow] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; list.forEach(card.addSubview); needsLayout = true } }
    var editor: ProviderEditorView? { didSet { oldValue?.removeFromSuperview(); editor.map(card.addSubview); needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineHeight = 20
        addSubview(title)
        add.iconSize = 14
        add.setAccessibilityLabel("Add provider")
        add.isEnabled = false
        _ = TooltipController.attach(to: add, text: "Add provider")
        addSubview(add)
        refresh.iconSize = 14
        refresh.setAccessibilityLabel("Refresh provider status")
        _ = TooltipController.attach(to: refresh, text: "Refresh provider status")
        addSubview(refresh)
        var style = BoxStyle()
        style.radius = 14
        style.border = Themed.color(\.contrastBorder, 0.6)
        style.fill = Themed.color(\.card, 0.4)
        style.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        card.boxStyle = style
        card.layer?.masksToBounds = true
        addSubview(card)
        card.layer?.addSublayer(listFill)
        card.layer?.addSublayer(divider)
        addRow.isEnabled = false
        card.addSubview(addRow)
    }

    func setChecked(_ text: String?) { refresh.title = text ?? ""; needsLayout = true }

    private var twoColumns: Bool { bounds.width >= 768 }

    private func listHeight() -> CGFloat { list.reduce(0) { $0 + $1.height(forWidth: 272) + 1 } + 44 }

    func height(forWidth width: CGFloat) -> CGFloat {
        let editorWidth = width >= 768 ? width - 272 - 2 : width - 2
        let editorHeight = (editor?.height(forWidth: editorWidth) ?? 60)
        let cardHeight = width >= 768 ? max(512, listHeight(), editorHeight) : listHeight() + 1 + editorHeight
        return 28 + 10 + cardHeight + 2
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 16, y: 4, width: ceil(title.textWidth) + 1, height: 20)
        add.frame = NSRect(x: title.frame.maxX + 4, y: 2, width: 24, height: 24)
        let rs = refresh.intrinsicContentSize
        refresh.frame = NSRect(x: w - 16 - rs.width, y: (28 - rs.height) / 2, width: rs.width, height: rs.height)
        card.frame = NSRect(x: 0, y: 38, width: w, height: bounds.height - 38)
        // Not `insetBy`: on a card smaller than 2pt it returns `.null`, whose infinite origin crashed
        // CALayer when the page laid out before it had a size (opening Providers from a link).
        let inner = CGRect(x: 1, y: 1, width: max(0, card.bounds.width - 2), height: max(0, card.bounds.height - 2))
        var y = inner.minY
        let listWidth = twoColumns ? 272 : inner.width
        for row in list {
            let h = row.height(forWidth: listWidth)
            row.frame = NSRect(x: inner.minX, y: y, width: listWidth, height: h)
            y += h + 1
        }
        addRow.frame = NSRect(x: inner.minX, y: y, width: listWidth, height: 44)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if twoColumns {
            listFill.frame = CGRect(x: inner.minX, y: inner.minY, width: 272, height: inner.height)
            divider.frame = CGRect(x: inner.minX + 272, y: inner.minY, width: 1, height: inner.height)
            editor?.frame = NSRect(x: inner.minX + 273, y: inner.minY, width: inner.width - 273, height: inner.height)
        } else {
            listFill.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: y + 44 - inner.minY)
            divider.frame = CGRect(x: inner.minX, y: y + 44, width: inner.width, height: 1)
            editor?.frame = NSRect(x: inner.minX, y: y + 45, width: inner.width, height: inner.maxY - y - 45)
        }
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        listFill.backgroundColor = Themed.color(\.muted, 0.1).cgColor(in: self)
        divider.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }

    /// The list's last row: "+ Add provider" (`px-4 py-3 text-sm text-muted-foreground`).
    final class SidebarStyleAddRow: ControlView {
        private let icon = IconView(name: .plus, size: 16)
        private let label = LabelView("Add provider", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            transitions = .colors // transition-colors hover:bg-muted/25 hover:text-foreground (ProviderSettingsPanel.tsx:1196)
            label.lineHeight = 20
            addSubview(icon)
            addSubview(label)
            restyle()
        }
        override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
        override func updateLayer() { restyle() }
        private func restyle() {
            let hot = state.hovered || state.focusVisible
            label.color = Themed.color(hot ? \.foreground : \.mutedForeground)
            icon.strokeColor = label.color
            Motion.setBackground(layer, hot ? Themed.color(\.muted, 0.25).cgColor(in: self) : nil)
        }
        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
            label.frame = NSRect(x: 44, y: (bounds.height - 20) / 2, width: bounds.width - 60, height: 20)
        }
    }
}

/// One instance in the list (ProviderInstanceCard.tsx `mode === "list"`): icon, name, version, status line, switch.
final class ProviderListRow: ControlView {
    let toggle = SwitchView(isOn: false)
    private let icon: NSView
    private let name = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let version = LabelView("", font: DSFont.mono(12), color: Themed.color(\.mutedForeground))
    private let status = TextBlockView()
    private let dot = CALayer()
    private let fill = CALayer()
    private let showsDot: Bool
    private let enabled: Bool
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { Motion.transitioning(window == nil ? [] : transitions) { restyle() } } }
    /// The version advisory button (`icon-micro`) after the version, and the update progress in place of the status.
    var advisory: ButtonView? { didSet { oldValue?.removeFromSuperview(); advisory.map(addSubview); needsLayout = true } }
    var updateProgress: String? { didSet { if let updateProgress { status.text = "Updating · \(updateProgress)"; dot.isHidden = true } } }

    init(row: ProvidersLogic.Row, provider: ServerProvider?) {
        let displayName = row.instance["displayName"]?.stringValue ?? ProvidersLogic.label(row.driver) ?? row.driver
        icon = ProviderIcon.make(driver: row.driver, displayName: displayName, size: 16, color: Themed.color(\.foreground, 0.8))
        enabled = row.enabled
        let key = row.enabled ? provider?.status.rawValue ?? "warning" : "disabled"
        showsDot = key == "warning" || key == "error"
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = [.background] // transition-colors on the row (ProviderInstanceCard.tsx:914)
        layer?.addSublayer(fill)
        name.text = displayName
        name.lineHeight = 20
        version.text = ProvidersLogic.versionLabel(provider?.version) ?? ""
        version.lineHeight = 16
        let summary: (headline: String, detail: String?) = row.enabled ? ProvidersLogic.summary(provider) : ("Disabled", nil)
        status.text = summary.headline + (showsDot ? summary.detail.map { " · \($0)" } ?? "" : "")
        status.font = DSFont.ui(12)
        status.lineHeight = 18
        status.maxLines = 2
        status.color = Themed.color(\.mutedForeground, 0.8)
        dot.cornerRadius = 3
        dot.backgroundColor = (key == "error" ? Themed.color(\.destructive) : Themed.color(\.warning)).cgColor
        dot.isHidden = !showsDot
        layer?.addSublayer(dot)
        for v in [icon, name, version, status, toggle] as [NSView] { addSubview(v) }
        toggle.isOn = row.enabled
        toggle.setAccessibilityLabel("Enable \(displayName)")
        action = { [weak self] in self?.onSelect?() }
        setAccessibilityLabel("Select \(displayName)")
        restyle()
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }

    /// `min-h-18 py-3`: the name line, `mt-0.5`, and up to two status lines.
    func height(forWidth width: CGFloat) -> CGFloat {
        let right = width - 16 - toggle.intrinsicContentSize.width - 12
        let sx: CGFloat = 16 + 20 + 12 + (showsDot ? 12 : 0)
        return max(72, 12 + 20 + 2 + status.height(forWidth: max(0, right - sx)) + 12)
    }

    private func restyle() {
        Motion.setBackground(fill, isSelected ? Themed.color(\.muted, 0.45).cgColor(in: self) : state.hoverOrPressed ? Themed.color(\.muted, 0.25).cgColor(in: self) : nil)
        let dim: CGFloat = !enabled && !isSelected && !state.hoverOrPressed ? 0.6 : 1
        // `opacity-60 transition-opacity group-hover:opacity-100` (ProviderInstanceCard.tsx:918-922).
        for v in [icon, name, version, status] as [NSView] { HoverReveal.fade(v, to: dim) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        let s = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: bounds.width - 16 - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        let textX: CGFloat = 16 + 20 + 12
        let right = toggle.frame.minX - 12
        icon.frame = NSRect(x: 16 + 2, y: 12 + 2, width: 16, height: 16)
        let nw = min(ceil(name.textWidth) + 1, max(0, right - textX))
        name.frame = NSRect(x: textX, y: 12, width: nw, height: 20)
        let vw = min(96, ceil(version.textWidth) + 1)
        version.frame = NSRect(x: textX + nw + 8, y: 14, width: max(0, min(vw, right - textX - nw - 8)), height: 16)
        advisory?.frame = NSRect(x: version.text.isEmpty ? textX + nw + 8 : version.frame.maxX + 8, y: 12, width: 20, height: 20)
        var sx = textX
        if showsDot && !dot.isHidden {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: sx, y: 34 + 6, width: 6, height: 6)
            CATransaction.commit()
            sx += 6 + 6
        }
        status.frame = NSRect(x: sx, y: 12 + 20 + 2, width: max(0, right - sx), height: status.height(forWidth: max(0, right - sx)))
    }

    override func mouseDown(with event: NSEvent) {
        if toggle.frame.contains(convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }
}

/// The editor column (`space-y-6 p-4`).
final class ProviderEditorView: DSView {
    var sections: [NSView & SettingsGroupRow] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; sections.forEach(addSubview); needsLayout = true } }
    func height(forWidth width: CGFloat) -> CGFloat {
        sections.reduce(0) { $0 + $1.height(forWidth: width - 32) } + 24 * CGFloat(max(0, sections.count - 1)) + 32
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 16
        for s in sections {
            let h = s.height(forWidth: bounds.width - 32)
            s.frame = NSRect(x: 16, y: y, width: bounds.width - 32, height: h)
            y += h + 24
        }
    }
}

/// `ProviderModelsSection` inside the Models card (`px-4 py-3`): the note, the toolbar (filter, Disable all, count,
/// Add custom model), the grouped list, and the add form.
final class ProviderModelsView: DSView, SettingsGroupRow {
    private let note = TextBlockView()
    private let filter = InputView(placeholder: "Filter models", text: "", size: .sm)
    private let bulk = ButtonView("Disable all", variant: .ghostMuted, size: .xs)
    private let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let addButton = ButtonView("Add custom model", icon: .plus, variant: .ghostMuted, size: .xs)
    private let addInput = InputView(placeholder: "model-slug", text: "", size: .sm)
    private let addConfirm = ButtonView("Add", variant: .outline, size: .sm)
    private let addCancel = ButtonView("Cancel", variant: .ghost, size: .sm)
    private let errorText = LabelView("", font: DSFont.ui(12), color: Themed.color(\.destructive))
    private var rows: [NSView] = []
    var builtinModels: [ServerProviderModel] = []
    private let driver: String
    private let models: [ProvidersLogic.DisplayModel]
    private let favorites: Set<String>
    private let hiddenSlugs: Set<String>
    private let canManage: Bool
    var onFavorite: ((String) -> Void)?
    var onHidden: (([String]) -> Void)?
    var onOrder: (([String]) -> Void)?
    var onAdd: ((String) -> Void)?
    var onEdit: ((JSONValue) -> Void)?
    var customDefinitions: [String: JSONValue] = [:]
    private var editedSlug: String?
    var onRemove: ((String) -> Void)?
    var onAddOpen: ((Bool) -> Void)?
    var onHeightChange: (() -> Void)?
    var addOpen = false { didSet { syncAdd() } }
    private var error: String? { didSet { errorText.text = error ?? ""; errorText.isHidden = error == nil; onHeightChange?() } }

    static let placeholders = ["codex": "gpt-6.7-codex-ultra-preview", "claudeAgent": "claude-sonnet-5", "cursor": "claude-sonnet-4-6",
                               "opencode": "openai/gpt-5", "pi": "anthropic/claude-sonnet-5"]

    init(models: [ProvidersLogic.DisplayModel], favorites: Set<String>, hidden: Set<String>, driver: String, canManage: Bool) {
        self.driver = driver
        self.models = models
        self.favorites = favorites
        self.hiddenSlugs = hidden
        self.canManage = canManage && driver != "antigravity"
        super.init(frame: .zero)
        note.text = "Favorites, visibility, and ordering are saved on this device. Custom models are saved on the selected environment."
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        note.color = Themed.color(\.mutedForeground)
        addSubview(note)
        filter.frame.size = NSSize(width: 224, height: 28)
        filter.setAccessibilityLabel("Filter models")
        filter.isHidden = models.count <= 8
        filter.onChange = { [weak self] _ in self?.rebuild(); self?.onHeightChange?() }
        addSubview(filter)
        let builtIn = models.filter { !$0.isCustom }
        bulk.title = !builtIn.isEmpty && builtIn.allSatisfy { hidden.contains($0.slug) } ? "Enable all" : "Disable all"
        bulk.isHidden = builtIn.isEmpty
        bulk.action = { [weak self] in
            guard let self else { return }
            self.onHidden?(ProvidersLogic.bulkToggle(self.models, hidden: Array(self.hiddenSlugs)))
        }
        addSubview(bulk)
        let fav = models.filter { favorites.contains($0.slug) }.count
        let hid = models.filter { !$0.isCustom && hidden.contains($0.slug) }.count
        count.text = "\(models.count) model\(models.count == 1 ? "" : "s")" + (fav > 0 ? " · \(fav) favorite\(fav == 1 ? "" : "s")" : "") + (hid > 0 ? " · \(hid) hidden" : "")
        count.lineHeight = 16
        addSubview(count)
        addButton.iconSize = 12
        addButton.isHidden = !self.canManage
        addButton.action = { [weak self] in self?.onAddOpen?(true); self?.addOpen = true }
        addSubview(addButton)
        addInput.placeholder = Self.placeholders[driver] ?? "model-slug"
        addInput.onChange = { [weak self] _ in if self?.error != nil { self?.error = nil } }
        addInput.onSubmit = { [weak self] in self?.submitAdd() }
        addInput.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.cancelAdd()
            return true
        }
        addConfirm.action = { [weak self] in self?.submitAdd() }
        addCancel.action = { [weak self] in self?.cancelAdd() }
        for v in [addInput, addConfirm, addCancel, errorText] as [NSView] { addSubview(v) }
        errorText.lineHeight = 16
        errorText.isHidden = true
        rebuild()
        syncAdd()
    }

    private func syncAdd() {
        for v in [addInput, addConfirm, addCancel] as [NSView] { v.isHidden = !addOpen || !canManage }
        addButton.isHidden = !canManage || addOpen
        needsLayout = true
        if addOpen { DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.addInput) } }
    }

    private func submitAdd() {
        let custom = models.filter(\.isCustom).map(\.slug)
        if let e = ProvidersLogic.customModelError(addInput.text, live: models, custom: custom) { error = e; return }
        let slug = addInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        addInput.text = ""
        error = nil
        addOpen = false
        onAdd?(slug)
    }

    private func cancelAdd() { addInput.text = ""; error = nil; addOpen = false; onAddOpen?(false) }

    private var filtering: Bool { !filter.isHidden && !filter.text.trimmingCharacters(in: .whitespaces).isEmpty }

    private func group(_ m: ProvidersLogic.DisplayModel) -> String {
        favorites.contains(m.slug) ? "favorite" : !m.isCustom && hiddenSlugs.contains(m.slug) ? "hidden" : "visible"
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        let q = filter.text.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = filtering ? models.filter { $0.name.lowercased().contains(q) || $0.slug.lowercased().contains(q) } : models
        if visible.isEmpty {
            let empty = LabelView(filtering ? "No models match." : "No models reported for this provider yet.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            empty.lineHeight = 16
            rows.append(empty)
        }
        let favoriteCount = models.filter { favorites.contains($0.slug) }.count
        for (i, m) in visible.enumerated() {
            let g = group(m)
            let starts = i == 0 || group(visible[i - 1]) != g
            if starts && ((favoriteCount > 0 && g == "favorite") || (favoriteCount > 0 && g == "visible") || g == "hidden") {
                let label = LabelView(g == "favorite" ? "Favorites" : g == "visible" ? "All" : "Hidden from picker", font: DSFont.ui(11),
                                      color: Themed.color(\.mutedForeground))
                label.lineHeight = 16
                label.identifier = NSUserInterfaceItemIdentifier(i == 0 ? "first-group" : "group")
                rows.append(label)
            }
            let index = models.firstIndex { $0.slug == m.slug }!
            let canUp = !filtering && index > 0 && group(models[index - 1]) == g
            let canDown = !filtering && index + 1 < models.count && group(models[index + 1]) == g
            let row = ModelRow(model: m, favorite: favorites.contains(m.slug), hidden: !m.isCustom && hiddenSlugs.contains(m.slug), canUp: canUp, canDown: canDown,
                               showMoves: !filtering && !(!m.isCustom && hiddenSlugs.contains(m.slug)), canManage: canManage)
            row.onFavorite = { [weak self] in self?.onFavorite?(m.slug) }
            row.onHidden = { [weak self] hide in
                guard let self else { return }
                var next = Array(self.hiddenSlugs)
                if hide { next.append(m.slug) } else { next.removeAll { $0 == m.slug } }
                self.onHidden?(next)
            }
            row.onMove = { [weak self] dir in
                guard let self else { return }
                var order = self.models.map(\.slug)
                order.swapAt(index, index + dir)
                self.onOrder?(order)
            }
            row.onRemove = { [weak self] in self?.onRemove?(m.slug) }
            row.onEdit = { [weak self] in self?.editedSlug = m.slug; self?.rebuild(); self?.onHeightChange?() }
            rows.append(row)
            if editedSlug == m.slug {
                let editor = ComposerCustomModelEditor(entry: customDefinitions[m.slug] ?? .string(m.slug), driver: driver, builtins: builtinModels)
                editor.onHeightChange = { [weak self] in self?.needsLayout = true; self?.onHeightChange?() }
                editor.onCancel = { [weak self] in self?.editedSlug = nil; self?.rebuild(); self?.onHeightChange?() }
                editor.onSave = { [weak self] definition in self?.editedSlug = nil; self?.onEdit?(definition) }
                rows.append(editor)
            }
        }
        rows.forEach(addSubview)
        needsLayout = true
    }

    private func layoutAll(width: CGFloat, place: Bool) -> CGFloat {
        var y: CGFloat = 12
        let nh = note.height(forWidth: width - 32)
        if place { note.frame = NSRect(x: 16, y: y, width: width - 32, height: nh) }
        y += nh + 12
        // Toolbar.
        if place {
            var x: CGFloat = 16
            if !filter.isHidden { filter.frame = NSRect(x: x, y: y, width: min(224, width - 32), height: 28); x += 224 + 8 }
            if !bulk.isHidden {
                let bw = bulk.intrinsicContentSize.width
                bulk.frame = NSRect(x: x, y: y + 2, width: bw, height: 24)
                x += bw + 8
            }
            count.frame = NSRect(x: x, y: y + 6, width: ceil(count.textWidth) + 1, height: 16)
            let aw = addButton.intrinsicContentSize.width
            addButton.frame = NSRect(x: width - 16 - aw, y: y + 2, width: aw, height: 24)
        }
        y += 28 + 8
        for r in rows {
            let isLabel = r is LabelView
            let top: CGFloat = isLabel ? (r.identifier?.rawValue == "first-group" ? 4 : 20) : 0
            let h: CGFloat = r is ComposerCustomModelEditor ? r.intrinsicContentSize.height + 12 : isLabel ? 16 + 6 : 28
            if place { r.frame = NSRect(x: 16 + (isLabel ? 8 : 0) - (isLabel ? 0 : 8), y: y + top, width: width - 32 + (isLabel ? -8 : 16), height: r is ComposerCustomModelEditor ? h - 12 : isLabel ? 16 : 28) }
            y += top + h
        }
        if addOpen && canManage {
            y += 12
            if place {
                let bw = addConfirm.intrinsicContentSize.width, cw = addCancel.intrinsicContentSize.width
                addCancel.frame = NSRect(x: width - 16 - cw, y: y, width: cw, height: 28)
                addConfirm.frame = NSRect(x: addCancel.frame.minX - 8 - bw, y: y, width: bw, height: 28)
                addInput.frame = NSRect(x: 16, y: y, width: max(0, addConfirm.frame.minX - 8 - 16), height: 28)
            }
            y += 28
        }
        if error != nil {
            y += 8
            if place { errorText.frame = NSRect(x: 16, y: y, width: width - 32, height: 16) }
            y += 16
        }
        return y + 12
    }

    func height(forWidth width: CGFloat) -> CGFloat { layoutAll(width: width, place: false) }
    override func layout() { super.layout(); _ = layoutAll(width: bounds.width, place: true) }

    /// One model (`grid h-7 grid-cols-[1.5rem_minmax(0,1fr)_auto_minmax(5.5rem,auto)_auto]`): star, name and slug,
    /// capabilities, move and custom actions, the picker switch.
    final class ModelRow: DSView {
        private let star = ButtonView(nil, icon: .star, variant: .ghostMuted, size: .iconMicro)
        private let name = LabelView("", font: DSFont.ui(12), color: Themed.color(\.foreground, 0.9))
        private let slug = LabelView("", font: DSFont.mono(11), color: Themed.color(\.mutedForeground, 0.7))
        private let custom = LabelView("custom", font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.7))
        private let caps = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.7))
        private let up = ButtonView(nil, icon: .arrowUp, variant: .ghostMuted, size: .iconMicro)
        private let down = ButtonView(nil, icon: .arrowDown, variant: .ghostMuted, size: .iconMicro)
        private let remove = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconMicro)
        private let edit = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconMicro)
        private let toggle = SwitchView(isOn: true, size: .sm)
        private let showMoves: Bool
        private let isCustom: Bool
        var onFavorite: (() -> Void)?
        var onHidden: ((Bool) -> Void)?
        var onMove: ((Int) -> Void)?
        var onRemove: (() -> Void)?
        var onEdit: (() -> Void)?

        init(model: ProvidersLogic.DisplayModel, favorite: Bool, hidden: Bool, canUp: Bool, canDown: Bool, showMoves: Bool, canManage: Bool) {
            self.showMoves = showMoves
            isCustom = model.isCustom
            super.init(frame: .zero)
            alphaValue = hidden ? 0.5 : 1
            star.iconSize = 12
            if favorite { star.iconColor = Themed.color(\.warning) }
            star.setAccessibilityLabel("\(favorite ? "Remove" : "Add") \(model.name) \(favorite ? "from" : "to") favorites")
            _ = TooltipController.attach(to: star, text: favorite ? "Remove from favorites" : "Add to favorites")
            star.action = { [weak self] in self?.onFavorite?() }
            name.text = model.name
            name.lineHeight = 16
            if hidden { name.color = Themed.color(\.mutedForeground) }
            slug.text = model.name != model.slug ? model.slug : ""
            slug.lineHeight = 14
            custom.isHidden = !model.isCustom
            custom.lineHeight = 14
            caps.text = model.capabilities.joined(separator: " · ")
            caps.lineHeight = 14
            for (b, label) in [(up, "Move \(model.name) up"), (down, "Move \(model.name) down"), (remove, "Remove \(model.slug)")] {
                b.iconSize = 12
                b.setAccessibilityLabel(label)
            }
            _ = TooltipController.attach(to: up, text: "Move up")
            _ = TooltipController.attach(to: down, text: "Move down")
            _ = TooltipController.attach(to: remove, text: "Remove custom model")
            up.isEnabled = canUp
            down.isEnabled = canDown
            up.isHidden = !showMoves
            down.isHidden = !showMoves
            up.action = { [weak self] in self?.onMove?(-1) }
            down.action = { [weak self] in self?.onMove?(1) }
            remove.isHidden = !model.isCustom
            remove.isEnabled = canManage
            remove.action = { [weak self] in self?.onRemove?() }
            edit.isHidden = !model.isCustom
            edit.isEnabled = canManage
            edit.setAccessibilityLabel("Edit custom model")
            edit.action = { [weak self] in self?.onEdit?() }
            toggle.isOn = !hidden
            toggle.isEnabled = !model.isCustom
            toggle.setAccessibilityLabel("Show \(model.name) in the model picker")
            _ = TooltipController.attach(to: toggle, text: model.isCustom ? "Custom models are always shown in the picker" : hidden ? "Hidden from picker" : "Shown in picker")
            toggle.onChange = { [weak self] on in self?.onHidden?(!on) }
            for v in [star, name, slug, custom, caps, up, down, remove, edit, toggle] as [NSView] { addSubview(v) }
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            star.frame = NSRect(x: 8, y: (h - 20) / 2, width: 20, height: 20)
            let ts = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: bounds.width - 8 - ts.width, y: (h - ts.height) / 2, width: ts.width, height: ts.height)
            // Actions column: at least 88 wide, buttons right-aligned.
            var ax = toggle.frame.minX - 8
            for b in [remove, edit, down, up] where !b.isHidden { ax -= 20; b.frame = NSRect(x: ax, y: (h - 20) / 2, width: 20, height: 20); ax -= 2 }
            let actionsLeft = min(ax, toggle.frame.minX - 8 - 88)
            let cw = ceil(caps.textWidth) + (caps.text.isEmpty ? 0 : 1)
            caps.frame = NSRect(x: actionsLeft - 8 - cw, y: (h - 14) / 2, width: cw, height: 14)
            let textRight = caps.frame.minX - 8
            var x: CGFloat = 8 + 24 + 8
            let nw = min(ceil(name.textWidth) + 1, max(0, textRight - x))
            name.frame = NSRect(x: x, y: (h - 16) / 2, width: nw, height: 16)
            x += nw + 8
            if !slug.text.isEmpty {
                let sw = min(ceil(slug.textWidth) + 1, max(0, textRight - x))
                slug.frame = NSRect(x: x, y: (h - 14) / 2 + 1, width: sw, height: 14)
                x += sw + 8
            }
            if !custom.isHidden { custom.frame = NSRect(x: x, y: (h - 14) / 2 + 1, width: min(ceil(custom.textWidth) + 1, max(0, textRight - x)), height: 14) }
        }
    }
}

public enum UsageHubLogic {
    /// `sourceIdFromUrl`: `cliproxy-<host>`, dots and dashes kept, anything else (a port's colon) folded to a dash.
    public static func sourceId(_ url: String) -> String {
        let host = URL(string: url).flatMap { u in u.host.map { h in u.port.map { "\(h):\($0)" } ?? h } } ?? url
        var slug = host.lowercased().replacingOccurrences(of: "[^a-z0-9.-]+", with: "-", options: .regularExpression)
        slug = slug.replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        return "cliproxy-\(slug.isEmpty ? "hub" : slug)"
    }
}

/// The add hub form: labels over inputs, `grid gap-4` with `gap-1.5` inside each field.
final class UsageHubFormView: DSView {
    private let fields: [(LabelView, NSView)]
    init(_ fields: [(String, NSView)]) {
        self.fields = fields.map { (FormLabel.make($0.0), $0.1) }
        super.init(frame: .zero)
        for (l, v) in self.fields { addSubview(l); addSubview(v) }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(fields.count) * 70 - 16) }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (l, v) in fields {
            l.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16)
            v.frame = NSRect(x: 0, y: y + 22, width: bounds.width, height: 32)
            y += 70
        }
    }
}
