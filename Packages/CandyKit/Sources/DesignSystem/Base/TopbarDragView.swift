import AppKit

/// Header areas of the top bar drag the window, like T3's `app-region: drag` header.
/// Controls inside it (ControlView subclasses) keep their clicks.
open class TopbarDragView: DSView {
    open override var mouseDownCanMoveWindow: Bool { true }

    /// Where the content starts: the 20px gutter, or `--workspace-titlebar-content-left` when the header begins
    /// under the window controls because the sidebar is collapsed (`COLLAPSED_SIDEBAR_TITLEBAR_INSET_CLASS`,
    /// workspaceTitlebar.ts:1-2).
    // ponytail: the content jumps to its inset; T3 eases padding-left over the panel animation. Animate it if the jump shows
    public var contentStart: CGFloat {
        guard window != nil else { return 20 }
        let x = convert(NSPoint.zero, to: nil).x
        let left = SidebarMetrics.titlebarContentLeft(windowedMac: true)
        return x < left ? max(20, left - x) : 20
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    open override func mouseUp(with event: NSEvent) {
        // Double-click on the bar follows the system "double-click a window's title bar" setting.
        guard event.clickCount == 2, let window else { return super.mouseUp(with: event) }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
    }
}
