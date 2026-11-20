import Foundation
import AgentConfig
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// candywrapper-helper: reads and changes the MCP servers and skills of Claude and Codex on a machine, for the
// Connectors tab (docs/connectors.md). A CandyWrapper client runs it through a hidden T3 terminal.
let usage = """
usage: candywrapper-helper <command>
  config get [--config-home <dir>]
                              the MCP servers and skills of Claude and Codex here, without secrets; prints CWH-CONFIG
  config set [--config-home <dir>]
                              apply changes read from stdin (base64 JSON lines, then a lone dot); prints CWH-CONFIG
  version
"""

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
func fail(_ text: String, code: Int32 = 1) -> Never { FileHandle.standardError.write(Data("\(text)\n".utf8)); exit(code) }

/// The `VERSION` file the release puts next to the binary; "dev" in a plain build.
let helperVersion: String = {
    let file = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "VERSION")
    let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? "dev" : text
}()

/// What `config` prints last, for the CandyWrapper client reading the terminal (`HelperInstall.scan`).
enum Sentinel {
    static let ready = "CWH-READY"
    static func ok(_ detail: String) { print("CWH-RESULT ok \(detail)"); fflush(stdout) }
    static func failed(_ why: String) -> Never { print("CWH-RESULT failed \(why)"); fflush(stdout); exit(1) }
}

/// Reads stdin with echo off when it's a terminal, so secrets never show in a scrollback.
/// `ready` goes out once echo is off, so whoever types the lines waits for it.
func readSecretLines(ready: String? = nil) -> [String] {
    var saved = termios()
    let tty = isatty(0) == 1 && tcgetattr(0, &saved) == 0
    if tty {
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(0, TCSANOW, &quiet)
    }
    if let ready { print(ready); fflush(stdout) }
    defer { if tty { tcsetattr(0, TCSANOW, &saved) } }
    var lines: [String] = []
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." { break }
        lines.append(trimmed)
    }
    return lines
}

switch args.first {
case "config":
    // `--config-home` or CANDY_CONFIG_HOME points it at a test home.
    let home = option("--config-home") ?? ProcessInfo.processInfo.environment["CANDY_CONFIG_HOME"] ?? ProcessInfo.processInfo.environment["HOME"]
    guard let home, args.count >= 2 else { fail(usage, code: 2) }
    let store = AgentConfigStore(home: URL(fileURLWithPath: home, isDirectory: true))
    switch args[1] {
    case "get":
        print(ConfigWire.marker + ConfigWire.encode(store.snapshot()))
        Sentinel.ok("config")
    case "set":
        // Echo off: a new server's token travels in these lines.
        let lines = readSecretLines(ready: Sentinel.ready)
        guard let changes = ConfigWire.decodeChanges(lines.joined()) else { Sentinel.failed("the changes didn't read") }
        do {
            try store.apply(changes)
            print(ConfigWire.marker + ConfigWire.encode(store.snapshot()))
            Sentinel.ok("config")
        } catch {
            print(ConfigWire.marker + ConfigWire.encode(store.snapshot()))
            Sentinel.failed("\(error)")
        }
    default:
        fail(usage, code: 2)
    }

case "version":
    print(helperVersion)

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}
