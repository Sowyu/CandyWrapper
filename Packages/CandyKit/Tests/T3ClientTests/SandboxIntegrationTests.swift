import Foundation
import Testing
@testable import T3Client
import T3Protocol

/// Runs against the sandbox server from scripts/sandbox-server (127.0.0.1:47391) and skips
/// when it isn't running. Never points at the live service.
struct SandboxIntegrationTests {
    static let baseURL = URL(string: "http://127.0.0.1:47391")!
    static let tokenFile = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "CandyWrapper-research/sandbox/session.token")

    /// Descriptor and cached bearer, or nil when the sandbox isn't usable.
    static func sandbox() async -> (EnvironmentHTTP, EnvironmentDescriptor, String)? {
        var http = EnvironmentHTTP(baseURL: baseURL)
        http.timeout = 2
        guard let descriptor = try? await http.descriptor(),
              let token = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let session = try? await http.session(token: token), session.authenticated
        else { return nil }
        return (http, descriptor, token)
    }

    @Test(.timeLimit(.minutes(1)))
    func connectSubscribeInterruptAndReconnect() async throws {
        guard let (http, descriptor, token) = await Self.sandbox() else {
            print("sandbox server not reachable or no cached token; skipping")
            return
        }
        #expect(descriptor.isCompatible)
        let ticket = try await http.webSocketTicket(token: token)
        #expect(!ticket.ticket.isEmpty)

        let supervisor = ConnectionSupervisor(dependencies: .init(connect: ConnectionSupervisor.directConnector(
            http: http, environmentId: descriptor.environmentId,
            identity: ClientIdentity(appVersion: "0.0.0-candykit-test"), token: { token })))
        await supervisor.connect()
        #expect(await eventually(seconds: 10) { await supervisor.state.phase == .connected })

        let config = try await supervisor.request("server.getConfig")
        #expect(config["environment"]?["environmentId"]?.stringValue == descriptor.environmentId)

        let connection = try #require(await supervisor.currentConnection)
        var kinds: [String] = []
        do {
            let shell = await connection.stream("orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)]))
            for try await item in shell {
                let kind = item["kind"]?.stringValue ?? "?"
                kinds.append(kind)
                if kind == "synchronized" { break }
            }
        }
        // Leaving the scope dropped the stream, which sent Interrupt. The session stays usable.
        #expect(kinds.first == "snapshot")
        #expect(kinds.last == "synchronized")
        _ = try await connection.request("server.probe")

        // Unknown tags fail only that request, as a Die.
        do {
            _ = try await connection.request("projects.list")
            Issue.record("expected a Die")
        } catch let e as RPCClientError {
            guard case .failure(let causes) = e, case .die = causes.first else {
                Issue.record("expected Die, got \(e)")
                return
            }
        }

        await connection.close(reason: "integration test")
        #expect(await eventually(seconds: 10) {
            let s = await supervisor.state
            return s.generation == 2 && s.phase == .connected
        })
        _ = try await supervisor.request("server.probe")
        await supervisor.disconnect()
        #expect(await supervisor.state.status == .available)
    }
}
