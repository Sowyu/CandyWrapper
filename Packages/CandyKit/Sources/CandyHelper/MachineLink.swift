import Foundation
import T3Protocol
import T3Store
import T3Transport

/// One machine's connection: it signs in with the helper's bearer token, subscribes to the shell (and, on the home
/// machine, the scheduled tasks) and reconnects on its own. Everything it learns comes out of `events`, in order.
actor MachineLink {
    enum Event: Sendable {
        /// A new connection; `generation` tells its shell states apart from an older connection's.
        case connected(generation: Int, config: ServerProviderConfig?, route: URL)
        case shell(generation: Int, ShellSnapshot)
        case tasks([ScheduledTask])
        case disconnected(String)
        /// The machine refused the token: revoked, expired or never valid.
        case rejected(String)
    }

    nonisolated let machine: HelperMachine
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let token: String
    private let identity: ClientIdentity
    private var connection: RPCConnection?
    private var generation = 0

    // ponytail: a 45 s ping per machine finds a socket that died without a close (a tunnel or NAT dropping it); lengthen it if it ever shows in the energy numbers
    static let pingInterval: Duration = .seconds(45)

    init(machine: HelperMachine, token: String, identity: ClientIdentity) {
        self.machine = machine
        self.token = token
        self.identity = identity
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Unary call on the live connection.
    func request(_ method: String, _ payload: JSONValue = .object([:])) async throws -> JSONValue {
        guard let connection else { throw HelperError("\(machine.label) isn't connected right now") }
        return try await connection.request(method, payload: payload)
    }

    /// Connects, and connects again whenever the connection ends, until the task is cancelled.
    func run() async {
        var delay: Double = 1
        while !Task.isCancelled {
            do {
                try await session()
                delay = 1
            } catch let error as Rejected {
                continuation.yield(.rejected(error.reason))
                // A revoked token stays revoked; a renewal restarts the helper with a new one.
                delay = 300
            } catch {
                continuation.yield(.disconnected(Self.describe(error)))
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
        continuation.finish()
    }

    private struct Rejected: Error { var reason: String }

    /// Set once the loopback refused this token: from then on the URL CandyWrapper paired at.
    private var loopbackRefused = false

    private func session() async throws {
        var route = try await base()
        var http = helperHTTP(route)
        let ticket: WebSocketTicket
        do {
            ticket = try await http.webSocketTicket(token: token)
        } catch EnvironmentHTTPError.status(let code, let body) where (code == 401 || code == 403) && route != machine.url {
            // The loopback answered as this machine but isn't the server that issued the token, like an old server on
            // the same T3 home. The paired URL decides.
            log("\(machine.label): \(hostPort(route)) refused the token (\(Self.statusText(code, body))); using \(hostPort(machine.url)) instead")
            loopbackRefused = true
            route = machine.url
            http = helperHTTP(route)
            ticket = try await refusedAs(route) { try await http.webSocketTicket(token: self.token) }
        } catch EnvironmentHTTPError.status(let code, let body) where code == 401 || code == 403 {
            throw Rejected(reason: "\(Self.statusText(code, body)) from \(hostPort(route))")
        }
        let socket = try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity))
        let conn = RPCConnection(socket: socket)
        await conn.start()
        connection = conn
        generation += 1
        let gen = generation
        defer { connection = nil }
        let config = try? await conn.request("server.getConfig").decode(as: ServerProviderConfig.self)
        continuation.yield(.connected(generation: gen, config: config, route: route))
        let continuation = self.continuation
        let home = machine.isHome
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let store = ShellStore(onChange: {})
                    for try await value in await conn.stream("orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)])) {
                        guard let item = try? value.decode(as: ShellStreamItem.self) else { continue }
                        await store.apply([item])
                        if let snapshot = await store.snapshot { continuation.yield(.shell(generation: gen, snapshot)) }
                    }
                    throw HelperError("the shell stream ended")
                }
                if home {
                    group.addTask {
                        for try await value in await conn.stream("scheduledTasks.subscribe") {
                            continuation.yield(.tasks(ScheduledTask.list(value)))
                        }
                        throw HelperError("the task stream ended")
                    }
                }
                group.addTask {
                    while true {
                        try await Task.sleep(for: Self.pingInterval)
                        try await conn.ping(timeout: .seconds(15))
                    }
                }
                // Whichever ends first ends the connection.
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await conn.close()
            throw error
        }
        await conn.close()
    }

    /// The loopback address when the home server answers there as itself, else the URL CandyWrapper uses. The token goes
    /// only to a server whose public descriptor names this machine, as T3 checks a learned route (service.ts:142-181).
    private func base() async throws -> URL {
        if let loopback = machine.loopbackURL, !loopbackRefused,
           let d = try? await helperHTTP(loopback, timeout: 3).descriptor(), d.environmentId == machine.id { return loopback }
        let descriptor = try await helperHTTP(machine.url).descriptor()
        guard descriptor.environmentId == machine.id else {
            throw HelperError("\(machine.url.host() ?? "the address") now answers as another machine (\(descriptor.label))")
        }
        return machine.url
    }

    /// Runs a request whose 401 or 403 means the token is refused.
    private func refusedAs<T>(_ route: URL, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch EnvironmentHTTPError.status(let code, let b) where code == 401 || code == 403 {
            throw Rejected(reason: "\(Self.statusText(code, b)) from \(hostPort(route))")
        }
    }

    /// "HTTP 401 EnvironmentAuthInvalidError invalid_credential: …", or "HTTP 401 with no body": what T3 said, redacted.
    static func statusText(_ code: Int, _ body: EnvironmentHTTPErrorBody?) -> String {
        guard let body else { return "HTTP \(code) with no body" }
        return redact("HTTP \(code) \(body.tag)" + (body.reason.map { " \($0)" } ?? "") + (body.message.map { ": \($0)" } ?? "")
                      + (body.requiredScope.map { " (needs \($0))" } ?? ""))
    }

    /// For logs and results, redacted.
    static func describe(_ error: Error) -> String {
        if let e = error as? RPCClientError { return redact(e.typedError?.message ?? e.description) }
        if case EnvironmentHTTPError.status(let code, let body) = error { return statusText(code, body) }
        if let e = error as? LocalizedError, let d = e.errorDescription { return redact(d) }
        return redact("\(error)")
    }
}
