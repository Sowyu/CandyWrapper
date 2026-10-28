import AppKit
import DesignSystem
import T3Protocol

/// The tones and glyphs every pull request surface shares (pullRequestIcons.tsx,
/// pullRequestPresentation.tsx), so one pull request reads the same in a row, a tab and a header.
@MainActor
public enum PullRequestStyle {
    /// `PULL_REQUEST_STATE_PRESENTATION` tones.
    public static func color(_ tone: PullRequestStateTone) -> NSColor {
        switch tone {
        case .open: Themed.base("emerald-600", 1, dark: "emerald-300", 0.9)
        case .draft: Themed.base("zinc-500", 1, dark: "zinc-400", 0.8)
        case .closed: Themed.base("red-600", 1, dark: "red-300", 0.9)
        case .merged: Themed.base("violet-600", 1, dark: "violet-300", 0.9)
        }
    }

    public static func icon(_ tone: PullRequestStateTone) -> IconName {
        switch tone {
        case .open: .gitPullRequestArrow
        case .draft: .gitPullRequestDraft
        case .closed: .gitPullRequestClosed
        case .merged: .gitMerge
        }
    }

    /// `CHECK_STATUS_PRESENTATION`: pending is a spinner, drawn by `CheckStatusGlyph`.
    public static func checkStatus(_ status: String) -> (icon: IconName, color: NSColor) {
        switch status {
        case "action-required": (.circleDot, Themed.base("amber-600", 1, dark: "amber-400", 0.9))
        case "success": (.circleCheck, color(.open))
        case "failure", "cancelled": (.circleX, Themed.color(\.destructive))
        case "pending": (.loaderCircle, Themed.base("amber-500"))
        case "skipped": (.circleSlash, Themed.color(\.mutedForeground, 0.7))
        default: (.circleDashed, Themed.color(\.mutedForeground, 0.7))
        }
    }

    /// `CHECKS_STATE_PRESENTATION`: the rollup glyph a row wears.
    public static func checksState(_ state: String) -> (icon: IconName, color: NSColor) {
        switch state {
        case "passing": (.circleCheck, color(.open))
        case "failing": (.circleX, Themed.color(\.destructive))
        default: (.circleDot, Themed.base("amber-600", 1, dark: "amber-400", 0.9))
        }
    }

    /// `reviewDecisionPresentation`.
    public static func reviewDecision(_ decision: String) -> (icon: IconName, color: NSColor, label: String)? {
        switch decision {
        case "approved": (.userCheck, color(.open), "Approved")
        case "changes-requested": (.userRoundX, Themed.base("amber-600", 0.9, dark: "amber-400", 0.8), "Changes requested")
        case "review-required": (.userRound, Themed.color(\.mutedForeground, 0.6), "Awaiting review")
        default: nil
        }
    }

    /// `REVIEW_OUTCOME_PRESENTATION` ring colors (fresh, stale).
    public static func outcomeRing(_ outcome: String, stale: Bool) -> NSColor {
        switch outcome {
        case "approved": stale ? Themed.base("emerald-500", 0.35, dark: "emerald-400", 0.35) : Themed.base("emerald-500", 1, dark: "emerald-400", 1)
        case "changes-requested": Themed.color(\.destructive, stale ? 0.35 : 1)
        default: Themed.color(\.mutedForeground, stale ? 0.3 : 0.6)
        }
    }

    /// `text-diff-addition-foreground`, `text-diff-deletion`.
    public static let addition = Themed.color(\.diffAdditionForeground)
    public static let deletion = Themed.color(\.diffDeletion)

    /// The lucide glyph for an option's icon name.
    public static func optionIcon(_ name: String) -> IconName {
        switch name {
        case "layers": .layers
        case "eye": .eye
        case "pen-line": .penLine
        case "git-pull-request-arrow": .gitPullRequestArrow
        case "git-pull-request-closed": .gitPullRequestClosed
        case "git-pull-request-draft": .gitPullRequestDraft
        case "git-merge": .gitMerge
        case "list-checks": .listChecks
        case "user-lock": .userLock
        case "clock": .clock
        case "calendar-arrow-down": .calendarArrowDown
        case "calendar-arrow-up": .calendarArrowUp
        case "maximize-2": .maximize2
        case "minimize-2": .minimize2
        case "eye-off": .eyeOff
        case "circle-check": .circleCheck
        case "circle-x": .circleX
        case "circle-dashed": .circleDashed
        case "circle-slash": .circleSlash
        default: .layers
        }
    }

    /// `getSourceControlPresentationForKind(kind).Icon`.
    public static func providerIcon(_ kind: String) -> IconName {
        switch kind {
        case "github": IconName(rawValue: "brandGitHub") ?? .gitBranch
        case "gitlab": IconName(rawValue: "brandGitLab") ?? .gitBranch
        case "forgejo": .brandForgejo
        default: .gitBranch
        }
    }

