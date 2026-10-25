import Foundation

/// `ThreadGuestMessageStatus` (packages/contracts/src/guestShare.ts:30).
public struct GuestMessageStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let pending: Self = "pending"
    public static let sent: Self = "sent"
    public static let dismissed: Self = "dismissed"
}

/// `ThreadGuestMessage` (guestShare.ts:33-40): a message a guest proposed, waiting for the owner while `pending`.
public struct ThreadGuestMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var status: GuestMessageStatus
    public var submittedAt: T3Timestamp
    /// The thread's attachments (`ChatAttachment`). Absent on older messages.
    public var attachments: [JSONValue]?

    public init(id: String, text: String, status: GuestMessageStatus, submittedAt: T3Timestamp, attachments: [JSONValue]? = nil) {
        self.id = id; self.text = text; self.status = status; self.submittedAt = submittedAt; self.attachments = attachments
    }
}

/// `ThreadGuestShare` (guestShare.ts:43-53): the thread's guest link, on `thread.guestShare`. It stays on the
/// thread after it expires, until the owner closes it.
public struct ThreadGuestShare: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The T3 Connect tunnel hostname the link points at.
    public var host: String
    public var createdAt: T3Timestamp
    public var expiresAt: T3Timestamp
    /// Set once, when the guest redeems the link.
    public var guestName: String?
    public var messages: [ThreadGuestMessage]

    public init(id: String, host: String, createdAt: T3Timestamp, expiresAt: T3Timestamp, guestName: String?, messages: [ThreadGuestMessage]) {
        self.id = id; self.host = host; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.guestName = guestName; self.messages = messages
    }

    /// `pendingGuestMessageCount` (guestShare.ts:55-56) lists them in order.
    public var pendingMessages: [ThreadGuestMessage] { messages.filter { $0.status == .pending } }

    /// `GuestShareStatus` (GuestShareControls.tsx:216-223): expired once the current UTC minute reaches
    /// `expiresAt`'s minute (`expiresAt.slice(0, 16) <= nowMinute`).
    public func isExpired(now: Date) -> Bool {
        guard let ms = expiresAt.epochMs else { return false }
        return ms / 60_000 <= Int64((now.timeIntervalSince1970 * 1000).rounded(.down)) / 60_000
    }

    /// The header's status text (GuestShareControls.tsx:216-223).
    public func statusText(now: Date) -> String {
        if isExpired(now: now) { return "Guest link expired" }
        return guestName.map { "\($0) is a guest" } ?? "Guest link active"
    }

    /// When the status text next changes on its own: the start of `expiresAt`'s minute, or nil once expired.
    public func expiryDate(after now: Date) -> Date? {
        guard let ms = expiresAt.epochMs, !isExpired(now: now) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms / 60_000 * 60))
    }
}

/// `GuestShareCreateResult` (guestShare.ts:61-65), the reply to `guestShare.create`.
public struct GuestShareCreateResult: Codable, Hashable, Sendable {
    public var url: String
    public var share: ThreadGuestShare
}

/// `GuestShareCreateError` (guestShare.ts:67-93): the server's `reason` and the text T3 shows for it.
public enum GuestShareCreateError {
    public static let messages: [String: String] = [
        "disabled": "Guest links are off. Turn them on in Settings > Beta.",
        "connect_unavailable": "Guest links need a running T3 Connect tunnel.",
        "thread_unavailable": "This thread cannot be shared.",
        "read_failed": "Failed to read the shared thread.",
        "changed": "The guest link changed while it was being created.",
    ]
    /// GuestShareControls.tsx:116 when the failure carries no message.
    public static let fallback = "Could not create a guest link."

    public static func message(reason: String?) -> String? { reason.flatMap { messages[$0] } }
}

/// `GuestMessageAttribution` (packages/contracts/src/composerContext.ts:257-267), on a sent guest message's
/// `context.guest`. The message `text` is the attributed form the agent reads; people see `text` here.
public struct GuestMessageAttribution: Hashable, Sendable {
    public var guestMessageId: String
    public var name: String
    public var text: String
    public var shareId: String?

    public init?(_ value: JSONValue?) {
        guard let value, let id = value["guestMessageId"]?.stringValue, let name = value["name"]?.stringValue,
              let text = value["text"]?.stringValue else { return nil }
        guestMessageId = id; self.name = name; self.text = text; shareId = value["shareId"]?.stringValue
    }
}
