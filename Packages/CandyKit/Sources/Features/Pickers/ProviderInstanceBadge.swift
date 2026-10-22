import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `ProviderInstanceIcon`'s account badge (chat/ProviderInstanceIcon.tsx:126-141): a round chip at the
/// icon's bottom right with the instance's initials, filled with its accent color (white text) or
/// `card` (`muted-foreground` text), a 1px ring in the surface color behind it and `shadow-sm`.
public struct ProviderBadge: Equatable {
    enum Size: Equatable {
        /// `h-3 min-w-3 px-0.5 text-5xs`.
        case small
        /// The default `h-3.5 min-w-3.5 px-0.5 text-4xs`.
        case regular
        /// `h-2 min-w-2 px-0` with `badgeContent="none"`: the accent dot.
        case dot
        var height: CGFloat { switch self { case .small: 12; case .regular: 14; case .dot: 8 } }
        var fontSize: CGFloat { self == .small ? 7 : 8 }
    }

    var initials: String
    /// `#rrggbb` (`normalizeProviderAccentColor`), else nil.
    var accent: String?
    var size: Size
    /// How far the badge's right and bottom edges sit outside the glyph's box.
    var overhang: CGFloat
    /// `indicatorBackground`, the ring's color.
    var ring: NSColor

    /// `shouldShowInstanceBadge` (client-runtime providerInstanceDisplay.ts:79-104): an accent color, or
    /// another instance of the same driver in the catalog.
    // ponytail: ACP registry instances count as one driver here; T3 tells them apart by agent id, add it with ACP glyphs
    public static func shows(_ entry: ProviderInstanceEntry, in catalog: ProviderCatalog) -> Bool {
        accent(entry) != nil || catalog.entries.filter { $0.driver == entry.driver }.count > 1
    }

    public static func accent(_ entry: ProviderInstanceEntry) -> String? {
        guard let t = entry.provider.accentColor?.trimmingCharacters(in: .whitespacesAndNewlines), t.count == 7, t.first == "#",
              t.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return t
    }

    /// The badge for `entry` when it shows one. `small` follows the call site's `h-3` class; some
    /// sites apply it only with an accent (ModelPickerSidebar.tsx:215).
    static func make(_ entry: ProviderInstanceEntry, in catalog: ProviderCatalog, size: Size, overhang: CGFloat, ring: NSColor) -> ProviderBadge? {
        guard shows(entry, in: catalog) else { return nil }
        return ProviderBadge(initials: ProviderIcon.initials(entry.displayName), accent: accent(entry), size: size, overhang: overhang, ring: ring)
    }
}

extension ProviderIcon {
    /// `providerInstanceInitials`: the first two characters of one word, or the first character of
    /// each of the first two words, upper-cased (providerInstanceDisplay.ts:56-63).
    nonisolated static func initials(_ label: String) -> String {
        let words = label.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return "" }
        if words.count == 1 { return String(first.prefix(2)).uppercased() }
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// The glyph with its badge on top; nil `badge` returns the glyph alone.
    static func make(driver: String, displayName: String, size: CGFloat, color: NSColor = Themed.color(\.contrastForeground),
                     model: Bool = false, badge: ProviderBadge?) -> NSView {
        let glyph = make(driver: driver, displayName: displayName, size: size, color: color, model: model)
        guard let badge else { return glyph }
        return ProviderBadgedIconView(glyph: glyph, badge: badge)
    }
}

/// The glyph's box with the badge hanging off its bottom right corner.
final class ProviderBadgedIconView: NSView {
    let glyph: NSView
    let badgeView: ProviderBadgeView

    init(glyph: NSView, badge: ProviderBadge) {
        self.glyph = glyph
        badgeView = ProviderBadgeView(badge)
        super.init(frame: .zero)
        wantsLayer = true
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)
        addSubview(badgeView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The ring follows the surface under the icon (the rail's hover and selected fills).
    var ring: NSColor {
        get { badgeView.badge.ring }
        set { badgeView.badge.ring = newValue }
    }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        let s = badgeView.intrinsicContentSize
        let o = badgeView.badge.overhang
        badgeView.frame = NSRect(x: bounds.maxX + o - s.width, y: bounds.maxY + o - s.height, width: s.width, height: s.height)
    }
}

final class ProviderBadgeView: DSView {
    var badge: ProviderBadge { didSet { if badge != oldValue { label.text = text; invalidateIntrinsicContentSize(); needsDisplay = true; superview?.needsLayout = true } } }
    private let label = LabelView()
    private var text: String { badge.size == .dot ? "" : badge.initials }

    init(_ badge: ProviderBadge) {
        self.badge = badge
        super.init(frame: .zero)
        layer?.masksToBounds = false
        label.font = DSFont.ui(badge.size.fontSize, weight: .semibold)
        label.lineHeight = badge.size.fontSize
        label.alignment = .center
        label.truncates = false
        label.text = text
        addSubview(label)
    }

    override var intrinsicContentSize: NSSize {
        let h = badge.size.height
        guard badge.size != .dot else { return NSSize(width: h, height: h) }
        // `min-w-*` with `px-0.5` and the 1px border on each side.
        return NSSize(width: max(h, ((label.textWidth + 4 + 2) * 2).rounded(.up) / 2), height: h)
    }

    override func layout() {
        super.layout()
        let lh = badge.size.fontSize
        label.frame = NSRect(x: 0, y: (bounds.height - lh) / 2, width: bounds.width, height: lh)
        layer?.cornerRadius = bounds.height / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
    }

    override func updateLayer() {
        let fill = badge.accent.flatMap(PullRequestStyle.hex)
        layer?.backgroundColor = (fill ?? Themed.color(\.card)).cgColor(in: self)
        layer?.borderWidth = 1
        layer?.borderColor = badge.ring.cgColor(in: self)
        // `shadow-sm`: 0 1px 3px rgb(0 0 0 / 0.1), one layer shadow with a fixed path.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.1
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        label.color = fill != nil ? .white : Themed.color(\.mutedForeground)
    }
}
