import Foundation

// The subset of `server.getConfig` and `subscribeServerConfig` the composer's pickers read:
// providers with their models and option descriptors, and the settings that seed new threads.
// Schemas: packages/contracts/src/server.ts:213-300 (ServerProvider), :75-86 (ServerProviderModel),
// packages/contracts/src/model.ts:7-53 (descriptors and selections). docs/protocol.md 9.4 and 9.6.

/// `RuntimeMode` (packages/contracts/src/providerPolicy.ts:25-32). Default `full-access`.
public struct RuntimeMode: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let approvalRequired: Self = "approval-required"
    public static let autoAcceptEdits: Self = "auto-accept-edits"
    public static let auto: Self = "auto"
    public static let fullAccess: Self = "full-access"
    /// The access picker's order (runtimeModeConfig.ts object order).
    public static let all: [RuntimeMode] = [.approvalRequired, .autoAcceptEdits, .auto, .fullAccess]
}

/// A `ProviderOptionSelection` value: a non-empty string or a boolean.
public enum ProviderOptionValue: Codable, Hashable, Sendable {
    case string(String)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
}

/// `ProviderOptionSelection` (model.ts:46-53): `{id, value}`.
public struct ProviderOptionSelection: Codable, Hashable, Sendable {
    public var id: String
    public var value: ProviderOptionValue
    public init(id: String, value: ProviderOptionValue) { self.id = id; self.value = value }
}

/// `ProviderOptionChoice` (model.ts:10-15).
public struct ProviderOptionChoice: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public var isDefault: Bool?
    public init(id: String, label: String, description: String? = nil, isDefault: Bool? = nil) {
        self.id = id; self.label = label; self.description = description; self.isDefault = isDefault
    }
}

/// `ProviderOptionDescriptor` (model.ts:18-44): a `select` with choices or a `boolean`. Unknown
/// types decode and are ignored by the pickers.
public struct ProviderOptionDescriptor: Codable, Hashable, Sendable {
    public struct Kind: OpenStringEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let select: Self = "select"
        public static let boolean: Self = "boolean"
    }

    public var id: String
    public var label: String
    public var description: String?
    public var type: Kind
    public var options: [ProviderOptionChoice]
    public var currentValue: ProviderOptionValue?
    public var promptInjectedValues: [String]?

    public init(id: String, label: String, description: String? = nil, type: Kind, options: [ProviderOptionChoice] = [],
                currentValue: ProviderOptionValue? = nil, promptInjectedValues: [String]? = nil) {
        self.id = id; self.label = label; self.description = description; self.type = type; self.options = options
        self.currentValue = currentValue; self.promptInjectedValues = promptInjectedValues
    }

    private enum CodingKeys: String, CodingKey { case id, label, description, type, options, currentValue, promptInjectedValues }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        type = try c.decode(Kind.self, forKey: .type)
        options = try c.decodeIfPresent([ProviderOptionChoice].self, forKey: .options) ?? []
        currentValue = try c.decodeIfPresent(ProviderOptionValue.self, forKey: .currentValue)
        promptInjectedValues = try c.decodeIfPresent([String].self, forKey: .promptInjectedValues)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(type, forKey: .type)
        if type == .select { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(currentValue, forKey: .currentValue)
        try c.encodeIfPresent(promptInjectedValues, forKey: .promptInjectedValues)
    }
}

/// `ServerProviderModel` (server.ts:75-86). `capabilities` is `{optionDescriptors?} | null`; only
/// the descriptors are kept.
public struct ServerProviderModel: Decodable, Hashable, Sendable {
    public var slug: String
    public var name: String
    public var shortName: String?
    public var subProvider: String?
    public var aliases: [String]?
    /// `"new"` or absent.
    public var badge: String?
    public var isCustom: Bool
    public var isDefault: Bool?
    public var isLegacy: Bool?
    public var optionDescriptors: [ProviderOptionDescriptor]

