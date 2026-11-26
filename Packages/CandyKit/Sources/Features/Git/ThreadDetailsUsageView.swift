import AppKit
import DesignSystem
import T3Protocol

/// One row of the card's Usage limits or Context window section (4928 ThreadDetailsUsage.tsx:226-300): a label,
/// a 3pt bar with an optional tick, and the value. Usage rows open the Usage page.
public struct ThreadDetailsUsageRow: Equatable, Sendable {
    public enum Tone: Sendable { case error, warning }
    public var label: String
    /// 0 to 100; nil hides the bar and lets the value take its column.
    public var fill: Double?
    public var tone: Tone?
    /// A marker on the bar, 0 to 100.
    public var tick: Double?
    public var value: String
    public var tooltip: [String]
    public var muted = false
    public var opensUsage = false
    public init(label: String, fill: Double?, tone: Tone?, tick: Double? = nil, value: String, tooltip: [String],
                muted: Bool = false, opensUsage: Bool = false) {
        self.label = label; self.fill = fill; self.tone = tone; self.tick = tick; self.value = value; self.tooltip = tooltip
        self.muted = muted; self.opensUsage = opensUsage
    }

    /// `ThreadDetailsContext` (ThreadDetailsUsage.tsx:84-155): tokens against the limit, the auto-compact tick.
    public static func context(_ u: ThreadContextWindowUsage) -> ThreadDetailsUsageRow {
        let maximum = u.maximum.flatMap { $0 > 0 ? $0 : nil }
        let used = maximum != nil ? u.percentage.map { Int($0.rounded()) } : nil
        let threshold = u.autoCompactThreshold
        let tick = maximum.flatMap { m in threshold.flatMap { $0 > 0 && $0 < m ? $0 / m * 100 : nil } }
        let usedTokens = ThreadContextWindowUsage.tokens(u.used)
        func grouped(_ v: Double) -> String { Int(v).formatted(.number.locale(Locale(identifier: "en_US"))) }
        var tooltip = [used.map { "Context: \($0)% used" } ?? "Context: \(usedTokens) tokens used"]
        if let maximum { tooltip.append("\(grouped(u.used)) of \(grouped(maximum)) tokens") }
        if let threshold, threshold > 0 { tooltip.append("Compacts automatically at about \(grouped(threshold)) tokens.") }
        return ThreadDetailsUsageRow(label: "Context", fill: used.map(Double.init),
                                     tone: used.flatMap { $0 >= 90 ? .error : $0 >= 80 ? .warning : nil }, tick: tick,
                                     value: maximum.map { "\(usedTokens) / \(ThreadContextWindowUsage.tokens($0))" } ?? usedTokens,
                                     tooltip: tooltip, muted: true)
    }

    /// `LimitRow` (5258 ThreadDetailsUsage.tsx:185-233): room left, the time left as the tick, the pace and reset.
    /// An HTTP quota's row names its account under the first line.
    public static func limit(_ w: UsageLimitWindow, nowMs: Int64, accountLabel: String? = nil) -> ThreadDetailsUsageRow {
        let left = UsageLimitsLogic.remainingPercent(w)
        let elapsed = UsageLimitsLogic.elapsedShare(w, nowMs: nowMs)
        let timeLeft = elapsed.map { Int(((1 - $0) * 100).rounded()) }  // `paceRemainingPercent`
        var tooltip = ["\(w.label): \(left)% left"]
        if let accountLabel { tooltip.append(accountLabel) }
        if let pace = UsageLimitsLogic.pace(w, nowMs: nowMs), let timeLeft {
            tooltip.append("\(paceWord(pace)) · \(timeLeft)% of the window left")
        }
        if let reset = w.resetsAt.flatMap(T3Timestamp.parseEpochMs), reset > nowMs {
            tooltip.append("Resets in \(UsageLimitsLogic.duration(Double(reset - nowMs))) · \(resetTime(reset))")
        }
        return ThreadDetailsUsageRow(label: w.label, fill: Double(left), tone: tone(left),
                                     tick: timeLeft.map(Double.init), value: "\(left)%", tooltip: tooltip, opensUsage: true)
    }

