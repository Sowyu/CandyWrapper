import Foundation
import T3Protocol

/// "Allow remote access". The user's explicit choice wins; until they make one, it follows
/// whether T3 Connect is linked on this machine, cached from the last server we reached.
/// When on, the lifecycle never idle-stops the server.
public struct RemoteAccessSetting: Sendable {
    public let suiteName: String?
    private static let choiceKey = "localServer.remoteAccess.userChoice"
    private static let linkedKey = "localServer.remoteAccess.connectLinked"

    /// Nil uses the standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public var isOn: Bool { userChoice ?? connectLinked ?? false }

    public var userChoice: Bool? {
        get { defaults.object(forKey: Self.choiceKey) as? Bool }
        nonmutating set { defaults.set(newValue, forKey: Self.choiceKey) }
    }

    /// Cached `linked` from `/api/connect/link-state`.
    public var connectLinked: Bool? {
        get { defaults.object(forKey: Self.linkedKey) as? Bool }
        nonmutating set { defaults.set(newValue, forKey: Self.linkedKey) }
    }

    /// `GET /api/connect/link-state` (needs `relay:read`), then caches `linked`. Returns the
    /// resulting setting.
    @discardableResult
    public func refresh(http: EnvironmentHTTP, token: String) async throws -> Bool {
        struct LinkState: Decodable { var linked: Bool }
        connectLinked = try await http.get("api/connect/link-state", token: token, as: LinkState.self).linked
        return isOn
    }
}
