import Foundation
import T3Protocol

/// The Pull Requests page's list logic (apps/web/src/components/pullRequest/pullRequestList.logic.ts
/// and the route's own constants, routes/_chat.pull-requests.tsx:210-276).
public enum PullRequestListLogic {
    /// Final rows stay cached during a timed or activation refresh. The user also requests closed
    /// PRs here; T3 3234 only skips merged PRs (#19374). Explicit refresh does not use this filter.
    public static func periodicRefreshState(_ state: String) -> String? {
        switch state {
        case "closed", "merged": nil
        case "all": "open"
        default: state
        }
    }

    public typealias Entry = PullRequestListEntry

    /// `PullRequestGroupKey`, in display order.
    public enum GroupKey: String, Sendable { case authored, reviewRequested, others }

    public struct Group: Equatable, Sendable {
        public var key: GroupKey
        public var label: String
        public var entries: [Entry]
        public init(key: GroupKey, label: String, entries: [Entry]) { self.key = key; self.label = label; self.entries = entries }
    }

    static let groupLabels: [GroupKey: String] = [.reviewRequested: "Review requested", .authored: "Authored", .others: "Others"]

    /// The page's page size: one host page, since every provider asks for one more row as its
    /// "is there more" probe (`PAGE_SIZE`).
    public static let pageSize = 99
    public static let maxPageSize = 500
    /// `SEARCH_DEBOUNCE_MS`.
    public static let searchDebounce: Duration = .milliseconds(250)
    /// What `score` gives a row none of whose fields carry the search (`MATCHED_ELSEWHERE_SCORE`).
    public static let matchedElsewhereScore = 10

    public struct Option: Equatable, Sendable {
        public var value: String
        public var label: String
        public var icon: String
    }

    /// `INVOLVEMENT_TABS`, `STATE_TABS`, `SORT_OPTIONS` (icons by lucide name).
    public static let involvementOptions = [Option(value: "all", label: "All", icon: "layers"),
                                            Option(value: "reviewing", label: "Reviewing", icon: "eye"),
                                            Option(value: "authored", label: "Authored", icon: "pen-line")]
    public static let stateOptions = [Option(value: "all", label: "All", icon: "layers"),
                                      Option(value: "open", label: "Open", icon: "git-pull-request-arrow"),
                                      Option(value: "closed", label: "Closed", icon: "git-pull-request-closed"),
                                      Option(value: "merged", label: "Merged", icon: "git-merge")]
    public static let sortOptions = [Option(value: "ready", label: "Merge readiness", icon: "list-checks"),
                                     Option(value: "blocked", label: "Blocked on me", icon: "user-lock"),
                                     Option(value: "updated", label: "Recently updated", icon: "clock"),
                                     Option(value: "newest", label: "Newest shown", icon: "calendar-arrow-down"),
                                     Option(value: "oldest", label: "Oldest shown", icon: "calendar-arrow-up"),
                                     Option(value: "largest", label: "Largest shown", icon: "maximize-2"),
                                     Option(value: "smallest", label: "Smallest shown", icon: "minimize-2")]
    /// The filter menu's narrowing options (PullRequestListFilters.tsx:136-155).
    public static let draftOptions = [Option(value: "all", label: "All", icon: "layers"),
                                      Option(value: "only", label: "Drafts only", icon: "git-pull-request-draft"),
                                      Option(value: "hide", label: "Hide drafts", icon: "eye-off")]
    public static let reviewOptions = [Option(value: "all", label: "All", icon: "layers"),
                                       Option(value: "approved", label: "Approved", icon: "circle-check"),
                                       Option(value: "changes-requested", label: "Changes requested", icon: "circle-x"),
                                       Option(value: "review-required", label: "Review required", icon: "circle-dashed"),
                                       Option(value: "none", label: "No reviews", icon: "circle-slash")]
    public static let checksOptions = [Option(value: "all", label: "All", icon: "layers"),
                                       Option(value: "passing", label: "Passing", icon: "circle-check"),
                                       Option(value: "failing", label: "Failing", icon: "circle-x")]

    static func normalize(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return t.isEmpty ? nil : t
    }

