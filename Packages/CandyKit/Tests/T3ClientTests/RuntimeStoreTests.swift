import Foundation
import SQLite3
import Testing
@testable import T3Client
import T3Protocol

/// CandyWrapper's own T3 runtimes: version order, which runtime starts, the downgrade guard and cleanup.
/// Every folder here is a fresh one under the temporary directory.
struct RuntimeStoreTests {
    func scratch() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "cw-runtime-tests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fake installed runtime: the sentinel and an executable `t3`.
    func fakeInstall(_ store: RuntimeStore, _ version: String, complete: Bool = true) throws {
        let dir = store.versionsDir.appending(path: version, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t3 = dir.appending(path: "t3")
        try Data("#!/bin/sh\n".utf8).write(to: t3)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t3.path)
        if complete { try Data((version + "\n").utf8).write(to: dir.appending(path: ".install-complete")) }
    }

    func v(_ s: String) -> T3Version { T3Version(s)! }

    @Test func versionsOrderLikeSemver() {
        let ordered = ["0.0.44", "0.0.45", "0.0.46-nightly.20261009.2861", "0.0.46-nightly.20261011.2994",
                       "0.0.46-nightly.20261014.3093", "0.0.46-preview.20261001.1", "0.0.46", "0.1.0", "1.0.0"].map(v)
        #expect(ordered == ordered.sorted())
        #expect(v("v0.0.45") == v("0.0.45"))
        #expect(v("0.0.46-nightly.9") < v("0.0.46-nightly.10"))
        #expect(v("1.0.0-alpha") < v("1.0.0-alpha.1"))
        for bad in ["", "0.0", "0.0.45.1", "a.b.c", "0.0.45-", "0.0.45/../x", "0.0.x"] { #expect(T3Version(bad) == nil) }
    }

    @Test func choiceTakesTheNewerRuntimeAndNeverGoesBelowTheFloor() {
        let t3 = (v("0.0.46-nightly.20261014.3093"), URL(filePath: "/t3"))
        let ours = (v("0.0.46-nightly.20261009.2861"), URL(filePath: "/ours"))
        let wanted = v("0.0.46-nightly.20261009.2861")
        #expect(RuntimeChoice.decide(t3: t3, ours: ours, wanted: wanted, floor: nil) == .t3(t3.0, t3.1))
        #expect(RuntimeChoice.decide(t3: ours, ours: t3, wanted: wanted, floor: nil) == .ours(t3.0, t3.1))
        #expect(RuntimeChoice.decide(t3: nil, ours: ours, wanted: wanted, floor: nil) == .ours(ours.0, ours.1))
        #expect(RuntimeChoice.decide(t3: nil, ours: nil, wanted: wanted, floor: nil) == .install(wanted))
        // Ours is older than what last used the home: install the floor rather than downgrade.
        #expect(RuntimeChoice.decide(t3: nil, ours: ours, wanted: wanted, floor: t3.0) == .install(t3.0))
        // T3's runtime is newer than ours but still below the floor: neither may start.
        #expect(RuntimeChoice.decide(t3: (v("0.0.45"), URL(filePath: "/old")), ours: nil, wanted: wanted, floor: t3.0) == .install(t3.0))
    }

    @Test func floorReadsOurRecordT3sServiceAndOtherApps() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let records = HomeRecords(file: root.appending(path: "homes.json"))
        #expect(records.floor(home: home) == nil)
        records.recordStart("0.0.46-nightly.20261009.2861", home: home, migration: 58)
        records.recordStart("0.0.45", home: home, migration: 50)
        #expect(records.home(home).highest == "0.0.46-nightly.20261009.2861")
        #expect(records.floor(home: home) == v("0.0.46-nightly.20261009.2861"))
        try FileManager.default.createDirectory(at: home.appending(path: "runtime"), withIntermediateDirectories: true)
        try Data(#"{"protocol":3,"activeVersion":"0.0.45","update":{"targetVersion":"0.0.46-nightly.20261011.2994","status":"pending"}}"#.utf8)
            .write(to: home.appending(path: "runtime/service-state.json"))
        #expect(records.floor(home: home) == v("0.0.46-nightly.20261011.2994"))
        #expect(records.floor(home: home, others: ["0.0.46-nightly.20261014.3093", "not a version"]) == v("0.0.46-nightly.20261014.3093"))
    }

    @Test func theGuardRefusesADowngradeByVersionAndByMigration() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let records = HomeRecords(file: root.appending(path: "homes.json"))
        let old = v("0.0.46-nightly.20261009.2861"), new = v("0.0.46-nightly.20261011.2994")
        #expect(records.refusal(candidate: old, home: home, floor: new, migration: nil)?.contains("T3 Code \(new) already used this data") == true)
        #expect(records.refusal(candidate: new, home: home, floor: new, migration: nil) == nil)
        // 2861 left migration 58 behind; a database at 60 came from something newer.
        records.recordStart(old.raw, home: home, migration: 58)
        #expect(records.refusal(candidate: old, home: home, floor: nil, migration: 58) == nil)
        #expect(records.refusal(candidate: old, home: home, floor: nil, migration: 60)?.contains("a newer T3 Code changed its database") == true)
        // A version CandyWrapper never ran has no migration record, so only the floor applies.
        #expect(records.refusal(candidate: new, home: home, floor: nil, migration: 60) == nil)
    }

