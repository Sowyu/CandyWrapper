// Launches an app binary in its own session with an isolated T3 home and
// reports the time until its first on-screen window appears.
// Must run inside the GUI session: sudo launchctl asuser <uid> sudo -u <user> ./measure-launch ...
//
// Usage: measure-launch <app-binary> <t3-home> [timeout-seconds]
// Prints: pid=<n> t0=<epoch ms> window_ms=<ms since spawn>
import CoreGraphics
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: measure-launch <app-binary> <t3-home> [timeout-seconds]"); exit(2) }
let binary = args[1], home = args[2]
let timeout = args.count >= 4 ? Double(args[3]) ?? 60 : 60

let user = ProcessInfo.processInfo.environment["USER"] ?? "mrm"
let homeDir = NSHomeDirectory()
let env = [
    "HOME=\(homeDir)", "USER=\(user)", "LOGNAME=\(user)", "SHELL=/bin/zsh", "LANG=en_US.UTF-8",
    "TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")",
    "PATH=\(homeDir)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    // Isolation: the official app must never open the live ~/.t3.
    "T3CODE_HOME=\(home)", "T3CODE_TELEMETRY_ENABLED=false",
]

var attr = posix_spawnattr_t(bitPattern: 0)
posix_spawnattr_init(&attr)
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
var pid: pid_t = 0
let argv: [UnsafeMutablePointer<CChar>?] = [strdup(binary), nil]
let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
// Detach the app's stdio so callers waiting on our output pipe don't wait on the app.
var actions = posix_spawn_file_actions_t(bitPattern: 0)
posix_spawn_file_actions_init(&actions)
posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
posix_spawn_file_actions_addopen(&actions, 1, "\(home)/app-stdout.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
posix_spawn_file_actions_addopen(&actions, 2, "\(home)/app-stdout.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
let t0 = Date()
let rc = posix_spawn(&pid, binary, &actions, &attr, argv, envp)
guard rc == 0 else { print("spawn failed: \(rc)"); exit(1) }

func hasWindow(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    return list.contains { w in
        (w[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (w[kCGWindowLayer as String] as? Int) == 0
            && ((w[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 200
    }
}

let deadline = Date().addingTimeInterval(timeout)
var windowMs: Int?
while Date() < deadline {
    if hasWindow(pid) { windowMs = Int(Date().timeIntervalSince(t0) * 1000); break }
    usleep(10_000)
}
let line = "pid=\(pid) t0=\(Int(t0.timeIntervalSince1970 * 1000)) window_ms=\(windowMs.map(String.init) ?? "timeout")\n"
FileManager.default.createFile(atPath: "\(home)/launch-result.txt", contents: Data(line.utf8))
print(line, terminator: "")
fflush(stdout)
