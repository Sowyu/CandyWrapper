import Foundation

/// A link from one environment to another, the peer (contracts/src/peerLink.ts at 3814). The environment
/// signed in to the peer's `/mcp` with a pairing code from it, so its agents can work there.
/// `peerLinks.list` returns these with the `status` worked out when listing (`PeerLinkSummary`).
public struct PeerLinkSummary: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable { case reachable, unreachable, expired }

    public var environmentId: String
    public var label: String
    /// Addresses the peer was linked at, tried in order.
    public var urls: [String]
    /// `AuthMcpClientAccess`: "read-only" or a runtime mode.
    public var access: String
    public var linkedAt: String
    public var expiresAt: String
    public var lastReachedAt: String?
    public var lastError: String?
    public var status: Status

    public init(environmentId: String, label: String, urls: [String], access: String, linkedAt: String, expiresAt: String,
                lastReachedAt: String? = nil, lastError: String? = nil, status: Status) {
        self.environmentId = environmentId; self.label = label; self.urls = urls; self.access = access
        self.linkedAt = linkedAt; self.expiresAt = expiresAt; self.lastReachedAt = lastReachedAt
        self.lastError = lastError; self.status = status
    }

    /// `{links: PeerLinkSummary[]}`, the `peerLinks.list` reply.
    public static func list(_ reply: JSONValue) throws -> [PeerLinkSummary] {
        try (reply["links"] ?? .array([])).decode(as: [PeerLinkSummary].self)
    }
}

/// What a link's row says about it (client-runtime/src/state/peerLinks.ts `peerLinkHealth` at 3814).
public enum PeerLinkHealth: Equatable, Sendable {
    case reachable(expiresInDays: Int?)
    case unreachable(String?)
    /// Listing only checks that the peer answers; a link whose last call failed keeps its reason
    /// until a call succeeds.
    case failing(String)
    case expired

    static let expiryWarningDays = 5

    public init(_ link: PeerLinkSummary, now: Date) {
        let expires = T3Timestamp.parseEpochMs(link.expiresAt).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if link.status == .expired || expires.map({ $0 <= now }) == true { self = .expired; return }
        if link.status == .unreachable { self = .unreachable(link.lastError); return }
        if let error = link.lastError { self = .failing(error); return }
        let days = expires.map { Int(ceil($0.timeIntervalSince(now) / 86_400)) }
        self = .reachable(expiresInDays: days.flatMap { $0 <= Self.expiryWarningDays ? $0 : nil })
    }

    /// The row's status text (LinkedEnvironmentsSettings.tsx:118-127).
    public var text: String {
        switch self {
        case .expired: "Expired. Link it again with a new pairing code."
        case .unreachable(let detail): detail ?? "Not answering right now."
        case .failing(let detail): detail
        case .reachable(let days?): "Expires in \(days) \(days == 1 ? "day" : "days"). Link it again to renew."
        case .reachable(nil): "Reachable"
        }
    }
}

public enum PeerLinks {
    /// `offersLinkedEnvironments` (client-runtime/src/linkRequest.ts:20-23): the server supports links and its
    /// Linked environments beta is on. Servers before 3814 have neither.
    public static func offered(capabilities: Set<String>, settings: JSONValue) -> Bool {
        capabilities.contains("peerLinks") && settings["linkedEnvironmentsEnabled"] == .bool(true)
    }

    /// T3 3814, client-runtime/src/linkRequest.ts:29-46. An unreachable link still names a
    /// machine the agent can try; an expired link cannot authorize a foreign thread reference.
    public static func names(_ links: [PeerLinkSummary], labels: [String: String]) -> [String: String] {
        Dictionary(links.filter { $0.status != .expired }.map { ($0.environmentId, labels[$0.environmentId] ?? $0.label) },
                   uniquingKeysWith: { _, latest in latest })
    }

    /// `mcpClientScopes` (contracts/src/auth.ts:412-422): the scopes a pairing code for `access` must carry.
    public static func scopes(for access: String) -> [String] {
        switch access {
        case "read-only": ["orchestration:read"]
        case "full-access": ["orchestration:read", "orchestration:operate", "settings:write", "source-control:write"]
        default: ["orchestration:read", "orchestration:operate"]
        }
    }

    /// `PeerLinkError.reason` values (peerLink.ts:61-71). The server's `message` is already in words a user
    /// can act on, so the client shows it as sent.
    public static let errorTag = "PeerLinkError"

    /// `PeerLinkRequestError`'s text by reason (peerLink.ts:102-107). The server sends the reason; the message is a getter.
    public static func requestFailure(_ reason: String?) -> String? {
        switch reason {
        case "load_failed": "Could not load the link request."
        case "not_found": "This link request no longer exists."
        case "already_answered": "This link request was already answered."
        case "record_failed": "Could not update the link request."
        default: nil
        }
    }
}

/// `linkRequestAnswerInput` and the card's machine choice (client-runtime/src/linkRequest.ts:144-200, 248-298 at 3814).
public enum LinkRequestAnswer {
    /// `{threadId, turnItemId, answer}` for `peerLinks.answerRequest`.
    public static func payload(_ item: TurnItem, _ answer: JSONValue) -> JSONValue {
        .object(["threadId": .string(item.threadId.rawValue), "turnItemId": .string(item.id.rawValue), "answer": answer])
    }

    /// A link answer: the machine picked with its addresses, or only the address typed in.
    public static func link(environmentId: String?, label: String?, urls: [String], access: String, pairingCode: String) -> JSONValue? {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !code.isEmpty, !urls.isEmpty else { return nil }
        var answer: [String: JSONValue] = ["type": .string("link"), "urls": .array(urls.map(JSONValue.string)),
                                           "access": .string(access), "pairingCode": .string(code)]
        if let environmentId { answer["environmentId"] = .string(environmentId) }
        if let label { answer["label"] = .string(label) }
        return .object(answer)
    }

    /// `hintRank`: exact, prefix, substring, then a hint naming the machine among other words ("the box on hetzner").
    public static func hintRank(_ label: String, _ hint: String) -> Int {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var wanted = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["my ", "our ", "the "] where wanted.hasPrefix(prefix) {
            wanted = String(wanted.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if name == wanted { return 0 }
        if name.hasPrefix(wanted) { return 1 }
        if name.contains(wanted) { return 2 }
        func words(_ t: String) -> String {
            " " + t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        }
        return words(wanted).contains(words(name)) ? 3 : 4
    }

    /// `linkRequestInitialMachine`: the machine the request names, else the hint's best match, else none.
    public static func initialMachine(environmentId: String?, hint: String?, labels: [(id: String, label: String)]) -> String? {
        if let environmentId { return environmentId }
        guard let hint, !hint.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let best = labels.enumerated().min { a, b in
            let ra = hintRank(a.element.label, hint), rb = hintRank(b.element.label, hint)
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        return best.flatMap { hintRank($0.element.label, hint) < 4 ? $0.element.id : nil }
    }
}
