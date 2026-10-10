import Foundation

/// A saved remote environment (client-runtime connection/catalog.ts `BearerConnectionRegistration`
/// with its `alternateRoutes`, direct routes only). Everything here is safe on disk; each route's
/// bearer token lives in the Keychain under the route's connection id.
public struct EnvironmentRegistration: Codable, Sendable, Equatable, Identifiable {
    /// The descriptor's `environmentId`, the environment's identity. Never a URL.
    public var environmentId: String
    /// The descriptor's `label`, shown in hover text and badges.
    public var label: String
    /// The preferred route: the server's HTTP origin.
    public var httpBaseURL: URL
    /// More routes to the same environment, in preference order after `httpBaseURL`.
    public var alternateRoutes: [URL]
    /// The descriptor's `platform.machine`, for the sidebar glyph. Nil means `server`.
    public var machine: String?
    /// False keeps the registration and its token but never connects (T3's `disabledEnvironmentIds`).
    public var enabled: Bool
    public var createdAt: Date

    public var id: String { environmentId }

    /// Every route, preferred first (`connectionRoutes`).
    public var routes: [URL] {
        get { [httpBaseURL] + alternateRoutes }
        set {
            guard let first = newValue.first else { return }
            httpBaseURL = first
            alternateRoutes = Array(newValue.dropFirst())
        }
    }

    public init(environmentId: String, label: String, httpBaseURL: URL, alternateRoutes: [URL] = [], machine: String? = nil,
                enabled: Bool = true, createdAt: Date = Date()) {
        self.environmentId = environmentId
        self.label = label
        self.httpBaseURL = httpBaseURL
        self.alternateRoutes = alternateRoutes
        self.machine = machine
        self.enabled = enabled
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case environmentId, label, httpBaseURL, alternateRoutes, machine, enabled, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try c.decode(String.self, forKey: .environmentId)
        label = try c.decode(String.self, forKey: .label)
        httpBaseURL = try c.decode(URL.self, forKey: .httpBaseURL)
        alternateRoutes = try c.decodeIfPresent([URL].self, forKey: .alternateRoutes) ?? []
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// The saved environments: one JSON document in Application Support (T3's `ConnectionCatalogDocument`,
/// docs/research/L-multi-environment.md 1.3) and one Keychain item per environment for its token.
/// The local environment is platform-managed like T3's primary and is never written here.
///
/// Calls block on file and Keychain I/O. A Keychain read can wait on an access prompt, so the app
/// calls this off the main thread.
public struct EnvironmentCatalog: Sendable {
    public let file: URL
    public let credentials: CredentialStore

    public static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "CandyWrapper/environments.json")
    }

    public init(file: URL = EnvironmentCatalog.defaultFile, credentials: CredentialStore = CredentialStore()) {
        self.file = file
        self.credentials = credentials
    }

    struct Document: Codable {
        static let currentVersion = 1
        var version = Document.currentVersion
        var environments: [EnvironmentRegistration] = []
    }

    /// Registrations in the order they were added. A missing file is an empty catalog. A document that
    /// doesn't decode is moved aside, as T3 copies a corrupt one to `document:corrupt:<timestamp>`.
    public func load() -> [EnvironmentRegistration] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let document = try? JSONDecoder.catalog.decode(Document.self, from: data), document.version <= Document.currentVersion {
            return document.environments
        }
        let aside = file.deletingLastPathComponent()
            .appending(path: file.deletingPathExtension().lastPathComponent + ".corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return []
    }

    /// Saves the token for the registration's route, then the registration, and returns what was saved.
    /// An id that is already saved keeps its place, switch and routes: the route joins them, or replaces
    /// the route with the same origin (registry.ts `register`, routes.ts `upsertRoute`).
    @discardableResult
    public func add(_ registration: EnvironmentRegistration, token: String) throws -> EnvironmentRegistration {
        let route = registration.httpBaseURL
        try credentials.save(token: token, environmentId: EnvironmentRoute.connectionId(environmentId: registration.environmentId, route))
        var all = load()
        var saved = registration
        if let i = all.firstIndex(where: { $0.environmentId == registration.environmentId }) {
            saved = all[i]
            saved.label = registration.label
            saved.machine = registration.machine ?? saved.machine
            saved.routes = EnvironmentRoute.upsert(route, into: saved.routes)
            all[i] = saved
        } else {
            all.append(saved)
        }
        try write(all)
        return saved
    }

    /// Forgets the registration and every route's token. There is no server-side logout (protocol.md 4.7).
    public func remove(environmentId: String) throws {
        let routes = load().first { $0.environmentId == environmentId }?.routes ?? []
        try write(load().filter { $0.environmentId != environmentId })
        for route in routes {
            try credentials.delete(environmentId: EnvironmentRoute.connectionId(environmentId: environmentId, route))
        }
    }

    /// Drops one route and its token (registry.ts `removeRoute`). The last route goes with the
    /// environment through `remove`, so this refuses it.
    @discardableResult
    public func removeRoute(_ route: URL, environmentId: String) throws -> EnvironmentRegistration? {
        var all = load()
        guard let i = all.firstIndex(where: { $0.environmentId == environmentId }), all[i].routes.count > 1 else { return nil }
        let origin = EnvironmentRoute.origin(route)
        all[i].routes = all[i].routes.filter { EnvironmentRoute.origin($0) != origin }
        try write(all)
        try credentials.delete(environmentId: EnvironmentRoute.connectionId(environmentId: environmentId, route))
        return all[i]
    }

    public func setEnabled(_ enabled: Bool, environmentId: String) throws {
        var all = load()
        guard let i = all.firstIndex(where: { $0.environmentId == environmentId }) else { return }
        all[i].enabled = enabled
        try write(all)
    }

    /// The token for `route`, or for the preferred route.
    public func token(environmentId: String, route: URL? = nil) throws -> String? {
        guard let route = route ?? load().first(where: { $0.environmentId == environmentId })?.httpBaseURL else { return nil }
        return try credentials.load(environmentId: EnvironmentRoute.connectionId(environmentId: environmentId, route))
    }

    private func write(_ environments: [EnvironmentRegistration]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.catalog.encode(Document(environments: environments))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension JSONEncoder {
    static var catalog: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var catalog: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
