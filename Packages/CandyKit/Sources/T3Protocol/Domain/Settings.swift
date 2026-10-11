import Foundation

// T3's two settings stores (packages/contracts/src/settings.ts):
// - client settings (`ClientSettingsSchema`, :300-508) live on this device. T3 desktop keeps them in its own
//   settings file through the desktop bridge (apps/web/src/hooks/useSettings.ts:140-176); CandyWrapper keeps
//   them in its defaults. They never go on the wire.
// - server settings (`ServerSettings`, :1116-1450) live in the environment's settings.json. `server.getConfig`
//   and `subscribeServerConfig` `settingsUpdated` send the whole object with defaults filled in;
//   `server.updateSettings {patch}` changes them (docs/protocol.md 9.6).

/// One settings key: what values decode, and the default an absent or invalid value falls back to
/// (`Schema.withDecodingDefault`).
public struct SettingSpec: Sendable {
    public enum Kind: Sendable {
        case bool
        case literals([String])
        case int(ClosedRange<Int>)
        /// A number in range, or null (`Schema.NullOr`).
        case nullableNumber(ClosedRange<Double>)
        case string(maxLength: Int)
        /// A nested value the client passes through (objects, model selections).
        case any
    }

    public let kind: Kind
    public let defaultValue: JSONValue

    public init(_ kind: Kind, _ defaultValue: JSONValue) { self.kind = kind; self.defaultValue = defaultValue }

    public func accepts(_ value: JSONValue) -> Bool {
        switch (kind, value) {
        case (.bool, .bool): true
        case (.literals(let allowed), .string(let s)): allowed.contains(s)
        case (.int(let range), _): value.intValue.map(range.contains) ?? false
        case (.nullableNumber, .null): true
        case (.nullableNumber(let range), .number(let n)): range.contains(n)
        case (.string(let max), .string(let s)): s.count <= max
        case (.any, _): true
        default: false
        }
    }
}

/// The client settings this app reads and writes, by T3's key names.
public struct ClientSettings: Equatable, Sendable {
    public private(set) var values: [String: JSONValue]

