import Foundation
import T3Protocol
import T3Store
import T3Transport
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
  handback                    hand the "while closed" task back to the schedule, for uninstall
  status                      the machines this helper reaches, without secrets
  forget                      delete every token and the machine list
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
func readSecretLines() -> [String] {
    var saved = termios()
    let tty = isatty(0) == 1 && tcgetattr(0, &saved) == 0
    if tty {
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(0, TCSANOW, &quiet)
    }
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
    let loopback = option("--loopback").flatMap(URL.init(string:))
    var entries: [(id: String, label: String, url: URL, code: String)] = []
    for line in readSecretLines() {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, let url = URL(string: f[2]) else { fail("a pairing line didn't read: expected 4 tab-separated fields", code: 2) }
        entries.append((f[0], f[1], url, f[3]))
    }
    guard let home = entries.first(where: { $0.id == homeId }) else { fail("no line for the home machine \(homeId)", code: 2) }
    var paired: [HelperMachine] = []
    for e in entries {
        do {
            let (descriptor, token) = try await EnvironmentHTTP(baseURL: e.url).pair(code: e.code, identity: identity(home: home.label))
            guard descriptor.environmentId == e.id else { throw HelperError("the address answers as another machine (\(descriptor.label))") }
            try HelperSecrets.save(token.accessToken, for: e.id)
            paired.append(HelperMachine(id: e.id, label: e.label, url: e.url, isHome: e.id == homeId, loopbackURL: e.id == homeId ? loopback : nil))
            print("paired \(e.label)")
        } catch {
            print("failed \(e.label): \(MachineLink.describe(error))")
        }
    }
    // The list is whole each time: a machine left out is forgotten.
    for old in HelperStore.machines where !paired.contains(where: { $0.id == old.id }) && !entries.contains(where: { $0.id == old.id }) {
        HelperSecrets.remove(old.id)
    }
    do { try HelperStore.write("machines.json", paired) } catch { fail("couldn't save machines.json: \(error)") }
    exit(paired.count == entries.count ? 0 : 1)

case "handback":
    let machines = HelperStore.machines
    guard let home = machines.first(where: \.isHome), let token = HelperSecrets.load(home.id) else { exit(0) }
    let link = MachineLink(machine: home, token: token, identity: identity(home: home.label))
    let helper = Helper(machines: [home], links: [link])
    let running = Task { await helper.run() }
    // Wait for the home machine's tasks and the Orchestrator thread, then hand back.
    try? await Task.sleep(for: .seconds(8))
    await helper.handBack()
    running.cancel()
    exit(0)

case "status":
    for m in HelperStore.machines {
        print("\(m.label)\t\(m.id)\t\(m.url.absoluteString)\(m.isHome ? "\thome" : "")\t\(HelperSecrets.load(m.id) == nil ? "no token" : "token saved")")
    }

case "forget":
    HelperSecrets.removeAll()
    try? FileManager.default.removeItem(at: HelperStore.home.appending(path: "machines.json"))
    try? FileManager.default.removeItem(at: HelperStore.home.appending(path: "memory.json"))
    print("forgot every machine")

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

case "version":
    print(helperVersion)

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}

