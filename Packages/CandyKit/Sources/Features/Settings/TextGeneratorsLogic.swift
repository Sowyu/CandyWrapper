import Foundation
import T3Protocol

/// Text generators (T3 eb97d82156, PR #33147): a model API that only writes short text, saved in the server
/// setting `textGenerators` keyed by an id from the provider instance namespace (contracts settings.ts, textGenerators.ts).
/// The API key goes once to the server's secret storage in `server.updateSettings`; the server sends back only its
/// redaction marker, and sending the marker back keeps the stored key. CandyWrapper never stores the key itself.
public enum TextGenerators {
    public struct Config: Equatable, Sendable {
        /// `openaiCompatible` or `anthropic`.
        public var kind: String
        public var label: String?
        public var baseUrl: String
        /// The literal key, the redaction marker for a saved one, or "".
        public var apiKey: String
        public var enabled: Bool
        public init(kind: String, label: String? = nil, baseUrl: String, apiKey: String = "", enabled: Bool = true) {
            self.kind = kind; self.label = label; self.baseUrl = baseUrl; self.apiKey = apiKey; self.enabled = enabled
        }
        public init?(_ json: JSONValue) {
            guard let kind = json["kind"]?.stringValue, let baseUrl = json["baseUrl"]?.stringValue else { return nil }
            self.init(kind: kind, label: json["label"]?.stringValue, baseUrl: baseUrl,
                      apiKey: json["apiKey"]?.stringValue ?? "", enabled: json["enabled"]?.boolValue ?? true)
        }
        public var json: JSONValue {
            var o: [String: JSONValue] = ["kind": .string(kind), "baseUrl": .string(baseUrl), "apiKey": .string(apiKey), "enabled": .bool(enabled)]
            if let label { o["label"] = .string(label) }
            return .object(o)
        }
    }

    public struct Preset: Equatable, Sendable {
        public let id: String, label: String, kind: String, baseUrl: String
    }
    /// `TEXT_GENERATOR_PRESETS` (textGenerators.ts:40-60).
    public static let presets: [Preset] = [
        Preset(id: "openai", label: "OpenAI", kind: "openaiCompatible", baseUrl: "https://api.openai.com/v1"),
        Preset(id: "openrouter", label: "OpenRouter", kind: "openaiCompatible", baseUrl: "https://openrouter.ai/api/v1"),
        Preset(id: "anthropic", label: "Anthropic", kind: "anthropic", baseUrl: "https://api.anthropic.com/v1"),
        Preset(id: "custom", label: "Custom (OpenAI-compatible)", kind: "openaiCompatible", baseUrl: ""),
    ]

    /// Whether a server knows text generators: 4928 sends `textGenerators` in its settings, 3824 does not.
    public static func supported(_ settings: ServerSettingsValues) -> Bool { settings.raw["textGenerators"] != nil }

    /// Saved generators in the server's key order.
    public static func list(_ settings: ServerSettingsValues) -> [(id: String, config: Config)] {
        guard case .object(let o)? = settings.raw["textGenerators"] else { return [] }
        return o.keys.sorted().compactMap { id in o[id].flatMap(Config.init).map { (id, $0) } }
    }

    /// `textGeneratorDisplayName` (textGenerators.ts:62-76).
    public static func displayName(_ c: Config) -> String {
        if let label = c.label, !label.isEmpty { return label }
        if let preset = presets.first(where: { $0.baseUrl == c.baseUrl && $0.kind == c.kind }) { return preset.label }
        return URL(string: c.baseUrl).flatMap { url in url.host.map { h in url.port.map { "\(h):\($0)" } ?? h } } ?? c.baseUrl
    }

    /// `textGeneratorBrand` (textGenerators.ts:78-95): the service, which picks the icon.
    public static func brand(kind: String, baseUrl: String) -> String {
        if kind == "anthropic" { return "anthropic" }
        let url = URL(string: baseUrl)
        let host = url?.host ?? ""
        if host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") { return "openrouter" }
        if host == "api.openai.com" { return "openai" }
        if url?.port == 11434 || host.contains("ollama") { return "ollama" }
        return "openaiCompatible"
    }

    /// The row's description: "Off · " for a disabled one, then the URL without its scheme.
    public static func rowDetail(_ c: Config) -> String {
        (c.enabled ? "" : "Off · ") + c.baseUrl.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
    }

    /// `nextTextGeneratorId` (textGenerators.ts:97-117): not a configured instance, a driver's default, or another generator.
    public static func nextId(_ base: String, settings: ServerSettingsValues, providers: [ServerProvider]) -> String {
        var taken = Set(settings.raw["providerInstances"]?.objectValue?.keys.map { $0 } ?? [])
        taken.formUnion(list(settings).map(\.id))
        taken.formUnion(providers.map(\.instanceId.rawValue))
        taken.formUnion(ProvidersLogic.drivers.map(\.driver))
        var id = base, suffix = 2
        while taken.contains(id) { id = "\(base)-\(suffix)"; suffix += 1 }
        return id
    }