    public static let fields: [String: SettingSpec] = [
        "notificationMode": SettingSpec(.literals(["off", "notifications", "sound", "notifications-and-sound"]), .string("off")),
        "inAppNotificationsEnabled": SettingSpec(.bool, .bool(false)),
        "diffColorScheme": SettingSpec(.literals(["red-green", "blue-orange"]), .string("red-green")),
        "chatWidth": SettingSpec(.literals(["comfortable", "wide", "full"]), .string("comfortable")),
        "appearanceContrast": SettingSpec(.int(50...200), .number(100)),
        "panelAnimationDurationMs": SettingSpec(.int(0...400), .number(0)),
        "confirmQuit": SettingSpec(.literals(["direct", "hold", "double-click"]), .string("hold")),
        "confirmThreadArchive": SettingSpec(.bool, .bool(false)),
        "confirmThreadDelete": SettingSpec(.bool, .bool(true)),
        "confirmThreadUnpin": SettingSpec(.bool, .bool(false)),
        "diffFilesCollapsed": SettingSpec(.bool, .bool(true)),
        "diffIgnoreWhitespace": SettingSpec(.bool, .bool(true)),
        "diffLayout": SettingSpec(.literals(["stacked", "split"]), .string("stacked")),
        "environmentIdentificationMode": SettingSpec(.literals(["artwork", "pill", "none"]), .string("artwork")),
        "glassOpacity": SettingSpec(.int(40...100), .number(80)),
        "fontSizeInterface": SettingSpec(.int(12...20), .number(16)),
        "fontSizePrompt": SettingSpec(.int(12...20), .number(14)),
        "fontSizeCode": SettingSpec(.int(10...18), .number(13)),
        "fontSizeTerminal": SettingSpec(.int(8...20), .number(12)),
        "fontFamilyCode": SettingSpec(.string(maxLength: 200), .string("")),
        "fontFamilyComposer": SettingSpec(.string(maxLength: 200), .string("")),
        "fontFamilySans": SettingSpec(.string(maxLength: 200), .string("")),
        "fontFamilyTerminal": SettingSpec(.string(maxLength: 200), .string("")),
        "fontSmoothing": SettingSpec(.bool, .bool(true)),
        "persistComposerContextStrip": SettingSpec(.bool, .bool(false)),
        "planModeEnabled": SettingSpec(.bool, .bool(false)),
        "contextWindowMeterEnabled": SettingSpec(.bool, .bool(false)),
        "composerCollapseOnScroll": SettingSpec(.bool, .bool(true)),
        "composerRichTextEnabled": SettingSpec(.bool, .bool(true)),
        "sendShortcut": SettingSpec(.literals(["enter", "mod-enter-multiline", "mod-enter"]), .string("enter")),
        "followUpBehavior": SettingSpec(.literals(["queue", "steer"]), .string("queue")),
        "proactivePanelsEnabled": SettingSpec(.bool, .bool(false)),
        "showSkillsInSlashMenu": SettingSpec(.bool, .bool(true)),
        "legacySidebarEnabled": SettingSpec(.bool, .bool(false)),
        "sidebarWorkingShelfEnabled": SettingSpec(.bool, .bool(false)),
        "sidebarProjectGroupingMode": SettingSpec(.literals(["repository", "repository_path", "separate"]), .string("repository")),
        "sidebarProjectGroupingOverrides": SettingSpec(.any, .object([:])),
        "sidebarProjectSortOrder": SettingSpec(.literals(["updated_at", "created_at", "manual"]), .string("updated_at")),
        "sidebarThreadSortOrder": SettingSpec(.literals(["updated_at", "created_at"]), .string("updated_at")),
        "sidebarThreadPreviewCount": SettingSpec(.int(1...15), .number(6)),
        "timestampFormat": SettingSpec(.literals(["locale", "12-hour", "24-hour"]), .string("locale")),
        "wordWrap": SettingSpec(.bool, .bool(true)),
        // Settings > SnapShots (settings.ts:493-505).
        "onboardingCompletedAt": SettingSpec(.any, .null),
        "snapShotEnabled": SettingSpec(.bool, .bool(false)),
        "snapShotIncludeAccessibility": SettingSpec(.bool, .bool(true)),
        "snapShotShortcut": SettingSpec(.any, .object(["kind": .string("both-shift-keys")])),
        "snapShotPlaySound": SettingSpec(.bool, .bool(true)),
        "snapShotSound": SettingSpec(.literals(["soft-pop", "camera-shutter"]), .string("soft-pop")),
        "snapShotFlash": SettingSpec(.bool, .bool(true)),
        "snapShotAnimations": SettingSpec(.bool, .bool(true)),
        // Settings > Integrations > Browser (settings.ts:319-364).
        "browserProfiles": SettingSpec(.any, .array([])),
        "browserDefaultProfileId": SettingSpec(.string(maxLength: 64), .string("default")),
        "browserDefaultViewport": SettingSpec(.any, .object(["_tag": .string("fill")])),
        "browserDefaultZoomFactor": SettingSpec(.any, .number(1)),
        "browserDefaultAppearance": SettingSpec(.literals(["system", "light", "dark"]), .string("system")),
        "browserRecordingFrameRate": SettingSpec(.any, .number(30)),
        "browserRecordingShowKeyPresses": SettingSpec(.bool, .bool(false)),
        "browserRecordingShowMousePresses": SettingSpec(.bool, .bool(false)),
        "browserLinkTarget": SettingSpec(.literals(["system", "app"]), .string("system")),
        "browserAutoShowFloatingPreview": SettingSpec(.bool, .bool(true)),
        // Settings > Providers: favorites, visibility and order per instance (client settings).
        "providerModelPreferences": SettingSpec(.any, .object([:])),
    ]

    public static let defaults = ClientSettings(values: fields.mapValues(\.defaultValue))

    private init(values: [String: JSONValue]) { self.values = values }

    /// Decodes a stored document: a missing or invalid key takes its default, unknown keys drop
    /// (`Schema.decodeSync(ClientSettingsSchema)`). `confirmQuit` also accepts the old boolean.
    public init(decoding json: JSONValue?) {
        var values: [String: JSONValue] = [:]
        for (key, spec) in Self.fields {
            var stored = json?[key]
            if key == "confirmQuit", case .bool(let on)? = stored { stored = .string(on ? "hold" : "direct") }
            values[key] = stored.flatMap { spec.accepts($0) ? $0 : nil } ?? spec.defaultValue
        }
        self.values = values
    }

