import Foundation
import Testing
@testable import Features
@testable import T3Store

/// The store's side of the settings sync: the first launch stamps what you set before, edits are stamped, and settings
/// merged from other devices keep their own stamps.
@MainActor @Suite struct OrchestratorStoreSyncTests {
    @Test func firstLaunchMigratesAndEditsAreStamped() throws {
        let suite = "orchestrator-sync-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var before = OrchestratorConfig()
        before.name = "Ada"
        before.crewLimit = 2
        defaults.set(try JSONEncoder().encode(before), forKey: OrchestratorStore.defaultsKey)

        let store = OrchestratorStore(defaults: defaults)
        #expect(store.config == before)
        #expect(Set(store.stamps.keys) == ["name", "crewLimit"])
        #expect(store.stamps["name"]?.by == store.device)

        // A relaunch keeps the device id and the stamps, and migrates nothing again.
        let again = OrchestratorStore(defaults: defaults)
        #expect(again.device == store.device)
        #expect(again.stamps == store.stamps)

        again.now = { Date(timeIntervalSince1970: 2_000_000_000) }
        again.update { $0.askFirstMinutes = 30 }
        #expect(again.stamps["askFirstMinutes"] == .init(at: 2_000_000_000_000, by: again.device))
        again.update { $0.relayedAt["env-a:t1"] = 1 }
        #expect(again.stamps["relayedAt"] == nil)

        var merged = again.config
        merged.name = "Phone name"
        var stamps = again.stamps
        stamps["name"] = .init(at: 3, by: "phone")
        again.applyMerged(.init(config: merged, stamps: stamps, write: nil))
        #expect(again.stamps["name"] == .init(at: 3, by: "phone"))
        let reopened = OrchestratorStore(defaults: defaults)
        #expect(reopened.config.name == "Phone name")
        #expect(reopened.stamps["name"] == .init(at: 3, by: "phone"))
    }
}
