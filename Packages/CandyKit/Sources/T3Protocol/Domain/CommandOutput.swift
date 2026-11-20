import Foundation

/// `orchestration.subscribeCommandOutput` (3234 contracts orchestrationV2.ts:3064-3089).
public struct CommandOutputFrame: Codable, Hashable, Sendable {
    public var kind: String
    public var text: String
    public var truncated: Bool
    public var running: Bool
}

/// `server.getDatabaseStorage` (3234 contracts settings.ts, DatabaseStorageStatus).
public struct DatabaseStorageStatus: Codable, Hashable, Sendable {
    public var databaseBytes: Double
    public var reclaimableBytes: Double
    public var incrementalVacuumEnabled: Bool
    public var compactCommand: String
    /// The server runs the repair itself and the desktop app or service restarts it (Nightly 4928, #32941).
    public var canReclaim: Bool?
    /// Why the last repair started from Settings failed.
    public var reclaimFailure: String?

    public var recommendsCompaction: Bool { !incrementalVacuumEnabled && reclaimableBytes >= 1_073_741_824 }
    /// `databaseReclaimMinutes` (contracts settings.ts:1305-1309): 30 s per GiB of live data, at least a minute.
    public var reclaimMinutes: Int { max(1, Int(ceil((databaseBytes - reclaimableBytes) / 1_073_741_824 / 2))) }
    public static let reclaimMethod = "server.reclaimDatabaseSpace"
}
