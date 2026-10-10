import CryptoKit
import Foundation
import Security

/// One DPoP proof key per installation, shared by the relay and every environment, like T3's
/// `t3code.cloud.dpop-proof-key` (apps/mobile/src/features/cloud/dpop.ts:89) and the web client's
/// IndexedDB key (apps/web/src/cloud/dpop.ts:24-27). The minted environment credential is bound to
/// its thumbprint, so the same key must sign the relay connect and the `/oauth/token` exchange.
///
/// With a Secure Enclave the key is an enclave key and the Keychain item holds its wrapped blob,
/// which only this Mac's enclave can use. Without one, the Keychain item holds a software key.
/// Either way the item is `ThisDeviceOnly` and nothing but the public JWK leaves it.
public struct DPoPKeyStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "dev.candywrapper.t3.dpop-proof-key", account: String = "installation") {
        self.service = service
        self.account = account
    }

    private static let enclaveTag: UInt8 = 1
    private static let softwareTag: UInt8 = 2

    /// The stored key, or a new one saved to the Keychain.
    public func loadOrCreate() throws -> any DPoPSigningKey {
        if let key = try load() { return key }
        let key: any DPoPSigningKey
        let blob: Data
        if SecureEnclave.isAvailable {
            let enclaveKey = try SecureEnclave.P256.Signing.PrivateKey()
            key = try SecureEnclaveDPoPKey(enclaveKey)
            blob = Data([Self.enclaveTag]) + enclaveKey.dataRepresentation
        } else {
            let softwareKey = P256.Signing.PrivateKey()
            key = try SoftwareDPoPKey(softwareKey)
            blob = Data([Self.softwareTag]) + softwareKey.rawRepresentation
        }
        try save(blob)
        return key
    }

    public func load() throws -> (any DPoPSigningKey)? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let tag = data.first else {
            throw CredentialStore.KeychainError(status: status)
        }
        let body = data.dropFirst()
        switch tag {
        case Self.enclaveTag: return try SecureEnclaveDPoPKey(SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body))
        case Self.softwareTag: return try SoftwareDPoPKey(P256.Signing.PrivateKey(rawRepresentation: body))
        default: throw DPoPError.invalidKey
        }
    }

    /// Drops the key. Every relay and environment token bound to it stops working.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStore.KeychainError(status: status) }
    }

    private func save(_ blob: Data) throws {
        var add = baseQuery
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "T3 Connect proof key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStore.KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