    public var encoded: JSONValue { .object(values) }

    /// Applies a patch; invalid values and unknown keys are ignored. Returns the keys that changed.
    @discardableResult
    public mutating func apply(_ patch: [String: JSONValue]) -> Set<String> {
        var changed: Set<String> = []
        for (key, value) in patch {
            guard let spec = Self.fields[key], spec.accepts(value), values[key] != value else { continue }
            values[key] = value
            changed.insert(key)
        }
        return changed
    }

    public subscript(key: String) -> JSONValue { values[key] ?? Self.fields[key]?.defaultValue ?? .null }
    public func bool(_ key: String) -> Bool { self[key].boolValue ?? false }
    public func string(_ key: String) -> String { self[key].stringValue ?? "" }
    public func int(_ key: String) -> Int { self[key].intValue ?? 0 }
    public func isDefault(_ key: String) -> Bool { self[key] == Self.fields[key]?.defaultValue }
}

/// Server settings as the server sent them, with `ServerSettings` defaults for the keys this client reads.
public struct ServerSettingsValues: Equatable, Sendable {
    public var raw: [String: JSONValue]

    /// `DEFAULT_SERVER_SETTINGS` for the keys the General page shows (settings.ts:1116-1450).
    public static let fields: [String: SettingSpec] = [
        "responseStreamingMode": SettingSpec(.literals(["turn", "paragraph"]), .string("paragraph")),
        "enableProviderUpdateChecks": SettingSpec(.bool, .bool(true)),
        "continueThreadsAfterServerUpdate": SettingSpec(.bool, .bool(false)),
        "sidebarAutoSettleAfterDays": SettingSpec(.nullableNumber(1...90), .number(3)),
        "snoozeLimitedThreads": SettingSpec(.bool, .bool(false)),
        "autoResumeLimitedThreads": SettingSpec(.bool, .bool(false)),
        "sidebarAutoSettleOnMerge": SettingSpec(.bool, .bool(true)),
        "backgroundActivity": SettingSpec(.any, BackgroundActivity.defaultSettings),
        "backgroundActivityProfile": SettingSpec(.literals(["balanced", "performance", "battery-saver"]), .string("balanced")),
        "automaticGitFetchInterval": SettingSpec(.any, .number(30_000)),
        "providerHealthRefreshInterval": SettingSpec(.any, .number(300_000)),
        "newWorktreesStartFromOrigin": SettingSpec(.bool, .bool(true)),
        "addProjectBaseDirectory": SettingSpec(.string(maxLength: 4096), .string("")),
        "defaultRuntimeMode": SettingSpec(.literals(["approval-required", "auto-accept-edits", "auto", "full-access"]), .string("full-access")),
        // `OmittedWhenNull`: absent on the wire means null (inherit t3.json, then local).
        "defaultThreadEnvMode": SettingSpec(.any, .null),
        "worktreeSubmodules": SettingSpec(.any, .null),
        "defaultModelSelection": SettingSpec(.any, .null),
        "textGenerationModelSelection": SettingSpec(.any, .object([
            "instanceId": .string("codex"), "model": .string("gpt-6-luna"),
            "options": .array([.object(["id": .string("reasoningEffort"), "value": .string("low")])]),
        ])),
        // Settings > Project, Source Control, Integrations, Storage and Providers (WP7.7b).
        "defaultAutoPull": SettingSpec(.bool, .bool(false)),
        "removeAgentCreditsOnMerge": SettingSpec(.bool, .bool(false)),
        "pullRequestMergeMethod": SettingSpec(.any, .null),
        "branchNamingMode": SettingSpec(.literals(["static", "semantic", "custom"]), .string("static")),
        "branchNamePrefix": SettingSpec(.string(maxLength: 4096), .string("t3")),
        "branchNameInstructions": SettingSpec(.string(maxLength: 65_536), .string("")),
        "sourceControlWritingStyle": SettingSpec(.any, .object([
            "mode": .string("repo_conventions"), "customInstructions": .string(""), "followChangeRequestTemplates": .bool(true),
        ])),
        "sourceControlWriterModelSelection": SettingSpec(.any, .null),
        "enableAgentBrowserAccess": SettingSpec(.bool, .bool(true)),
        "enableAgentDeviceAccess": SettingSpec(.bool, .bool(false)),
        "enableDeviceSupport": SettingSpec(.bool, .bool(false)),
        "worktreesDirectory": SettingSpec(.string(maxLength: 4096), .string("")),
        "storageCleanup": SettingSpec(.any, .object([
            "worktreeAfterDays": .null, "worktreeOnMerge": .bool(false), "worktreeOnDelete": .bool(false), "worktreeUnchanged": .bool(false),
            "browserArtifactsAfterDays": .null, "logsAfterDays": .null,
        ])),
        "worktreeCleanup": SettingSpec(.any, .null),
        "defaultProjectScripts": SettingSpec(.any, .array([])),
        "projectSettingsOverrides": SettingSpec(.any, .object([:])),
        "projectSettingsFolded": SettingSpec(.bool, .bool(false)),
        "providerInstances": SettingSpec(.any, .object([:])),
    ]

