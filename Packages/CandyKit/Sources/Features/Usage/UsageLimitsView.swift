import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `formatUpcomingTimestamp` (timestampFormat.ts:202-222) with the `timestampFormat` setting.
@MainActor
enum UsageTime {
    /// `resolveHour12` (timestampFormat.ts:94-96): "locale" follows the system's hour cycle.
    static func hour12(format: String = ClientSettingsStore.shared.current.string("timestampFormat")) -> Bool {
        switch format {
        case "12-hour": true
        case "24-hour": false
        default: DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: TimestampFormat.t3Locale)?.contains("a") ?? true
        }
    }

    static func upcoming(_ iso: String, nowMs: Int64, format: String = ClientSettingsStore.shared.current.string("timestampFormat")) -> String {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000), now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let time = TL.timeOfDay(date, format: format)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days < 0 { return TL.dayAwareTimestamp(T3Timestamp(iso), now: now, format: format) }
        if days == 0 { return time }
        if days == 1 { return "tomorrow at \(time)" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let d = sameYear ? date.formatted(.dateTime.month(.defaultDigits).day()) : date.formatted(.dateTime.month(.defaultDigits).day().year())
        return "\(d) \(time)"
    }
}

/// `RedactedSensitiveText`: a stable scramble of the value in 11pt mono, blurred, that reveals the value on click.
final class UsageRedactedTextView: ControlView {
    private let label: LabelView
    private let value: String
    private let revealTooltip: String, hideTooltip: String
    private var revealed = false { didSet { update() } }
    private var tip: TooltipController?

    /// The defaults are the email form (`text-2xs font-mono`); the composer's account label passes
    /// `font-sans text-xs` and its own words (ComposerUsageLimits.tsx:30-37).
    init(_ value: String, font: NSFont = DSFont.mono(11), lineHeight: CGFloat = 16, glass: Bool = false,
         revealTooltip: String = "Click to reveal email", hideTooltip: String = "Click to hide email") {
        self.value = value
        self.revealTooltip = revealTooltip
        self.hideTooltip = hideTooltip
        label = glass ? glassLabel(font: font, color: Themed.color(\.mutedForeground), lineHeight: lineHeight)
            : LabelView("", font: font, color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = lineHeight
        addSubview(label)
        layerUsesCoreImageFilters = true
        tip = TooltipController.attach(to: self, text: "")
        update()
    }

    /// `redactedPlaceholder`: FNV-1a seeded, separators kept.
    static func placeholder(_ value: String) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var state: UInt32 = 0x811c9dc5
        for u in value.utf16 { state ^= UInt32(u); state = state &* 0x01000193 }
        func next() -> Character {
            state = (state ^ (state >> 13)) &* 0x85ebca6b
            state = (state ^ (state >> 16)) &* 0xc2b2ae35
            let signed = Int64(Int32(bitPattern: state))
            return alphabet[Int(abs(signed) % Int64(alphabet.count))]
        }
        return String(value.map { "@.-_".contains($0) ? $0 : next() })
    }

    private func update() {
        label.text = revealed ? value : Self.placeholder(value)
        tip?.text = revealed ? hideTooltip : revealTooltip
        label.layer?.filters = revealed ? nil : [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])].compactMap { $0 }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: label.lineHeight ?? 16) }
    override func performAction() { revealed.toggle() }
    override func layout() { super.layout(); label.frame = bounds }
}

/// `PaceIcon`: the glyph with the words as its tooltip.
@MainActor
func usagePaceIcon(_ pace: UsageLimitPace) -> NSView {
    let (icon, text): (IconName, String) = switch pace {
    case .ahead: (.trendingUp, "Ahead of pace: spending faster than the window elapses")
    case .on: (.gauge, "On pace with the window")
    case .under: (.trendingDown, "Under pace: headroom left for the rest of the window")
    }
    let v = IconView(name: icon, size: 14, strokeColor: Themed.color(\.mutedForeground))
    v.frame.size = NSSize(width: 14, height: 14)
    v.setAccessibilityLabel(text)
    _ = TooltipController.attach(to: v, text: text)
    return v
}

/// `LimitWindows`: one account's windows as rows of label and percent, bar, then pace and countdown.
/// Compact rows (the `/usage-limits` banner) use `minmax(0,9rem) minmax(3rem,1fr) auto` columns.
public final class UsageLimitWindowsView: DSView {
    private var rows: [(label: LabelView, percent: LabelView, bar: UsageLimitWindowBar, pace: NSView?, resets: LabelView)] = []
    let compact: Bool

    public init(driver: String, windows: [UsageLimitWindow], nowMs: Int64, compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
        let color = UsageStyle.barColor(driver: driver)
        rows = windows.map { w in
            let label = UsageStyle.label(w.label, 12, color: Themed.color(\.mutedForeground))
            let pct = UsageStyle.label("\(UsageLimitsLogic.remainingPercent(w))% left", 12, .medium, tabular: true)
            let bar = UsageLimitWindowBar(color: color, window: w, nowMs: nowMs)
            let pace = UsageLimitsLogic.pace(w, nowMs: nowMs).map(usagePaceIcon)
            let resets = UsageStyle.label(UsageLimitsLogic.resetsIn(w, nowMs: nowMs) ?? "", 12, color: Themed.color(\.mutedForeground), tabular: true)
            resets.alignment = .right
            for v in [label, pct, bar, resets] as [NSView] { addSubview(v) }
            pace.map(addSubview)
            return (label, pct, bar, pace, resets)
        }
    }

    private var rowHeight: CGFloat { 24 }
    private var rowGap: CGFloat { compact ? 2 : 4 }

