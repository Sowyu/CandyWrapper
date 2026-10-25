import Foundation
import T3Protocol
import T3Store
import T3Transport
import AgentConfig
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// candywrapper-helper: the always-on Orchestrator relay (docs/orchestrator-helper.md).
let usage = """
usage: candywrapper-helper <command>
  run                         relay until stopped (what the service runs)
  pair --home <id> [--loopback <url>]
                              read "<machine id>\\t<label>\\t<url>\\t<pairing code>" lines on stdin and sign in to each
  install --home <id> [--loopback auto|none|<url>]
                              pair from stdin like pair, then run this version as the service; prints CWH-RESULT
  uninstall                   hand the task back, stop and remove the service, the tokens and the files
  handback                    hand the "while closed" task back to the schedule
  status                      the machines this helper reaches, without secrets
  forget                      delete every token and the machine list
  print-install --version <v> --base <url> --sums <SHA256SUMS> --home <id> [--test-home <dir>]
  print-config --version <v> --base <url> --sums <SHA256SUMS> [--set] [--test-home <dir>] [--config-home <dir>]
  print-uninstall [--test-home <dir>]
                              the line a CandyWrapper client types into a T3 terminal (HelperInstall), for manual installs
  config get [--config-home <dir>]
                              the MCP servers and skills of Claude and Codex here, without secrets; prints CWH-CONFIG
  config set [--config-home <dir>]
                              apply changes read from stdin (base64 JSON lines, then a lone dot); prints CWH-CONFIG
  find-servers                every T3 server on this machine: its loopback URL, label and machine id
  check-ws <wss-url>          a WebSocket and TLS check that needs no T3
  check-descriptor <url>      a server's public descriptor, no auth
  version
"""

let args = Array(CommandLine.arguments.dropFirst())
/// Kept alive for the process: top-level globals start in source order, so this sits above its first use.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
func fail(_ text: String, code: Int32 = 1) -> Never { log(text); exit(code) }

func identity(home: String) -> ClientIdentity {
    ClientIdentity(label: "CandyWrapper Helper \(helperVersion) on \(home)", appVersion: helperVersion, deviceType: "bot", os: helperOS)
}

/// Reads stdin with echo off when it's a terminal, so pairing codes never show in a scrollback.
/// `ready` goes out once echo is off, so whoever types the codes waits for it.
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

/// Signs in to every machine on the lines and saves the list; returns the ids that failed and why, by label.
@MainActor func pairAll(homeId: String, loopback: URL?, lines: [String]) async -> (failed: Set<String>, messages: [String]) {
    var entries: [(id: String, label: String, url: URL, code: String)] = []
    for line in lines {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, let url = URL(string: f[2]) else { return ([homeId], ["a pairing line didn't read: expected 4 tab-separated fields"]) }
        entries.append((f[0], f[1], url, f[3]))
    }
    guard let home = entries.first(where: { $0.id == homeId }) else { return ([homeId], ["no line for the home machine \(homeId)"]) }
    var paired: [HelperMachine] = []
    var failures: [String] = []
    var failed = Set<String>()
    for e in entries {
        do {
            let (descriptor, token) = try await helperHTTP(e.url).pair(code: e.code, identity: identity(home: home.label))
            guard descriptor.environmentId == e.id else { throw HelperError("the address answers as another machine (\(descriptor.label))") }
            try HelperSecrets.save(token.accessToken, for: e.id)
            paired.append(HelperMachine(id: e.id, label: e.label, url: e.url, isHome: e.id == homeId, loopbackURL: e.id == homeId ? loopback : nil))
            print("paired \(e.label)")
        } catch {
            failed.insert(e.id)
            failures.append("\(e.label): \(MachineLink.describe(error))")
        }
    }
    // The list is whole each time: a machine left out is forgotten. One that failed keeps its old entry and token.
    let kept = HelperStore.machines.filter { old in !paired.contains { $0.id == old.id } && entries.contains { $0.id == old.id } }
    for old in HelperStore.machines where !entries.contains(where: { $0.id == old.id }) { HelperSecrets.remove(old.id) }
    do { try HelperStore.write("machines.json", paired + kept) } catch { failed.insert(homeId); failures.append("couldn't save machines.json: \(error)") }
    return (failed, failures)
}

