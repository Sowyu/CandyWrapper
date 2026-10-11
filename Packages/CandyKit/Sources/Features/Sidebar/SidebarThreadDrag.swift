import AppKit
import DesignSystem
import T3Protocol

extension NSPasteboard.PasteboardType {
    /// Sidebar threads dragged out of the list (`THREAD_CONTEXT_DROP_EVENT`, threadContextDrag.ts): their
    /// scoped ids, one per line. The composer turns them into thread context.
    public static let sidebarThreads = NSPasteboard.PasteboardType("application/x-t3code-sidebar-threads")
}

/// Reads the dragged sidebar threads off a pasteboard.
public enum SidebarThreadDrag {
    public static func threads(_ pasteboard: NSPasteboard) -> [ThreadId]? {
        guard let text = pasteboard.string(forType: .sidebarThreads) else { return nil }
        let ids = text.split(separator: "\n").map { ThreadId(String($0)) }
        return ids.isEmpty ? nil : ids
    }
}

/// `ThreadContextDragGhost` (chat/ThreadContextDragGhost.tsx): `max-w-72 rounded-lg border bg-popover px-3
/// py-2 text-sm shadow-lg`, a `messages-square` glyph, the title and "+N" for more threads. Drawn once
/// into the drag image.
final class SidebarThreadDragGhostView: DSView {
    private let icon = IconView(name: .messagesSquare, size: 16)
    private let title = LabelView()
    private let more: LabelView?

    init(title text: String, count: Int) {
        more = count > 1 ? LabelView("+\(count - 1)", font: DSFont.ui(12)) : nil
        super.init(frame: .zero)
        title.text = text
        title.font = DSFont.ui(14)
        title.lineHeight = 20
        more?.lineHeight = 16
        more?.alignment = .center
        addSubview(icon)
        addSubview(title)
        more.map(addSubview)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        // `border px-3 py-2`: 1 + 12 on each side around the icon, `gap-2`, the title and the count; 1 + 8 + 20 + 8 + 1 tall.
        let w = min(288, 1 + 12 + 16 + 8 + title.textWidth + (more.map { 8 + ceil($0.textWidth) + 12 } ?? 0) + 12 + 1)
        frame = NSRect(x: 0, y: 0, width: ceil(w), height: 38)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 13, y: 11, width: 16, height: 16)
        let moreWidth = more.map { ceil($0.textWidth) + 12 } ?? 0
        let right = bounds.width - 13 - (more == nil ? 0 : moreWidth + 8)
        title.frame = NSRect(x: 37, y: 9, width: max(0, right - 37), height: 20)
        more?.frame = NSRect(x: bounds.width - 13 - moreWidth, y: 11, width: moreWidth, height: 16)
    }

    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.popover).cgColor(in: self)
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        icon.strokeColor = Themed.color(\.secondaryLabel)
        title.color = Themed.color(\.popoverForeground)
        more?.color = Themed.color(\.secondaryLabel)
        more?.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        more?.layer?.cornerRadius = 8
    }

    /// The ghost as an image for the drag session.
    func image() -> NSImage {
        layoutSubtreeIfNeeded()
        updateLayer()
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}

extension SidebarListView: NSDraggingSource {
    /// `SIDEBAR_DRAG_DISTANCE`: the pointer moves this far before a press becomes a drag.
    static let dragDistance: CGFloat = 6

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : []
    }

    /// A row left its press: drag it (or the whole selection it belongs to) as thread context.
    func beginThreadDrag(_ row: SidebarRowBase, _ id: ThreadId, event: NSEvent) {
        closeHoverCard()
        let rows = items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        let selected = rows.filter(\.isSelected).map(\.id)
        let ids = selected.contains(id) ? selected : [id]
        let title = rows.first { $0.id == id }?.title.trimmingCharacters(in: .whitespaces) ?? ""
        let item = NSPasteboardItem()
        item.setString(ids.map(\.rawValue).joined(separator: "\n"), forType: .sidebarThreads)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let ghost = SidebarThreadDragGhostView(title: title.isEmpty ? "Thread" : title, count: ids.count)
        ghost.appearance = effectiveAppearance
        // `translate(x + 12px, y + 12px)`: the ghost hangs below and right of the pointer.
        let point = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: point.x + 12, y: point.y + 12, width: ghost.frame.width, height: ghost.frame.height),
                                  contents: ghost.image())
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
}