    public init(slug: String, name: String, shortName: String? = nil, subProvider: String? = nil, aliases: [String]? = nil,
                badge: String? = nil, isCustom: Bool = false, isDefault: Bool? = nil, isLegacy: Bool? = nil,
                optionDescriptors: [ProviderOptionDescriptor] = []) {
        self.slug = slug; self.name = name; self.shortName = shortName; self.subProvider = subProvider; self.aliases = aliases
        self.badge = badge; self.isCustom = isCustom; self.isDefault = isDefault; self.isLegacy = isLegacy
        self.optionDescriptors = optionDescriptors
    }

    private enum CodingKeys: String, CodingKey { case slug, name, shortName, subProvider, aliases, badge, isCustom, isDefault, isLegacy, capabilities }
    private enum CapabilityKeys: String, CodingKey { case optionDescriptors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName)
        subProvider = try c.decodeIfPresent(String.self, forKey: .subProvider)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        isLegacy = try c.decodeIfPresent(Bool.self, forKey: .isLegacy)
        if (try? c.decodeNil(forKey: .capabilities)) == false, c.contains(.capabilities) {
            let caps = try c.nestedContainer(keyedBy: CapabilityKeys.self, forKey: .capabilities)
            optionDescriptors = try caps.decodeIfPresent([ProviderOptionDescriptor].self, forKey: .optionDescriptors) ?? []
        } else {
            optionDescriptors = []
        }
    }
}

/// `ServerProviderState` (server.ts): `ready`, `warning`, `error`, `disabled`, ...
public struct ServerProviderStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let ready: Self = "ready"
    public static let warning: Self = "warning"
    public static let error: Self = "error"
    public static let disabled: Self = "disabled"
}

/// `ServerProviderSlashCommand` (server.ts:102-112).
public struct ServerProviderSlashCommand: Codable, Hashable, Sendable {
    public struct Input: Codable, Hashable, Sendable { public var hint: String }
    public var name: String
    public var description: String?
    public var input: Input?
    public init(name: String, description: String? = nil, hint: String? = nil) {
        self.name = name; self.description = description; self.input = hint.map { Input(hint: $0) }
    }
}

/// `ServerProviderSkill` (server.ts:114-135).
public struct ServerProviderSkill: Codable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var path: String
    public var scope: String?
    public var enabled: Bool
    public var displayName: String?
    public var shortDescription: String?
    public var userInvocationOnly: Bool?
    public var userInvocable: Bool?
    public init(name: String, description: String? = nil, path: String, scope: String? = nil, enabled: Bool = true,
                displayName: String? = nil, shortDescription: String? = nil, userInvocable: Bool? = nil) {
        self.name = name; self.description = description; self.path = path; self.scope = scope; self.enabled = enabled
        self.displayName = displayName; self.shortDescription = shortDescription; self.userInvocable = userInvocable
    }
}

/// `ServerProviderWorkspaceSnapshot` (server.ts:137-145): skills and commands found under one cwd.
public struct ServerProviderWorkspaceSnapshot: Codable, Hashable, Sendable {
    public var cwd: String
    public var checkedAt: String
    public var slashCommands: [ServerProviderSlashCommand]
    public var slashCommandsPending: Bool?
    public var skills: [ServerProviderSkill]
}

