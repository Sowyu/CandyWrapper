import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The Issues page's list rules (4928 packages/client-runtime/src/issueList.ts, state/issues.ts,
/// issuePresentation.ts and apps/web/src/components/issue/issuePresentation.tsx).
public enum IssueListLogic {
    /// `issueListTargets` (5258 issuesSearch.logic.ts:76-105, 9fde959ac0 #38799): each environment leaves out
    /// its hidden projects, named from the saved keys so a listing sent before the project list loads still
    /// leaves them out. One with every project hidden is not read. `hidden` holds `environmentId:projectId` keys.
    public static func listTargets(environments: [String], projects: [(environmentId: String, projectId: String)],
                                   hidden: Set<String>) -> [(environmentId: String, excludeProjectIds: [String])] {
        environments.compactMap { env in
            let own = projects.filter { $0.environmentId == env }
            let key = { (p: (environmentId: String, projectId: String)) in EnvironmentScope.key(p.environmentId, p.projectId) }
            if !own.isEmpty, own.allSatisfy({ hidden.contains(key($0)) }) { return nil }
            let excluded = own.isEmpty
                ? hidden.sorted().compactMap { k in EnvironmentScope.environmentId(of: k) == env ? EnvironmentScope.localId(of: k) : nil }
                : own.filter { hidden.contains(key($0)) }.map(\.projectId)
            return (env, Array(excluded.prefix(IssueListInput.maxExcludedProjects)))
        }
    }

    /// A server older than `excludeProjectIds` still answers for hidden projects (5258 IssuesPage.tsx:282-319).
    public static func dropHidden(_ page: HeldPage, environmentId env: String, hidden: Set<String>) -> HeldPage {
        guard !hidden.isEmpty else { return page }
        var p = page
        let shows = { (projectId: String) in !hidden.contains(EnvironmentScope.key(env, projectId)) }
        p.entries = p.entries.filter { shows($0.projectId) }
        p.errors = p.errors.filter { shows($0.projectId) }
        p.answer.scopes = p.answer.scopes?.filter { shows($0.projectId) }
        return p
    }

    /// `PAGE_SIZE` (IssuesPage.tsx:132).
    public static let pageSize = 50
    /// `useDebouncedValue(search.q, 300)` (IssuesPage.tsx:212).
    public static let searchDebounce: Duration = .milliseconds(300)
    /// `LIVE_REFRESH_INTERVAL_MS` (hooks/useLiveRefresh.ts:5).
    public static let liveRefreshInterval: TimeInterval = 300

    /// A row with the environment it was read from (`EnvironmentIssueEntry`, issueList.ts:17-19).
    public struct Row: Equatable, Sendable {
        public var entry: IssueListEntry
        public var environmentId: String
        public init(entry: IssueListEntry, environmentId: String) { self.entry = entry; self.environmentId = environmentId }
        public var key: String { IssueListLogic.entryKey(entry) }
    }

    /// One environment's rows with continuation pages laid over them (`HeldIssuePage`, issueList.ts:22-35).
    public struct HeldPage: Equatable, Sendable {
        public var answer: IssueListResult
        public var entries: [IssueListEntry]
        public var errors: [IssueListProjectError]
        public var moreErrors: [(asked: [String], errors: [IssueListProjectError])]
        public var nextCursors: [String: String]
        public var moreFailure: String?

        public init(answer: IssueListResult) {
            self.answer = answer
            entries = answer.entries
            errors = answer.errors
            moreErrors = []
            nextCursors = answer.nextCursors
            moreFailure = nil
        }

        public static func == (a: HeldPage, b: HeldPage) -> Bool {
            a.answer == b.answer && a.entries == b.entries && a.errors == b.errors && a.nextCursors == b.nextCursors
                && a.moreFailure == b.moreFailure && a.moreErrors.map(\.asked) == b.moreErrors.map(\.asked)
                && a.moreErrors.map(\.errors) == b.moreErrors.map(\.errors)
        }
    }

    /// One tracker account's section (`groupIssues`, issueList.ts:118-178).
    public struct Group: Equatable, Sendable {
        public var tracker: IssueTrackerSummary
        public var rows: [Row] = []
        public var errors: [(projectTitle: String, message: String, environmentId: String)] = []
        /// Environments whose cursors carry this tracker's host on.
        public var more: [String] = []
        public init(tracker: IssueTrackerSummary) { self.tracker = tracker }
        public var key: String { IssueListLogic.trackerKey(tracker) }

        public static func == (a: Group, b: Group) -> Bool {
            a.tracker == b.tracker && a.rows == b.rows && a.more == b.more
                && a.errors.map { "\($0.environmentId)\u{0}\($0.projectTitle)\u{0}\($0.message)" }
                    == b.errors.map { "\($0.environmentId)\u{0}\($0.projectTitle)\u{0}\($0.message)" }
        }
    }

