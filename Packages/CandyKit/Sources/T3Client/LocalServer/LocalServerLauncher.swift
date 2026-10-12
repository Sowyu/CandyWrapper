import Darwin
import Foundation
import Security
import T3Protocol

/// What to start. `home` is the T3 home the server owns (`~/.t3` in the app, a throwaway
/// directory in tests).
public struct LocalServerConfiguration: Sendable {
    public var binary: URL
    public var home: URL
    /// Nil picks a free loopback port.
    public var port: Int?
    /// The user's PATH so provider CLIs such as `claude` resolve. The server also merges in its
    /// login shell's PATH (apps/server/src/os-jank.ts:20-35).
    public var path: String
    /// Measured: idle footprint 313 to 246 MB. No `--max-old-space-size`, a heap cap can crash
    /// the server on big threads.
    public var nodeOptions: String = "--max-semi-space-size=1"
    /// Added to the clean environment, for example `T3CODE_TELEMETRY_ENABLED=false` in tests.
    public var extraEnvironment: [String: String] = [:]
    /// stderr goes here (appended). stdout is discarded: `t3 serve` prints a 5-minute admin
    /// pairing token there.
    public var logFile: URL?
    /// How long to wait for the descriptor to answer.
    public var readinessTimeout: Duration = .seconds(60)

    public init(binary: URL, home: URL, port: Int? = nil, path: String) {
        self.binary = binary
        self.home = home
        self.port = port
        self.path = path
    }

    /// The child's whole environment. Built from scratch (protocol.md 11.4): inheriting
    /// `T3_SERVICE_LAUNCHER_CONTEXT` or `T3CODE_HOME` would attach to the live service.
    public func environment() -> [String: String] {
        let user = NSUserName()
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": user,
            "LOGNAME": user,
            "SHELL": ProcessTools.loginShell,
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": path,
            "T3CODE_HOME": home.path,
            "NODE_OPTIONS": nodeOptions,
        ]
        env.merge(extraEnvironment) { _, new in new }
        return env
    }
}

/// A server this app started. Only these get stopped or reprioritized.
public final class LaunchedLocalServer: Sendable {
    public let pid: pid_t
    public let identity: ProcessIdentity
    public let origin: URL
    public let home: URL
    public let descriptor: EnvironmentDescriptor
    /// Bearer from the bootstrap exchange. Also saved in the Keychain under the environment id.
    public let accessToken: String
    let watcher: ChildExitWatcher

    init(pid: pid_t, identity: ProcessIdentity, origin: URL, home: URL, descriptor: EnvironmentDescriptor,
         accessToken: String, watcher: ChildExitWatcher) {
        self.pid = pid
        self.identity = identity
        self.origin = origin
        self.home = home
        self.descriptor = descriptor
        self.accessToken = accessToken
        self.watcher = watcher
    }

    public var hasExited: Bool { watcher.exitStatus != nil }

    /// Returns when the process exits, for any reason.
    public func waitForExit() async { _ = await watcher.waitForExit() }
}

public enum LocalServerLaunchError: Error, Sendable, Equatable, CustomStringConvertible {
    case spawnFailed(Int32)
    case exitedDuringStartup(Int32)
    case notReady
    case bootstrapRejected(String)
    case incompatible(String)

    public var description: String {
        switch self {
        case .spawnFailed(let e): "Could not start the T3 server: \(String(cString: strerror(e)))"
        case .exitedDuringStartup(let s): "The T3 server exited during startup (status \(s))."
        case .notReady: "The T3 server did not become ready."
        case .bootstrapRejected(let m): "The T3 server rejected the bootstrap credential: \(m)"
        case .incompatible(let m): "The T3 server is not compatible: \(m)"
        }
    }
}

/// Starts `t3 serve` the way the desktop app starts its backend, stops it, and sets its priority.
public enum LocalServerLauncher {
    /// T3's server exit timeout. A clean shutdown finishes well inside it.
    public static let stopTimeout: Duration = .seconds(90)

