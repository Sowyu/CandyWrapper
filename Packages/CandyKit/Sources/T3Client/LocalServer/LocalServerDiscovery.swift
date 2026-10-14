import Darwin
import Foundation
import T3Protocol

/// `<home>/userdata/server-runtime.json`, written by a listening server and removed on shutdown
/// (protocol.md 11.1, apps/server/src/serverRuntimeState.ts:11-30).
public struct ServerRuntimeState: Codable, Sendable, Equatable {
    public var version: Int
    public var pid: Int32
    public var host: String?
    public var port: Int
    public var origin: String
    public var devUrl: String?
    public var startedAt: String
    public var serviceManaged: Bool?
}

/// A server found running for a T3 home. We never stop or reprioritize one of these.
public struct RunningLocalServer: Sendable, Equatable {
    public var runtime: ServerRuntimeState
    public var origin: URL
    public var descriptor: EnvironmentDescriptor
}

/// Read-only discovery of the user's T3 home: the running server and the installed runtime.
/// Nothing here writes to the home.
public enum LocalServerDiscovery {
    /// `~/.t3`. We don't honor an inherited `T3CODE_HOME`: under the live service it leaks into
    /// every shell, and the app's own home choice should be explicit.
    public static var defaultHome: URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".t3", directoryHint: .isDirectory)
    }

    public static func runtimeStateURL(home: URL) -> URL {
        home.appending(path: "userdata/server-runtime.json")
    }

    public static func parseRuntimeState(_ data: Data) throws -> ServerRuntimeState {
        try JSONDecoder().decode(ServerRuntimeState.self, from: data)
    }

    /// `kill(pid, 0)`: EPERM still means alive (another user's process), as in T3's isProcessAlive.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The official `t3 pair` check (cli/pair.ts:255-290): the file, a live pid, then the
    /// descriptor answering within 2.5 s. Nil when any step fails.
    public static func findRunning(home: URL, timeout: TimeInterval = 2.5) async -> RunningLocalServer? {
        guard let data = try? Data(contentsOf: runtimeStateURL(home: home)),
              let runtime = try? parseRuntimeState(data),
              isProcessAlive(runtime.pid),
              let origin = URL(string: runtime.origin)
        else { return nil }
        var http = EnvironmentHTTP(baseURL: origin)
        http.timeout = timeout
        guard let descriptor = try? await http.descriptor() else { return nil }
        return RunningLocalServer(runtime: runtime, origin: origin, descriptor: descriptor)
    }

    /// Like `findRunning`, but never clears the way for a second server on a home that has one.
    /// Nil only when nobody else runs a server for `home`. A server process that is alive but
    /// doesn't answer, or a home that T3's background service owns, is waited for up to `wait`
    /// (the service restarts its server by itself), then reported as an error.
    public static func discover(home: URL, servicePlist: URL = servicePlistURL,
                                wait: Duration = .seconds(20)) async throws -> RunningLocalServer? {
        let deadline = ContinuousClock.now + wait
        while true {
            if let running = await findRunning(home: home) { return running }
            // A 3105+ server holds the owner lock from before it opens the database, so a server still
            // migrating counts as running before it writes `server-runtime.json`.
            let alive = runtimeProcessAlive(home: home) || ownerLockHolder(home: home) != nil
            let serviceOwned = serviceHome(plist: servicePlist)?.standardizedFileURL.path == home.standardizedFileURL.path
            guard alive || serviceOwned else { return nil }
            guard ContinuousClock.now < deadline else {
                throw alive ? LocalServerDiscoveryError.unresponsive : LocalServerDiscoveryError.serviceNotRunning
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// The runtime file names a live process. A pid that an unrelated, newer process took over
    /// after a crash (the file outlives a killed server) doesn't count.
    public static func runtimeProcessAlive(home: URL) -> Bool {
        guard let data = try? Data(contentsOf: runtimeStateURL(home: home)),
              let runtime = try? parseRuntimeState(data), isProcessAlive(runtime.pid)
        else { return false }
        if let started = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(runtime.startedAt),
           let process = ProcessIdentity.of(runtime.pid),
           Double(process.startTime) / 1_000_000 > started.timeIntervalSince1970 + 5 {
            return false
        }
        return true
    }

    /// The process holding T3's one-owner lock on `home`, or nil (serverOwnership.ts, 570542662). A server
    /// keeps an exclusive SQLite transaction open on `<home>/userdata/server-owner.sqlite` for its whole
    /// life, so the file carries a POSIX write lock in SQLite's lock range. `F_GETLK` reports it without
    /// taking any lock, so asking can never make that server, or one starting, fail with exit 78.
    public static func ownerLockHolder(home: URL) -> pid_t? {
        let fd = open(home.appending(path: "userdata/server-owner.sqlite").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // SQLite's unix VFS locks bytes from PENDING_BYTE (0x40000000): the pending, reserved and shared bytes.
        var lock = flock(l_start: 0x4000_0000, l_len: 512, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }

    /// T3's launch agent (apps/server/src/cloud/bootService.ts:43, 302-316).
    public static var servicePlistURL: URL {
        URL(filePath: NSHomeDirectory()).appending(path: "Library/LaunchAgents/com.t3tools.t3code.service.plist")
    }

    /// The home T3's background service runs, from its plist's `T3CODE_HOME`, the way
    /// `bootServiceBaseDirOf` reads it back (bootService.ts:62-80). Nil when not installed.
    public static func serviceHome(plist: URL = servicePlistURL) -> URL? {
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = root["EnvironmentVariables"] as? [String: Any],
              let home = env["T3CODE_HOME"] as? String, !home.isEmpty
        else { return nil }
        return URL(filePath: home, directoryHint: .isDirectory)
    }

    /// `activeVersion` from `<home>/runtime/service-state.json` (cloud/serviceProtocol.ts:28-32).
    public static func parseActiveVersion(_ data: Data) -> String? {
        struct ServiceState: Decodable { var activeVersion: String? }
        guard let version = (try? JSONDecoder().decode(ServiceState.self, from: data))?.activeVersion,
              !version.isEmpty, !version.contains("/"), version != "..", version != "."
        else { return nil }
        return version
    }

    /// T3's installed runtime for the home: its service's active version and that version's `t3`.
    public static func installedRuntime(home: URL) -> (T3Version, URL)? {
        guard let data = try? Data(contentsOf: home.appending(path: "runtime/service-state.json")),
              let raw = parseActiveVersion(data), let version = T3Version(raw) else { return nil }
        let binary = home.appending(path: "runtime/versions/\(raw)/t3")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? (version, binary) : nil
    }

    /// The installed runtime's `t3`, else `t3` on `path`. Nil when neither is executable.
    public static func resolveBinary(home: URL, path: String) -> URL? {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: home.appending(path: "runtime/service-state.json")),
           let version = parseActiveVersion(data) {
            let binary = home.appending(path: "runtime/versions/\(version)/t3")
            if fm.isExecutableFile(atPath: binary.path) { return binary }
        }
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(filePath: String(dir)).appending(path: "t3")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

public enum LocalServerDiscoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A server for this home is running but didn't answer. Starting another would put two
    /// servers on one database.
    case unresponsive
    /// T3's background service owns this home and its server isn't up.
    case serviceNotRunning

    public var description: String {
        switch self {
        case .unresponsive: "T3 Code's server on this Mac is running but not responding. Try again in a moment."
        case .serviceNotRunning: "T3 Code's background service runs the server on this Mac, and it isn't running right now. Start T3 Code's service, then try again."
        }
    }
}