/// `ServerProvider` (server.ts:213-300), one configured provider instance. Fields nothing here
/// reads (auth, usage limits, advisories) are skipped.
public struct ServerProvider: Decodable, Hashable, Sendable {
    public var instanceId: ProviderInstanceId
    /// Driver kind slug (`claudeAgent`, `codex`, ...). Picks the icon; never a routing key.
    public var driver: String
    public var displayName: String?
    public var accentColor: String?
    public var badgeLabel: String?
    public var continuationGroupKey: String?
    public var showInteractionModeToggle: Bool?
    public var reportsContextWindow: Bool?
    public var supportsConversationRollback: Bool?
    /// Absent or empty means every mode. Unknown values are dropped, like `ForwardCompatibleArray`.
    public var supportedRuntimeModes: [RuntimeMode]?
    public var requiresNewThreadForModelChange: Bool?
    public var enabled: Bool
    public var installed: Bool
    public var status: ServerProviderStatus
    public var message: String?
    /// `available` or `unavailable`; absent means available.
    public var availability: String?
    public var models: [ServerProviderModel]
    public var slashCommands: [ServerProviderSlashCommand] = []
    public var skills: [ServerProviderSkill] = []
    public var workspaceSnapshots: [ServerProviderWorkspaceSnapshot]?
    /// Settings > Providers: the CLI version, `auth` (`{status, type?, label?, email?}`) and the last probe.
    public var version: String?
    public var auth: JSONValue?
    public var checkedAt: String?
    /// `usageLimits`: the subscription windows the account reports (Usage > Limits, `/usage-limits`).
    public var usageLimits: ProviderUsageLimits?
    /// `updateState` (`ServerProviderUpdateState`, contracts server.ts:231-237): a one-click update's progress.
    public var updateState: UpdateState?
    /// `versionAdvisory.latestVersion`, the version an update installs.
    public var latestVersion: String?
    /// The whole `versionAdvisory` (`{status, latestVersion, updateCommand, canUpdate, canInstallVersion?, message}`): Settings > Providers.
    public var versionAdvisory: JSONValue?
    /// `compatibilityAdvisory` (`{status: supported|unsupported|broken, message?}`) and `setup`
    /// (`{canAuthenticate?, canInstall?}`): the composer's provider status banner reads them.
    public var compatibilityAdvisory: JSONValue?
    public var setup: JSONValue?

    public struct UpdateState: Hashable, Sendable {
        /// `queued`, `running`, `succeeded`, `failed` or `unchanged`.
        public var status: String
        public var finishedAt: String?
        public var message: String?
        public init(status: String, finishedAt: String? = nil, message: String? = nil) {
            self.status = status; self.finishedAt = finishedAt; self.message = message
        }
    }

    public init(instanceId: ProviderInstanceId, driver: String, displayName: String? = nil, enabled: Bool = true,
                installed: Bool = true, status: ServerProviderStatus = .ready, models: [ServerProviderModel] = []) {
        self.instanceId = instanceId; self.driver = driver; self.displayName = displayName; self.enabled = enabled
        self.installed = installed; self.status = status; self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId, driver, displayName, accentColor, badgeLabel, continuation, showInteractionModeToggle
        case supportsConversationRollback, reportsContextWindow, supportedRuntimeModes, requiresNewThreadForModelChange, enabled, installed
        case status, message, availability, models, slashCommands, skills, workspaceSnapshots, version, auth, checkedAt, usageLimits
        case updateState, versionAdvisory, compatibilityAdvisory, setup
    }
    private enum ContinuationKeys: String, CodingKey { case groupKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try c.decode(ProviderInstanceId.self, forKey: .instanceId)
        driver = try c.decode(String.self, forKey: .driver)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
        badgeLabel = try c.decodeIfPresent(String.self, forKey: .badgeLabel)
        if c.contains(.continuation), (try? c.decodeNil(forKey: .continuation)) == false {
            continuationGroupKey = try c.nestedContainer(keyedBy: ContinuationKeys.self, forKey: .continuation)
                .decodeIfPresent(String.self, forKey: .groupKey)
        }
        showInteractionModeToggle = try c.decodeIfPresent(Bool.self, forKey: .showInteractionModeToggle)
        reportsContextWindow = try c.decodeIfPresent(Bool.self, forKey: .reportsContextWindow)
        supportsConversationRollback = try c.decodeIfPresent(Bool.self, forKey: .supportsConversationRollback)
        supportedRuntimeModes = try c.decodeIfPresent([RuntimeMode].self, forKey: .supportedRuntimeModes)?
            .filter { RuntimeMode.all.contains($0) }
        requiresNewThreadForModelChange = try c.decodeIfPresent(Bool.self, forKey: .requiresNewThreadForModelChange)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        status = try c.decode(ServerProviderStatus.self, forKey: .status)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        availability = try c.decodeIfPresent(String.self, forKey: .availability)
        models = try c.decodeIfPresent([ServerProviderModel].self, forKey: .models) ?? []
        // Lenient: a malformed entry drops the list, never the provider.
        slashCommands = (try? c.decodeIfPresent([ServerProviderSlashCommand].self, forKey: .slashCommands)) ?? []
        skills = (try? c.decodeIfPresent([ServerProviderSkill].self, forKey: .skills)) ?? []
        workspaceSnapshots = try? c.decodeIfPresent([ServerProviderWorkspaceSnapshot].self, forKey: .workspaceSnapshots)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        auth = try? c.decodeIfPresent(JSONValue.self, forKey: .auth)
        checkedAt = try? c.decodeIfPresent(String.self, forKey: .checkedAt)
        usageLimits = ProviderUsageLimits(json: (try? c.decodeIfPresent(JSONValue.self, forKey: .usageLimits)) ?? nil)
        if let update = (try? c.decodeIfPresent(JSONValue.self, forKey: .updateState)) ?? nil, let status = update["status"]?.stringValue {
            updateState = UpdateState(status: status, finishedAt: update["finishedAt"]?.stringValue, message: update["message"]?.stringValue)
        }
        versionAdvisory = (try? c.decodeIfPresent(JSONValue.self, forKey: .versionAdvisory)) ?? nil
        latestVersion = versionAdvisory?["latestVersion"]?.stringValue
        compatibilityAdvisory = (try? c.decodeIfPresent(JSONValue.self, forKey: .compatibilityAdvisory)) ?? nil
        setup = (try? c.decodeIfPresent(JSONValue.self, forKey: .setup)) ?? nil
    }

