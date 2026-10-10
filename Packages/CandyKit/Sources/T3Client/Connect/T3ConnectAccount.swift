import Foundation
import T3Protocol

/// One machine on the signed-in account, as Settings > Connections lists it
/// (client-runtime relay/discovery.ts, CloudEnvironmentConnectList.tsx).
public struct T3ConnectMachine: Sendable, Equatable {
    /// `RelayEnvironmentAvailability` (discovery.ts:26).
    public enum Availability: Sendable, Equatable {
        case checking, online, offline
        case error(String)
    }

    public var record: RelayEnvironmentRecord
    public var availability: Availability
    public var status: RelayEnvironmentStatus?

    public init(record: RelayEnvironmentRecord, availability: Availability, status: RelayEnvironmentStatus? = nil) {
        self.record = record
        self.availability = availability
        self.status = status
    }

    public var environmentId: String { record.environmentId }
    /// The relay health probe carries the server's descriptor, so the row can show its glyph early.
    public var machine: String? { status?.descriptor?.platform?.machine }

    /// `orchestrationProtocolCompatibilityError` on the status descriptor (connection/compatibility.ts:9-27).
    public var unsupportedReason: String? {
        guard let d = status?.descriptor, !d.isCompatible else { return nil }
        return d.protocolVersion > T3Protocol.orchestrationProtocolVersion
            ? "This client is not supported by this server. Update your app or use a compatible release to connect to \(d.label)."
            : "This client requires a newer server. Update T3 Code on \(d.label) to connect."
    }

    /// `relayOfflineReasonMessage` when the relay reports it offline.
    public var offlineReason: String? { availability == .offline ? status?.offlineMessage : nil }
}

