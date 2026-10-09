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

    /// `activeVersion` from `<home>/runtime/service-state.json` (cloud/serviceProtocol.ts:28-32).
    public static func parseActiveVersion(_ data: Data) -> String? {
        struct ServiceState: Decodable { var activeVersion: String? }
        guard let version = (try? JSONDecoder().decode(ServiceState.self, from: data))?.activeVersion,
              !version.isEmpty, !version.contains("/"), version != "..", version != "."
        else { return nil }
        return version
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
