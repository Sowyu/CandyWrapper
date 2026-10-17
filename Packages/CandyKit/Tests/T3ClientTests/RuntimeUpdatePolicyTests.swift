import Foundation
import Testing
@testable import T3Client

struct RuntimeUpdatePolicyTests {
    let old = "0.1.1-nightly.20261017.3234"
    func release(_ version: String, draft: Bool = false, prerelease: Bool = true) -> RuntimeRelease {
        .init(version: version, draft: draft, prerelease: prerelease,
              assets: ["SHA256SUMS", "t3-\(version)-darwin-arm64.tar.gz"])
    }
    @Test func channelAndNewestReleaseDoNotDependOnClientPin() {
        #expect(RuntimeUpdatePolicy.channel(for: old) == .nightly)
        #expect(RuntimeUpdatePolicy.channel(for: "0.1.1") == .latest)
        #expect(RuntimeUpdatePolicy.channel(for: "0.1.1-preview.20261017.1") == .latest)
        let newer = "0.1.2-nightly.20261020.3400"
        let releases = [release("8.0.0", prerelease: false), release(newer), release(old),
                        release("9.0.0-nightly.20261021.9", draft: true)]
        #expect(RuntimeUpdatePolicy.update(current: old, releases: releases)?.version == newer)
        #expect(RuntimeUpdatePolicy.update(current: newer, releases: [release(old)]) == nil)
        #expect(RuntimeUpdatePolicy.update(current: "0.1.1", releases: releases)?.version == "8.0.0")
        #expect(RuntimeUpdatePolicy.update(current: old, releases: [release("0.1.2-preview.20261020.1")]) == nil)
        var incomplete = release(newer); incomplete.assets.remove("SHA256SUMS")
        #expect(RuntimeUpdatePolicy.update(current: old, releases: [incomplete]) == nil)
    }
    @Test func checksWaitFifteenSecondsAndThrottleActivations() {
        let launch = Date(timeIntervalSince1970: 1_000)
        func check(_ elapsed: Double, last: Double? = nil, owned: Bool = true, busy: Bool = false) -> Bool {
            RuntimeUpdatePolicy.shouldCheck(now: launch.addingTimeInterval(elapsed), launchedAt: launch,
                lastCheck: last.map { launch.addingTimeInterval($0) }, owned: owned, busy: busy)
        }
        #expect(!check(14.9)); #expect(check(15))
        #expect(!check(254.9, last: 15)); #expect(check(255, last: 15))
        #expect(!check(900, owned: false)); #expect(!check(900, busy: true))
        #expect(!check(100, last: 200))
    }
    @Test func githubReleaseDecodesWithoutRejectingFutureFields() throws {
        let data = Data(#"{"tag_name":"v0.1.2-nightly.20261020.3400","draft":false,"prerelease":true,"assets":[{"name":"SHA256SUMS","future":true}],"future":{"value":1}}"#.utf8)
        let release = try JSONDecoder().decode(RuntimeRelease.self, from: data)
        #expect(release.version == "0.1.2-nightly.20261020.3400")
        #expect(release.assets == ["SHA256SUMS"])
    }
    @Test func downloadSurvivesCleanupWithoutBecomingActive() throws {
        let helper = RuntimeStoreTests(), root = try helper.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        try helper.fakeInstall(store, old); try store.activate(old)
        let newer = "0.1.2-nightly.20261020.3400"
        try helper.fakeInstall(store, newer); try store.markDownloaded(newer); store.cleanup()
        #expect(store.state().active == old)
        #expect(store.state().downloaded == newer)
        #expect(store.binary(newer) != nil)
        try store.activate(newer)
        #expect(store.state().active == newer && store.state().previous == old && store.state().downloaded == nil)
    }
}

struct RuntimeTrialTests {
    let old = "0.1.1-nightly.20261017.3234", new = "0.1.2-nightly.20261020.3400"
    @Test(arguments: [false, true]) func failedConnectionRestoresFilesAndVersion(emptyHome: Bool) async throws {
        let helper = RuntimeStoreTests(), root = try helper.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home"), store = RuntimeStore(root: root.appending(path: "runtimes"))
        try helper.fakeInstall(store, old); try store.activate(old)
        try helper.fakeInstall(store, new); try store.markDownloaded(new)
        let database = DatabaseBackup.database(home: home), backup = root.appending(path: "backup")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !emptyHome { try Data("before".utf8).write(to: database) }
        do {
            try await RuntimeTrial.apply(store: store, home: home, target: new, backupDirectory: backup, stop: {},
                startAndConnect: {
                    #expect(DatabaseBackup.pending(database: database, in: backup) != nil)
                    #expect(store.state().active == new)
                    try Data("migrated".utf8).write(to: database)
                    try Data("new WAL".utf8).write(to: URL(filePath: database.path + "-wal"))
                    throw RuntimeTrial.Failure("RPC refused")
                }, unowned: { true })
            Issue.record("The failed RPC was accepted")
        } catch {
            #expect(error.localizedDescription.contains("restored its database"))
        }
        #expect(store.state().active == old)
        if emptyHome { #expect(!FileManager.default.fileExists(atPath: database.path)) }
        else { #expect(try String(contentsOf: database, encoding: .utf8) == "before") }
        #expect(!FileManager.default.fileExists(atPath: database.path + "-wal"))
        #expect(DatabaseBackup.pending(database: database, in: backup) == nil)
    }
    @Test func successKeepsNewDatabaseAndDisarmsRecovery() async throws {
        let helper = RuntimeStoreTests(), root = try helper.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home"), store = RuntimeStore(root: root.appending(path: "runtimes"))
        try helper.fakeInstall(store, old); try store.activate(old)
        try helper.fakeInstall(store, new); try store.markDownloaded(new)
        let database = DatabaseBackup.database(home: home), backup = root.appending(path: "backup")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: database)
        try await RuntimeTrial.apply(store: store, home: home, target: new, backupDirectory: backup, stop: {},
            startAndConnect: { try Data("verified".utf8).write(to: database) }, unowned: { true })
        #expect(store.state().active == new && store.state().previous == old)
        #expect(try String(contentsOf: database, encoding: .utf8) == "verified")
        #expect(DatabaseBackup.pending(database: database, in: backup) == nil)
    }
}