/// Connects to the home machine just long enough to hand the task back.
@MainActor func handBackInline() async {
    let machines = HelperStore.machines
    guard let home = machines.first(where: \.isHome), let token = HelperSecrets.load(home.id) else { return }
    let link = MachineLink(machine: home, token: token, identity: identity(home: home.label))
    let helper = Helper(machines: [home], links: [link])
    let running = Task { await helper.run() }
    // Long enough for the home machine's tasks and the Orchestrator thread to arrive.
    try? await Task.sleep(for: .seconds(8))
    await helper.handBack()
    running.cancel()
}

var runningHelperPid: Int32? {
    guard let status = HelperStore.read("status.json", as: HelperStatus.self), kill(status.pid, 0) == 0 else { return nil }
    return status.pid
}

switch args.first {
case "run":
    let machines = HelperStore.machines
    guard let home = machines.first(where: \.isHome) else { fail("no machines yet: CandyWrapper pairs the helper when it installs it", code: 78) }
    let links = machines.compactMap { m -> MachineLink? in
        guard let token = HelperSecrets.load(m.id) else { log("no token for \(m.label); skipping it"); return nil }
        return MachineLink(machine: m, token: token, identity: identity(home: home.label))
    }
    guard !links.isEmpty else { fail("no tokens: CandyWrapper needs to pair the helper again", code: 78) }
    log("CandyWrapper Helper \(helperVersion) starting on \(home.label), reaching \(links.count) machine\(links.count == 1 ? "" : "s")")
    let helper = Helper(machines: machines, links: links)
    helper.exitWhenRefused = true
    // A frame that doesn't decode goes to the log with its length and first bytes, redacted, before the connection closes.
    RPCConnection.onUndecodableFrame = { frame, error in
        let head = redact(String(decoding: frame.prefix(160), as: UTF8.self)).debugDescription
        let tail = redact(String(decoding: frame.suffix(48), as: UTF8.self)).debugDescription
        log("undecodable frame of \(frame.count) bytes, starts \(head), ends \(tail); \(redact(String(error.prefix(400))))")
    }
    // A clean stop hands the task back, like the Mac quitting.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                log("stopping")
                await helper.handBack()
                exit(0)
            }
        }
        source.resume()
        signalSources.append(source)
    }
    await helper.run()

case "pair":
    guard let homeId = option("--home") else { fail(usage, code: 2) }
    let result = await pairAll(homeId: homeId, loopback: option("--loopback").flatMap(URL.init(string:)), lines: readSecretLines())
    for f in result.messages { print("failed \(f)") }
    exit(result.messages.isEmpty ? 0 : 1)

