import CoreGraphics
import T3Protocol
import T3Store

/// The thread list as T3's sortable sees it (Sidebar.logic.ts:150-264): thread rows plus the structural
/// markers. Markers are zero height at rest; during a drag the boundaries open 24pt for their labels
/// and an empty section's placeholder opens a 36pt target.
enum SidebarSortMarker: Sendable {
    /// The top boundary, also the landing target when there are no pins.
    case pinnedHeader
    /// The boundary between pinned and active rows.
    case pinnedDivider
    case activePlaceholder
    case workingHeader
    case snoozedHeader
    case settledHeader
    case settledPlaceholder

    var isShelfHeader: Bool { self == .workingHeader || self == .snoozedHeader || self == .settledHeader }
    var isBoundary: Bool { self == .pinnedHeader || self == .pinnedDivider }
    var isPlaceholder: Bool { self == .activePlaceholder || self == .settledPlaceholder }
}

enum SidebarSortItem: Equatable, Sendable {
    case thread(ThreadId, SidebarSection)
    case marker(SidebarSortMarker)

    var threadId: ThreadId? { if case .thread(let id, _) = self { id } else { nil } }
    var marker: SidebarSortMarker? { if case .marker(let m) = self { m } else { nil } }
}

/// `SidebarDropTarget`: the destination section and the manual orders after the move.
public struct SidebarDropTarget: Equatable, Sendable {
    public var section: SidebarSection
    public var pinnedOrder: [ThreadId]
    public var activeOrder: [ThreadId]
}

/// `SidebarDropVerb` (Sidebar.logic.ts:257-276): what a drop does, shown on the lifted row.
public enum SidebarDropVerb: Sendable {
    case pin, unpin, settle, unsettle, wake

    public static func resolve(from: SidebarSection, to: SidebarSection?) -> SidebarDropVerb? {
        guard let to, to != from, to != .working, to != .snoozed else { return nil }
        if to == .pinned { return .pin }
        if to == .settled { return .settle }
        if from == .pinned { return .unpin }
        if from == .settled { return .unsettle }
        return .wake
    }

    var title: String {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .settle: "Settle"
        case .unsettle: "Un-settle"
        case .wake: "Wake"
        }
    }
}

enum SidebarSortPlanner {
    /// `SIDEBAR_DRAG_LABEL_HEIGHT`: room each pinned boundary opens for its label while dragging.
    static let labelHeight: CGFloat = 24
    static let cardHeight: CGFloat = 82
    static let slimHeight: CGFloat = 36

    /// `sidebarListItems` (Sidebar.tsx:3781-3829) from the rendered list: indices into `list` for each
    /// sortable item, nil for markers that have no row of their own.
    static func items(_ list: [SidebarItem]) -> (items: [SidebarSortItem], rows: [Int?]) {
        var items: [SidebarSortItem] = [], rows: [Int?] = []
        func add(_ item: SidebarSortItem, _ row: Int?) { items.append(item); rows.append(row) }
        let threads = list.indices.filter {
            if case .row = list[$0] { true } else if case .shelfHeader = list[$0] { true } else { false }
        }
        guard !threads.isEmpty else { return ([], []) }
        add(.marker(.pinnedHeader), nil)
        var dividerAdded = false
        func divider() {
            guard !dividerAdded else { return }
            dividerAdded = true
            add(.marker(.pinnedDivider), nil)
            add(.marker(.activePlaceholder), nil)
        }
        for i in threads {
            switch list[i] {
            case .row(let r):
                if r.section != .pinned { divider() }
                add(.thread(r.id, r.section), i)
            case .shelfHeader(let shelf, _, _):
                divider()
                switch shelf {
                case .working: add(.marker(.workingHeader), i)
                case .snoozed: add(.marker(.snoozedHeader), i)
                case .settled: add(.marker(.settledHeader), i); add(.marker(.settledPlaceholder), nil)
                }
            default: break
            }
        }
        divider()
        return (items, rows)
    }

    /// `sectionAtSidebarSlot`: the section a slot belongs to, read off the markers above it.
    static func section(at index: Int, in items: [SidebarSortItem]) -> SidebarSection {
        var section = SidebarSection.pinned
        for item in items.prefix(index) {
            switch item.marker {
            case .pinnedDivider?: section = .active
            case .workingHeader?: section = .working
            case .snoozedHeader?: section = .snoozed
            case .settledHeader?: section = .settled
            default: break
            }
        }
        return section
    }

    /// `resolveSidebarDropTarget`: move the lifted row to `over` and read the section and orders.
    static func target(_ items: [SidebarSortItem], active: Int, over: Int) -> SidebarDropTarget? {
        guard items.indices.contains(active), items.indices.contains(over), items[active].threadId != nil else { return nil }
        var moved = items
        let lifted = moved.remove(at: active)
        moved.insert(lifted, at: min(over, moved.count))
        let section = section(at: over, in: moved)
        guard section != .working, section != .snoozed else { return nil }
        var pinned: [ThreadId] = [], activeOrder: [ThreadId] = []
        var current = SidebarSection.pinned
        loop: for item in moved {
            switch item {
            case .marker(.pinnedDivider): current = .active
            case .marker(let m) where m.isShelfHeader: break loop
            case .marker: break
            case .thread(let id, _): if current == .pinned { pinned.append(id) } else { activeOrder.append(id) }
            }
        }
        return SidebarDropTarget(section: section, pinnedOrder: pinned, activeOrder: activeOrder)
    }

