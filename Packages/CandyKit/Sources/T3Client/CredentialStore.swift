import Foundation
import os
import Security

/// Bearer tokens in the macOS Keychain, one generic password per environment id.
/// Tokens never go to disk elsewhere, and nothing here logs them.
public struct CredentialStore: Sendable {
    public let service: String
    /// Tests only: tokens in this dictionary instead of the Keychain.
    private let memory: OSAllocatedUnfairLock<[String: String]>?

    public init(service: String = "dev.candywrapper.t3.environment-token") {
        self.service = service
        memory = nil
    }

    /// A store that never touches the Keychain, for tests of the code around it.
    static func inMemory() -> CredentialStore { CredentialStore(memory: OSAllocatedUnfairLock(initialState: [:])) }

    private init(memory: OSAllocatedUnfairLock<[String: String]>) {
        service = "in-memory"
        self.memory = memory
    }

    public struct KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    public func save(token: String, environmentId: String) throws {
        if let memory { return memory.withLock { $0[environmentId] = token } }
        let query = baseQuery(environmentId)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(addQuery(token, environmentId: environmentId) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func load(environmentId: String) throws -> String? {
        if let memory { return memory.withLock { $0[environmentId] } }
        var query = baseQuery(environmentId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    /// "Forget this environment". There is no server-side logout (protocol.md 4.7).
    public func delete(environmentId: String) throws {
        if let memory { return memory.withLock { $0[environmentId] = nil } }
        let status = SecItemDelete(baseQuery(environmentId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// The attributes of a new item: `ThisDeviceOnly`, like the Clerk session and the DPoP key, so a token
    /// never syncs or moves to another Mac. Tests check this dictionary, as the login keychain doesn't
    /// report `kSecAttrAccessible` back.
    // ponytail: the file-based login keychain ignores the accessibility class; it applies only in the data
    // protection keychain, which needs a signed build with an application identifier (milestone 9)
    func addQuery(_ token: String, environmentId: String) -> [String: Any] {
        var add = baseQuery(environmentId)
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "T3 Code environment token"
        return add
    }

    private func baseQuery(_ environmentId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentId,
        ]
    }
}
