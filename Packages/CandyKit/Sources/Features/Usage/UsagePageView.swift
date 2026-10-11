import AppKit
import DesignSystem
import T3Protocol

/// The Usage page's choices (usageShortcuts.ts, usagePagePreferences.ts).
public enum UsagePageOptions {
    public static let metrics: [(value: String, label: String, command: String)] = [
        ("cost", "Cost", "usage.cost"), ("tokens", "Tokens", "usage.tokens"), ("limits", "Limits", "usage.limits"),
    ]
    public static let windows: [(days: Int, label: String, command: String)] = [
        (1, "Past 24h", "usage.period.day"), (7, "7 days", "usage.period.week"), (30, "30 days", "usage.period.month"), (90, "90 days", "usage.period.quarter"),
    ]

    /// `t3code:usage-page-preferences:v1`; Limits is the first-visit default.
    public struct Preferences: Equatable, Sendable {
        public var metric = "limits"
        public var windowDays = 30
        public var hiddenProviders: [UsageProviderKind] = []
        public init() {}

        public init(json: JSONValue?) {
            if let m = json?["metric"]?.stringValue, metrics.contains(where: { $0.value == m }) { metric = m }
            if let d = json?["windowDays"]?.intValue, windows.contains(where: { $0.days == d }) { windowDays = d }
            hiddenProviders = json?["hiddenProviders"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UsageProviderKind.init(rawValue:)) } ?? []
        }

        public var json: JSONValue {
            var o: [String: JSONValue] = ["metric": .string(metric), "windowDays": .number(Double(windowDays))]
            if !hiddenProviders.isEmpty { o["hiddenProviders"] = .array(hiddenProviders.map { .string($0.rawValue) }) }
            return .object(o)
        }
    }

    /// `UsageProviderFilter`'s label.
    public static func providerFilterLabel(hidden: Set<UsageProviderKind>) -> String {
        let visible = UsageProviderKind.allCases.filter { !hidden.contains($0) }
        return visible.count == UsageProviderKind.allCases.count ? "All providers"
            : visible.isEmpty ? "No providers" : visible.count == 1 ? visible[0].label : "\(visible.count) providers"
    }

    /// `UsageEnvironmentFilter`'s label.
    public static func environmentFilterLabel(allSelected: Bool, selectedLabels: [String]) -> String {
        allSelected ? "All environments" : selectedLabels.count == 1 ? selectedLabels[0] : "\(selectedLabels.count) environments"
    }

    /// The period named in the header: hours for the past 24h, else days.
    public static func windowLabel(_ w: UsageWindow) -> String {
        if w.isHourly, let s = w.sinceTime, let u = w.untilTime {
            return "\(UsageFormat.dateTimeShort(s, timeZone: w.timeZone)) to \(UsageFormat.dateTimeShort(u, timeZone: w.timeZone))"
        }
        return "\(UsageFormat.dayShort(w.sinceDay)) to \(UsageFormat.dayShort(w.untilDay))"
    }
}

/// Usage (UsagePage.tsx): the 52pt header with the breadcrumb (Usage / environments / providers), the period,
/// the metric and period toggles and refresh; under it a `max-w-5xl` page with the totals, chart, type split
/// and breakdown, or the pooled limits.
public final class UsagePageView: DSView {
    public enum Body: Equatable { case message(String), skeleton, errors([String]), usage, limits }

    public struct Model {
        public var metric = "limits"
        public var windowDays = 30
        public var windowLabel = ""
        public var environmentLabel = "All environments"
        public var environmentIssue = false
        public var providerLabel = "All providers"
        public var refreshing = false
        public var refreshEnabled = true
        public var body = Body.skeleton
        public var merged = MergedUsage()
        public var window = UsageWindow(sinceDay: "", untilDay: "", timeZone: "UTC")
        public var partial = false
        public var everyProviderLoading = false
        public var loadingProviders: Set<UsageProviderKind> = []
        public var activeProviders: [UsageProviderKind] = []
        public var providersWithData: [UsageProviderKind] = []
        public var sourceMessages: [String] = []
        /// Cursor Keychain rows in the summary (environment id, label), and whether to name the environment.
        public var cursorRows: [(id: String, label: String)] = []
        public var cursorShowsEnvironment = false
        public var breakdown = "model"
        public var shortcutTitles: [String: String] = [:]
        public init() {}

        func providerLoading(_ p: UsageProviderKind) -> Bool { everyProviderLoading || loadingProviders.contains(p) }
    }

    public var model = Model() { didSet { apply() } }
    public let limits = UsageLimitsView()