    /// The parts of the list state the preview reads (`createSidebarSortingStrategy` inputs).
    struct Context: Equatable {
        var settledExpanded = false
        var settledVisibleCount = SidebarListBuilder.settledInitialCount
        var routeThreadId: ThreadId?
        var snoozedCount = 0
        /// Working beta: the inbox is time-ordered, so the lifted row previews at the top.
        var activeTimeOrdered = false
    }

    /// `createSidebarSortingStrategy.project` (Sidebar.drag.ts:100-245): each item's top in the preview
    /// of dropping `active` on `target`, nil for items the preview hides. `tops` and `heights` are
    /// the resting layout, markers zero high.
    static func project(_ items: [SidebarSortItem], tops: [CGFloat], heights: [CGFloat], active: Int,
                        target: SidebarDropTarget, context: Context) -> [CGFloat?] {
        guard case .thread(let activeId, let activeSection)? = items.indices.contains(active) ? items[active] : nil,
              let firstTop = tops.first else { return [] }
        var groups: [SidebarSection: [SidebarSortItem]] = [:]
        for item in items {
            if case .thread(let id, let section) = item, id != activeId { groups[section, default: []].append(item) }
        }
        let lifted = SidebarSortItem.thread(activeId, target.section)
        switch target.section {
        case .pinned, .active:
            // Pinned and active keep the dragged position; the time-ordered inbox shows the landing slot.
            let order = target.section == .pinned ? target.pinnedOrder : target.activeOrder
            let rank = target.section == .active && context.activeTimeOrdered ? -1 : (order.firstIndex(of: activeId) ?? Int.max)
            var group = groups[target.section] ?? []
            let at = group.firstIndex { (order.firstIndex(of: $0.threadId!) ?? Int.max) > rank } ?? group.count
            group.insert(lifted, at: at)
            groups[target.section] = group
        case .settled:
            // Settled history orders by when work ended, so a thread settled now lands first.
            // ponytail: rendered settled rows stand in for the whole shelf; read sortSettledThreads if a hidden row matters
            groups[.settled] = [lifted] + (groups[.settled] ?? [])
        case .working, .snoozed: break
        }
        let settledOrder = groups[.settled] ?? []
        var settled = context.settledExpanded ? Array(settledOrder.prefix(context.settledVisibleCount)) : []
        if let route = context.routeThreadId, !settled.contains(where: { $0.threadId == route }),
           let routeRow = settledOrder.first(where: { $0.threadId == route }) {
            settled.append(routeRow)
        }
        groups[.settled] = settled

        var projected: [SidebarSortItem] = []
        func section(_ s: SidebarSection, placeholder: SidebarSortMarker) {
            if let rows = groups[s], !rows.isEmpty { projected += rows } else { projected.append(.marker(placeholder)) }
        }
        projected.append(.marker(.pinnedHeader))
        projected += groups[.pinned] ?? []
        projected.append(.marker(.pinnedDivider))
        section(.active, placeholder: .activePlaceholder)
        if items.contains(.marker(.workingHeader)) {
            projected.append(.marker(.workingHeader))
            projected += groups[.working] ?? []
        }
        if !(groups[.snoozed] ?? []).isEmpty
            || ((activeSection != .snoozed || context.snoozedCount > 1) && items.contains(.marker(.snoozedHeader))) {
            projected.append(.marker(.snoozedHeader))
            projected += groups[.snoozed] ?? []
        }
        projected.append(.marker(.settledHeader))
        section(.settled, placeholder: .settledPlaceholder)

        func key(_ item: SidebarSortItem) -> SidebarSortItem {
            if case .thread(let id, _) = item { return .thread(id, .pinned) }
            return item
        }
        var indexByKey: [SidebarSortItem: Int] = [:]
        for (i, item) in items.enumerated() { indexByKey[key(item)] = i }
        let projectedHeights = projected.map { item -> CGFloat in
            switch item {
            case .marker(let m) where m.isBoundary: return labelHeight
            case .marker(let m) where m.isPlaceholder: return slimHeight
            case .thread(let id, let s) where id == activeId: return s == .pinned || s == .active || s == .working ? cardHeight : slimHeight
            default: return indexByKey[key(item)].map { heights[$0] } ?? slimHeight
            }
        }
        // The shelf's auto margin gives room to the labels and resized rows, keeping the shelves at
        // their measured bottom.
        var shelfSpace: CGFloat = 0
        if let firstShelf = items.firstIndex(where: { $0.marker?.isShelfHeader == true }), firstShelf > 0,
           tops[firstShelf] > tops[firstShelf - 1] + heights[firstShelf - 1] + 1, let lastTop = tops.last, let lastHeight = heights.last {
            shelfSpace = max(0, lastTop + lastHeight - firstTop - (projectedHeights.reduce(0) { $0 + $1 + 1 } - 1))
        }
        var result = [CGFloat?](repeating: nil, count: items.count)
        var top = firstTop
        for (p, item) in projected.enumerated() {
            if item.marker?.isShelfHeader == true { top += shelfSpace; shelfSpace = 0 }
            if let i = indexByKey[key(item)] { result[i] = top }
            top += projectedHeights[p] + 1
        }
        result[active] = tops[active]
        return result
    }
}

extension SidebarSortItem: Hashable {}
extension SidebarSortMarker: Hashable {}
