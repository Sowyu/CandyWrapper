import Foundation

/// `OrchestrationProjectShell` (packages/contracts/src/orchestrationProject.ts:9-27).
/// Fields the sidebar does not read (`scripts`, `projectIcon`) stay raw JSON.
public struct ProjectShell: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectId
    public var title: String
    public var workspaceRoot: String
    public var repositoryIdentity: RepositoryIdentity?
    public var defaultModelSelection: ModelSelection?
    public var defaultThreadEnvMode: String?
    public var autoPull: Bool?
    public var faviconPath: String?
    public var projectIcon: JSONValue?
    public var scripts: [JSONValue]
    public var createdAt: T3Timestamp
    public var updatedAt: T3Timestamp
}

/// `RepositoryIdentity` (packages/contracts/src/environment.ts:229-258).
public struct RepositoryIdentity: Codable, Hashable, Sendable {
    public struct Origin: Codable, Hashable, Sendable {
        public var canonicalKey: String
        public var displayName: String?
    }

    public var canonicalKey: String
    public var locator: JSONValue
    public var webUrl: String?
    public var rootPath: String?
    public var displayName: String?
    public var provider: String?
    public var owner: String?
    public var name: String?
    public var origin: Origin?

    /// `repositoryGroupingKeyOf` (environment.ts:262-264): a fork's own remote, else the repository.
    public var groupingKey: String { origin?.canonicalKey ?? canonicalKey }

    /// `repositoryGroupingDisplayNameOf` (environment.ts:267-271).
    public var groupingDisplayName: String? {
        if let origin { return origin.displayName ?? origin.canonicalKey }
        return displayName
    }
}

/// `ModelSelection` (packages/contracts/src/modelSelection.ts:10-60). Decoding accepts the
/// legacy `provider` key for `instanceId`; encoding always writes `instanceId`.
public struct ModelSelection: Codable, Hashable, Sendable {
    public var instanceId: ProviderInstanceId
    public var model: String
    public var options: JSONValue?

    public init(instanceId: ProviderInstanceId, model: String, options: JSONValue? = nil) {
        self.instanceId = instanceId
        self.model = model
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case instanceId, provider, model, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try c.decodeIfPresent(ProviderInstanceId.self, forKey: .instanceId)
            ?? c.decode(ProviderInstanceId.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        options = try c.decodeIfPresent(JSONValue.self, forKey: .options)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instanceId, forKey: .instanceId)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(options, forKey: .options)
    }
}
