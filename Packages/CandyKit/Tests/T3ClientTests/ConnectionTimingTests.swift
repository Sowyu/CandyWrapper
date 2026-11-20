import Foundation
import Testing
@testable import T3Client
@testable import T3Transport
import T3Protocol

/// Headless timings of CandyWrapper's connection against a sandbox server, for
/// docs/research/connection-vs-t3-desktop-4928.md. No window. Opt-in with `CW_TIMING=1`; run it through
/// scripts/connection-timing/run, which starts the proxy and passes the sandbox's address and token.
///
/// Each test prints `TIMING {json}` lines and appends them to `CW_TIMING_OUT`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CW_TIMING"] == "1", "set CW_TIMING=1"))
struct ConnectionTimingTests {
    static let env = ProcessInfo.processInfo.environment
    static let baseURL = URL(string: env["CW_TIMING_URL"] ?? "http://127.0.0.1:47392")!
    static let token = (try? String(contentsOfFile: env["CW_TIMING_TOKEN"] ?? "", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    static let runs = Int(env["CW_TIMING_RUNS"] ?? "") ?? 5
    static let identity = ClientIdentity(appVersion: "0.0.0-connection-timing")

    // MARK: Cold connect

    /// The app's sequence (ShellSession.prepareShell): descriptor, ticket, socket, config snapshot, then the
    /// HTTP shell, then `subscribeShell` from its cursor. `early` starts the HTTP shell as soon as the descriptor
    /// names the shell flags, as T3 4928 does (#35071, client-runtime state/shell.ts:562-611).
    @Test(.timeLimit(.minutes(5)))
    func coldConnect() async throws {
        for early in [false, true] {
            var samples: [[String: Double]] = []
            for _ in 0..<Self.runs {
                samples.append(try await Self.connectOnce(early: early))
            }
            Self.report("cold-connect", ["early": early ? 1 : 0], samples)
        }
    }

    static func connectOnce(early: Bool) async throws -> [String: Double] {
        let t0 = ContinuousClock.now
        func ms() -> Double { (ContinuousClock.now - t0).milliseconds }
        var marks: [String: Double] = [:]
        let http = EnvironmentHTTP(baseURL: baseURL)
        let descriptor = try await http.descriptor()
        marks["descriptor"] = ms()
        let shellFlags = descriptor.capabilities["shellThreadFamilies"]?.boolValue == true
        var earlyShell: Task<(Data, Int), Error>?
        if early, shellFlags {
            earlyShell = Task { try await Self.rawGet(Self.shellPath(descriptor.capabilities)) }
        }
        let ticket = try await http.webSocketTicket(token: token)
        marks["ticket"] = ms()
        let socket = CountingSocket(try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity)))
        marks["socketOpen"] = ms()
        let connection = RPCConnection(socket: socket)
        await connection.start()
        var configPayload: [String: JSONValue] = ["environmentThemes": .bool(true), "usageLimitSources": .bool(true), "usageLimitsCommand": .bool(true)]
        if descriptor.capabilities["providerWorkspaceSnapshotsOnDemand"]?.boolValue == true { configPayload["workspaceSnapshotsOnDemand"] = .bool(true) }
        let configStream = await connection.stream("subscribeServerConfig", payload: .object(configPayload), snapshotFirst: true)
        var config: JSONValue = .null
        for try await value in configStream { config = value["config"] ?? .null; break }
        marks["configSnapshot"] = ms()
        marks["configBytes"] = Double(socket.received)
        let path = shellPath(config.objectValue ?? [:])
        let shellData: (Data, Int)
        if let earlyShell, path == shellPath(descriptor.capabilities) { shellData = try await earlyShell.value } else { shellData = try await rawGet(path) }
        marks["httpShell"] = ms()
        marks["httpShellBodyBytes"] = Double(shellData.0.count)
        marks["httpShellWireBytes"] = Double(shellData.1)
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: shellData.0)
        var payload: [String: JSONValue] = ["requestCompletionMarker": .bool(true)]
        if config["shellThreadFamilies"]?.boolValue == true { payload["omitIdleSubagents"] = .bool(true) }
        if config["shellOlderSettled"]?.boolValue == true { payload["omitOlderSettled"] = .bool(true) }
        if let sequence = snapshot["snapshotSequence"]?.doubleValue { payload["afterSequence"] = .number(sequence) }
        let before = socket.received
        for try await item in await connection.stream("orchestration.subscribeShell", payload: .object(payload)) {
            if item["kind"]?.stringValue == "synchronized" { break }
        }
        marks["shellSynchronized"] = ms()
        marks["shellSocketBytes"] = Double(socket.received - before)
        marks["socketRxBytes"] = Double(socket.received)
        marks["socketTxBytes"] = Double(socket.sent)
        marks["socketRxFrames"] = Double(socket.receivedFrames)
        await connection.close()
        return marks
    }

    static func shellPath(_ flags: [String: JSONValue]) -> String {
        var query: [String] = []
        if flags["shellThreadFamilies"]?.boolValue == true { query.append("omitIdleSubagents=1") }
        if flags["shellOlderSettled"]?.boolValue == true { query.append("omitOlderSettled=1") }
        return "/api/orchestration/shell" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    // MARK: Config bytes

    /// What the 4928 bandwidth flags save on the first config snapshot (rpc.ts:2145-2154).
    @Test(.timeLimit(.minutes(2)))
    func configSnapshotBytes() async throws {
        for flags in [false, true] {
            let (connection, socket) = try await Self.open()
            var payload: [String: JSONValue] = ["environmentThemes": .bool(true), "usageLimitSources": .bool(true),
                                                "usageLimitsCommand": .bool(true), "workspaceSnapshotsOnDemand": .bool(true)]
            if flags {
                payload["providerCatalogsOnDemand"] = .bool(true)
                payload["providerCatalogDigests"] = .bool(true)
                payload["providerStatusDeltas"] = .bool(true)
            }
            let t0 = ContinuousClock.now
            for try await _ in await connection.stream("subscribeServerConfig", payload: .object(payload), snapshotFirst: true) { break }
            Self.report("config-snapshot", ["catalogFlags": flags ? 1 : 0],
                        [["ms": (ContinuousClock.now - t0).milliseconds, "bytes": Double(socket.received)]])
            await connection.close()
        }
    }

    // MARK: Thread open

    /// ThreadSession's open: the bounded HTTP snapshot, then `subscribeThread` from its sequence until
    /// `synchronized`. Also the socket-only open that follows a failed HTTP read.
    @Test(.timeLimit(.minutes(5)))
    func threadOpen() async throws {
        let (connection, socket) = try await Self.open()
        for (label, key) in [("short", "CW_TIMING_SHORT"), ("long", "CW_TIMING_LONG")] {
            guard let id = Self.env[key], !id.isEmpty else { continue }
            for deferWork in [false, true] {
                var samples: [[String: Double]] = []
                for _ in 0..<Self.runs {
                    let t0 = ContinuousClock.now
                    var path = ThreadHistoryRequest.boundedSnapshotPath(ThreadId(rawValue: id))
                    if deferWork { path += "&deferWork=1" }
                    let (body, wire) = try await Self.rawGet(path)
                    let httpMs = (ContinuousClock.now - t0).milliseconds
                    let snapshot = try JSONDecoder().decode(JSONValue.self, from: body)
                    let sequence = snapshot["snapshotSequence"]?.doubleValue ?? snapshot["sequence"]?.doubleValue
                    var input: [String: JSONValue] = ["threadId": .string(id), "requestCompletionMarker": .bool(true),
                                                      "acceptBoundedSnapshot": .bool(true), "acceptCompactTurnItems": .bool(true),
                                                      "acceptDedupedBodies": .bool(true), "acceptCompactIds": .bool(true)]
                    if let sequence { input["afterSequence"] = .number(sequence) }
                    let before = socket.received
                    for try await item in await connection.stream("orchestration.subscribeThread", payload: .object(input)) {
                        if item["kind"]?.stringValue == "synchronized" { break }
                    }
                    samples.append(["http": httpMs, "synchronized": (ContinuousClock.now - t0).milliseconds,
                                    "httpBodyBytes": Double(body.count), "httpWireBytes": Double(wire),
                                    "socketBytes": Double(socket.received - before)])
                }
                Self.report("thread-open-http", ["thread": label == "long" ? 1 : 0, "deferWork": deferWork ? 1 : 0], samples)
            }
            var samples: [[String: Double]] = []
            for _ in 0..<Self.runs {
                let t0 = ContinuousClock.now
                let before = socket.received
                let input: [String: JSONValue] = ["threadId": .string(id), "requestCompletionMarker": .bool(true),
                                                  "acceptBoundedSnapshot": .bool(true), "acceptCompactTurnItems": .bool(true),
                                                  "acceptDedupedBodies": .bool(true), "acceptCompactIds": .bool(true)]
                for try await item in await connection.stream("orchestration.subscribeThread", payload: .object(input)) {
                    if item["kind"]?.stringValue == "synchronized" { break }
                }
                samples.append(["synchronized": (ContinuousClock.now - t0).milliseconds, "socketBytes": Double(socket.received - before)])
            }
            Self.report("thread-open-socket", ["thread": label == "long" ? 1 : 0], samples)
        }
        await connection.close()
    }

    // MARK: Reconnect after a restart

    /// Kills the server named by `CW_TIMING_SERVER_DIR` (its server.pid), starts it again with
    /// scripts/sandbox-server, and times from the moment its descriptor answers to a supervised session whose
    /// shell subscription is synchronized again.
    @Test(.timeLimit(.minutes(20)))
    func reconnectAfterRestart() async throws {
        guard let dir = Self.env["CW_TIMING_SERVER_DIR"], let port = Self.env["CW_TIMING_SERVER_PORT"],
              let version = Self.env["CW_TIMING_SERVER_VERSION"], let repo = Self.env["CW_TIMING_REPO"] else { return }
        let http = EnvironmentHTTP(baseURL: Self.baseURL)
        let supervisor = ConnectionSupervisor(dependencies: Self.dependencies(http))
        let synced = SyncCounter()
        let shell = supervisor.subscribe("orchestration.subscribeShell", payload: { .object(["requestCompletionMarker": .bool(true)]) }) { event in
            if case .value(let json) = event, json["kind"]?.stringValue == "synchronized" { await synced.bump() }
        }
        defer { shell.cancel() }
        await supervisor.connect()
        #expect(await eventually(seconds: 30) { await synced.count >= 1 })
        var samples: [[String: Double]] = []
        for _ in 0..<Self.runs {
            // Up for 30 s resets the ladder, so each restart starts from a live session's first loss.
            try await Task.sleep(for: .seconds(31))
            let seen = await synced.count
            let pid = try String(contentsOfFile: dir + "/server.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let killedAt = ContinuousClock.now
            kill(pid_t(pid)!, SIGTERM)
            #expect(await eventually(seconds: 30) { await supervisor.state.phase != .connected })
            let noticed = (ContinuousClock.now - killedAt).milliseconds
            // Wait for the old process to exit before starting the next one on the same port.
            for _ in 0..<600 where kill(pid_t(pid)!, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
            let start = Process()
            start.executableURL = URL(filePath: repo + "/scripts/sandbox-server")
            start.arguments = [version]
            start.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SANDBOX_DIR": dir, "SANDBOX_PORT": port]
            start.standardOutput = FileHandle.nullDevice
            try start.run()
            start.waitUntilExit()
            let probe = EnvironmentHTTP(baseURL: Self.baseURL)
            var readyAt = ContinuousClock.now
            for _ in 0..<2400 {
                if (try? await probe.descriptor()) != nil { readyAt = ContinuousClock.now; break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(await eventually(seconds: 300) { await synced.count > seen })
            let back = ContinuousClock.now
            samples.append(["noticedClose": noticed, "serverReady": (readyAt - killedAt).milliseconds,
                            "readyToSynchronized": (back - readyAt).milliseconds, "attempts": Double(await supervisor.state.attempt)])
        }
        Self.report("reconnect-after-restart", [:], samples)
        await supervisor.disconnect()
    }

    // MARK: Half-open socket

    /// Connects through scripts/connection-timing/freeze-proxy.py, freezes the socket without a close, then
    /// sends one signal and times how long the supervisor takes to notice and to be connected again.
    @Test(.timeLimit(.minutes(10)))
    func halfOpenRecovery() async throws {
        guard let proxy = Self.env["CW_TIMING_PROXY_URL"].flatMap(URL.init(string:)), let control = Self.env["CW_TIMING_PROXY_CONTROL"] else { return }
        let idleWait = Double(Self.env["CW_TIMING_IDLE_WAIT"] ?? "") ?? 30
        let only = Self.env["CW_TIMING_SCENARIOS"].map { Set($0.split(separator: ",").map(String.init)) }
        for scenario in ["idle", "turnRunning", "applicationActive", "systemWake", "networkPathChanged", "retryNow"] where only?.contains(scenario) ?? true {
            try "open".write(toFile: control, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(150))
            let http = EnvironmentHTTP(baseURL: proxy)
            let supervisor = ConnectionSupervisor(dependencies: Self.dependencies(http))
            await supervisor.connect()
            #expect(await eventually(seconds: 30) { await supervisor.state.phase == .connected })
            if scenario == "turnRunning" { await supervisor.setExpectingTraffic(true) }
            let generation = await supervisor.state.generation
            try "freeze".write(toFile: control, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(150))
            let frozenAt = ContinuousClock.now
            switch scenario {
            case "applicationActive": await supervisor.wakeup(.applicationActive)
            case "systemWake": await supervisor.wakeup(.systemWake)
            case "networkPathChanged": await supervisor.networkPathChanged()
            case "retryNow": await supervisor.retryNow()
            default: break
            }
            var noticed: Double = -1
            var back: Double = -1
            let limit = frozenAt + .seconds(idleWait)
            while ContinuousClock.now < limit {
                let state = await supervisor.state
                if noticed < 0, state.phase != .connected || state.generation > generation { noticed = (ContinuousClock.now - frozenAt).milliseconds }
                if Self.env["CW_TIMING_TRACE"] == "1" { print("TRACE \((ContinuousClock.now - frozenAt).milliseconds) \(state.phase) gen \(state.generation) attempt \(state.attempt) \(state.lastFailure ?? "")") }
                if state.phase == .connected, state.generation > generation { back = (ContinuousClock.now - frozenAt).milliseconds; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            Self.report("half-open", ["scenario": Double(["idle", "turnRunning", "applicationActive", "systemWake", "networkPathChanged", "retryNow"].firstIndex(of: scenario)!)],
                        [["noticed": noticed, "reconnected": back, "limit": idleWait * 1000]], name: scenario)
            await supervisor.disconnect()
        }
        try "open".write(toFile: control, atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    /// `CW_TIMING_BASELINE=1` measures the supervisor as it was before the connection fixes: no host check and no
    /// pool reset. The ladder and first-loss timing come from the code under test either way.
    static func dependencies(_ http: EnvironmentHTTP) -> ConnectionSupervisor.Dependencies {
        if env["CW_TIMING_BASELINE"] == "1" {
            return .init(connect: ConnectionSupervisor.directConnector(http: http, environmentId: nil, identity: identity, token: { token }))
        }
        return .direct(http: http, environmentId: nil, identity: identity, token: { token })
    }

    static func open() async throws -> (RPCConnection, CountingSocket) {
        let http = EnvironmentHTTP(baseURL: baseURL)
        let ticket = try await http.webSocketTicket(token: token)
        let socket = CountingSocket(try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity)))
        let connection = RPCConnection(socket: socket)
        await connection.start()
        return (connection, socket)
    }

    /// GET with the bearer; returns the decoded body and the bytes on the wire (gzip when the server compressed).
    static func rawGet(_ path: String) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
        let metrics = MetricsDelegate()
        let (data, response) = try await URLSession.shared.data(for: request, delegate: metrics)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EnvironmentHTTPError.status((response as? HTTPURLResponse)?.statusCode ?? 0, nil) }
        return (data, metrics.wireBytes ?? data.count)
    }

    static func report(_ name: String, _ tags: [String: Double], _ samples: [[String: Double]], name label: String? = nil) {
        var keys = Set<String>()
        samples.forEach { keys.formUnion($0.keys) }
        var medians: [String: Double] = [:]
        for key in keys {
            let values = samples.compactMap { $0[key] }.sorted()
            medians[key] = values.isEmpty ? 0 : values[values.count / 2]
        }
        let line: [String: Any] = ["test": name, "label": label ?? "", "server": baseURL.absoluteString, "tags": tags,
                                   "runs": samples.count, "median": medians, "samples": samples]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let text = String(decoding: data, as: UTF8.self)
        print("TIMING " + text)
        if let out = env["CW_TIMING_OUT"], let handle = FileHandle(forWritingAtPath: out) ?? {
            FileManager.default.createFile(atPath: out, contents: nil)
            return FileHandle(forWritingAtPath: out)
        }() {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        }
    }
}

/// Counts what crosses an RPC socket.
final class CountingSocket: RPCSocket, @unchecked Sendable {
    let inner: any RPCSocket
    private let lock = NSLock()
    private var rx = 0, tx = 0, frames = 0
    init(_ inner: any RPCSocket) { self.inner = inner }
    var received: Int { lock.withLock { rx } }
    var sent: Int { lock.withLock { tx } }
    var receivedFrames: Int { lock.withLock { frames } }
    func send(_ frame: Data) async throws {
        lock.withLock { tx += frame.count }
        try await inner.send(frame)
    }
    func receive() async throws -> Data {
        let frame = try await inner.receive()
        lock.withLock { rx += frame.count; frames += 1 }
        return frame
    }
    func close() { inner.close() }
}

private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var wireBytes: Int?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        wireBytes = metrics.transactionMetrics.last.map { Int($0.countOfResponseBodyBytesReceived) }
    }
}

private actor SyncCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