    /// `pullRequestLabelColor`: a usable six digit hex, or nil.
    public static func labelColor(_ color: String?) -> String? {
        var hex = color?.trimmingCharacters(in: .whitespaces) ?? ""
        if hex.hasPrefix("#") { hex.removeFirst() }
        return hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? "#" + hex : nil
    }

    /// `pullRequestEntryKey`: environment, host, repository and number.
    public static func key(_ e: Entry) -> String {
        "\(e.environmentId.map { $0 + ":" } ?? "")\(e.host):\(e.repository)#\(e.number)"
    }

    /// `pullRequestEntryViewer`: the signed-in login for the row's host.
    public static func viewer(_ e: Entry, _ viewers: [String: String]) -> String? {
        normalize(viewers["\(e.environmentId ?? "") \(e.host)"] ?? viewers[e.host])
    }

    static func isAuthoredByViewer(_ e: Entry, _ viewers: [String: String]) -> Bool {
        guard let v = viewer(e, viewers) else { return false }
        return normalize(e.author?.login) == v
    }

    // MARK: Query

    static let reviewValues: [String: String] = ["approved": "approved", "changes_requested": "changes-requested",
                                                 "changes-requested": "changes-requested", "required": "review-required",
                                                 "review-required": "review-required", "none": "none"]
    static let checksValues: [String: String] = ["success": "passing", "passing": "passing", "failure": "failing", "failing": "failing"]

