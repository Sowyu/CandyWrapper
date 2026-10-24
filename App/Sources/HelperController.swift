import DesignSystem
import Foundation
import Features
import T3Client
import T3Protocol
import T3Store

/// The CandyWrapper Helper from the app's side (docs/orchestrator-helper.md): whether it's connected on the
/// Orchestrator's machine, which makes the Mac stand by, and the one button that installs, updates, renews or removes
/// it through a hidden T3 terminal there.
@MainActor
final class HelperController {
    private let environments: Environments
    /// The Orchestrator's machine, its thread and the folder a terminal there opens in.
    var home: () -> String? = { nil }
    var orchestratorThread: () -> ThreadId? = { nil }
    var workspace: () -> String? = { nil }
    var machines: () -> [OrchestratorMachineRef] = { [] }
    var toast: (String, String?, ToastQueue.Kind) -> Void = { _, _, _ in }
    /// The helper came or went, or a run started or ended.
    var onChange: () -> Void = {}

    private var watched: (env: String, session: ObjectIdentifier)?
    private var accessTask: Task<Void, Never>?
    private var access = AuthAccessSnapshot()
    private var accessLoaded = false
    private(set) var busy: String?
    private var autoTried = false

    init(environments: Environments) { self.environments = environments }

    /// The build this app installs: `helper-manifest.json` in the app, which scripts/release writes, or
    /// `CANDY_HELPER_MANIFEST` for a test build.
    static let release: HelperInstall.Release? = {
        let url = ProcessInfo.processInfo.environment["CANDY_HELPER_MANIFEST"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "helper-manifest", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HelperInstall.Release.self, from: data)
    }()
    /// `CANDY_HELPER_HOME` on the Orchestrator's machine, for a test install that never touches a real one.
    private static let testHome = ProcessInfo.processInfo.environment["CANDY_HELPER_TEST_HOME"]

    var sessions: [AuthClientSession] { OrchestratorHandoff.helperSessions(access.clientSessions) }
    /// Connected on the Orchestrator's machine, so it relays and this Mac stands by.
    var connected: Bool { sessions.contains(where: \.connected) }
    var installed: Bool { !sessions.isEmpty }
    private var newest: AuthClientSession? { sessions.max { ($0.issuedAt.epochMs ?? 0) < ($1.issuedAt.epochMs ?? 0) } }
    var version: String? { newest.flatMap { HelperInstall.version(fromSessionLabel: $0.client.label ?? "") } }

    // MARK: Watching

    /// Follows the Orchestrator machine's clients (`subscribeAuthAccess`), pushed, nothing while idle. Call when the
    /// machine, its session or the Orchestrator's state changed; `active` false stops it.
    func watch(active: Bool) {
        let env = active ? home() : nil
        let session = env.flatMap { environments.session($0) }
        let key = session.map(ObjectIdentifier.init)
        guard watched?.env != env || watched?.session != key else { return }
        accessTask?.cancel()
        accessTask = nil
        access = AuthAccessSnapshot()
        accessLoaded = false
        watched = nil
        defer { onChange() }
        guard let env, let session, let key else { return }
        watched = (env, key)
        // Without access:read (a server before 3473 through T3 Connect) the helper stays invisible and the Mac relays too;
        // the "Result:" check keeps calls from running twice.
        guard environments.authSession(env)?.permissions?.contains("access:read") ?? true else { return }
        accessTask = session.supervisor.subscribe("subscribeAuthAccess", payload: { .object([:]) }) { [weak self] event in
            guard case .value(let json) = event else { return }
            await MainActor.run {
                guard let self, self.watched?.env == env else { return }
                try? self.access.apply(json)
                self.accessLoaded = true
                self.onChange()
                self.renewIfDue()
            }
        }
    }

