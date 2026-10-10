import Foundation
import T3Protocol

/// A thread's browser tabs as the server reports them (`ThreadPreviewState`,
/// apps/web/src/previewStateStore.ts). `preview.list` is the baseline and `subscribePreviewEvents`
/// keeps it live; `serverEpoch` and `revision` drop stale lists and events.
public struct ThreadPreviewState: Sendable, Equatable {
    public var sessions: [String: PreviewSessionSnapshot] = [:]
    /// Tabs this client closed; stale snapshots must not bring them back.
    public var suppressedTabIds: Set<String> = []
    public var activeTabId: String?
    public var listLoaded = false
    public var serverEpoch: String?
    public var serverRevision = 0

    public init() {}

    public var active: PreviewSessionSnapshot? { activeTabId.flatMap { sessions[$0] } }

    /// The newest session by `updatedAt` (`latestSnapshot`).
    var latest: PreviewSessionSnapshot? { sessions.values.max { $0.updatedAt < $1.updatedAt } }

    private mutating func remove(_ tabId: String) {
        guard sessions.removeValue(forKey: tabId) != nil else { return }
        if activeTabId == tabId || activeTabId.flatMap({ sessions[$0] }) == nil { activeTabId = latest?.tabId }
    }

    /// `applyPreviewServerEvent`. Returns false when the event belongs to another server epoch,
    /// which means the list must be fetched again.
    @discardableResult
    public mutating func apply(_ event: PreviewEvent) -> Bool {
        if let epoch = serverEpoch, epoch != event.serverEpoch { return false }
        if event.revision < serverRevision { return true }
        switch event.type {
        case .opened, .navigated, .resized:
            guard let snapshot = event.snapshot, !suppressedTabIds.contains(snapshot.tabId) else { break }
            sessions[snapshot.tabId] = snapshot
            if event.type == .opened || activeTabId == nil { activeTabId = snapshot.tabId }
        case .failed:
            guard var existing = sessions[event.tabId] else { break }
            existing.navStatus = .loadFailed(url: event.url ?? existing.navStatus.url ?? "", title: event.title ?? "",
                                             code: event.code ?? 0, description: event.description ?? "", download: event.download)
            existing.updatedAt = event.createdAt
            sessions[event.tabId] = existing
        case .closed:
            remove(event.tabId)
            suppressedTabIds.remove(event.tabId)
        }
        serverEpoch = event.serverEpoch
        serverRevision = event.revision
        return true
    }

    /// `reconcilePreviewServerSessions`: the authoritative list. Newer local snapshots win within one
    /// server epoch; the active tab stays when it still exists.
    public mutating func reconcile(_ result: PreviewListResult) {
        let sameServer = serverEpoch == result.serverEpoch
        if sameServer, result.revision < serverRevision { return }
        let suppressed = sameServer ? suppressedTabIds : []
        var next: [String: PreviewSessionSnapshot] = [:]
        for snapshot in result.sessions where !suppressed.contains(snapshot.tabId) {
            let existing = sameServer ? sessions[snapshot.tabId] : nil
            next[snapshot.tabId] = existing.map { $0.updatedAt > snapshot.updatedAt ? $0 : snapshot } ?? snapshot
        }
        sessions = next
        if activeTabId.flatMap({ next[$0] }) == nil { activeTabId = latest?.tabId }
        suppressedTabIds = suppressed.filter { id in result.sessions.contains { $0.tabId == id } }
        listLoaded = true
        serverEpoch = result.serverEpoch
        serverRevision = result.revision
    }

    /// `applyPreviewServerSnapshot`: a tab this client opened becomes the active one.
    public mutating func applyOpened(_ snapshot: PreviewSessionSnapshot) {
        guard !suppressedTabIds.contains(snapshot.tabId) else { return }
        if let existing = sessions[snapshot.tabId], existing.updatedAt > snapshot.updatedAt { return }
        sessions[snapshot.tabId] = snapshot
        activeTabId = snapshot.tabId
    }

    /// `updatePreviewServerSnapshot`: a mutation's reply, without changing the active tab.
    public mutating func update(_ snapshot: PreviewSessionSnapshot) {
        guard !suppressedTabIds.contains(snapshot.tabId) else { return }
        if let existing = sessions[snapshot.tabId], existing.updatedAt > snapshot.updatedAt { return }
        sessions[snapshot.tabId] = snapshot
        if activeTabId.flatMap({ sessions[$0] }) == nil { activeTabId = snapshot.tabId }
    }

    /// `beginPreviewSessionClose`: optimistic; a failed close calls `cancelClose`.
    public mutating func beginClose(_ tabId: String) {
        suppressedTabIds.insert(tabId)
        remove(tabId)
    }

