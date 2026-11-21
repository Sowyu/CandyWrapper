import Foundation
import Testing
import T3Protocol
@testable import Features

/// The Stable/Nightly switch plan (T3 sidebar/updateEverything.logic.ts:153-424, settings/updateTrackSwitch.logic.ts).
/// Pure data: no server is called and no track changes anywhere.
struct UpdateTrackSwitchLogicTests {
    typealias L = UpdateTrackSwitchLogic
    static let nightly = L.Release(channel: "nightly", version: "0.0.46-nightly.20261119.4928", databaseMigration: 120)
    static let stable = L.Release(channel: "latest", version: "0.0.45", databaseMigration: 110)
    static func machine(_ id: String, _ version: String?, path: ServerSelfUpdateCapability? = .respawn, migration: Int? = 100,
                        connected: Bool = true, maintain: Bool = true, os: String = "linux", channelSwitch: Bool = true, own: Bool = false) -> L.Machine {
        L.Machine(environmentId: id, label: id, serverVersion: version, connected: connected, canMaintain: maintain,
                  capabilities: ServerUpdateCapabilities(selfUpdate: path, desktopAppUpdate: true), desktopAppChannelSwitch: channelSwitch,
                  platformOS: os, databaseMigration: migration, ownServer: own)
    }

    /// Redesign says the switch moves the T3 servers and interrupts threads, and leaves this app's version alone.
    @Test func redesignWordingNamesTheServersAndThreads() {
        typealias L = UpdateTrackSwitchLogic
        #expect(L.redesignTrackLine(unswitched: nil, selected: "latest") == "Sets the T3 server track on your connected machines. This app has one release track.")
        #expect(L.redesignTrackLine(unswitched: 2, selected: "latest").hasSuffix(" 2 machines still run Nightly."))
        let lead = L.redesignLead(moves: [.init(machine: "Mac mini", from: "0.1.11-nightly.20261119.4928", to: "0.1.10"),
                                          .init(machine: "vps", from: nil, to: "0.1.10")], stopped: 3, continuing: 0)
        #expect(lead == ["This moves the T3 servers on Mac mini from 0.1.11-nightly.20261119.4928 to 0.1.10 and vps to 0.1.10.",
                         "3 running threads will be interrupted.", "This app's own version does not change."])
        #expect(L.redesignLead(moves: [], stopped: 0, continuing: 0) == ["No T3 server changes version.", "This app's own version does not change."])
    }

    @Test func movesServersAndCarriesTheTrackAndMigration() {
        let plan = L.targets([Self.machine("a", "0.0.45"), Self.machine("d", "0.0.45", path: .desktopManaged)], release: Self.nightly)
        #expect(plan.skipped.isEmpty)
        #expect(plan.targets.map(\.targetVersion) == [Self.nightly.version, Self.nightly.version])
        #expect(plan.targets[0].channel == nil && plan.targets[1].channel == "nightly")
        #expect(plan.targets.allSatisfy { $0.targetDatabaseMigration == 120 && !$0.trackOnly })
    }

    @Test func databaseChecksBlockACrossing() {
        let old = L.targets([Self.machine("a", "0.0.45", migration: nil)], release: Self.nightly)
        #expect(old.skipped.first?.reason == "its server predates database checks; update it on Stable first")
        let noMigration = L.Release(channel: "nightly", version: "0.0.46-nightly.1.1", databaseMigration: nil)
        #expect(L.targets([Self.machine("a", "0.0.45")], release: noMigration).skipped.first?.reason
                == "0.0.46-nightly.1.1 predates database checks; wait for a newer Nightly release")
        let ahead = L.targets([Self.machine("a", "0.0.46-nightly.20261118.4900", migration: 115)], release: Self.stable)
        #expect(ahead.skipped.first?.reason == "its database has changes 0.0.45 does not support yet; stay on Nightly until Stable has them")
        // Same track: no check.
        #expect(L.targets([Self.machine("a", "0.0.44", migration: nil)], release: Self.stable).targets.count == 1)
    }

    @Test func skipsWhatCannotMove() {
        let plan = L.targets([
            Self.machine("off", "0.0.46-nightly.20261118.4900", connected: false),
            Self.machine("ro", "0.0.46-nightly.20261118.4900", maintain: false),
            Self.machine("manual", "0.0.46-nightly.20261118.4900", path: nil),
            Self.machine("preview", "0.0.45-preview.20261101.1"),
            Self.machine("mac", "0.0.46-nightly.20261118.4900", path: .desktopManaged, os: "darwin"),
            Self.machine("olddesk", "0.0.46-nightly.20261118.4900", path: .desktopManaged, channelSwitch: false),
            Self.machine("svc", "0.0.46-nightly.20261118.4900", path: .bootService, migration: 100),
            Self.machine("own", "0.0.46-nightly.20261118.4900", own: true),
        ], release: Self.stable)
        #expect(plan.targets.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.environmentId, $0.reason) }) == [
            "off": "not connected", "ro": "no permission", "manual": "needs a manual update", "preview": "runs a preview build",
            "mac": "switch the Mac app on that Mac", "olddesk": "needs a newer desktop app",
            "svc": "run `t3 update --channel stable --allow-downgrade` there",
            "own": "CandyWrapper's own server keeps its runtime's track",
        ])
    }

    @Test func aCurrentDesktopHostOnlySavesItsTrack() {
        let plan = L.targets([Self.machine("d", "0.0.46-nightly.20261119.4928", path: .desktopManaged),
                              Self.machine("s", "0.0.46-nightly.20261119.4928")], release: Self.nightly)
        #expect(plan.targets.count == 1 && plan.targets[0].trackOnly && plan.targets[0].channel == "nightly")
        #expect(plan.skipped.isEmpty)
    }

    @Test func nothingToMoveSaysWhatConfirmingDoes() {
        let skippedRow = UpdateEverythingLogic.MachineRow(environmentId: "a", label: "a", app: nil, providers: [], skipped: "no permission")
        #expect(L.nothingToMove(channel: "nightly", savedChannel: "nightly", switchesLocal: false, crossesLocal: false, rows: [], hasTargets: false)
                == (nil, "Every connected machine is already on Nightly."))
        #expect(L.nothingToMove(channel: "nightly", savedChannel: "latest", switchesLocal: false, crossesLocal: false, rows: [], hasTargets: false)
                == ("Every connected machine is already on Nightly. This only saves the track.", nil))
        #expect(L.nothingToMove(channel: "nightly", savedChannel: "nightly", switchesLocal: false, crossesLocal: false, rows: [skippedRow], hasTargets: false)
                == (nil, "No machine can switch to Nightly now."))
        #expect(L.nothingToMove(channel: "nightly", savedChannel: "latest", switchesLocal: true, crossesLocal: true, rows: [], hasTargets: false) == (nil, nil))
    }

    @Test func awaitingAndLines() {
        #expect(L.awaitsSwitch(Self.machine("a", "0.0.45"), channel: "nightly"))
        #expect(!L.awaitsSwitch(Self.machine("a", "0.0.46-nightly.20261118.4900"), channel: "nightly"))
        #expect(!L.awaitsSwitch(Self.machine("a", "0.0.45", own: true), channel: "nightly"))
        #expect(!L.awaitsSwitch(Self.machine("a", "0.0.45", path: nil), channel: "nightly"))
        #expect(L.trackLine(unswitched: 2, selected: "nightly") == "2 machines still run Stable.")
        #expect(L.trackLine(unswitched: 0, selected: "latest").hasPrefix("Switches this app"))
        #expect(L.appNote(channel: "latest", savedChannel: "nightly", updatesEnabled: true)
                == "This app stays on its current build until a Stable release is newer, then updates to it.")
        #expect(L.appNote(channel: "nightly", savedChannel: "nightly", updatesEnabled: true) == nil)
    }

    @Test func semverOrder() {
        #expect(L.compareSemver("0.0.45", "0.0.46-nightly.1.1") < 0)
        #expect(L.compareSemver("0.0.46", "0.0.46-nightly.1.1") > 0)
        #expect(L.compareSemver("0.0.46-nightly.20261119.10", "0.0.46-nightly.20261119.9") > 0)
        #expect(L.compareSemver("1.2.3", "v1.2.3") == 0)
    }
}