    /// Once per launch: an older version than this app carries, or a sign-in with under a week left, runs the install
    /// again, which only re-pairs when the version is the same.
    private func renewIfDue() {
        guard !autoTried, busy == nil, accessLoaded, installed, let release = Self.release, let newest else { return }
        let older = version.map { $0.compare(release.version, options: .numeric) == .orderedAscending } ?? false
        let expiring = newest.expiresAt?.date.map { $0 < Date().addingTimeInterval(7 * 86_400) } ?? false
        guard older || expiring else { return }
        autoTried = true
        Task { await install(reason: older ? "Updating the helper" : "Renewing the helper") }
    }

    var status: String {
        if let busy { return busy + "…" }
        guard let env = home() else { return "Start the Orchestrator first." }
        let label = environments.label(env) ?? "its machine"
        guard Self.release != nil else { return "This build of CandyWrapper doesn't include the helper." }
        guard accessLoaded else { return "Relays for the Orchestrator on \(label) while CandyWrapper is closed." }
        guard installed else { return "Not installed. It relays for the Orchestrator on \(label) while CandyWrapper is closed." }
        let v = version.map { ", version \($0)" } ?? ""
        return connected ? "Running on \(label)\(v). This Mac leaves relaying to it." : "Installed on \(label)\(v), not connected right now."
    }

    var primaryTitle: String {
        guard installed else { return "Install" }
        if let release = Self.release, let version, version.compare(release.version, options: .numeric) == .orderedAscending { return "Update" }
        return "Reinstall"
    }

    var canRun: Bool {
        busy == nil && Self.release != nil && home().map { environments.session($0) != nil } == true && orchestratorThread() != nil && workspace() != nil
    }

    // MARK: Install and remove

