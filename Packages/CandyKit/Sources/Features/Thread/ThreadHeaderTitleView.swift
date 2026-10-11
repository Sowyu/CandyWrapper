import AppKit
import DesignSystem

/// ChatHeader.tsx:58-73, 179-216: click opens actions, double-click edits the title.
final class ThreadHeaderTitleView: DSView {
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onRename: (() -> Void)?
    private var pending: DispatchWorkItem?
    private let chevron = IconView(name: .chevronDown, size: 14)
    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.alphaValue = 0
        chevron.strokeColor = Themed.color(\.mutedForeground)
        addSubview(chevron)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func layout() { super.layout(); chevron.frame = NSRect(x: bounds.width - 14, y: 3, width: 14, height: 14) }
    override func mouseEntered(with event: NSEvent) { chevron.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { chevron.alphaValue = 0 }
    func cancelPendingMenu() { pending?.cancel(); pending = nil }
    override func mouseDown(with event: NSEvent) {
        pending?.cancel()
        if convert(event.locationInWindow, from: nil).x >= bounds.width - 18 { onMenu?(event, self); return }
        if event.clickCount > 1 {
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { onRename?() }
            return
        }
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
