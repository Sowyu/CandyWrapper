import AppKit
import DesignSystem

/// How the timeline's rows draw. `classic` is T3's web timeline, pixel for pixel. `native` is Glass Native's
/// (docs/glass-native.md phase 3): T3 Mobile's iPad feed (ThreadFeed.tsx, work-log-layout.tsx) with the system
/// font and SF Symbols. The engine (recycling, the height cache, `TimelineChange`, the frame pacer) is the same;
/// rows read the style from `TimelineContext` in `configure`.
public enum TimelineStyle: Sendable, Equatable { case classic, native }

/// The turn that works now: when its working row started (epoch ms) and whether it compacts.
public struct TimelineWorking: Sendable, Equatable {
    public var sinceMs: Int64?
    public var compacting: Bool
}

/// Glass Native's timeline metrics: T3 Mobile's iPad sizes times about 0.875 (docs/glass-native.md).
enum NativeTimeline {
    /// `ThreadDetailScreen.tsx:846`, `layout.ts:23`: the content column is at most 960 wide, centered, with at
    /// least 20 on each side.
    static let maxContent: CGFloat = 960
    static let sidePadding: CGFloat = 20
    /// The user bubble: radius 20, `px-3.5 py-2.5`, at most 85% of the column (ThreadFeed.tsx:1741-1760).
    static let bubbleRadius: CGFloat = 20
    static let bubbleFraction: CGFloat = 0.85
    static let bubblePadding = (x: CGFloat(14), y: CGFloat(10))
    /// The footer under a bubble: time and copy, always shown (there is no hover on iPad).
    static let footer: CGFloat = 24
    /// Body text is 14/21 (16/23 on iPad, scaled).
    static let bodyLine: CGFloat = 21
    /// A work row is at least 28 tall with a 24 icon slot and a 6 gap; details indent `ml-7` (work-log-layout.tsx).
    static let workLine: CGFloat = 28
    static let workIcon: CGFloat = 24
    static let workIndent: CGFloat = 28
    /// "Load earlier activity": a 36 pill with `chevron.up` (ThreadFeed.tsx:3337), and the room around it.
    static let earlierPill: CGFloat = 36
    static let earlierSpace: CGFloat = 8 + 36 + 4
    /// Approval and question cards (PendingApprovalCard.tsx:23-76).
    static let cardRadius: CGFloat = 20

    /// The content column inside a timeline `width` wide; an inline details card keeps the column left of it.
    static func lane(width: CGFloat, cardLeft: CGFloat? = nil) -> (x: CGFloat, width: CGFloat) {
        ThreadDetailsPlacement.lane(width: width, maximum: maxContent, padding: sidePadding, cardLeft: cardLeft)
    }

    /// The widest a user bubble gets in a column `width` wide.
    static func maxBubble(_ width: CGFloat) -> CGFloat { (width * bubbleFraction).rounded(.down) }

    /// `--color-user-bubble`: #efeff1 light, #161616 dark.
    nonisolated(unsafe) static let userBubble = Themed.pick(light: NSColor(srgbRed: 0xef / 255, green: 0xef / 255, blue: 0xf1 / 255, alpha: 1),
                                        dark: NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1))
    /// `--color-card`: #ffffff light, #111111 dark. Content blocks stay solid so text reads over the frost.
    nonisolated(unsafe) static let card = Themed.pick(light: .white, dark: NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1))
    /// `text-adaptive-rose-600-400`: failed work rows.
    static var rose: NSColor { Themed.base("rose-600", dark: "rose-400") }

    /// The SF Symbol T3 Mobile draws for a work row's kind (work-log-layout.tsx icon map).
    static func symbol(_ icon: IconName) -> String {
        switch icon {
        case .eye: "eye"
        case .squarePen: "square.and.pencil"
        case .terminal: "terminal"
        case .globe, .brandBrowserApp: "globe"
        case .search: "magnifyingglass"
        case .brain: "brain"
        case .bot: "sparkles"
        case .hammer: "hammer"
        case .gitPullRequestArrow: "arrow.triangle.pull"
        case .smartphone: "iphone"
        case .circleAlert: "exclamationmark.circle"
        case .messageCircle: "bubble.left"
        case .check: "checkmark"
        case .zap: "bolt"
        case .brandT3Wordmark: "plus.bubble"
        default: "wrench"
        }
    }

    /// A 14 pt medium symbol image at the font size setting, cached per name and size.
    @MainActor static func image(_ symbol: String) -> NSImage? {
        let size = 14 * FontRuntime.interfaceScale, key = "\(symbol)@\(size)"
        if let hit = images[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        images[key] = image
        return image
    }
    @MainActor private static var images: [String: NSImage] = [:]
}

/// An SF Symbol in a fixed slot, tinted with `color`. Layer-backed and drawn once per change.
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
