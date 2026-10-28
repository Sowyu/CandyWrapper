import Testing
import T3Protocol
@testable import T3Client
@testable import T3Transport

struct FirstSnapshotTests {
    @Test(arguments: ["scheduledTasks.subscribe", "subscribeAuthAccess"])
    func readsOneSnapshotAndInterruptsTheSubscription(tag: String) async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        await supervisor.connect()
        #expect(await eventually { await supervisor.currentConnection != nil })
        let read = Task { try await supervisor.firstSnapshot(tag) }
        let socket = try #require(harness.lastSocket)
        #expect(await eventually { !socket.sent.isEmpty })
        let request = try #require(socket.sent.compactMap { if case .request(let r) = $0 { r } else { nil } }.first)
        #expect(request.tag == tag)
        let snapshot: JSONValue = tag == "subscribeAuthAccess"
            ? .object(["type": .string("snapshot"), "payload": .object(["clientSessions": .array([]), "pairingLinks": .array([])])])
            : .object(["tasks": .array([])])
        socket.deliver(.chunk(requestId: request.id, values: [snapshot]))
        #expect(try await read.value == snapshot)
        #expect(await eventually { socket.sent.contains(.interrupt(request.id)) })
        await supervisor.disconnect()
    }

    @Test func disconnectedSnapshotReadFailsWithoutWaitingForReconnect() async {
        let supervisor = ConnectionSupervisor(dependencies: Harness([]).dependencies)
        await #expect(throws: RPCClientError.self) { try await supervisor.firstSnapshot("scheduledTasks.subscribe") }
    }
}
