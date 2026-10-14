import Foundation
import Testing
@testable import T3Client
import T3Protocol

/// `ServerUpdater` against a fake server that plays T3's frames for each update path
/// (client-runtime state/server.ts:684-912, contracts server.ts:949-1003).
struct ServerUpdaterTests {
    final class Stages: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ServerUpdateStage] = []
        func add(_ s: ServerUpdateStage) { lock.withLock { if list.last != s { list.append(s) } } }
        var all: [ServerUpdateStage] { lock.withLock { list } }
    }

    /// The request with `tag` the client sent on `socket`.
    func request(_ socket: FakeSocket, _ tag: String) async -> RPCRequest? {
        @Sendable func find() -> RPCRequest? {
            for case .request(let r) in socket.sent where r.tag == tag { return r }
            return nil
        }
        _ = await eventually { find() != nil }
        return find()
    }

    func ready(_ version: String, outcome: [String: JSONValue]? = nil) -> JSONValue {
        var payload: [String: JSONValue] = ["at": .string("2026-10-14T00:00:00.000Z"),
                                            "environment": .object(["environmentId": .string("env"), "label": .string("box"), "serverVersion": .string(version),
                                                                    "capabilities": .object([:])])]
        if let outcome { payload["updateOutcome"] = .object(outcome) }
        return .object(["version": .number(1), "sequence": .number(2), "type": .string("ready"), "payload": .object(payload)])
    }

    func connected(_ outcomes: Int) async -> (ConnectionSupervisor, Harness) {
        let h = Harness(Array(repeating: .succeed, count: outcomes))
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        _ = await eventually { await s.state.phase == .connected }
        return (s, h)
    }

    let old = "0.0.46-nightly.20261009.2861", new = "0.0.46-nightly.20261011.2994"

    @Test func bootServiceStreamsProgressRestartsAndChecksTheOutcome() async throws {
        let (s, h) = await connected(2)
        let stages = Stages()
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("boot-service"), "serverSelfUpdateProgress": .bool(true)])
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: false, capabilities: caps,
                                        nudgeInterval: .milliseconds(10)) { stage, _ in stages.add(stage) }
        }
        let first = h.lastSocket!
        let call = try #require(await request(first, "server.updateServerWithProgress"))
        #expect(call.payload == .object(["targetVersion": .string(new)]))
        first.deliver(.chunk(requestId: call.id, values: [.object(["type": .string("progress"), "stage": .string("downloading")])]))
        first.deliver(.chunk(requestId: call.id, values: [.object(["type": .string("progress"), "stage": .string("installing")])]))
        let result: JSONValue = .object(["targetVersion": .string(new), "method": .string("boot-service"), "updateId": .string("u1")])
        first.deliver(.chunk(requestId: call.id, values: [.object(["type": .string("complete"), "result": result])]))
        // The launcher stops the old process before the stream's exit arrives.
        #expect(await eventually { stages.all.last == .resuming })
        first.close()
        #expect(await eventually { h.attemptCount == 2 })
        let second = h.lastSocket!
        let lifecycle = try #require(await request(second, "subscribeServerLifecycle"))
        second.deliver(.chunk(requestId: lifecycle.id, values: [ready(new, outcome: ["id": .string("u1"), "fromVersion": .string(old),
                                                                                    "targetVersion": .string(new), "status": .string("committed")])]))
        let done = try await update.value
        #expect(done.updateId == "u1")
        #expect(stages.all == [.downloading, .installing, .resuming])
    }

    @Test func aRolledBackUpdateFailsWithTheLaunchersReason() async throws {
        let (s, h) = await connected(2)
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("boot-service"), "serverSelfUpdateProgress": .bool(true)])
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: true, capabilities: caps,
                                        nudgeInterval: .milliseconds(10)) { _, _ in }
        }
        let first = h.lastSocket!
        let call = try #require(await request(first, "server.updateServerWithProgress"))
        #expect(call.payload == .object(["targetVersion": .string(new), "continueRunningThreads": .bool(true)]))
        let result: JSONValue = .object(["targetVersion": .string(new), "method": .string("boot-service"), "updateId": .string("u2")])
        first.deliver(.chunk(requestId: call.id, values: [.object(["type": .string("complete"), "result": result])]))
        first.close()
        #expect(await eventually { h.attemptCount == 2 })
        let second = h.lastSocket!
        let lifecycle = try #require(await request(second, "subscribeServerLifecycle"))
        // The old version's replayed ready event does not match the update id and is skipped.
        second.deliver(.chunk(requestId: lifecycle.id, values: [ready(old)]))
        second.deliver(.chunk(requestId: lifecycle.id, values: [ready(old, outcome: ["id": .string("u2"), "fromVersion": .string(old), "targetVersion": .string(new),
                                                                                    "status": .string("rolled-back"), "reason": .string("Trial did not become ready.")])]))
        await #expect(throws: ServerUpdater.Failure("Trial did not become ready.")) { try await update.value }
    }

    @Test func aTypedFailureReadsLikeT3() async throws {
        let (s, h) = await connected(1)
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("boot-service")])
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: false, capabilities: caps) { _, _ in }
        }
        let socket = h.lastSocket!
        let call = try #require(await request(socket, "server.updateServer"))
        let error = RPCTypedError(tag: "ServerSelfUpdateError", fields: ["reason": .string("A server update is already in progress.")])
        socket.deliver(.exit(requestId: call.id, exit: .failure([.fail(error)])))
        await #expect(throws: ServerUpdater.Failure("Server update failed: A server update is already in progress.")) { try await update.value }
    }

    /// Older servers can drop the socket before the unary answer; the ready event's version proves it.
    @Test func aLegacyUnaryHandoffLossCountsAsAccepted() async throws {
        let (s, h) = await connected(2)
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("respawn")])
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: false, capabilities: caps,
                                        nudgeInterval: .milliseconds(10)) { _, _ in }
        }
        let first = h.lastSocket!
        _ = try #require(await request(first, "server.updateServer"))
        first.close()
        #expect(await eventually { h.attemptCount == 2 })
        let second = h.lastSocket!
        let lifecycle = try #require(await request(second, "subscribeServerLifecycle"))
        second.deliver(.chunk(requestId: lifecycle.id, values: [ready(new)]))
        let done = try await update.value
        #expect(done == ServerSelfUpdateResult(targetVersion: new, method: "respawn"))
    }

    @Test func aDesktopAppGetsTheCommitTokenThenComesBackOnTheTarget() async throws {
        let (s, h) = await connected(2)
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("desktop-managed"), "desktopAppUpdate": .bool(true),
                                             "serverSelfUpdateProgress": .bool(true)])
        #expect(caps.canUpdateRemotely)
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: false, capabilities: caps,
                                        nudgeInterval: .milliseconds(10)) { _, _ in }
        }
        let first = h.lastSocket!
        let call = try #require(await request(first, "server.updateServerWithProgress"))
        let result: JSONValue = .object(["targetVersion": .string("0.0.47"), "method": .string("desktop-app"), "desktopUpdateToken": .string("tok")])
        first.deliver(.chunk(requestId: call.id, values: [.object(["type": .string("complete"), "result": result])]))
        first.deliver(.exit(requestId: call.id, exit: .success(.null)))
        let commit = try #require(await request(first, "server.commitDesktopUpdate"))
        #expect(commit.payload == .object(["requestId": .string("tok")]))
        // The commit never answers: the app quits and takes the socket with it.
        first.close()
        #expect(await eventually { h.attemptCount == 2 })
        let second = h.lastSocket!
        let lifecycle = try #require(await request(second, "subscribeServerLifecycle"))
        second.deliver(.chunk(requestId: lifecycle.id, values: [ready("0.0.47")]))
        let done = try await update.value
        #expect(done.targetVersion == "0.0.47")
    }

    @Test func noReadyEventTimesOut() async throws {
        let (s, h) = await connected(1)
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("boot-service")])
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: false, capabilities: caps,
                                        resumeTimeout: .milliseconds(200)) { _, _ in }
        }
        let socket = h.lastSocket!
        let call = try #require(await request(socket, "server.updateServer"))
        socket.deliver(.exit(requestId: call.id, exit: .success(.object(["targetVersion": .string(new), "method": .string("boot-service"), "updateId": .string("u3")]))))
        await #expect(throws: ServerUpdater.Failure("The server did not resume on t3@\(new).")) { try await update.value }
    }

    @Test func aStreamThatEndsWithoutCompleteFails() async throws {
        let (s, h) = await connected(1)
        let caps = ServerUpdateCapabilities(["serverSelfUpdate": .string("boot-service"), "serverSelfUpdateProgress": .bool(true)])
        let update = Task {
            try await ServerUpdater.run(supervisor: s, targetVersion: new, continueRunningThreads: false, capabilities: caps) { _, _ in }
        }
        let socket = h.lastSocket!
        let call = try #require(await request(socket, "server.updateServerWithProgress"))
        socket.deliver(.chunk(requestId: call.id, values: [.object(["type": .string("progress"), "stage": .string("downloading")])]))
        socket.deliver(.exit(requestId: call.id, exit: .success(.null)))
        await #expect(throws: ServerUpdater.Failure("The t3@\(new) update ended before the server accepted the restart.")) { try await update.value }
    }
}
