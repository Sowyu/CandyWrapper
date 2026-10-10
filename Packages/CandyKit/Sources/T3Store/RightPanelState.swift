import Foundation

/// One surface in a thread's right panel (`RightPanelSurface`, apps/web/src/rightPanelStore.ts:43-87).
/// Only the kinds this app draws: the diff and files singletons and one tab per workspace file.
// ponytail: browser, terminal, device and pull request surfaces are not modeled; add cases when
// WP7.5b and WP7.6b build them (their ids are `browser:*`, `terminal:*`, `pull-request:*`)
public enum RightPanelSurface: Codable, Sendable, Equatable {
    case diff
    case files
    /// `file:<path>`: workspace relative, or absolute for a host file. `revealRequestId` counts the
    /// opens of this path so the same line can be revealed again.
    case file(path: String, revealLine: Int?, revealRequestId: Int)

    public var id: String {
        switch self {
        case .diff: "diff"
        case .files: "files"
        case .file(let path, _, _): "file:" + path
        }
    }

    public enum Kind: String, Sendable { case diff, files, file }
    public var kind: Kind {
        switch self {
        case .diff: .diff
        case .files: .files
        case .file: .file
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
        }
    }

    public var filePath: String? {
        if case .file(let path, _, _) = self { return path }
        return nil
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
        case .file: break
        }
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
        let kept = surfaces.filter { $0.kind == .diff }
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
        public init(threadKey: String, surface: RightPanelSurface) { self.threadKey = threadKey; self.surface = surface }
    }

    public static let limit = 20
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    /// `remember`.
    public mutating func remember(_ surface: RightPanelSurface, threadKey: String) {
        let entry = Entry(threadKey: threadKey, surface: surface)
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
        case .diff, .files: state.open(surface.kind)
        case .file(let path, let line, _): state.openFile(path, line: line)
        }
    }

    public mutating func removeThreads(where drop: (String) -> Bool) { entries.removeAll { drop($0.threadKey) } }
}
