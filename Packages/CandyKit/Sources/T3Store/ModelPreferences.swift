import T3Protocol

/// Model favorites, hidden models and model order. Servers from 2994 keep them in server settings
/// and share them across clients (f84589527, contracts settings.ts:1084-1089); older servers leave
/// them to each client. `settings` is the server settings object as sent.
public enum ModelPreferences {
    /// The server has the keys. A 2994 server sends `favorites` as null until a client migrates.
    public static func serverOwned(_ settings: JSONValue) -> Bool { settings.objectValue?["favorites"] != nil }

    /// `resolveModelPreferences` (packages/shared/src/serverSettings.ts:650-659): the server's list
    /// once it has one, else this client's.
    public static func favorites(_ settings: JSONValue, local: [ModelFavorite]) -> [ModelFavorite] {
        guard let list = settings["favorites"]?.arrayValue else { return local }
        return list.compactMap { f in
            guard let p = f["provider"]?.stringValue, let m = f["model"]?.stringValue else { return nil }
            return ModelFavorite(provider: ProviderInstanceId(rawValue: p), model: m)
        }
    }

    public static func providerPreferences(_ settings: JSONValue, local: JSONValue) -> JSONValue {
        if let server = settings["providerModelPreferences"], server.objectValue != nil { return server }
        return local
    }

    static func json(_ favorites: [ModelFavorite]) -> JSONValue {
        .array(favorites.map { .object(["provider": .string($0.provider.rawValue), "model": .string($0.model)]) })
    }

    /// `modelPreferencesMigrationPatch` (serverSettings.ts:662-685): seeds what the server has not
    /// saved yet from this client, once. Empty local lists claim nothing.
    public static func migrationPatch(_ settings: JSONValue, local favorites: [ModelFavorite], localPreferences: JSONValue) -> [String: JSONValue]? {
        guard serverOwned(settings) else { return nil }
        var migrate: [String: JSONValue] = [:]
        if settings["favorites"] == .null, !favorites.isEmpty { migrate["favorites"] = json(favorites) }
        if settings["providerModelPreferences"] ?? .null == .null, let p = localPreferences.objectValue, !p.isEmpty {
            migrate["providerModelPreferences"] = localPreferences
        }
        return migrate.isEmpty ? nil : ["migrateModelPreferences": .object(migrate)]
    }

    /// `useToggleEnvironmentModelFavorite` (apps/web/src/hooks/useSettings.ts:467-532): sends the
    /// wanted state so two clients adding a favorite don't cancel each other, plus the migration.
    public static func favoritePatch(_ settings: JSONValue, local: [ModelFavorite], localPreferences: JSONValue,
                                     provider: ProviderInstanceId, model: String) -> (patch: JSONValue, favorites: [ModelFavorite]) {
        var current = favorites(settings, local: local)
        let on = !current.contains { $0.provider == provider && $0.model == model }
        if on { current.append(ModelFavorite(provider: provider, model: model)) } else {
            current.removeAll { $0.provider == provider && $0.model == model }
        }
        var patch = migrationPatch(settings, local: local, localPreferences: localPreferences) ?? [:]
        patch["setModelFavorites"] = .array([.object(["provider": .string(provider.rawValue), "model": .string(model), "favorite": .bool(on)])])
        return (.object(patch), current)
    }

    /// One instance's hidden models and order. `ProviderSettingsPanel.tsx:1080-1106` sends
    /// `setModelsHidden` for the models that changed and `setProviderModelOrder` for a new order.
    public static func preferencesPatch(_ settings: JSONValue, local: [ModelFavorite], localPreferences: JSONValue,
                                        instanceId: String, hidden: [String], order: [String]) -> JSONValue {
        let prior = providerPreferences(settings, local: localPreferences)[instanceId]
        let priorHidden = Set((prior?["hiddenModels"]?.arrayValue ?? []).compactMap(\.stringValue))
        let priorOrder = (prior?["modelOrder"]?.arrayValue ?? []).compactMap(\.stringValue)
        var patch = migrationPatch(settings, local: local, localPreferences: localPreferences) ?? [:]
        let next = Set(hidden)
        let changed = priorHidden.symmetricDifference(next).sorted()
        if !changed.isEmpty {
            patch["setModelsHidden"] = .array(changed.map {
                .object(["provider": .string(instanceId), "model": .string($0), "hidden": .bool(next.contains($0))])
            })
        }
        if order != priorOrder {
            patch["setProviderModelOrder"] = .object(["provider": .string(instanceId), "modelOrder": .array(order.map(JSONValue.string))])
        }
        return .object(patch)
    }

    /// Settings with the resolved lists written in, shown until the server's reply replaces them.
    public static func applying(_ settings: JSONValue, favorites: [ModelFavorite]? = nil,
                                instanceId: String? = nil, hidden: [String] = [], order: [String] = [], localPreferences: JSONValue = .object([:])) -> JSONValue {
        guard var o = settings.objectValue else { return settings }
        if let favorites { o["favorites"] = json(favorites) }
        if let instanceId {
            var all = providerPreferences(settings, local: localPreferences).objectValue ?? [:]
            all[instanceId] = .object(["hiddenModels": .array(hidden.map(JSONValue.string)), "modelOrder": .array(order.map(JSONValue.string))])
            o["providerModelPreferences"] = .object(all)
        }
        return .object(o)
    }
}
