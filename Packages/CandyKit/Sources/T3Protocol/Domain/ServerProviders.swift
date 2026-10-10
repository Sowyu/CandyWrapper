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

/// `ServerProvider` (server.ts:213-300), one configured provider instance. Fields the pickers don't
/// read (auth, skills, slash commands, usage limits, advisories) are skipped.
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

    public init(instanceId: ProviderInstanceId, driver: String, displayName: String? = nil, enabled: Bool = true,
                installed: Bool = true, status: ServerProviderStatus = .ready, models: [ServerProviderModel] = []) {
        self.instanceId = instanceId; self.driver = driver; self.displayName = displayName; self.enabled = enabled
        self.installed = installed; self.status = status; self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId, driver, displayName, accentColor, badgeLabel, continuation, showInteractionModeToggle
        case reportsContextWindow, supportedRuntimeModes, requiresNewThreadForModelChange, enabled, installed
        case status, message, availability, models
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
        supportedRuntimeModes = try c.decodeIfPresent([RuntimeMode].self, forKey: .supportedRuntimeModes)?
            .filter { RuntimeMode.all.contains($0) }
        requiresNewThreadForModelChange = try c.decodeIfPresent(Bool.self, forKey: .requiresNewThreadForModelChange)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        status = try c.decode(ServerProviderStatus.self, forKey: .status)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        availability = try c.decodeIfPresent(String.self, forKey: .availability)
        models = try c.decodeIfPresent([ServerProviderModel].self, forKey: .models) ?? []
    }
}

/// The `ServerSettings` fields that seed a new thread's selection (contracts settings.ts:1116-1171).
public struct ServerThreadDefaults: Decodable, Hashable, Sendable {
    public var defaultModelSelection: ModelSelection?
    public var defaultRuntimeMode: RuntimeMode

    public init(defaultModelSelection: ModelSelection? = nil, defaultRuntimeMode: RuntimeMode = .fullAccess) {
        self.defaultModelSelection = defaultModelSelection
        self.defaultRuntimeMode = defaultRuntimeMode
    }

    private enum CodingKeys: String, CodingKey { case defaultModelSelection, defaultRuntimeMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultModelSelection = try c.decodeIfPresent(ModelSelection.self, forKey: .defaultModelSelection)
        defaultRuntimeMode = try c.decodeIfPresent(RuntimeMode.self, forKey: .defaultRuntimeMode) ?? .fullAccess
    }
}

/// `ServerConfig` reduced to providers and the thread defaults. The full reply is about 80 KB.
public struct ServerProviderConfig: Decodable, Hashable, Sendable {
    public var providers: [ServerProvider]
    public var settings: ServerThreadDefaults

    public init(providers: [ServerProvider], settings: ServerThreadDefaults = ServerThreadDefaults()) {
        self.providers = providers
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case providers, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([ServerProvider].self, forKey: .providers) ?? []
        settings = try c.decodeIfPresent(ServerThreadDefaults.self, forKey: .settings) ?? ServerThreadDefaults()
    }
}

/// One `subscribeServerConfig` event (server.ts:784-853), the kinds the pickers follow. A snapshot
/// replaces the config; `providerStatuses` replaces the providers; `settingsUpdated` the defaults.
public enum ServerConfigEvent: Decodable, Sendable {
    case snapshot(ServerProviderConfig)
    case providerStatuses([ServerProvider])
    case settingsUpdated(ServerThreadDefaults)
    case other(String)

    private enum CodingKeys: String, CodingKey { case type, config, providers, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "snapshot": self = .snapshot(try c.decode(ServerProviderConfig.self, forKey: .config))
        case "providerStatuses": self = .providerStatuses(try c.decode([ServerProvider].self, forKey: .providers))
        case "settingsUpdated": self = .settingsUpdated(try c.decode(ServerThreadDefaults.self, forKey: .settings))
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