    /// `issueEntryKey` (state/issues.ts:35-39).
    public static func entryKey(_ e: IssueListEntry) -> String {
        "\(e.projectId)\u{0}\(e.host.lowercased())\u{0}\(e.scope.lowercased())\u{0}\(e.key)"
    }

    /// `issueTrackerKey` (issueList.ts:37-39).
    public static func trackerKey(_ t: IssueTrackerSummary) -> String { "\(t.tracker) \(t.host.lowercased())" }

    /// `mergeIssueListPage` (state/issues.ts:47-57): a repeated row takes the newer words.
    public static func mergePage(_ held: [IssueListEntry], _ page: [IssueListEntry]) -> [IssueListEntry] {
        if held.isEmpty { return page }
        if page.isEmpty { return held }
        var order: [String] = []
        var byKey: [String: IssueListEntry] = [:]
        for e in held + page {
            let k = entryKey(e)
            if byKey[k] == nil { order.append(k) }
            byKey[k] = e
        }
        return order.compactMap { byKey[$0] }.sorted { date($0.updatedAt) > date($1.updatedAt) }
    }

    /// `issueCursorsForHost` (issueList.ts:66-68).
    public static func cursors(_ cursors: [String: String], host: String) -> [String: String] {
        cursors.filter { $0.key.hasPrefix("\(host) ") }
    }

    public enum PageResult: Sendable { case page(IssueListResult), failure(String) }

    /// `continueIssuePage` (issueList.ts:75-95). A failure keeps the rows and says why.
    public static func continuePage(_ page: HeldPage, _ next: PageResult, asked: [String: String]) -> HeldPage {
        var out = page
        switch next {
        case .failure(let message):
            out.moreFailure = message
            return out
        case .page(let result):
            var moreErrors = page.moreErrors.filter { more in !more.asked.contains { asked[$0] != nil } }
            if !result.errors.isEmpty { moreErrors.append((Array(asked.keys).sorted(), result.errors)) }
            out.entries = mergePage(page.entries, result.entries)
            out.errors = page.answer.errors + moreErrors.flatMap(\.errors)
            out.moreErrors = moreErrors
            out.nextCursors = page.nextCursors.filter { asked[$0.key] == nil }.merging(result.nextCursors) { $1 }
            out.moreFailure = nil
            return out
        }
    }

    /// `groupIssues` (issueList.ts:118-178). `errorTracker` names the tracker key a project's
    /// repository is on, so its error lands in that section.
    public static func group(_ held: [(String, HeldPage)], query: String, sort: String,
                             errorTracker: (_ environmentId: String, _ projectId: String) -> String? = { _, _ in nil }) -> [Group] {
        var groups: [String: Group] = [:]
        var order: [String] = []
        var listed = Set<String>()
        let needle = query.lowercased()
        for (env, page) in held {
            for tracker in page.answer.trackers {
                let key = trackerKey(tracker)
                if groups[key] == nil { groups[key] = Group(tracker: tracker); order.append(key) }
                if !groups[key]!.tracker.configured && tracker.configured { groups[key]!.tracker = tracker }
                if page.nextCursors.keys.contains(where: { $0.hasPrefix("\(tracker.host) ") }) { groups[key]!.more.append(env) }
            }
            for entry in page.entries {
                let key = "\(entry.tracker) \(entry.host.lowercased())"
                guard let group = groups[key] else { continue }
                // A tracker that cannot search is narrowed here instead.
                if !needle.isEmpty, group.tracker.capabilities?.search != true,
                   !entry.title.lowercased().contains(needle), !entry.displayKey.lowercased().contains(needle) { continue }
                // Environments holding the same repository answer the same issue; the first keeps it (#38205).
                guard listed.insert(entry.url).inserted else { continue }
                groups[key]!.rows.append(Row(entry: entry, environmentId: env))
            }
            for error in page.errors {
                let key = errorTracker(env, error.projectId).flatMap { groups[$0] == nil ? nil : $0 } ?? order.first
                if let key { groups[key]!.errors.append((error.projectTitle, error.message, env)) }
            }
        }
        return order.compactMap { groups[$0] }.map { g in
            var g = g
            g.rows = g.rows.stableSorted { date(sort == "created" ? $0.entry.createdAt : $0.entry.updatedAt) > date(sort == "created" ? $1.entry.createdAt : $1.entry.updatedAt) }
            return g
        }.sorted { $0.key < $1.key }
    }

