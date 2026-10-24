import SpaceModel

/// A missing parent, a cycle or any trashed ancestor hides a page and its content.
struct PageHierarchy: Sendable {
    struct Node: Sendable {
        var parent: PageID?
        var title: String
        var trashed: Bool
    }

    var nodes: [PageID: Node] = [:]

    init(_ pages: [PageID: PageRecord]) {
        nodes = pages.mapValues { Node(parent: $0.parent, title: $0.title, trashed: $0.trashed) }
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
