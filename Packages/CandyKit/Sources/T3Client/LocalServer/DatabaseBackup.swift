import Darwin
import Foundation

/// A snapshot of a T3 home's database taken before CandyWrapper starts a newer runtime on it, so a
/// version that fails to start can go back without leaving a database it half migrated. Follows T3's
/// service launcher (serviceLauncher.ts:75-370, 3417bc385): the main file, WAL and shared-memory
/// file, cloned on APFS, checked for space before the server stops, restored over the live files.
public struct DatabaseBackup: Sendable {
    /// `DB_FILE_SUFFIXES`.
    static let suffixes = ["", "-wal", "-shm"]

    public let database: URL
    public let directory: URL

    /// `<home>/userdata/statev2.sqlite` (apps/server/src/config.ts:144).
    public static func database(home: URL) -> URL { home.appending(path: "userdata/statev2.sqlite") }

    /// `databaseBackupBlocker`: nil when a backup fits in `root`'s volume, else T3's reason. A clone on
    /// the same APFS volume needs room only for what the new server rewrites: a tenth of the database,
    /// at least 1 GiB. Anything else needs a full copy plus 5%.
    public static func blocker(database: URL, root: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: database.path) else { return nil }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let files = suffixes.compactMap { info(database.path + $0) }
        let size = Double(files.reduce(0) { $0 + $1.size })
        guard let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map(Double.init) else { return nil }
        let full = size * 1.05
        if free >= full { return nil }
        let rootDevice = info(root.path)?.device
        let clones = files.allSatisfy { $0.device == rootDevice && $0.links == 1 }
        let needed = clones ? max(Double(1 << 30), size * 0.1) : full
        if free >= needed { return nil }
        let gb = { (bytes: Double) in String(format: "%.1f", bytes / Double(1 << 30)) }
        return "Not enough free disk space to back up the database before updating: \(gb(needed)) GB needed, \(gb(free)) GB free. Free up disk space and try again. The server was not stopped."
    }

    /// `backupDatabaseOnce`: copies the files that exist into `directory`, through a staging folder.
    /// Nil when the home has no database yet. Call it only while no server runs on the home.
    public static func make(database: URL, in directory: URL) throws -> DatabaseBackup? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: database.path) else { return nil }
        try? fm.removeItem(at: directory)
        let staging = directory.deletingLastPathComponent().appending(path: directory.lastPathComponent + ".staging")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for suffix in suffixes where fm.fileExists(atPath: database.path + suffix) {
                // copyItem clones on APFS, so a large database takes no time and no space.
                try fm.copyItem(atPath: database.path + suffix, toPath: staging.appending(path: "database" + suffix).path)
            }
            try fm.moveItem(at: staging, to: directory)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return DatabaseBackup(database: database, directory: directory)
    }

    /// `restoreDatabaseBackup`: puts every saved file back and removes a sidecar the backup didn't have.
    /// Call it only once the server that used the database has exited.
    // ponytail: no restore marker, so a crash mid-restore or mid-update leaves the backup unused on disk;
    // recover it at the next launch if anyone hits that
    public func restore() throws {
        let fm = FileManager.default
        for suffix in Self.suffixes {
            let live = database.path + suffix, saved = directory.appending(path: "database" + suffix).path
            guard fm.fileExists(atPath: saved) else { try? fm.removeItem(atPath: live); continue }
            // Copied beside the live file, then renamed over it, so a failed copy leaves the live file whole.
            let incoming = live + ".candy-restore"
            try? fm.removeItem(atPath: incoming)
            try fm.copyItem(atPath: saved, toPath: incoming)
            guard rename(incoming, live) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: live]) }
        }
    }

    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func info(_ path: String) -> (size: Int64, device: dev_t, links: nlink_t)? {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        return (s.st_size, s.st_dev, s.st_nlink)
    }
}
