import Foundation

/// A failed Clerk call, with a message the sign-in view can show as is. Never carries a token,
/// a code the user typed or a password.
///
/// Codes and statuses come from Clerk's Frontend API error index
/// (https://clerk.com/docs/guides/development/errors/frontend-api, read 2026-10-10) and from clerk-ios:
/// `form_code_incorrect` (`ClerkKitUI/Common/OTPSubmissionDisposition.swift:22`),
/// `form_identifier_not_found` (`ClerkKitUI/Components/Auth/AuthStartView.swift:575`),
/// `authentication_invalid`, `resource_not_found`, `signed_out`
/// (`Networking/Middleware/ClerkInvalidAuthResponseMiddleware.swift:10`).
public struct ClerkAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// 422 `form_code_incorrect`.
        case wrongCode
        /// 400 `verification_expired`.
        case codeExpired
        /// 400 `verification_failed`: too many wrong codes for this attempt.
        case tooManyAttempts
        /// 422 `form_identifier_not_found`.
        case unknownEmail
        /// 422 `form_password_incorrect`.
        case wrongPassword
        /// 422 `form_password_compromised`.
        case passwordCompromised
        /// 429 `too_many_requests`, `verification_code_rate_limit_exceeded`,
        /// `verification_code_too_many_requests`, `verification_code_too_many_attempts`.
        /// `retryAfter` is the `Retry-After` header in seconds.
        case rateLimited(retryAfter: Int?)
        /// 403 `user_locked`, with `meta.lockout_expires_in_seconds`.
        case accountLocked(seconds: Int?)
        /// 401 `authentication_invalid` or `signed_out`, 404 `resource_not_found` on a session call,
        /// or a sign-in that needs a step CandyWrapper does not offer.
        case signedOut
        /// The instance has the native API or this strategy turned off.
        case unavailable
        /// No answer: offline, DNS, timeout, TLS.
        case network
        /// Any other Clerk error. `message` is Clerk's `long_message`.
        case clerk(status: Int, code: String?)
        case invalidResponse
        /// The Keychain refused to store the sign-in.
        case keychain
    }

    public let kind: Kind
    /// Text for the UI.
    public let message: String

    public init(_ kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message ?? Self.defaultMessage(kind)
    }

    public var description: String { message }

    static func defaultMessage(_ kind: Kind) -> String {
        switch kind {
        case .wrongCode: "That code is incorrect. Check the email and try again."
        case .codeExpired: "That code has expired. Send a new code."
        case .tooManyAttempts: "Too many incorrect codes. Start the sign-in again."
        case .unknownEmail: "No T3 Connect account uses that email."
        case .wrongPassword: "That password is incorrect. Try again, or sign in with an email code."
        case .passwordCompromised: "This password appeared in a data breach. Sign in with an email code instead."
        case .rateLimited(let seconds?): "Too many attempts. Try again in \(seconds) \(seconds == 1 ? "second" : "seconds")."
        case .rateLimited(nil): "Too many attempts. Wait a moment and try again."
        case .accountLocked(let seconds?): "Your account is locked. Try again in \(max(1, (seconds + 59) / 60)) min."
        case .accountLocked(nil): "Your account is locked. Try again later."
        case .signedOut: "Sign in to T3 Connect."
        case .unavailable: "This sign-in method is not available for T3 Connect."
        case .network: "Can't reach T3 Connect sign-in. Check your connection and try again."
        case .clerk: "Sign-in failed. Try again."
        case .invalidResponse: "T3 Connect sign-in sent an unexpected response. Try again."
        case .keychain: "Couldn't save the sign-in to the Keychain."
        }
    }

    /// Maps a non-2xx Frontend API response.
    static func from(status: Int, body: Data, retryAfter: String?) -> ClerkAuthError {
        let item = (try? ClerkWire.decoder.decode(ClerkErrorBody.self, from: body))?.errors.first
        switch item?.code {
        case "form_code_incorrect": return ClerkAuthError(.wrongCode)
        case "verification_expired": return ClerkAuthError(.codeExpired)
        case "verification_failed": return ClerkAuthError(.tooManyAttempts)
        case "form_identifier_not_found": return ClerkAuthError(.unknownEmail)
        case "form_password_incorrect": return ClerkAuthError(.wrongPassword)
        case "form_password_compromised": return ClerkAuthError(.passwordCompromised)
        case "user_locked": return ClerkAuthError(.accountLocked(seconds: item?.meta?.lockoutExpiresInSeconds))
        case "authentication_invalid", "signed_out": return ClerkAuthError(.signedOut)
        case "too_many_requests", "verification_code_rate_limit_exceeded",
             "verification_code_too_many_requests", "verification_code_too_many_attempts":
            return ClerkAuthError(.rateLimited(retryAfter: retryAfter.flatMap(retrySeconds)))
        default:
            if status == 429 { return ClerkAuthError(.rateLimited(retryAfter: retryAfter.flatMap(retrySeconds))) }
            let text = item?.longMessage ?? item?.message
            return ClerkAuthError(.clerk(status: status, code: item?.code), message: text.map { "Sign-in failed: \($0)" })
        }
    }

    /// `Retry-After` in whole seconds, rounded up. Accepts a number only; Clerk sends seconds.
    static func retrySeconds(_ value: String) -> Int? {
        guard let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 else { return nil }
        return Int(seconds.rounded(.up))
    }
}
