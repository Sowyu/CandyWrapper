import Foundation
import T3Protocol

/// Runs one server self-update over an environment's connection, as client-runtime's `updateServer`
/// does (state/server.ts:684-912):
///
/// 1. `server.updateServerWithProgress` when the server streams progress, else `server.updateServer`.
///    An older launcher-backed server may drop the socket before its unary answer; that loss counts
///    as the handoff.
/// 2. A desktop app that staged the update gets `server.commitDesktopUpdate` with its token. The commit
///    relaunches the app, so a dropped socket is success.
/// 3. "Restarting…": reconnect attempts stay about a second apart, and the `ready` lifecycle event of
///    the new process must carry the launcher's committed outcome (or the target version), within
///    4 minutes. A desktop app that came back on the old version gets the commit again, up to 3 times.
public enum ServerUpdater {
    /// The message T3 shows in the failure toast and the progress row.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// `onStage` runs on every stage change. Throws `Failure`, or `CancellationError` when cancelled.
    public static func run(supervisor: ConnectionSupervisor, targetVersion requested: String, continueRunningThreads: Bool,
                           capabilities: ServerUpdateCapabilities, resumeTimeout: Duration = ServerUpdateLogic.resumeTimeout,
                           nudgeInterval: Duration = .seconds(1),
                           onStage: @escaping @Sendable (ServerUpdateStage, String) async -> Void) async throws -> ServerSelfUpdateResult {
        let input = ServerUpdateLogic.input(targetVersion: requested, continueRunningThreads: continueRunningThreads)
        // Without a session a lost unary call would pass for the handoff.
        guard let connection = await supervisor.currentConnection else { throw Failure("The server is not connected.") }
        await onStage(.downloading, requested)
        let result = try await handoff(connection, input: input, targetVersion: requested, capabilities: capabilities, onStage: onStage)

        var commitLostTransport = false
        // The generation before the commit: a lost commit waits for a session newer than it.
        let beforeCommit = await supervisor.state.generation
        if let token = result.desktopUpdateToken, result.method == "desktop-app" {
            do {
                _ = try await supervisor.request("server.commitDesktopUpdate", payload: .object(["requestId": .string(token)]))
            } catch let error as RPCClientError {
                guard isHandoffLoss(error) else { throw Failure(message(error)) }
                commitLostTransport = true
            }
        }
        await onStage(.resuming, result.targetVersion)

        // nudgeReconnectDuringUpdateRestart: the restart is expected, so retry every second instead of
        // climbing the backoff ladder. A restarted server may refuse the first credential.
        let nudge = Task {
            for await state in await supervisor.states() {
                guard state.phase == .backoff || state.phase == .blocked(.authentication) else { continue }
                try? await Task.sleep(for: nudgeInterval)
                if Task.isCancelled { return }
                await supervisor.retryNow()
            }
        }
        defer { nudge.cancel() }

        if result.needsDesktopCommit && commitLostTransport {
            let back = try? await withTimeout(resumeTimeout) { await supervisor.waitForConnection(after: beforeCommit) != nil }
            if back != true { throw Failure(ServerUpdateLogic.resumeTimeoutMessage(result.targetVersion)) }
        }

        guard result.needsDesktopCommit, let token = result.desktopUpdateToken else {
            let ready = try await nextReady(supervisor, result, timeout: resumeTimeout)
            if let failure = ServerUpdateLogic.failure(result, ready) { throw Failure(failure) }
            return result
        }
        // waitForDesktopUpdateTarget.
        for attempt in 1...3 {
            let ready = try await nextReady(supervisor, result, timeout: resumeTimeout)
            if ready.serverVersion == result.targetVersion { return result }
            if attempt == 3 { break }
            let generation = await supervisor.state.generation
            do {
                _ = try await supervisor.request("server.commitDesktopUpdate", payload: .object(["requestId": .string(token)]))
                break
            } catch let error as RPCClientError {
                guard isHandoffLoss(error) else { throw Failure(message(error)) }
                _ = try? await withTimeout(resumeTimeout) { await supervisor.waitForConnection(after: generation) != nil }
            }
        }
        throw Failure(ServerUpdateLogic.desktopNotInstalledMessage)
    }

    /// Asks the server to stage the update: the progress stream when it offers one, else the unary call,
    /// whose answer an older launcher-backed server may drop with the socket.
    private static func handoff(_ connection: RPCConnection, input: JSONValue, targetVersion: String, capabilities: ServerUpdateCapabilities,
                                onStage: @escaping @Sendable (ServerUpdateStage, String) async -> Void) async throws -> ServerSelfUpdateResult {
        do {
            if capabilities.progress {
                return try await streamUpdate(connection, input: input, targetVersion: targetVersion, onStage: onStage)
            }
            do {
                return try await connection.request("server.updateServer", payload: input).decode(as: ServerSelfUpdateResult.self)
            } catch let error as RPCClientError where isHandoffLoss(error) {
                switch capabilities.selfUpdate {
                case .bootService?, .respawn?: return ServerSelfUpdateResult(targetVersion: targetVersion, method: capabilities.selfUpdate!.rawValue)
                default: throw error
                }
            }
        } catch let error as RPCClientError {
            throw Failure(message(error))
        } catch is DecodingError {
            throw Failure("Server update failed.")
        }
    }

