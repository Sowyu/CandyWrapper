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
}
