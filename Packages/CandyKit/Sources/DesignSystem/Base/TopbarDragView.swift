import AppKit

/// Header areas of the top bar drag the window, like T3's `app-region: drag` header.
/// Controls inside it (ControlView subclasses) keep their clicks.
open class TopbarDragView: DSView {
    open override var mouseDownCanMoveWindow: Bool { true }

    /// Where Glass Native's toolbar starts its content after the traffic lights and the sidebar toggle.
    // ponytail: measured where macOS 26 and 27 put the toolbar's first item after the toggle; read it from the toolbar if that moves
    public static let nativeToolbarContentLeft: CGFloat = 140

    /// Where the content starts: the 20px gutter, or `--workspace-titlebar-content-left` when the header begins
    /// under the window controls because the sidebar is collapsed (`COLLAPSED_SIDEBAR_TITLEBAR_INSET_CLASS`,
    /// workspaceTitlebar.ts:1-2).
    // ponytail: the content jumps to its inset; T3 eases padding-left over the panel animation. Animate it if the jump shows
    public var contentStart: CGFloat {
        guard let window else { return 20 }
        if usesNativeChrome {
            // Glass Native's toolbar row: with the sidebar collapsed the header starts after the traffic lights and
            // the sidebar toggle, where the toolbar's breadcrumb starts. In full screen the header sits below the
            // toolbar, clear of them.
            if window.styleMask.contains(.fullScreen) { return 20 }
            // The toolbar's edge is in window points; under View > Zoom the header draws at the column's scale.
            let x = convert(NSPoint.zero, to: nil).x
            let scale = convert(NSSize(width: 1, height: 0), to: nil).width
            return x < Self.nativeToolbarContentLeft ? max(20, (Self.nativeToolbarContentLeft - x) / scale) : 20
        }
        // T3 measures from the viewport, which is the sidebar layout's frame (the window's content in the app).
        var layout = superview
        while let view = layout, !(view is SidebarLayoutView) { layout = view.superview }
        let x = convert(NSPoint.zero, to: layout).x
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
