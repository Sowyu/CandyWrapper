import Darwin
import Foundation
import Testing
@testable import T3Client
import T3Protocol

/// Launches a real `t3 serve` through LocalServerLauncher against a throwaway home under
/// ../CandyWrapper-research (never ~/.t3). It reads ~/.t3/runtime/service-state.json only to
/// find the installed binary. Skips when no runtime is installed.
@Suite(.serialized)
struct LocalServerIntegrationTests {
    static let research = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "CandyWrapper-research")
    static let home = research.appending(path: "sandbox-localserver/t3home", directoryHint: .isDirectory)
    static let path = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let identity = ClientIdentity(appVersion: "0.0.0-candykit-test")
    static let keychain = CredentialStore(service: "dev.candywrapper.test.local-server")

    static func configuration() throws -> LocalServerConfiguration {
        guard let binary = LocalServerDiscovery.resolveBinary(home: LocalServerDiscovery.defaultHome, path: path) else {
            throw LocalServerLaunchError.notReady
        }
        precondition(!home.path.hasPrefix(LocalServerDiscovery.defaultHome.path), "never start a server against ~/.t3")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var config = LocalServerConfiguration(binary: binary, home: home, path: path)
        config.extraEnvironment = ["T3CODE_TELEMETRY_ENABLED": "false"]
        config.logFile = home.deletingLastPathComponent().appending(path: "server.stderr.log")
        return config
    }

    @Test(.timeLimit(.minutes(5)))
    func launchAuthenticateConnectStopRestart() async throws {
        guard (try? Self.configuration()) != nil else {
            print("no installed T3 runtime; skipping")
            return
        }
        #expect(await LocalServerDiscovery.findRunning(home: Self.home) == nil, "a server already runs for the test home")

        let lifecycle = LocalServerLifecycle.live(home: Self.home, identity: Self.identity, credentials: Self.keychain,
                                                  configuration: { try Self.configuration() }, remoteAccess: false)
        // 1. Start, bootstrap auth.
        guard case .owned(let first) = try await lifecycle.ensureRunning() else {
            Issue.record("expected a server we own"); return
        }
        let environmentId = first.descriptor.environmentId
        defer { try? Self.keychain.delete(environmentId: environmentId) }
        #expect(try Self.keychain.load(environmentId: environmentId) == first.accessToken)
        let http = EnvironmentHTTP(baseURL: first.origin)
        let session = try await http.session(token: first.accessToken)
        #expect(session.authenticated)
        #expect(first.descriptor.isCompatible)

        // Discovery sees it, so a second app launch would reuse it instead of starting another.
        let found = await LocalServerDiscovery.findRunning(home: Self.home)
        #expect(found?.runtime.pid == first.pid)

        // 2. Connect over WebSocket RPC with the bearer.
        let supervisor = ConnectionSupervisor(dependencies: .init(connect: ConnectionSupervisor.directConnector(
            http: http, environmentId: environmentId, identity: Self.identity, token: { first.accessToken })))
        await supervisor.connect()
        #expect(await eventually(seconds: 15) { await supervisor.state.phase == .connected })
        let config = try await supervisor.request("server.getConfig")
        #expect(config["environment"]?["environmentId"]?.stringValue == environmentId)

        // Joining a server someone else started, as the app does with a running T3: mint a code
        // with the CLI while the server runs, redeem it, and the new bearer works.
        let code = try await LocalServerLauncher.mintPairingCode(binary: try Self.configuration().binary,
                                                                 home: Self.home, path: Self.path)
        let (pairedDescriptor, paired) = try await http.pair(code: code, identity: Self.identity)
        #expect(pairedDescriptor.environmentId == environmentId)
        #expect(try await http.session(token: paired.accessToken).authenticated)

        // Remote access default comes from the link state.
        let suite = "candykit-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let remote = RemoteAccessSetting(suiteName: suite)
        #expect(try await remote.refresh(http: http, token: first.accessToken) == false)
        #expect(remote.connectLinked == false)

        // 3. Priority: background while no run, normal when one starts.
        #expect(ProcessTools.isBackground(first.pid))
        await lifecycle.update(.init(activeRuns: 1))
        #expect(!ProcessTools.isBackground(first.pid))
        await lifecycle.update(.init(activeRuns: 0))
        #expect(ProcessTools.isBackground(first.pid))

        // 4. Stop: no process of ours is left, and the runtime file is gone.
        let family = ([first.pid] + ProcessTools.descendants(of: first.pid)).compactMap(ProcessIdentity.of)
        await supervisor.disconnect()
        let stopStart = ContinuousClock.now
        await lifecycle.shutdown()
        print("stop took \(ContinuousClock.now - stopStart), family of \(family.count)")
        #expect(first.hasExited)
        #expect(family.allSatisfy { !$0.isAlive })
        #expect(await LocalServerDiscovery.findRunning(home: Self.home) == nil)
        #expect(await lifecycle.phase == .stopped)

        // 5. Restart on use: a new process and a new bearer that works.
        guard case .owned(let second) = try await lifecycle.ensureRunning() else {
            Issue.record("expected a server we own"); return
        }
        #expect(second.pid != first.pid)
        #expect(second.descriptor.environmentId == environmentId)
        #expect(try await EnvironmentHTTP(baseURL: second.origin).session(token: second.accessToken).authenticated)
        let secondFamily = ([second.pid] + ProcessTools.descendants(of: second.pid)).compactMap(ProcessIdentity.of)
        await lifecycle.shutdown()
        #expect(secondFamily.allSatisfy { !$0.isAlive })
    }
}

