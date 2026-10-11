import Foundation
import T3Protocol

/// One surface in a thread's right panel (`RightPanelSurface`, apps/web/src/rightPanelStore.ts:43-87).
/// Only the kinds this app draws: the diff and files singletons, one tab per workspace file, one
/// per pull request, the thread's linked pull requests, browser tabs and terminal tabs.
// ponytail: device surfaces are not modeled; add a case when the device panel is built (id `device`)
public enum RightPanelSurface: Codable, Sendable, Equatable {
    case diff
    case files
    /// `file:<path>`: workspace relative, or absolute for a host file. `revealRequestId` counts the
    /// opens of this path so the same line can be revealed again.
    case file(path: String, revealLine: Int?, revealRequestId: Int)
    /// `pull-request:<scope>`: a change request beside a thread or on the Pull Requests page.
    case pullRequest(PullRequestSurfaceTarget)
    /// The thread's linked pull requests, one singleton tab.
    case pullRequests
    /// `browser:<tabId>`: a server browser tab; nil is the `browser:new` placeholder that shows the
    /// empty state until a tab exists.
    case browser(tabId: String?)
    /// `terminal:<first terminal id>`: one split group of terminals in a tab.
    case terminal(TerminalPanelSurface)

    public var id: String {
        switch self {
        case .diff: "diff"
        case .files: "files"
        case .file(let path, _, _): "file:" + path
        case .pullRequest(let target): target.surfaceId
        case .pullRequests: "pull-requests"
        case .browser(let tabId): "browser:" + (tabId ?? "new")
        case .terminal(let t): "terminal:" + t.resourceId
        }
    }

    public enum Kind: String, Sendable { case diff, files, file, pullRequest, pullRequests, browser, terminal }
    public var kind: Kind {
        switch self {
        case .diff: .diff
        case .files: .files
        case .file: .file
        case .pullRequest: .pullRequest
        case .pullRequests: .pullRequests
        case .browser: .browser
        case .terminal: .terminal
        }
    }

    /// `surfaceTitle` (RightPanelTabs.tsx:582-617).
    public var title: String {
        switch self {
        case .diff: return "Diff"
        case .files: return "Files"
        case .file(let path, _, _):
            let cut = max(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex,
                          path.lastIndex(of: "\\").map { path.index(after: $0) } ?? path.startIndex)
            return String(path[cut...])
        case .pullRequest(let target): return "#\(target.number)"
        case .pullRequests: return "Pull requests"
        case .browser: return "Browser"
        // The app shows the server's label for the active terminal when it knows one.
        case .terminal(let t): return TerminalLabels.label(t.activeTerminalId)
        }
    }

    /// A browser surface's server tab id.
    public var browserTabId: String? {
        if case .browser(let id) = self { return id }
        return nil
    }

    public var filePath: String? {
        if case .file(let path, _, _) = self { return path }
        return nil
    }

    public var pullRequest: PullRequestSurfaceTarget? {
        if case .pullRequest(let target) = self { return target }
        return nil
    }

    public var terminal: TerminalPanelSurface? {
        if case .terminal(let t) = self { return t }
        return nil
    }
}

/// A terminal tab (rightPanelStore.ts:47-54): the terminals it shows side by side or stacked, at
/// most `TerminalDrawerState.maxPerGroup`, and the one with the keyboard.
public struct TerminalPanelSurface: Codable, Sendable, Equatable {
    /// The first terminal's id; the tab keeps it as its id after that terminal closes.
    public var resourceId: String
    public var terminalIds: [String]
    public var activeTerminalId: String
    public var splitDirection: TerminalGroup.Direction

    public init(resourceId: String, terminalIds: [String], activeTerminalId: String, splitDirection: TerminalGroup.Direction = .horizontal) {
        self.resourceId = resourceId; self.terminalIds = terminalIds; self.activeTerminalId = activeTerminalId; self.splitDirection = splitDirection
    }

    /// `terminalSurface`.
    public init(terminalId: String) { self.init(resourceId: terminalId, terminalIds: [terminalId], activeTerminalId: terminalId) }
}

/// The pull request a `pull-request` surface shows (rightPanelStore.ts:68-86). The environment is
/// set on the Pull Requests page, whose panel spans servers; beside a thread it is the thread's.
public struct PullRequestSurfaceTarget: Codable, Sendable, Hashable {
    public var environmentId: String?
    /// The server's own project id.
    public var projectId: String
    public var host: String?
    public var repository: String
    public var number: Int
    public var url: String?

