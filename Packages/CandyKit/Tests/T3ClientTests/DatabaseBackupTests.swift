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

        backup.discard()
        #expect(!FileManager.default.fileExists(atPath: backup.directory.path))
        // A home with no database yet has nothing to back up.
        #expect(try DatabaseBackup.make(database: root.appending(path: "none.sqlite"), in: root.appending(path: "backups/two")) == nil)
    }
}
