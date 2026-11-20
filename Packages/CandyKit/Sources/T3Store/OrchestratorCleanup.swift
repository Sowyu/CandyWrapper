import Foundation
import T3Protocol

/// What the removed Orchestrator (CandyWrapper 1.14 and older) left behind, and which of it is safe to remove
/// (docs/research/orchestrator-removal-2026-11-21.md). The app's `OrchestratorCleanupRunner` does the calls.
public enum OrchestratorCleanup {
    /// The UserDefaults keys the feature wrote: its settings and its settings-sync stamps.
    public static let configKey = "orchestrator.v1"
    public static let syncKey = "orchestrator.sync.v1"
    /// The machines already cleaned, kept until every machine is done.
    public static let doneKey = "orchestratorCleanup.done"

    /// The title of the always-off task that held its settings for every device.
    public static let settingsTaskTitle = "CandyWrapper Orchestrator settings"
    /// Every "while closed" check task's prompt started with this.
    public static let checkPrefix = "Scheduled check:"
    /// The first sentence of the check prompt CandyWrapper wrote, which nothing else writes.
    public static let checkPrompt = "Scheduled check: CandyWrapper is closed."

    /// The part of the old `OrchestratorConfig` the cleanup needs. Anything else in the stored JSON is ignored.
    public struct Legacy: Decodable, Equatable {
        public struct Machine: Decodable, Equatable {
            public var threadId: String
            public init(threadId: String) { self.threadId = threadId }
        }
        public var enabled = false
        /// The machine it ran on; nil meant the primary machine.
        public var environmentId: String?
        /// Its thread per machine.
        public var machines: [String: Machine] = [:]

        private enum CodingKeys: String, CodingKey { case enabled, environmentId, machines }
        public init(enabled: Bool = false, environmentId: String? = nil, machines: [String: Machine] = [:]) {
            self.enabled = enabled; self.environmentId = environmentId; self.machines = machines
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            environmentId = try? c.decodeIfPresent(String.self, forKey: .environmentId)
            machines = (try? c.decodeIfPresent([String: Machine].self, forKey: .machines)) ?? [:]
        }

        /// Nil for missing data. Data that doesn't parse still counts, with nothing on any server to clean.
        public static func read(_ data: Data?) -> Legacy? {
            guard let data else { return nil }
            return (try? JSONDecoder().decode(Legacy.self, from: data)) ?? Legacy()
        }

        /// Whether it may have left anything on a server: it was switched on or had started a thread.
        public var touchedServers: Bool { enabled || !machines.isEmpty }

        /// The machines to clean: each one that had its thread, plus the one it ran on (`primary` when none was picked).
        /// Nil while that machine isn't known yet.
        public func pending(primary: String?) -> Set<String>? {
            guard touchedServers else { return [] }
            guard let home = environmentId ?? primary else { return nil }
            return Set(machines.keys).union([home])
        }
    }

    /// The tasks to delete on one machine: the settings task, and every check task bound to one of `threads` (the
    /// Orchestrator's own) or carrying the exact check prompt CandyWrapper wrote. Any other task stays.
    public static func tasksToDelete(_ tasks: [ScheduledTask], threads: Set<String>) -> [ScheduledTask] {
        tasks.filter { task in
            if task.title == settingsTaskTitle && task.threadId == nil { return true }
            guard let thread = task.threadId else { return false }
            return threads.contains(thread) && task.prompt.hasPrefix(checkPrefix) || task.prompt.hasPrefix(checkPrompt)
        }
    }

    /// The old relay helper's sessions among a machine's clients: a bot whose label `HelperInstall.sessionLabel` made.
    public static func helperSessions(_ sessions: [AuthClientSession]) -> [AuthClientSession] {
        sessions.filter { $0.client.deviceType == "bot" && HelperInstall.version(fromSessionLabel: $0.client.label ?? "") != nil }
    }

    /// The Orchestrator threads to archive on one machine: its stored thread when still live, never any other.
    public static func threadsToArchive(_ legacy: Legacy, env: String, threads: [ThreadShell]) -> [ThreadShell] {
        guard let id = legacy.machines[env]?.threadId else { return [] }
        return threads.filter { $0.id.rawValue == id && $0.archivedAt == nil && $0.deletedAt == nil }
    }
}