    // Callbacks.
    public var onMetric: ((String) -> Void)?
    public var onWindow: ((Int) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onEnvironmentMenu: ((NSView) -> Void)?
    public var onProviderMenu: ((NSView) -> Void)?
    public var onBreakdown: ((String) -> Void)?
    public var onSelectModel: ((String) -> Void)?
    public var onEnableCursor: ((String) -> Void)?
    /// Escape returns to the previous page (`useEscapeToGoBack`).
    public var onEscape: (() -> Void)?

    public let header = UsageHeaderView()
    private let document = DSView()
    private let scroll: ScrollAreaView
    private var sections: [NSView] = []
    private let breakdownTable = UsageBreakdownTableView()
    private let breakdownToggle = ToggleGroupView(items: [("Model", nil), ("Day", nil)], selected: 0)
    private let chart = UsageChartView()

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document)
        super.init(frame: frameRect)
        addSubview(scroll)
        addSubview(header)
        header.metric.onChange = { [weak self] i in
            guard let self else { return }
            guard let i else { self.header.metric.selectedIndex = UsagePageOptions.metrics.firstIndex { $0.value == self.model.metric }; return }
            self.onMetric?(UsagePageOptions.metrics[i].value)
        }
        header.period.onChange = { [weak self] i in
            guard let self else { return }
            guard let i else { self.header.period.selectedIndex = UsagePageOptions.windows.firstIndex { $0.days == self.model.windowDays }; return }
            self.onWindow?(UsagePageOptions.windows[i].days)
        }
        header.metricSelect.onChange = { [weak self] i in self?.onMetric?(UsagePageOptions.metrics[i].value) }
        header.periodSelect.onChange = { [weak self] i in self?.onWindow?(UsagePageOptions.windows[i].days) }
        header.refresh.action = { [weak self] in self?.onRefresh?() }
        header.compactRefresh.action = { [weak self] in self?.onRefresh?() }
        header.environment.action = { [weak self] in guard let self else { return }; self.onEnvironmentMenu?(self.header.environment) }
        header.providers.action = { [weak self] in guard let self else { return }; self.onProviderMenu?(self.header.providers) }
        breakdownToggle.onChange = { [weak self] i in
            guard let self else { return }
            guard let i else { self.breakdownToggle.selectedIndex = self.model.breakdown == "model" ? 0 : 1; return }
            self.onBreakdown?(i == 0 ? "model" : "time")
        }
        breakdownTable.onSelect = { [weak self] key in self?.onSelectModel?(key) }
        limits.onEnableCursor = { [weak self] id in self?.onEnableCursor?(id) }
        apply()
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func cancelOperation(_ sender: Any?) { onEscape?() }

    // MARK: Model

    private func apply() {
        let m = model
        header.apply(m)
        rebuild()
        needsLayout = true
    }

    private var viewport: CGFloat { window?.frame.width ?? bounds.width }

    private func rebuild() {
        sections.forEach { $0.removeFromSuperview() }
        sections = []
        let m = model
        switch m.body {
        case .message(let text):
            sections = [UsageParagraphRow(text)]
        case .errors(let lines):
            sections = lines.map { l in let p = UsageParagraphRow(l); return p }
        case .limits:
            sections = [limits]
        case .skeleton:
            sections = [UsageSkeletonView()]
        case .usage:
            sections = m.sourceMessages.map { UsageParagraphRow($0) }
            sections.append(UsageSummarySectionView(model: m, chart: chart, owner: self))
            sections.append(UsageTotalsView(model: m))
            if m.merged.totalTokens > 0 {
                var bars: [UsageShareBarView] = []
                if m.metric == "tokens" {
                    UsageShareBarView(label: "Tokens by type", segments: UsageBreakdown.tokenSegments(m.merged.tokenTotals), format: UsageFormat.tokens).map { bars.append($0) }
                } else {
                    UsageShareBarView(label: "Cost by type", segments: UsageBreakdown.costSegments(m.merged.categoryCost), format: UsageFormat.usd).map { bars.append($0) }
                    if m.merged.speedCost.fast + m.merged.speedCost.ultrafast > 0,
                       let speed = UsageShareBarView(label: "Cost by speed", segments: UsageBreakdown.speedSegments(m.merged.speedCost), format: UsageFormat.usd) {
                        speed.aside = UsageBreakdown.premiumLabel(m.merged.speedCost.premium)
                        bars.append(speed)
                    }
                }
                if !bars.isEmpty { sections.append(UsageShareGridView(bars, dimmed: m.partial)) }
            }
            sections.append(UsageBreakdownSectionView(toggle: breakdownToggle, table: breakdownTable))
            breakdownToggle.items[1].title = m.window.isHourly ? "Hour" : "Day"
            breakdownToggle.selectedIndex = m.breakdown == "model" ? 0 : 1
            breakdownTable.content = breakdownContent(m)
        }
        sections.forEach(document.addSubview)
    }

