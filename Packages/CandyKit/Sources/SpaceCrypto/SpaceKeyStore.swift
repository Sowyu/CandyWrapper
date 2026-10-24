import Foundation
import os
import Security

/// The Space key in the file-based login Keychain, one generic password per Space id, with an ACL that
/// trusts only the app that saved it. Another app, even one signed by the same team, gets
/// errSecAuthFailed or a prompt for the user (the space-spike branch,
/// docs/research/space-spikes-2026-10-24.md). The stronger
/// data protection Keychain needs a provisioning profile the release signing doesn't have.
/// Call it off the main thread, since a read can wait on that prompt.
///
/// Unit tests use `inMemory()`. A debug app uses its own bundle-specific service and can reopen the item
/// across launches of the same binary. Ad hoc rebuilds may need access approved again.
/// `scripts/space-keychain-test` checks updates in release-style signed builds.
public struct SpaceKeyStore: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case keychain(OSStatus)
        /// The Keychain already holds another key for this Space. Delete it first on purpose; save never replaces one.
        case differentKeyStored
        case corruptItem
    }

    public let service: String
    private let memory: OSAllocatedUnfairLock<[String: SpaceKey]>?

    /// The service names the bundle id, so test builds never see the real app's key.
    public init(service: String = "\(Bundle.main.bundleIdentifier ?? "dev.candywrapper.app").space-key") {
        self.service = service
        memory = nil
    }

    public static func inMemory() -> SpaceKeyStore { SpaceKeyStore(memory: OSAllocatedUnfairLock(initialState: [:])) }

    private init(memory: OSAllocatedUnfairLock<[String: SpaceKey]>) {
        service = "in-memory"
        self.memory = memory
    }

    public func save(_ key: SpaceKey, spaceId: String) throws {
        if let memory {
            return try memory.withLock {
                if let stored = $0[spaceId], stored != key { throw Failure.differentKeyStored }
                $0[spaceId] = key
            }
        }
        var item = query(spaceId)
        item[kSecAttrAccess] = try access()
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel] = "CandyWrapper Space key"
        var raw = key.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0..<raw.count) }
        item[kSecValueData] = raw
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try load(spaceId: spaceId) == key else { throw Failure.differentKeyStored }
            return
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public func load(spaceId: String) throws -> SpaceKey? {
        if let memory { return memory.withLock { $0[spaceId] } }
        var q = query(spaceId)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, var data = result as? Data else { throw Failure.keychain(status) }
        defer { data.resetBytes(in: 0..<data.count) }
        guard let key = try? SpaceKey(rawBytes: data) else { throw Failure.corruptItem }
        return key
    }

    /// "Remove Space from this Mac". Without another device or the recovery key the Space is gone.
    public func delete(spaceId: String) throws {
        if let memory { return memory.withLock { $0[spaceId] = nil } }
        let status = SecItemDelete(query(spaceId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    /// Always the full service and account, never an unqualified generic-password query.
    private func query(_ spaceId: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: spaceId,
         kSecAttrSynchronizable: false]
    }

    /// An ACL whose only trusted application is this process's signed app. The login Keychain records its
    /// designated requirement, so updates signed with the same identity keep access.
    /// SecTrustedApplication and SecAccess are deprecated with no replacement for login Keychain ACLs, hence
    /// the two warnings.
    private func access() throws -> SecAccess {
        var app: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &app)
        guard status == errSecSuccess, let app else { throw Failure.keychain(status) }
        var access: SecAccess?
        status = SecAccessCreate("CandyWrapper Space key" as CFString, [app] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw Failure.keychain(status) }
        return access
    }
}
