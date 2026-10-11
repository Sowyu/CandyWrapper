import AppKit
import DesignSystem

/// ChatHeader.tsx:58-73, 179-216: click opens actions, double-click edits the title.
final class ThreadHeaderTitleView: DSView {
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onRename: (() -> Void)?
    private var pending: DispatchWorkItem?
    func cancelPendingMenu() { pending?.cancel(); pending = nil }
    override func mouseDown(with event: NSEvent) {
        pending?.cancel()
        if event.clickCount > 1 { onRename?(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onMenu?(event, self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    override func rightMouseDown(with event: NSEvent) { pending?.cancel(); onMenu?(event, self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { pending?.cancel() } }
}