    private func breakdownContent(_ m: Model) -> UsageBreakdownTableView.Content {
        let tokens = m.metric == "tokens"
        if m.breakdown == "model" {
            let models = tokens ? UsageBreakdown.sortByTokens(m.merged.models) : m.merged.models
            let peak = models.reduce(0) { max($0, tokens ? $1.totalTokens : $1.costUsd) }
            return .models(models.map { model in
                let value = tokens ? model.totalTokens : model.costUsd
                let share = UsageBreakdown.share(model, tokens: tokens)
                return .init(key: model.key, provider: model.provider, model: model.model,
                             cost: model.isCostUnknown ? "Unpriced" : UsageFormat.usd(model.costUsd), costMuted: model.isCostUnknown,
                             share: share.map { UsageFormat.percent($0) } ?? "", tokens: UsageFormat.tokens(model.totalTokens),
                             fraction: value > 0 && peak > 0 ? value / peak : 0, loading: m.providerLoading(model.provider))
            })
        }
        let periods = (m.window.isHourly ? m.merged.hourly : m.merged.daily).reversed()
        return .periods(header: m.window.isHourly ? "Hour" : "Day", providers: m.activeProviders, rows: periods.map { p in
            .init(label: m.window.isHourly ? UsageFormat.hourShort(p.hourStart ?? "", timeZone: m.window.timeZone) : UsageFormat.dayShort(p.day),
                  providers: m.activeProviders.map { UsageFormat.usd(p.byProvider[$0]?.costUsd ?? 0) },
                  providerLoading: m.activeProviders.map { m.providerLoading($0) },
                  total: UsageFormat.usd(p.costUsd), tokens: UsageFormat.tokens(p.totalTokens))
        }, loading: m.partial)
    }

    // MARK: Layout

    private func sectionHeight(_ v: NSView, _ width: CGFloat) -> CGFloat {
        if let r = v as? SettingsGroupRow { return r.height(forWidth: width) }
        if let s = v as? UsageSectionSizing { return s.height(forWidth: width, viewport: viewport) }
        return v.fittingSize.height
    }

    public override func layout() {
        super.layout()
        let headerH = UsageHeaderView.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerH)
        header.viewport = viewport
        scroll.frame = NSRect(x: 0, y: headerH, width: bounds.width, height: max(0, bounds.height - headerH))
        // `WorkspacePageContainer width="wide"`: max-w-5xl, px-5 sm:px-6, pt-6 pb-12, gap-6.
        let pad: CGFloat = viewport >= 640 ? 24 : 20
        let outer = min(bounds.width, 1024)
        let inner = outer - 2 * pad
        let x0 = (bounds.width - outer) / 2 + pad
        breakdownTable.showsShare = viewport >= 640
        var y: CGFloat = 24
        for (i, s) in sections.enumerated() {
            let h = sectionHeight(s, inner)
            // `mb-4` on the source messages adds to the gap.
            s.frame = NSRect(x: x0, y: y, width: inner, height: h)
            s.needsLayout = true
            y += h + (i < sections.count - 1 ? 24 : 0) + (s is UsageParagraphRow && model.body == .usage ? 16 : 0)
        }
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: y + 48)
    }

    public func scrollToTop() { scroll.scroll(to: .zero) }
}

/// Sections whose layout depends on the window's width (Tailwind breakpoints are viewport widths).
@MainActor protocol UsageSectionSizing: NSView {
    func height(forWidth width: CGFloat, viewport: CGFloat) -> CGFloat
}

