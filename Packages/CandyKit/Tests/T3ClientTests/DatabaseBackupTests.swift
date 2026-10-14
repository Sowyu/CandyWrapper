import Foundation
import Testing
@testable import T3Client

struct DatabaseBackupTests {
    /// A trial that migrated the database and left a WAL behind goes back to the exact files it started from.
    @Test func restoresTheSnapshotAndDropsSidecarsItDidNotHave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dbbackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let database = DatabaseBackup.database(home: home)
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: database)
        try Data("shm".utf8).write(to: URL(filePath: database.path + "-shm"))

        #expect(DatabaseBackup.blocker(database: database, root: root.appending(path: "backups")) == nil)
        let backup = try #require(try DatabaseBackup.make(database: database, in: root.appending(path: "backups/one")))

        try Data("migrated".utf8).write(to: database)
        try Data("wal".utf8).write(to: URL(filePath: database.path + "-wal"))
        try backup.restore()
        #expect(try String(contentsOf: database, encoding: .utf8) == "before")
        #expect(try String(contentsOf: URL(filePath: database.path + "-shm"), encoding: .utf8) == "shm")
        #expect(!FileManager.default.fileExists(atPath: database.path + "-wal"))

        try backup.discard()
        #expect(!FileManager.default.fileExists(atPath: backup.directory.path))
        // A home with no database yet has nothing to back up.
        #expect(try DatabaseBackup.make(database: root.appending(path: "none.sqlite"), in: root.appending(path: "backups/two")) == nil)
    }

    /// A database that links to its file elsewhere is saved and put back through the link, which stays a link.
    @Test func followsASymlinkedDatabase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "dbbackup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let real = root.appending(path: "elsewhere/state.sqlite")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: real)
        let database = DatabaseBackup.database(home: root.appending(path: "home"))
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Relative, so a copied link would dangle in the backup folder.
        try fm.createSymbolicLink(atPath: database.path, withDestinationPath: "../../elsewhere/state.sqlite")

        let backup = try #require(try DatabaseBackup.make(database: database, in: root.appending(path: "backups/one")))
        try Data("migrated".utf8).write(to: real)
        try backup.restore()
        #expect(try String(contentsOf: real, encoding: .utf8) == "before")
        #expect(try fm.destinationOfSymbolicLink(atPath: database.path) == "../../elsewhere/state.sqlite")
    }

    /// A restore that fails stays pending, so it runs again before a server starts, and no new backup replaces it.
    @Test func aFailedRestoreStaysPending() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "dbbackup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let database = DatabaseBackup.database(home: root.appending(path: "home"))
        let userdata = database.deletingLastPathComponent()
        try fm.createDirectory(at: userdata, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: database)
        let directory = root.appending(path: "backups/one")
        let backup = try #require(try DatabaseBackup.make(database: database, in: directory))
        #expect(DatabaseBackup.pending(database: database, in: directory) == nil)

        try Data("migrated".utf8).write(to: database)
        // A folder that takes no new file fails the restore after it marked the backup.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: userdata.path)
        #expect(throws: (any Error).self) { try backup.restore(previous: "0.0.46-nightly.20261011.2994") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: userdata.path)
        #expect(try String(contentsOf: database, encoding: .utf8) == "migrated")

        let pending = try #require(DatabaseBackup.pending(database: database, in: directory))
        // The marker keeps the runtime to go back to for a restore that runs again after a crash.
        #expect(pending.previousRuntime == "0.0.46-nightly.20261011.2994")
        #expect(throws: (any Error).self) { try DatabaseBackup.make(database: database, in: directory) }
        try pending.restore()
        #expect(try String(contentsOf: database, encoding: .utf8) == "before")
        try pending.discard()
        #expect(DatabaseBackup.pending(database: database, in: directory) == nil)
        #expect(!fm.fileExists(atPath: directory.path))
    }
}
