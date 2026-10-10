import Foundation
import T3Protocol

/// `ThreadCheckpointSummary`, also `TurnDiffSummary` (client-runtime/src/state/threadCheckpoints.ts:11-26):
/// one run's changed files, shown under its final assistant message.
public struct TurnDiffSummary: Sendable, Hashable {
    public var checkpointId: CheckpointId
    public var scopeId: CheckpointScopeId
    public var runId: RunId
    /// The app run ordinal (1 for the first run), the unit of `getTurnDiff`.
    public var checkpointTurnCount: Int
    public var checkpointRef: String
    /// `ready`, `missing`, `error` or `stale`.
    public var status: String
    public var files: [CheckpointFile]
    public var assistantMessageId: MessageId?
    public var completedAt: T3Timestamp

    public init(checkpointId: CheckpointId, scopeId: CheckpointScopeId, runId: RunId, checkpointTurnCount: Int, checkpointRef: String,
                status: String, files: [CheckpointFile], assistantMessageId: MessageId?, completedAt: T3Timestamp) {
        self.checkpointId = checkpointId
        self.scopeId = scopeId
        self.runId = runId
        self.checkpointTurnCount = checkpointTurnCount
        self.checkpointRef = checkpointRef
        self.status = status
        self.files = files
        self.assistantMessageId = assistantMessageId
        self.completedAt = completedAt
    }
}

public enum TurnDiffs {
    /// Port of `deriveThreadCheckpointSummaries` (threadCheckpoints.ts:29-52). Bounded snapshots
    /// can carry only some checkpoints, so a missing summary just means no card.
    public static func summaries(_ projection: ThreadProjection) -> [TurnDiffSummary] {
        guard !projection.checkpoints.isEmpty else { return [] }
        // The last assistant message per run, in one pass (was a scan per checkpoint).
        var lastAssistant: [RunId: MessageId] = [:]
        for message in projection.messages where message.role == "assistant" {
            if let runId = message.runId { lastAssistant[runId] = message.id }
        }
        return projection.checkpoints.compactMap { checkpoint in
            guard let ordinal = checkpoint.appRunOrdinal, let runId = checkpoint.runId else { return nil }
            let assistantMessageId = lastAssistant[runId]
            return TurnDiffSummary(
                checkpointId: checkpoint.id, scopeId: checkpoint.scopeId, runId: runId, checkpointTurnCount: ordinal,
                checkpointRef: checkpoint.ref, status: checkpoint.status, files: checkpoint.files,
                assistantMessageId: assistantMessageId, completedAt: checkpoint.capturedAt)
        }
    }

    /// The diff panel's order (DiffPanel.tsx:263-277): newest run first.
    public static func sortedForPanel(_ summaries: [TurnDiffSummary]) -> [TurnDiffSummary] {
        summaries.sorted {
            ($0.checkpointTurnCount, $0.completedAt.epochMs ?? 0) > ($1.checkpointTurnCount, $1.completedAt.epochMs ?? 0)
        }
    }

    /// The request the diff panel sends for one run (DiffPanel.tsx:320-330,
    /// apps/web/src/state/queries.ts:343-383): exactly that run's delta. The first run has no
    /// earlier checkpoint, so it uses `getFullThreadDiff`.
    public enum Request: Sendable, Hashable {
        case turn(GetTurnDiffInput)
        case fullThread(GetFullThreadDiffInput)
    }

    public static func request(threadId: ThreadId, summary: TurnDiffSummary, ignoreWhitespace: Bool = true) -> Request {
        let to = summary.checkpointTurnCount
        let from = max(0, to - 1)
        return from == 0
            ? .fullThread(GetFullThreadDiffInput(threadId: threadId, toTurnCount: to, ignoreWhitespace: ignoreWhitespace))
            : .turn(GetTurnDiffInput(threadId: threadId, fromTurnCount: from, toTurnCount: to, ignoreWhitespace: ignoreWhitespace))
    }
}

