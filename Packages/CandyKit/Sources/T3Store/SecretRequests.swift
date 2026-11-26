import Foundation
import T3Protocol

/// A `secret_request` turn item's card (packages/client-runtime/src/secretRequest.ts): the agent asked for a
/// secret through T3's `request_secret` tool. The value travels only in `secrets.answerRequest`.
public enum SecretRequests {
    /// Shown under the field: the one promise the card makes about the value. A `file` request lets the
    /// agent's commands read it, so its card promises less (`secretRequestPrivacyNote`, secretRequest.ts:9-12).
    /// A `file` request with `fields` writes one file per value (5258 secretRequest.ts:22-35).
    public static func privacyNote(delivery: String?, multiple: Bool = false) -> String {
        delivery != "file" ? "Stored securely, never shown to the agent"
            : multiple ? "Kept out of chat, in private files this agent's commands can read for 24 hours"
            : "Kept out of chat, in a private file this agent's commands can read for 24 hours"
    }

    /// `SecretRequestInput` (5258 client-runtime secretRequest.ts:38-45): `key` is the field name, or "" on a card
    /// without fields. `secret` inputs are masked.
    public struct Input: Equatable, Sendable {
        public var key: String
        public var label: String
        public var placeholder: String
        public var secret: Bool
    }

    /// `secretRequestInputs` (:47-67): one masked input for a single-secret card, else one per field.
    public static func inputs(label: String, placeholder: String?, fields: [TurnItem.SecretRequestField]?) -> [Input] {
        guard let fields else { return [Input(key: "", label: label, placeholder: placeholder ?? defaultPlaceholder, secret: true)] }
        return fields.map { Input(key: $0.name, label: $0.label, placeholder: $0.placeholder ?? "", secret: $0.secret != false) }
    }
    /// `secretRequestPageUrl` (5258 packages/contracts/src/secretRequest.ts:7-15): only an http(s) page with a host,
    /// so an agent cannot make the card open another scheme. `href` follows the URL standard's spelling for what
    /// tells two pages apart here: lowercase scheme and host, and "/" for an empty path.
    // ponytail: no IDNA or percent-encoding pass; add one if a card shows a host that differs from the web's.
    public static func pageURL(_ value: String) -> (href: String, host: String)? {
        guard var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = scheme; parts.host = host
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        guard let href = parts.string else { return nil }
        return (href, parts.port.map { "\(host):\($0)" } ?? host)
    }

    /// `secretRequestLink` (5258 client-runtime/src/secretRequest.ts:116-120): the request's `url`, else the one
    /// distinct link in its reason, for the card's "Open {host}" button.
    public static func link(url: String?, reason: String) -> (href: String, host: String)? {
        guard let raw = url ?? reasonLink(reason) else { return nil }
        return pageURL(raw)
    }

    // Backticks, <angle brackets> and markdown link targets keep their exact text; a bare link drops trailing
    // sentence punctuation (`REASON_LINK`, secretRequest.ts:71-72).
    nonisolated(unsafe) private static let reasonLinkPattern = try! NSRegularExpression(
        pattern: #"`(https?://[^`\s]+)`|<(https?://[^>\s]+)>|\]\((https?://(?:[^()\s]|\([^()\s]*\))+)\)|(https?://[^\s<>"'`\[\]]+)"#,
        options: [.caseInsensitive])

    /// `reasonLink` (:98-113): the one distinct http(s) link in `reason`. Two spellings of one page count once.
    static func reasonLink(_ reason: String) -> String? {
        let ns = reason as NSString
        let raw = reasonLinkPattern.matches(in: reason, range: NSRange(location: 0, length: ns.length)).map { match -> String in
            for group in 1...3 where match.range(at: group).location != NSNotFound { return ns.substring(with: match.range(at: group)) }
            let before = ns.substring(to: match.range.location)
            var link = trimPunctuation(ns.substring(with: match.range(at: 4)))
            while true {
                let next = trimEmphasis(link, before: before)
                if next == link { break }
                link = next
            }
            return link
        }
        var seen: [String] = []
        for link in raw { let key = pageURL(link)?.href ?? link; if !seen.contains(key) { seen.append(key) } }
        return seen.count == 1 ? seen[0] : nil
    }

    /// `trimPunctuation` (:74-82): a `)` stays when the link opened a matching `(`.
    static func trimPunctuation(_ link: String) -> String {
        var chars = Array(link)
        while let last = chars.last, ".,;:!?)".contains(last) {
            if last == ")", chars.filter({ $0 == "(" }).count > chars.filter({ $0 == ")" }).count - 1 { break }
            chars.removeLast()
        }
        return String(chars)
    }

    /// `trimEmphasis` (:85-96): drops a closing `*` or `_` run only when the same run opened emphasis before the link
    /// and is still open.
    static func trimEmphasis(_ link: String, before: String) -> String {
        guard let run = link.firstMatch(of: /(\*{1,3}|_{1,3})$/)?.1 else { return link }
        let escaped = NSRegularExpression.escapedPattern(for: String(run))
        guard let opener = try? NSRegularExpression(pattern: "(?:^|[\\s(*_])\(escaped)(?=\\S|$)"),
              let last = opener.matches(in: before, range: NSRange(location: 0, length: (before as NSString).length)).last else { return link }
        let rest = (before as NSString).substring(from: last.range.location + last.range.length)
        let closed = rest.range(of: "\\S\(escaped)(?:[\\s.,;:!?)]|$)", options: .regularExpression) != nil
        return closed ? link : trimPunctuation(String(link.dropLast(run.count)))
    }

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

    /// `values` is keyed by `Input.key`; `save(text)` is the single-secret card's one value.
    public enum Answer: Sendable {
        case values([String: String]), decline
        public static func save(_ secret: String) -> Answer { .values(["": secret]) }
    }

    /// `secretRequestAnswerInput` (5258 secretRequest.ts:261-284): nil until every input has a value, since the server
    /// rejects a blank one. A card without `fields` answers `secret`, which every server takes; one with `fields`
    /// answers `values` keyed by field name, or a 5258 server refuses it with `fields_mismatch`.
    public static func answerInput(threadId: ThreadId, itemId: TurnItemId, fields: [TurnItem.SecretRequestField]? = nil,
                                   _ answer: Answer) -> JSONValue? {
        let reply: JSONValue
        switch answer {
        case .decline: reply = .object(["type": .string("decline")])
        case .values(let typed):
            let entries = inputs(label: "", placeholder: nil, fields: fields).map {
                ($0.key, (typed[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard entries.allSatisfy({ !$0.1.isEmpty }) else { return nil }
            reply = fields == nil
                ? .object(["type": .string("save"), "secret": .string(entries[0].1)])
                : .object(["type": .string("save"), "values": .object(Dictionary(entries.map { ($0.0, JSONValue.string($0.1)) }, uniquingKeysWith: { a, _ in a }))])
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