    @Test func databaseMigrationIsReadOnlyAndToleratesNoDatabase() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HomeRecords.databaseMigration(home: home) == nil)
        let userdata = home.appending(path: "userdata")
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(userdata.appending(path: "statev2.sqlite").path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE effect_sql_migrations (migration_id INTEGER PRIMARY KEY, name TEXT); INSERT INTO effect_sql_migrations VALUES (1,'a'),(60,'b');", nil, nil, nil)
        sqlite3_close(db)
        let before = try Data(contentsOf: userdata.appending(path: "statev2.sqlite"))
        #expect(HomeRecords.databaseMigration(home: home) == 60)
        #expect(try Data(contentsOf: userdata.appending(path: "statev2.sqlite")) == before)
    }

    @Test func storeKeepsTheActiveAndPreviousVersionsOnly() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        #expect(store.active() == nil)
        try fakeInstall(store, "0.0.45")
        try store.activate("0.0.45")
        try fakeInstall(store, "0.0.46-nightly.20261009.2861")
        try store.activate("0.0.46-nightly.20261009.2861")
        // Leftovers: an unfinished install and a staging folder.
        try fakeInstall(store, "0.0.46-nightly.20261014.3093", complete: false)
        try FileManager.default.createDirectory(at: store.versionsDir.appending(path: ".staging-leftover"), withIntermediateDirectories: true)
        #expect(store.binary("0.0.46-nightly.20261014.3093") == nil)
        #expect(store.binary("../evil") == nil)
        // An install lands, then becomes active; 0.0.45 is now two behind and goes with the leftovers.
        try fakeInstall(store, "0.0.46-nightly.20261011.2994")
        try store.activate("0.0.46-nightly.20261011.2994")
        #expect(store.state() == RuntimeStore.State(active: "0.0.46-nightly.20261011.2994", previous: "0.0.46-nightly.20261009.2861"))
        #expect(store.active()?.version == v("0.0.46-nightly.20261011.2994"))
        let left = try FileManager.default.contentsOfDirectory(atPath: store.versionsDir.path).sorted()
        #expect(left == ["0.0.46-nightly.20261009.2861", "0.0.46-nightly.20261011.2994"])
        // Activating the same version again keeps the previous one.
        try store.activate("0.0.46-nightly.20261011.2994")
        #expect(store.state().previous == "0.0.46-nightly.20261009.2861")
    }

    @Test func checksumsParseLikeT3() {
        let sums = RuntimeStore.checksums("""
        \(String(repeating: "A", count: 64))  t3-1.0.0-darwin-arm64.tar.gz
        \(String(repeating: "b", count: 64)) *t3-1.0.0-linux-x64.tar.gz
        not a line
        """)
        #expect(sums["t3-1.0.0-darwin-arm64.tar.gz"] == String(repeating: "a", count: 64))
        #expect(sums["t3-1.0.0-linux-x64.tar.gz"] == String(repeating: "b", count: 64))
        #expect(sums.count == 2)
        #expect(RuntimeStore.releaseDirectory("1.0.0", baseURL: URL(string: "https://mirror.example/rel")!).absoluteString == "https://mirror.example/rel/v1.0.0")
    }

    /// The real download from GitHub, verify and unpack, into `CANDY_RUNTIME_INSTALL_TEST=<folder under /tmp>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDY_RUNTIME_INSTALL_TEST"]?.hasPrefix("/tmp/") == true,
                   "downloads a T3 runtime: set CANDY_RUNTIME_INSTALL_TEST to a folder under /tmp"))
    func realInstallIntoATemporaryFolder() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["CANDY_RUNTIME_INSTALL_TEST"])
        let store = RuntimeStore(root: URL(filePath: root, directoryHint: .isDirectory))
        let version = "0.0.46-nightly.20261011.2994"
        let binary = try await store.install(version)
        #expect(store.binary(version) == binary)
        try store.activate(version)
        #expect(store.active()?.version == v(version))
    }
}