    /// `#rrggbb` to a color.
    public static func hex(_ hex: String) -> NSColor? {
        guard let v = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// `PullRequestActorAvatar`: the host's avatar image, or the login's initial on `bg-muted`
/// (`text-3xs font-medium text-muted-foreground`).
// ponytail: avatars load once per URL into a process cache with no eviction; bound it when long sessions show memory growth
public final class PullRequestAvatarView: DSView {
    private let initial = LabelView()
    private let image = CALayer()
    private let reviewRing = BoxDecorationLayer()
    private var loadedURL: String?
    @MainActor static var cache: [String: CGImage] = [:]
    /// A ring around the avatar (a reviewer's verdict), drawn 2px outside.
    public var ring: NSColor? { didSet { needsDisplay = true } }

    /// #25829: a shape keeps verdicts legible over a colored bot avatar.
    public var reviewOutcome: String? { didSet { updateVerdict() } }
    public var staleReview = false { didSet { needsDisplay = true } }
    private var verdict: IconView?

    private func updateVerdict() {
        verdict?.removeFromSuperview()
        verdict = nil
        guard let reviewOutcome else { return }
        let icon: IconName = reviewOutcome == "approved" ? .circleCheck : reviewOutcome == "changes-requested" ? .circleX : .circleDashed
        let mark = IconView(name: icon, size: 12, strokeColor: Themed.color(\.background))
        mark.strokeWidth = 3
        mark.layer?.zPosition = 1
        verdict = mark
        addSubview(mark)
        needsLayout = true
        needsDisplay = true
    }

    public var actor: PullRequestActor? {
        didSet {
            initial.text = String((actor?.login ?? "ghost").prefix(1)).uppercased()
            load(actor?.avatarUrl)
            needsLayout = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        reviewRing.host = self
        reviewRing.outset = 4
        layer?.addSublayer(reviewRing)
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        layer?.addSublayer(image)
        layer?.masksToBounds = false
        initial.alignment = .center
        addSubview(initial)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func load(_ url: String?) {
        guard url != loadedURL else { return }
        loadedURL = url
        image.contents = url.flatMap { Self.cache[$0] }
        initial.isHidden = image.contents != nil
        guard let url, image.contents == nil, let u = URL(string: url), u.scheme == "https" else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: u),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return }
            Self.cache[url] = cg
            guard let self, self.loadedURL == url else { return }
            self.image.contents = cg
            self.initial.isHidden = true
        }
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        reviewRing.frame = bounds
        reviewRing.layout(boxSize: bounds.size)
        image.frame = bounds
        image.cornerRadius = bounds.width / 2
        CATransaction.commit()
        let size = max(8, (bounds.width * 0.625).rounded())
        initial.font = DSFont.ui(min(10, size), weight: .medium)
        initial.lineHeight = bounds.height
        initial.frame = bounds
        // Bottom/right -4px in CSS; this view is flipped.
        verdict?.frame = NSRect(x: bounds.width - 8, y: bounds.height - 8, width: 12, height: 12)
    }

    public override func updateLayer() {
        // The review ring and verdict extend beyond the face, like T3's relative wrapper.
        // AppKit otherwise restores clipping when it attaches the view to a window.
        let classic = DesignGeometry.usesClassic(self)
        clipsToBounds = classic
        layer?.masksToBounds = classic
        reviewRing.isHidden = classic || ring == nil
        layer?.cornerRadius = bounds.width / 2
        layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        initial.color = Themed.color(\.mutedForeground)
        verdict?.isHidden = DesignGeometry.usesClassic(self)
        verdict?.strokeColor = Themed.color(\.background)
        verdict?.fillColor = reviewOutcome == "approved" ? Themed.base("emerald-500", 1, dark: "emerald-400", 1)
            : reviewOutcome == "changes-requested" ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        verdict?.alphaValue = staleReview ? 0.5 : 1
        if let ring {
            layer?.borderWidth = 0
            layer?.shadowOpacity = 0
            layer?.borderColor = nil
            ringLayer.isHidden = false
            let stroke = !classic && staleReview ? reviewOutcome.flatMap { Self.staleRings[$0] } ?? ring : ring
            ringLayer.strokeColor = stroke.cgColor(in: self)
            ringLayer.isHidden = !classic
            if !classic {
                var box = BoxStyle()
                box.radius = bounds.width / 2
                box.shadows = [BoxShadow(blur: 0, spread: 2, color: stroke)]
                reviewRing.boxStyle = box
                reviewRing.setNeedsDisplay()
            }
            ringLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: -1, dy: -1), transform: nil)
        } else {
            ringLayer.isHidden = true
        }
    }

    /// CSS mixes the extended sRGB channels before gamut clipping, including emerald's negative red.
    private static let staleRings: [String: NSColor] = Dictionary(uniqueKeysWithValues: ["approved", "changes-requested", "dismissed"].map { outcome in
        (outcome, NSColor(name: nil) { appearance in
            let dark = appearance.isDark
            let palette = ThemeRuntime.palettes.palette(dark: dark, sidebar: false)
            let tone = outcome == "approved" ? Tokens.baseColors[dark ? "emerald-400" : "emerald-500"]!
                : outcome == "changes-requested" ? palette.destructive : palette.mutedForeground
            let amount = outcome == "dismissed" ? 0.3 : 0.35
            let rgb = tone.srgb * amount + palette.background.srgb * (1 - amount)
            return NSColor(srgbRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
        })
    })

    private lazy var ringLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = nil
        l.lineWidth = 2
        l.actions = ["path": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(l)
        return l
    }()
}

