import T3Protocol

/// Client-fetched workspace data survives config pushes only while its provider-wide basis matches.
/// T3 3814: packages/client-runtime/src/state/server.ts:656-742.
public struct ProviderWorkspaceSnapshots: Sendable {
    private struct Entry: Sendable {
        var instanceId: ProviderInstanceId
        var snapshot: ServerProviderWorkspaceSnapshot
        var enabled: Bool
        var slashCommands: [ServerProviderSlashCommand]
        var skills: [ServerProviderSkill]
        var models: [ServerProviderModel]

        // The machine's models are part of the basis since 4928 (client-runtime state/server.ts:683, #24585).
        func matches(_ provider: ServerProvider) -> Bool {
            enabled == provider.enabled && slashCommands == provider.slashCommands && skills == provider.skills && models == provider.models
        }
    }
    private var entries: [Entry] = []
    public init() {}

    public static func refreshInput(_ input: JSONValue, capabilities: Set<String>) -> JSONValue {
        guard capabilities.contains("providerWorkspaceSnapshotsOnDemand"), case .object(var fields) = input else { return input }
        fields["workspaceSnapshotsOnDemand"] = .bool(true)
        fields["usageLimitsCommand"] = .bool(true)
        return .object(fields)
    }

    public mutating func record(instanceId: ProviderInstanceId, cwd: String, fresh: Bool,
                                providers: [ServerProvider], basis: ServerProvider?) {
        entries.removeAll { $0.snapshot.cwd == cwd && (fresh || $0.instanceId == instanceId) }
        guard let basis, let snapshot = providers.first(where: { $0.instanceId == instanceId })?.workspaceSnapshot(cwd) else { return }
        entries.append(Entry(instanceId: instanceId, snapshot: snapshot, enabled: basis.enabled, slashCommands: basis.slashCommands, skills: basis.skills,
                             models: basis.models))
        if entries.count > 32 { entries.removeFirst(entries.count - 32) }
    }

    public func merging(_ config: ServerProviderConfig) -> ServerProviderConfig {
        guard config.capabilities.contains("providerWorkspaceSnapshotsOnDemand") else { return config }
        var config = config
        config.providers = config.providers.map { provider in
            let snapshots = entries.filter { $0.instanceId == provider.instanceId && $0.matches(provider) }.map(\.snapshot)
            var provider = provider
            provider.workspaceSnapshots = snapshots.isEmpty ? nil : snapshots
            return provider
        }
        return config
    }
}
