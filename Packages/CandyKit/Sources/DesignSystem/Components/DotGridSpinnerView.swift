import AppKit

/// Dither's "working" mark, after Capy's: a 3 x 3 grid of dots with a light that sweeps across it diagonally. Core
/// Animation runs the sweep, only while the view is shown in a window that isn't covered; Reduce Motion leaves the
/// grid still at half strength. Nothing runs in the app while it animates.
public final class DotGridSpinnerView: NSView {
    public var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    private var dots: [CALayer] = []
    private var running = false
    private var occlusion: NSObjectProtocol?
    /// The sweep, in seconds.
    static let period: CFTimeInterval = 1.2

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for _ in 0..<9 {
            let d = CALayer()
            d.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(d)
            dots.append(d)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    @objc private func displayOptionsChanged(_ note: Notification) { sync() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var wantsUpdateLayer: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        // 3pt dots 2pt apart, centered: 13pt across.
        let dot: CGFloat = 3, gap: CGFloat = 2, side = 3 * dot + 2 * gap
        let x0 = ((bounds.width - side) / 2).rounded(), y0 = ((bounds.height - side) / 2).rounded()
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: x0 + CGFloat(i % 3) * (dot + gap), y: y0 + CGFloat(i / 3) * (dot + gap), width: dot, height: dot)
            d.cornerRadius = dot / 2
        }
    }

    public override func updateLayer() {
        let c = color.cgColor(in: self)
        for d in dots { d.backgroundColor = c }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        sync()
    }

    public override func viewDidHide() { super.viewDidHide(); sync() }
    public override func viewDidUnhide() { super.viewDidUnhide(); sync() }

    var sweepingForTesting: Bool { dots.contains { $0.animation(forKey: "sweep") != nil } }

    private func sync() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let run = visible && !isHiddenOrHasHiddenAncestor && !Motion.reduced
        // Keeps a running sweep's phase when nothing changed.
        guard run != running || !run else { return }
        running = run
        for (i, d) in dots.enumerated() {
            d.removeAnimation(forKey: "sweep")
            d.opacity = run ? 0.25 : 0.5
            guard run else { continue }
            // Rows are y up, so the light runs from the top-left dot to the bottom-right one.
            let step = Double(i % 3 + (2 - i / 3)) / 4
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.25, 1, 0.25, 0.25]
            a.keyTimes = [0, 0.25, 0.55, 1]
            a.duration = Self.period
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() - Self.period * (1 - step)
            d.add(a, forKey: "sweep")
        }
    }
}