    /// `PoolRow` (5258 ThreadDetailsUsage.tsx:235-293): a hub pool's room left across its accounts, the next
    /// reset that restores something, and the hubs it reads.
    public static func pool(_ w: UsageLimitPoolWindow, nowMs: Int64) -> ThreadDetailsUsageRow {
        let left = w.remainingPercent
        let accounts = w.members.count
        let from = UsageLimitsLogic.poolSources(w)
        let sources = from.hubs + (from.signedIn ? ["Signed-in accounts"] : [])
        var tooltip = [accounts > 1 ? "\(w.label): \(left)% left across \(accounts) accounts" : "\(w.label): \(left)% left"]
        if let pace = w.pace { tooltip.append(paceWord(pace)) }
        if let next = UsageLimitsLogic.nextPoolReset(w, nowMs: nowMs), let at = next.window.resetsAt.flatMap(T3Timestamp.parseEpochMs) {
            let duration = UsageLimitsLogic.duration(Double(next.at - nowMs)), time = resetTime(at)
            tooltip.append(accounts > 1 ? "+\(next.restoresPercent)% in \(duration) · \(time)" : "Resets in \(duration) · \(time)")
        }
        if !sources.isEmpty { tooltip.append("From \(sources.joined(separator: ", "))") }
        return ThreadDetailsUsageRow(label: w.label, fill: Double(left), tone: tone(left), value: "\(left)%", tooltip: tooltip, opensUsage: true)
    }

    /// `limitTone`.
    static func tone(_ left: Int) -> Tone? { left <= 10 ? .error : left <= 20 ? .warning : nil }

    static func paceWord(_ pace: UsageLimitPace) -> String {
        switch pace { case .ahead: "Ahead of pace"; case .on: "On pace"; case .under: "Under pace" }
    }

    // ponytail: the reset time is a short local time; T3's formatUpcomingTimestamp adds the day when it isn't today
    static func resetTime(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened)
    }

    /// `ThreadDetailsUsage` (5258 ThreadDetailsUsage.tsx:58-91): a hub pool's rows or the instance's windows (one
    /// "Limits · Unavailable" row with the reason), then the instance's HTTP quotas. With quotas, an instance
    /// whose own limits are unavailable shows only the quotas.
    public static func limits(instanceId: String?, model: String? = nil, providers: [ServerProvider], sources: [UsageLimitSourceSnapshot],
                              nowMs: Int64) -> [ThreadDetailsUsageRow] {
        let resolved = UsageLimitsLogic.threadDetailsLimits(instanceId: instanceId, model: model, providers: providers, sources: sources, nowMs: nowMs)
        let quotas = UsageLimitsLogic.threadHttpQuotas(instanceId: instanceId, sources: sources)
        var rows: [ThreadDetailsUsageRow] = []
        switch resolved {
        case .pool(let windows): rows = windows.map { pool($0, nowMs: nowMs) }
        case .instance(let limits):
            if let notice = UsageLimitsLogic.notice(limits) {
                if quotas.isEmpty {
                    rows = [ThreadDetailsUsageRow(label: "Limits", fill: nil, tone: nil, value: "Unavailable", tooltip: [notice], opensUsage: true)]
                }
            } else {
                rows = limits.windows.map { limit($0, nowMs: nowMs) }
            }
        case nil: break
        }
        return rows + quotas.map { limit($0.window, nowMs: nowMs, accountLabel: $0.accountLabel) }
    }
}

/// A `ThreadDetailsSection` of usage rows: `px-2 pt-2 pb-2.5` under the `border/65` rule, the rows in a shared
/// `grid-cols-[auto_minmax(3rem,1fr)_auto] gap-x-3` so labels and values line up.
public final class ThreadDetailsUsageSectionView: DSView {
    public var rows: [ThreadDetailsUsageRow] = [] { didSet { if rows != oldValue { rebuild() } } }
    /// Draws the rule over the section (a section shows above it).
    public var separated = true { didSet { rule.isHidden = !separated } }
    public var onOpenUsage: (@MainActor () -> Void)?
    private var views: [RowView] = []
    private let rule = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rule.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(rule)
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var preferredHeight: CGFloat { rows.isEmpty ? 0 : 1 + 8 + CGFloat(rows.count) * 24 + 10 }

