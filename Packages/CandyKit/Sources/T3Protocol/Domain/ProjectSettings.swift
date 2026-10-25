import Foundation

// Project overrides of server settings and project actions, ported from T3 (paths relative to the
// pingdotgg/t3code checkout): packages/shared/src/projectSettings.ts, packages/shared/src/projectScripts.ts,
// apps/web/src/projectScripts.ts and packages/contracts/src/settings.ts:1027-1102.

/// Where a project-scoped value comes from (`ProjectSettingSource`): a project override, the environment, or the
/// checkout's t3.json for file-backed keys. The built-in default reports the environment.
public enum ProjectSettingSource: String, Sendable, Equatable { case environment, project, t3json = "t3.json" }

public enum ProjectSettings {
    /// `PROJECT_SCOPED_SERVER_SETTING_KEYS` (settings.ts:966-990 at 3105).
    public static let scopedKeys: [String] = [
        "worktreeCleanup", "defaultModelSelection", "defaultRuntimeMode", "defaultThreadEnvMode", "newWorktreesStartFromOrigin",
        "worktreeSubmodules", "defaultAutoPull", "defaultProjectScripts", "enableAgentBrowserAccess", "enableAgentDeviceAccess",
        "textGenerationModelSelection", "threadTitleInstructions", "sourceControlWriterModelSelection", "reviewGuideModelSelection", "reviewGuideInstructions",
        "sourceControlWritingStyle", "removeAgentCreditsOnMerge",
        "branchNamingMode", "branchNamePrefix", "branchNameInstructions", "pullRequestMergeMethod", "sidebarAutoSettleOnMerge",
        "sidebarAutoSettleAfterDays", "sidebarAutoSettleKeepPullRequests", "continueThreadsAfterServerUpdate", "responseStreamingMode",
    ]
    static let scopedSet = Set(scopedKeys)

    public static func isScoped(_ key: String) -> Bool { scopedSet.contains(key) }

    /// `NULLABLE_PROJECT_SETTINGS_OVERRIDES` (settings.ts:1093-1102): null is a real override value only here.
    public static let nullableKeys: Set<String> = ["defaultModelSelection", "sourceControlWriterModelSelection", "reviewGuideModelSelection", "pullRequestMergeMethod",
                                                    "sidebarAutoSettleAfterDays"]

    /// The project aggregate's own model and workspace fields, which count until the server folds them
    /// into `projectSettingsOverrides` (`LegacyProjectSettingsFields`).
    public struct Legacy: Equatable, Sendable {
        public var defaultModelSelection: JSONValue?
        public var defaultThreadEnvMode: String?
        public init(defaultModelSelection: JSONValue? = nil, defaultThreadEnvMode: String? = nil) {
            self.defaultModelSelection = defaultModelSelection; self.defaultThreadEnvMode = defaultThreadEnvMode
        }
    }

    public struct Resolved: Equatable, Sendable {
        public var settings: ServerSettingsValues
        public var sources: [String: ProjectSettingSource]
        public var overrides: [String: JSONValue]
        public func source(_ key: String) -> ProjectSettingSource { sources[key] ?? .environment }
    }

    /// `PROJECT_FILE_BACKED_SETTINGS` (contracts t3ProjectFile.ts:125-127): each key's built-in value. The
    /// t3.json field has the key's name.
    public static let fileBacked: [String: String] = ["defaultThreadEnvMode": "local", "worktreeSubmodules": "recursive"]

    static func fileValue(_ key: String, _ file: T3ProjectFile?) -> String? {
        switch key {
        case "defaultThreadEnvMode": file?.defaultThreadEnvMode
        case "worktreeSubmodules": file?.worktreeSubmodules
        default: nil
        }
    }

