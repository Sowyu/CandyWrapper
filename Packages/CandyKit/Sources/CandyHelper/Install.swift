import Foundation
import T3Protocol
import T3Transport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What `install` and `uninstall` print last, for the CandyWrapper client reading the terminal.
enum Sentinel {
    static let ready = "CWH-READY"
    static func ok(_ detail: String) { print("CWH-RESULT ok \(detail)"); fflush(stdout) }
    static func failed(_ why: String) -> Never { print("CWH-RESULT failed \(why)"); fflush(stdout); exit(1) }
}

/// Where versions live: `<data>/versions/<version>/candywrapper-helper`, with `<data>/current` pointing at one.
/// On macOS that's the helper's own folder; on Linux `~/.local/share/candywrapper-helper`.
enum HelperFiles {
    static let data: URL = {
        #if os(Linux)
        if !HelperStore.isCustomHome {
            let share = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share", directoryHint: .isDirectory)
            return share.appending(path: "candywrapper-helper", directoryHint: .isDirectory)
        }
        #endif
        return HelperStore.home
    }()
    static var versions: URL { data.appending(path: "versions", directoryHint: .isDirectory) }
    static var current: URL { data.appending(path: "current") }
    static var currentBinary: URL { current.appending(path: "candywrapper-helper") }

    /// This binary's folder, through any symlink.
    static var ownFolder: URL { URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent() }

    /// Points `current` at `folder` in one rename, and returns where it pointed before.
    @discardableResult
    static func link(_ folder: URL) throws -> URL? {
        let before = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        let temp = data.appending(path: ".current-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: folder.path)
        guard rename(temp.path, current.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw HelperError("couldn't switch to \(folder.lastPathComponent) (errno \(errno))")
        }
        return before.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Keeps the current version and the one before it.
    static func prune(keep: [URL]) {
        let keepPaths = Set(keep.map { $0.resolvingSymlinksInPath().path })
        for folder in (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        where !keepPaths.contains(folder.resolvingSymlinksInPath().path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// What the running helper reports about itself, for `install` and `status`.
struct HelperStatus: Codable, Equatable {
    var version: String
    var pid: Int32
    var startedAt: Date
    /// Machine id to `connected`, `offline` or `rejected`.
    var machines: [String: String]
}

/// The service that keeps the helper running, under the user's account (docs/orchestrator-helper.md, section 4): a
/// launchd agent on macOS, a systemd user unit on Linux, as T3 keeps its own server (bootService.ts:114-128, 176-178).
enum HelperService {
    /// A test home gets its own label, so it never touches a real install.
    static var name: String { HelperStore.isCustomHome ? "com.sowyu.candywrapper.helper.test" : "com.sowyu.candywrapper.helper" }

    #if os(Linux)
    static var unitName: String { HelperStore.isCustomHome ? "candywrapper-helper-test.service" : "candywrapper-helper.service" }
    static var file: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "systemd/user/\(unitName)")
    }

    static func write() throws {
        var environment = ""
        if HelperStore.isCustomHome { environment = "Environment=CANDY_HELPER_HOME=\(HelperStore.home.path)\n" }
        let unit = """
        [Unit]
        Description=CandyWrapper Helper, the Orchestrator's relay
        After=network-online.target

        [Service]
        ExecStart=\(HelperFiles.currentBinary.path) run
        \(environment)Restart=on-failure
        RestartSec=5

        [Install]
        WantedBy=default.target

        """
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try unit.write(to: file, atomically: true, encoding: .utf8)
    }

    static func restart() throws {
        try shell("systemctl", "--user", "daemon-reload")
        try shell("systemctl", "--user", "enable", unitName)
        try shell("systemctl", "--user", "restart", unitName)
    }

    static func stop() { _ = try? shell("systemctl", "--user", "stop", unitName) }

    static func remove() {
        _ = try? shell("systemctl", "--user", "disable", "--now", unitName)
        try? FileManager.default.removeItem(at: file)
        _ = try? shell("systemctl", "--user", "daemon-reload")
    }

    /// T3's own advice when lingering is off (bootService.ts:453).
    static var lingerWarning: String? {
        let user = ProcessInfo.processInfo.environment["USER"] ?? ""
        guard let out = try? shell("loginctl", "show-user", user, "-p", "Linger", "--value"), out.trimmingCharacters(in: .whitespacesAndNewlines) != "yes" else { return nil }
        return "Lingering is off, so the helper stops when you log out and won't start at boot. Run `sudo loginctl enable-linger \"$(id -un)\"` on this machine."
    }
    #else
    static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(name).plist") }
    static var logFile: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/CandyWrapper Helper/\(HelperStore.isCustomHome ? "test" : "helper").log") }
    static var domain: String { "gui/\(getuid())" }

    static func write() throws {
        var plist: [String: Any] = [
            "Label": name,
            "ProgramArguments": [HelperFiles.currentBinary.path, "run"],
            "RunAtLoad": true,
            // A clean exit (every machine refused its token) stays down; a crash comes back.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
        ]
        if HelperStore.isCustomHome { plist["EnvironmentVariables"] = ["CANDY_HELPER_HOME": HelperStore.home.path] }
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file, options: .atomic)
    }

    static func restart() throws {
        _ = try? shell("launchctl", "bootout", "\(domain)/\(name)")
        try shell("launchctl", "bootstrap", domain, file.path)
    }

    static func stop() { _ = try? shell("launchctl", "bootout", "\(domain)/\(name)") }

    static func remove() {
        stop()
        try? FileManager.default.removeItem(at: file)
    }

    static var lingerWarning: String? { nil }
    #endif

    /// Runs a tool from the PATH and returns its output; throws with its output when it fails.
    @discardableResult
    static func shell(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw HelperError("\(args.joined(separator: " ")) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return out
    }
}

/// The home server's loopback address: every port this machine listens on, asked for its public descriptor until one
/// answers as the home machine. Nothing but the descriptor goes to any port.
enum Loopback {
    static func find(homeId: String) async -> URL? {
        let ports = listening().prefix(200)
        return await withTaskGroup(of: URL?.self) { group in
            for port in ports {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)")!
                    var http = EnvironmentHTTP(baseURL: url)
                    http.timeout = 1
                    return (try? await http.descriptor())?.environmentId == homeId ? url : nil
                }
            }
            for await url in group where url != nil {
                group.cancelAll()
                return url
            }
            return nil
        }
    }

    static func listening() -> [Int] {
        #if os(Linux)
        // /proc/net/tcp{,6}: the local address is hex `ip:port`, and state 0A is LISTEN. No tool needed.
        var ports = Set<Int>()
        for file in ["/proc/net/tcp", "/proc/net/tcp6"] {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count > 3, f[3] == "0A", let hex = f[1].split(separator: ":").last, let port = Int(hex, radix: 16) else { continue }
                ports.insert(port)
            }
        }
        return ports.sorted()
        #else
        guard let out = try? HelperService.shell("lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(getuid())", "-Fn") else { return [] }
        // -Fn prints `n<addr>:<port>` per socket.
        return Set(out.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("n"), let port = line.split(separator: ":").last else { return nil }
            return Int(port)
        }).sorted()
        #endif
    }
}