case "install":
    guard let homeId = option("--home") else { fail(usage, code: 2) }
    let lines = readSecretLines(ready: Sentinel.ready)
    let result = await pairAll(homeId: homeId, loopback: nil, lines: lines)
    // Its own machine is a must; another that can't be reached from here (asleep, or only on another Mac's loopback)
    // is a warning, and the helper relays to the rest.
    guard !result.failed.contains(homeId) else { Sentinel.failed("couldn't sign in to \(result.messages.joined(separator: "; "))") }
    for f in result.messages { print("CWH-WARNING couldn't sign in to \(f)") }
    // The loopback only where the new token signs in: an old server on the same T3 home answers as this machine too.
    var machines = HelperStore.machines
    let loopback: URL?
    if let i = machines.firstIndex(where: { $0.id == homeId }), let token = HelperSecrets.load(homeId) {
        switch option("--loopback") ?? "auto" {
        case "none": loopback = nil
        case "auto": loopback = await Loopback.find(homeId: homeId, token: token, prefer: machines[i].url)
        case let given:
            let url = URL(string: given)
            var works = false
            if let url { works = (try? await helperHTTP(url, timeout: 2).session(token: token))?.authenticated == true }
            if !works { print("CWH-WARNING \(given) doesn't accept the helper's token; not using it") }
            loopback = works ? url : nil
        }
        machines[i].loopbackURL = loopback
        try? HelperStore.write("machines.json", machines)
    } else { loopback = nil }
    let folder = HelperFiles.ownFolder
    let begin = Date()
    let previous: URL?
    do {
        previous = try HelperFiles.link(folder)
        try HelperService.write()
        try HelperService.restart()
    } catch { Sentinel.failed("\(MachineLink.describe(error))") }
    // Up within 30 s with its own machine's shell read, or back to the version before. Connecting isn't enough: on aniko
    // the socket opened and every snapshot then failed to decode.
    var outcome = "it didn't start within 30 seconds"
    var stillRunning = true
    for _ in 0..<60 {
        try? await Task.sleep(for: .milliseconds(500))
        guard let status = HelperStore.read("status.json", as: HelperStatus.self), status.startedAt >= begin.addingTimeInterval(-1),
              status.version == helperVersion else { continue }
        let note = status.notes?[homeId].map { ": \($0)" } ?? ""
        if status.machines[homeId] == "ready" { outcome = ""; break }
        outcome = status.machines[homeId] == "connected" ? "it connected but didn't read its machine within 30 seconds"
            : "it didn't connect within 30 seconds\(note)"
        if kill(status.pid, 0) != 0 { outcome = "it stopped\(note)"; stillRunning = false; break }
        if status.machines[homeId] == "rejected" {
            outcome = "its own machine refused the sign-in" + (status.notes?[homeId].map { ": \($0)" } ?? "")
            break
        }
    }
    guard outcome.isEmpty else {
        if let previous, previous.resolvingSymlinksInPath() != folder.resolvingSymlinksInPath() {
            _ = try? HelperFiles.link(previous)
            try? HelperService.restart()
            Sentinel.failed("\(outcome); went back to \(previous.lastPathComponent)")
        }
        if stillRunning { HelperService.stop() }
        Sentinel.failed(outcome)
    }
    HelperFiles.prune(keep: [folder] + (previous.map { [$0] } ?? []))
    if let warning = HelperService.lingerWarning { print("CWH-WARNING \(warning)") }
    Sentinel.ok("\(helperVersion) \(loopback.map { "loopback \($0.absoluteString)" } ?? "no loopback")")

case "uninstall":
    let service = FileManager.default.fileExists(atPath: HelperService.file.path)
    let files = [HelperStore.home, HelperFiles.data].filter { FileManager.default.fileExists(atPath: $0.path) }
    guard service || !files.isEmpty else {
        // Say so instead of claiming a removal, and point at a test install this run can't see.
        if !HelperStore.isCustomHome { print("nothing installed here; a test install is removed with CANDY_HELPER_HOME=<its folder> set") }
        Sentinel.ok("not installed")
        exit(0)
    }
    // A running helper hands the task back itself when the service stops it; a stopped one can't, so do it here.
    if runningHelperPid == nil { await handBackInline() }
    HelperService.remove()
    for _ in 0..<20 where runningHelperPid != nil { try? await Task.sleep(for: .milliseconds(250)) }
    HelperSecrets.removeAll()
    var removed: [String] = []
    if service, !FileManager.default.fileExists(atPath: HelperService.file.path) { removed.append(HelperService.file.lastPathComponent) }
    for folder in Set(files.map(\.path)) {
        try? FileManager.default.removeItem(atPath: folder)
        if !FileManager.default.fileExists(atPath: folder) { removed.append(folder) }
    }
    #if !os(Linux)
    try? FileManager.default.removeItem(at: HelperService.logFile)
    // Only when empty: a real install and a test home share the folder.
    rmdir(HelperService.logFile.deletingLastPathComponent().path)
    #endif
    let left = (service && FileManager.default.fileExists(atPath: HelperService.file.path) ? [HelperService.file.path] : [])
        + files.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
    for r in removed { print("removed \(r)") }
    guard left.isEmpty else { Sentinel.failed("couldn't remove \(left.joined(separator: ", "))") }
    Sentinel.ok("uninstalled")