    /// `resolveProjectSettings` (shared/projectSettings.ts:86-121). With a `projectFile` (the outer optional
    /// absent until the file was read, the inner nil for a missing or invalid file), every file-backed key
    /// left null resolves to the file's value (source t3.json) or the built-in (source environment).
    public static func resolve(_ settings: ServerSettingsValues, projectId: String?, legacy: Legacy? = nil,
                               projectFile: T3ProjectFile?? = .none) -> Resolved {
        var resolved = resolveOverrides(settings, projectId: projectId, legacy: legacy)
        guard case .some(let file) = projectFile else { return resolved }
        for (key, builtIn) in fileBacked where resolved.settings[key] == .null {
            if let value = fileValue(key, file) {
                resolved.settings.raw[key] = .string(value)
                resolved.sources[key] = .t3json
            } else {
                resolved.settings.raw[key] = .string(builtIn)
                resolved.sources[key] = .environment
            }
        }
        return resolved
    }

    /// The project's override entry on top of the environment settings. A model override on a disabled
    /// provider falls back to the environment.
    private static func resolveOverrides(_ settings: ServerSettingsValues, projectId: String?, legacy: Legacy?) -> Resolved {
        let stored = projectId.flatMap { settings["projectSettingsOverrides"][$0]?.objectValue }
        var overrides: [String: JSONValue]
        if let legacy, !settings.bool("projectSettingsFolded") {
            overrides = [:]
            if let m = legacy.defaultModelSelection, m != .null { overrides["defaultModelSelection"] = m }
            if let e = legacy.defaultThreadEnvMode { overrides["defaultThreadEnvMode"] = .string(e) }
            for (k, v) in stored ?? [:] { overrides[k] = v }
        } else {
            overrides = stored ?? [:]
        }
        guard !overrides.isEmpty else { return Resolved(settings: settings, sources: [:], overrides: [:]) }
        var effective = settings
        var sources: [String: ProjectSettingSource] = [:]
        for key in scopedKeys {
            guard let value = overrides[key] else { continue }
            if key == "textGenerationModelSelection" || key == "defaultModelSelection", value != .null,
               !isModelSelectionProviderEnabled(settings, value) { continue }
            effective.raw[key] = value
            sources[key] = .project
        }
        return Resolved(settings: effective, sources: sources, overrides: overrides)
    }

    /// `clearProjectSettingsOverrides`: the entry without `keys`, nil when that leaves it empty.
    public static func clear(_ settings: ServerSettingsValues, projectId: String, keys: [String]) -> [String: JSONValue]? {
        guard var entry = settings["projectSettingsOverrides"][projectId]?.objectValue else { return nil }
        for k in keys { entry.removeValue(forKey: k) }
        return entry.isEmpty ? nil : entry
    }

    /// The four worktree rules of `storageCleanup` (`WorktreeCleanupRules`).
    public static let worktreeRuleKeys = ["worktreeAfterDays", "worktreeSettledAfterDays", "worktreeOnMerge", "worktreeOnDelete", "worktreeUnchanged"]

    /// `resolveWorktreeCleanup`: custom rules, off, or the environment's `storageCleanup` rules.
    public static func worktreeCleanup(_ settings: ServerSettingsValues, projectId: String?) -> [String: JSONValue] {
        let policy = resolve(settings, projectId: projectId).settings["worktreeCleanup"]
        switch policy["mode"]?.stringValue {
        case "custom": return policy["rules"]?.objectValue ?? [:]
        case "off":
            var rules: [String: JSONValue] = ["worktreeAfterDays": .null, "worktreeSettledAfterDays": .null, "worktreeOnMerge": .bool(false), "worktreeOnDelete": .bool(false), "worktreeUnchanged": .bool(false)]
            // 2994 keeps the environment's `worktreeKeepWhen` (shared projectSettings.ts:275-282). 2861 servers have none.
            if let keep = settings["storageCleanup"].objectValue?["worktreeKeepWhen"] { rules["worktreeKeepWhen"] = keep }
            return rules
        default:
            let storage = settings["storageCleanup"].objectValue ?? [:]
            // `StorageCleanupSettings` decoding defaults for absent rules.
            var rules = Dictionary(uniqueKeysWithValues: worktreeRuleKeys.map { ($0, storage[$0] ?? ($0.hasSuffix("AfterDays") ? .null : .bool(false))) })
            if let keep = storage["worktreeKeepWhen"] { rules["worktreeKeepWhen"] = keep }
            return rules
        }
    }

