import Foundation
import Darwin

/// T3's `SshEnvironmentManager` (packages/ssh/src/tunnel.ts:1330-1765) on the system `/usr/bin/ssh`.
/// It launches or reuses a T3 server on the host, forwards a local port to it, and issues a pairing
/// credential. It owns only the processes it starts, and nothing runs until `ensure` is called.
/// Every argument goes to `Process` as an array, never through a shell. A password lives in memory
/// for this run of the app and reaches ssh only through the askpass helper's environment.
@MainActor
public final class SshEnvironmentLauncher {
    /// `DesktopSshEnvironmentBootstrap` with the pairing token issued (platform.ts:191-196).
    public struct Bootstrap: Sendable {
        public let target: SshEnvironmentTarget
        public let baseURL: URL
        public let credential: String
    }
    /// Asks for a password (`SshPasswordPrompt`): the target and the attempt, 1 or 2. Throws to cancel.
    public typealias PasswordPrompt = @MainActor (SshEnvironmentTarget, Int) async throws -> String
    public var passwordPrompt: PasswordPrompt?
    /// A tunnel that was ready exited on its own (network drop, host reboot).
    public var onTunnelExit: ((SshEnvironmentTarget) -> Void)?

    private struct Tunnel { let target: SshEnvironmentTarget; let process: Process; let baseURL: URL; var ready: Bool }
    private var tunnels: [String: Tunnel] = [:]
    /// `authSecrets` (tunnel.ts:1336): the password that worked, per target, for later commands and the stop.
    private var authSecrets: [String: String] = [:]
    private var cleanups: [String: Task<Void, Never>] = [:]
    private var cleanupIds: [String: UUID] = [:]
    private var operations: [String: Task<Bootstrap, Error>] = [:]
    private let version: String
    private let ssh: URL

    /// `version` is the T3 release the host downloads (`archiveVersion`, desktop main.ts:117).
    public init(version: String, ssh: URL = URL(fileURLWithPath: "/usr/bin/ssh")) { self.version = version; self.ssh = ssh }

    /// `resolveSshTarget` (command.ts:327-367): `ssh -G` without connecting; the alias alone when that fails.
    public func resolve(alias: String) async throws -> SshEnvironmentTarget {
        let fallback = try SshEnvironmentTarget(alias: alias)
        guard let output = try? await run(SshEnvironmentCommand.resolve(fallback.alias), destination: fallback.alias, input: nil, password: nil, timeout: 60),
              let resolved = try? SshEnvironmentTarget.resolved(alias: fallback.alias, output: output) else { return fallback }
        return resolved
    }