    public func height(forWidth width: CGFloat) -> CGFloat { CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * rowGap }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: 0)) }

    public override func layout() {
        super.layout()
        let gap: CGFloat = compact ? 12 : 16
        let third: CGFloat = compact ? (rows.map { r in (r.pace == nil ? 0 : 14 + 8) + ceil(r.resets.textWidth) }.max() ?? 0) : 112
        let first: CGFloat = compact ? min(144, max(0, bounds.width - third - 2 * gap - 48)) : 176
        let barW = max(compact ? 48 : 0, bounds.width - first - third - 2 * gap)
        var y: CGFloat = 0
        for r in rows {
            let pw = ceil(r.percent.textWidth) + 1
            r.percent.frame = NSRect(x: first - pw, y: y + 4, width: pw, height: 16)
            r.label.frame = NSRect(x: 0, y: y + 4, width: max(0, first - pw - 8), height: 16)
            r.bar.frame = NSRect(x: first + gap, y: y, width: barW, height: 24)
            let x3 = first + gap + barW + gap
            r.pace?.frame = NSRect(x: x3, y: y + 5, width: 14, height: 14)
            r.resets.frame = NSRect(x: x3, y: y + 4, width: third, height: 16)
            y += rowHeight + rowGap
        }
    }
}

/// `WindowBar`: quota left as the fill over `bg-muted`, a 2px foreground tick in a 6px gap where even
/// spending would be, and the figures as the tooltip.
final class UsageLimitWindowBar: DSView {
    let color: NSColor
    let remaining: Int
    let timeLeft: Int?
    private var tip: TooltipController?

    init(color: NSColor, window w: UsageLimitWindow, nowMs: Int64) {
        self.color = color
        remaining = UsageLimitsLogic.remainingPercent(w)
        timeLeft = UsageLimitsLogic.elapsedShare(w, nowMs: nowMs).map { Int(UsageFormat.jsRound((1 - $0) * 100)) }
        super.init(frame: .zero)
        let resetsIn = UsageLimitsLogic.resetsIn(w, nowMs: nowMs)
        var lines = ["\(remaining)% left" + (timeLeft.map { " · \($0)% of the window left" } ?? "")]
        if timeLeft != nil { lines.append("The line is where even spending would be.") }
        if let at = w.resetsAt { lines.append("Resets \(UsageTime.upcoming(at, nowMs: nowMs))" + (resetsIn.map { " · \($0)" } ?? "")) }
        tip = TooltipController.attach(to: self, text: lines.joined(separator: "\n"))
        setAccessibilityLabel("\(w.label): \(remaining)% left" + (timeLeft.map { ", \($0)% of the window left" } ?? "") + (resetsIn.map { ", \($0)" } ?? ""))
    }

    override var wantsUpdateLayer: Bool { false }

    /// `paceMarkStyles` (UsageLimits.tsx:77-111): the tick's center, clamped 3px inside the ends. Below
    /// 6px wide there is no room, so neither the gap nor the tick draws.
    static func paceMark(timeLeft: Int?, width: CGFloat) -> CGFloat? {
        guard let timeLeft, width >= 6 else { return nil }
        return min(max(width * CGFloat(timeLeft) / 100, 3), width - 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let at = Self.paceMark(timeLeft: timeLeft, width: bounds.width)
        if let at {
            ctx.saveGState()
            ctx.clip(to: [CGRect(x: -1, y: -1, width: at - 3 + 1, height: bounds.height + 2),
                          CGRect(x: at + 3, y: -1, width: bounds.width - at - 3 + 1, height: bounds.height + 2)])
        }
        let track = CGRect(x: 0, y: 6, width: bounds.width, height: bounds.height - 12)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: track.height / 2, cornerHeight: track.height / 2, transform: nil))
        ctx.setFillColor(Themed.color(\.muted).cgColor(in: self))
        ctx.fillPath()
        if remaining > 0 {
            let fill = CGRect(x: 0, y: 6, width: bounds.width * CGFloat(remaining) / 100, height: track.height)
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: min(fill.width, fill.height) / 2, cornerHeight: fill.height / 2, transform: nil))
            ctx.setFillColor(color.cgColor(in: self))
            ctx.fillPath()
        }
        if let at {
            ctx.restoreGState()
            // `inset-y-1 w-0.5 rounded-full bg-foreground`
            let tick = CGRect(x: at - 1, y: 4, width: 2, height: bounds.height - 8)
            ctx.addPath(CGPath(roundedRect: tick, cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.setFillColor(Themed.color(\.foreground).cgColor(in: self))
            ctx.fillPath()
        }
    }
}

/// `ResetCredits`: the banked count, `Use reset` (confirmed by the app) and the outcome.
public final class UsageResetCreditsView: DSView {
    private let summary: LabelView
    public let button = ButtonView("Use reset", variant: .outline, size: .xs)
    private let status = UsageStyle.label("", 12)
    public var onUse: (() -> Void)?
    public var busy = false { didSet { button.title = busy ? "Using…" : "Use reset"; button.isEnabled = !busy && canUse; needsLayout = true } }
    public var canUse = true { didSet { button.isEnabled = !busy && canUse } }
    public var statusText: String? { didSet { status.text = statusText ?? ""; needsLayout = true } }
    let available: Bool

