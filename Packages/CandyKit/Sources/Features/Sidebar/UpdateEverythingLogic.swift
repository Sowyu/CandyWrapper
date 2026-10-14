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
        public init(environmentId: String, label: String, serverVersion: String?, connected: Bool, canMaintain: Bool, updating: Bool,
                    capabilities: ServerUpdateCapabilities, ownServer: Bool = false, continuesThreads: Bool = false) {
            self.environmentId = environmentId; self.label = label; self.serverVersion = serverVersion; self.connected = connected
            self.canMaintain = canMaintain; self.updating = updating; self.capabilities = capabilities; self.ownServer = ownServer
            self.continuesThreads = continuesThreads
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
            guard m.serverVersion != nil, m.connected else { skip("not connected"); continue }
            guard m.canMaintain else { skip("no permission"); continue }
            guard !m.updating else { skip("already updating"); continue }
            if m.ownServer { targets.append(m); continue }
            guard let path = m.capabilities.selfUpdate else { skip("needs a manual update"); continue }
            if path == .desktopManaged, !m.capabilities.desktopAppUpdate { skip("needs a newer desktop app"); continue }
            if path != .desktopManaged, let v = m.serverVersion, channel(v) != channel(target) { skip("on the \(channel(v)) channel"); continue }
            targets.append(m)
        }
        return (targets, skipped)
    }

    /// `describeUpdateEverything`: "Update this app, 2 servers, and 3 providers", and a line per machine.
    public static func describe(localVersion: String?, servers: [Machine], target: String,
                                providerMachines: [(environmentId: String, label: String, providers: [String])]) -> (summary: String, lines: [String]) {
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
        return (summary, lines)
    }

    /// `UpdateRunMachineStatus` and its tooltip words.
    public enum MachineStatus: String, Sendable { case providers = "updating providers", waiting, downloading, restarting, done, failed }

    /// One machine in a running pass.
    public struct RunMachine: Equatable, Sendable {
        public var environmentId: String, label: String
        public var updatesProviders: Bool, updatesServer: Bool
        /// Set when every update for the machine has finished: true when one failed.
        public var failed: Bool?
        public init(environmentId: String, label: String, updatesProviders: Bool, updatesServer: Bool, failed: Bool? = nil) {
            self.environmentId = environmentId; self.label = label
            self.updatesProviders = updatesProviders; self.updatesServer = updatesServer; self.failed = failed
        }
    }

    /// `UpdateEverythingRun`.
    public struct Run: Equatable, Sendable {
        public enum Phase: Sendable { case providers, servers, installing }
        /// The version this app installs last, nil when it doesn't.
        public var localVersion: String?
        public var phase: Phase
        public var machines: [RunMachine]
        public init(localVersion: String?, phase: Phase, machines: [RunMachine]) {
            self.localVersion = localVersion; self.phase = phase; self.machines = machines
        }
    }

    /// `resolveUpdateRunMachineStatus`.
    public static func status(_ m: RunMachine, phase: Run.Phase, server: ServerUpdateState) -> MachineStatus {
        if let failed = m.failed { return failed ? .failed : .done }
        if phase == .providers, m.updatesProviders { return .providers }
        if m.updatesServer, case .running(let stage, _, _) = server { return stage == .resuming ? .restarting : .downloading }
        return .waiting
    }

    /// `describeUpdateRun`: "Updating…", this app, then "alvin: restarting".
    public static func runTooltip(_ machines: [(label: String, status: MachineStatus)], local: String?) -> String {
        (["Updating…"] + (local.map { ["This app: \($0)"] } ?? []) + machines.map { "\($0.label): \($0.status.rawValue)" }).joined(separator: "\n")
    }

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

    /// `getUpdateEverythingToastView`: one toast for a finished pass, nil when nothing finished.
    public static func toast(_ r: Result, appVersion: String) -> (success: Bool, title: String, description: String?)? {
        let parts = [r.localVersion != nil && r.localVersion == appVersion ? "this app" : nil,
                     count(r.updatedServers, "server"), count(r.updatedProviders, "provider")].compactMap { $0 }
        if r.failures.isEmpty { return parts.isEmpty ? nil : (true, "Updated \(joinList(parts))", nil) }
        return (false, parts.isEmpty ? "Update failed" : "Updated \(joinList(parts))", r.failures.joined(separator: "\n"))
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

    static func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func joinList(_ parts: [String]) -> String {
        parts.count <= 2 ? parts.joined(separator: " and ") : parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
    }
}