    /// `ensureEnvironment` with `issuePairingToken` (tunnel.ts:1681-1736). One run per target at a time.
    public func ensure(_ target: SshEnvironmentTarget) async throws -> Bootstrap {
        // Revalidate decoded or edited registrations before any executable sees them.
        let target = try SshEnvironmentTarget(alias: target.alias, hostname: target.hostname, username: target.username, port: target.port)
        let resolved = target.merging(resolved: try await resolve(alias: target.alias))
        let key = resolved.stateKey
        if let task = operations[key] { return try await task.value }
        let task = Task { try await self.start(resolved) }
        operations[key] = task
        defer { if operations[key] == task { operations[key] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func start(_ target: SshEnvironmentTarget) async throws -> Bootstrap {
        let key = target.stateKey
        if let cleanup = cleanups[key] { await cleanup.value }
        let scripts = try SshEnvironmentCommand.scripts(version: version, stateKey: key)
        let baseURL = try await tunnel(target, scripts: scripts)
        // `issueRemotePairingToken` (tunnel.ts:922-977); it may install the archive on a cold host.
        struct Pair: Decodable { let credential: String }
        let output = try await withAuth(target) { password in
            try await self.run(SshEnvironmentCommand.pairing(target, interactive: password != nil), destination: target.destination,
                               input: scripts.pairing, password: password, timeout: 900)
        }
        let pair: Pair
        do { pair = try SshEnvironmentCommand.lastJSON(output, as: Pair.self) } catch { throw SshEnvironmentError("SSH pairing returned unparseable output.") }
        guard !pair.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SshEnvironmentError("SSH pairing command returned an invalid credential.") }
        return Bootstrap(target: target, baseURL: baseURL, credential: pair.credential)
    }

    /// `ensureTunnelEntry` (tunnel.ts:1603-1652): reuses a tunnel that answers within 2 s, else stops
    /// it and the server it launched, then launches or reuses a server and forwards a fresh local port.
    private func tunnel(_ target: SshEnvironmentTarget, scripts: (launch: String, pairing: String, stop: String)) async throws -> URL {
        let key = target.stateKey
        if let entry = tunnels[key], entry.process.isRunning {
            if await Self.answers(entry.baseURL, within: 2) { return entry.baseURL }
        }
        if tunnels[key] != nil { disconnect(target); if let cleanup = cleanups[key] { await cleanup.value } }
        // `launchOrReuseRemoteServer` (tunnel.ts:861-920).
        struct Launch: Decodable { let remotePort: Int; let serverKind: String? }
        let output = try await withAuth(target) { password in
            try await self.run(SshEnvironmentCommand.launch(target, interactive: password != nil), destination: target.destination,
                               input: scripts.launch, password: password, timeout: 900)
        }
        let launch: Launch
        do { launch = try SshEnvironmentCommand.lastJSON(output, as: Launch.self) } catch { throw SshEnvironmentError("SSH launch returned unparseable output.") }
        return try await withAuth(target) { password in try await self.forward(target, remotePort: launch.remotePort, password: password) }
    }

    /// `startSshTunnel` (tunnel.ts:1100-1290): `ssh -N -L` and a 20 s wait for the descriptor through it.
    private func forward(_ target: SshEnvironmentTarget, remotePort: Int, password: String?) async throws -> URL {
        let key = target.stateKey
        let localPort = try Self.reservePort()
        let arguments = try SshEnvironmentCommand.tunnel(target, localPort: localPort, remotePort: remotePort, interactive: password != nil)
        let helper = try Self.makeHelper(password: password)
        defer { Self.removeHelper(helper) }
        let process = Process()
        process.executableURL = ssh
        process.arguments = arguments
        process.environment = SshEnvironmentCommand.childEnvironment(base: ProcessInfo.processInfo.environment, helper: helper?.path, password: password)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        // Keep the last 64 KB of stderr while the tunnel runs, for the failure message.
        let diagnostic = SshEnvironmentOutput()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { diagnostic.append(bytes) }
        }
        process.terminationHandler = { [weak self] ended in
            errors.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, let entry = self.tunnels[key], entry.process === ended else { return }
                self.tunnels[key] = nil
                if entry.ready { self.onTunnelExit?(entry.target) }
            }
        }
        try process.run()
        process.environment = nil
        let baseURL = URL(string: "http://127.0.0.1:\(localPort)")!
        // From here `disconnect` also stops the server this launch may have started (the entry scope's finalizer).
        tunnels[key] = Tunnel(target: target, process: process, baseURL: baseURL, ready: false)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if Task.isCancelled { disconnect(target); throw CancellationError() }
            guard process.isRunning else {
                tunnels[key] = nil
                throw SshEnvironmentError(SshEnvironmentCommand.failureMessage(stdout: "", stderr: diagnostic.text, destination: target.destination, status: process.terminationStatus))
            }
            if await Self.answers(baseURL, within: 1) {
                tunnels[key]?.ready = true
                return baseURL
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        disconnect(target)
        throw SshEnvironmentError("Timed out waiting 20000ms for backend readiness at \(baseURL.absoluteString)/.")
    }

    /// `runWithSshAuth` (tunnel.ts:1421-1489): batch mode first; on an auth failure, ask (twice at most)
    /// and retry with the answer through askpass.
    private func withAuth<T>(_ target: SshEnvironmentTarget, _ operation: (String?) async throws -> T) async throws -> T {
        let key = target.stateKey
        var password = authSecrets[key], prompts = 0
        while true {
            do { return try await operation(password) } catch let error as SshEnvironmentError where error.isAuthenticationFailure {
                if password != nil { authSecrets[key] = nil }
                guard let passwordPrompt, prompts < 2 else { throw error }
                prompts += 1
                password = try await passwordPrompt(target, prompts)
                authSecrets[key] = password
            }
        }
    }

    /// Closes the tunnel and runs T3's stop script (tunnel.ts:736-757), which stops only a server it
    /// launched; a server that was already running stays up. Best effort, in the background.
    public func disconnect(_ target: SshEnvironmentTarget) {
        let key = target.stateKey
        guard let entry = tunnels.removeValue(forKey: key) else { return }
        Self.stop(entry.process)
        let password = authSecrets[key], version = self.version
        let id = UUID()
        cleanupIds[key] = id
        cleanups[key] = Task {
            defer { if cleanupIds[key] == id { cleanups[key] = nil; cleanupIds[key] = nil } }
            guard let scripts = try? SshEnvironmentCommand.scripts(version: version, stateKey: key) else { return }
            _ = try? await run(SshEnvironmentCommand.pairing(entry.target, interactive: password != nil), destination: entry.target.destination,
                               input: scripts.stop, password: password, timeout: 60)
        }
    }

    // ponytail: app quit starts the remote stop jobs but doesn't wait for them; await `cleanups` from a quit
    // owner that keeps the run loop going if servers outlive quits.
    public func shutdown() {
        operations.values.forEach { $0.cancel() }; operations.removeAll()
        for entry in Array(tunnels.values) { disconnect(entry.target) }
        authSecrets.removeAll()
    }

    // MARK: Processes

    private static func answers(_ baseURL: URL, within seconds: Double) async -> Bool {
        var http = EnvironmentHTTP(baseURL: baseURL); http.timeout = seconds
        return (try? await http.descriptor()) != nil
    }

    /// SIGTERM, then SIGKILL after 2 s (`TUNNEL_SHUTDOWN_TIMEOUT_MS`).
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) }
        }
    }

    /// Writes the askpass script to a fresh 0700 directory in the user's temp folder (`ensureSshAskpassHelpers`,
    /// auth.ts:144-164). Only when a password is in play.
    private static func makeHelper(password: String?) throws -> URL? {
        guard password != nil else { return nil }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("t3code-ssh-runtime-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("ssh-askpass.sh")
        guard fm.createFile(atPath: file.path, contents: Data(SshEnvironmentCommand.askpassScript.utf8), attributes: [.posixPermissions: 0o700]) else {
            try? fm.removeItem(at: directory)
            throw SshEnvironmentError("Failed to prepare SSH authentication helpers.")
        }
        return file
    }
    private static func removeHelper(_ helper: URL?) {
        if let helper { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
    }

    /// `runSshCommand` (command.ts:162-325): stdin in, stdout back; a non-zero exit throws stderr.
    private func run(_ arguments: [String], destination: String, input: String?, password: String?, timeout: Double) async throws -> String {
        try Task.checkCancellation()
        let helper = try Self.makeHelper(password: password)
        defer { Self.removeHelper(helper) }
        let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = ssh; process.arguments = arguments
        process.environment = SshEnvironmentCommand.childEnvironment(base: ProcessInfo.processInfo.environment, helper: helper?.path, password: password)
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout; process.standardError = stderr
        let outReader = Task.detached(priority: .utility) { () -> String in
            let sink = SshEnvironmentOutput()
            while let bytes = try? stdout.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty { sink.append(bytes) }
            return sink.text
        }
        let errReader = Task.detached(priority: .utility) { () -> String in
            let sink = SshEnvironmentOutput()
            while let bytes = try? stderr.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty { sink.append(bytes) }
            return sink.text
        }
        let timedOut = SshEnvironmentFlag()
        let expiry = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(timeout)); timedOut.set(); Self.stop(process) } catch {}
        }
        defer { expiry.cancel() }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
                do { try process.run() } catch {
                    try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                    continuation.resume(throwing: SshEnvironmentError("Failed to spawn SSH command for \(destination)."))
                    return
                }
                process.environment = nil
                if let input {
                    // A script can exceed the pipe buffer; write it off the main actor.
                    DispatchQueue.global(qos: .utility).async {
                        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                        try? stdin.fileHandleForWriting.close()
                    }
                }
            }
        } onCancel: { Task { @MainActor in Self.stop(process) } }
        let out = await outReader.value, err = await errReader.value
        try Task.checkCancellation()
        if timedOut.value { throw SshEnvironmentError("SSH command timed out after \(Int(timeout * 1000))ms.") }
        guard status == 0 else {
            var message = SshEnvironmentCommand.failureMessage(stdout: out, stderr: err, destination: destination, status: status)
            if let password, !password.isEmpty { message = message.replacingOccurrences(of: password, with: "[redacted]") }
            throw SshEnvironmentError(message)
        }
        return out
    }

    /// `reserveLocalTunnelPort`: a free loopback port from the kernel.
    private static func reservePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SshEnvironmentError("Could not reserve a local SSH port.") }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw SshEnvironmentError("Could not reserve a local SSH port.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard got == 0 else { throw SshEnvironmentError("Could not read the local SSH port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// The last 64 KB of a process stream.
private final class SshEnvironmentOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes); if data.count > 65536 { data.removeFirst(data.count - 65536) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class SshEnvironmentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}
