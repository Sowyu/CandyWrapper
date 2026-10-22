import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What Redesign's provider card shows, read from the provider's own report: its status, the signed-in
/// account (`auth.email` and `auth.label`, the plan) and the most-used limit window. Nil fields stay out.
struct DitherProviderCardInfo: Equatable {
    var name: String
    var driver: String
    var status: ServerProviderStatus
    var message: String?
    var email: String?
    var plan: String?
    /// The most-used window's `usedPercent`, rounded, and its label.
    var used: (percent: Int, label: String)?

    init(_ entry: ProviderInstanceEntry) {
        let p = entry.provider
        name = entry.displayName
        driver = p.driver
        status = p.status
        message = p.message
        func text(_ key: String) -> String? {
            p.auth?[key]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        email = text("email")
        plan = text("label")
        if let limits = p.usageLimits, UsageLimitsLogic.notice(limits) == nil,
           let top = limits.windows.max(by: { $0.usedPercent < $1.usedPercent }) {
            used = (Int(min(100, max(0, top.usedPercent)).rounded()), top.label)
        }
    }

    static func == (l: Self, r: Self) -> Bool {
        l.name == r.name && l.driver == r.driver && l.status == r.status && l.message == r.message && l.email == r.email
            && l.plan == r.plan && l.used?.percent == r.used?.percent && l.used?.label == r.used?.label
    }

    var statusText: String {
        switch status {
        case .ready: "Connected"
        case .warning: message ?? "Needs attention"
        case .error: message ?? "Not connected"
        default: message ?? "Disabled"
        }
    }
}

/// Redesign's provider card at the top of the model list, after Capy's picker (2026-10-22): the glyph, the name and a
/// status dot with Manage at the right, then the e-mail (blurred until clicked) and plan, then a thin usage bar.
final class DitherProviderCardView: DSView {
    static let top: CGFloat = 8, titleHeight: CGFloat = 24, lineHeight: CGFloat = 20, bottom: CGFloat = 10

    let info: DitherProviderCardInfo
    private let icon: NSView
    private let name = LabelView("", font: DSFont.ui(14, weight: .medium))
    /// A view, not a layer, so it carries the status as its tooltip.
    private let dot = DSView()
    private var manage: ButtonView?
    private var email: UsageRedactedTextView?
    private var account: LabelView?
    private var track: CALayer?
    private var bar: CALayer?
    private var usedLabel: LabelView?

    init(info: DitherProviderCardInfo, onManage: (@MainActor () -> Void)?) {
        self.info = info
        icon = ProviderIcon.make(driver: info.driver, displayName: info.name, size: 18)
        super.init(frame: .zero)
        addSubview(icon)
        name.text = info.name
        name.lineHeight = 20
        name.smoothsFont = false
        addSubview(name)
        dot.layer?.cornerRadius = 3.5
        dot.toolTip = info.statusText
        addSubview(dot)
        if let onManage {
            let b = ButtonView("Manage", variant: .ghostMuted, size: .xs)
            b.action = { onManage() }
            addSubview(b)
            manage = b
        }
        if let e = info.email {
            let v = UsageRedactedTextView(e, font: DSFont.ui(12), lineHeight: Self.lineHeight)
            addSubview(v)
            email = v
        }
        if info.email != nil || info.plan != nil {
            let l = LabelView(info.email == nil ? info.plan ?? "" : info.plan.map { "· \($0)" } ?? "", font: DSFont.ui(12))
            l.lineHeight = Self.lineHeight
            l.smoothsFont = false
            addSubview(l)
            account = l
        }
        if let used = info.used {
            let pair = (CALayer(), CALayer())
            for l in [pair.0, pair.1] {
                l.cornerRadius = 1.5
                l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
                layer?.addSublayer(l)
            }
            (track, bar) = pair
            let l = LabelView("\(used.percent)% used", font: DSFont.ui(12, weight: .medium))
            l.lineHeight = Self.lineHeight
            l.smoothsFont = false
            l.alignment = .right
            addSubview(l)
            usedLabel = l
            toolTip = "\(used.label): \(used.percent)% used"
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([info.name, info.statusText, info.plan, info.used.map { "\($0.percent)% used" }].compactMap { $0 }.joined(separator: ", "))
    }

    var preferredHeight: CGFloat {
        Self.top + Self.titleHeight + (account != nil ? Self.lineHeight : 0) + (usedLabel != nil ? Self.lineHeight + 2 : 0) + Self.bottom
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y = Self.top
        icon.frame = NSRect(x: 8, y: y + 3, width: 18, height: 18)
        let manageW = manage.map { $0.intrinsicContentSize.width } ?? 0
        manage?.frame = NSRect(x: w - 4 - manageW, y: y, width: manageW, height: 24)
        let nameX: CGFloat = 8 + 18 + 10
        let nameW = min(ceil(name.textWidth), w - nameX - 8 - manageW - 20)
        name.frame = NSRect(x: nameX, y: y + 2, width: max(0, nameW), height: 20)
        dot.frame = CGRect(x: nameX + nameW + 8, y: y + 8.5, width: 7, height: 7)
        y += Self.titleHeight
        var x = nameX
        if let email {
            let ew = min(email.intrinsicContentSize.width, w - nameX - 8)
            email.frame = NSRect(x: x, y: y, width: ew, height: Self.lineHeight)
            x += ew + 4
        }
        if let account {
            account.frame = NSRect(x: x, y: y, width: max(0, min(ceil(account.textWidth), w - 8 - x)), height: Self.lineHeight)
            y += Self.lineHeight
        }
        if let usedLabel, let track, let bar, let used = info.used {
            y += 2
            let labelW = ceil(usedLabel.textWidth)
            usedLabel.frame = NSRect(x: w - 8 - labelW, y: y, width: labelW, height: Self.lineHeight)
            let barW = max(0, usedLabel.frame.minX - 16 - nameX)
            track.frame = CGRect(x: nameX, y: y + 8.5, width: barW, height: 3)
            bar.frame = CGRect(x: nameX, y: y + 8.5, width: (barW * CGFloat(used.percent) / 100).rounded(), height: 3)
        }
    }

    override func updateLayer() {
        name.color = Themed.color(\.contrastForeground)
        account?.color = Themed.color(\.contrastMutedForeground)
        usedLabel?.color = Themed.color(\.contrastForeground)
        let dotColor: NSColor = switch info.status {
        case .ready: Themed.color(\.success)
        case .warning: Themed.color(\.warning)
        case .error: Themed.color(\.destructive)
        default: Themed.color(\.contrastMutedForeground)
        }
        dot.layer?.backgroundColor = dotColor.cgColor(in: self)
        track?.backgroundColor = Themed.color(\.contrastForeground, 0.1).cgColor(in: self)
        bar?.backgroundColor = UsageStyle.barColor(driver: info.driver).cgColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
