import Darwin
import Foundation

/// A snapshot of a T3 home's database taken before CandyWrapper starts a newer runtime on it, so a
/// version that fails to start can go back without leaving a database it half migrated. Follows T3's
/// service launcher (serviceLauncher.ts:75-370, 3417bc385): the main file, WAL and shared-memory
/// file, cloned on APFS, checked for space before the server stops, restored over the live files.
public struct DatabaseBackup: Sendable {
    /// `DB_FILE_SUFFIXES`.
    static let suffixes = ["", "-wal", "-shm"]
    /// `RESTORE_MARKER`: a trial or restore remains pending. Removed first when the backup goes.
    /// Recovery must check that no process owns the home before restoring its files.
    static let restoreMarker = "restore-pending"

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
    /// Nil for a missing database unless `includeMissing` records its absence for a trial rollback.
    /// Call it only while no server runs on the home.
    public static func make(database: URL, in directory: URL, includeMissing: Bool = false) throws -> DatabaseBackup? {
        let fm = FileManager.default
        guard includeMissing || fm.fileExists(atPath: database.path) else { return nil }
        // A backup whose restore never finished is the only good copy left.
        if pending(database: database, in: directory) != nil {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path,
                NSLocalizedDescriptionKey: "The database saved before an earlier update is still waiting to be put back"])
        }
        try? fm.removeItem(at: directory)
        let staging = directory.deletingLastPathComponent().appending(path: directory.lastPathComponent + ".staging")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for suffix in suffixes where fm.fileExists(atPath: database.path + suffix) {
                // copyItem clones on APFS, so a large database takes no time and no space. It copies a symlink as
                // a link, where `cp -c` follows it, so it gets the file a symlinked database resolves to.
                try fm.copyItem(atPath: try restoreTarget(database.path + suffix), toPath: staging.appending(path: "database" + suffix).path)
            }
            try fm.moveItem(at: staging, to: directory)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return DatabaseBackup(database: database, directory: directory)
    }

    /// `restoreDatabaseBackup`: puts every saved file back and removes a sidecar the backup didn't have.
    /// Call it only once the server that used the database has exited. It marks the backup first, with
    /// `previous`, the runtime the failed update goes back to (nil for T3's own), so a restore that fails or
    /// is cut off shows up in `pending` and runs again, and goes back, before a server starts on the home.
    public func restore(previous: String? = nil) throws {
        let fm = FileManager.default
        try armRestore(previous: previous)
        for suffix in Self.suffixes {
            let live = database.path + suffix, saved = directory.appending(path: "database" + suffix).path
            guard fm.fileExists(atPath: saved) else {
                // It must go: SQLite would replay the failed version's WAL over the old file.
                do { try fm.removeItem(atPath: live) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
                continue
            }
            // Into the file a symlinked database resolves to, keeping the link. Copied beside it, then renamed
            // over it, so a failed copy leaves the live file whole.
            let target = try Self.restoreTarget(live)
            let incoming = target + ".candy-restore"
            try? fm.removeItem(atPath: incoming)
            try fm.copyItem(atPath: saved, toPath: incoming)
            guard rename(incoming, target) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target]) }
        }
    }

    /// Arm recovery before the first start of a trial version, including a crash before it answers.
    public func armRestore(previous: String?) throws {
        let marker = directory.appending(path: Self.restoreMarker)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data((previous ?? "").utf8).write(to: marker, options: .atomic)
        }
    }

    /// The backup in `directory` when a restore of it started and never finished (`databaseRestorePending`).
    public static func pending(database: URL, in directory: URL) -> DatabaseBackup? {
        FileManager.default.fileExists(atPath: directory.appending(path: restoreMarker).path)
            ? DatabaseBackup(database: database, directory: directory) : nil
    }

    /// The runtime the update that made this backup goes back to, from its restore marker: nil for T3's own.
    public var previousRuntime: String? {
        let text = (try? String(contentsOf: directory.appending(path: Self.restoreMarker), encoding: .utf8)) ?? ""
        return text.isEmpty ? nil : text
    }

    /// `restoreTarget`: where `path`'s symlinks lead, even when the last target is missing. Any other failure,
    /// a link loop included, throws rather than write over the link.
    static func restoreTarget(_ path: String) throws -> String {
        var current = path
        for _ in 0..<40 {
            if let real = realpath(current, nil) {
                defer { free(real) }
                return String(cString: real)
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return current }
            if link.hasPrefix("/") { current = link; continue }
            // Joined without normalizing, so a `..` follows directory links the way the filesystem does.
            guard let parent = realpath((current as NSString).deletingLastPathComponent, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            current = String(cString: parent) + "/" + link
            free(parent)
        }
        throw POSIXError(.ELOOP)
    }

    /// Removes the backup. The restore marker goes first and has to, so a backup that is only partly removed
    /// is never restored again over what a server wrote since.
    public func discard() throws {
        let fm = FileManager.default
        let marker = directory.appending(path: Self.restoreMarker)
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        try? fm.removeItem(at: directory)
    }

    private static func info(_ path: String) -> (size: Int64, device: dev_t, links: nlink_t)? {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        return (s.st_size, s.st_dev, s.st_nlink)
    }
}