    public mutating func cancelClose(_ snapshot: PreviewSessionSnapshot?, tabId: String) {
        suppressedTabIds.remove(tabId)
        if let snapshot { sessions[tabId] = snapshot; activeTabId = tabId }
    }

    /// `setActivePreviewTab`.
    public mutating func setActive(_ tabId: String) {
        if sessions[tabId] != nil { activeTabId = tabId }
    }

    /// Tabs the panel lists: every one but server tabs an agent opened hidden (`reveal: false`),
    /// ChatView.tsx:2406-2420.
    public var panelTabIds: (all: [String], hidden: Set<String>) {
        let all = sessions.values.sorted { $0.updatedAt < $1.updatedAt }.map(\.tabId)
        let hidden = Set(sessions.values.filter { $0.isServerTab && $0.reveal == false }.map(\.tabId))
        return (all, hidden)
    }
}

// MARK: - Discovery

/// A discovered server as the empty state lists it (`PreviewableServer`, useDiscoveredLocalServers.ts).
public struct PreviewableServer: Sendable, Equatable {
    public enum Source: Int, Sendable { case configured = 0, scanner = 1 }
    public var server: DiscoveredLocalServer
    public var source: Source
    /// The URL to open and remember. A server tab's browser runs on the environment, so the
    /// scanner's loopback URL is already right.
    public var requestedUrl: String

    public init(server: DiscoveredLocalServer, source: Source, requestedUrl: String) {
        self.server = server; self.source = source; self.requestedUrl = requestedUrl
    }

    /// `describeServer`: the process name, or "Listening".
    public var title: String { server.processName ?? "Listening" }
    public var detail: String { "\(server.host):\(server.port)" }
}

public enum LocalServerDiscovery {
    /// `CONFIGURED_LOCAL_SERVER_URLS_MAX_ITEMS`, `PREVIEW_URL_MAX_LENGTH`.
    public static let maxConfigured = 32
    static let maxURLLength = 2048

    /// `boundConfiguredLocalServerUrls` (portDiscoveryState.ts:17-42): loopback http(s) only,
    /// deduplicated without the fragment, at most 32.
    public static func boundConfiguredUrls(_ urls: [String]) -> [String] {
        var out: [String] = [], seen: Set<String> = []
        for raw in urls {
            guard !raw.isEmpty, raw.count <= maxURLLength, raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
                  var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = c.host, PreviewURL.isLoopbackHost(host.lowercased()) || PreviewURL.isLoopbackHost("[\(host)]") else { continue }
            c.fragment = nil
            let key = c.string ?? raw
            guard seen.insert(key).inserted else { continue }
            out.append(raw)
            if out.count >= maxConfigured { break }
        }
        return out
    }

    /// `mergeServers`: configured URLs first, then by port.
    public static func merge(scanner: [DiscoveredLocalServer], configuredUrls: [String], configuredUrlProbing: Bool?) -> [PreviewableServer] {
        func key(_ host: String, _ port: Int) -> String {
            let h = host.lowercased()
            return "\(PreviewURL.isLoopbackHost(h) ? "loopback" : h):\(port)"
        }
        var configured: [String: String] = [:]
        for url in configuredUrls {
            guard let c = URLComponents(string: url), let scheme = c.scheme, scheme == "http" || scheme == "https",
                  let host = c.host, PreviewURL.isLoopbackHost(host) || PreviewURL.isLoopbackHost("[\(host)]") else { continue }
            let port = c.port ?? (scheme == "http" ? 80 : 443)
            let k = key(host, port)
            if configured[k] == nil { configured[k] = url }
        }
        return scanner.map { server in
            let match = configured[key(server.host, server.port)]
            return PreviewableServer(server: server, source: match == nil ? .scanner : .configured,
                                     requestedUrl: match != nil && configuredUrlProbing == false ? match! : server.url)
        }.sorted { ($0.source.rawValue, $0.server.port) < ($1.source.rawValue, $1.server.port) }
    }

    /// `useThreadDiscoveredPorts`: servers a thread's own terminals started.
    public static func forThread(_ servers: [DiscoveredLocalServer], threadId: String) -> [DiscoveredLocalServer] {
        servers.filter { $0.terminal?.threadId == threadId }
    }
}

// MARK: - History