    /// `updateOutdatedHost` (client-runtime connection/outdatedHostUpdate.ts:49-205): a host on an older
    /// orchestration protocol never gets a normal session, so `connect` opens a bare socket that only
    /// carries the self-update calls, whose wire shape never changed. A desktop app's commit relaunches
    /// it, so a dropped socket is success. Then `descriptor` is asked every second, for 4 minutes, until
    /// the host answers on this client's protocol. Returns the version it came back on.
    public static func runOutdated(connect: @escaping @Sendable () async throws -> RPCConnection,
                                   descriptor: @escaping @Sendable () async throws -> EnvironmentDescriptor,
                                   environmentId: String, label: String, targetVersion: String,
                                   capabilities: ServerUpdateCapabilities, restartTimeout: Duration = ServerUpdateLogic.resumeTimeout,
                                   pollInterval: Duration = .seconds(1),
                                   onStage: @escaping @Sendable (ServerUpdateStage, String) async -> Void) async throws -> String {
        guard capabilities.canUpdateRemotely else { throw Failure("Update T3 Code on \(label) manually; it cannot update itself.") }
        await onStage(.downloading, targetVersion)
        let connection: RPCConnection
        do { connection = try await connect() } catch { throw Failure(String(describing: error)) }
        defer { Task { await connection.close(reason: "outdated host update finished") } }
        let input = ServerUpdateLogic.input(targetVersion: targetVersion, continueRunningThreads: false)
        let result = try await handoff(connection, input: input, targetVersion: targetVersion, capabilities: capabilities, onStage: onStage)
        if let token = result.desktopUpdateToken, result.method == "desktop-app" {
            do {
                _ = try await connection.request("server.commitDesktopUpdate", payload: .object(["requestId": .string(token)]))
            } catch let error as RPCClientError {
                guard isHandoffLoss(error) else { throw Failure(message(error)) }
            }
        }
        await onStage(.resuming, result.targetVersion)
        let resumed = try? await withTimeout(restartTimeout) { () -> EnvironmentDescriptor? in
            while !Task.isCancelled {
                if let d = try? await descriptor(), d.environmentId == environmentId, d.isCompatible { return d }
                try await Task.sleep(for: pollInterval)
            }
            return nil
        }
        try Task.checkCancellation()
        guard let resumed = resumed ?? nil else { throw Failure("\(label) did not come back on a compatible T3 Code version.") }
        return resumed.serverVersion
    }

    /// The socket `runOutdated` uses: a fresh ticket and the upgrade, without the descriptor's protocol
    /// check (a host from before protocol negotiation ignores the `orchestrationProtocol` parameter).
    public static func bareConnection(http: EnvironmentHTTP, identity: ClientIdentity, token: String) async throws -> RPCConnection {
        let ticket = try await http.webSocketTicket(token: token)
        let socket = try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity))
        let connection = RPCConnection(socket: socket)
        await connection.start()
        return connection
    }

    private static func streamUpdate(_ connection: RPCConnection, input: JSONValue, targetVersion: String,
                                     onStage: @escaping @Sendable (ServerUpdateStage, String) async -> Void) async throws -> ServerSelfUpdateResult {
        var terminal: ServerSelfUpdateResult?
        do {
            for try await value in await connection.stream("server.updateServerWithProgress", payload: input) {
                switch ServerSelfUpdateProgressEvent(value) {
                case .progress(let stage)?: await onStage(stage, targetVersion)
                case .complete(let result)?:
                    terminal = result
                    await onStage(.resuming, result.targetVersion)
                case nil: break
                }
            }
        } catch let error as RPCClientError {
            // resolveServerUpdateProgressResult: the socket may close right after `complete`.
            if let terminal, isHandoffLoss(error) { return terminal }
            throw error
        }
        guard let terminal else { throw Failure(ServerUpdateLogic.progressIncompleteMessage(targetVersion)) }
        return terminal
    }

    /// The first `ready` event that matches the update, on this or any later session.
    private static func nextReady(_ supervisor: ConnectionSupervisor, _ result: ServerSelfUpdateResult,
                                  timeout: Duration) async throws -> ServerLifecycleReady {
        let (stream, continuation) = AsyncStream<ServerLifecycleReady>.makeStream()
        let subscription = supervisor.subscribe("subscribeServerLifecycle", payload: { .object([:]) }) { event in
            guard case .value(let json) = event, let ready = ServerLifecycleReady(json),
                  ServerUpdateLogic.matchesResume(result, ready) else { return }
            continuation.yield(ready)
        }
        defer { subscription.cancel(); continuation.finish() }
        let ready = try? await withTimeout(timeout) {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        try Task.checkCancellation()
        guard let ready = ready ?? nil else { throw Failure(ServerUpdateLogic.resumeTimeoutMessage(result.targetVersion)) }
        return ready
    }

    /// `isLegacyUpdateHandoffLoss`: the socket went away, or only interrupts.
    static func isHandoffLoss(_ error: RPCClientError) -> Bool {
        switch error {
        case .transport: return true
        case .failure(let causes):
            return !causes.isEmpty && causes.allSatisfy { if case .interrupt = $0 { return true }; return false }
        default: return false
        }
    }

    /// `error.message` as T3 shows it: `ServerSelfUpdateError` prefixes its reason.
    static func message(_ error: RPCClientError) -> String {
        if let typed = error.typedError, typed.tag == "ServerSelfUpdateError", let reason = typed.fields["reason"]?.stringValue {
            return "Server update failed: \(reason)"
        }
        return error.description
    }
}
