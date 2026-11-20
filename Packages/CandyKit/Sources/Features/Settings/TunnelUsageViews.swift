import AppKit
import DesignSystem

/// T3 Connect's managed tunnel cap and use (apps/web/src/cloud/managedRelayState.ts:150-199,
/// components/cloud/TunnelUsage.tsx, components/settings/SavedEnvironmentRows.tsx:506-560).
public enum TunnelUsageLogic {
    /// `ManagedTunnelUpgrade`: how the account can raise its cap.
    public enum Upgrade: String, Sendable { case link, pro, premier }

    /// `DEFAULT_MANAGED_TUNNEL_LIMIT` and `T3CHAT_PLAN_TUNNEL_LIMITS` (contracts relay.ts:969-972).
    public static let defaultLimit = 3
    public static let proLimit = 10, premierLimit = 100
    public static let subscriptionURL = URL(string: "https://t3.chat/settings/subscription")!

    /// `managedTunnelCap` (managedRelayState.ts:154-172): an override is exact, else the linked plan raises the default.
    public static func cap(available: Bool, plan: String?, override: Int?) -> (limit: Int, upgrade: Upgrade?) {
        if let override { return (override, nil) }
        guard available else { return (defaultLimit, nil) }
        switch plan {
        case "premier": return (premierLimit, nil)
        case "pro": return (proLimit, .premier)
        case "free": return (defaultLimit, .pro)
        case nil: return (defaultLimit, .link)
        default: return (defaultLimit, nil)
        }
    }

    /// `useManagedTunnelUsage`: tunnels are the account's environments on a Cloudflare tunnel.
    public static func used(providerKinds: [String]) -> Int { providerKinds.filter { $0 == "cloudflare_tunnel" }.count }

    /// `T3ConnectTunnelUsage`'s alert rule (SavedEnvironmentRows.tsx:511-522): after a refusal at `tunnelLimit`, only a
    /// freed tunnel or a higher cap clears it, since the relay also counts tunnels still being set up.
    public static func showsLimitAlert(tunnelLimit: Int?, usedAtRefusal: Int?, used: Int?, limit: Int?) -> Bool {
        guard let tunnelLimit else { return false }
        if let usedAtRefusal, let used, used < usedAtRefusal { return false }
        if let limit, limit > tunnelLimit { return false }
        return true
    }

    /// The meter's action (SavedEnvironmentRows.tsx:528-540): none at the cap while the alert shows.
    public static func meterAction(used: Int, limit: Int, upgrade: Upgrade?, alert: Bool) -> String? {
        guard !alert else { return nil }
        if upgrade != nil { return "Get more tunnels" }
        return used >= limit ? "Manage tunnels" : nil
    }

    /// `TunnelLimitAlert`'s description and action (TunnelUsage.tsx:92-137).
    public static func alertDescription(_ upgrade: Upgrade?) -> String {
        switch upgrade {
        case .link: "Switch to Tailscale or get more tunnels by linking your T3 Chat sub (sorry!)"
        case .pro, .premier: "Switch to Tailscale or get more tunnels by upgrading your T3 Chat sub (sorry!)"
        case nil: "Switch to Tailscale or deregister an environment you no longer use (sorry!)"
        }
    }

    public static func alertAction(_ upgrade: Upgrade?) -> String {
        switch upgrade {
        case .link: "Link T3 Chat"
        case .pro, .premier: "Upgrade on T3 Chat"
        case nil: "Manage tunnels"
        }
    }
}

/// What the T3 Connect row shows below itself: the meter once both reads land, and the alert after a refusal.
public struct TunnelUsageState: Equatable, Sendable {
    public var used: Int?
    public var limit: Int?
    public var upgrade: TunnelUsageLogic.Upgrade?
    /// The cap the relay named when it refused a tunnel, and the use when it did.
    public var tunnelLimit: Int?
    public var usedAtRefusal: Int?
    public init(used: Int? = nil, limit: Int? = nil, upgrade: TunnelUsageLogic.Upgrade? = nil, tunnelLimit: Int? = nil, usedAtRefusal: Int? = nil) {
        self.used = used; self.limit = limit; self.upgrade = upgrade; self.tunnelLimit = tunnelLimit; self.usedAtRefusal = usedAtRefusal
    }
    public var showsAlert: Bool {
        TunnelUsageLogic.showsLimitAlert(tunnelLimit: tunnelLimit, usedAtRefusal: usedAtRefusal, used: used, limit: limit)
    }
    public var isEmpty: Bool { (used == nil || limit == nil) && !showsAlert }
}

