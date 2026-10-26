import Foundation
import Testing
import T3Protocol
@testable import T3Client
@testable import T3Transport

/// Read-only load against the fixed sandbox. Never dispatches commands or starts provider turns.
@Suite(.serialized, .integration,
       .enabled(if: ProcessInfo.processInfo.environment["CW_SANDBOX_AUDIT"] == "1"))
struct SandboxResponsivenessAuditTests {
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func report(_ name: String, _ values: [Double]) throws {
        let ordered = values.sorted()
        func p(_ fraction: Double) -> Double {
            ordered[min(ordered.count - 1, Int(ceil(Double(ordered.count) * fraction)) - 1)]
        }
        let result: [String: Any] = ["name": name, "samples": values.count,
            "p50_ms": p(0.5), "p95_ms": p(0.95), "p99_ms": p(0.99), "max_ms": ordered.last!, "raw_ms": values]
        print("SANDBOX_AUDIT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    @Test(.timeLimit(.minutes(5)))
    func requestBurstsThreadSwitchesAndReconnects() async throws {
        let (http, descriptor, token) = try #require(await SandboxIntegrationTests.sandbox(), "start scripts/sandbox-server")
        let supervisor = ConnectionSupervisor(dependencies: .init(connect: ConnectionSupervisor.directConnector(
            http: http, environmentId: descriptor.environmentId,
            identity: ClientIdentity(appVersion: "0.0.0-responsiveness-audit"), token: { token })))
        defer { Task { await supervisor.disconnect() } }
        await supervisor.connect()
        try #require(await eventually(seconds: 30) { await supervisor.state.phase == .connected })
        let shell = try await http.get("api/orchestration/shell", token: token, as: ShellSnapshot.self)
        let threadIds = Array(shell.threads.prefix(12).map(\.id))
        try #require(!threadIds.isEmpty, "sandbox must contain existing threads")

        var rpcTimes: [Double] = []
        for _ in 0..<20 {
            let times = try await withThrowingTaskGroup(of: Double.self, returning: [Double].self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        let start = ContinuousClock.now
                        let config = try await supervisor.request("server.getConfig")
                        #expect(config["environment"]?["environmentId"]?.stringValue == descriptor.environmentId)
                        return Self.milliseconds(ContinuousClock.now - start)
                    }
                }
                var samples: [Double] = []
                for try await value in group { samples.append(value) }
                return samples
            }
            rpcTimes += times
        }
        try Self.report("rpc_20_concurrent", rpcTimes)

        var threadTimes: [Double] = []
        var reconnectTimes: [Double] = []
        for round in 0..<20 {
            let connection = try #require(await supervisor.currentConnection)
            for offset in 0..<5 {
                let id = threadIds[(round * 5 + offset) % threadIds.count]
                let start = ContinuousClock.now
                let stream = await connection.stream("orchestration.subscribeThread", payload: .object([
                    "threadId": .string(id.rawValue), "requestCompletionMarker": .bool(true),
                    "acceptBoundedSnapshot": .bool(true), "acceptCompactTurnItems": .bool(true),
                ]))
                var sawSnapshot = false
                var synchronized = false
                for try await json in stream {
                    switch try json.decode(as: ThreadStreamItem.self) {
                    case .snapshot(let snapshot):
                        #expect(snapshot.projection.thread.id == id)
                        sawSnapshot = true
                    case .synchronized: synchronized = true
                    default: break
                    }
                    if synchronized { break }
                }
                #expect(sawSnapshot && synchronized)
                threadTimes.append(Self.milliseconds(ContinuousClock.now - start))
            }
            let generation = await supervisor.state.generation
            let start = ContinuousClock.now
            await connection.close(reason: "sandbox audit reconnect")
            // Repeated synthetic drops intentionally grow T3's automatic backoff to minutes.
            // Exercise the user's Retry action so this measures reconnect work, not that policy.
            try #require(await eventually(seconds: 5) { await supervisor.state.phase == .backoff })
            await supervisor.retryNow()
            try #require(await eventually(seconds: 15) {
                let state = await supervisor.state
                return state.phase == .connected && state.generation > generation
            })
            _ = try await supervisor.request("server.probe")
            reconnectTimes.append(Self.milliseconds(ContinuousClock.now - start))
        }
        try Self.report("thread_subscribe_decode_and_marker", threadTimes)
        try Self.report("retry_action_reconnect_and_probe", reconnectTimes)
        await supervisor.disconnect()
    }
}