// MARK: - Changed files tree (apps/web/src/lib/turnDiffTree.ts)

public struct TurnDiffStat: Sendable, Hashable {
    public var additions: Int
    public var deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    /// `hasNonZeroStat` (DiffStatLabel.tsx:4-6).
    public var isNonZero: Bool { additions > 0 || deletions > 0 }

    /// `readStat`: nil unless both counts are numbers.
    init?(_ file: CheckpointFile) {
        guard let a = file.additions, let d = file.deletions else { return nil }
        self.init(additions: a, deletions: d)
    }
}

public indirect enum TurnDiffTreeNode: Sendable, Hashable {
    case directory(name: String, path: String, stat: TurnDiffStat, children: [TurnDiffTreeNode])
    case file(name: String, path: String, stat: TurnDiffStat?)

    public var name: String {
        switch self { case .directory(let n, _, _, _), .file(let n, _, _): n }
    }

    public var path: String {
        switch self { case .directory(_, let p, _, _), .file(_, let p, _): p }
    }
}

public enum TurnDiffTree {
    /// `summarizeTurnDiffStats` (turnDiffTree.ts:95-105): sums files that have numeric stats.
    public static func totalStat(_ files: [CheckpointFile]) -> TurnDiffStat {
        files.compactMap(TurnDiffStat.init).reduce(TurnDiffStat(additions: 0, deletions: 0)) {
            TurnDiffStat(additions: $0.additions + $1.additions, deletions: $0.deletions + $1.deletions)
        }
    }

    private final class Directory {
        let name: String
        let path: String
        var stat = TurnDiffStat(additions: 0, deletions: 0)
        var directories: [String: Directory] = [:]
        var files: [TurnDiffTreeNode] = []
        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// `localeCompare` with `{numeric: true, sensitivity: "base"}`.
    static func compareNames(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive]) == .orderedAscending
    }

    /// Port of `buildTurnDiffTree` (turnDiffTree.ts:107-147): directories first, then files, both
    /// in natural order; single-child directory chains merge into `a/b`.
    public static func build(_ files: [CheckpointFile]) -> [TurnDiffTreeNode] {
        let root = Directory(name: "", path: "")
        for file in files {
            let segments = file.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard let fileName = segments.last else { continue }
            let stat = TurnDiffStat(file)
            var ancestors = [root]
            var current = root
            for segment in segments.dropLast() {
                let next = current.directories[segment] ?? {
                    let created = Directory(name: segment, path: current.path.isEmpty ? segment : "\(current.path)/\(segment)")
                    current.directories[segment] = created
                    return created
                }()
                current = next
                ancestors.append(current)
            }
            current.files.append(.file(name: fileName, path: segments.joined(separator: "/"), stat: stat))
            if let stat {
                for ancestor in ancestors {
                    ancestor.stat.additions += stat.additions
                    ancestor.stat.deletions += stat.deletions
                }
            }
        }
        return nodes(root)
    }

    private static func nodes(_ directory: Directory) -> [TurnDiffTreeNode] {
        let subdirectories = directory.directories.values
            .sorted { compareNames($0.name, $1.name) }
            .map { compact(.directory(name: $0.name, path: $0.path, stat: $0.stat, children: nodes($0))) }
        let files = directory.files.sorted { compareNames($0.name, $1.name) }
        return subdirectories + files
    }

    /// `compactDirectoryNode` (turnDiffTree.ts:50-70).
    private static func compact(_ node: TurnDiffTreeNode) -> TurnDiffTreeNode {
        guard case .directory(var name, var path, var stat, var children) = node else { return node }
        while children.count == 1, case .directory(let childName, let childPath, let childStat, let grandchildren) = children[0] {
            name = "\(name)/\(childName)"
            path = childPath
            stat = childStat
            children = grandchildren
        }
        return .directory(name: name, path: path, stat: stat, children: children)
    }
}