    static func qualifierValue(_ raw: String) -> String { raw.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces) }

    static func splitQualifierList(_ raw: String) -> [String] {
        if raw.range(of: #"^\s*"[^"]*"\s*$"#, options: .regularExpression) != nil {
            let whole = qualifierValue(raw)
            return whole.isEmpty ? [] : [whole]
        }
        return raw.split(separator: ",", omittingEmptySubsequences: false).map { qualifierValue(String($0)) }.filter { !$0.isEmpty }
    }

    static func boundedNames(_ names: [String]) -> [String] {
        names.prefix(10).map { String($0.prefix(200)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Compiled once: `parseQuery` runs on every keystroke in the search field.
    private static let tokenRegex = try! NSRegularExpression(pattern: #"(?:[^\s"]|"[^"]*")+"#)
    private static let qualifierRegex = try! NSRegularExpression(pattern: #"^(-?)([A-Za-z][A-Za-z0-9_-]*):(.*)$"#, options: [.dotMatchesLineSeparators])

    /// `parsePullRequestQuery`: GitHub style qualifiers (`label:`, `-label:`, `author:`, `draft:`,
    /// `review:`, `status:`/`checks:`, and an unknown `key:value` as a namespaced label) split from
    /// the text that is left.
    public static func parseQuery(_ raw: String) -> (text: String, filters: PullRequestListFilters) {
        var text: [String] = []
        var labels: [[String]] = []
        var excluded: [String] = []
        var filters = PullRequestListFilters()
        for m in tokenRegex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            let token = String(raw[Range(m.range, in: raw)!])
            let q = qualifierRegex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token))
            func group(_ i: Int) -> String { q.flatMap { Range($0.range(at: i), in: token) }.map { String(token[$0]) } ?? "" }
            let rawValue = group(3)
            let value = q == nil ? "" : qualifierValue(rawValue)
            let negated = group(1) == "-"
            let key = value.isEmpty ? "" : group(2).lowercased()
            var consumed = false
            switch key {
            case "label":
                let names = boundedNames(splitQualifierList(rawValue))
                if !names.isEmpty { if negated { excluded += names } else { labels.append(names) }; consumed = true }
            case "author":
                if !negated { filters.author = String(value.prefix(200)).trimmingCharacters(in: .whitespaces); consumed = true }
            case "draft":
                let v = value.lowercased()
                if !negated, v == "true" || v == "false" { filters.draft = v == "true" ? "only" : "hide"; consumed = true }
            case "review":
                if !negated, let d = reviewValues[value.lowercased()] { filters.review = d; consumed = true }
            case "status", "checks":
                if !negated, let s = checksValues[value.lowercased()] { filters.checks = s; consumed = true }
            case "":
                break
            default:
                if !value.hasPrefix("/") {
                    let names = boundedNames(splitQualifierList(rawValue).map { $0.contains(":") ? $0 : "\(group(2)):\($0)" })
                    if !names.isEmpty { if negated { excluded += names } else { labels.append(names) }; consumed = true }
                }
            }
            if !consumed { text.append(token) }
        }
        if !labels.isEmpty { filters.labels = Array(labels.prefix(10)) }
        if !excluded.isEmpty { filters.excludedLabels = Array(excluded.prefix(10)) }
        return (text.joined(separator: " "), filters)
    }

    /// `matchesPullRequestQuery`: the fields a row shows, plus `#123`.
    public static func matchesQuery(_ e: Entry, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return "#\(e.number) \(e.title) \(e.repository) \(e.headBranch) \(e.author?.login ?? "")".lowercased().contains(q)
    }

    /// `filterPullRequestsByInvolvement`.
    public static func filterByInvolvement(_ entries: [Entry], viewers: [String: String], involvement: String) -> [Entry] {
        switch involvement {
        case "reviewing": entries.filter(\.viewerReviewRequested)
        case "authored": entries.filter { isAuthoredByViewer($0, viewers) }
        default: entries
        }
    }

    /// `narrowPullRequestsToFilters`: rows held for an earlier question, narrowed to the new one.
    public static func narrow(_ entries: [Entry], state: String, projectId: String?, host: String?) -> [Entry] {
        entries.filter { (state == "all" || $0.state == state) && (projectId == nil || $0.projectId == projectId) && (host == nil || $0.host == host) }
    }

    /// `resolvePullRequestAuthorFilter` (pullRequest.ts:1345): `me` and `@me` name the viewer.
    public static func resolveAuthor(_ author: String, viewer: String?) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^@?me$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return trimmed }
        guard let viewer, !viewer.trimmingCharacters(in: .whitespaces).isEmpty else { return trimmed }
        return viewer
    }

    /// `matchesPullRequestFilters`: the narrowings a row can be judged by itself (no checks).
    public static func matchesFilters(_ e: Entry, _ f: PullRequestListFilters, viewer: String? = nil) -> Bool {
        let labels = e.labels.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        func holds(_ l: String) -> Bool { labels.contains(l.trimmingCharacters(in: .whitespaces).lowercased()) }
        if let d = f.draft, e.isDraft != (d == "only") { return false }
        if let r = f.review { if r == "none" ? e.reviewDecision != nil : e.reviewDecision != r { return false } }
        if let groups = f.labels, !groups.allSatisfy({ $0.contains(where: holds) }) { return false }
        if let ex = f.excludedLabels, ex.contains(where: holds) { return false }
        if let a = f.author, e.author?.login.lowercased() != resolveAuthor(a, viewer: viewer).lowercased() { return false }
        return true
    }

    /// `groupPullRequestsByInvolvement`: Authored, Review requested, Others, empty groups dropped.
    public static func groupByInvolvement(_ entries: [Entry], viewers: [String: String]) -> [Group] {
        var buckets: [GroupKey: [Entry]] = [.authored: [], .reviewRequested: [], .others: []]
        for e in entries {
            if isAuthoredByViewer(e, viewers) { buckets[.authored]!.append(e) }
            else if e.viewerReviewRequested { buckets[.reviewRequested]!.append(e) }
            else { buckets[.others]!.append(e) }
        }
        return [GroupKey.authored, .reviewRequested, .others].compactMap { k in
            buckets[k]!.isEmpty ? nil : Group(key: k, label: groupLabels[k]!, entries: buckets[k]!)
        }
    }

    /// `partitionPullRequestsWithPriority`: Authored and Review requested from their own complete
    /// reads, the feed fills Others; the feed's copy of a partitioned row replaces it in place.
    public static func partition(_ entries: [Entry], authored: [Entry], reviewRequested: [Entry]) -> [Group] {
        var authoredOrder = authored.map(key)
        var authoredByKey = Dictionary(authored.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        authoredOrder = authoredOrder.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var reviewOrder: [String] = []
        var reviewByKey: [String: Entry] = [:]
        for e in reviewRequested where authoredByKey[key(e)] == nil && reviewByKey[key(e)] == nil {
            reviewOrder.append(key(e)); reviewByKey[key(e)] = e
        }
        var others: [Entry] = []
        for e in entries {
            let k = key(e)
            if authoredByKey[k] != nil { authoredByKey[k] = e } else if reviewByKey[k] != nil { reviewByKey[k] = e } else { others.append(e) }
        }
        let byRecency: (Entry, Entry) -> Bool = { $0.updatedAt > $1.updatedAt }
        let groups: [(GroupKey, [Entry])] = [(.authored, authoredOrder.map { authoredByKey[$0]! }.stableSorted(by: byRecency)),
                                             (.reviewRequested, reviewOrder.map { reviewByKey[$0]! }.stableSorted(by: byRecency)),
                                             (.others, others)]
        return groups.filter { !$0.1.isEmpty }.map { Group(key: $0.0, label: groupLabels[$0.0]!, entries: $0.1) }
    }

    // MARK: Ranking

    /// `scorePullRequestMatch`: 100 for the number asked for, 90 title equal, 80 title contains,
    /// 70 every word in the title, 60 branch, 50 author, 40 repository, 30 any word, 10 the host
    /// matched something the row does not show.
    public static func score(_ e: Entry, _ query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        let number = needle.hasPrefix("#") ? String(needle.dropFirst()) : needle
        if !number.isEmpty, number.allSatisfy { $0.isASCII && $0.isNumber } { return String(e.number) == number ? 100 : 0 }
        let title = e.title.lowercased()
        let terms = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        if title == needle { return 90 }
        if title.contains(needle) { return 80 }
        if terms.count > 1, terms.allSatisfy({ title.contains($0) }) { return 70 }
        if e.headBranch.lowercased().contains(needle) { return 60 }
        if (e.author?.login ?? "").lowercased().contains(needle) { return 50 }
        if e.repository.lowercased().contains(needle) { return 40 }
        if terms.contains(where: { title.contains($0) }) { return 30 }
        return 10
    }

    /// `rankPullRequestMatches`: by score, then recency; no search keeps the host's order.
    public static func rank(_ entries: [Entry], _ query: String) -> [Entry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return entries }
        return entries.stableSorted { l, r in
            let a = score(l, query), b = score(r, query)
            return a != b ? a > b : l.updatedAt > r.updatedAt
        }
    }

    public static func measured(_ e: Entry) -> Bool { e.additions + e.deletions > 0 }

    /// `rankPullRequestsByMergeReadiness`: green and approved, green, the rest open, finished,
    /// conflicting last; smaller measured diffs first, then recency.
    public static func rankByMergeReadiness(_ entries: [Entry], hasMeasuredSize: (Entry) -> Bool = measured) -> [Entry] {
        func tier(_ e: Entry) -> Int {
            if e.mergeability == "conflicting" { return 4 }
            if e.state != "open" { return 3 }
            if e.isDraft { return 2 }
            if e.checksState == "passing" && e.reviewDecision == "approved" { return 0 }
            if e.checksState == "passing" { return 1 }
            return 2
        }
        return entries.stableSorted { l, r in
            if tier(l) != tier(r) { return tier(l) < tier(r) }
            let ml = hasMeasuredSize(l), mr = hasMeasuredSize(r)
            if ml != mr { return ml }
            let sl = l.additions + l.deletions, sr = r.additions + r.deletions
            if sl != sr { return sl < sr }
            return l.updatedAt > r.updatedAt
        }
    }

    static func epoch(_ iso: String) -> Double? { T3Timestamp(iso).epochMs.map(Double.init) }

    static func rankByTierThenRecency(_ entries: [Entry], tier: (Entry) -> Int) -> [Entry] {
        entries.stableSorted { l, r in
            if tier(l) != tier(r) { return tier(l) < tier(r) }
            let a = epoch(l.updatedAt), b = epoch(r.updatedAt)
            switch (a, b) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?): return a > b
            }
        }
    }

    /// `rankPullRequestsBlockedOnAuthor`: conflicts, changes requested, failing, drafts, waiting, ready.
    public static func rankBlockedOnAuthor(_ entries: [Entry]) -> [Entry] {
        rankByTierThenRecency(entries) { e in
            if e.state != "open" { return 6 }
            if e.mergeability == "conflicting" { return 0 }
            if e.reviewDecision == "changes-requested" { return 1 }
            if e.checksState == "failing" { return 2 }
            if e.isDraft { return 3 }
            if e.checksState == "passing" && e.reviewDecision == "approved" { return 5 }
            return 4
        }
    }

    public static func rankBlockedOnReviewer(_ entries: [Entry]) -> [Entry] {
        rankByTierThenRecency(entries) { $0.state == "open" ? 0 : 1 }
    }

    /// `sortPullRequestGroups`: the chosen order inside every group; authored work stays first.
    public static func sortGroups(_ groups: [Group], sort: String, searchText: String, involvement: String = "all",
                                  hasMeasuredSize: (Entry) -> Bool = measured) -> [Group] {
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        func within(_ rank: ([Entry]) -> [Entry]) -> [Group] { groups.map { var g = $0; g.entries = rank(g.entries); return g } }
        switch sort {
        case "ready": return searching ? groups : within { rankByMergeReadiness($0, hasMeasuredSize: hasMeasuredSize) }
        case "blocked":
            if searching { return groups }
            return groups.map { g in
                let role = g.key == .others ? involvement : g.key == .authored ? "authored" : "reviewing"
                guard role != "all" else { return g }
                var out = g
                out.entries = role == "authored" ? rankBlockedOnAuthor(g.entries) : rankBlockedOnReviewer(g.entries)
                return out
            }
        case "updated": return groups
        default:
            func ts(_ e: Entry) -> Double { epoch(e.updatedAt) ?? epoch(e.createdAt) ?? 0 }
            return within { entries in
                entries.stableSorted { l, r in
                    if sort == "newest" || sort == "oldest" {
                        let a = epoch(l.createdAt), b = epoch(r.createdAt)
                        if (a != nil) != (b != nil) { return a != nil }
                        let dated = (a ?? 0) - (b ?? 0)
                        if dated != 0 { return sort == "newest" ? dated > 0 : dated < 0 }
                        return ts(l) > ts(r)
                    }
                    let ml = hasMeasuredSize(l), mr = hasMeasuredSize(r)
                    if ml != mr { return ml }
                    let sized = (l.additions + l.deletions) - (r.additions + r.deletions)
                    if sized != 0 { return sort == "largest" ? sized > 0 : sized < 0 }
                    return ts(l) > ts(r)
                }
            }
        }
    }

    // MARK: Facets

    public struct AuthorFacet: Equatable, Sendable {
        public var actor: PullRequestActor
        public var count: Int
        public var mergedCount: Int
    }

    public struct LabelFacet: Equatable, Sendable {
        public var name: String
        public var color: String?
        public var count: Int
    }

    /// `collectPullRequestListFacets`: the authors and labels the filter menu offers.
    public static func facets(_ entries: [Entry], state: String) -> (authors: [AuthorFacet], labels: [LabelFacet]) {
        var authors: [String: AuthorFacet] = [:]
        var labels: [String: LabelFacet] = [:]
        var seen = Set<String>()
        for e in entries where seen.insert(key(e)).inserted {
            let inState = state == "all" || e.state == state
            if let a = e.author, let k = normalize(a.login) {
                let held = authors[k]
                authors[k] = AuthorFacet(actor: held?.actor ?? a, count: (held?.count ?? 0) + (inState ? 1 : 0),
                                         mergedCount: (held?.mergedCount ?? 0) + (e.state == "merged" ? 1 : 0))
            }
            guard inState else { continue }
            for l in e.labels {
                guard let k = normalize(l.name) else { continue }
                let held = labels[k]
                labels[k] = LabelFacet(name: held?.name ?? l.name, color: held?.color ?? l.color, count: (held?.count ?? 0) + 1)
            }
        }
        let a = authors.values.filter { $0.count > 0 }.sorted {
            $0.mergedCount != $1.mergedCount ? $0.mergedCount > $1.mergedCount
                : $0.count != $1.count ? $0.count > $1.count : $0.actor.login < $1.actor.login
        }
        let l = labels.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return (a, l)
    }

    // MARK: Overrides

    /// `PullRequestListOverride`: what a row says the moment an action is sent.
    public struct Override: Equatable, Sendable {
        public var state: String
        public var isDraft: Bool?
        public var updatedAt: String
        public var token: Int
        public var at: Double
    }

    /// `pullRequestOverrideAfterAction`.
    public static func override(after action: String, entry: Entry, now: Date, token: Int) -> Override? {
        let stamp = ISO8601DateFormatter.withFractionalSeconds.string(from: now)
        let at = now.timeIntervalSince1970 * 1000
        switch action {
        case "close": return Override(state: "closed", updatedAt: stamp, token: token, at: at)
        case "reopen": return Override(state: "open", updatedAt: stamp, token: token, at: at)
        case "merge": return Override(state: "merged", updatedAt: stamp, token: token, at: at)
        case "draft": return Override(state: entry.state, isDraft: true, updatedAt: stamp, token: token, at: at)
        case "ready": return Override(state: entry.state, isDraft: false, updatedAt: stamp, token: token, at: at)
        default: return nil
        }
    }

    /// `applyPullRequestOverrides`: pending answers written over rows; rows the state filter no
    /// longer holds dropped.
    public static func apply(_ overrides: [String: Override], to entries: [Entry], state: String) -> [Entry] {
        guard !overrides.isEmpty || state != "all" else { return entries }
        return entries.compactMap { e in
            let o = overrides[key(e)]
            if state != "all", (o?.state ?? e.state) != state { return nil }
            guard let o else { return e }
            var out = e
            out.state = o.state
            if let d = o.isDraft { out.isDraft = d }
            out.updatedAt = o.updatedAt
            return out
        }
    }

    /// `settlePullRequestOverrides`: an override stays until an answer agrees with it, or for a
    /// minute against one that does not.
    public static func settle(_ overrides: [String: Override], answered: [Entry], now: Double) -> [String: Override] {
        guard !overrides.isEmpty else { return overrides }
        let byKey = Dictionary(answered.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        return overrides.filter { k, o in
            guard let row = byKey[k] else { return true }
            let agrees = row.state == o.state && (o.isDraft == nil || row.isDraft == o.isDraft)
            return !agrees && now - o.at <= 60_000
        }
    }

    /// `pullRequestHostLabel` (PullRequestListFilters.tsx:93-101): the provider's name, or the host
    /// where two hosts share a kind.
    public static func hostLabel(_ hosts: [(host: String, kind: String)], _ entry: (host: String, kind: String)) -> String {
        hosts.filter { $0.kind == entry.kind }.count > 1 ? entry.host : providerName(entry.kind)
    }

    /// `pullRequestHostActions` (2994 pullRequestList.logic.ts:1268-1290): each host's reported actions, by
    /// lowercased host. Hosts that report none, as on 2861 servers, are left out.
    public static func hostActions(_ providers: [PullRequestProviderSummary]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for p in providers { if let actions = p.actions { out[p.host.lowercased()] = Set(actions) } }
        return out
    }

    /// `pullRequestQuickActions` (2994 pullRequestList.logic.ts:1293-1306): what the row's state allows, narrowed
    /// to what its host can do. A host that reports nothing keeps what it always got: GitHub all four, others none.
    public static func quickActions(state: String, isDraft: Bool, host: String, provider: String, byHost: [String: Set<String>]) -> [String] {
        let can = byHost[host.lowercased()] ?? (provider == "github" ? ["close", "merge", "ready", "reopen"] : [])
        let forState: [String] = state == "merged" ? [] : state == "closed" ? ["reopen"] : isDraft ? ["close", "ready"] : ["close", "merge"]
        return forState.filter(can.contains)
    }

    /// `getSourceControlPresentationForKind(kind).providerName`.
    public static func providerName(_ kind: String) -> String {
        switch kind {
        case "github": "GitHub"
        case "gitlab": "GitLab"
        case "bitbucket": "Bitbucket"
        case "azure-devops": "Azure DevOps"
        case "forgejo": "Forgejo"
        default: "Source control"
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension Array {
    /// `Array.prototype.toSorted` is stable; Swift's `sorted` is not guaranteed to be.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
