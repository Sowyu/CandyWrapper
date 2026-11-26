import Foundation
import Testing
import T3Protocol
@testable import Features

/// A pass across this app's relaunch, from T3 5258 updateEverythingRun.test.ts and updateEverything.logic.test.ts
/// (#41964, #33002).
struct UpdatePassRestoreTests {
    typealias L = UpdateEverythingLogic
    let target = "0.0.50"

    func row(_ id: String, failed: Bool? = nil, updatesServer: Bool = true, handedOff: String? = nil) -> L.RunMachine {
        L.RunMachine(environmentId: id, label: id, updatesProviders: false, updatesServer: updatesServer, startedAt: 100,
                     failed: failed, handedOffVersion: handedOff)
    }

    /// The saved pass keeps every unfinished server with its target and update id, and leaves finished and provider-only rows out.
    @Test func savesUnfinishedServers() throws {
        let run = L.Run(localVersion: "1.2", phase: .installing, machines: [
            row("restarting"), row("done", failed: false), row("failed", failed: true), row("providers", updatesServer: false),
        ])
        let handedOff = L.handedOff(run) { $0.environmentId == "restarting" ? ("0.0.50", "u1") : nil }
        #expect(handedOff == [L.HandedOffServer(environmentId: "restarting", label: "restarting", targetVersion: "0.0.50", startedAt: 100, updateId: "u1")])
        let pass = L.SavedPass(savedAt: 1_000, result: L.Result(localVersion: "1.2", updatedServers: 1, updatedProviders: 0, failures: []), handedOff: handedOff)
        let data = try JSONEncoder().encode(pass)
        #expect(L.takeSaved(data, now: 1_000 + 60) == pass)
        #expect(L.takeSaved(data, now: 1_000 + L.savedMaxAge) == nil)
        // A result saved before the pass was kept still reads, with nothing to follow.
        let old = Data(#"{"savedAt":1000,"result":{"localVersion":"1.2","updatedServers":0,"updatedProviders":0,"failures":[]}}"#.utf8)
        #expect(L.takeSaved(old, now: 1_001)?.handedOff == nil)
    }

    /// A restored row shows restarting until it settles, then done or failed.
    @Test func restoredRowRestarts() throws {
        let server = L.HandedOffServer(environmentId: "a", label: "alvin", targetVersion: target, startedAt: 100, updateId: "u1")
        let run = try #require(L.restoredRun([server]))
        #expect(run.phase == .servers && run.localVersion == nil)
        #expect(L.status(run.machines[0], phase: run.phase, server: .idle) == .restarting)
        #expect(L.restoredRun([]) == nil)
    }

    /// The server is back on the target: done. Still on the old version with no outcome: still waiting.
    /// The launcher rolled the update back (#33002): failed with its reason, though the old version never matches.
    @Test func settlesFromVersionAndOutcome() {
        let s = L.HandedOffServer(environmentId: "a", label: "alvin", targetVersion: target, startedAt: 0, updateId: "u1")
        #expect(L.settlement(s, serverVersion: target, ready: nil) == .some(nil))
        #expect(L.settlement(s, serverVersion: "0.0.40", ready: nil) == nil)
        func ready(_ id: String, _ status: String, _ reason: String? = nil) -> ServerLifecycleReady {
            ServerLifecycleReady(serverVersion: "0.0.40", updateOutcome: .init(id: id, fromVersion: "0.0.40", targetVersion: target, status: status, reason: reason))
        }
        #expect(L.settlement(s, serverVersion: "0.0.40", ready: ready("u1", "rolled-back", "Trial did not become ready.")) == .some("Trial did not become ready."))
        #expect(L.settlement(s, serverVersion: "0.0.40", ready: ready("u1", "rolled-back")) == .some("The t3@0.0.50 update rolled-back."))
        // Another update's outcome, or a committed one still on its way up, ends nothing.
        #expect(L.settlement(s, serverVersion: "0.0.40", ready: ready("u0", "rolled-back")) == nil)
        #expect(L.settlement(s, serverVersion: "0.0.40", ready: ready("u1", "committed")) == nil)
        // Without an update id only the version can end it.
        var noId = s; noId.updateId = nil
        #expect(L.settlement(noId, serverVersion: "0.0.40", ready: ready("u1", "rolled-back")) == nil)
    }

    /// #41964: a restored failed row rebuilds its retry from the server as it is now.
    @Test func restoredRetry() {
        let failed = row("a", failed: true, updatesServer: false, handedOff: target)
        func now(_ version: String?, connected: Bool = true) -> [L.Machine] {
            [UpdateEverythingLogicTests.machine("a", version, .bootService, connected: connected)]
        }
        #expect(L.restoredRetry(failed, current: now(target)) == .current)
        #expect(L.restoredRetry(failed, current: now("0.0.40")) == .update)
        #expect(L.restoredRetry(failed, current: now("0.0.40", connected: false)) == nil)
        // A machine that is gone, or a row that is not a restored failure, retries nothing.
        #expect(L.restoredRetry(failed, current: []) == nil)
        #expect(L.restoredRetry(row("a", failed: true), current: now("0.0.40")) == nil)
        #expect(L.restoredRetry(row("a", updatesServer: false, handedOff: target), current: now("0.0.40")) == nil)

        let run = L.Run(localVersion: nil, phase: .servers, machines: [failed])
        let statuses = [L.MachineStatus.failed]
        #expect(L.describeCapsule(run, statuses: statuses, local: nil, now: 200).action == .dismiss)
        #expect(L.describeCapsule(run, statuses: statuses, local: nil, now: 200, restored: [.update]).action == .retry)
        #expect(L.describeCapsule(run, statuses: statuses, local: nil, now: 200, restored: [.current]).action == .retry)
    }

    @Test func toastNamesServersStillRestarting() {
        let r = L.Result(localVersion: "1.2", updatedServers: 0, updatedProviders: 0, failures: [])
        #expect(L.toast(r, appVersion: "1.2", restarting: ["alvin"])?.description == "alvin is still restarting.")
        #expect(L.toast(r, appVersion: "1.2", restarting: ["alvin", "bea"])?.description == "alvin and bea are still restarting.")
        var failed = r; failed.failures = ["studio: offline"]
        #expect(L.toast(failed, appVersion: "1.2", restarting: ["alvin"])?.description == "studio: offline\nalvin is still restarting.")
    }
}