/// `WorkspacePageHeader`: breadcrumb, period (2xl), and at xl the segmented toggles and refresh; narrower, two
/// compact ghost selects and refresh.
public final class UsageHeaderView: TopbarDragView {
    static let height: CGFloat = 52
    private let title = UsageStyle.label("Usage", 14, .medium, color: Themed.color(\.mutedForeground))
    private let slash1 = UsageStyle.label("/", 14, .medium, color: Themed.color(\.iconMuted))
    private let slash2 = UsageStyle.label("/", 14, .medium, color: Themed.color(\.iconMuted))
    public let environment = UsageInlineMenuButton()
    public let providers = UsageInlineMenuButton()
    private let windowLabel = UsageStyle.label("", 12, color: Themed.color(\.mutedForeground))
    public let metric = ToggleGroupView(items: UsagePageOptions.metrics.map { ($0.label, nil) }, selected: 2)
    public let period = ToggleGroupView(items: UsagePageOptions.windows.map { ($0.label, nil) }, selected: 2)
    public let refresh = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconSm)
    public let metricSelect = SelectView(options: UsagePageOptions.metrics.map(\.label), selected: 2, variant: .ghost, size: .compact)
    public let periodSelect = SelectView(options: UsagePageOptions.windows.map(\.label), selected: 2, variant: .ghost, size: .compact)
    public let compactRefresh = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconSm)
    var viewport: CGFloat = 1440 { didSet { if viewport != oldValue { needsLayout = true } } }
    private var showsWindowLabel = true

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v in [title, slash1, slash2, environment, providers, windowLabel, metric, period, refresh, metricSelect, periodSelect, compactRefresh] as [NSView] {
            addSubview(v)
        }
        for b in [refresh, compactRefresh] { b.iconSize = 14 }
        for s in [metricSelect, periodSelect] { s.fitsContent = true; s.alignItemWithTrigger = false; s.popupAlign = .end }
        setAccessibilityLabel("Usage breadcrumb")
    }

    func apply(_ m: UsagePageView.Model) {
        environment.title = m.environmentLabel
        environment.alert = m.environmentIssue && m.metric != "limits"
        providers.title = m.providerLabel
        windowLabel.text = m.windowLabel
        showsWindowLabel = m.metric != "limits"
        let mi = UsagePageOptions.metrics.firstIndex { $0.value == m.metric }
        let pi = UsagePageOptions.windows.firstIndex { $0.days == m.windowDays }
        metric.selectedIndex = mi
        period.selectedIndex = pi
        metricSelect.selectedIndex = mi
        periodSelect.selectedIndex = pi
        let limits = m.metric == "limits"
        period.items.forEach { $0.isEnabled = !limits }
        periodSelect.isEnabled = !limits
        for (i, o) in UsagePageOptions.metrics.enumerated() { metric.items[i].toolTip = m.shortcutTitles[o.command] ?? o.label }
        for (i, o) in UsagePageOptions.windows.enumerated() { period.items[i].toolTip = m.shortcutTitles[o.command] ?? o.label }
        for b in [refresh, compactRefresh] {
            b.isEnabled = m.refreshEnabled && !m.refreshing
            b.setAccessibilityLabel(limits ? "Refresh limits" : "Refresh usage")
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let xl = viewport >= 1280, xxl = viewport >= 1536
        for v in [metric, period, refresh] as [NSView] { v.isHidden = !xl }
        for v in [metricSelect, periodSelect, compactRefresh] as [NSView] { v.isHidden = xl }
        windowLabel.isHidden = !(xxl && showsWindowLabel)
        // Right cluster first, so the breadcrumb truncates into what is left.
        var right = bounds.width - 20
        let controls: [NSView] = xl ? [refresh, period, metric] : [compactRefresh, periodSelect, metricSelect]
        for (i, c) in controls.enumerated() {
            let s = c.intrinsicContentSize
            right -= s.width
            c.frame = NSRect(x: right, y: ((Self.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            right -= xl ? 8 : 4
            _ = i
        }
        var x: CGFloat = 20
        let gap: CGFloat = viewport >= 640 ? 12 : 8
        title.frame = NSRect(x: x, y: 16, width: ceil(title.textWidth) + 1, height: 20)
        x = title.frame.maxX + gap
        slash1.frame = NSRect(x: x, y: 16, width: ceil(slash1.textWidth), height: 20)
        x = slash1.frame.maxX + gap
        let budget = max(0, right - 12 - x)
        let ew = min(environment.intrinsicContentSize.width, max(40, budget * 0.6))
        environment.frame = NSRect(x: x, y: 14, width: ew, height: 24)
        x = environment.frame.maxX + gap
        slash2.frame = NSRect(x: x, y: 16, width: ceil(slash2.textWidth), height: 20)
        x = slash2.frame.maxX + gap
        let pw = min(providers.intrinsicContentSize.width, max(40, right - 12 - x))
        providers.frame = NSRect(x: x, y: 14, width: pw, height: 24)
        x = providers.frame.maxX + 12
        if !windowLabel.isHidden {
            windowLabel.frame = NSRect(x: x, y: 18, width: max(0, min(ceil(windowLabel.textWidth) + 1, right - 12 - x)), height: 16)
        }
    }
}

/// `InlineButton` in the breadcrumb: 14pt medium foreground, underlined on hover, with a chevron that shows
/// on hover and while its menu is open, or a warning glyph when something needs attention.
public final class UsageInlineMenuButton: ControlView {
    private let label = UsageStyle.label("", 14, .medium)
    private let chevron = IconView(name: .chevronDown, size: 14)
    private let warning = IconView(name: .circleAlert, size: 14)
    public var title = "" { didSet { label.text = title; invalidateIntrinsicContentSize(); needsLayout = true } }
    public var alert = false { didSet { restyle() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        addSubview(label)
        addSubview(chevron)
        addSubview(warning)
        setAccessibilityRole(.popUpButton)
        restyle()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 2 + 14, height: 24) }

    public override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }

    private func restyle() {
        let active = state.hoverOrPressed || state.popupOpen
        label.isUnderlined = state.hoverOrPressed
        chevron.strokeColor = Themed.color(\.mutedForeground)
        chevron.isHidden = alert || !active
        warning.isHidden = !alert
        warning.strokeColor = Themed.color(\.warningForeground)
    }

    public override func layout() {
        super.layout()
        let lw = min(ceil(label.textWidth), bounds.width - 16)
        label.frame = NSRect(x: 0, y: 2, width: lw, height: 20)
        chevron.frame = NSRect(x: lw + 2, y: 5, width: 14, height: 14)
        warning.frame = chevron.frame
    }
}

/// The summary column beside the chart (`lg:grid-cols-[minmax(0,18rem)_minmax(0,1fr)]`, stacked below 1024pt).
final class UsageSummarySectionView: DSView, UsageSectionSizing {
    private let big: LabelView
    private let caption: LabelView
    private let info: IconView?
    private var rows: [NSView & SettingsGroupRow] = []
    private let chartTitle: LabelView
    private let chart: UsageChartView

    init(model m: UsagePageView.Model, chart: UsageChartView, owner: UsagePageView) {
        let cost = m.metric == "cost"
        big = UsageStyle.label(cost ? UsageFormat.usd(m.merged.costUsd) : UsageFormat.tokens(m.merged.totalTokens), 36, .semibold, tabular: true,
                               lineHeight: 40)
        big.alphaValue = m.partial ? 0.4 : 1
        caption = UsageStyle.label("\(UsageFormat.count(m.merged.sessions)) sessions" + (cost ? " · API estimate" : ""), 12,
                                   color: Themed.color(\.mutedForeground))
        if cost, m.merged.unpricedShare > 0 {
            let i = IconView(name: .info, size: 12, strokeColor: Themed.color(\.mutedForeground))
            _ = TooltipController.attach(to: i, text: "API estimate excludes \(UsageFormat.percent(m.merged.unpricedShare)) unpriced records.")
            info = i
        } else { info = nil }
        chartTitle = UsageStyle.label((m.window.isHourly ? "Hourly " : "Daily ") + (m.metric == "tokens" ? "processed tokens" : "cost"), 14, .medium)
        self.chart = chart
        super.init(frame: .zero)
        for v in [big, caption, chartTitle, chart] as [NSView] { addSubview(v) }
        info.map(addSubview)
        // Cursor's Enable rows go right after Codex and Claude (`cursorInsertAt`).
        var providerRows: [NSView & SettingsGroupRow] = m.activeProviders.map { UsageProviderSummaryRow(provider: $0, model: m) }
        let insertAt = max(m.activeProviders.firstIndex(of: .codex) ?? -1, m.activeProviders.firstIndex(of: .claude) ?? -1) + 1
        let cursor = m.cursorRows.map { e -> NSView & SettingsGroupRow in
            UsageCursorEnableRow(environmentId: e.id, label: e.label, showEnvironment: m.cursorShowsEnvironment) { [weak owner] id in owner?.onEnableCursor?(id) }
        }
        providerRows.insert(contentsOf: cursor, at: min(insertAt, providerRows.count))
        rows = providerRows
        rows.forEach(addSubview)
        var cm = UsageChartView.Model()
        cm.providers = m.activeProviders
        cm.loading = Set(m.activeProviders.filter { m.providerLoading($0) })
        cm.periods = m.window.isHourly
            ? (m.window.sinceTime.flatMap { s in m.window.untilTime.map { UsageFormat.enumerateHourStarts(s, $0) } } ?? [])
            : UsageFormat.enumerateDays(m.window.sinceDay, m.window.untilDay)
        cm.byPeriod = Dictionary((m.window.isHourly ? m.merged.hourly : m.merged.daily).map { ($0.periodKey, $0) }, uniquingKeysWith: { a, _ in a })
        cm.tokens = m.metric == "tokens"
        cm.hourly = m.window.isHourly
        cm.timeZone = m.window.timeZone
        cm.referenceTime = m.window.untilTime
        chart.model = cm
    }

    private var leftHeight: CGFloat { 44 + 16 + rows.reduce(0) { $0 + 20 + $1.height(forWidth: 288) } }
    private var rightHeight: CGFloat { 20 + 12 + UsageChartView.height }

    func height(forWidth width: CGFloat, viewport: CGFloat) -> CGFloat {
        viewport >= 1024 ? max(leftHeight, rightHeight) : leftHeight + 24 + rightHeight
    }

    override func layout() {
        super.layout()
        let two = (window?.frame.width ?? 1440) >= 1024
        let leftW = two ? min(288, bounds.width) : bounds.width
        big.frame = NSRect(x: 0, y: 0, width: leftW, height: 40)
        caption.frame = NSRect(x: 0, y: 44, width: ceil(caption.textWidth) + 1, height: 16)
        info?.frame = NSRect(x: caption.frame.maxX + 4, y: 46, width: 12, height: 12)
        var y: CGFloat = 60
        for r in rows {
            y += 20
            let h = r.height(forWidth: leftW)
            r.frame = NSRect(x: 0, y: y, width: leftW, height: h)
            y += h
        }
        let rx: CGFloat = two ? leftW + 24 : 0
        let ry: CGFloat = two ? 0 : y + 24
        let rw = bounds.width - rx
        chartTitle.frame = NSRect(x: rx, y: ry, width: rw, height: 20)
        chart.frame = NSRect(x: rx, y: ry + 32, width: rw, height: UsageChartView.height)
    }
}

/// One provider in the summary: dot, mark, label and sessions, the figure, and the share line.
final class UsageProviderSummaryRow: DSView, SettingsGroupRow {
    private let dot = DSView()
    private let mark: NSView
    private let name: LabelView
    private let sessions: LabelView
    private let value: LabelView
    private let share: LabelView
    private let provider: UsageProviderKind

    init(provider p: UsageProviderKind, model m: UsagePageView.Model) {
        provider = p
        let totals = m.merged.providers.first { $0.provider == p }
        let cost = m.metric == "cost"
        let loading = m.providerLoading(p)
        let awaiting = loading && !m.providersWithData.contains(p)
        let n = totals?.sessions ?? 0
        mark = UsageStyle.mark(p, size: 16)
        name = UsageStyle.label(p.label, 14)
        sessions = UsageStyle.label("\(UsageFormat.count(n)) \(n == 1 ? "session" : "sessions")", 11, color: Themed.color(\.mutedForeground), tabular: true)
        value = UsageStyle.label(awaiting ? "—" : cost ? UsageFormat.usd(totals?.costUsd ?? 0) : UsageFormat.tokens(totals?.totalTokens ?? 0), 14, .medium,
                                 tabular: true)
        value.alignment = .right
        let s = cost ? totals?.costShare ?? 0 : totals?.tokenShare ?? 0
        share = UsageStyle.label(cost ? "\(UsageFormat.percent(s)) of cost · \(UsageFormat.tokens(totals?.totalTokens ?? 0)) tokens"
                                     : "\(UsageFormat.percent(s)) of tokens · \(UsageFormat.usd(totals?.costUsd ?? 0))", 12, color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        dot.layer?.cornerRadius = 4
        for v in [dot, mark, name, sessions, value, share] as [NSView] { addSubview(v) }
        for v in [sessions, value, share] as [NSView] { v.alphaValue = loading ? 0.4 : 1 }
        sessions.isHidden = awaiting
        share.isHidden = awaiting
    }

    func height(forWidth width: CGFloat) -> CGFloat { 20 + 4 + 16 }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); dot.layer?.backgroundColor = UsageStyle.color(provider).cgColor(in: self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    override func layout() {
        super.layout()
        let vw = ceil(value.textWidth) + 1
        value.frame = NSRect(x: bounds.width - vw, y: 0, width: vw, height: 20)
        dot.frame = NSRect(x: 0, y: 6, width: 8, height: 8)
        mark.frame = NSRect(x: 16, y: 2, width: 16, height: 16)
        let avail = bounds.width - vw - 16 - 40
        let nw = min(ceil(name.textWidth) + 1, max(0, avail - ceil(sessions.textWidth) - 6))
        name.frame = NSRect(x: 40, y: 0, width: nw, height: 20)
        // `items-baseline`: the 11pt sessions share the 14pt label's baseline.
        sessions.frame = NSRect(x: name.frame.maxX + 6, y: 3, width: ceil(sessions.textWidth) + 1, height: 16)
        share.frame = NSRect(x: 0, y: 24, width: bounds.width, height: 16)
    }
}

/// `CursorEnableRow`: Cursor's dot and mark, the name (and environment), and an inline Enable with the Keychain tooltip.
final class UsageCursorEnableRow: DSView, SettingsGroupRow {
    private let dot = DSView()
    private let mark = UsageStyle.mark(.cursor, size: 16)
    private let name: LabelView
    private let enable = UsageInlineTextButton("Enable")

    init(environmentId: String, label: String, showEnvironment: Bool, onEnable: @escaping @MainActor (String) -> Void) {
        name = UsageStyle.label("Cursor" + (showEnvironment ? " · \(label)" : ""), 14)
        super.init(frame: .zero)
        dot.layer?.cornerRadius = 4
        for v in [dot, mark, name, enable] as [NSView] { addSubview(v) }
        enable.setAccessibilityLabel("Enable Cursor usage from \(label)")
        _ = TooltipController.attach(to: enable, text: UsageCursorPromptView.copy)
        enable.action = { [weak enable] in enable?.isEnabled = false; onEnable(environmentId) }
    }

    func height(forWidth width: CGFloat) -> CGFloat { 20 }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); dot.layer?.backgroundColor = UsageStyle.color(.cursor).cgColor(in: self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 0, y: 6, width: 8, height: 8)
        mark.frame = NSRect(x: 16, y: 2, width: 16, height: 16)
        let ew = enable.intrinsicContentSize.width
        enable.frame = NSRect(x: bounds.width - ew, y: 0, width: ew, height: 20)
        name.frame = NSRect(x: 40, y: 0, width: max(0, bounds.width - ew - 56), height: 20)
    }
}

/// `InlineButton` tone default as a plain text action.
final class UsageInlineTextButton: ControlView {
    private let label: LabelView
    init(_ title: String) {
        label = UsageStyle.label(title, 14, .medium)
        super.init(frame: .zero)
        scalesWhenPressed = false
        addSubview(label)
        setAccessibilityRole(.button)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 20) }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.isUnderlined = state.hoverOrPressed
        alphaValue = isEnabled ? 1 : 0.64
    }
    override func layout() { super.layout(); label.frame = bounds }
}

