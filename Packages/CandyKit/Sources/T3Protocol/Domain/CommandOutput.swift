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

    public var recommendsCompaction: Bool { !incrementalVacuumEnabled && reclaimableBytes >= 1_073_741_824 }
}
