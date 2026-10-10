import Foundation
import Security

/// What CandyWrapper keeps of a Clerk sign-in. The client token is the only secret: it lets this
/// Mac mint session JWTs until the Clerk session ends. Session JWTs are never stored.
public struct ClerkStoredSession: Sendable, Equatable, Codable {
    /// The device token from the response `Authorization` header (clerk-ios
    /// `ClerkDeviceTokenResponseMiddleware.swift`).
    public var clientToken: String
    /// The Clerk client id, sent back as `x-clerk-client-id`.
    public var clientId: String?
    /// The active session (`created_session_id` of the finished sign-in). Nil before sign-in completes.
    public var sessionId: String?
    /// The Clerk user id, the same as the relay JWT `sub`.
    public var userId: String?
    /// The email the user signed in with, for display.
    public var identifier: String?

    public init(clientToken: String, clientId: String? = nil, sessionId: String? = nil,
                userId: String? = nil, identifier: String? = nil) {
        self.clientToken = clientToken
        self.clientId = clientId
        self.sessionId = sessionId
        self.userId = userId
        self.identifier = identifier
    }
}

/// Where `ClerkClient` keeps its `ClerkStoredSession`. The app uses `ClerkKeychainStore`; tests can
/// pass an in-memory one.
public protocol ClerkSessionStorage: Sendable {
    func load() throws -> ClerkStoredSession?
    func save(_ session: ClerkStoredSession) throws
    func delete() throws
}

/// One generic-password Keychain item, `AfterFirstUnlockThisDeviceOnly`, so it never syncs or
/// migrates to another Mac. Nothing else goes to disk.
public struct ClerkKeychainStore: ClerkSessionStorage {
    public let service: String
    public let account: String

    public init(service: String = "dev.candywrapper.t3.clerk-client", account: String = "t3-connect") {
        self.service = service
        self.account = account
    }

    public func load() throws -> ClerkStoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStore.KeychainError(status: status) }
        // An unreadable item is treated as signed out; the next save replaces it.
        return try? JSONDecoder().decode(ClerkStoredSession.self, from: data)
    }

    public func save(_ session: ClerkStoredSession) throws {
        let data = try JSONEncoder().encode(session)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(addQuery(data) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStore.KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStore.KeychainError(status: status) }
    }

    /// The attributes of a new item. `ThisDeviceOnly` and no `kSecAttrSynchronizable`: the item never
    /// syncs or moves to another Mac. The file-based login keychain an unsigned build uses does not
    /// report `kSecAttrAccessible` back, so tests check this dictionary instead.
    func addQuery(_ data: Data) -> [String: Any] {
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "T3 Connect sign-in"
        return add
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