/// The signed-in T3 Connect account: Clerk session, relay client and the connect authorizer, plus the
/// account-level calls Settings needs (discovery, deregister, sign-out cleanup). The Clerk client token
/// and the DPoP key live in the Keychain; relay and environment tokens stay in memory.
public actor T3ConnectAccount {
    public nonisolated let clerk: ClerkClient
    public nonisolated let relay: RelayClient
    public nonisolated let authorizer: T3ConnectAuthorizer

    public init(clerk: ClerkClient, relay: RelayClient, identity: ClientIdentity, send: HTTPSend? = nil) {
        self.clerk = clerk
        self.relay = relay
        authorizer = T3ConnectAuthorizer(relay: relay, tokens: clerk, identity: identity, send: send)
    }

    /// T3's production Clerk and relay with the Keychain stores.
    public static func production(identity: ClientIdentity, device: ClerkDeviceInfo) throws -> T3ConnectAccount {
        let key = try DPoPKeyStore().loadOrCreate()
        return T3ConnectAccount(clerk: ClerkClient(device: device), relay: try RelayClient(key: key), identity: identity)
    }

    /// The signed-in account, or nil.
    public func account() async -> ClerkAccount? { await clerk.account() }

    /// `GET /v1/environments`, then every machine's relay status at once (discovery.ts:226-305).
    /// A failed status marks only that machine; a failed list throws. Signed out throws
    /// `CloudSessionError.signedOut`.
    public func discover() async throws -> [T3ConnectMachine] {
        let records = try await relay.listEnvironments(bearer: try await clerk.clientBearer())
        guard !records.isEmpty else { return [] }
        let jwt = try await clerk.relaySessionJWT()
        let relay = self.relay
        let statuses = await withTaskGroup(of: (Int, T3ConnectMachine).self) { group in
            for (i, record) in records.enumerated() {
                group.addTask {
                    do {
                        let status = try await relay.environmentStatus(environmentId: record.environmentId, relayJWT: jwt)
                        if let failure = status.validate(against: record) {
                            return (i, T3ConnectMachine(record: record, availability: .error(failure.detail)))
                        }
                        return (i, T3ConnectMachine(record: record, availability: status.isOnline ? .online : .offline, status: status))
                    } catch {
                        return (i, T3ConnectMachine(record: record, availability: .error(T3Connect.failure(for: error).detail)))
                    }
                }
            }
            var all: [(Int, T3ConnectMachine)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return statuses
    }

    /// Saves a listed machine as a T3 Connect route in the catalog (`RelayConnectionRegistration`).
    @discardableResult
    public func add(_ machine: T3ConnectMachine, to catalog: EnvironmentCatalog) async throws -> EnvironmentRegistration {
        guard let accountId = try await clerk.accountId() else { throw CloudSessionError.signedOut }
        return try catalog.addRelay(machine.record, accountId: accountId, machine: machine.machine)
    }

    /// The account page's "Deregister": `DELETE /v1/client/environment-links/:id`. Works while the host
    /// is offline. Local connections are not changed (T3ConnectUserProfilePage.tsx).
    public func deregister(environmentId: String) async throws {
        try await relay.deregister(environmentId: environmentId, bearer: try await clerk.clientBearer())
        await authorizer.forget(environmentId: environmentId)
    }

    /// Sign-out (managedAuth.tsx:46-57): the Clerk session goes, then every relay and environment token,
    /// then the catalog's relay routes. Machines reached only through T3 Connect are forgotten. Returns
    /// what the catalog removed and changed, for the app to close their sessions.
    @discardableResult
    public func signOut(catalog: EnvironmentCatalog) async throws -> (removed: [String], updated: [EnvironmentRegistration]) {
        await clerk.signOut()
        await authorizer.reset()
        return try catalog.removeRelay()
    }
}

/// The sign-in sheet's state machine: email, then the emailed code (resend, wrong or expired code), or a
/// password. Errors are `ClerkAuthError` messages. No secret is kept here: the code and password pass
/// straight to Clerk.
@MainActor
public final class T3ConnectSignInFlow {
    public enum Step: Equatable, Sendable {
        case email
        /// Clerk emailed a code to `sentTo` (Clerk's masked address, else the typed email).
        case code(sentTo: String)
        case password
        case signedIn(ClerkAccount)
    }

    public enum Busy: Equatable, Sendable { case continuing, resending }

    public private(set) var step: Step = .email
    public private(set) var email = ""
    public private(set) var busy: Busy?
    public private(set) var error: String?
    /// "We sent a new code." after a resend.
    public private(set) var notice: String?
    /// After every change.
    public var onChange: (() -> Void)?

    private let clerk: ClerkClient
    private var challenge: ClerkCodeChallenge?

    public init(clerk: ClerkClient) {
        self.clerk = clerk
    }

    public var isBusy: Bool { busy != nil }

    /// Continue on the email step: creates the sign-in and emails a code.
    public func submitEmail(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard busy == nil else { return }
        email = trimmed
        guard trimmed.contains("@") else { return fail("Enter a valid email address.") }
        await run(.continuing) {
            let challenge = try await self.clerk.startEmailCode(email: trimmed)
            self.challenge = challenge
            self.step = .code(sentTo: challenge.sentTo ?? trimmed)
        }
    }

    /// Continue on the code step. Six digits; anything else is refused before Clerk sees it.
    public func submitCode(_ code: String) async {
        guard busy == nil, let challenge else { return }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return fail("Enter the 6-digit code from the email.") }
        await run(.continuing) {
            let account = try await self.clerk.verifyCode(digits, for: challenge)
            self.challenge = nil
            self.step = .signedIn(account)
        } onError: { error in
            // Clerk ends the attempt after too many wrong codes; start over from the email.
            if error.kind == .tooManyAttempts || error.kind == .signedOut {
                self.challenge = nil
                self.step = .email
            }
        }
    }

    /// "Resend" on the code step.
    public func resend() async {
        guard busy == nil, let challenge else { return }
        await run(.resending) {
            try await self.clerk.resendCode(challenge)
            self.notice = "We sent a new code."
        }
    }

    /// "Use password instead" on the code step.
    public func usePassword() {
        guard busy == nil else { return }
        challenge = nil
        error = nil
        notice = nil
        step = .password
        onChange?()
    }

    /// "Use an email code instead" on the password step: emails a fresh code.
    public func useEmailCode() async {
        guard busy == nil else { return }
        await submitEmail(email)
    }

    /// Continue on the password step. Clerk may still ask for an emailed code on a new device.
    public func submitPassword(_ password: String) async {
        guard busy == nil else { return }
        guard !password.isEmpty else { return fail("Enter your password.") }
        let email = self.email
        await run(.continuing) {
            switch try await self.clerk.signIn(email: email, password: password) {
            case .complete(let account):
                self.step = .signedIn(account)
            case .needsCode(let challenge):
                self.challenge = challenge
                self.step = .code(sentTo: challenge.sentTo ?? email)
            }
        }
    }

    /// The pencil next to the address: back to the email step, keeping what was typed.
    public func editEmail() {
        guard busy == nil else { return }
        challenge = nil
        error = nil
        notice = nil
        step = .email
        onChange?()
    }

    private func fail(_ message: String) {
        error = message
        notice = nil
        onChange?()
    }

    private func run(_ kind: Busy, _ body: @MainActor () async throws -> Void,
                     onError: @MainActor (ClerkAuthError) -> Void = { _ in }) async {
        busy = kind
        error = nil
        notice = nil
        onChange?()
        do {
            try await body()
        } catch let e as ClerkAuthError {
            error = e.message
            onError(e)
        } catch is CancellationError {
        } catch {
            self.error = ClerkAuthError(.network).message
        }
        busy = nil
        onChange?()
    }
}