    public init(credits: UsageResetCredits, nowMs: Int64) {
        summary = UsageStyle.label(UsageLimitsLogic.resetCreditsSummary(credits, nowMs: nowMs), 12, color: Themed.color(\.mutedForeground), tabular: true)
        available = credits.availableCount > 0
        super.init(frame: .zero)
        addSubview(summary)
        if available { addSubview(button) }
        addSubview(status)
        button.action = { [weak self] in self?.onUse?() }
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 24 }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        summary.frame = NSRect(x: 0, y: 4, width: ceil(summary.textWidth) + 1, height: 16)
        x = summary.frame.maxX + 12
        if available {
            let w = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: 0, width: w, height: 24)
            x += w + 12
        }
        status.frame = NSRect(x: x, y: 4, width: max(0, bounds.width - x), height: 16)
    }
}

/// What the Limits tab draws, built by the app from every selected environment.
public struct UsageLimitsModel {
    public var pools: [UsageLimitPool] = []
    public var notices: [String] = []
    public var externalLinks: [(label: String, url: String, message: String?)] = []
    /// Environments to offer Cursor's Keychain access on (id, label).
    public var cursorPrompt: [(id: String, label: String)] = []
    public var nowMs: Int64 = 0
    /// A reset credit in use or its outcome, by account key: "Using reset credit…" then the result. The
    /// popover closes for the confirm, so the line sits under the pool (UsageLimitsPooled.tsx:307-322).
    public var resetStatus: (accountKey: String, text: String)?
    public init() {}
}

/// Usage > Limits (`UsageLimitsPooled`): per provider a heading and a card per pooled window, the Cursor
/// prompt after Codex and Claude, external usage links, and the notices for what could not be read.
public final class UsageLimitsView: DSView, SettingsGroupRow {
    public var model = UsageLimitsModel() { didSet { rebuild() } }
    /// A segment wants its account's reset credit used (the app confirms first).
    public var onUseReset: ((UsageLimitAccount) -> Void)?
    public var onEnableCursor: ((String) -> Void)?
    public var onOpenURL: ((String) -> Void)?
    private var items: [NSView & SettingsGroupRow] = []

    private func rebuild() {
        items.forEach { $0.removeFromSuperview() }
        items = []
        let m = model
        let cursorAt = max(m.pools.firstIndex { $0.driver == "codex" } ?? -1, m.pools.firstIndex { $0.driver == "claudeAgent" } ?? -1) + 1
        if m.pools.isEmpty && m.notices.isEmpty && m.cursorPrompt.isEmpty && m.externalLinks.isEmpty {
            items.append(UsageParagraphRow("No provider on the selected environments reports subscription limits."))
        }
        for (i, pool) in m.pools.enumerated() {
            if i == cursorAt, !m.cursorPrompt.isEmpty { items.append(cursorSection()) }
            items.append(UsagePoolSectionView(pool: pool, nowMs: m.nowMs, owner: self))
        }
        if cursorAt == m.pools.count, !m.cursorPrompt.isEmpty { items.append(cursorSection()) }
        for link in m.externalLinks { items.append(UsageExternalLinkRow(link, onOpen: { [weak self] in self?.onOpenURL?(link.url) })) }
        if !m.notices.isEmpty {
            let alert = AlertView(m.notices.joined(separator: "\n"), icon: .triangleAlert, variant: .warning)
            alert.controlAlignment = .firstLine
            items.append(alert)
        }
        items.forEach(addSubview)
        needsLayout = true
    }

    private func cursorSection() -> NSView & SettingsGroupRow {
        UsageCursorPromptView(environments: model.cursorPrompt) { [weak self] id in self?.onEnableCursor?(id) }
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        items.reduce(0) { $0 + $1.height(forWidth: width) } + 32 * CGFloat(max(0, items.count - 1))
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for item in items {
            let h = item.height(forWidth: bounds.width)
            item.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 32
        }
    }
}

/// A muted `text-sm` paragraph.
final class UsageParagraphRow: DSView, SettingsGroupRow {
    private let text = TextBlockView()
    init(_ message: String, size: CGFloat = 14, color: NSColor = Themed.color(\.mutedForeground)) {
        super.init(frame: .zero)
        text.text = message
        text.font = DSFont.ui(size)
        text.lineHeight = size == 14 ? 20 : 16
        text.color = color
        addSubview(text)
    }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: width) }
    override func layout() { super.layout(); text.frame = bounds }
}

/// `PoolSection`: the provider heading, then one card per window.
final class UsagePoolSectionView: DSView, SettingsGroupRow {
    private let icon: NSView
    private let title: LabelView
    private var cards: [UsagePoolCardView] = []

    init(pool: UsageLimitPool, nowMs: Int64, owner: UsageLimitsView) {
        let label = UsageProviderLabels.driverLabel(pool.driver)
        icon = ProviderIcon.make(driver: pool.driver, displayName: label, size: 16, color: Themed.color(\.foreground, 0.8))
        title = UsageStyle.label(label, 14, .medium)
        super.init(frame: .zero)
        addSubview(icon)
        addSubview(title)
        let color = UsageStyle.barColor(driver: pool.driver)
        cards = UsageLimitsLogic.displayWindows(pool).map { w in
            let details = pool.driver == "cursor" ? UsageLimitsLogic.cursorWindowDetails(w.id) : nil
            let status = owner.model.resetStatus.flatMap { s -> (UsageLimitAccount, String)? in
                w.columns.first { $0.account.key == s.accountKey }.map { ($0.account, s.text) }
            }
            let card = UsagePoolCardView(window: w, color: color, nowMs: nowMs, label: details?.label, description: details?.description,
                                         resetStatus: status)
            card.onUseReset = { [weak owner] a in owner?.onUseReset?(a) }
            return card
        }
        cards.forEach(addSubview)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        20 + cards.reduce(0) { $0 + 12 + $1.height(forWidth: width) }
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 2, y: 2, width: 16, height: 16)
        title.frame = NSRect(x: 28, y: 0, width: ceil(title.textWidth) + 1, height: 20)
        var y: CGFloat = 32
        for c in cards {
            let h = c.height(forWidth: bounds.width)
            c.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 12
        }
    }
}