/// Totals: five figures, `grid-cols-2 md:grid-cols-5 gap-x-6 gap-y-4 py-1`, under an `h2`.
final class UsageTotalsView: DSView, UsageSectionSizing {
    private let title = UsageStyle.label("Totals", 14, .medium)
    private var metrics: [(LabelView, NSView)] = []

    init(model m: UsagePageView.Model) {
        super.init(frame: .zero)
        addSubview(title)
        let values = [("Processed tokens", UsageFormat.tokens(m.merged.totalTokens)), ("Cached input", UsageFormat.tokens(m.merged.cachedInputTokens)),
                      ("Uncached input", UsageFormat.tokens(m.merged.uncachedInputTokens)), ("Output", UsageFormat.tokens(m.merged.outputTokens)),
                      ("Cache savings", UsageFormat.usd(m.merged.cacheSavingsUsd))]
        metrics = values.map { k, v in
            let l = UsageStyle.label(k, 12, color: Themed.color(\.mutedForeground))
            let value = UsageStyle.label(v, 16, .medium, tabular: true, lineHeight: 24)
            value.alphaValue = m.partial ? 0.4 : 1
            addSubview(l)
            addSubview(value)
            return (l, value)
        }
    }

    /// Skeleton totals: the labels over 24pt pulse bars.
    init(skeleton: Bool) {
        super.init(frame: .zero)
        addSubview(title)
        metrics = ["Processed tokens", "Cached input", "Uncached input", "Output", "Cache savings"].map { k in
            let l = UsageStyle.label(k, 12, color: Themed.color(\.mutedForeground))
            let bar = SkeletonView()
            bar.frame.size = NSSize(width: 64, height: 24)
            addSubview(l)
            addSubview(bar)
            return (l, bar)
        }
    }

