import Foundation

/// `StorageCleanupReport` (contracts settings.ts:1046-1066, 2994): what one storage cleanup run did.
/// `server.getStorageCleanupReport` streams the latest report (or `null` before the first run) and
/// `server.runStorageCleanup` answers with the report of the run it started. Servers advertise both
/// with the `storageCleanupRun` capability.
public struct StorageCleanupReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// `worktree`, `browser-artifacts` or `logs`.
        public var kind: String
        /// `removed`, `kept` or `failed`.
        public var outcome: String
        public var reason: String
        public var path: String?
        public var threadId: String?
        public var threadTitle: String?
        public var bytes: Double?
        public var files: Double?

        public init(kind: String, outcome: String, reason: String, path: String? = nil, threadId: String? = nil,
                    threadTitle: String? = nil, bytes: Double? = nil, files: Double? = nil) {
            self.kind = kind; self.outcome = outcome; self.reason = reason; self.path = path
            self.threadId = threadId; self.threadTitle = threadTitle; self.bytes = bytes; self.files = files
        }

        init?(json: JSONValue) {
            guard let kind = json["kind"]?.stringValue, let outcome = json["outcome"]?.stringValue else { return nil }
            self.init(kind: kind, outcome: outcome, reason: json["reason"]?.stringValue ?? "", path: json["path"]?.stringValue,
                      threadId: json["threadId"]?.stringValue, threadTitle: json["threadTitle"]?.stringValue,
                      bytes: json["bytes"]?.doubleValue, files: json["files"]?.doubleValue)
        }
    }

    /// `automatic` or `manual`.
    public var trigger: String
    public var startedAt: String
    public var finishedAt: String
    public var entries: [Entry]
    public var removed: Int
    public var kept: Int
    public var failed: Int
    public var omittedCount: Int
    public var bytesFreed: Double

    public init(trigger: String = "manual", startedAt: String, finishedAt: String, entries: [Entry], removed: Int, kept: Int,
                failed: Int, omittedCount: Int = 0, bytesFreed: Double = 0) {
        self.trigger = trigger; self.startedAt = startedAt; self.finishedAt = finishedAt; self.entries = entries
        self.removed = removed; self.kept = kept; self.failed = failed; self.omittedCount = omittedCount; self.bytesFreed = bytesFreed
    }

    /// Nil for `null` (no run yet) or a shape this build can't read.
    public init?(json: JSONValue) {
        guard let finishedAt = json["finishedAt"]?.stringValue, case .array(let items)? = json["entries"] else { return nil }
        let counts = json["counts"]
        self.init(trigger: json["trigger"]?.stringValue ?? "manual", startedAt: json["startedAt"]?.stringValue ?? finishedAt,
                  finishedAt: finishedAt, entries: items.compactMap(Entry.init(json:)),
                  removed: counts?["removed"]?.intValue ?? 0, kept: counts?["kept"]?.intValue ?? 0,
                  failed: counts?["failed"]?.intValue ?? 0, omittedCount: json["omittedCount"]?.intValue ?? 0,
                  bytesFreed: json["bytesFreed"]?.doubleValue ?? 0)
    }

    /// `formatBytes` (apps/web/src/lib/formatBytes.ts, 2994): whole bytes, then KB to TB with 2, 1 or 0 decimals.
    public static func formatBytes(_ value: Double) -> String {
        if value < 1024 { return "\(Int(value.rounded())) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var next = value, i = -1
        repeat { next /= 1024; i += 1 } while next >= 1024 && i < units.count - 1
        return String(format: next >= 100 ? "%.0f %@" : next >= 10 ? "%.1f %@" : "%.2f %@", next, units[i])
    }
}

/// `WorktreeKeepWhen` (contracts settings.ts:920-924, 2994): which local files keep a worktree from cleanup.
/// Absent means `uncommitted-changes`.
public enum WorktreeKeepWhen: String, Sendable, CaseIterable {
    case anyLocalFiles = "any-local-files"
    case uncommittedChanges = "uncommitted-changes"
    case trackedChanges = "tracked-changes"

    /// `KEEP_WHEN_LABELS` (StorageSettings.tsx:147-151).
    public var label: String {
        switch self {
        case .anyLocalFiles: "Any local files"
        case .uncommittedChanges: "Uncommitted changes"
        case .trackedChanges: "Edited tracked files"
        }
    }

    /// The row description (StorageSettings.tsx:579-585).
    public var detail: String {
        switch self {
        case .anyLocalFiles: "Includes ignored files, except node_modules."
        case .trackedChanges: "Deletes untracked and ignored files, including .env."
        case .uncommittedChanges: "Keeps edits and untracked files. Deletes ignored files, including .env."
        }
    }
}