/// Measures what background priority does to an idle server we started. Opt in with
/// `CANDY_MEASURE_PRIORITY=1 swift test --filter BackgroundPriorityMeasurement`: it takes about
/// two minutes. Prints CPU time, wakeups and billed energy for the server tree per phase, and
/// phase boundaries so a concurrent `powermetrics` run can be lined up with them.
struct BackgroundPriorityMeasurement {
    struct Usage {
        var cpuNs: UInt64 = 0, wakeups: UInt64 = 0, energyNj: UInt64 = 0
        static func - (a: Usage, b: Usage) -> Usage {
            Usage(cpuNs: a.cpuNs &- b.cpuNs, wakeups: a.wakeups &- b.wakeups, energyNj: a.energyNj &- b.energyNj)
        }
    }

    /// swift test holds test stdout until the end, so lines also go to `CANDY_MEASURE_LOG` live.
    func log(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["CANDY_MEASURE_LOG"],
              let h = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil)
        else { return }
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        try? h.close()
    }

    static func usage(_ pids: [pid_t]) -> Usage {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        var total = Usage()
        for pid in pids {
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else { continue }
            total.cpuNs += (info.ri_user_time + info.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
            total.wakeups += info.ri_pkg_idle_wkups + info.ri_interrupt_wkups
            total.energyNj += info.ri_billed_energy
        }
        return total
    }

    @Test(.timeLimit(.minutes(5)))
    func idleServerNormalVersusBackground() async throws {
        guard ProcessInfo.processInfo.environment["CANDY_MEASURE_PRIORITY"] == "1",
              let config = try? LocalServerIntegrationTests.configuration() else { return }
        let server = try await LocalServerLauncher.launch(config, identity: LocalServerIntegrationTests.identity, credentials: nil)
        defer { Task { await LocalServerLauncher.stop(server) } }
        log("measure: server pid \(server.pid)")
        try await Task.sleep(for: .seconds(15)) // startup work settles
        let phase: Duration = .seconds(30)
        for (name, background) in [("normal", false), ("background", true), ("normal-again", false)] {
            LocalServerLauncher.setBackground(background, server: server)
            let pids = [server.pid] + ProcessTools.descendants(of: server.pid)
            let start = Self.usage(pids)
            log("measure: phase \(name) start \(Date()) base priority \(ProcessTools.basePriority(server.pid) ?? -1)")
            try await Task.sleep(for: phase)
            let d = Self.usage(pids) - start
            let s = Double(phase.components.seconds)
            log(String(format: "measure: phase %@ cpu %.2f ms/s, wakeups %.1f/s, energy %.3f mJ/s, pids %d",
                         name, Double(d.cpuNs) / 1e6 / s, Double(d.wakeups) / s, Double(d.energyNj) / 1e6 / s, pids.count))
        }
        await LocalServerLauncher.stop(server)
        #expect(server.hasExited)
    }
}
