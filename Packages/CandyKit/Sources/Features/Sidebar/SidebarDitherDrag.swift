import AppKit
import DesignSystem
import T3Protocol
import T3Store

extension NSPasteboard.PasteboardType {
    /// A Dither project section dragged to a new place: its group key. Only the sidebar reads it.
    static let sidebarProjectGroup = NSPasteboard.PasteboardType("dev.candywrapper.sidebar-project-group")
}

/// Where a Dither drag lands: the drop line's y in the list (nil for the Settled header, which lights up instead)
/// and what the drop does.
struct SidebarDitherDrop: Equatable {
    enum Action: Equatable {
        case thread(SidebarDropTarget)
        /// The dragged section goes before this group, or to the end for nil.
        case group(before: String?)
    }
    var lineY: CGFloat?
    var action: Action
}

/// Dither's drag planner. Dither shows Pinned and one section per project instead of T3's flat Pinned and Active
/// list, which T3's sortable preview (SidebarSortPlanner) has no slots for, so Dither drops on a line between rows:
/// - a thread reorders inside the Pinned section or its own project's section, pins when dropped in Pinned, unpins,
///   wakes or un-settles when dropped in its project, and settles on the Settled header;
/// - a project section moves between the others as a whole.
enum SidebarDitherDropPlanner {
    struct Section {
        var key: String
        var isPinned: Bool
        var header: Int
        var rows: [Int]
        var expanded: Bool
    }

    static func sections(_ items: [SidebarItem]) -> [Section] {
        var out: [Section] = []
        for (i, item) in items.enumerated() {
            switch item {
            case .projectHeader(let h): out.append(Section(key: h.key, isPinned: h.isPinned, header: i, rows: [], expanded: h.expanded))
            case .row(let r) where r.inProjectSection && !out.isEmpty: out[out.count - 1].rows.append(i)
            case .shelfHeader: return out // shelves end the sections
            default: break
            }
        }
        return out
    }

    private static func bottom(_ i: Int, _ items: [SidebarItem], _ tops: [CGFloat]) -> CGFloat { tops[i] + items[i].height }

    private static func id(_ i: Int, _ items: [SidebarItem]) -> ThreadId? {
        if case .row(let r) = items[i] { r.id } else { nil }
    }

    /// The rows shown in a section, by the list's own sections (what `planSortDrop` compares against).
    static func shown(_ items: [SidebarItem], _ section: SidebarSection) -> [ThreadId] {
        items.compactMap { if case .row(let r) = $0, r.section == section { r.id } else { nil } }
    }

