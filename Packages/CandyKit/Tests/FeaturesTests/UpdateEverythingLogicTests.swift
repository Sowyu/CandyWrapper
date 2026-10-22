import Testing
import T3Protocol
@testable import Features

/// Ported from T3 3105 sidebar/updateEverything.logic.test.ts.
struct UpdateEverythingLogicTests {
    typealias L = UpdateEverythingLogic

    static func machine(_ id: String, _ version: String?, _ path: ServerSelfUpdateCapability?, connected: Bool = true,
                        canMaintain: Bool = true, updating: Bool = false, own: Bool = false) -> L.Machine {
        L.Machine(environmentId: id, label: id, serverVersion: version, connected: connected, canMaintain: canMaintain, updating: updating,
                  capabilities: ServerUpdateCapabilities(selfUpdate: path, desktopAppUpdate: path == .desktopManaged), ownServer: own)
    }

    @Test func targetsAndSkips() {
        let (targets, skipped) = L.serverTargets([
            Self.machine("service", "0.0.40", .bootService),
            Self.machine("nightly-service", "0.0.49-nightly.20261001.3", .bootService),
            Self.machine("other-desktop", "0.0.49-nightly.20261001.3", .desktopManaged),
            Self.machine("offline", "0.0.40", .bootService, connected: false),
            Self.machine("never-connected", nil, .bootService),
            Self.machine("no-scope", "0.0.40", .bootService, canMaintain: false),
            Self.machine("busy", "0.0.40", .bootService, updating: true),
            Self.machine("current", "0.0.50", .bootService),
            Self.machine("current-offline", "0.0.50", .bootService, connected: false),
            Self.machine("manual", "0.0.40", nil),
            Self.machine("own", "0.0.40", nil, own: true),
        ], target: "0.0.50")
        #expect(targets.map(\.label) == ["service", "other-desktop", "own"])
        #expect(skipped.map { [$0.label, $0.reason] } == [
            ["nightly-service", "on the nightly channel"], ["offline", "not connected"], ["never-connected", "not connected"],
            ["no-scope", "no permission"], ["busy", "already updating"], ["manual", "needs a manual update"],
        ])
    }

    @Test func describesThePass() {
        let alvin = Self.machine("alvin", "0.0.40", .bootService), studio = Self.machine("studio", "0.0.40", .desktopManaged)
        let d = L.describe(localVersion: "0.0.50", servers: [alvin, studio], target: "0.0.50",
                           providerMachines: [("alvin", "alvin", ["Codex", "Claude"]), ("box", "box", ["Cursor"])])
        #expect(d.summary == "Update this app, 2 servers, and 3 providers")
        #expect(d.lines == ["This app: 0.0.50, restarts last", "alvin: server to 0.0.50, Codex, Claude", "studio: desktop app update", "box: Cursor"])
        #expect(L.describe(localVersion: nil, servers: [], target: "x", providerMachines: [("a", "alvin", ["Codex"])]).summary == "Update 1 provider")
    }

    @Test func runStatusAndToast() {
        let m = L.RunMachine(environmentId: "a", label: "alvin", updatesProviders: true, updatesServer: true)
        #expect(L.status(m, phase: .providers, server: .idle) == .providers)
        #expect(L.status(m, phase: .servers, server: .idle) == .waiting)
        #expect(L.status(m, phase: .servers, server: .running(stage: .resuming, fromVersion: "1", targetVersion: "2")) == .restarting)
        #expect(L.status(m, phase: .servers, server: .running(stage: .installing, fromVersion: "1", targetVersion: "2")) == .downloading)
        var done = m; done.failed = true
        #expect(L.status(done, phase: .servers, server: .idle) == .failed)
        let r = L.Result(localVersion: "0.0.50", updatedServers: 1, updatedProviders: 2, failures: ["alvin: offline"])
        #expect(L.toast(r, appVersion: "0.0.50")?.title == "Updated this app, 1 server, and 2 providers")
        #expect(L.toast(L.Result(localVersion: nil, updatedServers: 0, updatedProviders: 0, failures: ["alvin: offline"]), appVersion: "1")?.title == "Update failed")
        #expect(L.toast(L.Result(localVersion: nil, updatedServers: 0, updatedProviders: 0, failures: []), appVersion: "1") == nil)
        #expect(L.threadsLine(stopped: 1, continuing: 2) == "3 running threads will be interrupted. 2 can resume after the restart.")
        #expect(L.channel("0.0.46-nightly.20261014.3105") == "nightly" && L.channel("0.0.46") == "stable")
    }

    /// Dither: a turn on this Mac holds every update but this app's own; nothing running offers them all.
    @Test func localWorkHoldsServerUpdates() {
        let all = L.Pending(app: true, runtime: true, servers: 2, providers: 3)
        #expect(all.count == 7)
        #expect(L.offered(all, runningOnThisMac: false) == all)
        #expect(L.offered(all, runningOnThisMac: true) == L.Pending(app: true))
        #expect(L.offered(L.Pending(servers: 1), runningOnThisMac: true).count == 0)
    }
}
