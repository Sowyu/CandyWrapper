import Foundation
import T3Protocol

/// "Update everything" from the sidebar update button (T3 3105 d83929ad0 and eeaac49a9,
/// sidebar/updateEverything.logic.ts). One click updates every connected machine's outdated providers, then the
/// servers behind this client's T3 version, then this app last. CandyWrapper installs no T3 server with its own
/// update, so no machine counts as `hostedByThisApp`, and its target is always the T3 version it implements.
public enum UpdateEverythingLogic {
    /// `UpdateEverythingMachine`, with the server's update path already resolved.
    public struct Machine: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        /// The server's version from its last `welcome`, nil when it never connected.
        public var serverVersion: String?
        public var connected: Bool
        /// The session holds `environment:maintain`.
        public var canMaintain: Bool
        public var updating: Bool
        public var capabilities: ServerUpdateCapabilities
        /// CandyWrapper's own server, which it updates into its runtimes itself.
        public var ownServer: Bool
        /// `threadRestartContinuation` and the server's "Continue threads after restarts".
        public var continuesThreads: Bool
        /// The saved connection is switched off in Settings, so it never connects (#41672).
        public var turnedOff = false
        /// Why the connection is down, when it says (`connectionErrorText`, #41672).
        public var connectionError: String?
        /// The local environment, T3's `PrimaryConnectionTarget`. It has no row in Environments > List.
        public var primary = false
        public init(environmentId: String, label: String, serverVersion: String?, connected: Bool, canMaintain: Bool, updating: Bool,
                    capabilities: ServerUpdateCapabilities, ownServer: Bool = false, continuesThreads: Bool = false,
                    turnedOff: Bool = false, connectionError: String? = nil, primary: Bool = false) {
            self.primary = primary
            self.environmentId = environmentId; self.label = label; self.serverVersion = serverVersion; self.connected = connected
            self.canMaintain = canMaintain; self.updating = updating; self.capabilities = capabilities; self.ownServer = ownServer
            self.continuesThreads = continuesThreads; self.turnedOff = turnedOff; self.connectionError = connectionError
        }
    }

    public struct Skipped: Equatable, Sendable {
        public var environmentId: String, label: String, reason: String
    }

    /// `cliReleaseChannelOf` (packages/shared/src/cliRelease.ts:90-93).
    public static func channel(_ version: String) -> String {
        let core = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard let match = core.range(of: #"^[^-+]+-(nightly|preview)\.\d{8}\.\d+$"#, options: .regularExpression) else { return "stable" }
        return core[match].contains("-nightly.") ? "nightly" : "preview"
    }

    /// `collectServerUpdateTargets`: the servers this pass moves to `target`, and the behind ones it leaves alone.
    public static func serverTargets(_ machines: [Machine], target: String) -> (targets: [Machine], skipped: [Skipped]) {
        var targets: [Machine] = [], skipped: [Skipped] = []
        for m in machines {
            if let v = m.serverVersion, !ServerVersionSkewLogic.serverIsBehind(v, client: target) { continue }
            let skip = { (reason: String) in skipped.append(Skipped(environmentId: m.environmentId, label: m.label, reason: reason)) }
            // `unavailableReason` (updateEverything.logic.ts:152-173 at 5258, #41672).
            if m.turnedOff { skip("turned off"); continue }
            guard m.connected else { skip(m.connectionError ?? "not connected"); continue }
            guard m.serverVersion != nil else { skip("still loading"); continue }
            guard m.canMaintain else { skip("no permission"); continue }
            guard !m.updating else { skip("already updating"); continue }
            if m.ownServer { targets.append(m); continue }
            guard let path = m.capabilities.selfUpdate else { skip("needs a manual update"); continue }
            // A desktop server without the desktop control cannot be updated from here (#33030, updateEverything.logic.ts:54-56).
            if path == .desktopManaged, !m.capabilities.desktopAppUpdate { skip("update T3 Code on that machine"); continue }
            // A desktop app installs its own track's newest release. Nightly builds run ahead of Stable, so a Nightly
            // host behind a Stable target has something newer; a Stable one may not (updateEverything.logic.ts, #37490).
            if let v = m.serverVersion, channel(v) != channel(target), path != .desktopManaged || channel(v) == "stable" {
                skip("on the \(channel(v)) channel"); continue
            }
            targets.append(m)
        }
        return (targets, skipped)
    }

    /// A saved environment's row in Settings > Environments > List shows the server's version and an update control:
    /// switched on, connected and behind this client (`showUpdateAction`, SavedEnvironmentRows.tsx:244-248 at 5258, less
    /// its running-update check, since a running update shows its progress on the row instead).
    public static func rowOffersUpdate(enabled: Bool, connected: Bool, serverVersion: String?, target: String) -> Bool {
        enabled && connected && serverVersion.map { ServerVersionSkewLogic.serverIsBehind($0, client: target) } == true
    }

    /// The machines the sidebar's server update notice counts, in sidebar order. The notice is CandyWrapper's own
    /// (T3 lights the button only for `servers.length > 0 || providers`, useUpdateEverything.ts:107), for servers
    /// Update all can't take. It counts only what a row in Environments > List can update. The local environment has
    /// no row there, and T3 never counts it (`hostedByThisApp`, useUpdateEverything.ts:41-48, updateEverything.logic.ts:96).
    public static func serverUpdateNoticeMachines(_ machines: [Machine], target: String) -> [Machine] {
        machines.filter { m in
            !m.primary && !m.ownServer && rowOffersUpdate(enabled: !m.turnedOff, connected: m.connected, serverVersion: m.serverVersion, target: target)
        }
    }

    /// The notice and the button's tooltip: "Server update available: studio runs 0.1.12, this app expects 0.1.13".
    public static func serverUpdateNotice(_ machines: [Machine], target: String) -> String? {
        let counted = serverUpdateNoticeMachines(machines, target: target)
        guard let first = counted.first, let version = first.serverVersion else { return nil }
        let head = counted.count == 1 ? "Server update available" : "\(counted.count) server updates available"
        let more = counted.count == 1 ? "" : " and \(counted.count - 1) more"
        return "\(head): \(first.label) runs \(version)\(more), this app expects \(target)"
    }

    public struct MachineRow: Equatable, Sendable {
        public enum App: String, Sendable { case thisApp = "This app", server = "Server", desktopApp = "Desktop app" }
        public var environmentId: String?
        public var label: String
        public var app: App?
        public var providers: [String]
        public var skipped: String?
    }

    public struct Description: Equatable, Sendable {
        public var summary: String
        public var lines: [String]
        public var version: String?
        public var providerCount: Int
        public var rows: [MachineRow]
        public var updatingRows: [MachineRow] { rows.filter { $0.app != nil || !$0.providers.isEmpty } }
    }

    /// `describeUpdateEverything`: "Update this app, 2 servers, and 3 providers", and a line per machine.
    public static func describe(localVersion: String?, servers: [Machine], target: String,
                                providerMachines: [(environmentId: String, label: String, providers: [String])],
                                localMachines: [(environmentId: String, label: String)] = [], skipped: [Skipped] = []) -> Description {
        let providerCount = providerMachines.reduce(0) { $0 + $1.providers.count }
        let summary = "Update " + joinList([localVersion != nil ? "this app" : nil, count(servers.count, "server"), count(providerCount, "provider")].compactMap { $0 })
        var order: [String] = [], items: [String: (label: String, items: [String])] = [:]
        func add(_ id: String, _ label: String, _ more: [String]) {
            if items[id] == nil { order.append(id); items[id] = (label, []) }
            items[id]!.items += more
        }
        for s in servers {
            // A desktop-managed server installs whatever its own app's feed offers: no version to show.
            add(s.environmentId, s.label, [s.capabilities.selfUpdate == .desktopManaged && !s.ownServer ? "desktop app update" : "server to \(target)"])
        }
        for m in providerMachines { add(m.environmentId, m.label, m.providers) }
        let lines = (localVersion.map { ["This app: \($0), restarts last"] } ?? [])
            + order.map { "\(items[$0]!.label): \(items[$0]!.items.joined(separator: ", "))" }
        // updateEverything.logic.ts:387-458 (3814): one row per environment, in insertion order.
        var rows: [MachineRow] = []
        func update(_ id: String?, _ label: String, _ change: (inout MachineRow) -> Void) {
            if let index = rows.firstIndex(where: { $0.environmentId == id }) { change(&rows[index]) }
            else {
                var row = MachineRow(environmentId: id, label: label, app: nil, providers: [], skipped: nil)
                change(&row); rows.append(row)
            }
        }
        if localVersion != nil {
            if localMachines.isEmpty { update(nil, "This app") { $0.app = .thisApp } }
            for local in localMachines { update(local.environmentId, local.label) { $0.app = .thisApp } }
        }
        for server in servers {
            update(server.environmentId, server.label) { $0.app = server.capabilities.selfUpdate == .desktopManaged && !server.ownServer ? .desktopApp : .server }
        }
        for machine in providerMachines { update(machine.environmentId, machine.label) { $0.providers = machine.providers } }
        for machine in skipped { update(machine.environmentId, machine.label) { $0.skipped = machine.reason } }
        return Description(summary: summary, lines: lines,
            version: localVersion ?? (servers.contains { $0.capabilities.selfUpdate != .desktopManaged || $0.ownServer } ? target : nil),
            providerCount: providerCount, rows: rows)
    }

    /// `UpdateRunMachineStatus` and its words (`RUN_STATUS_LABELS`, updateEverything.logic.ts:681-688 at 5258).
    public enum MachineStatus: String, Sendable {
        case providers = "updating providers", waiting, downloading, restarting, done, failed
        /// `isActive` (updateEverything.logic.ts:601).
        public var isActive: Bool { self != .done && self != .failed }
    }

    /// `UpdateRunMachine` (updateEverything.logic.ts:501-511). `server !== null` is `updatesServer`: it clears once the
    /// server updated, like T3's `server: null`. A row restored after a relaunch has neither, only `handedOffVersion`.
    public struct RunMachine: Equatable, Sendable {
        public var environmentId: String, label: String
        public var updatesProviders: Bool, updatesServer: Bool
        /// `handedOffVersion`: the version a server restarts into, set on a row this app restored after its own relaunch.
        public var handedOffVersion: String?
        /// Seconds since 1970 when this machine's current step began; a server's restarts when the providers finish.
        public var startedAt: Double
        /// `result`: set when every update for the machine has finished, true when one failed.
        public var failed: Bool?
        public var failure: String?
        /// A provider failure kept across a server retry, so the row stays failed after the server updates.
        public var providerFailure: String?
        public init(environmentId: String, label: String, updatesProviders: Bool, updatesServer: Bool, startedAt: Double = 0,
                    failed: Bool? = nil, failure: String? = nil, providerFailure: String? = nil, handedOffVersion: String? = nil) {
            self.environmentId = environmentId; self.label = label; self.handedOffVersion = handedOffVersion
            self.updatesProviders = updatesProviders; self.updatesServer = updatesServer; self.startedAt = startedAt
            self.failed = failed; self.failure = failure; self.providerFailure = providerFailure
        }
    }

    /// `UpdateEverythingRun` (updateEverything.logic.ts:513-520).
    public struct Run: Equatable, Sendable {
        public enum Phase: Sendable { case providers, servers, countdown, installing }
        /// The version this app installs last, nil when it doesn't.
        public var localVersion: String?
        public var phase: Phase
        /// Seconds since 1970 when the countdown restarts the app.
        public var restartAt: Double?
        public var machines: [RunMachine]
        public init(localVersion: String?, phase: Phase, restartAt: Double? = nil, machines: [RunMachine]) {
            self.localVersion = localVersion; self.phase = phase; self.restartAt = restartAt; self.machines = machines
        }

        /// `restartSecondsLeft` (SidebarUpdateCapsule.tsx:56-60).
        public func restartSeconds(now: Double) -> Int? {
            guard phase == .countdown, let restartAt else { return nil }
            return max(0, Int((restartAt - now).rounded(.up)))
        }
    }

    /// `UPDATE_RESTART_DELAY_MS` (useUpdateEverything.ts:38).
    public static let restartDelay: Double = 5
    /// `UPDATE_SLOW_AFTER_MS` (updateEverything.logic.ts:572).
    public static let slowAfter: Double = 3 * 60

    /// `resolveUpdateRunMachineStatus` (updateEverything.logic.ts:522-534).
    public static func status(_ m: RunMachine, phase: Run.Phase, server: ServerUpdateState) -> MachineStatus {
        if let failed = m.failed { return failed ? .failed : .done }
        if m.handedOffVersion != nil { return .restarting }
        if phase == .providers, m.updatesProviders { return .providers }
        if m.updatesServer, case .running(let stage, _, _) = server { return stage == .resuming ? .restarting : .downloading }
        return .waiting
    }

    // MARK: A pass across this app's relaunch (updateEverythingRun.tsx:208-432 at 5258, #41964, #33002)

    /// `HandedOffServer` (updateEverythingRun.tsx:212-219): a server still restarting when this app relaunched.
    /// `updateId` is the service launcher's id for the update, which finds its outcome after the restart.
    public struct HandedOffServer: Codable, Equatable, Sendable {
        public var environmentId: String, label: String, targetVersion: String
        public var startedAt: Double
        public var updateId: String?
        public init(environmentId: String, label: String, targetVersion: String, startedAt: Double, updateId: String? = nil) {
            self.environmentId = environmentId; self.label = label; self.targetVersion = targetVersion
            self.startedAt = startedAt; self.updateId = updateId
        }
    }

    /// `HANDOFF_TIMEOUT_MS` (updateEverythingRun.tsx:211): a background service's 30-minute trial start, and then some.
    public static let handoffTimeout: Double = 32 * 60
    /// `SAVED_RESULT_MAX_AGE_MS`: a saved pass older than this belongs to an install that never relaunched the app.
    public static let savedMaxAge: Double = 10 * 60

    /// What `saveUpdateEverythingResult` keeps (updateEverythingRun.tsx:221-266): the result so far, and every row that
    /// had not finished, with the version its server restarts into.
    public struct SavedPass: Codable, Equatable, Sendable {
        public var savedAt: Double
        public var result: Result
        public var handedOff: [HandedOffServer]?
        public init(savedAt: Double, result: Result, handedOff: [HandedOffServer] = []) {
            self.savedAt = savedAt; self.result = result; self.handedOff = handedOff
        }
    }

    /// The unfinished rows to save. `target` gives a row's server target now: its running update's, else the pass's.
    /// A provider-only row has no server to follow and is left out, as in T3.
    public static func handedOff(_ run: Run?, target: (RunMachine) -> (version: String, updateId: String?)?) -> [HandedOffServer] {
        (run?.machines ?? []).compactMap { m in
            guard m.failed == nil else { return nil }
            let found = m.handedOffVersion.map { (version: $0, updateId: nil as String?) } ?? (m.updatesServer ? target(m) : nil)
            guard let found else { return nil }
            return HandedOffServer(environmentId: m.environmentId, label: m.label, targetVersion: found.version, startedAt: m.startedAt,
                                   updateId: found.updateId)
        }
    }

    /// `takeSavedUpdateEverythingResult`: nil once the pass is too old to belong to this launch.
    public static func takeSaved(_ data: Data?, now: Double) -> SavedPass? {
        guard let data, let saved = try? JSONDecoder().decode(SavedPass.self, from: data), now - saved.savedAt < savedMaxAge else { return nil }
        return saved
    }

    /// `followHandedOffServers` (updateEverythingRun.tsx:306-327): the capsule shows each restarting server again.
    public static func restoredRun(_ servers: [HandedOffServer]) -> Run? {
        servers.isEmpty ? nil : Run(localVersion: nil, phase: .servers, machines: servers.map {
            RunMachine(environmentId: $0.environmentId, label: $0.label, updatesProviders: false, updatesServer: false,
                       startedAt: $0.startedAt, handedOffVersion: $0.targetVersion)
        })
    }

    /// How a followed server ended, from what it reports now: nil while it still restarts, `.some(nil)` once it runs the
    /// target, `.some(why)` when its launcher rolled the update back or failed it (updateEverythingRun.tsx:379-421, #33002).
    /// A rollback restarts the old version, which the version check never accepts, so only the outcome can end it.
    public static func settlement(_ s: HandedOffServer, serverVersion: String?, ready: ServerLifecycleReady?) -> String?? {
        if let v = serverVersion, !ServerVersionSkewLogic.serverIsBehind(v, client: s.targetVersion) { return .some(nil) }
        guard let id = s.updateId, let outcome = ready?.updateOutcome, outcome.id == id, outcome.status != "committed" else { return nil }
        // `ServerUpdateTerminalError.message` (client-runtime state/server.ts:165-195).
        return .some(outcome.reason ?? "The t3@\(s.targetVersion) update \(outcome.status).")
    }

    /// `"Not back after {minutes} minutes"`, a followed server's failure once `handoffTimeout` passes.
    public static let notBackMessage = "Not back after \(Int(handoffTimeout / 60)) minutes"

    /// `RestoredRetry` (updateEverything.logic.ts:536-537): `.current` when the server already runs the target, so a
    /// retry only settles the row; `.update` when it can update again now.
    public enum RestoredRetry: Equatable, Sendable { case current, update }

    /// `resolveRestoredRetry` (updateEverything.logic.ts:539-558, #41964): a failed row restored after this app relaunched
    /// keeps only its target version, so its retry is rebuilt from the server as it is now. Nil when nothing can retry,
    /// which includes a machine no longer among `current`.
    public static func restoredRetry(_ m: RunMachine, current: [Machine]) -> RestoredRetry? {
        guard m.failed == true, !m.updatesServer, let target = m.handedOffVersion,
              let now = current.first(where: { $0.environmentId == m.environmentId }) else { return nil }
        if now.connected, let v = now.serverVersion, !ServerVersionSkewLogic.serverIsBehind(v, client: target) { return .current }
        return serverTargets([now], target: target).targets.isEmpty ? nil : .update
    }

    /// `closeFinishedUpdateRun` (updateEverything.logic.ts:564-570): a pass with nothing left to show closes.
    public static func closeFinished(_ run: Run) -> Run? {
        run.phase == .servers && run.localVersion == nil && run.machines.allSatisfy { $0.failed == false } ? nil : run
    }

    /// `formatUpdateElapsed` (updateEverything.logic.ts:574-581).
    public static func elapsed(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// `UpdateRunLocalState`: this app's own download while it installs last.
    public enum LocalState: Equatable, Sendable { case downloading(percent: Double?), waiting }

    /// `UpdateCapsuleView` (updateEverything.logic.ts:594-599).
    public struct CapsuleView: Equatable, Sendable {
        public enum Tone: Sendable { case `default`, slow, failed }
        public enum Action: String, Sendable { case later = "Later", retry = "Retry", dismiss = "Dismiss" }
        public var tone: Tone
        public var label: String
        /// The slowest machine's status and time, in `text-warning` after the label.
        public var slow: (status: String, elapsed: String)?
        public var action: Action?
        public static func == (a: CapsuleView, b: CapsuleView) -> Bool {
            a.tone == b.tone && a.label == b.label && a.slow?.status == b.slow?.status && a.slow?.elapsed == b.slow?.elapsed && a.action == b.action
        }
    }

    /// `describeUpdateCapsule` (updateEverything.logic.ts:603-678). A failed machine can retry when its server still
    /// waits to update, or when it is a restored row with a `restored` retry (index for index with the machines).
    public static func describeCapsule(_ run: Run, statuses: [MachineStatus], local: LocalState?, now: Double,
                                       restored: [RestoredRetry?] = []) -> CapsuleView {
        if let seconds = run.restartSeconds(now: now) { return CapsuleView(tone: .default, label: "Restart in \(seconds)s", action: .later) }
        if run.phase == .installing { return CapsuleView(tone: .default, label: "Restarting…", action: nil) }
        let rows = Array(zip(run.machines, statuses))
        if let slowest = rows.filter({ $0.1.isActive && $0.1 != .waiting }).min(by: { $0.0.startedAt < $1.0.startedAt }),
           now - slowest.0.startedAt >= slowAfter {
            return CapsuleView(tone: .slow, label: slowest.0.label, slow: (slowest.1.rawValue, elapsed(now - slowest.0.startedAt)), action: nil)
        }
        let done = statuses.filter { $0 == .done }.count
        let updated = CapsuleView(tone: .default, label: "\(done) of \(statuses.count) updated", action: nil)
        if statuses.contains(where: \.isActive) { return updated }
        if case .downloading(let percent) = local {
            return CapsuleView(tone: .default, label: percent.map { "Downloading \(Int($0.rounded(.down)))%" } ?? "Downloading", action: nil)
        }
        let failed = rows.indices.filter { rows[$0].1 == .failed }
        if !failed.isEmpty {
            let canRetry = failed.contains { rows[$0].0.updatesServer || (restored.indices.contains($0) && restored[$0] != nil) }
            return CapsuleView(tone: .failed, label: failed.count == 1 ? "\(rows[failed[0]].0.label) failed" : "\(failed.count) failed",
                               action: canRetry ? .retry : .dismiss)
        }
        return updated
    }

    /// `localStatusLabel` (SidebarUpdateCapsule.tsx:62-78): this app's line in the capsule's popover.
    public static func localStatus(_ run: Run, local: LocalState?, now: Double) -> String {
        if let seconds = run.restartSeconds(now: now) { return "restarts in \(seconds)s" }
        if run.phase == .installing { return "restarting" }
        if case .downloading(let percent) = local { return percent.map { "downloading \(Int($0.rounded(.down)))%" } ?? "downloading" }
        return "restarts after the servers"
    }

    /// How often the capsule needs a new `now` (`useNow`, SidebarUpdateCapsule.tsx:97-100): every second in the
    /// countdown, every 30 seconds while a machine still works for its elapsed time, else never.
    public static func tickInterval(_ run: Run, statuses: [MachineStatus]) -> Double? {
        if run.phase == .countdown { return 1 }
        return statuses.contains { $0.isActive && $0 != .waiting } ? 30 : nil
    }

    /// The width the capsule takes in a row `available` wide (SidebarUpdateCapsule.tsx:126-131): 32 until the
    /// `@container/sidebar-update` reaches 5rem, or 12rem while the countdown shows, then all of it.
    public static func capsuleExpands(available: Double, counting: Bool) -> Bool { available >= (counting ? 192 : 80) }

    /// `UpdateEverythingResult`.
    public struct Result: Codable, Equatable, Sendable {
        public var localVersion: String?
        public var updatedServers: Int
        public var updatedProviders: Int
        public var failures: [String]
        public init(localVersion: String?, updatedServers: Int, updatedProviders: Int, failures: [String]) {
            self.localVersion = localVersion; self.updatedServers = updatedServers; self.updatedProviders = updatedProviders; self.failures = failures
        }
    }

    /// `getUpdateEverythingToastView` (updateEverything.logic.ts:725-766 at 5258): one toast for a finished pass, nil when
    /// nothing finished. `restarting` names the servers a relaunched pass still follows.
    public static func toast(_ r: Result, appVersion: String, restarting: [String] = []) -> (success: Bool, title: String, description: String?)? {
        let parts = [r.localVersion != nil && r.localVersion == appVersion ? "this app" : nil,
                     count(r.updatedServers, "server"), count(r.updatedProviders, "provider")].compactMap { $0 }
        let still = restarting.isEmpty ? [] : ["\(joinList(restarting)) \(restarting.count == 1 ? "is" : "are") still restarting."]
        if r.failures.isEmpty {
            return parts.isEmpty ? nil : (true, "Updated \(joinList(parts))", still.isEmpty ? nil : still.joined(separator: "\n"))
        }
        return (false, parts.isEmpty ? "Update failed" : "Updated \(joinList(parts))", (r.failures + still).joined(separator: "\n"))
    }

    /// The confirmation's thread line (UpdateEverythingDialog.tsx:104-112), nil when nothing runs.
    public static func threadsLine(stopped: Int, continuing: Int) -> String? {
        let running = stopped + continuing
        guard running > 0 else { return nil }
        let threads = "\(running) running \(running == 1 ? "thread" : "threads")"
        if stopped == 0 { return "\(threads) will be interrupted and can resume after the restart." }
        if continuing == 0 { return "\(threads) will be interrupted." }
        return "\(threads) will be interrupted. \(continuing) can resume after the restart."
    }

    /// What waits to update: this app, CandyWrapper's own runtime, other servers and providers.
    public struct Pending: Equatable, Sendable {
        public var app: Bool, runtime: Bool, servers: Int, providers: Int
        public init(app: Bool = false, runtime: Bool = false, servers: Int = 0, providers: Int = 0) {
            self.app = app; self.runtime = runtime; self.servers = servers; self.providers = providers
        }
        /// N in the account menu's "Update all (N)".
        public var count: Int { (app ? 1 : 0) + (runtime ? 1 : 0) + servers + providers }
    }

    /// Dither (the user's rule, 2026-10-22): this app's own update shows at once, but servers, the runtime and
    /// providers wait until no thread runs on this Mac, so an update never cuts off local work. Remote turns don't hold them.
    public static func offered(_ pending: Pending, runningOnThisMac: Bool) -> Pending {
        runningOnThisMac ? Pending(app: pending.app) : pending
    }

    static func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func joinList(_ parts: [String]) -> String {
        parts.count <= 2 ? parts.joined(separator: " and ") : parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
    }
}