/// `TunnelUsageMeter` (TunnelUsage.tsx:43-89): "2 of 3 tunnels in use" with one 6pt slot per tunnel, a single
/// track above 10; `max-w-sm`, `gap-1.5`. Full turns the count and the fill to the warning color.
final class TunnelUsageMeterView: DSView {
    static let maxSegments = 10
    private let count = LabelView("", font: SB.tabular(12), color: Themed.color(\.foreground))
    let action = TunnelInlineButton()
    private var segments: [CALayer] = []
    private var used = 0, limit = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        count.lineHeight = 16
        addSubview(count)
        addSubview(action)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("T3 Connect tunnels in use")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(used: Int, limit: Int, action title: String?) {
        self.used = used; self.limit = max(1, limit)
        count.text = "\(used) of \(limit) tunnels in use"
        action.title = title ?? ""
        action.isHidden = title == nil
        setAccessibilityValue(used)
        let n = limit <= Self.maxSegments ? self.limit : 2
        while segments.count < n { let l = CALayer(); l.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]; layer?.addSublayer(l); segments.append(l) }
        while segments.count > n { segments.removeLast().removeFromSuperlayer() }
        needsLayout = true
        needsDisplay = true
    }

    static let height: CGFloat = 16 + 6 + 6

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let full = used >= limit
        count.color = full ? Themed.color(\.warningForeground) : Themed.color(\.foreground)
        let fill = (full ? Themed.color(\.warning) : Themed.color(\.foreground, 0.72)).cgColor(in: self)
        let track = Themed.color(\.muted).cgColor(in: self)
        if limit <= Self.maxSegments {
            for (i, s) in segments.enumerated() { s.backgroundColor = i < used ? fill : track }
        } else if segments.count == 2 {
            segments[0].backgroundColor = track
            segments[1].backgroundColor = fill
        }
    }

    override func layout() {
        super.layout()
        let w = min(384, bounds.width)
        let aw = action.isHidden ? 0 : action.intrinsicContentSize.width
        count.frame = NSRect(x: 0, y: 0, width: max(0, w - aw - (aw > 0 ? 12 : 0)), height: 16)
        action.frame = NSRect(x: w - aw, y: 0, width: aw, height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y: CGFloat = 16 + 6
        if limit <= Self.maxSegments {
            let gap: CGFloat = 4
            let sw = (w - gap * CGFloat(limit - 1)) / CGFloat(limit)
            for (i, s) in segments.enumerated() {
                s.frame = CGRect(x: CGFloat(i) * (sw + gap), y: y, width: max(0, sw), height: 6)
                s.cornerRadius = 3
            }
        } else if segments.count == 2 {
            segments[0].frame = CGRect(x: 0, y: y, width: w, height: 6)
            segments[1].frame = CGRect(x: 0, y: y, width: w * min(1, CGFloat(used) / CGFloat(limit)), height: 6)
            segments.forEach { $0.cornerRadius = 3 }
        }
        CATransaction.commit()
        updateLayer()
    }
}

/// `InlineButton` (ui/button.tsx:103-120) at the meter's `text-xs`: medium, foreground, underlined on hover.
final class TunnelInlineButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    var title = "" { didSet { label.text = title; setAccessibilityLabel(title); invalidateIntrinsicContentSize(); needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 16) }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); label.underlineDecoration = state.hovered ? (2, 1) : nil }
    override func layout() { super.layout(); label.frame = bounds }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Below the T3 Connect row: the meter, then `TunnelLimitAlert` after the relay refused a tunnel at the cap
/// (`flex flex-col gap-3 pb-3`, SavedEnvironmentRows.tsx:542-556).
public final class TunnelUsageView: DSView, SettingsGroupRow {
    let meter = TunnelUsageMeterView()
    let alert = AlertView(nil, icon: .triangleAlert, variant: .warning)
    private let alertButton = ButtonView("", size: .sm)
    /// The account page for `t3-chat` (link or upgrade) or `t3-connect` (manage tunnels).
    public var onAction: ((_ chat: Bool) -> Void)?
    public private(set) var state = TunnelUsageState()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        alert.title = "You’re out of tunnels (they cost us money)."
        alert.actions = [alertButton]
        addSubview(meter)
        addSubview(alert)
        meter.action.action = { [weak self] in self?.onAction?(self?.state.upgrade != nil) }
        alertButton.action = { [weak self] in self?.onAction?(self?.state.upgrade != nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func configure(_ s: TunnelUsageState) {
        state = s
        let alertShown = s.showsAlert
        if let used = s.used, let limit = s.limit {
            meter.isHidden = false
            meter.configure(used: used, limit: limit, action: TunnelUsageLogic.meterAction(used: used, limit: limit, upgrade: s.upgrade, alert: alertShown))
        } else {
            meter.isHidden = true
        }
        alert.isHidden = !alertShown
        alert.message = TunnelUsageLogic.alertDescription(s.upgrade)
        alertButton.title = TunnelUsageLogic.alertAction(s.upgrade)
        alertButton.variant = s.upgrade == nil ? .outline : .default
        needsLayout = true
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        var parts: [CGFloat] = []
        if !meter.isHidden { parts.append(TunnelUsageMeterView.height) }
        if !alert.isHidden { parts.append(alert.height(forWidth: width)) }
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0, +) + 12 * CGFloat(parts.count - 1) + 12
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        if !meter.isHidden {
            meter.frame = NSRect(x: 0, y: y, width: bounds.width, height: TunnelUsageMeterView.height)
            y += TunnelUsageMeterView.height + 12
        }
        if !alert.isHidden { alert.frame = NSRect(x: 0, y: y, width: bounds.width, height: alert.height(forWidth: bounds.width)) }
    }
}