    private func columns(_ viewport: CGFloat) -> Int { viewport >= 768 ? 5 : 2 }

    func height(forWidth width: CGFloat, viewport: CGFloat) -> CGFloat {
        let rows = CGFloat((metrics.count + columns(viewport) - 1) / columns(viewport))
        return 20 + 8 + 4 + rows * 42 + (rows - 1) * 16 + 4
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        let cols = columns(window?.frame.width ?? 1440)
        let colW = (bounds.width - 24 * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, (l, v)) in metrics.enumerated() {
            let x = CGFloat(i % cols) * (colW + 24), y = 32 + CGFloat(i / cols) * (42 + 16)
            l.frame = NSRect(x: x, y: y, width: colW, height: 16)
            v.frame = NSRect(x: x, y: y + 18, width: v is SkeletonView ? 64 : colW, height: 24)
        }
    }
}

/// The share bars, `grid gap-x-12 gap-y-8 lg:grid-cols-2`.
final class UsageShareGridView: DSView, UsageSectionSizing {
    private let bars: [UsageShareBarView]
    init(_ bars: [UsageShareBarView], dimmed: Bool) {
        self.bars = bars
        super.init(frame: .zero)
        bars.forEach { addSubview($0); $0.alphaValue = dimmed ? 0.4 : 1 }
    }

