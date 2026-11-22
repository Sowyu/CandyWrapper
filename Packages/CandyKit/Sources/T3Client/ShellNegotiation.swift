import Foundation
import T3Protocol

/// What one session's shell asks for: read from that session's config, or from none when the config never came.
/// Without config the shell asks for everything with no flags, as T3 does when its config read fails
/// (client-runtime state/shell.ts:638-645, 537-552): the full HTTP shell, then `subscribeShell` from its cursor.
public struct ShellNegotiation: Equatable, Sendable {
    public var omissions: ShellOmissions
    /// `requestCompletionMarker`, sent only when the config says the server answers it.
    public var completionMarker: Bool
    /// False when the shell went ahead without config.
    public var negotiated: Bool

    public init(omissions: ShellOmissions, completionMarker: Bool, negotiated: Bool) {
        self.omissions = omissions
        self.completionMarker = completionMarker
        self.negotiated = negotiated
    }

    public init(config: JSONValue?) {
        self.init(omissions: ShellOmissions(config: config ?? .null),
                  completionMarker: config?["shellResumeCompletionMarker"]?.boolValue == true,
                  negotiated: config != nil)
    }

    /// Whether a config snapshot on the session this prepared restarts the shell subscription. A negotiated session
    /// restarts when the flags change. One that went ahead without config already holds the complete shell, so a
    /// config that comes late is only recorded; the next session negotiates with its own.
    public func restarts(for config: JSONValue) -> Bool {
        guard negotiated else { return false }
        let next = ShellNegotiation(config: config)
        return next.omissions != omissions || next.completionMarker != completionMarker
    }

    /// Waits up to `deadline` for session `generation`'s config. Nil when the task was cancelled, the session ended or
    /// a newer one began meanwhile: nothing more belongs on that session.
    public static func read(feed: ServerConfigFeed, supervisor: ConnectionSupervisor, generation: Int,
                            deadline: Duration = ServerConfigFeed.shellConfigDeadline) async -> ShellNegotiation? {
        let config = await feed.initialConfig(generation: generation, within: deadline)
        guard !Task.isCancelled, await supervisor.state.generation == generation,
              await supervisor.currentConnection != nil else { return nil }
        return ShellNegotiation(config: config)
    }
}
