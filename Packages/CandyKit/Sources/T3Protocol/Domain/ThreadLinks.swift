import Foundation

/// Thread-link ids stay as written, including percent escapes (shared/src/threadLinks.ts:16-42, 3814).
public struct ThreadLink: Sendable, Equatable {
    public var environmentId: String?
    public var threadId: String

    /// `DEFAULT_HOSTED_APP_URL` (4928 packages/shared/src/connectAuth.ts:10) plus `/threads/`.
    public static let hostedPrefix = "https://app.t3.codes/threads/"

    public init?(href: String) {
        if href.hasPrefix(Self.hostedPrefix) {
            // `parseHostedThreadLink` (4928 shared/src/threadLinks.ts:57-68): `<env>/<thread>`, each escaped
            // by the link itself, so these ids are percent-decoded.
            let segments = href.dropFirst(Self.hostedPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_%-")
            guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }),
                  let env = segments[0].removingPercentEncoding, let thread = segments[1].removingPercentEncoding,
                  !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            environmentId = env
            threadId = thread
        } else if href.hasPrefix("t3-thread://v1/") {
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

/// `orchestration.getThreadLinkMetadata` (4928 packages/contracts/src/rpc.ts:2019, orchestrationV2.ts:4010-4021, 4551-4554):
/// titles and projects of threads a chip names but the client hasn't loaded. Servers that serve it set the
/// `threadLinkMetadata` config flag (server.ts:725). Deleted and unknown ids are absent from the answer.
public struct ThreadLinkMetadata: Decodable, Hashable, Sendable {
    public static let method = "orchestration.getThreadLinkMetadata"
    public static let configFlag = "threadLinkMetadata"

    public var title: String
    public var projectId: ProjectId?

    public static func input(threadIds: [ThreadId]) -> JSONValue {
        .object(["threadIds": .array(threadIds.map { .string($0.rawValue) })])
    }

    /// The answer by thread id; entries that don't decode are skipped.
    public static func decode(_ value: JSONValue?) -> [ThreadId: ThreadLinkMetadata] {
        var out: [ThreadId: ThreadLinkMetadata] = [:]
        for (id, entry) in value?.objectValue ?? [:] {
            if let meta = try? entry.decode(as: ThreadLinkMetadata.self) { out[ThreadId(id)] = meta }
        }
        return out
    }
}