/// Recently used URLs per project (apps/web/src/browserHistoryStore.ts): newest first, 50 per
/// project, 20 projects. Loopback and the environment's own host count as one place.
public struct BrowserHistory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var url: String
        /// Milliseconds since 1970, as T3 stores it.
        public var lastVisitedAt: Double
        public var title: String?
        public init(url: String, lastVisitedAt: Double, title: String? = nil) { self.url = url; self.lastVisitedAt = lastVisitedAt; self.title = title }
    }

    public static let maxEntriesPerProject = 50
    public static let maxProjects = 20
    /// The empty state shows this many (`slice(0, 8)`).
    public static let shown = 8

    public private(set) var byProjectKey: [String: [Entry]] = [:]

    public init(byProjectKey: [String: [Entry]] = [:]) { self.byProjectKey = byProjectKey }

    public func entries(_ projectKey: String) -> [Entry] { byProjectKey[projectKey] ?? [] }

    /// `normalizeHistoryUrl`: normalized, credentials dropped, 2048 at most.
    public static func normalize(_ raw: String) -> String? {
        guard let n = PreviewURL.normalize(raw), var c = URLComponents(string: n) else { return nil }
        c.user = nil; c.password = nil
        guard let s = c.string, s.count <= 2048 else { return nil }
        return s
    }

    /// `visitLookupKey`: loopback, 0.0.0.0 and the environment's host read as `local`.
    static func visitKey(_ url: String, environmentHost: String? = nil) -> String {
        guard var c = URLComponents(string: url), let host = c.host?.lowercased() else { return url }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if PreviewURL.isLoopbackHost(h) || h.hasPrefix("127.") || h == environmentHost?.lowercased() { c.host = "local" }
        return c.string ?? url
    }

    static func titleKey(_ url: String, environmentHost: String?) -> String {
        guard var c = URLComponents(string: visitKey(url, environmentHost: environmentHost)) else { return url }
        if c.path != "/", c.path.hasSuffix("/") { c.path.removeLast() }
        return c.string ?? url
    }

    static func isStableLocal(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return PreviewURL.isLoopbackHost(h) || h.hasPrefix("127.")
    }

    /// `recordVisit` with `upsertHistoryEntry`: moves the place to the front.
    public mutating func recordVisit(_ projectKey: String, url raw: String, at: Double, environmentHost: String? = nil) {
        guard let url = Self.normalize(raw) else { return }
        let entries = byProjectKey[projectKey] ?? []
        let key = Self.visitKey(url, environmentHost: environmentHost)
        let existing = entries.first { Self.visitKey($0.url, environmentHost: environmentHost) == key }
        let rest = entries.filter { Self.visitKey($0.url, environmentHost: environmentHost) != key }
        var entry = existing ?? Entry(url: url, lastVisitedAt: at)
        if let existing, !(Self.isStableLocal(existing.url) || !Self.isStableLocal(url)) { entry.url = url }
        entry.lastVisitedAt = at
        byProjectKey[projectKey] = Array(([entry] + rest).prefix(Self.maxEntriesPerProject))
        evict()
    }

    /// `setTitleForUrl`: only enriches a URL already in the list.
    public mutating func setTitle(_ projectKey: String, url raw: String, title: String, environmentHost: String? = nil) {
        guard let url = Self.normalize(raw), var entries = byProjectKey[projectKey] else { return }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !trimmed.isEmpty else { return }
        let key = Self.titleKey(url, environmentHost: environmentHost)
        guard let i = entries.firstIndex(where: { Self.titleKey($0.url, environmentHost: environmentHost) == key }), entries[i].title != trimmed else { return }
        entries[i].title = trimmed
        byProjectKey[projectKey] = entries
    }

    public mutating func remove(_ projectKey: String, url raw: String) {
        guard let url = Self.normalize(raw), let entries = byProjectKey[projectKey] else { return }
        let next = entries.filter { $0.url != url }
        byProjectKey[projectKey] = next.isEmpty ? nil : next
    }

    /// `evictExcessProjects`: the 20 projects visited most recently stay.
    mutating func evict() {
        guard byProjectKey.count > Self.maxProjects else { return }
        let kept = byProjectKey.keys.sorted { (byProjectKey[$0]?.first?.lastVisitedAt ?? 0) > (byProjectKey[$1]?.first?.lastVisitedAt ?? 0) }
            .prefix(Self.maxProjects)
        byProjectKey = byProjectKey.filter { kept.contains($0.key) }
    }

    /// The empty state's label for an entry (PreviewRecentUrlCard.tsx): host, path unless `/`,
    /// query and fragment.
    public static func label(_ url: String) -> String {
        guard let c = URLComponents(string: url), let host = PreviewURL.host(of: url) else { return url }
        let path = c.path == "/" ? "" : c.percentEncodedPath
        return host + path + (c.percentEncodedQuery.map { "?" + $0 } ?? "") + (c.percentEncodedFragment.map { "#" + $0 } ?? "")
    }
}
