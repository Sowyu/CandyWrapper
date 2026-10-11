import Foundation

// A thread's linked pull requests: link identity, URL parsing and the one-slot views (badge,
// current link, stack chains). Ports packages/shared/src/threadPullRequests.ts,
// changeRequestUrl.ts and apps/web/src/pullRequestReference.ts.

/// `ThreadPullRequestKey` (threadPullRequest.ts:89-94): host, repository path and number.
public struct ThreadPullRequestKey: Hashable, Sendable {
    public var host: String
    public var repository: String
    public var number: Int
    public init(host: String, repository: String, number: Int) { self.host = host; self.repository = repository; self.number = number }

    /// `normalizeThreadPullRequestKey` without Forgejo ports: lower case, Azure paths canonical.
    public var normalized: ThreadPullRequestKey {
        let canonical = ChangeRequestURL.canonicalRepositoryKey("\(host.trimmingCharacters(in: .whitespaces).lowercased())/\(repository.trimmingCharacters(in: .whitespaces).lowercased())")
        guard let slash = canonical.firstIndex(of: "/") else { return self }
        return ThreadPullRequestKey(host: String(canonical[..<slash]), repository: String(canonical[canonical.index(after: slash)...]), number: number)
    }

    /// `threadPullRequestKeyOf`.
    public var id: String { let n = normalized; return "\(n.host)/\(n.repository)#\(n.number)" }
}

extension ThreadPullRequestLink {
    public var key: ThreadPullRequestKey { ThreadPullRequestKey(host: host, repository: repository, number: number) }
}

/// A change request named by its URL (`ChangeRequestLink`, changeRequestUrl.ts).
public enum ChangeRequestURL {
    public struct Link: Hashable, Sendable {
        public var host: String
        public var repository: String
        public var number: Int
        /// Forgejo's host and port.
        public var authority: String?
        public var key: ThreadPullRequestKey { ThreadPullRequestKey(host: host, repository: repository, number: number) }
    }

