import Foundation

// Server self-update: the wire types of `server.updateServer`, `server.updateServerWithProgress`
// and `server.commitDesktopUpdate`, the capabilities that pick the path, and the checks on the
// `ready` lifecycle event that prove the restart (contracts server.ts:949-1003, environment.ts:72-96,
// 182-211; client-runtime state/server.ts:60-180, 280-310).

/// `ServerSelfUpdateCapability`: what update path a server offers. Unknown strings stay so a newer
/// server can't break decoding; the client treats them as no remote update.
public enum ServerSelfUpdateCapability: Equatable, Sendable {
    case bootService, respawn, desktopManaged, other(String)
    public init(_ raw: String) {
        switch raw {
        case "boot-service": self = .bootService
        case "respawn": self = .respawn
        case "desktop-managed": self = .desktopManaged
        default: self = .other(raw)
        }
    }
    public var rawValue: String {
        switch self {
        case .bootService: "boot-service"
        case .respawn: "respawn"
        case .desktopManaged: "desktop-managed"
        case .other(let raw): raw
        }
    }
}

/// The update-related part of an environment's capabilities (environment.ts:182-211).
public struct ServerUpdateCapabilities: Equatable, Sendable {
    /// Nil when the server must be relaunched by hand.
    public var selfUpdate: ServerSelfUpdateCapability?
    /// `ServerInstallation`, kept raw for the manual command.
    public var installation: JSONValue?
    public var progress: Bool
    public var desktopAppUpdate: Bool
    public var threadContinuation: Bool

    public init(selfUpdate: ServerSelfUpdateCapability? = nil, installation: JSONValue? = nil, progress: Bool = false,
                desktopAppUpdate: Bool = false, threadContinuation: Bool = false) {
        self.selfUpdate = selfUpdate; self.installation = installation; self.progress = progress
        self.desktopAppUpdate = desktopAppUpdate; self.threadContinuation = threadContinuation
    }

    public init(_ capabilities: [String: JSONValue]) {
        func flag(_ key: String) -> Bool { if case .bool(true)? = capabilities[key] { return true }; return false }
        self.init(selfUpdate: capabilities["serverSelfUpdate"]?.stringValue.map(ServerSelfUpdateCapability.init),
                  installation: capabilities["serverInstallation"].flatMap { $0 == .null ? nil : $0 },
                  progress: flag("serverSelfUpdateProgress"), desktopAppUpdate: flag("desktopAppUpdate"),
                  threadContinuation: flag("serverUpdateThreadContinuation"))
    }

    /// Whether the client can run the update over RPC: a launcher-backed server, or a desktop app that
    /// takes the remote trigger (ServerUpdateAction.tsx:125-129, 285-291).
    public var canUpdateRemotely: Bool {
        switch selfUpdate {
        case .bootService?, .respawn?: true
        case .desktopManaged?: desktopAppUpdate
        default: false
        }
    }
}

/// `ServerSelfUpdateResult`: the update is staged and the server is about to restart.
public struct ServerSelfUpdateResult: Codable, Equatable, Sendable {
    public var targetVersion: String
    /// `boot-service`, `respawn` or `desktop-app`.
    public var method: String
    public var updateId: String?
    public var desktopUpdateToken: String?
    public init(targetVersion: String, method: String, updateId: String? = nil, desktopUpdateToken: String? = nil) {
        self.targetVersion = targetVersion; self.method = method; self.updateId = updateId; self.desktopUpdateToken = desktopUpdateToken
    }
    /// A desktop app that staged the update and waits for `server.commitDesktopUpdate`.
    public var needsDesktopCommit: Bool { method == "desktop-app" && desktopUpdateToken != nil }
}

/// One `server.updateServerWithProgress` value.
public enum ServerSelfUpdateProgressEvent: Equatable, Sendable {
    case progress(ServerUpdateStage)
    case complete(ServerSelfUpdateResult)

    public init?(_ json: JSONValue) {
        switch json["type"]?.stringValue {
        case "progress":
            guard let stage = json["stage"]?.stringValue.flatMap(ServerUpdateStage.init(rawValue:)) else { return nil }
            self = .progress(stage)
        case "complete":
            guard let result = try? json["result"]?.decode(as: ServerSelfUpdateResult.self) else { return nil }
            self = .complete(result)
        default: return nil
        }
    }
}

