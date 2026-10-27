import Foundation
import Testing
import T3Protocol
@testable import Features

/// Audit SU1 (docs/research/responsiveness-audit-2026-10-26/settings-updates.md): two quick project-scope edits
/// against a server that, like T3, replaces a project's whole override entry and answers late.
@MainActor
struct SettingsWriteQueueTests {
    /// `server.updateSettings` with T3's whole-entry replacement for `projectSettingsOverrides`
    /// (serverSettings.ts:259-278, projectSettings.test.ts:269-295), answering after a delay.
    @MainActor final class Server {
        var raw = SettingsProjectTests.json(#"{"projectSettingsFolded": true, "projectSettingsOverrides": {"fleet": {"branchNamePrefix": "x"}}}"#)

        func update(_ patch: [String: JSONValue]) async -> JSONValue {
            try? await Task.sleep(for: .milliseconds(30))
            guard case .object(var settings) = raw else { return raw }
            for (key, value) in patch {
                if key == "projectSettingsOverrides", case .object(let entries) = value, case .object(var current)? = settings[key] {
                    for (id, entry) in entries { current[id] = entry == .null ? nil : entry }
                    settings[key] = .object(current)
                } else {
                    settings[key] = value
                }
            }
            raw = .object(settings)
            return raw
        }

        var fleet: JSONValue? { raw["projectSettingsOverrides"]?["fleet"] }
    }

    static func scope(_ raw: JSONValue) -> SettingsScopeState {
        SettingsProjectTests.scope([SettingsProjectTests.env("server", String(decoding: try! JSONEncoder().encode(raw), as: UTF8.self))],
                                   machine: "server")
    }

    /// The bug as it was: both plans come from one snapshot, so the second reply erases the first edit.
    @Test func plansFromOneSnapshotEraseEachOther() async {
        let server = Server()
        let known = server.raw
        let first = Self.scope(known).plan(["enableAgentBrowserAccess": .bool(true)]).writes
        let second = Self.scope(known).plan(["defaultAutoPull": .bool(true)]).writes
        async let a = server.update(first[0].patch)
        async let b = server.update(second[0].patch)
        _ = await (a, b)
        #expect(server.fleet?["enableAgentBrowserAccess"] == nil)
    }

    @Test func queuedEditsPlanFromTheLastReplyAndBothSurvive() async {
        let server = Server()
        var known = server.raw
        let queue = SettingsWriteQueue()
        for patch: [String: JSONValue] in [["enableAgentBrowserAccess": .bool(true)], ["defaultAutoPull": .bool(true)]] {
            queue.enqueue {
                for write in Self.scope(known).plan(patch).writes { known = await server.update(write.patch) }
            }
        }
        await queue.settled()
        #expect(server.fleet?["enableAgentBrowserAccess"] == .bool(true))
        #expect(server.fleet?["defaultAutoPull"] == .bool(true))
        #expect(server.fleet?["branchNamePrefix"] == .string("x"), "an override set before both edits stays")
    }
}