/// `providerClients` labels for the drivers the limits views name.
enum UsageProviderLabels {
    static func driverLabel(_ driver: String) -> String {
        switch driver {
        case "codex": "Codex"
        case "claudeAgent": "Claude"
        case "cursor": "Cursor"
        case "grok": "Grok"
        case "opencode": "OpenCode"
        case "antigravity": "Antigravity"
        default: driver
        }
    }
}

/// `PoolWindowCard`: big pooled number and the segment bar, `rounded-lg border-border/60 p-4`.
final class UsagePoolCardView: BoxView, SettingsGroupRow {
    let pool: UsageLimitPoolWindow
    private let title: LabelView
    private let big: LabelView
    private let left = UsageStyle.label("left", 14, color: Themed.color(\.mutedForeground))
    private let pace: NSView?
    private let refill: LabelView?
    private let note: TextBlockView?
    private var segments: [UsagePoolSegmentView] = []
    private var legend: [UsagePoolLegendRow] = []
    /// `role="status"` under the segments: the account's name in `font-medium text-foreground`, then the words.
    // ponytail: keyed by account, so every card with that account shows it; key by window too if users notice
    private let resetStatus: TextBlockView?
    var onUseReset: ((UsageLimitAccount) -> Void)?

    init(window w: UsageLimitPoolWindow, color: NSColor, nowMs: Int64, label: String?, description: String?,
         resetStatus status: (account: UsageLimitAccount, text: String)? = nil) {
        pool = w
        resetStatus = status.map { s in
            let name = s.account.displayName ?? UsageProviderLabels.driverLabel(s.account.driver)
            let t = TextBlockView()
            t.text = "\(name) \(s.text)"; t.font = DSFont.ui(12); t.lineHeight = 16; t.color = Themed.color(\.mutedForeground)
            t.boldPrefix = name; t.boldColor = Themed.color(\.foreground)
            return t
        }
        title = UsageStyle.label(label ?? w.label, 14, .medium)
        big = UsageStyle.label("\(w.remainingPercent)%", 30, .semibold, tabular: true, lineHeight: 36)
        pace = w.pace.map(usagePaceIcon)
        let next = w.resets.first { $0.restoresPercent > 0 }
        refill = next != nil && w.columns.count > 1 ? UsageStyle.label("↻ +\(next!.restoresPercent)%", 12, .medium, tabular: true) : nil
        note = description.map { d in
            let t = TextBlockView()
            t.text = d; t.font = DSFont.ui(12); t.lineHeight = 16; t.color = Themed.color(\.mutedForeground)
            return t
        }
        super.init(frame: .zero)
        var s = BoxStyle()
        s.radius = 8
        s.border = Themed.color(\.border, 0.6)
        boxStyle = s
        for v in [title, big, left] as [NSView] { addSubview(v) }
        pace.map(addSubview)
        refill.map(addSubview)
        note.map(addSubview)
        resetStatus.map(addSubview)
        let restores = Dictionary(w.resets.map { ($0.account.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, col) in w.columns.enumerated() {
            guard let cw = col.window else { continue }
            let seg = UsagePoolSegmentView(account: col.account, window: cw, reset: restores[col.account.key], color: color, nowMs: nowMs, index: i + 1,
                                           columns: w.columns.count, showAccountName: w.columns.count > 1)
            seg.onUseReset = { [weak self] a in self?.onUseReset?(a) }
            segments.append(seg)
            addSubview(seg)
            let row = UsagePoolLegendRow(segment: seg)
            legend.append(row)
            addSubview(row)
        }
    }

    /// `md:grid-cols-[11rem_minmax(0,1fr)]` from 768pt of window width; stacked below.
    private func twoColumns(_ width: CGFloat) -> Bool { (window_width ?? width) >= 768 }
    private var window_width: CGFloat? { (self as NSView).window?.frame.width }
    private func barWidth(_ width: CGFloat) -> CGFloat { twoColumns(width) ? width - 32 - 176 - 24 : width - 32 }
    /// `@2xl/pool`: labeled segments from a 672pt bar.
    private func wide(_ width: CGFloat) -> Bool { barWidth(width) >= 672 }
    private var leftHeight: CGFloat { 20 + 4 + 36 + (refill == nil ? 0 : 4 + 16) }

    private func barHeight(_ width: CGFloat) -> CGFloat {
        (wide(width) ? 32 : 20 + CGFloat(legend.count) * (28 + 4)) + statusHeight(width)
    }

    private func statusHeight(_ width: CGFloat) -> CGFloat {
        resetStatus.map { 4 + $0.height(forWidth: barWidth(width)) } ?? 0
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 32
        var h: CGFloat = twoColumns(width) ? max(leftHeight, barHeight(width)) : leftHeight + 12 + barHeight(width)
        if let note { h += 12 + note.height(forWidth: inner) }
        return h + 32
    }

    override func layout() {
        super.layout()
        let width = bounds.width, inner = width - 32
        let two = twoColumns(width), isWide = wide(width)
        let bh = barHeight(width)
        let rowH = two ? max(leftHeight, bh) : leftHeight
        let leftY: CGFloat = 16 + (two ? (rowH - leftHeight) / 2 : 0)
        title.frame = NSRect(x: 16, y: leftY, width: min(176, ceil(title.textWidth) + 1), height: 20)
        let bw = ceil(big.textWidth) + 1
        big.frame = NSRect(x: 16, y: leftY + 24, width: bw, height: 36)
        left.frame = NSRect(x: 16 + bw + 8, y: leftY + 24 + 12, width: ceil(left.textWidth) + 1, height: 20)
        pace?.frame = NSRect(x: left.frame.maxX + 8, y: leftY + 24 + 15, width: 14, height: 14)
        refill?.frame = NSRect(x: 16, y: leftY + 64, width: ceil(refill!.textWidth) + 1, height: 16)
        let bx: CGFloat = two ? 16 + 176 + 24 : 16
        let by: CGFloat = two ? 16 + (rowH - bh) / 2 : 16 + leftHeight + 12
        let bwidth = barWidth(width)
        let n = CGFloat(pool.columns.count)
        let segW = (bwidth - 4 * (n - 1)) / n
        for s in segments {
            s.isWide = isWide
            s.frame = NSRect(x: bx + CGFloat(s.index - 1) * (segW + 4), y: by, width: segW, height: isWide ? 32 : 20)
        }
        for (i, l) in legend.enumerated() {
            l.isHidden = isWide
            l.frame = NSRect(x: bx, y: by + 24 + CGFloat(i) * 32, width: bwidth, height: 28)
        }
        if let resetStatus {
            let sh = statusHeight(width) - 4
            resetStatus.frame = NSRect(x: bx, y: by + bh - sh, width: bwidth, height: sh)
        }
        if let note { note.frame = NSRect(x: 16, y: 16 + rowH + (two ? 0 : 12 + bh) + 12, width: inner, height: note.height(forWidth: inner)) }
    }
}

/// `PoolSegment`: one account's share of one pooled window. The open share fills at 35%, the spent share is
/// hatched when a reset will restore it. Narrow it shows its index; wide it carries the account, the percent
/// and a plate with the countdown and banked credits. A click opens the account popover.
final class UsagePoolSegmentView: ControlView {
    let account: UsageLimitAccount
    let limitWindow: UsageLimitWindow
    let reset: UsageLimitPoolWindow.Reset?
    let color: NSColor
    let nowMs: Int64
    let index: Int
    var isWide = false { didSet { if isWide != oldValue { configure() } } }
    var onUseReset: ((UsageLimitAccount) -> Void)?
    private let number: LabelView
    private let name: NSView?
    private let percent: LabelView
    private let plate = DSView()
    private let plateText: LabelView
    private let ticket: IconView?
    private let credits: LabelView?
    let remaining: Int
    let resetsIn: String?
    let creditCount: Int
    /// `paceRemainingPercent`: where even spending would be, as the tick in a gap (UsageLimitsPooled.tsx:345-393).
    let timeLeft: Int?

    init(account: UsageLimitAccount, window: UsageLimitWindow, reset: UsageLimitPoolWindow.Reset?, color: NSColor, nowMs: Int64, index: Int,
         columns: Int, showAccountName: Bool) {
        self.account = account; self.limitWindow = window; self.reset = reset; self.color = color; self.nowMs = nowMs; self.index = index
        remaining = UsageLimitsLogic.remainingPercent(window)
        resetsIn = UsageLimitsLogic.resetsIn(window, nowMs: nowMs)
        creditCount = account.limits.resetCredits?.availableCount ?? 0
        timeLeft = UsageLimitsLogic.elapsedShare(window, nowMs: nowMs).map { Int(UsageFormat.jsRound((1 - $0) * 100)) }
        number = UsageStyle.label("\(index)", 10, .semibold, color: Themed.color(\.foreground, 0.8), tabular: true, lineHeight: 14)
        number.alignment = .center
        name = showAccountName ? UsageAccountName.make(account, font: DSFont.ui(12, weight: .medium)) : nil
        percent = UsageStyle.label("\(remaining)%", 12, .semibold, tabular: true)
        plateText = UsageStyle.label(resetsIn?.replacingOccurrences(of: "resets in ", with: "↻ ") ?? "", 11, tabular: true)
        ticket = creditCount > 0 ? IconView(name: .ticket, size: 12, strokeColor: Themed.color(\.foreground)) : nil
        credits = creditCount > 0 ? UsageStyle.label((resetsIn != nil ? "· " : "") + "\(creditCount)", 11, .semibold, tabular: true) : nil
        super.init(frame: .zero)
        scalesWhenPressed = false
        for v in [number, percent, plate, plateText] as [NSView] { addSubview(v) }
        name.map(addSubview)
        ticket.map(addSubview)
        credits.map(addSubview)
        plate.layer?.cornerRadius = 4
        setAccessibilityRole(.button)
        let who = account.displayName ?? account.email.map(UsageLimitsLogic.accountInitials) ?? account.driver
        setAccessibilityLabel("\(who): \(remaining)% left" + (resetsIn.map { ", \($0)" } ?? "") + (timeLeft.map { ", \($0)% of the window left" } ?? "")
                              + (creditCount > 0 ? ", \(creditCount) reset \(creditCount == 1 ? "credit" : "credits") banked" : ""))
        configure()
    }

    override var wantsUpdateLayer: Bool { false }

    private func configure() {
        number.isHidden = isWide
        for v in [percent, plate, plateText] as [NSView] { v.isHidden = !isWide }
        name?.isHidden = !isWide
        ticket?.isHidden = !isWide
        credits?.isHidden = !isWide
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        number.frame = bounds
        guard isWide else { return }
        var x: CGFloat = 8
        if let name {
            let w = min(name.fittingSize.width, bounds.width / 2)
            name.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: w, height: 16)
            x += w + 6
        }
        percent.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: ceil(percent.textWidth) + 1, height: 16)
        // The plate: `bg-background/85 rounded-sm px-1.5 py-0.5 text-2xs`, `gap-1.5` between its parts.
        var pw = ceil(plateText.textWidth) + 1
        if let credits { pw += (plateText.text.isEmpty ? 0 : 6) + 12 + 2 + ceil(credits.textWidth) + 1 }
        let px = bounds.width - 8 - pw - 12
        plate.frame = NSRect(x: px, y: (bounds.height - 20) / 2, width: pw + 12, height: 20)
        plateText.frame = NSRect(x: px + 6, y: (bounds.height - 16) / 2, width: ceil(plateText.textWidth) + 1, height: 16)
        if let ticket, let credits {
            let cx = plateText.frame.maxX + (plateText.text.isEmpty ? 0 : 6)
            ticket.frame = NSRect(x: cx, y: (bounds.height - 12) / 2, width: 12, height: 12)
            credits.frame = NSRect(x: cx + 14, y: (bounds.height - 16) / 2, width: ceil(credits.textWidth) + 1, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        let shape = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let at = UsageLimitWindowBar.paceMark(timeLeft: timeLeft, width: r.width)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let at { ctx.clip(to: [CGRect(x: -1, y: -1, width: at - 2, height: r.height + 2), CGRect(x: at + 3, y: -1, width: r.width - at - 2, height: r.height + 2)]) }
        ctx.setFillColor(Themed.color(\.muted).cgColor(in: self))
        ctx.fill(r)
        let fillW = r.width * CGFloat(remaining) / 100
        if fillW > 0 {
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: fillW, height: r.height), cornerWidth: min(6, fillW / 2), cornerHeight: 6, transform: nil))
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor(in: self))
            ctx.fillPath()
        }
        // `repeating-linear-gradient(135deg, color 0 1px, transparent 1px 5px)` at 20%.
        if remaining < 100, reset != nil {
            let spent = CGRect(x: fillW, y: 0, width: r.width - fillW, height: r.height)
            ctx.saveGState()
            ctx.clip(to: spent)
            ctx.setStrokeColor(color.withAlphaComponent(0.2).cgColor(in: self))
            ctx.setLineWidth(1)
            let step: CGFloat = 5 * sqrt(2)
            var x = spent.minX - r.height
            while x < spent.maxX + r.height {
                ctx.move(to: CGPoint(x: x, y: r.height))
                ctx.addLine(to: CGPoint(x: x + r.height, y: 0))
                x += step
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
        if let at {
            // `inset-y-0.5 w-0.5 rounded-full bg-foreground`
            ctx.addPath(CGPath(roundedRect: CGRect(x: at - 1, y: 2, width: 2, height: r.height - 4), cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.setFillColor(Themed.color(\.foreground).cgColor(in: self))
            ctx.fillPath()
        }
        if state.popupOpen {
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
            ctx.setStrokeColor(Themed.color(\.border).cgColor(in: self))
            ctx.strokePath()
        }
    }

    override func updateLayer() {}
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        plate.layer?.backgroundColor = Themed.color(\.background, 0.85).cgColor(in: self)
        needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    override func performAction() { openPopover(from: self) }

    func openPopover(from trigger: NSView) {
        let content = UsageSegmentPopoverContent(segment: self)
        content.onUseReset = { [weak self] in
            guard let self else { return }
            self.popupHost?.closeAll()
            self.onUseReset?(self.account)
        }
        PopoverView(content: content, padding: .default, width: .auto).show(from: trigger, placement: PopupPlacement(side: .top, align: .center, sideOffset: 6))
    }
}

/// `LegendRow`: under a narrow strip, one row per account carrying what the segment has no room for.
final class UsagePoolLegendRow: ControlView {
    private weak var segment: UsagePoolSegmentView?
    private let badge: LabelView
    private let swatch = DSView()
    private let name: NSView
    private let percent: LabelView
    private let trail: LabelView

    init(segment s: UsagePoolSegmentView) {
        segment = s
        badge = UsageStyle.label("\(s.index)", 10, .semibold, color: Themed.color(\.foreground, 0.8), tabular: true, lineHeight: 16)
        badge.alignment = .center
        name = UsageAccountName.make(s.account, font: DSFont.ui(14, weight: .medium))
        percent = UsageStyle.label("\(s.remaining)%", 14, .semibold, tabular: true)
        let r = s.resetsIn?.replacingOccurrences(of: "resets in ", with: "↻ ") ?? ""
        trail = UsageStyle.label(r + (s.creditCount > 0 ? (r.isEmpty ? "" : " · ") + "🎟 \(s.creditCount)" : ""), 11, color: Themed.color(\.mutedForeground), tabular: true)
        trail.alignment = .right
        super.init(frame: .zero)
        swatch.layer?.cornerRadius = 2
        for v in [swatch, badge, name, percent, trail] as [NSView] { addSubview(v) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        swatch.layer?.backgroundColor = segment?.color.withAlphaComponent(0.35).cgColor(in: self)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    override func layout() {
        super.layout()
        swatch.frame = NSRect(x: 8, y: 6, width: 16, height: 16)
        badge.frame = swatch.frame
        let nw = min(name.fittingSize.width, bounds.width / 2)
        name.frame = NSRect(x: 30, y: 4, width: nw, height: 20)
        percent.frame = NSRect(x: name.frame.maxX + 6, y: 4, width: ceil(percent.textWidth) + 1, height: 20)
        trail.frame = NSRect(x: percent.frame.maxX + 6, y: 6, width: max(0, bounds.width - 8 - percent.frame.maxX - 6), height: 16)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 8
        layer?.backgroundColor = state.hoverOrPressed ? Themed.color(\.accent).cgColor(in: self) : nil
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true; updateLayer() }
    override func performAction() { segment?.openPopover(from: self) }
}

/// `AccountName`: the instance name, else the two-letter chip, else the driver.
@MainActor
enum UsageAccountName {
    static func make(_ a: UsageLimitAccount, font: NSFont) -> NSView {
        if let d = a.displayName { let l = LabelView(d, font: font, color: Themed.color(\.foreground)); l.lineHeight = 16; l.frame.size = l.intrinsicContentSize; return l }
        if let e = a.email { return UsageAccountChip(email: e) }
        let l = LabelView(UsageProviderLabels.driverLabel(a.driver), font: font, color: Themed.color(\.foreground))
        l.lineHeight = 16
        l.frame.size = l.intrinsicContentSize
        return l
    }
}

/// `AccountChip`: the initials on a 16pt circle in a stable hue (`oklch(0.85 0.08 h)` on `oklch(0.35 0.1 h)`).
final class UsageAccountChip: DSView {
    private let label: LabelView
    let hue: Int
    init(email: String) {
        hue = UsageLimitsLogic.accountHue(email)
        label = LabelView(UsageLimitsLogic.accountInitials(email), font: DSFont.ui(10, weight: .semibold),
                          color: OKLab.oklch(0.35, 0.1, CGFloat(UsageLimitsLogic.accountHue(email))))
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        label.lineHeight = 16
        label.alignment = .center
        addSubview(label)
        layer?.cornerRadius = 8
        layer?.backgroundColor = OKLab.oklch(0.85, 0.08, CGFloat(hue)).cgColor
        setAccessibilityLabel("Account \(UsageLimitsLogic.accountInitials(email))")
    }
    override var fittingSize: NSSize { NSSize(width: 16, height: 16) }
    override func layout() { super.layout(); label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16) }
}

/// `SegmentPopover`: who the account is, plan and where it is signed in, what is left and when it resets, and
/// the reset credit action. `w-72`, `gap-2.5`, sections divided by `border-border/60`.
final class UsageSegmentPopoverContent: DSView {
    /// Each part with its height and the gap above it.
    private var parts: [(view: NSView, height: CGFloat, gap: CGFloat)] = []
    private var rules: [DSView] = []
    var onUseReset: (() -> Void)?

    init(segment s: UsagePoolSegmentView) {
        super.init(frame: .zero)
        let a = s.account
        let header = DSView()
        let avatar: NSView = a.redeem != nil
            ? ProviderIcon.make(driver: a.driver, displayName: a.displayName ?? UsageProviderLabels.driverLabel(a.driver), size: 16,
                                color: Themed.color(\.foreground, 0.8))
            : a.email.map { UsageAccountChip(email: $0) } ?? DSView()
        let title = UsageStyle.label(a.displayName ?? UsageProviderLabels.driverLabel(a.driver), 14, .medium)
        header.addSubview(avatar)
        header.addSubview(title)
        avatar.frame = NSRect(x: 2, y: 2, width: 16, height: 16)
        title.frame = NSRect(x: 26, y: 0, width: 256 - 26, height: 20)
        add(header, 20)
        if let email = a.email {
            let r = UsageRedactedTextView(email)
            let wrap = DSView()
            wrap.addSubview(r)
            r.frame = NSRect(origin: NSPoint(x: 0, y: 0), size: r.intrinsicContentSize)
            add(wrap, 16, gap: 2)
        }
        var rows: [(String, String)] = []
        if let plan = a.plan { rows.append(("Plan", plan)) }
        let where_ = a.environments.isEmpty ? a.sourceLabel : a.environments.map(\.label).joined(separator: ", ")
        if let w = where_ { rows.append((a.environments.isEmpty ? "Via" : "Signed in", w)) }
        if !rows.isEmpty { section(rows) }
        var rows2: [(String, String)] = [("Left", "\(s.remaining)%")]
        if let at = s.limitWindow.resetsAt {
            rows2.append(("Resets", UsageTime.upcoming(at, nowMs: s.nowMs) + (s.resetsIn.map { " · " + $0.replacingOccurrences(of: "resets in ", with: "in ") } ?? "")))
        }
        // UsageLimitsPooled.tsx:193
        if let t = s.timeLeft { rows2.append(("Even pace", "\(t)% left by now")) }
        if let r = s.reset, r.restoresPercent > 0 { rows2.append(("Restores", "+\(r.restoresPercent)% of pool")) }
        section(rows2)
        if a.redeem != nil, let credits = a.limits.resetCredits, credits.availableCount > 0 {
            let line = DSView()
            let text = UsageStyle.label(UsageLimitsLogic.resetCreditsSummary(credits, nowMs: s.nowMs, compact: true), 12,
                                        color: Themed.color(\.mutedForeground), tabular: true)
            let button = ButtonView("Use reset", variant: .outline, size: .xs)
            button.action = { [weak self] in self?.onUseReset?() }
            line.addSubview(text)
            line.addSubview(button)
            text.frame = NSRect(x: 0, y: 4, width: 180, height: 16)
            let bw = button.intrinsicContentSize.width
            button.frame = NSRect(x: 256 - bw, y: 0, width: bw, height: 24)
            rule()
            add(line, 24, gap: 10)
        }
    }

    private func add(_ v: NSView, _ h: CGFloat, gap: CGFloat = 10) {
        addSubview(v)
        parts.append((v, h, parts.isEmpty ? 0 : gap))
    }

    private func rule() {
        let r = DSView()
        r.layer?.backgroundColor = Themed.color(\.border, 0.6).cgColor
        addSubview(r)
        rules.append(r)
        parts.append((r, 1, 10))
    }

    /// `Row`: a 72pt muted label column and the value.
    private func section(_ rows: [(String, String)]) {
        rule()
        let v = DSView()
        for (i, (k, value)) in rows.enumerated() {
            let kl = UsageStyle.label(k, 12, color: Themed.color(\.mutedForeground))
            let vl = UsageStyle.label(value, 12, tabular: true)
            kl.frame = NSRect(x: 0, y: CGFloat(i) * 20, width: 72, height: 16)
            vl.frame = NSRect(x: 84, y: CGFloat(i) * 20, width: 256 - 84, height: 16)
            v.addSubview(kl)
            v.addSubview(vl)
        }
        addSubview(v)
        parts.append((v, CGFloat(rows.count) * 16 + CGFloat(rows.count - 1) * 4, 10))
    }

    override var fittingSize: NSSize { NSSize(width: 256, height: parts.reduce(0) { $0 + $1.gap + $1.height }) }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for p in parts {
            y += p.gap
            p.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: p.height)
            y += p.height
        }
    }

    override func updateLayer() { for r in rules { r.layer?.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) } }
}