    // MARK: Providers

    /// `DEFAULT_DISABLED_PROVIDER_DRIVERS` (settings.ts:1356-1360).
    public static let defaultDisabledDrivers: Set<String> = ["cursor", "grok", "muse", "pi", "opencode", "antigravity"]

    /// A project's own `providerInstances[id].enabled` (contracts settings.ts:975-1021, 2994), nil when it inherits.
    /// `resolveProjectProviderInstanceEnabled` (settings.ts:1398-1414) uses it before the machine-wide value.
    public static func providerOverride(_ settings: ServerSettingsValues, projectId: String, instanceId: String) -> Bool? {
        settings["projectSettingsOverrides"][projectId]?["providerInstances"]?[instanceId]?["enabled"]?.boolValue
    }

    /// `buildProviderInstanceOverridePatch` (ProviderSettingsPanel.logic.ts:126-148): each project's whole entry with
    /// the instance's `enabled` set, or dropped for nil. An entry left empty becomes null.
    public static func providerOverridePatch(_ settings: ServerSettingsValues, projectIds: [String], instanceId: String,
                                             enabled: Bool?) -> JSONValue {
        let overrides = settings["projectSettingsOverrides"].objectValue ?? [:]
        var patch: [String: JSONValue] = [:]
        for projectId in projectIds {
            var rest = overrides[projectId]?.objectValue ?? [:]
            var instances = rest.removeValue(forKey: "providerInstances")?.objectValue ?? [:]
            var instance = instances[instanceId]?.objectValue ?? [:]
            if let enabled { instance["enabled"] = .bool(enabled) } else { instance.removeValue(forKey: "enabled") }
            if instance.isEmpty { instances.removeValue(forKey: instanceId) } else { instances[instanceId] = .object(instance) }
            if rest.isEmpty && instances.isEmpty {
                patch[projectId] = .null
            } else {
                rest["providerInstances"] = .object(instances)
                patch[projectId] = .object(rest)
            }
        }
        return .object(patch)
    }

    /// `resolveProviderInstanceEnabled`: an explicit false on the envelope or in the config wins, then the
    /// envelope, the config, and the driver's default.
    public static func providerInstanceEnabled(_ instance: JSONValue) -> Bool {
        let configEnabled = instance["config"]?["enabled"]?.boolValue
        let enabled = instance["enabled"]?.boolValue
        if enabled == false || configEnabled == false { return false }
        return enabled ?? configEnabled ?? !defaultDisabledDrivers.contains(instance["driver"]?.stringValue ?? "")
    }

    /// `isModelSelectionProviderEnabled` (shared serverSettings.ts:61-71).
    public static func isModelSelectionProviderEnabled(_ settings: ServerSettingsValues, _ selection: JSONValue) -> Bool {
        guard let id = selection["instanceId"]?.stringValue else { return false }
        if let instance = settings["providerInstances"][id], instance != .null { return providerInstanceEnabled(instance) }
        return id == "codex" || id == "claudeAgent"
    }
}

// MARK: - Project actions

/// `ProjectScript` (contracts project.ts:33-45).
public struct ProjectScript: Equatable, Sendable {
    public static let icons = ["play", "test", "lint", "configure", "build", "debug"]
    public var id: String
    public var name: String
    public var command: String
    public var icon: String
    public var runOnWorktreeCreate: Bool
    public var runOnSettle: Bool?
    public var async: Bool?
    public var previewUrl: String?
    public var autoOpenPreview: Bool?

