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
    /// The T3 Connect route, when the machine was added from the signed-in account (T3's
    /// `RelayConnectionRegistration`, or a relay route on a paired machine).
    public var relay: RelayLink?

    public var id: String { environmentId }

    /// The relay route's place in `routes`: the tunnel origin, last. It has no Keychain token;
    /// `T3ConnectAuthorizer` mints a DPoP token for each connect.
    public var relayRoute: URL? { relay.flatMap { URL(string: $0.endpoint.httpBaseUrl) } }

    public func isRelayRoute(_ url: URL) -> Bool {
        relayRoute.map { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(url) } ?? false
    }

    /// Reached only through T3 Connect. Sign-out removes these (routes.ts:364-370).
    public var isRelayOnly: Bool { relay != nil && routes.allSatisfy(isRelayRoute) }

    /// `connectionRouteLabel`: "T3 Connect" for the relay route, else the direct route's label.
    public func routeLabel(_ url: URL) -> String { isRelayRoute(url) ? "T3 Connect" : EnvironmentRoute.label(url) }

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

    enum CodingKeys: String, CodingKey { case environmentId, label, httpBaseURL, alternateRoutes, machine, enabled, createdAt, relay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try c.decode(String.self, forKey: .environmentId)
        label = try c.decode(String.self, forKey: .label)
        httpBaseURL = try c.decode(URL.self, forKey: .httpBaseURL)
        alternateRoutes = try c.decodeIfPresent([URL].self, forKey: .alternateRoutes) ?? []
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        relay = try c.decodeIfPresent(RelayLink.self, forKey: .relay)
    }
}

/// A machine's T3 Connect link: the account that listed it and the tunnel endpoint the relay reported.
/// Ids and URLs only; no token.
public struct RelayLink: Codable, Sendable, Equatable {
    /// The Clerk user id (the relay JWT `sub`). A different account signing in drops the route.
    public var accountId: String
    public var endpoint: RelayEndpoint

