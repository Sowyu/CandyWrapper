import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `SidebarDragBoundary` (Sidebar.tsx:753-786): the "Pinned" or "Active" label and its rule that open
/// between the pinned and active blocks while a row is dragged. `absolute inset-x-2 top-1 h-4 gap-2`,
/// `text-xs font-medium`.
final class SidebarSortBoundaryView: DSView {
    private let label: LabelView
    private let rule = CALayer()
    var isDropTarget = false { didSet { if isDropTarget != oldValue { updateLayer() } } }

    init(_ title: String) {
        label = LabelView(title, font: DSFont.ui(12, weight: .medium))
        super.init(frame: .zero)
        label.lineHeight = 16
        addSubview(label)
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(rule)
    }

    override func layout() {
        super.layout()
        let w = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 8, y: 4, width: w, height: 16)
        rule.frame = CGRect(x: 8 + w + 8, y: 12, width: max(0, bounds.width - 16 - w - 8), height: 1)
    }

    override func updateLayer() {
        label.color = isDropTarget ? SB.c(\.primary) : SB.c(\.sidebarForeground, 0.8)
        rule.backgroundColor = (isDropTarget ? SB.c(\.primary, 0.5) : SB.c(\.sidebarForeground, 0.25)).cgColor(in: self)
    }

    /// `.sidebar-drag-boundary-label` (index.css:2207-2219): hidden for 200 ms, then shown, so the rows
    /// open their room before the labels paint.
    func reveal() {
        guard let layer, !Motion.reduced else { return }
        // Held at zero, then removed: the model's full opacity shows at once (`step-end`).
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 0
        a.duration = 0.2
        layer.add(a, forKey: "reveal")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `SidebarSectionPlaceholder` (Sidebar.tsx:713-741): where a dragged row lands in an empty section.
/// `h-9 rounded-md border border-dashed border-sidebar-foreground/25 text-xs text-sidebar-foreground/80`,
/// `border-primary/40 bg-primary/5 text-primary` as the drop target.
final class SidebarSortPlaceholderView: DSView {
    private let label: LabelView
    private let border = CAShapeLayer()
    var isDropTarget = false { didSet { if isDropTarget != oldValue { updateLayer() } } }

    init(_ title: String) {
        label = LabelView(title, font: DSFont.ui(12))
        super.init(frame: .zero)
        label.lineHeight = 16
        label.alignment = .center
        addSubview(label)
        border.fillColor = nil
        border.lineWidth = 1
        border.lineDashPattern = [3, 3]
        border.actions = ["path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(border)
        layer?.cornerRadius = 6
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
    }

    override func updateLayer() {
        label.color = isDropTarget ? SB.c(\.primary) : SB.c(\.sidebarForeground, 0.8)
        border.strokeColor = (isDropTarget ? SB.c(\.primary, 0.4) : SB.c(\.sidebarForeground, 0.25)).cgColor(in: self)
        layer?.backgroundColor = isDropTarget ? SB.c(\.primary, 0.05).cgColor(in: self) : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One drag of a thread row (Sidebar.tsx:3460-4160): the lifted row, the planner's preview, autoscroll,
/// and the switch to a thread-context drag when the pointer leaves the list sideways.
@MainActor final class SidebarSortSession {
    let id: ThreadId
    let key: String
    let section: SidebarSection
    /// The press's distance below the row's top: the lifted row keeps it under the pointer.
    let grabOffset: CGFloat
    /// False for rows T3 cannot pick up (working rows, servers without pin ordering): only the
    /// context drag runs.
    let sortable: Bool
    let session: NSDraggingSession
    let ghost: NSImage

    var items: [SidebarSortItem] = []
    /// List index per sortable item, nil for markers.
    var rows: [Int?] = []
    var sortIndexByRow: [Int: Int] = [:]
    var tops: [CGFloat] = []
    var heights: [CGFloat] = []
    var active = 0
    var over: Int?
    var target: SidebarDropTarget?
    /// Each sortable item's top in the preview, nil where the preview hides it; empty for no preview.
    var projected: [CGFloat?] = []
    /// `restrictBelowPins`: the lifted row stays below the Pinned label.
    var minTop: CGFloat = 0
    /// Which side of the Active label the pointer last crossed to (Sidebar.drag.ts:47-80).
    var boundarySection: SidebarSection
    var previousPointerY: CGFloat?
    var validity: [Int: Bool] = [:]
    /// The pointer left the list sideways: a thread-context drag with the ghost.
    var outside = false
    /// The lifted thread left the list under the drag.
    var lost = false
    var boundaries: [SidebarSortMarker: SidebarSortBoundaryView] = [:]
    var placeholders: [SidebarSortMarker: SidebarSortPlaceholderView] = [:]
    /// The last pointer, in window coordinates.
    var pointer: NSPoint = .zero
    var autoscroll: Timer?
    var lastTick: CFTimeInterval = 0
    /// Watches for Escape while the drag runs (`SidebarPointerSensor.keydown`).
    var escape: Timer?
    /// `dragTargetSection`: none while the drag is thread context.
    var targetSection: SidebarSection? { outside ? nil : target?.section }
    var previewing: Bool { !outside && !projected.isEmpty }

    init(id: ThreadId, section: SidebarSection, grabOffset: CGFloat, sortable: Bool, session: NSDraggingSession, ghost: NSImage) {
        self.id = id
        key = "thread:\(id.rawValue)"
        self.section = section
        self.grabOffset = grabOffset
        self.sortable = sortable
        self.session = session
        self.ghost = ghost
        boundarySection = section == .pinned ? .pinned : .active
    }
}

extension SidebarListView: NSDraggingSource {
    /// `SIDEBAR_DRAG_DISTANCE`: the pointer moves this far before a press becomes a drag.
    static let dragDistance: CGFloat = 6
    /// dnd-kit's sortable transition, `transform 200ms ease`.
    static let sortDuration: CFTimeInterval = 0.2

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : []
    }

    /// A row left its press: lift it in the list, and drag it (or the whole selection it belongs to) as
    /// thread context once the pointer leaves the list.
    func beginThreadDrag(_ row: SidebarRowBase, _ id: ThreadId, event: NSEvent, press: NSPoint) {
        closeHoverCard()
        let rows = items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        // The multi-selection when the picked-up row is part of it (Sidebar.tsx:3487-3497).
        let selected = rows.filter(\.isSelected).map(\.id)
        let ids = selected.contains(id) ? selected : [id]
        let model = rows.first { $0.id == id }
        let title = model?.title.trimmingCharacters(in: .whitespaces) ?? ""
        let item = NSPasteboardItem()
        item.setString(ids.map(\.rawValue).joined(separator: "\n"), forType: .sidebarThreads)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let ghostView = SidebarThreadDragGhostView(title: title.isEmpty ? "Thread" : title, count: ids.count)
        ghostView.appearance = effectiveAppearance
        let ghost = ghostView.image()
        // `disabled`: renaming, the Working shelf, and servers that cannot store a pin order (Sidebar.tsx:5374-5384).
        let sortable = model.map { !$0.isRenaming && $0.section != .working && canSortThread?($0.id) == true } ?? false
        let point = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(ghostFrame(point, size: ghost.size), contents: sortable ? Self.clearImage(ghost.size) : ghost)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        guard let model, let i = indexByKey["thread:\(id.rawValue)"] else { return }
        let s = SidebarSortSession(id: id, section: model.section, grabOffset: convert(press, from: nil).y - tops[i],
                                   sortable: sortable, session: session, ghost: ghost)
        s.outside = !sortable
        sort = s
        guard sortable else { return }
        // AppKit's drag loop keeps key events from the app, so Escape is read off the keyboard state,
        // only while a sort runs.
        let escape = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if CGEventSource.keyState(.combinedSessionState, key: 53) { self?.endSort(commit: false) }
            }
        }
        RunLoop.main.add(escape, forMode: .common)
        s.escape = escape
        visible[s.key]?.layer?.zPosition = 10
        rebuildSortPlan(animated: false)
        moveSort(to: event.locationInWindow)
    }

    /// The drag image while the row itself is lifted: drawn, but empty.
    private static func clearImage(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in true }
    }

    /// `translate(x + 12px, y + 12px)`: the ghost hangs below and right of the pointer.
    private func ghostFrame(_ point: NSPoint, size: NSSize) -> NSRect {
        NSRect(x: point.x + 12, y: point.y + 12, width: size.width, height: size.height)
    }

    public func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window, sort?.session === session else { return }
        moveSort(to: window.convertPoint(fromScreen: screenPoint))
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard sort?.session === session else { return }
        // Escape cancels; a release anywhere beside the list drops (SidebarPointerSensor).
        endSort(commit: NSApp.currentEvent?.type != .keyDown)
    }

    // MARK: Planning

    /// The sortable items and their resting geometry; markers sit at the slot they open in. Runs at
    /// pickup and whenever the list changes under the drag.
    func rebuildSortPlan(animated: Bool) {
        guard let s = sort, s.sortable else { return }
        if let sortContextProvider { sortContext = sortContextProvider() }
        (s.items, s.rows) = SidebarSortPlanner.items(items)
        s.sortIndexByRow = [:]
        s.tops = []
        s.heights = []
        s.validity = [:]
        var cursor: CGFloat = 0
        if let first = s.rows.compactMap({ $0 }).first, first > 0 { cursor = tops[first - 1] + items[first - 1].height + Self.gap }
        for (j, row) in s.rows.enumerated() {
            if let row {
                s.sortIndexByRow[row] = j
                s.tops.append(tops[row])
                s.heights.append(items[row].height)
                cursor = tops[row] + items[row].height + Self.gap
            } else {
                // Zero high, `-mb-px` cancels its gap.
                s.tops.append(cursor)
                s.heights.append(0)
            }
        }
        guard let active = s.items.firstIndex(of: .thread(s.id, s.section)) else {
            // The row left the list (another client moved it): T3 cancels the sort; the rest is thread context.
            s.lost = true
            s.outside = true
            s.over = nil
            s.target = nil
            s.projected = []
            setDragImage(ghost: true)
            placeSorted(animated: animated)
            return
        }
        s.active = active
        s.minTop = (s.items.firstIndex(of: .marker(.pinnedHeader)).map { s.tops[$0] } ?? 0) + SidebarSortPlanner.labelHeight
        if !(s.over.map { s.items.indices.contains($0) } ?? false) { s.over = active }
        project()
        placeSorted(animated: animated)
    }

    private func project() {
        guard let s = sort, let over = s.over else { return }
        s.target = SidebarSortPlanner.target(s.items, active: s.active, over: over)
        s.projected = s.target.map {
            SidebarSortPlanner.project(s.items, tops: s.tops, heights: s.heights, active: s.active, target: $0, context: sortContext)
        } ?? []
    }

    private func shownTop(_ j: Int) -> CGFloat {
        guard let s = sort else { return 0 }
        return s.projected.isEmpty ? s.tops[j] : s.projected[j] ?? s.tops[j]
    }

    /// `createSidebarCollisionDetection` over dnd-kit's `closestCenter` (Sidebar.drag.ts:35-97).
    private func collide(liftedTop: CGFloat, pointer p: NSPoint) -> Int {
        guard let s = sort else { return 0 }
        let center = liftedTop + s.heights[s.active] / 2
        func distance(_ j: Int) -> CGFloat { abs(center - (s.tops[j] + s.heights[j] / 2)) }
        var order = s.items.indices.sorted { distance($0) == distance($1) ? $0 < $1 : distance($0) < distance($1) }
        if let divider = s.items.firstIndex(of: .marker(.pinnedDivider)) {
            // The Active label as drawn. Only pointer movement changes sides: opening the destination
            // moves the label, but must not flip a still gesture back.
            let labelTop = shownTop(divider) + 4
            let previous = s.previousPointerY ?? p.y
            s.previousPointerY = p.y
            if p.x >= Self.padding + 10, p.x <= bounds.width - Self.padding - 10 {
                if p.y < previous && p.y <= labelTop + 16 { s.boundarySection = .pinned }
                else if p.y > previous && p.y >= labelTop { s.boundarySection = .active }
                let activeBottom = s.items.firstIndex { $0.marker?.isShelfHeader == true }.map(shownTop)
                if s.boundarySection == .pinned || activeBottom.map({ p.y < $0 }) == true,
                   let k = order.firstIndex(where: { SidebarSortPlanner.target(s.items, active: s.active, over: $0)?.section == s.boundarySection }) {
                    order.insert(order.remove(at: k), at: 0)
                }
            }
        }
        // Reject an unsupported nearest target without picking another section.
        guard let nearest = order.first, nearest != s.active else { return s.active }
        if s.validity[nearest] == nil {
            s.validity[nearest] = SidebarSortPlanner.target(s.items, active: s.active, over: nearest)
                .map { canSortDrop?(s.id, s.section, $0) == true } ?? false
        }
        return s.validity[nearest] == true ? nearest : s.active
    }

    // MARK: Pointer

    func moveSort(to windowPoint: NSPoint) {
        guard let s = sort, s.sortable else { return }
        s.pointer = windowPoint
        let p = convert(windowPoint, from: nil)
        // The drag becomes thread context once the pointer leaves the list's sides (Sidebar.tsx:3498-3520).
        let outside = s.lost || p.x < Self.padding || p.x > bounds.width - Self.padding
        if outside != s.outside {
            s.outside = outside
            setDragImage(ghost: outside)
            if !outside {
                s.previousPointerY = nil
                visible[s.key]?.layer?.zPosition = 10
            }
            placeSorted(animated: true)
        }
        updateAutoscroll()
        guard !outside, let lifted = visible[s.key] else { return }
        // `restrictBelowPins`, then `restrictToFirstScrollableAncestor`.
        let rect = visibleRect
        var top = max(p.y - s.grabOffset, s.minTop)
        top = min(max(top, rect.minY), rect.maxY - lifted.frame.height)
        lifted.layer?.removeAllAnimations()
        lifted.frame.origin.y = top
        let over = collide(liftedTop: top, pointer: p)
        if over != s.over {
            s.over = over
            project()
            placeSorted(animated: true)
        }
    }

    /// Swaps the drag image: nothing while the row itself is lifted, the ghost as thread context.
    private func setDragImage(ghost: Bool) {
        guard let s = sort else { return }
        // The drag loop's own pointer: the window's mouse location lags a fast crossing.
        let frame = ghostFrame(convert(s.pointer, from: nil), size: s.ghost.size)
        let image = ghost ? s.ghost : Self.clearImage(s.ghost.size)
        s.session.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(frame, contents: image)
        }
    }

    // MARK: Preview

    /// Puts every row where the preview wants it, and the markers, and styles the lifted row.
    func placeSorted(animated: Bool) {
        guard let s = sort, s.sortable else { return }
        let animate = animated && !Motion.reduced
        for (key, view) in visible {
            guard let i = indexByKey[key] else { continue }
            if key == s.key {
                guard let row = view as? SidebarRowBase else { continue }
                if s.outside {
                    // The lifted row glides home as the ghost takes over (Sidebar.tsx:666-668).
                    let rest = frame(at: i)
                    if view.frame.minY != rest.minY {
                        let from = view.frame.minY - rest.minY
                        view.frame = rest
                        if animate { slide(view, from: from) }
                    }
                    row.lift = nil
                } else {
                    row.lift = SidebarRowBase.Lift(verb: SidebarDropVerb.resolve(from: s.section, to: s.targetSection),
                                                   overPinned: s.targetSection == .pinned)
                }
                continue
            }
            var y = tops[i]
            var hidden = false
            if s.previewing, let j = s.sortIndexByRow[i] {
                if let t = s.projected[j] { y = t } else { hidden = true }
            }
            if view.isHidden != hidden { view.isHidden = hidden }
            if view.frame.minY != y {
                let from = view.frame.minY - y
                view.frame.origin.y = y
                if animate { sortSlide(view, from: from) }
            }
            if let shelf = view as? SidebarShelfRowView, case .shelfHeader(.settled, _, _)? = shelf.item {
                // `dragging={from !== null}`, accent while it is the target.
                shelf.dragTone = s.outside ? nil : s.targetSection == .settled ? .accent : .emphasized
            }
        }
        placeMarkers(animated: animate)
    }

    private func placeMarkers(animated: Bool) {
        guard let s = sort else { return }
        let width = max(0, bounds.width - Self.padding * 2 - 4)
        let target = s.targetSection
        for (marker, title) in [(SidebarSortMarker.pinnedHeader, "Pinned"), (.pinnedDivider, "Active")] {
            guard s.previewing, let j = s.items.firstIndex(of: .marker(marker)), let y = s.projected[j] else {
                s.boundaries[marker]?.removeFromSuperview()
                s.boundaries[marker] = nil
                continue
            }
            if let view = s.boundaries[marker] {
                if view.frame.minY != y {
                    let from = view.frame.minY - y
                    view.frame.origin.y = y
                    if animated { sortSlide(view, from: from) }
                }
            } else {
                let view = SidebarSortBoundaryView(title)
                view.frame = NSRect(x: Self.padding + 2, y: y, width: width, height: SidebarSortPlanner.labelHeight)
                addSubview(view)
                view.reveal()
                s.boundaries[marker] = view
            }
            s.boundaries[marker]?.isDropTarget = target == (marker == .pinnedHeader ? .pinned : .active)
        }
        // Empty targets show while they are a place to land (Sidebar.tsx:5433-5449, 5501-5518).
        func count(_ section: SidebarSection) -> Int {
            items.reduce(0) { if case .row(let r) = $1, r.section == section { $0 + 1 } else { $0 } }
        }
        for (marker, title, section) in [(SidebarSortMarker.activePlaceholder, "Active", SidebarSection.active),
                                         (.settledPlaceholder, "Settled", .settled)] {
            let n = count(section)
            let hint = n == 0 || (s.section == section && n == 1 && target != nil && target != section)
            guard s.previewing, hint, let j = s.items.firstIndex(of: .marker(marker)), let y = s.projected[j] else {
                s.placeholders[marker]?.removeFromSuperview()
                s.placeholders[marker] = nil
                continue
            }
            // A newly revealed target must not slide from its hidden position.
            let view = s.placeholders[marker] ?? SidebarSortPlaceholderView(title)
            if view.superview == nil { addSubview(view); s.placeholders[marker] = view }
            view.frame = NSRect(x: Self.padding + 2, y: y, width: width, height: SidebarSortPlanner.slimHeight)
            view.isDropTarget = target == section
        }
    }

    /// dnd-kit's `transform 200ms ease`, additive so a change in flight continues from where it is.
    private func sortSlide(_ view: NSView, from offset: CGFloat) {
        guard let layer = view.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = offset
        a.toValue = 0
        a.isAdditive = true
        a.duration = Self.sortDuration
        a.timingFunction = CAMediaTimingFunction(name: .default) // CSS `ease`
        layer.add(a, forKey: nil)
    }

    // MARK: Autoscroll (dnd-kit's defaults: 20% edge zones, up to 10 points per 5 ms)

    private func updateAutoscroll() {
        guard let s = sort else { return }
        let scrolling = !s.outside && autoscrollSpeed() != 0
        if !scrolling {
            s.autoscroll?.invalidate()
            s.autoscroll = nil
        } else if s.autoscroll == nil {
            s.lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            s.autoscroll = timer
        }
    }

    /// Points per second, negative upward: full speed at the edge, nothing at the zone's inner side.
    private func autoscrollSpeed() -> CGFloat {
        guard let s = sort, let clip = enclosingScrollView?.contentView else { return 0 }
        let p = clip.convert(s.pointer, from: nil)
        let rect = clip.bounds
        let threshold = rect.height * 0.2
        guard threshold > 0 else { return 0 }
        // ponytail: capped at the edge speed; dnd-kit keeps accelerating past the edge, add if a fast fling feels slow
        if p.y - rect.minY <= threshold, rect.minY > 0 { return -2000 * min(1, (threshold - (p.y - rect.minY)) / threshold) }
        if rect.maxY - p.y <= threshold, rect.maxY < frame.height { return 2000 * min(1, (threshold - (rect.maxY - p.y)) / threshold) }
        return 0
    }

    private func autoscrollTick() {
        guard let s = sort, let clip = enclosingScrollView?.contentView else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - s.lastTick)
        s.lastTick = now
        let speed = autoscrollSpeed()
        guard speed != 0 else { return updateAutoscroll() }
        let y = min(max(0, frame.height - clip.bounds.height), max(0, clip.bounds.minY + speed * dt))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        moveSort(to: s.pointer)
    }

    // MARK: Drop

    /// Ends the drag. A drop in the list hands the plan to the app and the rows wait where the preview
    /// left them for the new order; otherwise they glide back (Sidebar.tsx:3842-3858, Sidebar.motion.ts).
    func endSort(commit: Bool) {
        guard let s = sort else { return }
        s.autoscroll?.invalidate()
        s.escape?.invalidate()
        sort = nil
        for view in s.boundaries.values { view.removeFromSuperview() }
        for view in s.placeholders.values { view.removeFromSuperview() }
        var released: [String: CGFloat] = [:]
        for (key, view) in visible {
            released[key] = view.frame.minY
            if view.isHidden { view.isHidden = false }
            (view as? SidebarRowBase)?.lift = nil
            (view as? SidebarShelfRowView)?.dragTone = nil
        }
        visible[s.key]?.layer?.zPosition = 0
        guard s.sortable else { return }
        if commit, !s.outside, let target = s.target, let over = s.over, over != s.active,
           canSortDrop?(s.id, s.section, target) == true {
            releasedTops = released
            onSortDrop?(s.id, s.section, target)
            // The new order normally arrives within a frame or two; if it does not, glide back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let tops = self.releasedTops else { return }
                self.releasedTops = nil
                self.tile(oldTops: tops)
            }
        } else {
            tile(oldTops: released)
        }
    }
}