    /// The tracker menu (`hostOptionsFor`, IssuesPage.tsx:150-186): All, a remembered host no
    /// project is on any more, then one per host, a configured tracker winning.
    public struct HostOption: Equatable, Sendable {
        public var value: String
        public var label: String
        public var tracker: String?
        public var unavailable: String?
    }

    public static func hostOptions(_ trackers: [IssueTrackerSummary], chosen: String?) -> [HostOption] {
        var hosts: [String: IssueTrackerSummary] = [:]
        var order: [String] = []
        for t in trackers.sorted(by: { trackerKey($0) < trackerKey($1) }) {
            if let existing = hosts[t.host] {
                if !existing.configured && t.configured { hosts[t.host] = t }
            } else { hosts[t.host] = t; order.append(t.host) }
        }
        var out = [HostOption(value: "", label: "All", tracker: nil, unavailable: nil)]
        if let chosen, hosts[chosen] == nil { out.append(HostOption(value: chosen, label: chosen, tracker: nil, unavailable: nil)) }
        for host in order {
            let t = hosts[host]!
            let name = providerName(t.tracker)
            let label = hosts.count > 1 && name == t.host ? t.host : "\(name) (\(t.host))"
            out.append(HostOption(value: t.host, label: label, tracker: t.tracker,
                                  unavailable: t.configured ? nil : (t.detail ?? "Unavailable")))
        }
        return out
    }

    /// `issueTrackerPresentation` (issuePresentation.tsx:12-20): a git host wears its own name and
    /// mark, Linear its own, any other standalone tracker its kind and a ticket.
    public static func providerName(_ tracker: String) -> String {
        switch tracker {
        case "github": "GitHub"
        case "gitlab": "GitLab"
        case "azure-devops": "Azure DevOps"
        case "bitbucket": "Bitbucket"
        case "forgejo": "Forgejo"
        case "linear": "Linear"
        default: tracker
        }
    }

    @MainActor public static func trackerIcon(_ tracker: String) -> IconName {
        switch tracker {
        case "github", "gitlab", "forgejo": PullRequestStyle.providerIcon(tracker)
        case "linear": .brandLinear
        case "azure-devops", "bitbucket": .gitBranch
        default: .ticket
        }
    }

    /// `issueStatePresentation` (issuePresentation.tsx:28-50): open wears the open pull request's
    /// green, completed the merged violet, any other close the draft's grey.
    public enum Tone: Equatable, Sendable { case open, completed, notPlanned }

    public static func tone(_ s: IssueState) -> Tone {
        if s.category == "open" { return .open }
        if let r = s.closeReason, r != "completed" { return .notPlanned }
        return .completed
    }

    @MainActor public static func color(_ s: IssueState) -> NSColor {
        switch tone(s) {
        case .open: PullRequestStyle.color(.open)
        case .completed: PullRequestStyle.color(.merged)
        case .notPlanned: PullRequestStyle.color(.draft)
        }
    }

    @MainActor public static func icon(_ s: IssueState) -> IconName {
        switch tone(s) {
        case .open: .circleDot
        case .completed: .circleCheck
        case .notPlanned: .circleSlash
        }
    }

    /// `issueEventSentence` (client-runtime issuePresentation.ts).
    public static func eventSentence(_ e: IssueEvent) -> String {
        let d = e.detail
        switch e.kind {
        case "closed":
            guard let d else { return "closed this" }
            let words = d.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return "closed this as \(words.lowercased())"
        case "reopened": return "reopened this"
        case "labeled": return d.map { "added the \($0) label" } ?? "added a label"
        case "unlabeled": return d.map { "removed the \($0) label" } ?? "removed a label"
        case "assigned": return d.map { "assigned \($0)" } ?? "assigned someone"
        case "unassigned": return d.map { "unassigned \($0)" } ?? "unassigned someone"
        case "renamed": return d.map { "renamed this to “\($0)”" } ?? "renamed this"
        case "referenced": return d.map { "referenced this from \($0)" } ?? "referenced this"
        case "state-changed": return d.map { "moved this to \($0)" } ?? "changed the state"
        default: return e.kind
        }
    }

    /// `issueWriteAccess` (client-runtime issuePresentation.ts): the client's write scope, the issue
    /// being inside a project's scope, what the tracker can do and what it grants this account.
    public struct Access: Equatable, Sendable {
        public var blocked: String?
        public var comment = false
        public var edit = false
        public var labels = false
        public var assignees = false
        public var react = false
        /// The states the issue can move to; empty when the viewer may not move it.
        public var states: [IssueState] = []
    }