    public init(id: String, name: String, command: String, icon: String = "play", runOnWorktreeCreate: Bool = false, runOnSettle: Bool? = nil,
                async: Bool? = nil, previewUrl: String? = nil, autoOpenPreview: Bool? = nil) {
        self.id = id; self.name = name; self.command = command; self.icon = icon; self.runOnWorktreeCreate = runOnWorktreeCreate
        self.runOnSettle = runOnSettle; self.async = async; self.previewUrl = previewUrl; self.autoOpenPreview = autoOpenPreview
    }

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue, let command = json["command"]?.stringValue else { return nil }
        self.init(id: id, name: name, command: command, icon: json["icon"]?.stringValue.flatMap { Self.icons.contains($0) ? $0 : nil } ?? "play",
                  runOnWorktreeCreate: json["runOnWorktreeCreate"]?.boolValue ?? false, runOnSettle: json["runOnSettle"]?.boolValue,
                  async: json["async"]?.boolValue, previewUrl: json["previewUrl"]?.stringValue, autoOpenPreview: json["autoOpenPreview"]?.boolValue)
    }

    /// `projectScriptTerminalInput` (packages/shared/src/projectScripts.ts:83-90): a leading space keeps the
    /// script out of the history of bash with ignorespace, zsh with HIST_IGNORE_SPACE, and fish.
    public static func terminalInput(_ command: String) -> String { " \(command)\r" }

    /// Optional keys stay off the wire when unset, as T3 builds them.
    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name), "command": .string(command), "icon": .string(icon),
                                      "runOnWorktreeCreate": .bool(runOnWorktreeCreate)]
        if let runOnSettle { o["runOnSettle"] = .bool(runOnSettle) }
        if let async { o["async"] = .bool(async) }
        if let previewUrl { o["previewUrl"] = .string(previewUrl) }
        if let autoOpenPreview { o["autoOpenPreview"] = .bool(autoOpenPreview) }
        return .object(o)
    }

    public static func list(_ json: JSONValue?) -> [ProjectScript] { json?.arrayValue?.compactMap(ProjectScript.init) ?? [] }
}

/// The action editor's form (`NewProjectScriptInput`).
public struct ProjectScriptInput: Equatable, Sendable {
    public var name: String
    public var command: String
    public var icon: String
    public var runOnWorktreeCreate: Bool
    public var waitForSetup: Bool
    public var runOnSettle: Bool
    /// nil keeps the current shortcut; "" removes it.
    public var keybinding: String?
    public var previewUrl: String?
    public var autoOpenPreview: Bool

    public init(name: String = "", command: String = "", icon: String = "play", runOnWorktreeCreate: Bool = false, waitForSetup: Bool = false,
                runOnSettle: Bool = false, keybinding: String? = nil, previewUrl: String? = nil, autoOpenPreview: Bool = false) {
        self.name = name; self.command = command; self.icon = icon; self.runOnWorktreeCreate = runOnWorktreeCreate
        self.waitForSetup = waitForSetup; self.runOnSettle = runOnSettle; self.keybinding = keybinding; self.previewUrl = previewUrl
        self.autoOpenPreview = autoOpenPreview
    }
}

public enum ProjectScripts {
    /// `MAX_SCRIPT_ID_LENGTH`.
    public static let maxIdLength = 24

    /// `resolveProjectScripts`: the override, else (before the fold) the legacy map and the project's own list,
    /// else the environment defaults.
    public static func resolve(_ settings: ServerSettingsValues, projectId: String, projectScripts: [ProjectScript]) -> [ProjectScript] {
        if let override = settings["projectSettingsOverrides"][projectId]?["defaultProjectScripts"] { return ProjectScript.list(override) }
        let defaults = ProjectScript.list(settings["defaultProjectScripts"])
        if settings.bool("projectSettingsFolded") { return defaults }
        if let legacy = settings["projectScriptOverrides"][projectId] {
            return legacy == .null ? defaults : ProjectScript.list(legacy)
        }
        return projectScripts.isEmpty ? defaults : projectScripts
    }

    /// `buildProjectScript`.
    public static func build(id: String, _ input: ProjectScriptInput) -> ProjectScript {
        ProjectScript(id: id, name: input.name, command: input.command, icon: input.icon, runOnWorktreeCreate: input.runOnWorktreeCreate,
                      runOnSettle: input.runOnSettle ? true : nil, async: input.runOnWorktreeCreate && input.waitForSetup ? false : nil,
                      previewUrl: input.previewUrl, autoOpenPreview: input.previewUrl == nil ? nil : input.autoOpenPreview)
    }