    public init(accountId: String, endpoint: RelayEndpoint) {
        self.accountId = accountId
        self.endpoint = endpoint
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

    private struct Header: Decodable { var version: Int }

    public enum CatalogError: Error, Equatable {
        /// A newer CandyWrapper wrote the document. This build reads it but never overwrites it.
        case newerVersion(Int)
    }

    /// Every mutation reads, changes and writes the document under this lock, so two at once (two quick
    /// "Add" clicks, sign-out racing a switch) can't lose a write. One lock for every catalog value.
    // ponytail: one process-wide lock for every file; per-file locks if tests or a second catalog contend
    private static let lock = NSLock()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    /// Registrations in the order they were added. A missing file is an empty catalog. A document that
    /// doesn't decode is moved aside, as T3 copies a corrupt one to `document:corrupt:<timestamp>`.
    /// A document from a newer version stays where it is (a downgrade must not wipe it).
    public func load() -> [EnvironmentRegistration] { locked { read() } }

    private func read() -> [EnvironmentRegistration] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let header = try? JSONDecoder.catalog.decode(Header.self, from: data), header.version > Document.currentVersion {
            return (try? JSONDecoder.catalog.decode(Document.self, from: data))?.environments ?? []
        }
        if let document = try? JSONDecoder.catalog.decode(Document.self, from: data) {
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
        try locked {
            let route = registration.httpBaseURL
            try credentials.save(token: token, environmentId: EnvironmentRoute.connectionId(environmentId: registration.environmentId, route))
            var all = read()
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
    }

    /// Saves a machine from the T3 Connect account (`RelayConnectionRegistration`). A machine already
    /// saved over direct routes keeps them and gains the relay route last, as T3 ranks relay last
    /// (routes.ts:110-117). New machines start switched on.
    @discardableResult
    public func addRelay(_ record: RelayEnvironmentRecord, accountId: String, machine: String? = nil) throws -> EnvironmentRegistration {
        try locked {
            guard let tunnel = URL(string: record.endpoint.httpBaseUrl), tunnel.host != nil else {
                throw RelayError(.invalidResponse("Relay returned an environment without an endpoint."), action: .connect)
            }
            var all = read()
            let link = RelayLink(accountId: accountId, endpoint: record.endpoint)
            var saved: EnvironmentRegistration
            if let i = all.firstIndex(where: { $0.environmentId == record.environmentId }) {
                saved = all[i]
                let direct = saved.routes.filter { !saved.isRelayRoute($0) && EnvironmentRoute.origin($0) != EnvironmentRoute.origin(tunnel) }
                saved.relay = link
                saved.routes = direct + [tunnel]
                saved.machine = machine ?? saved.machine
                all[i] = saved
            } else {
                saved = EnvironmentRegistration(environmentId: record.environmentId, label: record.label, httpBaseURL: tunnel, machine: machine)
                saved.relay = link
                all.append(saved)
            }
            try write(all)
            return saved
        }
    }

    /// Sign-out or an account switch (managedAuth.tsx:46-57): machines reached only through T3 Connect
    /// are forgotten, the rest lose their relay route. `keepingAccount` keeps the links of that account.
    /// Returns the removed ids and the registrations that changed.
    @discardableResult
    public func removeRelay(keepingAccount: String? = nil) throws -> (removed: [String], updated: [EnvironmentRegistration]) {
        try locked {
            var removed: [String] = [], updated: [EnvironmentRegistration] = []
            var kept: [EnvironmentRegistration] = []
            for var r in read() {
                guard let link = r.relay, link.accountId != keepingAccount else { kept.append(r); continue }
                if r.isRelayOnly {
                    removed.append(r.environmentId)
                    continue
                }
                r.routes = r.routes.filter { !r.isRelayRoute($0) }
                r.relay = nil
                updated.append(r)
                kept.append(r)
            }
            guard !removed.isEmpty || !updated.isEmpty else { return ([], []) }
            try write(kept)
            return (removed, updated)
        }
    }

    /// Forgets the registration and every route's token. There is no server-side logout (protocol.md 4.7).
    public func remove(environmentId: String) throws {
        try locked {
            let routes = read().first { $0.environmentId == environmentId }?.routes ?? []
            try write(read().filter { $0.environmentId != environmentId })
            for route in routes {
                try credentials.delete(environmentId: EnvironmentRoute.connectionId(environmentId: environmentId, route))
            }
        }
    }

    /// Drops one route and its token (registry.ts `removeRoute`). The last route goes with the
    /// environment through `remove`, so this refuses it.
    @discardableResult
    public func removeRoute(_ route: URL, environmentId: String) throws -> EnvironmentRegistration? {
        try locked {
            var all = read()
            guard let i = all.firstIndex(where: { $0.environmentId == environmentId }), all[i].routes.count > 1 else { return nil }
            let origin = EnvironmentRoute.origin(route)
            if all[i].isRelayRoute(route) { all[i].relay = nil }
            all[i].routes = all[i].routes.filter { EnvironmentRoute.origin($0) != origin }
            try write(all)
            try credentials.delete(environmentId: EnvironmentRoute.connectionId(environmentId: environmentId, route))
            return all[i]
        }
    }

    /// The dragged route order (registry.ts `reorderRoutes`). The same routes in a new order; anything
    /// else is refused. Tokens are keyed by route, so they stay.
    @discardableResult
    public func reorderRoutes(_ routes: [URL], environmentId: String) throws -> EnvironmentRegistration? {
        try locked {
            var all = read()
            guard let i = all.firstIndex(where: { $0.environmentId == environmentId }) else { return nil }
            let origins = { (urls: [URL]) in urls.map(EnvironmentRoute.origin) }
            guard Set(origins(routes)) == Set(origins(all[i].routes)), routes.count == all[i].routes.count else { return nil }
            all[i].routes = routes.compactMap { url in all[i].routes.first { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(url) } }
            try write(all)
            return all[i]
        }
    }

    public func setEnabled(_ enabled: Bool, environmentId: String) throws {
        try locked {
            var all = read()
            guard let i = all.firstIndex(where: { $0.environmentId == environmentId }) else { return }
            all[i].enabled = enabled
            try write(all)
        }
    }

    /// The token for `route`, or for the preferred route.
    public func token(environmentId: String, route: URL? = nil) throws -> String? {
        guard let route = route ?? load().first(where: { $0.environmentId == environmentId })?.httpBaseURL else { return nil }
        return try credentials.load(environmentId: EnvironmentRoute.connectionId(environmentId: environmentId, route))
    }

    private func write(_ environments: [EnvironmentRegistration]) throws {
        if let data = try? Data(contentsOf: file), let header = try? JSONDecoder.catalog.decode(Header.self, from: data),
           header.version > Document.currentVersion {
            throw CatalogError.newerVersion(header.version)
        }
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
