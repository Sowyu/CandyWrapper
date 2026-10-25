import Foundation

/// `OrchestrationV2ShellSnapshot` (orchestrationV2.ts:1931-1942). The archived shell snapshot
/// has no `archivedThreads` key, so it decodes to `[]`.
public struct ShellSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var snapshotSequence: Int
    public var threads: [ThreadShell]
    public var archivedThreads: [ThreadShell]
    public var projects: [ProjectShell]
    public var olderSettled: OlderSettledThreads?
    /// Client cache metadata. A new connection always replaces this cached shell before resuming.
    public var omissions: ShellOmissions?
    /// Per-environment cuts on a merged display shell. Never written to the environment cache.
    public var olderSettledByEnvironment: [String: OlderSettledThreads] = [:]
    public var partialEnvironmentIds: Set<String> = []

    public init(
        schemaVersion: Int, snapshotSequence: Int, threads: [ThreadShell] = [],
        archivedThreads: [ThreadShell] = [], projects: [ProjectShell] = [],
        olderSettled: OlderSettledThreads? = nil, omissions: ShellOmissions? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotSequence = snapshotSequence
        self.threads = threads
        self.archivedThreads = archivedThreads
        self.projects = projects
        self.olderSettled = olderSettled
        self.omissions = omissions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshotSequence, threads, archivedThreads, projects, olderSettled, omissions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        snapshotSequence = try c.decode(Int.self, forKey: .snapshotSequence)
        threads = try c.decode([ThreadShell].self, forKey: .threads)
        archivedThreads = try c.decodeIfPresent([ThreadShell].self, forKey: .archivedThreads) ?? []
        projects = try c.decodeIfPresent([ProjectShell].self, forKey: .projects) ?? []
        olderSettled = try c.decodeIfPresent(OlderSettledThreads.self, forKey: .olderSettled)
        omissions = try c.decodeIfPresent(ShellOmissions.self, forKey: .omissions)
    }
}

/// T3 e57c093cdd, orchestrationV2.ts:2027-2031,3464-3492.
public struct OlderSettledThreads: Codable, Hashable, Sendable {
    public struct Count: Codable, Hashable, Sendable {
        public var projectId: ProjectId
        public var count: Int
        public init(projectId: ProjectId, count: Int) { self.projectId = projectId; self.count = count }
    }
    public var before: String
    public var asOfSequence: Int
    public var counts: [Count]
    public init(before: String, asOfSequence: Int, counts: [Count]) {
        self.before = before; self.asOfSequence = asOfSequence; self.counts = counts
    }
}

public struct OlderSettledCursor: Codable, Hashable, Sendable {
    public var settledAt: String
    public var threadId: ThreadId?
    public init(settledAt: String, threadId: ThreadId? = nil) { self.settledAt = settledAt; self.threadId = threadId }
}

public struct ShellThreadRead: Codable, Hashable, Sendable {
    public var snapshotSequence: Int
    public var threads: [ThreadShell]
    public init(snapshotSequence: Int, threads: [ThreadShell]) { self.snapshotSequence = snapshotSequence; self.threads = threads }
}

public struct OlderSettledPage: Codable, Hashable, Sendable {
    public var snapshotSequence: Int
    public var threads: [ThreadShell]
    public var counts: [OlderSettledThreads.Count]
    public init(snapshotSequence: Int, threads: [ThreadShell], counts: [OlderSettledThreads.Count] = []) {
        self.snapshotSequence = snapshotSequence; self.threads = threads; self.counts = counts
    }
}

/// Config flags are top-level, not environment capabilities (T3 server.ts:596-611).
public struct ShellOmissions: Codable, Hashable, Sendable {
    public var omitIdleSubagents: Bool
    public var omitOlderSettled: Bool
    public init(omitIdleSubagents: Bool = false, omitOlderSettled: Bool = false) {
        self.omitIdleSubagents = omitIdleSubagents
        self.omitOlderSettled = omitOlderSettled && omitIdleSubagents
    }
    public init(config: JSONValue) {
        self.init(omitIdleSubagents: config["shellThreadFamilies"]?.boolValue == true,
                  omitOlderSettled: config["shellOlderSettled"]?.boolValue == true)
    }
    public var isPartial: Bool { omitIdleSubagents || omitOlderSettled }
    public var payload: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        if omitIdleSubagents { result["omitIdleSubagents"] = .bool(true) }
        if omitOlderSettled { result["omitOlderSettled"] = .bool(true) }
        return result
    }
    public var snapshotPath: String {
        var url = URLComponents()
        url.path = "/api/orchestration/shell"
        if !payload.isEmpty { url.queryItems = payload.keys.sorted().map { URLQueryItem(name: $0, value: "1") } }
        return url.string ?? url.path
    }
}