    /// `resolveProviderSkillsForCwd`: the workspace snapshot's skills, else the provider's.
    public func skills(cwd: String?) -> [ServerProviderSkill] { workspaceSnapshot(cwd)?.skills ?? skills }
    /// `resolveProviderSlashCommandsForCwd`.
    public func slashCommands(cwd: String?) -> [ServerProviderSlashCommand] { workspaceSnapshot(cwd)?.slashCommands ?? slashCommands }
    public func workspaceSnapshot(_ cwd: String?) -> ServerProviderWorkspaceSnapshot? {
        guard let cwd else { return nil }
        return workspaceSnapshots?.first { $0.cwd == cwd }
    }
}

/// The `ServerSettings` fields that seed a new thread's selection (contracts settings.ts:1116-1171).
public struct ServerThreadDefaults: Decodable, Hashable, Sendable {
    public var defaultModelSelection: ModelSelection?
    public var defaultRuntimeMode: RuntimeMode
    /// `environmentIcon`: the machine kind the user picked for this environment, or nil for the detected one.
    public var environmentIcon: String?
    /// The whole settings object as sent, for the Settings pages (`ServerSettingsValues`).
    public var raw: JSONValue = .null

    public init(defaultModelSelection: ModelSelection? = nil, defaultRuntimeMode: RuntimeMode = .fullAccess, environmentIcon: String? = nil,
                raw: JSONValue = .null) {
        self.defaultModelSelection = defaultModelSelection
        self.defaultRuntimeMode = defaultRuntimeMode
        self.environmentIcon = environmentIcon
        self.raw = raw
    }

    private enum CodingKeys: String, CodingKey { case defaultModelSelection, defaultRuntimeMode, environmentIcon }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultModelSelection = try c.decodeIfPresent(ModelSelection.self, forKey: .defaultModelSelection)
        defaultRuntimeMode = try c.decodeIfPresent(RuntimeMode.self, forKey: .defaultRuntimeMode) ?? .fullAccess
        // `ForwardCompatibleNullable`: an unknown kind reads as no override.
        let icon = try? c.decodeIfPresent(String.self, forKey: .environmentIcon)
        environmentIcon = icon.flatMap { ["server", "cloud", "linux", "desktop", "laptop", "mac-mini", "mac-studio"].contains($0) ? $0 : nil }
        raw = (try? JSONValue(from: decoder)) ?? .null
    }
}

