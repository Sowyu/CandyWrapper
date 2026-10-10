import Foundation

/// A saved remote environment (client-runtime connection/catalog.ts `BearerConnectionRegistration`,
/// reduced to one direct route). Everything here is safe on disk; the bearer token lives in the Keychain.
public struct EnvironmentRegistration: Codable, Sendable, Equatable, Identifiable {
    /// The descriptor's `environmentId`, the environment's identity. Never a URL.
    public var environmentId: String
    /// The descriptor's `label`, shown in hover text and badges.
    public var label: String
    /// The route: the server's HTTP origin.
    public var httpBaseURL: URL
    /// The descriptor's `platform.machine`, for the sidebar glyph. Nil means `server`.
    public var machine: String?
    /// False keeps the registration and its token but never connects (T3's `disabledEnvironmentIds`).
    public var enabled: Bool
    public var createdAt: Date

    public var id: String { environmentId }

    public init(environmentId: String, label: String, httpBaseURL: URL, machine: String? = nil, enabled: Bool = true, createdAt: Date = Date()) {
        self.environmentId = environmentId
        self.label = label
        self.httpBaseURL = httpBaseURL
        self.machine = machine
        self.enabled = enabled
        self.createdAt = createdAt
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

    /// Saves the token, then the registration. Adding an id that is already saved replaces it in place.
    public func add(_ registration: EnvironmentRegistration, token: String) throws {
        try credentials.save(token: token, environmentId: registration.environmentId)
        var all = load()
        if let i = all.firstIndex(where: { $0.environmentId == registration.environmentId }) {
            all[i] = registration
        } else {
            all.append(registration)
        }
        try write(all)
    }

    /// Forgets the registration and its token. There is no server-side logout (protocol.md 4.7).
    public func remove(environmentId: String) throws {
        try write(load().filter { $0.environmentId != environmentId })
        try credentials.delete(environmentId: environmentId)
    }

    public func setEnabled(_ enabled: Bool, environmentId: String) throws {
        var all = load()
        guard let i = all.firstIndex(where: { $0.environmentId == environmentId }) else { return }
        all[i].enabled = enabled
        try write(all)
    }

    public func token(environmentId: String) throws -> String? {
        try credentials.load(environmentId: environmentId)
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
