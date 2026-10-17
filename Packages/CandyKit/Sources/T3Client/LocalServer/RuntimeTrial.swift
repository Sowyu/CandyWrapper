import Foundation

/// A downloaded runtime becomes active only for a backed-up trial. The caller owns the process;
/// `startAndConnect` must complete an authenticated RPC before the backup can be discarded.
public enum RuntimeTrial {
    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public static func apply(store: RuntimeStore, home: URL, target: String, backupDirectory: URL,
                             stop: @Sendable () async -> Void,
                             startAndConnect: @Sendable () async throws -> Void,
                             unowned: @Sendable () -> Bool) async throws {
        guard store.binary(target) != nil else { throw Failure("Download the server update before restarting.") }
        let database = DatabaseBackup.database(home: home)
        if let blocker = DatabaseBackup.blocker(database: database, root: backupDirectory.deletingLastPathComponent()) {
            throw Failure(blocker)
        }
        let previous = store.state().active
        await stop()
        guard unowned() else { throw Failure("Another server owns this data. The update was not applied.") }
        guard let backup = try DatabaseBackup.make(database: database, in: backupDirectory, includeMissing: true) else {
            throw Failure("Could not back up the database. The update was not applied.")
        }
        try backup.armRestore(previous: previous)
        do {
            try store.activate(target)
            try await startAndConnect()
            try backup.discard()
        } catch {
            await stop()
            guard unowned() else {
                throw Failure("The new server could not connect, and another server now owns the data. The backup is kept at \(backupDirectory.path).")
            }
            do {
                try backup.restore(previous: previous)
                if let previous { try store.activate(previous) } else { try store.deactivate() }
                try backup.discard()
            } catch {
                throw Failure("Could not restore the database after the server update. The backup is kept at \(backupDirectory.path): \(error.localizedDescription)")
            }
            let reason = (error as? LocalServerLaunchError)?.description ?? error.localizedDescription
            throw Failure("T3 Code \(target) did not start or connect: \(reason) CandyWrapper restored its database and went back to \(previous ?? "the previous runtime").")
        }
    }

    /// Read one config value through the same authenticated RPC transport as the app. A descriptor
    /// alone is insufficient: a server can answer HTTP while its RPC layer fails during startup.
    public static func verify(_ server: LaunchedLocalServer, identity: ClientIdentity) async throws {
        guard server.descriptor.isCompatible else {
            throw Failure("The updated server uses an unsupported orchestration protocol (\(server.descriptor.protocolVersion)).")
        }
        let http = EnvironmentHTTP(baseURL: server.origin)
        let ticket = try await http.webSocketTicket(token: server.accessToken)
        let socket = try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity))
        let connection = RPCConnection(socket: socket)
        await connection.start()
        do {
            try await withTimeout(.seconds(30), error: Failure("The updated server did not answer an RPC.")) {
                _ = try await connection.request("server.getConfig")
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
