import Foundation
import T3Protocol

/// `OrchestrationThreadSearchMatch` (packages/contracts/src/threadSearch.ts:22-28): a thread whose
/// messages the server matched for `orchestration.searchThreads`. `source` is "user" or "assistant".
public struct ThreadSearchMatch: Decodable, Equatable, Sendable {
    public var threadId: ThreadId
    public var projectId: ProjectId
    public var source: String
    public var snippet: String
    /// When the matched message was written.
    public var messageCreatedAt: T3Timestamp?

    public init(threadId: ThreadId, projectId: ProjectId, source: String, snippet: String, messageCreatedAt: T3Timestamp? = nil) {
        self.threadId = threadId
        self.projectId = projectId
        self.source = source
        self.snippet = snippet
        self.messageCreatedAt = messageCreatedAt
    }

    public var isUser: Bool { source == "user" }
}

/// `OrchestrationSearchThreadsResult` (threadSearch.ts:31-33).
public struct ThreadSearchResult: Decodable, Sendable {
    public var matches: [ThreadSearchMatch]
}

extension SidebarModel {
    /// `THREAD_SEARCH_DEBOUNCE_MS` (apps/web/src/state/queries.ts:39).
    public static let threadSearchDebounceMs = 200
    /// `OrchestrationSearchThreadsInput.query` has a two-character floor (threadSearch.ts:17).
    public static let threadSearchMinLength = 2

    /// Port of `threadPullRequestSearchTerms` (packages/shared/src/threadPullRequests.ts:312-326).
    public static func threadPullRequestSearchTerms(_ thread: ThreadShell) -> [String] {
        if let links = thread.pullRequests, !links.isEmpty {
            return links.filter { $0.source.rawValue != "stack-dismissed" }.flatMap { link in
                ["#\(link.number)", "\(link.repository)#\(link.number)", link.url, link.snapshot?.title ?? ""]
            }
        }
        guard let legacy = thread.linkedPullRequest else { return [] }
        return ["#\(legacy.number)", "\(legacy.repository)#\(legacy.number)", legacy.url]
    }

    /// Port of `searchSidebarThreads` (Sidebar.logic.ts:1080-1111): title or linked PR matches first,
    /// then threads whose messages the server matched, each in the input (shelf) order.
    public static func searchSidebarThreads(
        _ threads: [SidebarThread], query: String, contentMatchIds: Set<ThreadId> = []
    ) -> [SidebarThread] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var titleMatches: [SidebarThread] = [], contentMatches: [SidebarThread] = []
        for thread in threads {
            if ([thread.shell.title] + threadPullRequestSearchTerms(thread.shell)).contains(where: { $0.lowercased().contains(q) }) {
                titleMatches.append(thread)
            } else if contentMatchIds.contains(thread.id) {
                contentMatches.append(thread)
            }
        }
        return titleMatches + contentMatches
    }
}