/// `ServerSelfUpdateOutcome`, recorded by the service launcher for one update.
public struct ServerSelfUpdateOutcome: Codable, Equatable, Sendable {
    public var id: String
    public var fromVersion: String
    public var targetVersion: String
    /// `committed`, `rolled-back` or `failed`.
    public var status: String
    public var reason: String?
    public init(id: String, fromVersion: String, targetVersion: String, status: String, reason: String? = nil) {
        self.id = id; self.fromVersion = fromVersion; self.targetVersion = targetVersion; self.status = status; self.reason = reason
    }
}

/// A `ready` event of `subscribeServerLifecycle`: the version that came up, and the launcher's outcome.
public struct ServerLifecycleReady: Equatable, Sendable {
    public var serverVersion: String
    public var updateOutcome: ServerSelfUpdateOutcome?

    public init(serverVersion: String, updateOutcome: ServerSelfUpdateOutcome? = nil) {
        self.serverVersion = serverVersion; self.updateOutcome = updateOutcome
    }

    public init?(_ event: JSONValue) {
        guard event["type"]?.stringValue == "ready",
              let version = event["payload"]?["environment"]?["serverVersion"]?.stringValue else { return nil }
        serverVersion = version
        updateOutcome = try? event["payload"]?["updateOutcome"]?.decode(as: ServerSelfUpdateOutcome.self)
    }
}

public enum ServerUpdateStage: String, Equatable, Sendable { case downloading, installing, resuming }

/// One environment's update (state/server.ts:62-76). A failure keeps its stage and versions.
public enum ServerUpdateState: Equatable, Sendable {
    case idle
    case running(stage: ServerUpdateStage, fromVersion: String, targetVersion: String)
    case failed(stage: ServerUpdateStage, fromVersion: String, targetVersion: String, message: String)

    public var isRunning: Bool { if case .running = self { return true }; return false }
    public var isFailed: Bool { if case .failed = self { return true }; return false }

    /// `serverUpdateStateForServerVersion`: a failure clears once the server runs another version.
    public func forServerVersion(_ version: String?) -> ServerUpdateState {
        guard case .failed(_, let from, _, _) = self, let version, version != from else { return self }
        return .idle
    }
}

/// The update rules that don't need a socket (state/server.ts:130-178).
public enum ServerUpdateLogic {
    /// Covers the launcher's 120 s trial and a restart of the old version after a rollback.
    public static let resumeTimeout: Duration = .seconds(240)

    /// `server.updateServer` input: an exact version, and the opt-in to continue running turns.
    public static func input(targetVersion: String, continueRunningThreads: Bool) -> JSONValue {
        var object: [String: JSONValue] = ["targetVersion": .string(targetVersion)]
        if continueRunningThreads { object["continueRunningThreads"] = .bool(true) }
        return .object(object)
    }

    /// `matchesServerUpdateReadyEvent`.
    public static func matchesReady(_ result: ServerSelfUpdateResult, _ ready: ServerLifecycleReady) -> Bool {
        guard let id = result.updateId else { return ready.serverVersion == result.targetVersion }
        return ready.updateOutcome?.id == id
    }

    /// `matchesServerUpdateResumeEvent`: a desktop commit takes any ready event and checks its version after.
    public static func matchesResume(_ result: ServerSelfUpdateResult, _ ready: ServerLifecycleReady) -> Bool {
        result.needsDesktopCommit || matchesReady(result, ready)
    }

    /// `validateServerUpdateReadyEvent`: nil when the launcher committed the requested version, else
    /// the message to show.
    public static func failure(_ result: ServerSelfUpdateResult, _ ready: ServerLifecycleReady) -> String? {
        guard let id = result.updateId else { return nil }
        let outcome = ready.updateOutcome
        if outcome?.id == id, outcome?.status == "committed", outcome?.targetVersion == result.targetVersion,
           ready.serverVersion == result.targetVersion { return nil }
        return outcome?.reason ?? "The service launcher resumed without committing the requested server version."
    }

    public static func resumeTimeoutMessage(_ targetVersion: String) -> String { "The server did not resume on t3@\(targetVersion)." }
    public static func progressIncompleteMessage(_ targetVersion: String) -> String {
        "The t3@\(targetVersion) update ended before the server accepted the restart."
    }
    public static let desktopNotInstalledMessage = "The desktop app resumed without installing the prepared update."
}
