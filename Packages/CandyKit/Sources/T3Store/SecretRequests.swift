import Foundation
import T3Protocol

/// A `secret_request` turn item's card (packages/client-runtime/src/secretRequest.ts): the agent asked for a
/// secret through T3's `request_secret` tool. The value travels only in `secrets.answerRequest`.
public enum SecretRequests {
    /// Shown under the field: the one promise the card makes about the value.
    public static let privacyNote = "Stored securely, never shown to the agent"
    public static let defaultPlaceholder = "Paste the secret"
    public static let genericFailure = "Could not answer the request. Try again."

    public enum Display: Equatable, Sendable {
        case pending
        case pendingElsewhere(label: String)
        case answered(outcome: Outcome, label: String)
    }
    public enum Outcome: Sendable { case saved, declined, ended }

    /// `secretRequestDisplay` (:47-61): a request inherited from another thread (a fork) can only be answered
    /// where it was asked.
    public static func display(status: String?, visibility: String) -> Display {
        switch status {
        case "saved": .answered(outcome: .saved, label: "Saved securely and kept private")
        case "declined": .answered(outcome: .declined, label: "Declined")
        case "cancelled": .answered(outcome: .ended, label: "Request ended")
        default: visibility == "local" ? .pending : .pendingElsewhere(label: "Waiting for an answer in the original thread")
        }
    }

    public enum Answer: Sendable { case save(String), decline }

    /// `secretRequestAnswerInput` (:67-77): a blank save is nil, since the server rejects it.
    public static func answerInput(threadId: ThreadId, itemId: TurnItemId, _ answer: Answer) -> JSONValue? {
        let reply: JSONValue
        switch answer {
        case .decline: reply = .object(["type": .string("decline")])
        case .save(let raw):
            let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { return nil }
            reply = .object(["type": .string("save"), "secret": .string(secret)])
        }
        return .object(["threadId": .string(threadId.rawValue), "turnItemId": .string(itemId.rawValue), "answer": reply])
    }

    /// `secretRequestFailureMessage` (:87-101): only known server errors pass their message through, so the
    /// typed value can never surface in the UI.
    public static func failureMessage(tag: String?, message: String?) -> String {
        guard let tag, ["SecretRequestError", "EnvironmentAuthorizationError"].contains(tag),
              let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return genericFailure }
        return message
    }
}
