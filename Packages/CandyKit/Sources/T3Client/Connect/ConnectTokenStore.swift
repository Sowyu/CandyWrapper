import Foundation

/// T3 Connect environment tokens kept between launches, as T3 keeps `remoteDpopTokens` in its connection
/// catalog (client-runtime/src/authorization/tokenStore.ts:10-20, apps/web/src/connection/storage.ts:851-869).
/// One Keychain item per account and environment, through `CredentialStore` with its `ThisDeviceOnly` class,
/// in a service of its own so one attribute query lists them. Nothing here logs a token.
///
/// Every call runs in order on one serial queue, off the caller's thread: a save queued before a sign-out's
/// delete never outlives it, and a Keychain prompt blocks only this queue.
public struct ConnectTokenStore: Sendable {
    let credentials: CredentialStore
    private static let queue = DispatchQueue(label: "dev.candywrapper.connect-token-store", qos: .userInitiated)

    public init(credentials: CredentialStore = CredentialStore(service: "dev.candywrapper.t3.connect-environment-token",
                                                                label: "T3 Connect environment token")) {
        self.credentials = credentials
    }

    /// Tests: items in memory, never the Keychain.
    static func inMemory() -> ConnectTokenStore { ConnectTokenStore(credentials: .inMemory()) }

    /// `RemoteDpopAccessToken`'s fields (tokenStore.ts:10-20). The descriptor isn't kept: a reused token reads
    /// it beside the ticket, as T3 does (service.ts:711-724).
    struct Stored: Codable, Equatable {
        var environmentId: String
        var accountId: String
        var label: String
        var endpoint: RelayEndpoint
        var accessToken: String
        var expiresAtEpochMs: Double
        var dpopThumbprint: String
    }

    static func key(accountId: String, environmentId: String) -> String { "\(accountId)/\(environmentId)" }

    /// Splits an item's account name at the first `/`. Clerk user ids have none.
    static func parse(_ key: String) -> (accountId: String, environmentId: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    /// The stored token for this account and environment, or nil. An item that doesn't decode, or names another
    /// account or environment than its key, is deleted. A Keychain error (a refused prompt) returns nil and keeps it.
    /// A cancelled caller gets nil at once: a read waiting on a Keychain prompt never holds up the supervisor's timeout.
    public func load(accountId: String, environmentId: String) async -> T3ConnectToken? {
        await run(orOnCancel: nil) { () -> T3ConnectToken? in
            let key = Self.key(accountId: accountId, environmentId: environmentId)
            guard let raw = try? credentials.load(environmentId: key) else { return nil }
            guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8)),
                  stored.accountId == accountId, stored.environmentId == environmentId else {
                try? credentials.delete(environmentId: key)
                return nil
            }
            return T3ConnectToken(environmentId: stored.environmentId, label: stored.label, endpoint: stored.endpoint,
                                  accessToken: stored.accessToken,
                                  expiresAt: Date(timeIntervalSince1970: stored.expiresAtEpochMs / 1000),
                                  accountId: stored.accountId, thumbprint: stored.dpopThumbprint)
        }
    }

    /// Queues a save. A token without an account isn't kept.
    public func save(_ token: T3ConnectToken) {
        guard let accountId = token.accountId else { return }
        let stored = Stored(environmentId: token.environmentId, accountId: accountId, label: token.label, endpoint: token.endpoint,
                            accessToken: token.accessToken, expiresAtEpochMs: token.expiresAt.timeIntervalSince1970 * 1000,
                            dpopThumbprint: token.thumbprint)
        enqueue {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? credentials.save(token: String(decoding: data, as: UTF8.self),
                                  environmentId: Self.key(accountId: accountId, environmentId: token.environmentId))
        }
    }

    /// Queues deleting the item if it still holds `accessToken`, so a late rejection never removes a newer
    /// token (service.ts:337-346).
    public func delete(accountId: String, environmentId: String, ifToken accessToken: String) {
        enqueue {
            let key = Self.key(accountId: accountId, environmentId: environmentId)
            guard let raw = try? credentials.load(environmentId: key),
                  let stored = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8)),
                  stored.accessToken == accessToken else { return }
            try? credentials.delete(environmentId: key)
        }
    }

    /// Queues deleting this environment's items under every account (a removed machine or route).
    public func delete(environmentId: String) {
        deleteWhere { $0.environmentId == environmentId }
    }

    /// Queues deleting every item not issued to `accountId`; nil deletes them all (sign-out, an account switch,
    /// a launch whose sign-in changed).
    public func deleteAll(keepingAccount accountId: String?) {
        deleteWhere { $0.accountId != accountId }
    }

    /// Waits for everything queued before it.
    public func flush() async { await run(orOnCancel: ()) {} }

    private func deleteWhere(_ drop: @escaping @Sendable ((accountId: String, environmentId: String)) -> Bool) {
        enqueue {
            for key in (try? credentials.accounts()) ?? [] where Self.parse(key).map(drop) ?? true {
                try? credentials.delete(environmentId: key)
            }
        }
    }

    func enqueue(_ work: @escaping @Sendable () -> Void) { Self.queue.async(execute: work) }

    private func run<T: Sendable>(orOnCancel cancelled: T, _ work: @escaping @Sendable () -> T) async -> T {
        let once = Once<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                once.install(c)
                Self.queue.async { once.finish(work()) }
            }
        } onCancel: {
            once.finish(cancelled)
        }
    }
}

/// Resumes its continuation with the first value it gets, from the work or the cancel.
private final class Once<T: Sendable>: @unchecked Sendable {
    // Guards the fields below.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var value: T?

    func install(_ c: CheckedContinuation<T, Never>) {
        let early: T? = lock.withLock {
            if value == nil { continuation = c }
            return value
        }
        if let early { c.resume(returning: early) }
    }

    func finish(_ v: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            guard value == nil else { return nil }
            value = v
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: v)
    }
}