/// Where a `thread.updated` or `thread.removed` delta applies.
public struct ShellLocation: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let active: Self = "active"
    public static let archive: Self = "archive"
}

/// `OrchestrationV2ShellStreamItem` (orchestrationV2.ts:1945-1981), discriminated by `kind`.
/// A kind this build doesn't know decodes to `.unknown`, carrying its `sequence` when it has
/// one so the reducer can still advance the resume cursor.
public enum ShellStreamItem: Codable, Hashable, Sendable {
    /// `resolvedRepositoryIdentityRoots` is nil on an authoritative snapshot. When present the
    /// snapshot is an enrichment patch for project repository identity only.
    case snapshot(ShellSnapshot, resolvedRepositoryIdentityRoots: [String]?)
    case synchronized
    case projectUpdated(sequence: Int, project: ProjectShell)
    case projectRemoved(sequence: Int, projectId: ProjectId)
    case threadUpdated(sequence: Int, location: ShellLocation?, thread: ThreadShell)
    case threadRemoved(sequence: Int, location: ShellLocation?, threadId: ThreadId)
    case unknown(kind: String, sequence: Int?)

    public var sequence: Int? {
        switch self {
        case .snapshot, .synchronized: nil
        case .projectUpdated(let s, _), .projectRemoved(let s, _): s
        case .threadUpdated(let s, _, _), .threadRemoved(let s, _, _): s
        case .unknown(_, let s): s
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, snapshot, resolvedRepositoryIdentityRoots, sequence, project, projectId
        case location, thread, threadId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "snapshot":
            self = .snapshot(
                try c.decode(ShellSnapshot.self, forKey: .snapshot),
                resolvedRepositoryIdentityRoots: try c.decodeIfPresent([String].self, forKey: .resolvedRepositoryIdentityRoots))
        case "synchronized":
            self = .synchronized
        case "project.updated":
            self = .projectUpdated(
                sequence: try c.decode(Int.self, forKey: .sequence),
                project: try c.decode(ProjectShell.self, forKey: .project))
        case "project.removed":
            self = .projectRemoved(
                sequence: try c.decode(Int.self, forKey: .sequence),
                projectId: try c.decode(ProjectId.self, forKey: .projectId))
        case "thread.updated":
            self = .threadUpdated(
                sequence: try c.decode(Int.self, forKey: .sequence),
                location: try c.decodeIfPresent(ShellLocation.self, forKey: .location),
                thread: try c.decode(ThreadShell.self, forKey: .thread))
        case "thread.removed":
            self = .threadRemoved(
                sequence: try c.decode(Int.self, forKey: .sequence),
                location: try c.decodeIfPresent(ShellLocation.self, forKey: .location),
                threadId: try c.decode(ThreadId.self, forKey: .threadId))
        default:
            self = .unknown(kind: kind, sequence: try? c.decodeIfPresent(Int.self, forKey: .sequence))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let snapshot, let roots):
            try c.encode("snapshot", forKey: .kind)
            try c.encode(snapshot, forKey: .snapshot)
            try c.encodeIfPresent(roots, forKey: .resolvedRepositoryIdentityRoots)
        case .synchronized:
            try c.encode("synchronized", forKey: .kind)
        case .projectUpdated(let sequence, let project):
            try c.encode("project.updated", forKey: .kind)
            try c.encode(sequence, forKey: .sequence)
            try c.encode(project, forKey: .project)
        case .projectRemoved(let sequence, let projectId):
            try c.encode("project.removed", forKey: .kind)
            try c.encode(sequence, forKey: .sequence)
            try c.encode(projectId, forKey: .projectId)
        case .threadUpdated(let sequence, let location, let thread):
            try c.encode("thread.updated", forKey: .kind)
            try c.encode(sequence, forKey: .sequence)
            try c.encodeIfPresent(location, forKey: .location)
            try c.encode(thread, forKey: .thread)
        case .threadRemoved(let sequence, let location, let threadId):
            try c.encode("thread.removed", forKey: .kind)
            try c.encode(sequence, forKey: .sequence)
            try c.encodeIfPresent(location, forKey: .location)
            try c.encode(threadId, forKey: .threadId)
        case .unknown(let kind, let sequence):
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(sequence, forKey: .sequence)
        }
    }
}