    public init(environmentId: String? = nil, projectId: String, host: String? = nil, repository: String, number: Int, url: String? = nil) {
        self.environmentId = environmentId; self.projectId = projectId; self.host = host?.lowercased()
        self.repository = repository; self.number = number; self.url = url
    }

    /// `pullRequestSurfaceId`: environment, project, host, repository and number, URI encoded.
    public var surfaceId: String {
        func enc(_ s: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-_.!~*'()")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let scope = environmentId.map { enc($0) + ":" } ?? ""
        let h = host.map { enc($0.lowercased()) + ":" } ?? ""
        return "pull-request:\(scope)\(enc(projectId)):\(h)\(enc(repository)):\(number)"
    }
}

/// A thread's panel (`ThreadRightPanelState`, rightPanelStore.ts:107-112): its tabs in order, the
/// active one and whether the panel shows. Every mutation is a port of the store action it names.
public struct RightPanelState: Codable, Sendable, Equatable {
    public var isOpen = false
    public var activeSurfaceId: String?
    public var surfaces: [RightPanelSurface] = []

    public init(isOpen: Bool = false, activeSurfaceId: String? = nil, surfaces: [RightPanelSurface] = []) {
        self.isOpen = isOpen; self.activeSurfaceId = activeSurfaceId; self.surfaces = surfaces
    }

    public var active: RightPanelSurface? { surfaces.first { $0.id == activeSurfaceId } }
    public var isEmpty: Bool { !isOpen && activeSurfaceId == nil && surfaces.isEmpty }

    /// `upsertSurface`: opens the panel on the surface, adding it at the end when new.
    public mutating func upsert(_ surface: RightPanelSurface, activate: Bool = true) {
        isOpen = true
        if !surfaces.contains(where: { $0.id == surface.id }) { surfaces.append(surface) }
        if activate { activeSurfaceId = surface.id }
    }

    /// `open(ref, kind)` for the singletons.
    public mutating func open(_ kind: RightPanelSurface.Kind) {
        switch kind {
        case .diff: upsert(.diff)
        case .files: upsert(.files)
        case .pullRequests: upsert(.pullRequests)
        case .browser: upsert(surfaces.first { $0.kind == .browser } ?? .browser(tabId: nil))
        case .file, .pullRequest, .terminal: break
        }
    }

    /// `openBrowser` (rightPanelStore.ts:665-673): a real tab replaces the placeholder.
    public mutating func openBrowser(_ tabId: String?) {
        if tabId != nil { surfaces.removeAll { $0.id == "browser:new" } }
        upsert(.browser(tabId: tabId))
    }

    /// `reconcileBrowserSurfaces` (rightPanelStore.ts:882-908): the server's tabs minus the ones an
    /// agent opened hidden. Tabs gone from the server drop out, as does the placeholder. It does not
    /// open the panel.
    public mutating func reconcileBrowser(tabIds: [String], hidden: Set<String>) {
        let valid = Set(tabIds.map { "browser:" + $0 })
        let nonBrowser = surfaces.filter { $0.kind != .browser }
        let existing = surfaces.filter { $0.kind == .browser && $0.id != "browser:new" && valid.contains($0.id) }
        let known = Set(existing.map(\.id))
        let added = tabIds.filter { !known.contains("browser:" + $0) && !hidden.contains($0) }.map { RightPanelSurface.browser(tabId: $0) }
        let next = nonBrowser + existing + added
        guard next != surfaces else { return }
        surfaces = next
        if !surfaces.contains(where: { $0.id == activeSurfaceId }) {
            activeSurfaceId = surfaces.first { $0.kind == .browser }?.id ?? surfaces.first?.id
        }
    }

    /// `openPullRequest` (rightPanelStore.ts:675-689): a known tab takes the newer URL.
    public mutating func openPullRequest(_ target: PullRequestSurfaceTarget) {
        let surface = RightPanelSurface.pullRequest(target)
        upsert(surface)
        if target.url != nil { surfaces = surfaces.map { $0.id == surface.id ? surface : $0 } }
    }