    /// A thread dragged to `y`. `ownSection` is the group key of the thread's project.
    static func threadDrop(items: [SidebarItem], tops: [CGFloat], dragged: ThreadId, ownSection: String?, y: CGFloat) -> SidebarDitherDrop? {
        guard let from = items.indices.first(where: { id($0, items) == dragged }),
              case .row(let model) = items[from], model.section != .working else { return nil }
        let pinned = shown(items, .pinned), active = shown(items, .active)
        // The Settled header settles.
        if let settled = items.firstIndex(where: { if case .shelfHeader(.settled, _, _) = $0 { true } else { false } }),
           y >= tops[settled], y < bottom(settled, items, tops) {
            guard model.section != .settled else { return nil }
            return SidebarDitherDrop(lineY: nil, action: .thread(SidebarDropTarget(section: .settled, pinnedOrder: pinned, activeOrder: active)))
        }
        for s in sections(items) where s.isPinned || s.key == ownSection {
            let rows = s.expanded ? s.rows : []
            guard !rows.isEmpty || s.isPinned, y >= tops[s.header], y <= bottom(rows.last ?? s.header, items, tops) + SidebarListView.gap else { continue }
            let others = rows.filter { id($0, items) != dragged }
            // The boundaries between the rows that stay: before each, and after the last.
            var slots: [(y: CGFloat, at: Int)] = others.enumerated().map { (tops[$1] - SidebarListView.gap / 2, $0) }
            slots.append(((others.last.map { bottom($0, items, tops) } ?? bottom(s.header, items, tops)) + SidebarListView.gap / 2, others.count))
            guard let slot = slots.min(by: { abs($0.y - y) < abs($1.y - y) }) else { return nil }
            let ids = others.compactMap { id($0, items) }
            let target: SidebarDropTarget
            if s.isPinned {
                var order = pinned.filter { $0 != dragged }
                order.insert(dragged, at: slot.at < ids.count ? order.firstIndex(of: ids[slot.at]) ?? order.count : order.count)
                target = SidebarDropTarget(section: .pinned, pinnedOrder: order, activeOrder: active.filter { $0 != dragged })
                if model.section == .pinned && order == pinned { return nil }
            } else {
                guard !ids.isEmpty else { return nil }
                var order = active.filter { $0 != dragged }
                let at = slot.at < ids.count ? order.firstIndex(of: ids[slot.at]) : order.firstIndex(of: ids[ids.count - 1]).map { $0 + 1 }
                order.insert(dragged, at: at ?? order.count)
                target = SidebarDropTarget(section: .active, pinnedOrder: pinned.filter { $0 != dragged }, activeOrder: order)
                if model.section == .active && order == active { return nil }
            }
            return SidebarDitherDrop(lineY: slot.y, action: .thread(target))
        }
        return nil
    }

    /// A project section dragged to `y`: the nearest boundary between sections, nil where the drop changes nothing.
    static func groupDrop(items: [SidebarItem], tops: [CGFloat], dragged: String, y: CGFloat) -> SidebarDitherDrop? {
        let projects = sections(items).filter { !$0.isPinned }
        guard let from = projects.firstIndex(where: { $0.key == dragged }), let last = projects.last else { return nil }
        var slots: [(y: CGFloat, at: Int)] = projects.indices.map { (tops[projects[$0].header], $0) }
        slots.append((bottom(last.rows.last ?? last.header, items, tops) + SidebarListView.gap / 2, projects.count))
        guard let slot = slots.min(by: { abs($0.y - y) < abs($1.y - y) }), slot.at != from, slot.at != from + 1 else { return nil }
        return SidebarDitherDrop(lineY: slot.y, action: .group(before: slot.at < projects.count ? projects[slot.at].key : nil))
    }

    /// The rows a section drag carries: its header and its rows.
    static func groupKeys(_ items: [SidebarItem], _ key: String) -> Set<String> {
        guard let s = sections(items).first(where: { $0.key == key }) else { return [] }
        return Set(([s.header] + s.rows).map { items[$0].key })
    }
}

/// The drop line: 2pt in the primary color with round ends.
final class SidebarDropLineView: DSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 1
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = SB.c(\.primary).cgColor(in: self) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One Dither drag: a thread row or a project section. The dragged rows dim, the ghost follows the pointer, and the
/// drop line shows where they land. Leaving the list sideways turns a thread drag into thread context, as in T3.
@MainActor final class SidebarDitherDragSession {
    enum Subject: Equatable { case thread(ThreadId, SidebarSection), group(String) }
    let subject: Subject
    let session: NSDraggingSession
    let dimmed: Set<String>
    var drop: SidebarDitherDrop?
    var line: SidebarDropLineView?

    init(subject: Subject, session: NSDraggingSession, dimmed: Set<String>) {
        self.subject = subject
        self.session = session
        self.dimmed = dimmed
    }
}

extension SidebarListView {
    static let ditherDimAlpha: CGFloat = 0.4

    func ditherDimmed(_ key: String) -> Bool { ditherDrag?.dimmed.contains(key) == true }