/// `ServerConfig` reduced to providers and the thread defaults. The full reply is about 80 KB.
public struct ServerProviderConfig: Decodable, Hashable, Sendable {
    public var providers: [ServerProvider]
    public var settings: ServerThreadDefaults
    /// `keybindings`: the server's resolved rules (its defaults merged with the user's keybindings.json).
    public var keybindings: [ResolvedKeybindingRule]
    /// `environment.capabilities` booleans (threadAutoSettlement, threadRestartContinuation, ...).
    public var capabilities: Set<String> = []
    /// `keybindingsConfigPath`: the server's keybindings.json.
    public var keybindingsConfigPath: String?
    /// `usageLimitSources`: never in a snapshot; `usageLimitSourcesUpdated` fills it and it survives snapshots.
    public var usageLimitSources: [UsageLimitSourceSnapshot] = []
    /// `environment.platform.os` (`darwin`, `linux`, `win32`).
    public var platformOS: String?
    /// `availableEditors`: the editor ids the server found on its machine (`EditorId`, e.g. `file-manager`).
    public var availableEditors: [String] = []
    public var remoteOpenTargets: [JSONValue] = []
    /// `shellRevealInFileManager`: `shell.openInEditor` honors `reveal: true`.
    public var revealsInFileManager = false
    /// `scratchWorkspaceRoot`: the folder threads without a project live in, nil when the server offers none.
    public var scratchWorkspaceRoot: String?
    /// `newProjectsRoot`: where "New project" creates name-only projects, nil when the server offers none.
    public var newProjectsRoot: String?

    public init(providers: [ServerProvider], settings: ServerThreadDefaults = ServerThreadDefaults(), keybindings: [ResolvedKeybindingRule] = [],
                capabilities: Set<String> = [], keybindingsConfigPath: String? = nil) {
        self.providers = providers
        self.settings = settings
        self.keybindings = keybindings
        self.capabilities = capabilities
        self.keybindingsConfigPath = keybindingsConfigPath
    }

    private enum CodingKeys: String, CodingKey {
        case providers, settings, keybindings, environment, keybindingsConfigPath, availableEditors, remoteOpenTargets, shellRevealInFileManager,
             scratchWorkspaceRoot, newProjectsRoot, threadFind, threadFindProgressive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([ServerProvider].self, forKey: .providers) ?? []
        settings = try c.decodeIfPresent(ServerThreadDefaults.self, forKey: .settings) ?? ServerThreadDefaults()
        keybindings = Keymap.decodeRules(try c.decodeIfPresent(JSONValue.self, forKey: .keybindings))
        let environment = try? c.decodeIfPresent(JSONValue.self, forKey: .environment)
        platformOS = environment?["platform"]?["os"]?.stringValue
        capabilities = Set((environment?["capabilities"]?.objectValue ?? [:]).compactMap { $0.value.boolValue == true ? $0.key : nil })
        // These flags live at ServerConfig's top level (server.ts:687-688).
        if try c.decodeIfPresent(Bool.self, forKey: .threadFind) == true { capabilities.insert("threadFind") }
        if try c.decodeIfPresent(Bool.self, forKey: .threadFindProgressive) == true { capabilities.insert("threadFindProgressive") }
        keybindingsConfigPath = try? c.decodeIfPresent(String.self, forKey: .keybindingsConfigPath)
        availableEditors = (try? c.decodeIfPresent([String].self, forKey: .availableEditors)) ?? []
        remoteOpenTargets = (try? c.decodeIfPresent([JSONValue].self, forKey: .remoteOpenTargets)) ?? []
        revealsInFileManager = (try? c.decodeIfPresent(Bool.self, forKey: .shellRevealInFileManager)) ?? false
        scratchWorkspaceRoot = try? c.decodeIfPresent(String.self, forKey: .scratchWorkspaceRoot)
        newProjectsRoot = try? c.decodeIfPresent(String.self, forKey: .newProjectsRoot)
    }
}