    /// Spawn, wait for readiness, then exchange the bootstrap credential for a bearer.
    ///
    /// Auth follows the desktop app (DesktopBackendConfiguration.ts:560-606,
    /// DesktopLocalEnvironmentAuth.ts): a random credential travels in a one-line JSON envelope
    /// on fd 3 (`--bootstrap-fd 3`). The server seeds it as a `desktop-bootstrap` grant with
    /// administrative scopes, 24 h and unbounded uses (PairingGrantStore.ts:335-350), and
    /// `POST /oauth/token` turns it into a bearer. The credential never touches disk, argv or env.
    public static func launch(_ config: LocalServerConfiguration, identity: ClientIdentity,
                              credentials: CredentialStore?) async throws -> LaunchedLocalServer {
        let port = try config.port ?? ProcessTools.freeLoopbackPort()
        let credential = randomCredential()
        let envelope = bootstrapEnvelope(port: port, home: config.home, credential: credential)
        let args = [config.binary.path, "serve", "--host", "127.0.0.1", "--port", String(port), "--no-browser",
                    "--base-dir", config.home.path, "--bootstrap-fd", "3"]
        let pid = try spawn(executable: config.binary.path, arguments: args, environment: config.environment(),
                            fd3Payload: envelope, stderrPath: config.logFile?.path)
        let watcher = ChildExitWatcher(pid: pid)
        guard let processIdentity = ProcessIdentity.of(pid) else {
            _ = await watcher.waitForExit(timeout: .seconds(1))
            throw LocalServerLaunchError.exitedDuringStartup(watcher.exitStatus ?? -1)
        }
        let origin = URL(string: "http://127.0.0.1:\(port)")!
        do {
            let descriptor = try await waitForDescriptor(origin: origin, watcher: watcher, timeout: config.readinessTimeout)
            guard descriptor.isCompatible else {
                throw LocalServerLaunchError.incompatible("orchestration protocol \(descriptor.protocolVersion)")
            }
            let token = try await exchange(credential: credential, origin: origin, identity: identity, watcher: watcher)
            // A Keychain failure costs a re-exchange next launch, not this launch.
            try? credentials?.save(token: token, environmentId: descriptor.environmentId)
            return LaunchedLocalServer(pid: pid, identity: processIdentity, origin: origin, home: config.home,
                                       descriptor: descriptor, accessToken: token, watcher: watcher)
        } catch {
            await terminate(pid: pid, identity: processIdentity, watcher: watcher, timeout: .seconds(10))
            throw error
        }
    }

    /// SIGTERM, wait up to `timeout` (T3's own exit timeout is 90 s), then SIGKILL the process
    /// group. Descendants recorded before the signal that outlive the server (terminal shells
    /// run in their own sessions) get SIGTERM, then SIGKILL. Signals only recorded identities.
    public static func stop(_ server: LaunchedLocalServer, timeout: Duration = stopTimeout) async {
        await terminate(pid: server.pid, identity: server.identity, watcher: server.watcher, timeout: timeout)
    }

    /// Which app process started which server. Written after a launch and deleted after a stop,
    /// so the next start can stop a server whose app crashed or was force-quit. Without it the
    /// orphan looks like someone else's server and gets reused forever, never idle-stopped.
    /// `handoff` marks a server the app left running when it quit to install an update: the next
    /// launch, of whichever version and from whichever path, adopts it instead of stopping it.
    public struct OwnerRecord: Codable, Sendable, Equatable {
        public var server: ProcessIdentity
        public var owner: ProcessIdentity
        public var handoff: Bool?
    }

