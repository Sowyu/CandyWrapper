import Foundation
import T3Protocol

/// One `agentSessions.scan` candidate on a computer (`AgentSessionProjectCandidate`, contracts agentSessions.ts:47-61).
public struct OnboardingProjectCandidate: Equatable, Sendable {
    /// `git`: missing on servers that predate the git scan (treated as a repository without an origin),
    /// null for a folder that is not a repository root.
    public enum Git: Equatable, Sendable { case unknown, none, repository(remoteKey: String?, name: String?) }

    public var environmentId: String
    public var path: String
    public var title: String
    public var projectId: String?
    public var sources: [String]
    public var threadCount: Int
    public var lastActiveAt: String?
    public var git: Git
    public var key: String { OnboardingProjectImport.key(environmentId, path) }

    public init(environmentId: String, path: String, title: String, projectId: String? = nil, sources: [String] = [],
                threadCount: Int = 0, lastActiveAt: String? = nil, git: Git = .unknown) {
        self.environmentId = environmentId; self.path = path; self.title = title; self.projectId = projectId
        self.sources = sources; self.threadCount = threadCount; self.lastActiveAt = lastActiveAt; self.git = git
    }

    public init?(environmentId: String, json: JSONValue) {
        guard let path = json["path"]?.stringValue else { return nil }
        let git: Git
        switch json["git"] {
        case nil: git = .unknown
        case .null?: git = .none
        case let value?: git = .repository(remoteKey: value["remoteKey"]?.stringValue, name: value["repository"]?.stringValue)
        }
        self.init(environmentId: environmentId, path: path, title: json["title"]?.stringValue ?? path,
                  projectId: json["projectId"]?.stringValue, sources: json["sources"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  threadCount: json["threadCount"]?.intValue ?? 0, lastActiveAt: json["lastActiveAt"]?.stringValue, git: git)
    }
}

/// apps/web/src/onboarding/projectImport.logic.ts and the import step's copy (WelcomeWizard.tsx:1192-1432).
public enum OnboardingProjectImport {
    public static let permissionMessage = "This connection cannot import projects or thread history."
    public static let scanLimitMessage = "Scan limit reached. Some projects or conversations may be missing."
    static let recentWindowMs: Int64 = 30 * 24 * 60 * 60 * 1000
    /// One or two threads in a directory is usually a one-off question, not a project.
    static let minimumThreads = 3

    /// `onboardingProjectKey`: paths identify projects only within the computer that owns them.
    public static func key(_ environmentId: String, _ path: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [environmentId, path], options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `partitionOnboardingProjects`: the default selection is repositories active in the last 30 days with
    /// at least three threads. Old servers without `git` count as repositories.
    public static func recent(_ candidates: [OnboardingProjectCandidate], nowMs: Int64) -> [OnboardingProjectCandidate] {
        candidates.filter { c in
            if c.git == .none || c.threadCount < minimumThreads { return false }
            guard let iso = c.lastActiveAt, let at = T3Timestamp.parseEpochMs(iso) else { return false }
            return at >= nowMs - recentWindowMs && at <= nowMs
        }
    }

    public struct Group: Equatable, Sendable {
        public var key: String
        /// GitHub `owner/name`, or the checkout's folder name when the origin is elsewhere.
        public var label: String
        public var repository: String?
        public var candidates: [OnboardingProjectCandidate]
        public var threadCount: Int
        public var lastActiveAt: String?
    }

    /// `groupOnboardingProjects`: clones of one origin share a group, repositories without one get a group
    /// each, plain folders come back separately. Groups sort newest activity first, then by label.
    public static func group(_ candidates: [OnboardingProjectCandidate]) -> (repositories: [Group], other: [OnboardingProjectCandidate]) {
        var order: [String] = []
        var groups: [String: Group] = [:]
        var other: [OnboardingProjectCandidate] = []
        for c in candidates {
            let remoteKey: String?, name: String?
            switch c.git {
            case .none: other.append(c); continue
            case .unknown: remoteKey = nil; name = nil
            case .repository(let r, let n): remoteKey = r; name = n
            }
            let key = remoteKey.map { "remote:" + $0 } ?? "path:" + c.path
            if var existing = groups[key] {
                existing.candidates.append(c)
                existing.threadCount += c.threadCount
                existing.lastActiveAt = latest(existing.lastActiveAt, c.lastActiveAt)
                groups[key] = existing
            } else {
                order.append(key)
                groups[key] = Group(key: key, label: name ?? c.title, repository: name, candidates: [c],
                                    threadCount: c.threadCount, lastActiveAt: c.lastActiveAt)
            }
        }
        let repositories = order.compactMap { groups[$0] }.sorted { l, r in
            if l.lastActiveAt == r.lastActiveAt { return l.label.localizedStandardCompare(r.label) == .orderedAscending }
            guard let la = l.lastActiveAt else { return false }
            guard let ra = r.lastActiveAt else { return true }
            return la > ra
        }
        return (repositories, other)
    }

    private static func latest(_ l: String?, _ r: String?) -> String? {
        guard let l else { return r }
        guard let r else { return l }
        return l > r ? l : r
    }

    /// `resolveOnboardingLandingProject`: a selected project with imported history, else a completed empty import.
    public static func landing<T>(_ selection: [String], withHistory: [String: T], completed: [String: T]) -> T? {
        for key in selection { if let p = withHistory[key] { return p } }
        for key in selection { if let p = completed[key] { return p } }
        return nil
    }

    /// The toast description when some history did not come across (WelcomeWizard.tsx:1420-1430).
    public static func warning(imported: Int, skipped: Int) -> String {
        func threads(_ n: Int) -> String { "\(n) \(n == 1 ? "thread" : "threads")" }
        if imported > 0 && skipped > 0 { return "Imported \(threads(imported)). \(threads(skipped)) could not be imported." }
        if skipped > 0 { return "\(skipped) \(skipped == 1 ? "thread could" : "threads could") not be imported." }
        if imported > 0 { return "Imported \(threads(imported)). Some thread history could not be imported." }
        return "Could not import thread history."
    }
}