    /// A Dither thread row moved `dragDistance` from its press.
    func beginDitherThreadDrag(_ model: SidebarRowModel, ids: [ThreadId], event: NSEvent) {
        let title = model.title.trimmingCharacters(in: .whitespaces)
        let item = NSPasteboardItem()
        item.setString(ids.map(\.rawValue).joined(separator: "\n"), forType: .sidebarThreads)
        let ghost = SidebarThreadDragGhostView(title: title.isEmpty ? "Thread" : title, count: ids.count)
        startDitherDrag(.thread(model.id, model.section), item: item, ghost: ghost, dimmed: ["thread:\(model.id.rawValue)"], event: event)
    }

    /// A Dither project header moved `dragDistance` from its press: the section moves as a whole.
    func beginDitherGroupDrag(_ header: SidebarProjectHeaderModel, event: NSEvent) {
        closeHoverCard()
        let item = NSPasteboardItem()
        item.setString(header.key, forType: .sidebarProjectGroup)
        let ghost = SidebarThreadDragGhostView(title: header.label, count: 1, icon: .folder)
        startDitherDrag(.group(header.key), item: item, ghost: ghost, dimmed: SidebarDitherDropPlanner.groupKeys(items, header.key), event: event)
    }

    private func startDitherDrag(_ subject: SidebarDitherDragSession.Subject, item: NSPasteboardItem, ghost view: SidebarThreadDragGhostView,
                                 dimmed: Set<String>, event: NSEvent) {
        view.appearance = effectiveAppearance
        let ghost = view.image()
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let p = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: p.x + 12, y: p.y + 12, width: ghost.size.width, height: ghost.size.height), contents: ghost)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        ditherDrag = SidebarDitherDragSession(subject: subject, session: session, dimmed: dimmed)
        for (key, view) in visible where dimmed.contains(key) { view.alphaValue = Self.ditherDimAlpha }
        moveDitherDrag(to: event.locationInWindow)
    }

    func moveDitherDrag(to windowPoint: NSPoint) {
        guard let d = ditherDrag else { return }
        let p = convert(windowPoint, from: nil)
        var drop: SidebarDitherDrop?
        if p.x >= Self.padding, p.x <= bounds.width - Self.padding {
            switch d.subject {
            case .thread(let id, let section):
                drop = SidebarDitherDropPlanner.threadDrop(items: items, tops: tops, dragged: id, ownSection: projectSectionKey?(id), y: p.y)
                if case .thread(let target)? = drop?.action, canSortDrop?(id, section, target) != true { drop = nil }
            case .group(let key):
                drop = SidebarDitherDropPlanner.groupDrop(items: items, tops: tops, dragged: key, y: p.y)
            }
        }
        guard drop != d.drop else { return }
        d.drop = drop
        if let y = drop?.lineY {
            let line = d.line ?? SidebarDropLineView()
            if line.superview == nil { addSubview(line); d.line = line }
            line.layer?.zPosition = 20
            line.frame = NSRect(x: Self.padding + 4, y: (y - 1).rounded(), width: max(0, bounds.width - Self.padding * 2 - 8), height: 2)
            line.isHidden = false
        } else {
            d.line?.isHidden = true
        }
        let settling: Bool = if case .thread(let t)? = drop?.action { t.section == .settled } else { false }
        for view in visible.values {
            if let shelf = view as? SidebarShelfRowView, case .shelfHeader(.settled, _, _)? = shelf.item {
                shelf.dragTone = settling ? .accent : nil
            }
        }
    }

    /// The release: a drop with a line (or on Settled) commits, anything else leaves the order alone.
    func endDitherDrag(commit: Bool) {
        guard let d = ditherDrag else { return }
        ditherDrag = nil
        d.line?.removeFromSuperview()
        for view in visible.values {
            view.alphaValue = 1
            (view as? SidebarShelfRowView)?.dragTone = nil
        }
        guard commit, let drop = d.drop else { return }
        switch (d.subject, drop.action) {
        case (.thread(let id, let section), .thread(let target)): onSortDrop?(id, section, target)
        case (.group(let key), .group(let before)): onGroupDrop?(key, before)
        default: break
        }
    }
}
