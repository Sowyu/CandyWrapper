import CryptoKit
import Foundation

/// `pullRequestAnchor.ts` (4928 packages/shared, #33989 with GitLab's #34607 and #34662): what a
/// pull request link names past the pull request itself, so opening it jumps there.
public enum PullRequestAnchor: Equatable, Sendable {
    public struct Range: Equatable, Sendable {
        public var start: Int
        /// `left` or `right`.
        public var side: String
        public var end: Int
        public var endSide: String
        /// A GitLab line code's old-side counter: the line it names when that old line was removed.
        public var oldLine: Int?
        public init(start: Int, side: String, end: Int, endSide: String, oldLine: Int? = nil) {
            self.start = start; self.side = side; self.end = end; self.endSide = endSide; self.oldLine = oldLine
        }
    }

    case code, commits, checks
    case diff(digest: String, range: Range?)
    case timeline(String)
    case summary(String)

    private static func match(_ pattern: String, _ s: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Swift.Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    /// `pullRequestUrlHash`: the decoded fragment, or "" when it does not decode.
    static func hash(_ url: String?) -> String {
        guard let url, let c = URLComponents(string: url), let f = c.percentEncodedFragment else { return "" }
        return f.removingPercentEncoding ?? ""
    }

    /// `normalizePullRequestCommentAnchor`: `r123` and `discussion-diff-123R5` are `discussion_r123`.
    static func normalize(_ anchor: String) -> String {
        guard let m = match(#"^(?:r|discussion-diff-)(\d+)(?:[LR]\d+(?:-[LR]\d+)?)?$"#, anchor), let n = m[1] else { return anchor }
        return "discussion_r\(n)"
    }

    /// `pullRequestPathTab`: GitHub's tabs and GitLab's equivalents; Forgejo spells it `/pulls/`.
    static func pathTab(_ path: String) -> PullRequestAnchor? {
        guard let m = match(#"/(?:pulls?|-/merge_requests)/\d+/([a-z]+)(?:/(.*))?$"#, path), let tab = m[1]?.lowercased() else { return nil }
        let rest = m[2] ?? ""
        switch tab {
        case "files", "changes", "diffs": return .code
        case "commits":
            if rest.isEmpty { return .commits }
            return match(#"^[a-f0-9]{40}/?$"#, rest) != nil ? .code : nil
        case "checks", "pipelines": return rest.isEmpty ? .checks : nil
        default: return nil
        }
    }

    static func isLine(_ n: Int?) -> Bool { (n ?? 0) >= 1 && (n ?? 0) <= 9_007_199_254_740_991 }

    static func gitLabLine(_ start: Int?, _ side: String, oldLine: Int? = nil) -> Range? {
        guard let start, isLine(start) else { return nil }
        return Range(start: start, side: side, end: start, endSide: side, oldLine: isLine(oldLine) ? oldLine : nil)
    }

    /// `gitLabDiffAnchor`: `<sha1>_<old>_<new>`, Rapid Diffs' `line_<sha1 prefix>_<old>` or `_A<new>`.
    static func gitLab(_ anchor: String, file: String?) -> PullRequestAnchor? {
        if let m = match(#"^line_([a-f0-9]{9})_(A?)(\d+)$"#, anchor) {
            return .diff(digest: (m[1] ?? "").lowercased(), range: gitLabLine(Int(m[3] ?? ""), (m[2] ?? "").isEmpty ? "left" : "right"))
        }
        let code = match(#"^(?:diff-content-)?([a-f0-9]{40})(?:_(\d+)_(\d+))?$"#, anchor)
        let fileDigest = anchor.isEmpty && file.map { match(#"^[a-f0-9]{40}$"#, $0) != nil } == true ? file : nil
        guard let digest = code?[1] ?? fileDigest else { return nil }
        var range: Range?
        if let old = code?[2], let new = code?[3] {
            let o = Int(old), n = Int(new)
            range = n == 0 ? gitLabLine(o, "left") : gitLabLine(n, "right", oldLine: o)
        }
        return .diff(digest: digest.lowercased(), range: range)
    }

    /// `resolvePullRequestAnchorRange`: a GitLab line code whose old line was removed names that old line.
    public static func resolve(_ range: Range, isRemovedLine: (Int) -> Bool) -> Range {
        guard let old = range.oldLine, isRemovedLine(old) else { return range }
        return gitLabLine(old, "left") ?? range
    }

    /// `parsePullRequestAnchor`.
    public static func parse(_ url: String?) -> PullRequestAnchor? {
        guard let url, let c = URLComponents(string: url), c.scheme != nil, c.host != nil else { return nil }
        let path = c.path
        let fallback = pathTab(path)
        let anchor = hash(url)
        let file = match(#"/-/merge_requests/\d+/diffs/?$"#, path) != nil ? c.queryItems?.first { $0.name == "file" }?.value : nil
        if let g = gitLab(anchor, file: file) { return g }
        if anchor.isEmpty { return fallback }
        if let m = match(#"^diff-([a-f0-9]+)(?:([LR])(\d+)(?:-([LR])(\d+))?)?$"#, anchor) {
            guard let side = m[2] else { return .diff(digest: (m[1] ?? "").lowercased(), range: nil) }
            guard let start = Int(m[3] ?? ""), let end = Int(m[5] ?? m[3] ?? ""), isLine(start), isLine(end) else { return fallback }
            let endSide = m[4] ?? side
            return .diff(digest: (m[1] ?? "").lowercased(),
                         range: Range(start: start, side: side.uppercased() == "L" ? "left" : "right", end: end, endSide: endSide.uppercased() == "L" ? "left" : "right"))
        }
        if match(#"^(?:(?:issuecomment-|pullrequestreview-|discussion_r|r|commitcomment-|event-|note_|comment-)\d+|discussion-diff-\d+(?:[LR]\d+(?:-[LR]\d+)?)?)$"#, anchor) != nil {
            return .timeline(normalize(anchor))
        }
        return fallback ?? .summary(anchor)
    }

    /// `pullRequestAnchorMatchesUrl`.
    public static func matches(_ anchor: String, url: String?) -> Bool { normalize(hash(url)) == anchor }

    /// `resolvePullRequestReviewAnchor`: a review with no words of its own resolves to the earliest
    /// line comment it posted.
    public static func resolveReview(_ anchor: String, commentURLs: [String?], threadComments: [(url: String?, createdAt: String, reviewUrl: String?)]) -> String {
        guard match(#"^pullrequestreview-\d+$"#, anchor) != nil else { return anchor }
        if commentURLs.contains(where: { matches(anchor, url: $0) }) { return anchor }
        let posted = threadComments.filter { $0.url != nil && matches(anchor, url: $0.reviewUrl) }.min { $0.createdAt < $1.createdAt }
        let own = posted.map { normalize(hash($0.url)) } ?? ""
        return own.isEmpty ? anchor : own
    }

    /// `pullRequestDiffPathMatches`: GitHub's MD5 or SHA-256 of the path, GitLab's SHA-1 (or its 9-character prefix).
    public static func pathMatches(_ digest: String, _ path: String) -> Bool {
        let bytes = Data(path.utf8)
        func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
        if digest.count == 40 || digest.count == 9 { return hex(Insecure.SHA1.hash(data: bytes)).hasPrefix(digest) }
        return digest == (digest.count == 32 ? hex(Insecure.MD5.hash(data: bytes)) : hex(SHA256.hash(data: bytes)))
    }

    /// `pullRequestLinkCommit`: the commit a diff permalink is scoped to.
    public static func linkCommit(_ url: String?) -> String? {
        guard let url, let c = URLComponents(string: url) else { return nil }
        let commit = match(#"/-/merge_requests/\d+/diffs/?$"#, c.path) != nil
            ? c.queryItems?.first { $0.name == "commit_id" }?.value
            : match(#"/pulls?/\d+/commits/([a-f0-9]{40})/?$"#, c.path)?[1] ?? nil
        guard let commit, match(#"^[a-f0-9]{40}$"#, commit) != nil else { return nil }
        return commit
    }
}