    /// `openFile` (rightPanelStore.ts:690-723): "." is the explorer; a file tab replaces the
    /// standalone explorer, keeps its place when already open and counts one more reveal.
    public mutating func openFile(_ requestedPath: String, line: Int? = nil) {
        if requestedPath == "." { upsert(.files); return }
        var path = requestedPath
        let isDriveRoot = path.range(of: #"^[A-Za-z]:/+$"#, options: .regularExpression) != nil
        if !isDriveRoot {
            while path.hasSuffix("/") { path.removeLast() }
            if path.isEmpty { path = requestedPath }
        }
        let kept = surfaces.filter { $0.kind != .files }
        let id = "file:" + path
        var previous = 0
        if let existing = kept.first(where: { $0.id == id }), case .file(_, _, let count) = existing { previous = count }
        let surface = RightPanelSurface.file(path: path, revealLine: line.map { max(1, $0) }, revealRequestId: previous + 1)
        surfaces = kept.contains(where: { $0.id == id }) ? kept.map { $0.id == id ? surface : $0 } : kept + [surface]
        isOpen = true
        activeSurfaceId = id
    }

    /// `openTerminal` (rightPanelStore.ts:737-742): a new tab with one terminal.
    public mutating func openTerminal(_ terminalId: String) {
        upsert(.terminal(TerminalPanelSurface(terminalId: terminalId)))
    }

    /// `splitTerminal` (rightPanelStore.ts:743-762): the terminal joins the tab at the end and
    /// becomes active; the tab takes `direction`.
    public mutating func splitTerminal(_ surfaceId: String, terminalId: String, direction: TerminalGroup.Direction) {
        isOpen = true
        activeSurfaceId = surfaceId
        surfaces = surfaces.map { surface in
            guard surface.id == surfaceId, var t = surface.terminal else { return surface }
            if !t.terminalIds.contains(terminalId) { t.terminalIds.append(terminalId) }
            t.activeTerminalId = terminalId
            t.splitDirection = direction
            return .terminal(t)
        }
    }

    /// `activateTerminal` (rightPanelStore.ts:763-776).
    public mutating func activateTerminal(_ surfaceId: String, terminalId: String) {
        activeSurfaceId = surfaceId
        surfaces = surfaces.map { surface in
            guard surface.id == surfaceId, var t = surface.terminal, t.terminalIds.contains(terminalId) else { return surface }
            t.activeTerminalId = terminalId
            return .terminal(t)
        }
    }

    /// `closeTerminal` (rightPanelStore.ts:777-815): the tab's last terminal closes the tab; else
    /// the last remaining terminal takes over when the active one closed.
    public mutating func closeTerminal(_ surfaceId: String, terminalId: String) {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }), var t = surfaces[index].terminal else { return }
        t.terminalIds.removeAll { $0 == terminalId }
        if t.terminalIds.isEmpty {
            surfaces.remove(at: index)
            isOpen = !surfaces.isEmpty && isOpen
            if activeSurfaceId == surfaceId { activeSurfaceId = surfaces.isEmpty ? nil : surfaces[min(index, surfaces.count - 1)].id }
            return
        }
        if t.activeTerminalId == terminalId { t.activeTerminalId = t.terminalIds.last ?? t.terminalIds[0] }
        surfaces[index] = .terminal(t)
    }

    /// Every terminal id the panel's tabs show (the drawer leaves them out, ChatView.tsx:1013-1022).
    public var panelTerminalIds: Set<String> { Set(surfaces.flatMap { $0.terminal?.terminalIds ?? [] }) }

    /// `activateSurface`.
    public mutating func activate(_ id: String) {
        guard surfaces.contains(where: { $0.id == id }) else { return }
        isOpen = true
        activeSurfaceId = id
    }

    /// `closeSurface` (rightPanelStore.ts:824-844): the right neighbor takes over, else the left; the
    /// panel closes with its last tab. Returns the removed surfaces in T3's remember order.
    @discardableResult
    public mutating func close(_ id: String) -> [RightPanelSurface] {
        guard let index = surfaces.firstIndex(where: { $0.id == id }) else { return [] }
        let removed = surfaces[index]
        surfaces.remove(at: index)
        isOpen = !surfaces.isEmpty && isOpen
        if activeSurfaceId == id {
            activeSurfaceId = surfaces.isEmpty ? nil : surfaces[min(index, surfaces.count - 1)].id
        }
        return [removed]
    }

    /// `closeOtherSurfaces`.
    @discardableResult
    public mutating func closeOthers(_ id: String) -> [RightPanelSurface] {
        guard let surface = surfaces.first(where: { $0.id == id }), surfaces.count > 1 else { return [] }
        let before = self
        surfaces = [surface]
        isOpen = true
        activeSurfaceId = id
        return Self.closedInOrder(before: before, after: self)
    }