    private func colW(_ width: CGFloat, _ viewport: CGFloat) -> CGFloat { viewport >= 1024 ? (width - 48) / 2 : width }

    func height(forWidth width: CGFloat, viewport: CGFloat) -> CGFloat {
        let cols = viewport >= 1024 ? 2 : 1
        let w = colW(width, viewport)
        var h: CGFloat = 0
        stride(from: 0, to: bars.count, by: cols).forEach { i in
            let rowH = bars[i..<min(bars.count, i + cols)].map { $0.height(forWidth: w) }.max() ?? 0
            h += rowH + (i > 0 ? 32 : 0)
        }
        return h
    }

    override func layout() {
        super.layout()
        let viewport = window?.frame.width ?? 1440
        let cols = viewport >= 1024 ? 2 : 1
        let w = colW(bounds.width, viewport)
        var y: CGFloat = 0
        stride(from: 0, to: bars.count, by: cols).forEach { i in
            let row = Array(bars[i..<min(bars.count, i + cols)])
            let rowH = row.map { $0.height(forWidth: w) }.max() ?? 0
            for (j, b) in row.enumerated() { b.frame = NSRect(x: CGFloat(j) * (w + 48), y: y, width: w, height: b.height(forWidth: w)) }
            y += rowH + 32
        }
    }
}