    public init(_ json: JSONValue?) { raw = json?.objectValue ?? [:] }

    public subscript(key: String) -> JSONValue {
        if let v = raw[key], Self.fields[key]?.accepts(v) ?? true { return v }
        return Self.fields[key]?.defaultValue ?? .null
    }
    public func bool(_ key: String) -> Bool { self[key].boolValue ?? false }
    public func string(_ key: String) -> String { self[key].stringValue ?? "" }
    /// Differs from `DEFAULT_SERVER_SETTINGS` (the row's reset arrow and "Set on the environment").
    public func isDefault(_ key: String) -> Bool { self[key] == (Self.fields[key]?.defaultValue ?? .null) }
}

/// T3's background activity profiles (packages/shared/src/backgroundActivitySettings.ts and
/// apps/web/src/components/settings/SettingsPanels.logic.ts:172-330). Durations are milliseconds,
/// as `Schema.DurationFromMillis` puts them on the wire.
public enum BackgroundActivity {
    public static let profiles = ["balanced", "performance", "battery-saver"]
    public static let defaultSettings: JSONValue = .object(["schemaVersion": .number(1), "profile": .string("balanced"), "overrides": .object([:])])

    public struct Resolved: Equatable, Sendable {
        public var profile: String
        public var automaticGitFetchInterval: Double
        public var providerHealthRefreshInterval: Double
        public var hostPowerMonitorActiveInterval: Double
        public var hostPowerMonitorIdleInterval: Double
        public var idleClientTtl: Double
        public var pauseWhenHostLocked: Bool
        public var pauseWhenHostLowPower: Bool
        public var pauseWhenClientLowPower: Bool
        public var pauseWhenOnBattery: Bool

        static let durationKeys = ["automaticGitFetchInterval", "providerHealthRefreshInterval", "hostPowerMonitorActiveInterval",
                                   "hostPowerMonitorIdleInterval", "idleClientTtl"]
        static let boolKeys = ["pauseWhenHostLocked", "pauseWhenHostLowPower", "pauseWhenClientLowPower", "pauseWhenOnBattery"]

        var fields: [String: JSONValue] {
            ["automaticGitFetchInterval": .number(automaticGitFetchInterval), "providerHealthRefreshInterval": .number(providerHealthRefreshInterval),
             "hostPowerMonitorActiveInterval": .number(hostPowerMonitorActiveInterval), "hostPowerMonitorIdleInterval": .number(hostPowerMonitorIdleInterval),
             "idleClientTtl": .number(idleClientTtl), "pauseWhenHostLocked": .bool(pauseWhenHostLocked),
             "pauseWhenHostLowPower": .bool(pauseWhenHostLowPower), "pauseWhenClientLowPower": .bool(pauseWhenClientLowPower),
             "pauseWhenOnBattery": .bool(pauseWhenOnBattery)]
        }

