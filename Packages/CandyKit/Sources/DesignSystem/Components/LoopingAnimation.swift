import AppKit
import QuartzCore

/// Runs one infinite Core Animation loop on a layer only while it can be seen: the view is in a
/// visible, unoccluded window, not hidden, and Reduce Motion is off (T3's `motion-safe:` and
/// `observeVisibleAnimation`). The render server drives the frames; this process does no per-frame work.
@MainActor
public final class LoopingAnimation {
    private weak var view: NSView?
    private let layer: () -> CALayer?
    private let make: () -> CAAnimation
    private let key: String
    private var observers: [NSObjectProtocol] = []

    public init(view: NSView, key: String, layer: @escaping () -> CALayer?, make: @escaping () -> CAAnimation) {
        self.view = view
        self.key = key
        self.layer = layer
        self.make = make
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Call from viewDidMoveToWindow, viewDidHide and viewDidUnhide.
    public func windowChanged() {
        observers.dropFirst().forEach { NotificationCenter.default.removeObserver($0) }
        observers = Array(observers.prefix(1))
        if let window = view?.window {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
        }
        update()
    }

    public func update() {
        guard let view, let layer = layer() else { return }
        let visible = view.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let run = visible && !view.isHiddenOrHasHiddenAncestor && !Motion.reduced
        if run, layer.animation(forKey: key) == nil {
            let animation = make()
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = Motion.loopFrameRate
            layer.add(animation, forKey: key)
        } else if !run {
            layer.removeAnimation(forKey: key)
        }
    }
}
