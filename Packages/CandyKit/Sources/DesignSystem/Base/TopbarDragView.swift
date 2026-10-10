import AppKit

/// Header areas of the top bar drag the window, like T3's `app-region: drag` header.
/// Controls inside it (ControlView subclasses) keep their clicks.
open class TopbarDragView: DSView {
    open override var mouseDownCanMoveWindow: Bool { true }

    open override func mouseUp(with event: NSEvent) {
        // Double-click on the bar follows the system "double-click a window's title bar" setting.
        guard event.clickCount == 2, let window else { return super.mouseUp(with: event) }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
    }
}