    public static func recordOwnership(of server: LaunchedLocalServer, at url: URL, handoff: Bool = false) {
        guard let owner = ProcessIdentity.of(getpid()) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = OwnerRecord(server: server.identity, owner: owner, handoff: handoff ? true : nil)
        try? JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    /// Takes over the server a previous app process handed off for an update: finds it through the
    /// home's runtime file (the exact recorded process, not a pid reused since), and authenticates
    /// with the token saved in the Keychain at its launch. Without one it pairs, as this is our own
    /// server. Nil when there's no handoff or the server is gone (the record goes too), or when it
    /// can't be reached; the record then stays, and `stopOrphan` leaves it alone.
    public static func adopt(recordedAt url: URL, home: URL, identity: ClientIdentity, credentials: CredentialStore?,
                             configuration: () throws -> LocalServerConfiguration,
                             wait: Duration = .seconds(20)) async -> LaunchedLocalServer? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(OwnerRecord.self, from: data), record.handoff == true else { return nil }
        guard record.server.isAlive else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // A server that is up but busy may answer late; discovery waits for it rather than give up.
        guard let running = try? await LocalServerDiscovery.discover(home: home, wait: wait),
              running.runtime.pid == record.server.pid else { return nil }
        let environmentId = running.descriptor.environmentId
        var token = try? credentials?.load(environmentId: environmentId)
        if token == nil, let config = try? configuration(),
           let code = try? await mintPairingCode(binary: config.binary, home: home, path: config.path),
           let (_, result) = try? await EnvironmentHTTP(baseURL: running.origin).pair(code: code, identity: identity) {
            token = result.accessToken
            try? credentials?.save(token: result.accessToken, environmentId: environmentId)
        }
        guard let token, record.server.isAlive else { return nil }
        return LaunchedLocalServer(pid: record.server.pid, identity: record.server, origin: running.origin, home: home,
                                   descriptor: running.descriptor, accessToken: token,
                                   watcher: ChildExitWatcher(adopting: record.server))
    }