/// `CursorEnableLimits`: the Cursor heading and a bordered box with the Keychain copy and an Enable button per environment.
final class UsageCursorPromptView: DSView, SettingsGroupRow {
    static let copy = "Requires access to your Cursor login in macOS Keychain."
    private let icon = ProviderIcon.make(driver: "cursor", displayName: "Cursor", size: 16, color: Themed.color(\.foreground, 0.8))
    private let title = UsageStyle.label("Cursor", 14, .medium)
    private let box = BoxView()
    private let text = UsageStyle.label(copy, 12, color: Themed.color(\.mutedForeground))
    private var buttons: [ButtonView] = []

    init(environments: [(id: String, label: String)], onEnable: @escaping (String) -> Void) {
        super.init(frame: .zero)
        var s = BoxStyle()
        s.radius = 8
        s.border = Themed.color(\.border, 0.6)
        box.boxStyle = s
        for v in [icon, title, box, text] as [NSView] { addSubview(v) }
        buttons = environments.map { e in
            let b = ButtonView(environments.count > 1 ? "Enable on \(e.label)" : "Enable", variant: .outline, size: .sm)
            b.setAccessibilityLabel("Enable Cursor usage from \(e.label)")
            b.action = { [weak b] in b?.isEnabled = false; onEnable(e.id) }
            addSubview(b)
            return b
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat { 20 + 12 + 16 + 16 + 12 + 32 + 16 }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 2, y: 2, width: 16, height: 16)
        title.frame = NSRect(x: 28, y: 0, width: 80, height: 20)
        box.frame = NSRect(x: 0, y: 32, width: bounds.width, height: bounds.height - 32)
        text.frame = NSRect(x: 16, y: 48, width: bounds.width - 32, height: 16)
        var x: CGFloat = 16
        for b in buttons {
            let w = b.intrinsicContentSize.width
            b.frame = NSRect(x: x, y: 76, width: w, height: 32)
            x += w + 8
        }
    }
}