    /// `closeSurfacesToRight`.
    @discardableResult
    public mutating func closeToRight(_ id: String) -> [RightPanelSurface] {
        guard let index = surfaces.firstIndex(where: { $0.id == id }), index < surfaces.count - 1 else { return [] }
        let before = self
        surfaces = Array(surfaces[...index])
        if !surfaces.contains(where: { $0.id == activeSurfaceId }) { activeSurfaceId = id }
        return Self.closedInOrder(before: before, after: self)
    }

    /// `closeAllSurfaces`.
    @discardableResult
    public mutating func closeAll() -> [RightPanelSurface] {
        guard !surfaces.isEmpty else { return [] }
        let before = self
        isOpen = false
        surfaces = []
        activeSurfaceId = nil
        return Self.closedInOrder(before: before, after: self)
    }

    /// `toggle(ref, kind)`: closes the panel when it already shows that kind, else opens it there.
    public mutating func toggle(_ kind: RightPanelSurface.Kind) {
        if isOpen, active?.kind == kind { isOpen = false; return }
        open(kind)
    }

    /// `toggleVisibility`.
    public mutating func toggleVisibility() { isOpen.toggle() }

    /// `reconcileFileSurfaces(ref, false)`: without a workspace the file tabs go.
    public mutating func dropFileSurfaces() {
        let kept = surfaces.filter { $0.kind != .file && $0.kind != .files }
        guard kept.count != surfaces.count else { return }
        surfaces = kept
        if surfaces.isEmpty { isOpen = false }
        if !surfaces.contains(where: { $0.id == activeSurfaceId }) { activeSurfaceId = surfaces.last?.id }
    }

    /// The store's close subscriber (rightPanelStore.ts:1045-1066): removed tabs, the active one last.
    static func closedInOrder(before: RightPanelState, after: RightPanelState) -> [RightPanelSurface] {
        let removed = before.surfaces.filter { s in !after.surfaces.contains { $0.id == s.id } }
        return removed.filter { $0.id != before.activeSurfaceId } + removed.filter { $0.id == before.activeSurfaceId }
    }
}

/// `useClosedViewStore` (apps/web/src/closedViewStore.ts) for panel tabs: newest first, one entry
/// per thread and surface, 20 at most. Mod+Shift+T restores the newest one that is not open.
public struct ClosedPanelTabs: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var threadKey: String
        public var surface: RightPanelSurface
        /// A closed server tab's page (`{kind: "browser", snapshot}`), opened again with `preview.open`.
        public var browserURL: String?
        public init(threadKey: String, surface: RightPanelSurface, browserURL: String? = nil) {
            self.threadKey = threadKey; self.surface = surface; self.browserURL = browserURL
        }
    }

    public static let limit = 20
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    /// `remember`.
    public mutating func remember(_ surface: RightPanelSurface, threadKey: String, browserURL: String? = nil) {
        if surface.kind == .terminal { return }
        let entry = Entry(threadKey: threadKey, surface: surface, browserURL: browserURL)
        entries.removeAll { $0.threadKey == threadKey && $0.surface.id == surface.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// `planNextReopen` (reopenClosedView.ts:28-56), simplified to known threads: entries whose
    /// thread is gone are dropped, entries already open are dropped, the first other one restores.
    /// Returns it after removing it and everything dropped on the way.
    public mutating func popNext(threadExists: (String) -> Bool, panel: (String) -> RightPanelState) -> Entry? {
        while let entry = entries.first {
            entries.removeFirst()
            guard threadExists(entry.threadKey) else { continue }
            let state = panel(entry.threadKey)
            if state.isOpen, state.surfaces.contains(where: { $0.id == entry.surface.id }) { continue }
            return entry
        }
        return nil
    }

    /// Restores the entry into `state` like `reopenClosedView`: a file reopens at its line.
    public static func restore(_ surface: RightPanelSurface, into state: inout RightPanelState) {
        switch surface {
        case .diff, .files, .pullRequests: state.open(surface.kind)
        // A closed server tab reopens through `preview.open` in the app (`reopenClosedView`).
        case .browser(let tabId): if tabId == nil { state.openBrowser(nil) }
        case .file(let path, let line, _): state.openFile(path, line: line)
        case .pullRequest(let target): state.openPullRequest(target)
        case .terminal: break
        }
    }

    public mutating func removeThreads(where drop: (String) -> Bool) { entries.removeAll { drop($0.threadKey) } }
}