case "handback":
    await handBackInline()

case "status":
    if let status = HelperStore.read("status.json", as: HelperStatus.self) {
        print("version \(status.version), pid \(status.pid)\(runningHelperPid == nil ? " (not running)" : ""), started \(status.startedAt.ISO8601Format())")
    }
    for m in HelperStore.machines {
        print("\(m.label)\t\(m.id)\t\(m.url.absoluteString)\(m.isHome ? "\thome" : "")\t\(HelperSecrets.load(m.id) == nil ? "no token" : "token saved")")
    }

case "forget":
    HelperSecrets.removeAll()
    try? FileManager.default.removeItem(at: HelperStore.home.appending(path: "machines.json"))
    try? FileManager.default.removeItem(at: HelperStore.home.appending(path: "memory.json"))
    print("forgot every machine")

case "print-install", "print-config":
    guard let version = option("--version"), let base = option("--base").flatMap(URL.init(string:)), let sumsFile = option("--sums"),
          let text = try? String(contentsOfFile: sumsFile, encoding: .utf8) else { fail(usage, code: 2) }
    // SHA256SUMS lines: "<hex>  candywrapper-helper-<version>-<platform>.tar.gz".
    var sums: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count == 2 else { continue }
        let name = f[1].replacingOccurrences(of: "candywrapper-helper-\(version)-", with: "").replacingOccurrences(of: ".tar.gz", with: "")
        sums[name] = String(f[0])
    }
    let release = HelperInstall.Release(version: version, baseURL: base, sums: sums)
    if args[0] == "print-config" {
        print(HelperInstall.configCommand(release, set: args.contains("--set"), testHome: option("--test-home"), configHome: option("--config-home")), terminator: "")
    } else {
        guard let homeId = option("--home") else { fail(usage, code: 2) }
        print(HelperInstall.installCommand(release, homeId: homeId, testHome: option("--test-home")), terminator: "")
    }

case "print-uninstall":
    print(HelperInstall.uninstallCommand(testHome: option("--test-home")), terminator: "")

case "find-servers":
    // url, label, machine id, version, then notes: one that doesn't answer auth, or shares its id with a newer one.
    let servers = await Loopback.servers()
    for s in servers {
        var notes: [String] = []
        if !s.answersAuth { notes.append("doesn't answer auth") }
        if let first = servers.first(where: { $0.descriptor.environmentId == s.descriptor.environmentId }), first.url != s.url {
            notes.append("same machine id as \(hostPort(first.url)), likely an old server on the same T3 home")
        }
        print([s.url.absoluteString, s.descriptor.label, s.descriptor.environmentId, s.descriptor.serverVersion, notes.joined(separator: "; ")]
            .joined(separator: "\t"))
    }

case "check-ws":
    guard args.count == 2, let url = URL(string: args[1]) else { fail(usage, code: 2) }
    do {
        let socket = try await URLSessionRPCSocket.open(url: url)
        try await socket.send(Data("candywrapper-helper".utf8))
        for _ in 0..<3 where String(decoding: try await socket.receive(), as: UTF8.self) == "candywrapper-helper" {
            print("ok"); socket.close(); exit(0)
        }
        fail("no echo")
    } catch { fail("failed: \(error)") }

case "check-descriptor":
    guard args.count == 2, let url = URL(string: args[1]) else { fail(usage, code: 2) }
    do {
        let d = try await EnvironmentHTTP(baseURL: url).descriptor()
        print("\(d.label)\t\(d.environmentId)\tprotocol \(d.protocolVersion)")
    } catch { fail("failed: \(error)") }

case "config":
    // The Connectors tab (docs/connectors.md). `--config-home` or CANDY_CONFIG_HOME points it at a test home.
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