    func install(reason: String = "Installing the helper") async {
        guard busy == nil, let release = Self.release, let env = home(), let thread = orchestratorThread(), let cwd = workspace(),
              let homeSession = environments.session(env) else { return }
        busy = reason
        onChange()
        defer { busy = nil; onChange() }
        let homeLabel = environments.label(env) ?? env
        // A one-time code per machine the Orchestrator's machine can reach. A machine this Mac reaches on loopback is
        // its own local server, which no other machine can.
        var pairings: [HelperInstall.Pairing] = []
        var skipped: [String] = []
        for m in machines() where m.connected {
            guard let shell = environments.session(m.id), let url = environments.routeInUse(m.id) else { continue }
            if m.id != env, ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "") { skipped.append(m.label); continue }
            do {
                let created = try await shell.http.createPairingCredential(
                    PairingCredentialRequest(label: HelperInstall.sessionLabel(version: release.version, home: homeLabel), scopes: HelperInstall.scopes),
                    token: shell.token)
                pairings.append(.init(machineId: m.id, label: m.label, url: url, code: created.credential))
            } catch {
                if m.id == env { return fail("Couldn't create a sign-in for the helper on \(homeLabel)", error) }
                skipped.append(m.label)
            }
        }
        let lines = await runInTerminal(homeSession, env: env, thread: thread, cwd: cwd,
                                        command: HelperInstall.installCommand(release, homeId: env, testHome: Self.testHome),
                                        input: HelperInstall.pairingInput(pairings))
        switch lines.last {
        case .ok?:
            await revokeOld(keepNewest: true)
            let warnings = lines.compactMap { if case .warning(let w) = $0 { w } else { nil } }
            let note = (skipped.isEmpty ? [] : ["It can't reach \(skipped.joined(separator: ", ")) from \(homeLabel)."]) + warnings
            toast("The helper is running on \(homeLabel)", note.isEmpty ? nil : note.joined(separator: " "), note.isEmpty ? .success : .warning)
        case .failed(let why)?:
            toast("Couldn't install the helper", why, .error)
        default:
            toast("Couldn't install the helper", "\(homeLabel) didn't answer in time.", .error)
        }
    }

    func uninstall() async {
        guard busy == nil, let env = home(), let thread = orchestratorThread(), let cwd = workspace(), let homeSession = environments.session(env) else { return }
        busy = "Removing the helper"
        onChange()
        defer { busy = nil; onChange() }
        let lines = await runInTerminal(homeSession, env: env, thread: thread, cwd: cwd, command: HelperInstall.uninstallCommand(testHome: Self.testHome), input: nil)
        // Its sign-ins go either way: a machine that kept its files can't do anything with them.
        await revokeOld(keepNewest: false)
        if case .failed(let why)? = lines.last { toast("Couldn't remove the helper's files", why + " Its sign-ins are revoked.", .warning) }
        else if lines.last == nil { toast("Revoked the helper", "\(environments.label(env) ?? env) didn't answer, so its files stay until you remove it again.", .warning) }
        else { toast("Removed the helper", nil, .success) }
    }

    private func fail(_ title: String, _ error: Error) {
        toast(title, (error as? RPCClientError)?.typedError?.message ?? "\(error)", .error)
    }

    /// Opens a terminal no one sees, types `command` in slices a PTY's small input queue keeps up with, answers
    /// `CWH-READY` with `input`, and returns the marker lines once a result arrives. The terminal and its history go.
    private func runInTerminal(_ session: ShellSession, env: String, thread: ThreadId, cwd: String, command: String, input: String?) async -> [HelperInstall.Line] {
        let terminal = "candywrapper-helper-\(UUID().uuidString.prefix(8).lowercased())"
        let local = thread.localId.rawValue
        let base: [String: JSONValue] = ["threadId": .string(local), "terminalId": .string(terminal)]
        func with(_ extra: [String: JSONValue]) -> JSONValue { .object(base.merging(extra) { a, _ in a }) }
        let output = OutputBox()
        let attach = with(["cwd": .string(cwd), "cols": .number(200), "rows": .number(50)])
        let stream = session.supervisor.subscribe(TerminalRPC.attach, payload: { attach }) { event in
            guard case .value(let json) = event, json["type"]?.stringValue == "output", let data = json["data"]?.stringValue else { return }
            await output.append(data)
        }
        defer {
            stream.cancel()
            Task { _ = try? await environments.request(env, TerminalRPC.close, with(["deleteHistory": .bool(true)])) }
        }
        do {
            // Wait for the shell's first prompt before typing.
            for _ in 0..<40 where await output.text.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            var rest = Substring(command)
            while !rest.isEmpty {
                _ = try await environments.request(env, TerminalRPC.write, with(["data": .string(String(rest.prefix(256)))]))
                rest = rest.dropFirst(256)
                try await Task.sleep(for: .milliseconds(40))
            }
            var sentInput = input == nil
            // ponytail: 3 minutes covers a 25 MB download on a slow line; raise it if installs time out there
            for _ in 0..<720 {
                try await Task.sleep(for: .milliseconds(250))
                let lines = HelperInstall.scan(await output.text)
                if !sentInput, lines.contains(.ready), let input {
                    sentInput = true
                    _ = try await environments.request(env, TerminalRPC.write, with(["data": .string(input)]))
                }
                if lines.contains(where: { if case .ok = $0 { true } else if case .failed = $0 { true } else { false } }) { return lines }
            }
        } catch {}
        return []
    }

    /// Revokes the helper's sign-ins on every machine, all of them or all but the newest.
    private func revokeOld(keepNewest: Bool) async {
        for m in machines() {
            guard let shell = environments.session(m.id),
                  let all = try? await shell.http.get("api/auth/clients", token: shell.token, as: [AuthClientSession].self) else { continue }
            var helpers = OrchestratorHandoff.helperSessions(all).sorted { ($0.issuedAt.epochMs ?? 0) > ($1.issuedAt.epochMs ?? 0) }
            if keepNewest, !helpers.isEmpty { helpers.removeFirst() }
            for s in helpers { try? await shell.http.revokeClient(sessionId: s.sessionId, token: shell.token) }
        }
    }

    private actor OutputBox {
        private(set) var text = ""
        // ponytail: keeps the last 64 KB; the markers are always in the newest lines
        func append(_ s: String) { text = String((text + s).suffix(65_536)) }
    }
}
