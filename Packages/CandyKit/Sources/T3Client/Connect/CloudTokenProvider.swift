import Foundation

/// Where T3 Connect gets the user's cloud credential. The sign-in route is still open
/// (PROGRESS.md, Waiting on the user), so this library only asks for tokens.
///
/// The relay takes two kinds of Clerk token, and the routes differ (infra/relay/src/http/Api.ts):
///
/// - `POST /v1/client/dpop-token` accepts only a Clerk session JWT whose `aud` contains
///   `t3-code-relay`, which is what Clerk's `t3-relay` JWT template issues. The handler calls
///   `verifyClerkBearerToken` (Clerk `verifyToken` with that audience) and then checks the audience
///   again (Api.ts:1020-1025, 1638-1656). It never tries the OAuth path. Every DPoP route
///   (environment connect and status) needs the relay access token this exchange returns, so
///   connecting needs this JWT.
/// - The Bearer routes in the `client` group (`GET /v1/environments`, `DELETE
///   /v1/client/environment-links/:id`, link challenges, devices) run `clientBearer`
///   (Api.ts:310-336), which tries that JWT first and then a Clerk OAuth access token through
///   `authenticateRequest(..., {acceptsToken: "oauth_token"})` (Api.ts:1658-1697). The CLI's OAuth
///   token (`apps/server/src/cloud/CliTokenManager.ts`) works here, and the CLI uses it only for
///   linking (`apps/server/src/cloud/CloudLink.ts:899-901`). Nothing in apps or packages sends a
///   CLI token to `/v1/client/dpop-token`.
///
/// Official clients get the JWT from the Clerk SDK: `getToken({template: "t3-relay", skipCache: true})`
/// (apps/web/src/cloud/useCloudLinkController.ts:115, apps/web/src/cloud/publicConfig.ts:77-83).
public protocol CloudTokenProvider: Sendable {
    /// A Clerk session JWT from the `t3-relay` template (`aud` contains `t3-code-relay`).
    /// Needed for every connect. Throw `CloudSessionError.signedOut` when there is no session.
    func relaySessionJWT() async throws -> String

    /// The bearer for list and deregister. The relay accepts the `t3-relay` JWT or a Clerk OAuth
    /// access token here. Defaults to `relaySessionJWT()`.
    func clientBearer() async throws -> String

    /// The signed-in Clerk user id (the JWT `sub`), or nil when signed out. Environment tokens are
    /// cached per account and dropped when it changes (service.ts:225-238). Override with a cheap
    /// read; the default fetches a JWT and decodes it.
    func accountId() async throws -> String?

    /// The current sign-in, or nil when signed out. Environment tokens belong to one sign-in, so a new
    /// sign-in into the same account never gets the old one's (service.ts:263-268, 413-434). Defaults
    /// to the account alone.
    func currentSignIn() async throws -> CloudSignIn?
}

/// One signed-in session, the same until a sign-out or another sign-in replaces it, even into the same
/// account (client-runtime/src/platform/capabilities.ts:23-25).
public struct CloudSignIn: Sendable, Hashable {
    /// The Clerk user id, the relay JWT `sub`.
    public var accountId: String
    /// Different for every sign-in.
    public var session: String

    public init(accountId: String, session: String) {
        self.accountId = accountId
        self.session = session
    }
}

extension CloudTokenProvider {
    public func clientBearer() async throws -> String { try await relaySessionJWT() }

    public func accountId() async throws -> String? {
        do {
            return jwtSubject(try await relaySessionJWT())
        } catch CloudSessionError.signedOut {
            return nil
        }
    }

    public func currentSignIn() async throws -> CloudSignIn? {
        try await accountId().map { CloudSignIn(accountId: $0, session: $0) }
    }
}

public enum CloudSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case signedOut
    /// The JWT `sub` changed between steps (service.ts:225-238).
    case accountChanged

    public var description: String {
        switch self {
        case .signedOut: "Sign in to T3 Connect."
        case .accountChanged: "Your cloud sign-in changed. Sign in again to authorize the environment."
        }
    }
}

/// The unverified `sub` of a JWT. T3 keys its relay token cache by it (managedRelay.ts:385-393).
/// Only a cache key: the relay verifies the token.
public func jwtSubject(_ token: String) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let data = Base64URL.decode(String(parts[1])),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sub = object["sub"] as? String, !sub.isEmpty else { return nil }
    return sub
}