        func with(_ overrides: [String: JSONValue]) -> Resolved {
            var r = self
            func d(_ k: String, _ v: Double) -> Double { overrides[k]?.doubleValue ?? v }
            func b(_ k: String, _ v: Bool) -> Bool { overrides[k]?.boolValue ?? v }
            r.automaticGitFetchInterval = d("automaticGitFetchInterval", r.automaticGitFetchInterval)
            r.providerHealthRefreshInterval = d("providerHealthRefreshInterval", r.providerHealthRefreshInterval)
            r.hostPowerMonitorActiveInterval = d("hostPowerMonitorActiveInterval", r.hostPowerMonitorActiveInterval)
            r.hostPowerMonitorIdleInterval = d("hostPowerMonitorIdleInterval", r.hostPowerMonitorIdleInterval)
            r.idleClientTtl = d("idleClientTtl", r.idleClientTtl)
            r.pauseWhenHostLocked = b("pauseWhenHostLocked", r.pauseWhenHostLocked)
            r.pauseWhenHostLowPower = b("pauseWhenHostLowPower", r.pauseWhenHostLowPower)
            r.pauseWhenClientLowPower = b("pauseWhenClientLowPower", r.pauseWhenClientLowPower)
            r.pauseWhenOnBattery = b("pauseWhenOnBattery", r.pauseWhenOnBattery)
            return r
        }

        func sameValues(_ o: Resolved) -> Bool { var a = self; a.profile = o.profile; return a == o }
    }

    /// `PRESET_SETTINGS`.
    public static let presets: [String: Resolved] = [
        "performance": Resolved(profile: "performance", automaticGitFetchInterval: 15_000, providerHealthRefreshInterval: 60_000,
                                hostPowerMonitorActiveInterval: 30_000, hostPowerMonitorIdleInterval: 120_000, idleClientTtl: 45_000,
                                pauseWhenHostLocked: true, pauseWhenHostLowPower: false, pauseWhenClientLowPower: false, pauseWhenOnBattery: false),
        "balanced": Resolved(profile: "balanced", automaticGitFetchInterval: 30_000, providerHealthRefreshInterval: 300_000,
                             hostPowerMonitorActiveInterval: 30_000, hostPowerMonitorIdleInterval: 300_000, idleClientTtl: 45_000,
                             pauseWhenHostLocked: true, pauseWhenHostLowPower: true, pauseWhenClientLowPower: true, pauseWhenOnBattery: false),
        "battery-saver": Resolved(profile: "battery-saver", automaticGitFetchInterval: 0, providerHealthRefreshInterval: 900_000,
                                  hostPowerMonitorActiveInterval: 60_000, hostPowerMonitorIdleInterval: 600_000, idleClientTtl: 45_000,
                                  pauseWhenHostLocked: true, pauseWhenHostLowPower: true, pauseWhenClientLowPower: true, pauseWhenOnBattery: true),
    ]

    static func validProfile(_ s: String?) -> String? { s.flatMap { profiles.contains($0) ? $0 : nil } }

    /// `getBackgroundActivityBaseProfile`.
    public static func baseProfile(_ settings: JSONValue) -> String {
        let profile = settings["profile"]?.stringValue
        if profile == "custom" { return validProfile(settings["baseProfile"]?.stringValue) ?? "balanced" }
        return validProfile(profile) ?? "balanced"
    }

    /// `resolveBackgroundActivitySettings`.
    public static func resolve(_ settings: JSONValue) -> Resolved {
        let base = baseProfile(settings)
        let overrides = settings["profile"]?.stringValue == "custom" ? settings["overrides"]?.objectValue ?? [:] : [:]
        return presets[base]!.with(overrides)
    }

    /// `normalizeBackgroundActivitySettings`: a custom selection that matches a preset collapses to it.
    public static func normalize(_ settings: JSONValue) -> JSONValue {
        guard settings["profile"]?.stringValue == "custom" else {
            return .object(["schemaVersion": .number(1), "profile": .string(validProfile(settings["profile"]?.stringValue) ?? "balanced"), "overrides": .object([:])])
        }
        let resolved = resolve(settings)
        let base = baseProfile(settings)
        for profile in [base, "balanced", "performance", "battery-saver"] where resolved.sameValues(presets[profile]!) {
            return .object(["schemaVersion": .number(1), "profile": .string(profile), "overrides": .object([:])])
        }
        let preset = presets[base]!.fields
        let overrides = resolved.fields.filter { preset[$0.key] != $0.value }
        return .object(["schemaVersion": .number(1), "profile": .string("custom"), "baseProfile": .string(base), "overrides": .object(overrides)])
    }

