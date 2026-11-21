import Foundation
import T3Protocol

/// Switching every machine between Stable and Nightly in one step (T3 f2943ee90e PR #26288 and 477845733d PR #27484):
/// the planning from sidebar/updateEverything.logic.ts:153-424 and settings/updateTrackSwitch.logic.ts:65-116 at 4928.
///
/// Stable and Nightly build their own commits, so crossing tracks needs proof that the target release knows every
/// migration a server's database holds. Servers move to the release; desktop-managed hosts reinstall their app on its
/// track. CandyWrapper's own server keeps its runtime's track, and this app's own track is its Sparkle channel.
public enum UpdateTrackSwitchLogic {
    /// `ChannelSwitchRelease`: the newest release on the target track, as the primary server's npm registry reports it.
    public struct Release: Equatable, Sendable {
        /// `latest` (Stable) or `nightly`, the desktop channel names.
        public var channel: String
        public var version: String
        public var databaseMigration: Int?
        public init(channel: String, version: String, databaseMigration: Int?) {
            self.channel = channel; self.version = version; self.databaseMigration = databaseMigration
        }
    }

    public struct Machine: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        /// Nil when the server never connected.
        public var serverVersion: String?
        public var connected: Bool
        public var canMaintain: Bool
        public var updating: Bool
        public var capabilities: ServerUpdateCapabilities
        /// `desktopAppChannelSwitch` (environment.ts:172).
        public var desktopAppChannelSwitch: Bool
        public var platformOS: String?
        /// `databaseMigration` (environment.ts:224-225): the highest migration its database holds.
        public var databaseMigration: Int?
        /// CandyWrapper's own server, which follows its runtime's track.
        public var ownServer: Bool
        public init(environmentId: String, label: String, serverVersion: String?, connected: Bool, canMaintain: Bool, updating: Bool = false,
                    capabilities: ServerUpdateCapabilities, desktopAppChannelSwitch: Bool = false, platformOS: String? = nil,
                    databaseMigration: Int? = nil, ownServer: Bool = false) {
            self.environmentId = environmentId; self.label = label; self.serverVersion = serverVersion; self.connected = connected
            self.canMaintain = canMaintain; self.updating = updating; self.capabilities = capabilities
            self.desktopAppChannelSwitch = desktopAppChannelSwitch; self.platformOS = platformOS
            self.databaseMigration = databaseMigration; self.ownServer = ownServer
        }
    }

    /// A server the switch moves: to `targetVersion`, with the track for a desktop app and the checked migration.
    public struct Target: Equatable, Sendable {
        public var machine: Machine
        public var targetVersion: String
        public var channel: String?
        public var targetDatabaseMigration: Int?
        /// The host already runs its track's newest build and only saves the track.
        public var trackOnly: Bool
    }

    public static func label(_ channel: String) -> String { channel == "nightly" ? "Nightly" : "Stable" }

    /// The Switch dialog's line when the release check fails: the error's own sentence when it has one (RPC errors
    /// do), never a Swift type name, and what to try.
    public static func checkFailed(_ channel: String, error: any Error) -> String {
        let reason = (error as? LocalizedError)?.errorDescription.map { $0.hasSuffix(".") ? $0 : $0 + "." }
            ?? "The server did not answer."
        return "Could not check \(label(channel)) releases. \(reason) Check that the primary server is connected and try again."
    }

    /// `desktopUpdateChannelOf` (shared/cliRelease.ts:102-104).
    public static func desktopChannel(_ version: String) -> String {
        UpdateEverythingLogic.channel(version) == "nightly" ? "nightly" : "latest"
    }

    static func isOnTrack(_ version: String, _ channel: String) -> Bool {
        UpdateEverythingLogic.channel(version) != "preview" && desktopChannel(version) == channel
    }

    enum Block { case serverPredatesChecks, releasePredatesChecks, unsupported }

    /// `channelSwitchBlock` (:173-183): servers and releases before this check report no migration number.
    static func block(from version: String, _ release: Release, migration: Int?) -> Block? {
        guard desktopChannel(version) != release.channel else { return nil }
        guard let migration else { return .serverPredatesChecks }
        guard let target = release.databaseMigration else { return .releasePredatesChecks }
        return migration > target ? .unsupported : nil
    }

    static func blockReason(from version: String, _ release: Release, migration: Int?) -> String? {
        guard let block = block(from: version, release, migration: migration) else { return nil }
        let from = label(desktopChannel(version)), to = label(release.channel)
        switch block {
        case .serverPredatesChecks: return "its server predates database checks; update it on \(from) first"
        case .releasePredatesChecks: return "\(release.version) predates database checks; wait for a newer \(to) release"
        case .unsupported: return "its database has changes \(release.version) does not support yet; stay on \(from) until \(to) has them"
        }
    }

    /// `unavailableReason` (:136-151).
    static func unavailable(_ m: Machine) -> String? {
        if !m.connected { return "not connected" }
        if !m.canMaintain { return "no permission" }
        if m.updating { return "already updating" }
        return nil
    }

    /// `trackSwitchMove` (:412-431): how a switch moves a host, or why it never can from here.
    static func move(_ m: Machine, sameTrack: Bool) -> Result<ServerSelfUpdateCapability, Skip> {
        guard let version = m.serverVersion, UpdateEverythingLogic.channel(version) != "preview" else { return .failure(Skip("runs a preview build")) }
        guard let path = m.capabilities.selfUpdate else { return .failure(Skip("needs a manual update")) }
        guard path == .desktopManaged else { return .success(path) }
        guard m.desktopAppChannelSwitch else { return .failure(Skip("needs a newer desktop app")) }
        // Squirrel.Mac renames the bundle for the new track and then cannot relaunch it.
        if !sameTrack, m.platformOS == "darwin" { return .failure(Skip("switch the Mac app on that Mac")) }
        return .success(path)
    }
    struct Skip: Error { let reason: String; init(_ r: String) { reason = r } }

    /// `collectChannelSwitchTargets` (:299-389).
    public static func targets(_ machines: [Machine], release: Release) -> (targets: [Target], skipped: [UpdateEverythingLogic.Skipped]) {
        var targets: [Target] = [], skipped: [UpdateEverythingLogic.Skipped] = []
        for m in machines {
            func skip(_ reason: String) { skipped.append(.init(environmentId: m.environmentId, label: m.label, reason: reason)) }
            if m.ownServer {
                // T3 moves its own servers by reinstalling itself; CandyWrapper's runtime keeps its own track.
                if let v = m.serverVersion, !isOnTrack(v, release.channel) { skip("CandyWrapper's own server keeps its runtime's track") }
                continue
            }
            func target(_ path: ServerSelfUpdateCapability, _ version: String, trackOnly: Bool = false) -> Target {
                Target(machine: m, targetVersion: version, channel: path == .desktopManaged ? release.channel : nil,
                       targetDatabaseMigration: release.databaseMigration, trackOnly: trackOnly)
            }
            let version = m.serverVersion
            let sameTrack = version.map { isOnTrack($0, release.channel) } ?? false
            if let version, sameTrack, !ServerVersionSkewLogic.serverIsBehind(version, client: release.version) {
                // A desktop host already current gets a track-only request, since its saved track may still differ.
                if case .success(let path) = move(m, sameTrack: true), path == .desktopManaged, unavailable(m) == nil {
                    targets.append(target(path, version, trackOnly: true))
                }
                continue
            }
            if let reason = unavailable(m) { skip(reason); continue }
            guard let version else { skip("not connected"); continue }
            let path: ServerSelfUpdateCapability
            switch move(m, sameTrack: sameTrack) {
            case .failure(let s): skip(s.reason); continue
            case .success(let p): path = p
            }
            if let blocked = blockReason(from: version, release, migration: m.databaseMigration) { skip(blocked); continue }
            // Service launchers only accept newer versions, so leaving for an older release is manual.
            if path == .bootService, compareSemver(release.version, version) <= 0 {
                skip("run `t3 update --channel \(release.channel == "nightly" ? "nightly" : "stable") --allow-downgrade` there")
                continue
            }
            targets.append(target(path, release.version))
        }
        return (targets, skipped)
    }

    /// `awaitsTrackSwitch` (:392-405): a host on the other track that a switch can still move.
    public static func awaitsSwitch(_ m: Machine, channel: String) -> Bool {
        guard !m.ownServer, let v = m.serverVersion, !isOnTrack(v, channel) else { return false }
        if case .success = move(m, sameTrack: false) { return true }
        return false
    }

    /// `nothingToMove` (updateTrackSwitch.logic.ts:65-104): a note when confirming only saves the track, or the reason
    /// the button is off when even that is done.
    public static func nothingToMove(channel: String, savedChannel: String?, switchesLocal: Bool, crossesLocal: Bool,
                                     rows: [UpdateEverythingLogic.MachineRow], hasTargets: Bool) -> (note: String?, disabledReason: String?) {
        if switchesLocal || rows.contains(where: { $0.skipped == nil }) { return (nil, nil) }
        let name = label(channel)
        let allOnTrack = rows.isEmpty && !crossesLocal
        if !hasTargets, savedChannel == channel {
            return (nil, allOnTrack ? "Every connected machine is already on \(name)." : "No machine can switch to \(name) now.")
        }
        return (allOnTrack ? "Every connected machine is already on \(name). This only saves the track."
                : "No machine can switch to \(name) now. This only saves the track.", nil)
    }

    /// What this app does on a switch. Sparkle offers only builds newer than the running one, so Nightly to Stable keeps
    /// this build until a Stable release passes it; Stable to Nightly takes the next Nightly build.
    public static func appNote(channel: String, savedChannel: String?, updatesEnabled: Bool) -> String? {
        guard savedChannel != channel else { return nil }
        guard updatesEnabled else { return "This app's updates are off here, so it stays on its current build." }
        return channel == "nightly"
            ? "This app switches to Nightly and offers the next Nightly build."
            : "This app stays on its current build until a Stable release is newer, then updates to it."
    }

    // MARK: Redesign's wording

    /// Redesign's Update track row: the switch moves the T3 servers, while CandyWrapper itself has one release track
    /// (every release so far is on the default channel), which the user could not tell from T3's wording.
    public static func redesignTrackLine(unswitched: Int?, selected: String) -> String {
        let lead = "Sets the T3 server track on your connected machines. This app has one release track."
        guard let unswitched, unswitched > 0 else { return lead }
        let other = label(selected == "nightly" ? "latest" : "nightly")
        return lead + (unswitched == 1 ? " 1 machine still runs \(other)." : " \(unswitched) machines still run \(other).")
    }

    /// One server a switch moves, from its version to the target.
    public struct Move: Equatable, Sendable {
        public var machine: String, from: String?, to: String
        public init(machine: String, from: String?, to: String) { self.machine = machine; self.from = from; self.to = to }
    }

    /// Redesign's dialog, before the per-machine table: which servers change version and from what to what, the
    /// threads that stop, and that this app's own version stays.
    public static func redesignLead(moves: [Move], stopped: Int, continuing: Int) -> [String] {
        var lines: [String] = []
        let parts = moves.map { m in m.from.map { "\(m.machine) from \($0) to \(m.to)" } ?? "\(m.machine) to \(m.to)" }
        if parts.isEmpty {
            lines.append("No T3 server changes version.")
        } else {
            let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            lines.append("This moves the T3 \(parts.count == 1 ? "server" : "servers") on \(list).")
        }
        if let threads = UpdateEverythingLogic.threadsLine(stopped: stopped, continuing: continuing) { lines.append(threads) }
        lines.append("This app's own version does not change.")
        return lines
    }

    /// The Update track row's line (SettingsPanels.tsx:370-395): machines still on the other track, or what a switch does.
    public static func trackLine(unswitched: Int, selected: String) -> String {
        guard unswitched > 0 else { return "Switches this app and every connected machine whose database the target release supports." }
        let other = label(selected == "nightly" ? "latest" : "nightly")
        return unswitched == 1 ? "1 machine still runs \(other)." : "\(unswitched) machines still run \(other)."
    }

    /// `compareSemverVersions` (shared/semver.ts:97): core numbers, then a prerelease sorts before its release,
    /// numeric identifiers numerically and below alphanumeric ones.
    public static func compareSemver(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> ([Int], [String]) {
            let s = (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let halves = s.split(separator: "-", maxSplits: 1)
            let core = (halves.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (core, halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : [])
        }
        let (ca, pa) = parts(a), (cb, pb) = parts(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0, y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if pa.isEmpty || pb.isEmpty { return pa.isEmpty == pb.isEmpty ? 0 : (pa.isEmpty ? 1 : -1) }
        for i in 0..<max(pa.count, pb.count) {
            guard i < pa.count else { return -1 }
            guard i < pb.count else { return 1 }
            let x = pa[i], y = pb[i]
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny ? -1 : 1
            case (_?, nil): return -1
            case (nil, _?): return 1
            default: return x < y ? -1 : 1
            }
        }
        return 0
    }
}