/// One `subscribeServerConfig` event (server.ts:784-853), the kinds the pickers follow. A snapshot
/// replaces the config; `providerStatuses` replaces the providers; `settingsUpdated` the defaults.
public enum ServerConfigEvent: Decodable, Sendable {
    case snapshot(ServerProviderConfig)
    case providerStatuses([ServerProvider])
    case settingsUpdated(ServerThreadDefaults)
    /// `keybindingsUpdated` (server.ts:791-796): the whole resolved list after keybindings.json changed.
    case keybindingsUpdated([ResolvedKeybindingRule])
    case keybindingsInvalid([ResolvedKeybindingRule], String)
    /// `usageLimitSourcesUpdated` (server.ts:830-843), sent to subscribers that pass `usageLimitSources: true`.
    case usageLimitSourcesUpdated([UsageLimitSourceSnapshot])
    case other(String)

    private enum CodingKeys: String, CodingKey { case type, config, providers, settings, payload, keybindings, sources, issues }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "snapshot": self = .snapshot(try c.decode(ServerProviderConfig.self, forKey: .config))
        // Updates carry their fields in `payload` (apps/server/src/ws.ts:2955-3035).
        case "providerStatuses":
            let payload = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
            self = .providerStatuses(try payload.decode([ServerProvider].self, forKey: .providers))
        case "settingsUpdated":
            let payload = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
            self = .settingsUpdated(try payload.decode(ServerThreadDefaults.self, forKey: .settings))
        case "keybindingsUpdated":
            let payload = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
            let rules = Keymap.decodeRules(try payload.decodeIfPresent(JSONValue.self, forKey: .keybindings))
            let issues = try payload.decodeIfPresent([JSONValue].self, forKey: .issues) ?? []
            if let issue = issues.first(where: { $0["kind"]?.stringValue?.hasPrefix("keybindings.") == true }) {
                self = .keybindingsInvalid(rules, issue["message"]?.stringValue ?? "Invalid keybindings configuration")
            } else { self = .keybindingsUpdated(rules) }
        case "usageLimitSourcesUpdated":
            let payload = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
            self = .usageLimitSourcesUpdated(UsageLimitSourceSnapshot.list(try payload.decodeIfPresent(JSONValue.self, forKey: .sources)))
        default: self = .other(type)
        }
    }
}

extension ModelSelection {
    /// Builds the wire selection like `createModelSelection` (packages/shared/src/model.ts:474-485):
    /// the `options` key is omitted when there are none.
    public init(instanceId: ProviderInstanceId, model: String, selections: [ProviderOptionSelection]?) {
        let encoded: JSONValue? = (selections?.isEmpty ?? true) ? nil : .array(selections!.map { s in
            let value: JSONValue = switch s.value { case .string(let v): .string(v); case .bool(let b): .bool(b) }
            return .object(["id": .string(s.id), "value": value])
        })
        self.init(instanceId: instanceId, model: model, options: encoded)
    }

    /// `options` as selections. Accepts the array form and the legacy object form
    /// (`{effort:"max", fastMode:true}`, model.ts:55-80).
    public var optionSelections: [ProviderOptionSelection] {
        func value(_ v: JSONValue) -> ProviderOptionValue? {
            switch v {
            case .string(let s): s.isEmpty ? nil : .string(s)
            case .bool(let b): .bool(b)
            default: nil
            }
        }
        switch options {
        case .array(let items):
            return items.compactMap { item in
                guard let id = item["id"]?.stringValue, let raw = item["value"], let v = value(raw) else { return nil }
                return ProviderOptionSelection(id: id, value: v)
            }
        case .object(let fields):
            return fields.keys.sorted().compactMap { key in value(fields[key]!).map { ProviderOptionSelection(id: key, value: $0) } }
        default:
            return []
        }
    }
}
