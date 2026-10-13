import AppKit
import DesignSystem

/// How the timeline's rows draw. `classic` is T3's web timeline, pixel for pixel. `native` is Glass Native's
/// (docs/glass-native.md): the same T3 desktop layout, sizes and wording, with native material. SF Symbols stand in
/// for Lucide where the glyph means the same, and code blocks are solid cards on Glass's frost. The engine
/// (recycling, the height cache, `TimelineChange`, the frame pacer) is the same; rows read the style from
/// `TimelineContext` in `configure`.
public enum TimelineStyle: Sendable, Equatable { case classic, native }

enum NativeTimeline {
    /// `--color-card`: #ffffff light, #111111 dark. Content blocks stay solid so text reads over the frost.
    nonisolated(unsafe) static let card = Themed.pick(light: .white, dark: NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1))

    /// A hairline that keeps a user bubble's shape readable on the frost. Light mode always has one, 8% black: T3's
    /// #f4f4f5 bubble sits within a few levels of the light frost at any opacity, and its `border` token is too pale to
    /// show. Dark mode gets 12% white only below the default Glass opacity, fading out by 80%, where T3's bubble reads.
    /// Resolved at draw time, so a slider change shows on the next redraw.
    nonisolated(unsafe) static let lowOpacityEdge: NSColor = {
        NSColor(name: nil) { appearance in
            guard appearance.isDark else { return NSColor.black.withAlphaComponent(0.08) }
            let strength = min(1, max(0, (0.8 - ThemeRuntime.glassOpacity) / 0.5))
            return NSColor.white.withAlphaComponent(0.12 * strength)
        }
    }()

    /// The SF Symbol for a work row's Lucide icon, where one means the same; nil keeps the Lucide glyph (T3's own
    /// brand marks, for one).
    static func symbol(_ icon: IconName) -> String? {
        switch icon {
        case .eye: "eye"
        case .squarePen: "square.and.pencil"
        case .terminal: "terminal"
        case .globe: "globe"
        case .search: "magnifyingglass"
        case .wrench: "wrench.adjustable"
        case .brain: "brain"
        case .bot: "cpu"
        case .hammer: "hammer"
        case .gitPullRequestArrow: "arrow.triangle.pull"
        case .smartphone: "iphone"
        case .circleAlert: "exclamationmark.circle"
        case .messageCircle: "bubble.left"
        case .check: "checkmark"
        case .zap: "bolt"
        default: nil
        }
    }

    /// A symbol image sized like the 16 pt Lucide icon it replaces, at the font size setting, cached.
    @MainActor static func image(_ symbol: String) -> NSImage? {
        let size = 13 * FontRuntime.interfaceScale, key = "\(symbol)@\(size)"
        if let hit = images[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        images[key] = image
        return image
    }
    @MainActor private static var images: [String: NSImage] = [:]
}

/// An SF Symbol in a fixed slot, tinted with `color`.
final class SymbolView: NSImageView {
    var symbol: String? {
        didSet { if symbol != oldValue { image = symbol.flatMap(NativeTimeline.image) } }
    }
    var color: NSColor = .secondaryLabelColor { didSet { contentTintColor = color } }

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        contentTintColor = color
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