    /// `parseChangeRequestUrl`: the repository and number behind a change request URL on a host
    /// this can read, or nil for anything else.
    public static func parse(_ target: String) -> Link? {
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let rawHost = url.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.lowercased()
        let path = url.path
        func claim(_ pattern: String) -> Link? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
                  let r1 = Range(m.range(at: 1), in: path), let r2 = Range(m.range(at: 2), in: path),
                  let number = Int(path[r2]), number > 0 else { return nil }
            return Link(host: host, repository: path[r1].lowercased(), number: number)
        }
        func isHost(_ apex: String, label: String? = nil) -> Bool {
            host == apex || host.hasSuffix("." + apex) || (label.map { host.split(separator: ".").contains(Substring($0)) } ?? false)
        }
        if isHost("github.com", label: "github"), let link = claim(#"^/([^/]+/[^/]+)/pull/(\d+)(?:/|$)"#) { return link }
        if var link = claim(#"^/([^/]+(?:/[^/]+)+)/pulls/(\d+)(?:/|$)"#) {
            link.authority = url.port.map { "\(host):\($0)" } ?? host
            return link
        }
        if let link = claim(#"^/([^/]+(?:/[^/]+)+)/-/merge_requests/(\d+)(?:/|$)"#) { return link }
        if isHost("bitbucket.org", label: "bitbucket") { return claim(#"^/([^/]+/[^/]+)/pull-requests/(\d+)(?:/|$)"#) }
        if isHost("dev.azure.com") || host.hasSuffix(".visualstudio.com") { return claim(#"^/((?:[^/]+/)*_git/[^/]+)/pullrequest/(\d+)(?:/|$)"#) }
        return nil
    }

    /// `changeRequestUrlFor`: the web URL a host writes for a change request.
    public static func url(kind: String?, host: String, repository: String, number: Int) -> String? {
        switch kind {
        case "github": "https://\(host)/\(repository)/pull/\(number)"
        case "forgejo": "https://\(host)/\(repository)/pulls/\(number)"
        case "gitlab": "https://\(host)/\(repository)/-/merge_requests/\(number)"
        case "bitbucket": "https://\(host)/\(repository)/pull-requests/\(number)"
        case "azure-devops": "https://\(canonicalRepositoryKey("\(host)/\(repository)".lowercased()))/pullrequest/\(number)"
        default: nil
        }
    }

    /// `canonicalRepositoryKey` (shared/sourceControl.ts:302-312): Azure's older URL shapes.
    public static func canonicalRepositoryKey(_ key: String) -> String {
        var out = key
        for (pattern, template) in [(#"^(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)/v3/([^/]+)/([^/]+)/([^/]+)$"#, "dev.azure.com/$1/$2/_git/$3"),
                                    (#"^([^.]+)\.visualstudio\.com/(?:defaultcollection/)?([^/]+)/_git/([^/]+)$"#, "dev.azure.com/$1/$2/_git/$3")] {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// `parsePullRequestReference` (pullRequestReference.ts:41-79): a URL, `#123`, `123` or a
    /// checkout command, normalized to the URL or the bare number.
    public static func reference(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        func first(_ pattern: String, _ s: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        var normalized = trimmed
        if let arg = first(#"^tea\s+(?:pr|pulls)\s+checkout\s+(.+)$"#, trimmed) ?? first(#"^gh\s+pr\s+checkout\s+(.+)$"#, trimmed)
            ?? first(#"^glab\s+mr\s+checkout\s+(.+)$"#, trimmed) {
            normalized = arg.trimmingCharacters(in: .whitespaces)
        } else if let args = first(#"^az\s+repos\s+pr\s+checkout\s+(.+)$"#, trimmed) {
            let parts = args.split(whereSeparator: \.isWhitespace).map(String.init)
            var id: String?
            for (i, part) in parts.enumerated() {
                if part == "--id" || part == "-i" { id = i + 1 < parts.count ? parts[i + 1] : nil; break }
                if part.hasPrefix("--id=") { id = String(part.dropFirst(5)); break }
            }
            normalized = id ?? parts.first { !$0.hasPrefix("-") } ?? ""
        }
        guard !normalized.isEmpty else { return nil }
        let urlPatterns = [#"^https?://[^/\s]+/(?:[^/\s]+/)+[^/\s]+/pulls/(\d+)(?:[/?#].*)?$"#,
                           #"^https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+)(?:[/?#].*)?$"#,
                           #"^https://[^/\s]*gitlab[^/\s]*/.+/-/merge_requests/(\d+)(?:[/?#].*)?$"#,
                           #"^https://(?:dev\.azure\.com/[^/\s]+/[^/\s]+|[^/\s]+\.visualstudio\.com/[^/\s]+)/_git/[^/\s]+/pullrequest/(\d+)(?:[/?#].*)?$"#]
        if urlPatterns.contains(where: { first($0, normalized) != nil }) { return normalized }
        return first(#"^#?(\d+)$"#, normalized)
    }
}

/// The one-slot views of a thread's links (threadPullRequests.ts).
public enum ThreadPullRequests {
    /// `visibleThreadPullRequests`: tombstoned stack members stay hidden.
    public static func visible(_ links: [ThreadPullRequestLink]) -> [ThreadPullRequestLink] {
        links.filter { $0.source != .stackDismissed }
    }

    private static func isOpen(_ link: ThreadPullRequestLink) -> Bool { link.snapshot == nil || link.snapshot?.state == .open }

    private static func ms(_ t: T3Timestamp?) -> Double { t?.epochMs.map(Double.init) ?? 0 }
    /// The latest of a link's updates (`activityAt`, `latestUpdatedAt`).
    private static func activity(_ l: ThreadPullRequestLink) -> Double { ms(l.snapshot?.updatedAt ?? l.linkedAt) }
    private static func linkedMs(_ l: ThreadPullRequestLink) -> Double { ms(l.linkedAt) }

    public struct Chain: Sendable, Equatable {
        public var native: Bool
        /// Bottom to top.
        public var layers: [ThreadPullRequestLink]
    }

    /// `resolveThreadPullRequestChains`: native stacks first, then links chained base to head
    /// within one repository; a link that chains to nothing is its own chain.
    public static func chains(_ links: [ThreadPullRequestLink]) -> [Chain] {
        let shown = visible(links)
        var chains: [Chain] = []
        var placed = Set<String>()
        var nativeOrder: [String] = []
        var native: [String: [ThreadPullRequestLink]] = [:]
        for link in shown {
            guard let stack = link.stack else { continue }
            let n = link.key.normalized
            let k = "\(n.host)/\(n.repository)#stack:\(stack.id)"
            if native[k] == nil { nativeOrder.append(k) }
            native[k, default: []].append(link)
        }
        for k in nativeOrder {
            var members = native[k]!
            let order = Dictionary(members[0].stack!.layers.enumerated().map { ($0.element.number, $0.offset) }, uniquingKeysWith: { a, _ in a })
            members.sort { (order[$0.number] ?? 0) < (order[$1.number] ?? 0) }
            members.forEach { placed.insert($0.key.id) }
            chains.append(Chain(native: true, layers: members))
        }
        let remaining = shown.filter { !placed.contains($0.key.id) }
        func branchKey(_ link: ThreadPullRequestLink, _ branch: String) -> String {
            let n = link.key.normalized
            return "\(n.host)/\(n.repository):\(branch)"
        }
        // nil: a reused head name, which cannot name a parent.
        var byHead: [String: ThreadPullRequestLink?] = [:]
        for link in remaining {
            guard let snap = link.snapshot else { continue }
            let k = branchKey(link, snap.headBranch)
            byHead[k] = byHead[k] != nil ? .some(nil) : .some(link)
        }
        func parent(_ link: ThreadPullRequestLink) -> ThreadPullRequestLink? {
            guard let snap = link.snapshot, let entry = byHead[branchKey(link, snap.baseBranch)], let p = entry else { return nil }
            return p
        }
        var hasChild = Set<String>()
        for link in remaining { if let p = parent(link), p.key.id != link.key.id { hasChild.insert(p.key.id) } }
        for top in remaining where !hasChild.contains(top.key.id) {
            var layers: [ThreadPullRequestLink] = []
            var cursor: ThreadPullRequestLink? = top
            while let c = cursor, !placed.contains(c.key.id) {
                placed.insert(c.key.id)
                layers.insert(c, at: 0)
                cursor = parent(c)
            }
            if !layers.isEmpty { chains.append(Chain(native: false, layers: layers)) }
        }
        for link in remaining where !placed.contains(link.key.id) { chains.append(Chain(native: false, layers: [link])) }
        return chains
    }

    /// `resolveThreadCurrentPullRequestLink`: open work first, the top open layer of a chain;
    /// a finished chain points at its top, unrelated finished links at the latest updated.
    public static func current(_ links: [ThreadPullRequestLink]) -> ThreadPullRequestLink? {
        let shown = visible(links)
        guard !shown.isEmpty else { return nil }
        let open = shown.filter(isOpen)
        if open.count == 1 { return open[0] }
        let all = chains(shown)
        if open.count > 1 {
            let openChains: [[ThreadPullRequestLink]] = all.map { Array($0.layers.reversed().filter(isOpen)) }.filter { !$0.isEmpty }
            let newest = openChains.max { a, b in (a.map(linkedMs).max() ?? 0) < (b.map(linkedMs).max() ?? 0) }
            return newest?.first
        }
        if all.count == 1 { return all[0].layers.last }
        return shown.max { activity($0) < activity($1) }
    }

    /// `ThreadPullRequestBadge` (threadPullRequests.ts:281-309).
    public struct Badge: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case stack(layers: Int), pullRequest(others: Int) }
        public var kind: Kind
        /// open, closed, merged or draft.
        public var state: String
    }

    public static func badge(_ links: [ThreadPullRequestLink]?) -> Badge? {
        let shown = visible(links ?? [])
        guard !shown.isEmpty else { return nil }
        let states = shown.map { $0.snapshot?.state.rawValue ?? "open" }
        let state = shown.allSatisfy({ $0.snapshot?.state == .open && $0.snapshot?.isDraft == true }) ? "draft"
            : states.contains("open") ? "open" : states.allSatisfy({ $0 == "merged" }) ? "merged" : "closed"
        if shown.count > 1 && chains(shown).count == 1 { return Badge(kind: .stack(layers: shown.count), state: state) }
        return Badge(kind: .pullRequest(others: shown.count - 1), state: state)
    }

    /// One line of a thread's pull request list (`pullRequestListLines`): newest chain first, each
    /// read bottom to top with its depth.
    public struct Line: Equatable, Sendable {
        public var link: ThreadPullRequestLink
        public var depth: Int
        public var stackSize: Int?
        /// A host's native stack ("stack") rather than a base-branch chain ("chain").
        public var native = false
    }

    public static func lines(_ links: [ThreadPullRequestLink]) -> [Line] {
        let ordered = chains(links).enumerated().sorted { a, b in
            let l = a.element.layers.map(activity).max() ?? 0, r = b.element.layers.map(activity).max() ?? 0
            return l != r ? l > r : a.offset < b.offset
        }.map(\.element)
        return ordered.flatMap { chain in
            chain.layers.enumerated().map { Line(link: $0.element, depth: $0.offset, stackSize: $0.offset == 0 && chain.layers.count > 1 ? chain.layers.count : nil,
                                                 native: chain.native) }
        }
    }

    /// `threadPullRequestLinkMode`: `multiple` with `threadPullRequests`, `single` with
    /// `threadPullRequestLinking`, else nil.
    public static func linkMode(multiple: Bool, single: Bool) -> String? { multiple ? "multiple" : single ? "single" : nil }
}
