import SpaceModel

/// A missing parent, a cycle or any trashed ancestor hides a page and its content.
struct PageHierarchy: Sendable {
    struct Node: Sendable {
        var parent: PageID?
        var title: String
        var trashed: Bool
    }

    var nodes: [PageID: Node] = [:]
    private(set) var visibleIDs: Set<PageID> = []

    init(_ pages: [PageID: PageRecord]) {
        nodes = pages.mapValues { Node(parent: $0.parent, title: $0.title, trashed: $0.trashed) }
        rebuildVisibility()
    }

    mutating func update(_ id: PageID, node: Node?) {
        let old = nodes[id]
        nodes[id] = node
        if old == nil || node == nil || old?.parent != node?.parent || old?.trashed != node?.trashed {
            rebuildVisibility()
        }
    }

    private mutating func rebuildVisibility() {
        var visible: Set<PageID> = [], hidden: Set<PageID> = []
        for id in nodes.keys where !visible.contains(id) && !hidden.contains(id) {
            var path: Set<PageID> = []
            var current: PageID? = id
            var shown = true
            while let next = current {
                if visible.contains(next) { break }
                guard !hidden.contains(next), path.insert(next).inserted,
                      let node = nodes[next], !node.trashed else { shown = false; break }
                current = node.parent
            }
            if shown { visible.formUnion(path) } else { hidden.formUnion(path) }
        }
        visibleIDs = visible
    }

    func path(to id: PageID) -> [PageID]? {
        var path: [PageID] = []
        var seen: Set<PageID> = []
        var current: PageID? = id
        while let next = current {
            guard seen.insert(next).inserted, let node = nodes[next], !node.trashed else { return nil }
            path.append(next)
            current = node.parent
        }
        return path.reversed()
    }
}