    /// `releaseClaimedRoles`: one setup and one settle script per project, so the saved one takes the role.
    public static func releaseClaimedRoles(_ script: ProjectScript, saved: ProjectScriptInput) -> ProjectScript {
        let setup = saved.runOnWorktreeCreate && script.runOnWorktreeCreate
        let settle = saved.runOnSettle && script.runOnSettle == true
        guard setup || settle else { return script }
        var s = script
        if setup { s.runOnWorktreeCreate = false }
        if settle { s.runOnSettle = false }
        return s
    }

    /// `normalizeScriptId`.
    static func normalizeId(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        if cleaned.isEmpty { return "script" }
        if cleaned.count <= maxIdLength { return cleaned }
        let cut = String(cleaned.prefix(maxIdLength)).replacingOccurrences(of: "-+$", with: "", options: .regularExpression)
        return cut.isEmpty ? "script" : cut
    }

    /// `nextProjectScriptId`: the normalized name, else with `-2`, `-3`, ... kept within the length limit.
    public static func nextId(_ name: String, existing: [String]) -> String {
        let taken = Set(existing)
        let base = normalizeId(name)
        if !taken.contains(base) { return base }
        for suffix in 2..<10_000 {
            let candidate = "\(base)-\(suffix)"
            let safe = candidate.count <= maxIdLength ? candidate
                : "\(base.prefix(max(1, maxIdLength - String(suffix).count - 1)))-\(suffix)"
            if !taken.contains(safe) { return safe }
        }
        return String("\(base)-\(Int(Date().timeIntervalSince1970 * 1000))".prefix(maxIdLength))
    }

    /// `projectScriptIdFromCommand`: the id in `script.<id>.run`, nil for any other command.
    public static func scriptId(fromCommand command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard c.hasPrefix("script."), c.hasSuffix(".run") else { return nil }
        let id = String(c.dropFirst("script.".count).dropLast(".run".count))
        return Self.command(id) == c ? id : nil
    }

    /// `primaryProjectScript` (web projectScripts.ts:108-111): the first action with no role, else
    /// the first that does not run on settle.
    public static func primary(_ scripts: [ProjectScript]) -> ProjectScript? {
        scripts.first { !$0.runOnWorktreeCreate && $0.runOnSettle != true } ?? scripts.first { $0.runOnSettle != true }
    }

    /// `projectScriptMenuLabel` (shared projectScripts.ts:78-84): the name with its roles.
    public static func menuLabel(_ script: ProjectScript) -> String {
        let roles = (script.runOnWorktreeCreate ? ["setup"] : []) + (script.runOnSettle == true ? ["on settle"] : [])
        return roles.isEmpty ? script.name : "\(script.name) (\(roles.joined(separator: ", ")))"
    }

    /// `commandForProjectScript`: `script.<id>.run`, or nil for a legacy id the pattern rejects.
    public static func command(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= maxIdLength, id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else { return nil }
        return "script.\(id).run"
    }

    /// The list after saving `input` (`useProjectScriptSettings.submit`): an edit replaces its script, an add
    /// appends; either way other scripts give up the setup and settle roles the saved one claims.
    public static func applySubmit(_ current: [ProjectScript], id: String, isNew: Bool, input: ProjectScriptInput) -> [ProjectScript] {
        let next = build(id: id, input)
        let updated = current.map { $0.id == id ? next : releaseClaimedRoles($0, saved: input) }
        return isNew ? updated + [next] : updated
    }

    /// The editor's validation (`ProjectScriptEditorDialog.submit`): the trimmed input, or the error shown.
    public static func validate(_ input: ProjectScriptInput) -> Result<ProjectScriptInput, ValidationError> {
        var out = input
        out.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        out.command = input.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.name.isEmpty { return .failure(ValidationError(message: "Name is required.")) }
        if out.command.isEmpty { return .failure(ValidationError(message: "Command is required.")) }
        let url = input.previewUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        out.previewUrl = url.isEmpty ? nil : url
        out.autoOpenPreview = url.isEmpty ? false : input.autoOpenPreview
        out.waitForSetup = input.runOnWorktreeCreate && input.waitForSetup
        return .success(out)
    }

    public struct ValidationError: Error, Equatable, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
    }
}
