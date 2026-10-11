import AppKit
import DesignSystem

/// The main window, configured like the official desktop app on macOS
/// (apps/desktop/src/window/DesktopWindow.ts): `titleBarStyle: "hiddenInset"` with the
/// traffic lights at x 16, centered in the 52px workspace top bar; 1100x780 default,
/// 840x620 minimum; initial background #0a0a0a dark or #ffffff light.
@MainActor
final class MainWindow: NSWindow {
    /// `MACOS_WORKSPACE_TOPBAR_HEIGHT` and the traffic light x from DesktopWindow.ts:38 and :268.
    static let topbarHeight: CGFloat = 52
    static let trafficLightX: CGFloat = 16

    private var workspaceZoom: Double = 0
    func changeWorkspaceZoom(_ delta: Double) { setWorkspaceZoom(workspaceZoom + delta) }
    func setWorkspaceZoom(_ level: Double) {
        workspaceZoom = min(5, max(-3, level))
        applyWorkspaceZoom()
    }
    private func applyWorkspaceZoom() {
        guard let contentView else { return }
        let scale = pow(1.2, workspaceZoom)
        contentView.bounds.size = NSSize(width: contentView.frame.width / scale, height: contentView.frame.height / scale)
        contentView.needsLayout = true
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        minSize = NSSize(width: 840, height: 620)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "CandyWrapper"
        isReleasedWhenClosed = false
        backgroundColor = NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1) : .white }
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyWorkspaceZoom(); self?.layoutTrafficLights() }
            }
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    /// Electron's hiddenInset positioning: grow the title bar container to the top bar's height,
    /// then place the buttons at x 16 with the system's spacing, vertically centered.
    func layoutTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let mini = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let height = Self.topbarHeight
        var frame = container.frame
        if frame.height != height {
            frame.size.height = height
            frame.origin.y = (contentView?.superview?.frame.height ?? self.frame.height) - height
            container.frame = frame
        }
        let spacing = mini.frame.minX - close.frame.minX
        let stride = spacing > 0 ? spacing : 20
        for (i, button) in [close, mini, zoom].enumerated() {
            var f = button.frame
            f.origin.x = Self.trafficLightX + CGFloat(i) * stride
            f.origin.y = (titlebar.frame.height - f.height) / 2
            button.setFrameOrigin(f.origin)
        }
    }
}
