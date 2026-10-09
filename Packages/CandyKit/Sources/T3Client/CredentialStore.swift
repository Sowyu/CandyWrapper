import Foundation
import Security

/// Bearer tokens in the macOS Keychain, one generic password per environment id.
/// Tokens never go to disk elsewhere, and nothing here logs them.
public struct CredentialStore: Sendable {
    public let service: String

    public init(service: String = "dev.candywrapper.t3.environment-token") {
        self.service = service
    }

    public struct KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    public func save(token: String, environmentId: String) throws {
        let query = baseQuery(environmentId)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "T3 Code environment token"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func load(environmentId: String) throws -> String? {
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
        let status = SecItemDelete(baseQuery(environmentId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ environmentId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentId,
        ]
    }
}
