import AppKit

/// An environment theme's background image (`--theme-background-image`, themeBackground.ts) filling the main
/// panel, `center / cover`, under every page. It holds the one decoded image while a theme shows it; with no
/// image no view exists. The thread panel leaves its background clear while one shows.
public final class ThemeBackgroundView: NSView {
    @MainActor private static let hosts = NSHashTable<NSView>.weakObjects()
    @MainActor public private(set) static var image: CGImage?

    /// Shows `image` in every registered host, or takes the views out for nil.
    @MainActor public static func setImage(_ next: CGImage?) {
        guard next !== image else { return }
        image = next
        for host in hosts.allObjects {
            sync(in: host)
            // Pages that clear their fill for the image repaint.
            for v in host.subviews where !(v is ThemeBackgroundView) { v.needsDisplay = true }
        }
    }

    /// The main panel registers once; the image follows it from then on.
    @MainActor public static func register(_ host: NSView) {
        hosts.add(host)
        sync(in: host)
    }

    @MainActor static func sync(in host: NSView) {
        let existing = host.subviews.first { $0 is ThemeBackgroundView } as? ThemeBackgroundView
        guard let image else { existing?.removeFromSuperview(); return }
        let view = existing ?? {
            let made = ThemeBackgroundView(frame: host.bounds)
            host.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }()
        view.layer?.contents = image
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { false }
}
