import Foundation

/// Thread-link ids stay as written, including percent escapes (shared/src/threadLinks.ts:16-42, 3814).
public struct ThreadLink: Sendable, Equatable {
    public var environmentId: String?
    public var threadId: String

    public init?(href: String) {
        if href.hasPrefix("t3-thread://v1/") {
            environmentId = nil
            threadId = String(href.dropFirst("t3-thread://v1/".count))
        } else if href.hasPrefix("t3-thread://v2/") {
            let path = href.dropFirst("t3-thread://v2/".count)
            guard let slash = path.firstIndex(of: "/") else { return nil }
            environmentId = String(path[..<slash])
            threadId = String(path[path.index(after: slash)...])
            guard environmentId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        } else { return nil }
        guard !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    }

    public var href: String {
        if let environmentId { return "t3-thread://v2/\(environmentId)/\(threadId)" }
        return "t3-thread://v1/\(threadId)"
    }
    public var lookupKey: String { environmentId == nil ? threadId : href }
    public var percentDecoded: Self? {
        guard let decoded = threadId.removingPercentEncoding, decoded != threadId,
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var result = self
        result.threadId = decoded
        return result
    }
}