    /// `resolveServerBackgroundActivitySettings`: the legacy flat fields count while `backgroundActivity` is default.
    public static func resolveServer(_ s: ServerSettingsValues) -> Resolved {
        let ba = s["backgroundActivity"]
        let isDefault = ba["profile"]?.stringValue == "balanced" && ba["baseProfile"] == nil && (ba["overrides"]?.objectValue ?? [:]).isEmpty
        let legacy = validProfile(s.string("backgroundActivityProfile")) ?? "balanced"
        let git = s["automaticGitFetchInterval"].doubleValue ?? 30_000
        let health = s["providerHealthRefreshInterval"].doubleValue ?? 300_000
        let hasLegacy = legacy != "balanced" || git != 30_000 || health != 300_000
        if isDefault && hasLegacy {
            let preset = presets[legacy]!
            var overrides: [String: JSONValue] = [:]
            if git != preset.automaticGitFetchInterval { overrides["automaticGitFetchInterval"] = .number(git) }
            if health != preset.providerHealthRefreshInterval { overrides["providerHealthRefreshInterval"] = .number(health) }
            return resolve(.object(["schemaVersion": .number(1), "profile": .string(overrides.isEmpty ? legacy : "custom"),
                                    "baseProfile": .string(legacy), "overrides": .object(overrides)]))
        }
        return resolve(ba)
    }

    /// `resolveBackgroundActivityProfileOption`: a preset name, or "advanced" for custom intervals.
    public static func profileOption(_ s: ServerSettingsValues) -> String {
        let r = resolveServer(s)
        let normalized = normalize(.object(["schemaVersion": .number(1), "profile": .string("custom"), "baseProfile": .string(r.profile),
                                            "overrides": .object(r.fields)]))
        let profile = normalized["profile"]?.stringValue ?? "balanced"
        return profile == "custom" ? "advanced" : profile
    }

    /// `backgroundActivityProfileSettings`: picking a preset clears the overrides.
    public static func profileSettings(_ profile: String) -> JSONValue {
        .object(["schemaVersion": .number(1), "profile": .string(profile), "overrides": .object([:])])
    }

    /// `backgroundActivitySharedPolicySettings`: a new shared policy that keeps the custom intervals.
    public static func sharedPolicySettings(_ s: ServerSettingsValues, profile: String) -> JSONValue {
        let r = resolveServer(s)
        let normalized = normalize(.object(["schemaVersion": .number(1), "profile": .string("custom"), "baseProfile": .string(r.profile),
                                            "overrides": .object(r.fields)]))
        let overrides = normalized["profile"]?.stringValue == "custom" ? normalized["overrides"] ?? .object([:]) : .object([:])
        return .object(["schemaVersion": .number(1), "profile": .string("custom"), "baseProfile": .string(profile), "overrides": overrides])
    }

    /// `backgroundActivityOverrideSettings`: every resolved value as an override, with `changes` on top.
    public static func overrideSettings(_ s: ServerSettingsValues, _ changes: [String: JSONValue]) -> JSONValue {
        var overrides = resolveServer(s).fields
        for (k, v) in changes { overrides[k] = v }
        return .object(["schemaVersion": .number(1), "profile": .string("custom"), "baseProfile": .string(baseProfile(s["backgroundActivity"])),
                        "overrides": .object(overrides)])
    }

    /// `hasChangedBackgroundActivitySettings`.
    public static func isChanged(_ s: ServerSettingsValues) -> Bool {
        !s.isDefault("backgroundActivity") || !s.isDefault("backgroundActivityProfile")
            || !s.isDefault("automaticGitFetchInterval") || !s.isDefault("providerHealthRefreshInterval")
    }

    /// `normalizeIntervalSeconds`.
    public static func normalizeIntervalSeconds(_ value: Double?, minimum: Double = 0) -> Double {
        guard let value, value.isFinite else { return minimum }
        return max(minimum, value.rounded())
    }
}
