import Foundation
import Testing
@testable import T3Client

struct LocalServerDiscoveryTests {
    @Test func parsesRuntimeStateFromTheLiveFormat() throws {
        // Shape written by serverRuntimeState.ts, as seen in a real ~/.t3 (pid and port changed).
        let json = #"{"version":1,"pid":4242,"port":54660,"origin":"http://127.0.0.1:54660","startedAt":"2026-10-09T10:28:10.285Z","serviceManaged":true}"#
        let state = try LocalServerDiscovery.parseRuntimeState(Data(json.utf8))
        #expect(state.pid == 4242)
        #expect(state.port == 54660)
        #expect(state.origin == "http://127.0.0.1:54660")
        #expect(state.host == nil)
        #expect(state.serviceManaged == true)

        let withHost = #"{"version":1,"pid":1,"host":"0.0.0.0","port":3773,"origin":"http://127.0.0.1:3773","startedAt":"x"}"#
        #expect(try LocalServerDiscovery.parseRuntimeState(Data(withHost.utf8)).host == "0.0.0.0")
        #expect(throws: (any Error).self) { try LocalServerDiscovery.parseRuntimeState(Data("{}".utf8)) }
    }

    /// The owner lock as a 3105 server holds it (serverOwnership.ts): an exclusive transaction on
    /// `server-owner.sqlite`, here from another process, since a process never sees its own POSIX locks.
    @Test func seesTheOwnerLockWithoutTakingIt() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "t3home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "userdata"), withIntermediateDirectories: true)
        #expect(LocalServerDiscovery.ownerLockHolder(home: home) == nil)
        let owner = Process()
        owner.executableURL = URL(filePath: "/usr/bin/python3")
        owner.arguments = ["-I", "-c", "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1],isolation_level=None); c.execute('PRAGMA busy_timeout=0'); c.execute('BEGIN EXCLUSIVE'); print('held',flush=True); time.sleep(30)",
                           home.appending(path: "userdata/server-owner.sqlite").path]
        let out = Pipe()
        owner.standardOutput = out
        try owner.run()
        defer { owner.terminate(); owner.waitUntilExit() }
        // Blocks until the holder has the lock, or reads EOF if python died first.
        #expect(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self) == "held\n")
        #expect(LocalServerDiscovery.ownerLockHolder(home: home) == owner.processIdentifier)
        // Asking twice proves the probe took nothing: the holder still holds it.
        #expect(LocalServerDiscovery.ownerLockHolder(home: home) == owner.processIdentifier)
        owner.terminate()
        owner.waitUntilExit()
        #expect(LocalServerDiscovery.ownerLockHolder(home: home) == nil)
    }

    @Test func parsesActiveVersionAndRejectsPathTricks() {
        let state = #"{"protocol":3,"activeVersion":"0.0.46-nightly.20261009.2861","update":{"status":"committed"}}"#
        #expect(LocalServerDiscovery.parseActiveVersion(Data(state.utf8)) == "0.0.46-nightly.20261009.2861")
        #expect(LocalServerDiscovery.parseActiveVersion(Data(#"{"activeVersion":"../../bin"}"#.utf8)) == nil)
        #expect(LocalServerDiscovery.parseActiveVersion(Data(#"{"protocol":3}"#.utf8)) == nil)
    }

    @Test func resolvesTheActiveRuntimeThenPath() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "t3home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let versionDir = home.appending(path: "runtime/versions/1.2.3")
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let bin = versionDir.appending(path: "t3")
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let pathDir = home.appending(path: "bin")
        try fm.createDirectory(at: pathDir, withIntermediateDirectories: true)
        let onPath = pathDir.appending(path: "t3")
        try Data("#!/bin/sh\n".utf8).write(to: onPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onPath.path)

        // No service state yet: PATH.
        #expect(LocalServerDiscovery.resolveBinary(home: home, path: "/nonexistent:\(pathDir.path)") == onPath)
        try Data(#"{"protocol":3,"activeVersion":"1.2.3"}"#.utf8).write(to: home.appending(path: "runtime/service-state.json"))
        #expect(LocalServerDiscovery.resolveBinary(home: home, path: pathDir.path) == bin)
        #expect(LocalServerDiscovery.resolveBinary(home: home.appending(path: "nope"), path: "/nonexistent") == nil)
    }

    @Test func staleRuntimeFileIsIgnored() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "t3home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "userdata"), withIntermediateDirectories: true)
        // pid 0 is never a live server; a dead pid is how a crashed server's file looks.
        let json = #"{"version":1,"pid":0,"port":1,"origin":"http://127.0.0.1:1","startedAt":"x"}"#
        try Data(json.utf8).write(to: LocalServerDiscovery.runtimeStateURL(home: home))
        #expect(await LocalServerDiscovery.findRunning(home: home) == nil)
        #expect(LocalServerDiscovery.isProcessAlive(getpid()))
        #expect(!LocalServerDiscovery.isProcessAlive(0))
    }

    @Test func bootstrapEnvelopeMatchesTheDesktopSchema() throws {
        let data = LocalServerLauncher.bootstrapEnvelope(port: 4000, home: URL(filePath: "/tmp/h"), credential: "abc")
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(data.dropLast().contains(UInt8(ascii: "\n")) == false)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["mode"] as? String == "desktop")
        #expect(obj["desktopBootstrapToken"] as? String == "abc")
        #expect(obj["port"] as? Int == 4000)
        #expect(obj["host"] as? String == "127.0.0.1")
        #expect(obj["t3Home"] as? String == "/tmp/h")
        #expect(obj["noBrowser"] as? Bool == true)
        #expect(obj["tailscaleServeEnabled"] as? Bool == false)
        #expect(LocalServerLauncher.randomCredential().count == 64)
    }

    @Test func cleanEnvironmentDropsLiveServiceVariables() {
        var config = LocalServerConfiguration(binary: URL(filePath: "/bin/t3"), home: URL(filePath: "/tmp/h"), path: "/usr/bin:/bin")
        config.extraEnvironment = ["T3CODE_TELEMETRY_ENABLED": "false"]
        let env = config.environment()
        #expect(env["T3CODE_HOME"] == "/tmp/h")
        #expect(env["NODE_OPTIONS"] == "--max-semi-space-size=1")
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["T3CODE_TELEMETRY_ENABLED"] == "false")
        #expect(env["T3_SERVICE_LAUNCHER_CONTEXT"] == nil)
        #expect(env["T3_BOOT_SERVICE_UNIT"] == nil)
        #expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "PATH", "T3CODE_HOME",
                                  "NODE_OPTIONS", "T3CODE_TELEMETRY_ENABLED"])
    }

    @Test func remoteAccessFollowsConnectUntilTheUserChooses() {
        let suite = "candykit-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let setting = RemoteAccessSetting(suiteName: suite)
        #expect(setting.isOn == false)
        setting.connectLinked = true
        #expect(setting.isOn == true)
        setting.userChoice = false
        #expect(setting.isOn == false)
        setting.userChoice = nil
        setting.connectLinked = false
        #expect(setting.isOn == false)
    }

    /// `wait: .zero` checks each case once, so the outcome never depends on how long a poll takes.
    @Test func neverClearsTheWayForASecondServer() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "t3home-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appending(path: "userdata"), withIntermediateDirectories: true)
        let noService = home.appending(path: "none.plist")
        let runtimeFile = LocalServerDiscovery.runtimeStateURL(home: home)
        func writeRuntime(startedAt: String) throws {
            // This test process stands in for a server that is alive but answers nothing (port 9).
            try Data(#"{"version":1,"pid":\#(getpid()),"port":9,"origin":"http://127.0.0.1:9","startedAt":"\#(startedAt)"}"#.utf8)
                .write(to: runtimeFile)
        }

        // Nobody runs a server here: start ours.
        #expect(try await LocalServerDiscovery.discover(home: home, servicePlist: noService, wait: .zero) == nil)

        // A live server process that doesn't answer: wait, then refuse.
        try writeRuntime(startedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(.now))
        await #expect(throws: LocalServerDiscoveryError.unresponsive) {
            try await LocalServerDiscovery.discover(home: home, servicePlist: noService, wait: .zero)
        }

        // A file left by a killed server whose pid a newer process took: not a server.
        try writeRuntime(startedAt: "2001-01-01T00:00:00.000Z")
        #expect(try await LocalServerDiscovery.discover(home: home, servicePlist: noService, wait: .zero) == nil)

        // T3's background service owns this home: leave it to the service.
        try fm.removeItem(at: runtimeFile)
        let plist = home.appending(path: "service.plist")
        let unit: [String: Any] = ["Label": "com.t3tools.t3code.service", "EnvironmentVariables": ["T3CODE_HOME": home.path]]
        try PropertyListSerialization.data(fromPropertyList: unit, format: .xml, options: 0).write(to: plist)
        #expect(LocalServerDiscovery.serviceHome(plist: plist)?.path == home.path)
        await #expect(throws: LocalServerDiscoveryError.serviceNotRunning) {
            try await LocalServerDiscovery.discover(home: home, servicePlist: plist, wait: .zero)
        }
    }
}