/// An external usage destination (`rounded-xl border p-4`): ChatGPT's mark, the label and its line, and Manage usage.
final class UsageExternalLinkRow: BoxView, SettingsGroupRow {
    private let icon: NSView?
    private let title: LabelView
    private let line: TextBlockView
    private let button = ButtonView("Manage usage", variant: .ghostMuted, size: .xs)

    init(_ link: (label: String, url: String, message: String?), onOpen: @escaping @MainActor () -> Void) {
        let chatGpt = link.url == UsageLimitsLogic.chatGptUsageURL
        icon = chatGpt ? IconView(name: .brandOpenAI, size: 20, strokeColor: Themed.color(\.foreground)) : nil
        title = UsageStyle.label(link.label, 14, .medium)
        line = TextBlockView()
        line.text = chatGpt ? "View usage in ChatGPT with your connected account." : link.message ?? ""
        line.font = DSFont.ui(12)
        line.lineHeight = 16
        line.color = Themed.color(\.mutedForeground)
        super.init(frame: .zero)
        var s = BoxStyle()
        s.radius = 12
        s.border = Themed.color(\.border)
        boxStyle = s
        button.trailingIcon = .externalLink
        button.action = onOpen
        for v in [title, line, button] as [NSView] { addSubview(v) }
        icon.map(addSubview)
    }

    func height(forWidth width: CGFloat) -> CGFloat { 16 + 20 + (line.text.isEmpty ? 0 : 4 + 16) + 16 + 2 }

    override func layout() {
        super.layout()
        let bw = button.intrinsicContentSize.width
        button.frame = NSRect(x: bounds.width - 17 - bw, y: (bounds.height - 24) / 2, width: bw, height: 24)
        var x: CGFloat = 17
        if let icon { icon.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: 20, height: 20); x += 32 }
        let top: CGFloat = line.text.isEmpty ? (bounds.height - 20) / 2 : 17
        title.frame = NSRect(x: x, y: top, width: bounds.width - x - bw - 30, height: 20)
        line.frame = NSRect(x: x, y: top + 24, width: min(576, bounds.width - x - bw - 30), height: 16)
    }
}