    public static func access(_ d: IssueDetail, canWrite: Bool) -> Access {
        var a = Access()
        a.blocked = !canWrite ? "Writing to this tracker needs the source-control write scope."
            : !d.writable ? "This issue is outside every project's own scope, so it is read-only here." : nil
        let open = a.blocked == nil
        a.comment = open && d.capabilities.comment && d.viewerPermissions.comment
        a.edit = open && d.capabilities.edit && d.viewerPermissions.edit
        a.labels = open && d.capabilities.labels && d.viewerPermissions.labels
        a.assignees = open && d.capabilities.assignees && d.viewerPermissions.assignees
        a.react = open && d.capabilities.reactions
        a.states = open && d.viewerPermissions.setState ? d.states.filter { $0.name != d.state.name } : []
        return a
    }

    /// The issue panel's Activity: comments and events by time (IssueDetailPanel.tsx:429-432).
    public enum TimelineItem: Equatable, Sendable {
        case comment(IssueComment)
        case event(IssueEvent)
        var at: String { switch self { case .comment(let c): c.createdAt; case .event(let e): e.createdAt } }
    }

    public static func timeline(comments: [IssueComment], events: [IssueEvent]) -> [TimelineItem] {
        let items = comments.map(TimelineItem.comment) + events.map(TimelineItem.event)
        // A stable sort: equal times keep comments before events, as JS `sort` keeps insertion order.
        return items.enumerated().sorted { l, r in
            let a = date(l.element.at), b = date(r.element.at)
            return a == b ? l.offset < r.offset : a < b
        }.map(\.element)
    }

    /// `prependIssueComments` (state/issues.ts:60-67): older pages go in front, once each.
    public static func prepend(_ current: [IssueComment], older: [IssueComment]) -> [IssueComment] {
        let seen = Set(current.map(\.id))
        return older.filter { !seen.contains($0.id) } + current
    }

    /// `Date.parse`: fractional seconds or not; an unreadable date sorts last.
    static func date(_ iso: String) -> Double {
        if let d = ISO8601DateFormatter.withFractionalSeconds.date(from: iso) { return d.timeIntervalSince1970 }
        return plain.date(from: iso)?.timeIntervalSince1970 ?? -.infinity
    }

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
}

/// `resolveIssueLinkTarget` (4928 client-runtime issueLinks.ts:118-170, #38294) for git-host links: a GitHub
/// `owner/repo/issues/N` or GitLab `group/repo/-/issues/N` link resolves through a project bound to that tracker and
/// host, its own scope first, else any such project lending its credentials. A lookalike host matches no project.
public enum IssueLinkLogic {
    public typealias Project = (id: String, identity: RepositoryIdentity?)

    private static let githubPath = try! NSRegularExpression(pattern: #"^/([^/]+/[^/]+)/issues/(\d+)(?:/|$)"#)
    private static let gitlabPath = try! NSRegularExpression(pattern: #"^/([^/]+(?:/[^/]+)+)/-/(?:issues|work_items)/(\d+)(?:/|$)"#)

    // ponytail: GitHub and GitLab links only; Linear and other standalone trackers need the environment's tracker bindings
    public static func target(url: String, projects: [Project]) -> IssueRef? {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http", let hostname = u.host?.lowercased() else { return nil }
        let authority = u.port.map { "\(hostname):\($0)" } ?? hostname
        let path = u.path.isEmpty ? "/" : u.path
        func parse(_ re: NSRegularExpression) -> (scope: String, key: String)? {
            guard let m = re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)), m.numberOfRanges >= 3,
                  let s = Range(m.range(at: 1), in: path), let k = Range(m.range(at: 2), in: path),
                  let n = Int(path[k]), n > 0 else { return nil }
            return (String(path[s]).lowercased(), String(n))
        }
        let bindings: [(project: Project, tracker: String, host: String, scope: String)] = projects.compactMap { p in
            guard let identity = p.identity, let kind = identity.provider, kind == "github" || kind == "gitlab",
                  let host = identity.pullRequestHost, let scope = identity.pullRequestRepository else { return nil }
            return (p, kind, host, scope.lowercased())
        }
        for kind in ["github", "gitlab"] {
            // GitHub's path reads only on github.com, or on a host a GitHub project vouches for.
            let onHost = bindings.filter { $0.tracker == kind && ($0.host == hostname || $0.host == authority) }
            if kind == "github", hostname != "github.com", onHost.isEmpty { continue }
            guard let link = parse(kind == "github" ? githubPath : gitlabPath) else { continue }
            let onAuthority = onHost.filter { $0.host == authority }
            let bound = onAuthority.isEmpty ? onHost : onAuthority
            let own = bound.first { $0.scope == link.scope }
            guard let lender = own ?? bound.first else { return nil }
            return IssueRef(projectId: lender.project.id, tracker: lender.tracker, host: lender.host,
                            scope: own == nil ? link.scope : lender.scope, key: link.key)
        }
        return nil
    }
}
