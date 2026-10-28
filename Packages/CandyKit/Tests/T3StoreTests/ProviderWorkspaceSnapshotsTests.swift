import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct ProviderWorkspaceSnapshotsTests {
    @Test func refreshOptInsRequireAnAdvertisedCapability() {
        let input: JSONValue = .object(["instanceId": .string("claude"), "cwd": .string("/one")])
        #expect(ProviderWorkspaceSnapshots.refreshInput(input, capabilities: []) == input)
        let next = ProviderWorkspaceSnapshots.refreshInput(input, capabilities: ["providerWorkspaceSnapshotsOnDemand"])
        #expect(next["workspaceSnapshotsOnDemand"] == .bool(true) && next["usageLimitsCommand"] == .bool(true))
        #expect(next["cwd"] == input["cwd"])
    }

    func provider(_ id: String = "claude", cwd: String? = nil) throws -> ServerProvider {
        var provider = ServerProvider(instanceId: ProviderInstanceId(id), driver: "claudeAgent")
        if let cwd {
            let json: JSONValue = .object(["cwd": .string(cwd), "checkedAt": .string("2026-10-28T10:00:00Z"),
                                           "slashCommands": .array([]), "skills": .array([])])
            provider.workspaceSnapshots = [try json.decode(as: ServerProviderWorkspaceSnapshot.self)]
        }
        return provider
    }

    @Test func retainsFetchedWorkspacesAndInvalidatesChangedProviderBasis() throws {
        var cache = ProviderWorkspaceSnapshots()
        let basis = try provider()
        cache.record(instanceId: basis.instanceId, cwd: "/one", fresh: false, providers: [try provider(cwd: "/one")], basis: basis)
        #expect(cache.merging(ServerProviderConfig(providers: [basis])).providers[0].workspaceSnapshots == nil)
        var config = ServerProviderConfig(providers: [basis], capabilities: ["providerWorkspaceSnapshotsOnDemand"])
        #expect(cache.merging(config).providers[0].workspaceSnapshot("/one") != nil)
        config.providers[0].enabled = false
        #expect(cache.merging(config).providers[0].workspaceSnapshots == nil)
        config.providers[0] = basis
        config.providers[0].slashCommands = [.init(name: "new", description: nil)]
        #expect(cache.merging(config).providers[0].workspaceSnapshots == nil)
    }

    @Test func freshScansDropOtherProvidersAndMissingRepliesDropTheRequestedWorkspace() throws {
        var cache = ProviderWorkspaceSnapshots()
        let a = try provider(), b = try provider("other")
        let config = ServerProviderConfig(providers: [a, b], capabilities: ["providerWorkspaceSnapshotsOnDemand"])
        for p in [a, b] {
            cache.record(instanceId: p.instanceId, cwd: "/one", fresh: false, providers: [try provider(p.instanceId.rawValue, cwd: "/one")], basis: p)
        }
        #expect(cache.merging(config).providers.allSatisfy { $0.workspaceSnapshot("/one") != nil })
        cache.record(instanceId: a.instanceId, cwd: "/one", fresh: true, providers: [try provider(cwd: "/one")], basis: a)
        #expect(cache.merging(config).providers[1].workspaceSnapshots == nil)
        let decorated = cache.merging(config)
        cache.record(instanceId: a.instanceId, cwd: "/one", fresh: false, providers: [a], basis: a)
        #expect(cache.merging(config).providers[0].workspaceSnapshots == nil)
        #expect(cache.merging(decorated).providers[0].workspaceSnapshots == nil)
    }

    @Test func retainsAtMost32Snapshots() throws {
        var cache = ProviderWorkspaceSnapshots()
        let basis = try provider()
        for i in 0..<33 {
            cache.record(instanceId: basis.instanceId, cwd: "/\(i)", fresh: false, providers: [try provider(cwd: "/\(i)")], basis: basis)
        }
        let merged = cache.merging(ServerProviderConfig(providers: [basis], capabilities: ["providerWorkspaceSnapshotsOnDemand"]))
        #expect(merged.providers[0].workspaceSnapshots?.count == 32)
        #expect(merged.providers[0].workspaceSnapshot("/0") == nil)
    }
}