    /// Stops the recorded server if the app process that started it is gone, unless it was handed
    /// off for an update. Signals only the exact recorded process: a pid reused since then has a
    /// different start time.
    public static func stopOrphan(recordedAt url: URL, timeout: Duration = .seconds(10)) async {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let record = try? JSONDecoder().decode(OwnerRecord.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard !record.owner.isAlive, record.handoff != true else { return }
        try? FileManager.default.removeItem(at: url)
        guard record.server.signal(SIGTERM) else { return }
        let deadline = ContinuousClock.now + timeout
        // ponytail: 100 ms polls, only on the first start after a crash, for at most `timeout`
        while record.server.isAlive, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        record.server.signal(SIGKILL)
    }

    /// Background priority for a server we started and its children, or back to normal.
    @discardableResult
    public static func setBackground(_ background: Bool, server: LaunchedLocalServer) -> [pid_t] {
        guard server.identity.isAlive else { return [] }
        return ProcessTools.setBackground(background, root: server.pid)
    }

    /// `t3 auth pairing create --json` for a server we did not start: a one-time code to redeem
    /// at `/oauth/token`. It writes a pairing row into `home`'s database, so the app must ask
    /// the user before running it against `~/.t3`.
    public static func mintPairingCode(binary: URL, home: URL, path: String, label: String = "CandyWrapper") async throws -> String {
        var config = LocalServerConfiguration(binary: binary, home: home, path: path)
        config.nodeOptions = ""
        let output = try await run(executable: binary.path,
                                   arguments: [binary.path, "auth", "pairing", "create", "--base-dir", home.path,
                                               "--label", label, "--json"],
                                   environment: config.environment())
        // T3's own readers take the first `{` to the last `}` (packages/ssh/src/tunnel.ts:180-198).
        guard let start = output.firstIndex(of: UInt8(ascii: "{")), let end = output.lastIndex(of: UInt8(ascii: "}")),
              let json = try? JSONDecoder().decode([String: JSONValue].self, from: output[start...end]),
              let code = json["credential"]?.stringValue
        else { throw LocalServerLaunchError.bootstrapRejected("no credential in `t3 auth pairing create` output") }
        return code
    }

    // MARK: - Internals

    static func bootstrapEnvelope(port: Int, home: URL, credential: String) -> Data {
        // DesktopBackendBootstrap (packages/contracts/src/desktopBootstrap.ts). Mode "desktop"
        // is a schema literal; flags still win over it (cli/config.ts:281-310).
        let object: [String: Any] = [
            "mode": "desktop", "noBrowser": true, "port": port, "t3Home": home.path, "host": "127.0.0.1",
            "desktopBootstrapToken": credential, "tailscaleServeEnabled": false, "tailscaleServePort": 443,
        ]
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func randomCredential() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func waitForDescriptor(origin: URL, watcher: ChildExitWatcher, timeout: Duration) async throws -> EnvironmentDescriptor {
        var http = EnvironmentHTTP(baseURL: origin)
        http.timeout = 2
        let deadline = ContinuousClock.now + timeout
        // ponytail: 150 ms readiness poll during startup only, like the desktop's own loop
        // (DesktopBackendManager.ts:378-399). A stdout "ready" parser would save a few ms.
        while ContinuousClock.now < deadline {
            if let status = watcher.exitStatus { throw LocalServerLaunchError.exitedDuringStartup(status) }
            if let descriptor = try? await http.descriptor() { return descriptor }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw LocalServerLaunchError.notReady
    }

    /// Retries transient failures for 15 s like DesktopLocalEnvironmentAuth.ts:20-35.
    private static func exchange(credential: String, origin: URL, identity: ClientIdentity, watcher: ChildExitWatcher) async throws -> String {
        let http = EnvironmentHTTP(baseURL: origin)
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            do {
                return try await http.exchangeToken(TokenExchangeRequest(subjectToken: credential, clientLabel: identity.label)).accessToken
            } catch let error as EnvironmentHTTPError {
                let transient: Bool = switch error {
                case .network, .timedOut: true
                case .status(let code, _): [502, 503, 504].contains(code)
                case .invalidResponse: false
                }
                guard transient, ContinuousClock.now < deadline, watcher.exitStatus == nil else {
                    throw LocalServerLaunchError.bootstrapRejected(error.description)
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func terminate(pid: pid_t, identity: ProcessIdentity, watcher: ChildExitWatcher, timeout: Duration) async {
        guard watcher.exitStatus == nil else { return }
        let family = ProcessTools.descendants(of: pid).compactMap(ProcessIdentity.of)
        kill(pid, SIGTERM)
        if !(await watcher.waitForExit(timeout: timeout)) {
            // setsid at spawn made the server a group leader, so -pid is exactly its group.
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            _ = await watcher.waitForExit(timeout: .seconds(5))
        }
        var leftovers = family.filter(\.isAlive)
        guard !leftovers.isEmpty else { return }
        for p in leftovers { p.signal(SIGTERM) }
        // ponytail: 100 ms checks for at most 2 s, only for orphans at stop time.
        for _ in 0..<20 where !leftovers.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            leftovers = leftovers.filter(\.isAlive)
        }
        for p in leftovers { p.signal(SIGKILL) }
    }

    /// posix_spawn in a new session, with only fds 0 to 3 inherited. fd 3 is a pipe holding the
    /// bootstrap envelope.
    static func spawn(executable: String, arguments: [String], environment: [String: String],
                      fd3Payload: Data?, stderrPath: String?, stdoutPipe: Int32? = nil) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let stdoutPipe {
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe, 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, 2, stderrPath ?? "/dev/null", O_WRONLY | O_CREAT | O_APPEND, 0o600)

        var pipeFds: [Int32] = [-1, -1]
        if fd3Payload != nil {
            guard pipe(&pipeFds) == 0 else { throw LocalServerLaunchError.spawnFailed(errno) }
            posix_spawn_file_actions_adddup2(&actions, pipeFds[0], 3)
        }
        defer { for fd in pipeFds where fd >= 0 { close(fd) } }

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else { throw LocalServerLaunchError.spawnFailed(rc) }

        if let payload = fd3Payload {
            close(pipeFds[0]); pipeFds[0] = -1
            // The envelope is a few hundred bytes, far under the pipe buffer, so this never blocks.
            _ = payload.withUnsafeBytes { write(pipeFds[1], $0.baseAddress, $0.count) }
            close(pipeFds[1]); pipeFds[1] = -1
        }
        return pid
    }

    /// Runs a short CLI command to completion and returns its stdout.
    private static func run(executable: String, arguments: [String], environment: [String: String]) async throws -> Data {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw LocalServerLaunchError.spawnFailed(errno) }
        let pid: pid_t
        do {
            pid = try spawn(executable: executable, arguments: arguments, environment: environment,
                            fd3Payload: nil, stderrPath: nil, stdoutPipe: fds[1])
        } catch {
            close(fds[0]); close(fds[1])
            throw error
        }
        close(fds[1])
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let output = await Task.detached { reader.readDataToEndOfFile() }.value
        let watcher = ChildExitWatcher(pid: pid)
        _ = await watcher.waitForExit(timeout: .seconds(30))
        if watcher.exitStatus == nil { kill(pid, SIGKILL) }
        return output
    }
}
