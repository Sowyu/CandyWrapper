import Foundation

/// `review.getDiffPreview` (packages/contracts/src/review.ts, rpc.ts:426): the checkout's working tree and
/// branch range as unified diffs. The diff panel's Changes and Uncommitted scopes read it.
public struct ReviewDiffPreview: Decodable, Hashable, Sendable {
    public struct FileStat: Decodable, Hashable, Sendable {
        public var path: String
        public var previousPath: String?
        public var additions: Int
        public var deletions: Int
    }
    public struct Source: Decodable, Hashable, Sendable {
        public var id: String
        /// `working-tree` or `branch-range`.
        public var kind: String
        public var title: String
        public var baseRef: String?
        public var headRef: String?
        public var diff: String
        public var diffHash: String
        public var truncated: Bool
        /// Complete statistics, independent of patch limits. Absent on older servers.
        public var files: [FileStat]?
        public init(id: String, kind: String, title: String, baseRef: String?, headRef: String?, diff: String,
                    diffHash: String, truncated: Bool, files: [FileStat]? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.baseRef = baseRef; self.headRef = headRef
            self.diff = diff; self.diffHash = diffHash; self.truncated = truncated; self.files = files
        }
    }
    public var cwd: String
    public var sources: [Source]
    public init(cwd: String, sources: [Source]) { self.cwd = cwd; self.sources = sources }

    public static let method = "review.getDiffPreview"

    /// `ReviewDiffPreviewInput`: the base ref only when one was picked (DiffPanel.tsx:342-358).
    public static func input(cwd: String, baseRef: String?, ignoreWhitespace: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["cwd": .string(cwd), "ignoreWhitespace": .bool(ignoreWhitespace)]
        if let baseRef, !baseRef.trimmingCharacters(in: .whitespaces).isEmpty { o["baseRef"] = .string(baseRef) }
        return .object(o)
    }
}