/// `PullRequestDiffStat`: `+a -d`, nothing when both are zero.
public final class PullRequestDiffStatView: DSView {
    private let plus = LabelView()
    private let minus = LabelView()
    public var font: NSFont = DSFont.mono(11) { didSet { plus.font = font; minus.font = font; needsLayout = true } }
    public var lineHeight: CGFloat = 16 { didSet { plus.lineHeight = lineHeight; minus.lineHeight = lineHeight } }
    public var additions = 0 { didSet { update() } }
    public var deletions = 0 { didSet { update() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [plus, minus] { l.font = font; l.lineHeight = lineHeight; addSubview(l) }
        update()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func update() {
        let f = NumberFormatter(); f.numberStyle = .decimal
        plus.text = "+" + (f.string(from: NSNumber(value: additions)) ?? "\(additions)")
        minus.text = "-" + (f.string(from: NSNumber(value: deletions)) ?? "\(deletions)")
        isHidden = additions == 0 && deletions == 0
        needsLayout = true
    }

    public var width: CGFloat { isHidden ? 0 : ceil(plus.textWidth) + 4 + ceil(minus.textWidth) }

    public override func layout() {
        super.layout()
        let pw = ceil(plus.textWidth)
        plus.frame = NSRect(x: 0, y: 0, width: pw + 1, height: bounds.height)
        minus.frame = NSRect(x: pw + 4, y: 0, width: ceil(minus.textWidth) + 1, height: bounds.height)
    }

    public override func updateLayer() {
        plus.color = PullRequestStyle.addition
        minus.color = PullRequestStyle.deletion
    }
}

/// `PullRequestRowGlyph`: the lifecycle glyph with the conflict warning on its corner
/// (`absolute -right-1 -bottom-1`, `size-3 fill-background`).
public final class PullRequestStateGlyphView: DSView {
    private var icon: IconView?
    private var conflict: IconView?
    public var size: CGFloat = 16

    public func set(state: String, isDraft: Bool, mergeability: String?, baseBranch: String? = nil) {
        let tone = PullRequestStateTone(state: state, isDraft: isDraft)
        icon?.removeFromSuperview()
        let v = IconView(name: PullRequestStyle.icon(tone), size: size, strokeColor: PullRequestStyle.color(tone))
        addSubview(v)
        icon = v
        conflict?.removeFromSuperview()
        conflict = nil
        let conflicting = state == "open" && !isDraft && mergeability == "conflicting"
        if conflicting {
            let c = IconView(name: .triangleAlert, size: 12, strokeColor: Themed.color(\.destructive), fillColor: Themed.color(\.background))
            addSubview(c)
            conflict = c
            toolTip = baseBranch.map { "Conflicts with \($0)" } ?? "Has conflicts"
        } else {
            toolTip = tone.label
        }
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }

    /// A linked pull request the host has not been read for: the PR glyph in `text-muted-foreground`.
    public func setWaiting() {
        icon?.removeFromSuperview()
        conflict?.removeFromSuperview()
        conflict = nil
        let v = IconView(name: .gitPullRequestArrow, size: size, strokeColor: Themed.color(\.mutedForeground))
        addSubview(v)
        icon = v
        toolTip = "Waiting for host state"
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        icon?.frame = NSRect(x: 0, y: 0, width: size, height: size)
        conflict?.frame = NSRect(x: size + 4 - 12, y: size + 4 - 12, width: 12, height: 12)
    }
}

/// `PullRequestLabelChip`: a `label` badge in the host's color, the muted tag without one, plus an
/// optional overflow count.
@MainActor
public enum PullRequestLabelChip {
    public static func make(_ label: PullRequestLabel, size: BadgeView.Size = .sm, overflow: Int = 0) -> BadgeView {
        let title = overflow > 0 ? "\(label.name) +\(overflow)" : label.name
        let color = PullRequestListLogic.labelColor(label.color).flatMap(PullRequestStyle.hex)
        let badge = BadgeView(title, variant: color == nil ? .secondary : .label, size: size)
        if let color { badge.labelColor = color }
        return badge
    }
}

/// The checks glyph and the review verdict after a row's title (`size-3.5`).
public final class CheckStatusGlyph: DSView {
    private var view: NSView?

    public func set(icon: IconName, color: NSColor, spinning: Bool = false, size: CGFloat = 14) {
        view?.removeFromSuperview()
        if spinning {
            let s = SpinnerView(size: .sm)
            s.color = color
            view = s
        } else {
            view = IconView(name: icon, size: size, strokeColor: color)
        }
        addSubview(view!)
        needsLayout = true
    }

    public override func layout() { super.layout(); view?.frame = bounds }

    /// Set, the glyph is a button (`role="button"`, the checks popover's trigger); the click does not
    /// reach the row under it.
    public var onClick: ((CheckStatusGlyph) -> Void)? { didSet { setAccessibilityRole(onClick == nil ? nil : .button); window?.invalidateCursorRects(for: self) } }
    public override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }
    public override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }
    public override func mouseUp(with event: NSEvent) {
        guard let onClick else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(self) }
    }
    public override func accessibilityPerformPress() -> Bool { onClick?(self); return onClick != nil }
}