    /// `TextGeneratorBaseUrl` (settings.ts): http or https, at most 2048 characters, no credentials, query or fragment.
    public static func validBaseUrl(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 2048, let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", c.host?.isEmpty == false else { return false }
        return c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
    }

    /// The wizard's form (TextGeneratorsSettings.tsx:266-345).
    public struct Draft: Equatable, Sendable {
        public var preset: Preset
        public var baseUrl: String
        public var label = ""
        public var key = ""
        /// The generator being edited, or nil for a new one.
        public var existing: Config?

        public init(existing: Config?) {
            self.existing = existing
            preset = presets[0]
            baseUrl = existing?.baseUrl ?? presets[0].baseUrl
            label = existing?.label ?? ""
        }

        public mutating func pick(_ p: Preset) { preset = p; baseUrl = p.baseUrl }

        /// A saved literal key arrives redacted; sending the marker back keeps it.
        var storedKey: String { existing?.apiKey ?? "" }
        var apiKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? storedKey : key.trimmingCharacters(in: .whitespacesAndNewlines) }
        public var keyRequired: Bool { existing == nil && preset.id != "custom" }
        public var keyConfigured: Bool { !storedKey.isEmpty }
        /// Presets know their URL; only a custom endpoint, or one already saved as such, asks for it.
        public var showsBaseUrl: Bool {
            guard let existing else { return preset.id == "custom" }
            return !["openai", "anthropic", "openrouter"].contains(brand(kind: existing.kind, baseUrl: existing.baseUrl))
        }
        public var config: Config? {
            let url = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validBaseUrl(url) else { return nil }
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return Config(kind: existing?.kind ?? preset.kind, label: name.isEmpty ? nil : name, baseUrl: url,
                          apiKey: apiKey, enabled: existing?.enabled ?? true)
        }
        public var canConnect: Bool { config != nil && (!keyRequired || !apiKey.isEmpty) }
        public var name: String { config.map(displayName) ?? preset.label }
    }

    /// The `Use it` step's tasks; voice transcript cleanup is left out with dictation.
    public static let tasks: [(key: String, label: String)] = [
        ("textGenerationModelSelection", "Thread titles and other generated text"),
        ("sourceControlWriterModelSelection", "Commit messages, pull requests, and branch names"),
    ]

    /// `server.listTextGeneratorModels` payload (`ListTextGeneratorModelsInput`).
    public static func listInput(id: String, config: Config? = nil, refresh: Bool = false, test: Bool = false, model: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let config { o["config"] = config.json }
        if refresh { o["refresh"] = .bool(true) }
        if test { o["test"] = .bool(true) }
        if let model { o["model"] = .string(model) }
        return .object(o)
    }

    /// `ListTextGeneratorModelsResult.models`.
    public static func models(_ result: JSONValue) -> [(id: String, name: String)] {
        (result["models"]?.arrayValue ?? []).compactMap { m in m["id"]?.stringValue.map { ($0, m["name"]?.stringValue ?? $0) } }
    }

    /// `textGeneratorSnapshot` (textGenerators.ts:256-292): a picker stand-in for an enabled generator. The listed models,
    /// then any selected model the list lacks, so a selection keeps its name while the list loads.
    public static func snapshot(id: String, config: Config, models: [(id: String, name: String)]?, error: String?, selected: [String]) -> ServerProvider {
        var listed = (models ?? []).map { ServerProviderModel(slug: $0.id, name: $0.name) }
        for slug in Set(selected).sorted() where !listed.contains(where: { $0.slug == slug }) { listed.append(ServerProviderModel(slug: slug, name: slug)) }
        var p = ServerProvider(instanceId: ProviderInstanceId(rawValue: id), driver: brand(kind: config.kind, baseUrl: config.baseUrl),
                               displayName: displayName(config), enabled: config.enabled, status: error == nil ? .ready : .error, models: listed)
        p.message = error
        return p
    }

    /// `useTextGenerationTargets`: providers that write text, a generator replacing an instance with its id, then the
    /// enabled generators.
    public static func targets(providers: [ServerProvider], generators: [(id: String, config: Config)],
                               models: [String: [(id: String, name: String)]], errors: [String: String], selected: [ModelSelection]) -> [ServerProvider] {
        let ids = Set(generators.map(\.id))
        // ponytail: keeps providers without `supportsTextGeneration` filtering, as the pickers did before; decode the field if one shows up wrongly
        let kept = providers.filter { !ids.contains($0.instanceId.rawValue) }
        return kept + generators.filter(\.config.enabled).map { g in
            snapshot(id: g.id, config: g.config, models: models[g.id], error: errors[g.id],
                     selected: selected.filter { $0.instanceId.rawValue == g.id }.map(\.model))
        }
    }
}
