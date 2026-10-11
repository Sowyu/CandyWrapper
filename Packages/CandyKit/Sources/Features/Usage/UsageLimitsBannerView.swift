import AppKit
import DesignSystem
import T3Protocol

/// The `/usage-limits` result above the composer (ComposerUsageLimits.tsx `usageLimitsBannerItem`): a gauge,
/// "Usage limits" and the account (or "N accounts"), a dismiss button, then per account its compact window
/// rows or notice, Manage usage, and banked reset credits. Answered from the last Limits snapshot.
public final class UsageLimitsBannerView: ComposerBannerView {
    private let icon = IconView(name: .gauge, size: 12)
    private let title: LabelView
    private let detail: LabelView
    public let dismiss = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private var blocks: [(view: NSView, height: CGFloat, gap: CGFloat)] = []
    public private(set) var resetViews: [(account: UsageLimitsReport.Account, view: UsageResetCreditsView)] = []
    public var onOpenURL: ((String) -> Void)?
    public let report: UsageLimitsReport

    public init(report: UsageLimitsReport) {
        self.report = report
        title = glassLabel("Usage limits", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground), lineHeight: 24)
        let summary: String = report.accounts.count == 1 ? Self.accountSummary(report.accounts[0]) : "\(report.accounts.count) accounts"
        detail = glassLabel(summary, font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 24)
        super.init(variant: .neutral)
        icon.strokeColor = Themed.color(\.mutedForeground)
        dismiss.setAccessibilityLabel("Dismiss usage limits")
        dismiss.iconSize = 14
        for v in [icon, title, detail, dismiss] as [NSView] { addSubview(v) }
        let nowMs = T3Timestamp.parseEpochMs(report.createdAt) ?? 0
        for a in report.accounts {
            if report.accounts.count > 1 {
                add(glassLabel(Self.accountSummary(a), font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16), 16, gap: blocks.isEmpty ? 0 : 8)
            }
            if let notice = UsageLimitsLogic.notice(a.limits) {
                add(glassLabel(notice, font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16), 16, gap: report.accounts.count > 1 ? 4 : (blocks.isEmpty ? 0 : 8))
            } else {
                let w = UsageLimitWindowsView(driver: a.driver, windows: a.limits.windows, nowMs: nowMs, compact: true)
                add(w, w.height(forWidth: 0), gap: report.accounts.count > 1 ? 4 : (blocks.isEmpty ? 0 : 8))
            }
            if let external = a.limits.externalUsage {
                let b = ButtonView("Manage usage", variant: .link, size: .sm)
                b.action = { [weak self] in self?.onOpenURL?(external.url) }
                add(UsageLeadingButton(b), 32, gap: 4)
            }
            if let credits = a.limits.resetCredits, a.resetCreditTarget ?? a.instanceId.map({ .instance($0) }) != nil,
               credits.availableCount > 0 {
                let r = UsageResetCreditsView(credits: credits, nowMs: nowMs)
                resetViews.append((a, r))
                add(r, 24, gap: 4)
            }
        }
        for n in report.notices { add(glassLabel(n, font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16), 16, gap: 8) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Usage limits")
    }

    /// `AccountSummary`: the account label then the plan; labels with an email stay masked.
    static func accountSummary(_ a: UsageLimitsReport.Account) -> String {
        let label = UsageLimitsLogic.reportAccountLabel(a, driverLabel: UsageProviderLabels.driverLabel(a.driver))
        let shown = label.contains("@") ? UsageRedactedTextView.placeholder(label) : label
        return shown + (a.plan.map { " · \($0)" } ?? "")
    }

    private func add(_ v: NSView, _ h: CGFloat, gap: CGFloat) {
        addSubview(v)
        blocks.append((v, h, gap))
    }

    /// `py-1.25` around the 24pt header row, the body's `pt-1 pb-1.5`, capped like `max-h-[min(24rem,40dvh)]`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        let body = blocks.reduce(0) { $0 + $1.gap + $1.height }
        return 5 + 24 + (blocks.isEmpty ? 0 : 1 + 4 + min(384, body) + 6) + 5 + ComposerBannerView.overlap
    }

    public override func layout() {
        super.layout()
        let rowY: CGFloat = 5
        icon.frame = NSRect(x: 4 + 6, y: rowY + 6, width: 12, height: 12)
        dismiss.frame = NSRect(x: bounds.width - 4 - 24, y: rowY, width: 24, height: 24)
        let tx: CGFloat = 4 + 24 + 4
        let tw = ceil(title.textWidth) + 1
        title.frame = NSRect(x: tx, y: rowY, width: tw, height: 24)
        detail.frame = NSRect(x: tx + tw + 4, y: rowY, width: max(0, dismiss.frame.minX - 4 - tx - tw - 4), height: 24)
        // `Body ps-7 pe-2` inside the `px-1` root.
        let bx: CGFloat = 4 + 28, bw = max(0, bounds.width - 4 - 28 - 8 - 4)
        var y = rowY + 24 + 1 + 4
        for b in blocks {
            y += b.gap
            b.view.frame = NSRect(x: bx, y: y, width: bw, height: b.height)
            y += b.height
        }
    }
}

/// A button kept at its own width at the start of a row (`self-start`).
final class UsageLeadingButton: DSView {
    let button: ButtonView
    init(_ button: ButtonView) {
        self.button = button
        super.init(frame: .zero)
        addSubview(button)
    }
    override func layout() {
        super.layout()
        let s = button.intrinsicContentSize
        button.frame = NSRect(x: 0, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }
}