/// `PullRequestChangeBreakdownStat`'s tooltip (3473 PullRequestChangeBreakdownStat.tsx:60-131, 92a6f6d731,
/// 962428df10): a `grid-cols-[auto_auto_auto] gap-x-4 gap-y-1 py-0.5 font-mono tabular-nums` of each kind
/// with lines, its name in `font-sans`, then a `border-t` rule and the Total, on the tooltip surface.
public final class PullRequestChangeBreakdownTooltipView: DSView, PopupContent {
    private let surface = TooltipView("")
    private var cells: [[LabelView]] = []
    /// A view of its own so it stays above the surface's layers.
    private let rule = NSView()
    public var frostRadius: CGFloat { 8 }

    public init(_ breakdown: PullRequestChangeBreakdown, additions: Int, deletions: Int) {
        super.init(frame: .zero)
        addSubview(surface)
        let f = NumberFormatter(); f.numberStyle = .decimal
        let count = { (n: Int) in f.string(from: NSNumber(value: n)) ?? "\(n)" }
        let rows = breakdown.rows.map { ($0.label, $0.count.additions, $0.count.deletions) } + [("Total", additions, deletions)]
        cells = rows.map { label, a, d in
            let name = LabelView(label, font: DSFont.ui(12))
            let plus = LabelView("+" + count(a), font: DSFont.mono(12))
            let minus = LabelView("-" + count(d), font: DSFont.mono(12))
            plus.alignment = .right
            minus.alignment = .right
            for l in [name, plus, minus] { l.lineHeight = 16.5; addSubview(l) }
            return [name, plus, minus]
        }
        rule.wantsLayer = true
        addSubview(rule)
    }

    private var columns: [CGFloat] {
        (0..<3).map { i in cells.map { ceil($0[i].textWidth) + 1 }.max() ?? 0 }
    }

    /// Rows of 16.5pt with `gap-y-1`, and the 1pt rule as a row of its own before the Total.
    public var popupSize: CGSize {
        let c = columns
        let rowsHeight = CGFloat(cells.count) * 16.5 + 1 + CGFloat(cells.count) * 4
        return CGSize(width: c.reduce(0, +) + 32 + 18, height: rowsHeight + 4 + 10)
    }

    public override var intrinsicContentSize: NSSize { popupSize }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        let c = columns
        var y: CGFloat = 5 + 2
        for (i, row) in cells.enumerated() {
            if i == cells.count - 1 {
                rule.frame = CGRect(x: 9, y: y, width: c.reduce(0, +) + 32, height: 1)
                y += 1 + 4
            }
            var x: CGFloat = 9
            for (j, l) in row.enumerated() {
                l.frame = NSRect(x: x, y: y, width: c[j], height: 16.5)
                x += c[j] + 16
            }
            y += 16.5 + 4
        }
    }

    public override func updateLayer() {
        rule.layer?.backgroundColor = Themed.color(\.border).cgColor(in: self)
        for row in cells {
            row[0].color = Themed.color(\.contrastPopoverForeground)
            row[1].color = PullRequestStyle.addition
            row[2].color = PullRequestStyle.deletion
        }
    }
}

/// What the stat's hover shows: nothing before the first read or after a failed one, "Loading
/// breakdown" while it's on its way, then the split.
public enum PullRequestChangeBreakdownState: Equatable, Sendable {
    case none
    case loading
    case loaded(PullRequestChangeBreakdown)
}