/// Breakdown: the heading with the Model / Day toggle, then the table.
final class UsageBreakdownSectionView: DSView, SettingsGroupRow {
    private let title = UsageStyle.label("Breakdown", 14, .medium)
    private let toggle: ToggleGroupView
    private let table: UsageBreakdownTableView

    init(toggle: ToggleGroupView, table: UsageBreakdownTableView) {
        self.toggle = toggle
        self.table = table
        super.init(frame: .zero)
        for v in [title, toggle, table] as [NSView] { addSubview(v) }
    }

    func height(forWidth width: CGFloat) -> CGFloat { toggle.intrinsicContentSize.height + 12 + table.height(forWidth: width) }

    override func layout() {
        super.layout()
        let s = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: bounds.width - s.width, y: 0, width: s.width, height: s.height)
        title.frame = NSRect(x: 0, y: (s.height - 20) / 2, width: 200, height: 20)
        table.frame = NSRect(x: 0, y: s.height + 12, width: bounds.width, height: table.height(forWidth: bounds.width))
    }
}

/// `UsageSkeleton`: the loaded page's shape in pulsing bars until the first environment answers.
final class UsageSkeletonView: DSView, UsageSectionSizing {
    private var blocks: [(SkeletonView, NSRect)] = []
    private let totals = UsageTotalsView(skeleton: true)
    private let breakdown = UsageStyle.label("Breakdown", 14, .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(totals)
        addSubview(breakdown)
    }

    private func block(_ rect: NSRect, _ shape: SkeletonView.Shape = .block) {
        let s = SkeletonView(shape: shape)
        addSubview(s)
        blocks.append((s, rect))
    }

    private var built = false
    private func build(_ width: CGFloat, two: Bool) {
        blocks.forEach { $0.0.removeFromSuperview() }
        blocks = []
        block(NSRect(x: 0, y: 0, width: 144, height: 40))
        block(NSRect(x: 0, y: 44, width: 128, height: 16))
        var y: CGFloat = 80
        let leftW = two ? 288 : width
        for _ in UsageProviderKind.allCases {
            block(NSRect(x: 0, y: y + 6, width: 8, height: 8), .pill)
            block(NSRect(x: 16, y: y + 2, width: 16, height: 16), .pill)
            block(NSRect(x: 40, y: y + 3, width: 80, height: 14))
            block(NSRect(x: leftW - 56, y: y + 3, width: 56, height: 14))
            block(NSRect(x: 0, y: y + 24, width: 144, height: 16))
            y += 40 + 20
        }
        let rx: CGFloat = two ? 312 : 0, ry: CGFloat = two ? 0 : y + 4
        block(NSRect(x: rx, y: ry, width: 96, height: 20))
        block(NSRect(x: rx + 64, y: ry + 32, width: width - rx - 64, height: 224))
        block(NSRect(x: rx + 64, y: ry + 260, width: width - rx - 64, height: 16))
    }

    private func topHeight(_ two: Bool) -> CGFloat { two ? max(80 + 6 * 60 - 20, 32 + 244) : 80 + 6 * 60 + 4 + 276 }

    func height(forWidth width: CGFloat, viewport: CGFloat) -> CGFloat {
        let two = viewport >= 1024
        return topHeight(two) + 24 + totals.height(forWidth: width, viewport: viewport) + 24 + 70 + 24 + 28 + 12 + 176
    }

    override func layout() {
        super.layout()
        let viewport = window?.frame.width ?? 1440
        let two = viewport >= 1024
        build(bounds.width, two: two)
        var y = topHeight(two) + 24
        let th = totals.height(forWidth: bounds.width, viewport: viewport)
        totals.frame = NSRect(x: 0, y: y, width: bounds.width, height: th)
        y += th + 24
        block(NSRect(x: 0, y: y, width: 112, height: 20))
        block(NSRect(x: 0, y: y + 30, width: two ? (bounds.width - 48) / 2 : bounds.width, height: 8))
        block(NSRect(x: 0, y: y + 48, width: 288, height: 16))
        y += 70 + 24
        breakdown.frame = NSRect(x: 0, y: y + 4, width: 200, height: 20)
        block(NSRect(x: bounds.width - 112, y: y, width: 112, height: 28), .card)
        block(NSRect(x: 0, y: y + 40, width: bounds.width, height: 176))
        for (s, r) in blocks { s.frame = r }
    }
}