    private func rebuild() {
        views.forEach { $0.removeFromSuperview() }
        views = rows.map { row in
            let v = RowView(row)
            if row.opensUsage { v.action = { [weak self] in self?.onOpenUsage?() } }
            addSubview(v)
            return v
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let labelWidth = views.map(\.labelWidth).max() ?? 0, valueWidth = views.map(\.valueWidth).max() ?? 0
        var y: CGFloat = 1 + 8
        for v in views {
            v.columns = (labelWidth, valueWidth)
            v.frame = NSRect(x: 8, y: y, width: bounds.width - 16, height: 24)
            y += 24
        }
    }

    public override func updateLayer() {
        super.updateLayer()
        rule.backgroundColor = Themed.color(\.border, 0.65).cgColor(in: self)
    }

    /// `UsageRow`: `h-6 rounded-lg px-2.5`, hover `black/3.5%` (dark `white/8%`), the tooltip on the left.
    final class RowView: ControlView {
        let row: ThreadDetailsUsageRow
        private let label: LabelView
        private let value: LabelView
        private let track = CALayer(), bar = CALayer(), mark = CALayer()
        private let fill = CALayer()
        var columns: (label: CGFloat, value: CGFloat) = (0, 0) { didSet { needsLayout = true } }

        init(_ row: ThreadDetailsUsageRow) {
            self.row = row
            label = LabelView(row.label, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            value = LabelView(row.value, font: DSFont.ui(12, weight: .medium).monospacedDigits, color: Themed.color(\.foreground, 0.8))
            super.init(frame: .zero)
            scalesWhenPressed = false
            wantsLayer = true
            label.lineHeight = 16
            value.lineHeight = 16
            label.truncates = true
            for l in [track, bar, mark, fill] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
            layer?.addSublayer(fill)
            track.cornerRadius = 1.5
            bar.cornerRadius = 1.5
            layer?.addSublayer(track)
            track.addSublayer(bar)
            track.addSublayer(mark)
            track.masksToBounds = false
            addSubview(label)
            addSubview(value)
            TooltipController.attach(to: self, text: (row.tooltip + (row.opensUsage ? ["Open usage"] : [])).joined(separator: "\n"))
            setAccessibilityLabel("\(row.label): \(row.value)")
            setAccessibilityRole(row.opensUsage ? .link : .group)
            restyle()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        var labelWidth: CGFloat { min(112, ceil(label.textWidth) + 1) }  // `max-w-28`
        var valueWidth: CGFloat { row.fill == nil ? 0 : ceil(value.textWidth) + 1 }

        override var acceptsFirstResponder: Bool { false }
        override func resetCursorRects() { if row.opensUsage { addCursorRect(bounds, cursor: .pointingHand) } }
        override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
        override func updateLayer() { super.updateLayer(); restyle() }

        private func restyle() {
            let dark = effectiveAppearance.isDark
            let hover = row.opensUsage ? state.hoverOrPressed : state.hovered
            let alpha: Double = state.active && row.opensUsage ? (dark ? 0.12 : 0.06) : hover ? (dark ? 0.08 : 0.035) : 0
            fill.backgroundColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha).cgColor
            fill.cornerRadius = 8
            label.color = Themed.color(row.opensUsage && hover ? \.foreground : \.mutedForeground)
            track.backgroundColor = Themed.color(\.mutedForeground, dark ? 0.2 : 0.3).cgColor(in: self)
            let barColor: NSColor = switch row.tone {
            case .error: Themed.color(\.error)
            case .warning: Themed.color(\.warning)
            case nil: row.muted ? Themed.color(\.mutedForeground) : Themed.color(\.foreground, 0.8)
            }
            bar.backgroundColor = barColor.cgColor(in: self)
            mark.backgroundColor = Themed.color(\.foreground, 0.75).cgColor(in: self)
            value.color = switch row.tone {
            case .error: Themed.color(\.errorForeground)
            case .warning: Themed.color(\.warningForeground)
            case nil: row.fill == nil ? Themed.color(\.mutedForeground) : Themed.color(\.foreground, 0.8)
            }
        }

        override func layout() {
            super.layout()
            fill.frame = bounds
            let x0: CGFloat = 10, gap: CGFloat = 12
            label.frame = NSRect(x: x0, y: 4, width: columns.label, height: 16)
            let valueRight = bounds.width - 10
            if let f = row.fill {
                let vw = columns.value
                value.frame = NSRect(x: valueRight - vw, y: 4, width: vw, height: 16)
                value.alignment = .right
                let barX = x0 + columns.label + gap, barW = max(0, valueRight - vw - gap - barX)
                track.isHidden = false
                track.frame = CGRect(x: barX, y: 10.5, width: barW, height: 3)
                bar.isHidden = f <= 0
                bar.frame = CGRect(x: 0, y: 0, width: min(barW, max(6, barW * f / 100)), height: 3)  // `max(fill%, 6px)`
                mark.isHidden = row.tick == nil
                if let t = row.tick { mark.frame = CGRect(x: min(barW - 0.5, max(0.5, barW * t / 100)) - 0.5, y: -3, width: 1, height: 9) }
            } else {
                track.isHidden = true
                let x = x0 + columns.label + gap
                value.frame = NSRect(x: x, y: 4, width: max(0, valueRight - x), height: 16)
                value.alignment = .right
            }
        }
    }
}
