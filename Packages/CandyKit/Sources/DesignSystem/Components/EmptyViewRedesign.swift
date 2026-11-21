import AppKit

/// What a state says under Redesign: an icon, one title line, an optional plain sentence, and the raw error text for a
/// bug report, which shows only behind Details and in the tooltip.
public struct StateCopy: Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var icon: IconName?
    public var details: String?

    public init(title: String, detail: String? = nil, icon: IconName? = nil, details: String? = nil) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.details = details
    }
}

extension StateCopy {
    /// `VcsProcessSpawnError`, `ECONNRESET`, `rpc_unavailable`: one word, no spaces, the shape of a type or a code,
    /// which never shows as a message.
    public static func isTypeName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return false }
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == ":" || $0 == "-" }
    }

    /// For a failure nobody explained.
    public static let unexplained = "The server returned an error without a reason. Retry, or open Details to report it."
}

/// The one action a state offers, such as Retry or Open settings.
public struct StateAction {
    public var title: String
    public var icon: IconName?
    public var handler: @MainActor () -> Void

    public init(_ title: String, icon: IconName? = nil, handler: @escaping @MainActor () -> Void) {
        self.title = title
        self.icon = icon
        self.handler = handler
    }
}

/// Redesign's state view metrics, in `RedesignTokens` steps.
struct RedesignStateMetrics {
    let padding: CGFloat, box: CGFloat, icon: CGFloat, mediaGap: CGFloat
    let title: CGFloat, titleLine: CGFloat, body: CGFloat, bodyLine: CGFloat, actionGap: CGFloat, maxText: CGFloat
    let button: ButtonView.Size

    static func of(_ size: EmptyView.Size) -> RedesignStateMetrics {
        typealias S = RedesignTokens.Space
        switch size {
        case .default, .hero:
            return .init(padding: S.xl, box: 40, icon: 20, mediaGap: S.m, title: 14, titleLine: 20, body: 13, bodyLine: 18,
                         actionGap: S.l, maxText: 320, button: .sm)
        case .compact:
            return .init(padding: S.l, box: 32, icon: 16, mediaGap: S.m, title: 13, titleLine: 18, body: 12, bodyLine: 17,
                         actionGap: S.m, maxText: 280, button: .xs)
        case .inline:
            return .init(padding: S.s, box: 0, icon: 14, mediaGap: S.s, title: 13, titleLine: 18, body: 12, bodyLine: 18,
                         actionGap: S.s, maxText: .greatestFiniteMagnitude, button: .xs)
        }
    }
}

/// The views only Redesign's state view uses.
@MainActor final class RedesignParts {
    let box = BoxDecorationLayer()
    var icon: IconView?
    var iconName: IconName?
    var button: ButtonView?
    let detailsButton = ButtonView("Details", icon: .chevronDown, variant: .ghostMuted, size: .xs)
    let detailsLabel = TextBlockView()
    var detailsOpen = false

    init(in view: EmptyView) {
        box.host = view
        view.layer?.insertSublayer(box, at: 0)
        detailsButton.isHidden = true
        detailsLabel.isHidden = true
        detailsLabel.maxLines = 8
        view.addSubview(detailsButton)
        view.addSubview(detailsLabel)
        detailsButton.action = { [weak self, weak view] in
            guard let self, let view else { return }
            self.detailsOpen.toggle()
            self.detailsButton.setAccessibilityExpanded(self.detailsOpen)
            view.invalidateIntrinsicContentSize()
            view.restyle()
        }
    }

    func setAction(_ action: StateAction?, in view: EmptyView) {
        button?.removeFromSuperview()
        button = nil
        guard let action else { return }
        let b = ButtonView(action.title, icon: action.icon, variant: .outline, size: RedesignStateMetrics.of(view.size).button)
        b.action = action.handler
        view.addSubview(b)
        button = b
    }

    func setIcon(_ name: IconName?, size: CGFloat, in view: EmptyView) {
        guard name != iconName || icon?.frame.width != size else { return }
        icon?.removeFromSuperview()
        icon = name.map { IconView(name: $0, size: size) }
        iconName = name
        icon.map(view.addSubview)
    }

    func hide() {
        box.isHidden = true
        icon?.isHidden = true
        button?.isHidden = true
        detailsButton.isHidden = true
        detailsLabel.isHidden = true
    }
}

extension EmptyView {
    private var parts: RedesignParts {
        if let redesignParts { return redesignParts }
        let p = RedesignParts(in: self)
        p.setAction(action, in: self)
        redesignParts = p
        return p
    }

    private var redesignMetrics: RedesignStateMetrics { RedesignStateMetrics.of(size) }
    private var rawDetails: String? { isRedesign ? redesign?.details.flatMap { $0.isEmpty ? nil : $0 } : nil }
    private var iconName: IconName? { (isRedesign ? redesign?.icon : nil) ?? media?.icon }

    func restyleParts() {
        let m = redesignMetrics, p = parts
        media?.isHidden = true
        p.setIcon(illustration == nil ? iconName : nil, size: m.icon, in: self)
        titleLabel.font = DSFont.ui(m.title, weight: .medium)
        titleLabel.lineHeight = m.titleLine
        titleLabel.color = Themed.color(\.foreground)
        titleLabel.maxLines = size == .inline ? 1 : 0
        descriptionLabel.font = DSFont.ui(m.body)
        descriptionLabel.lineHeight = m.bodyLine
        descriptionLabel.color = Themed.color(\.mutedForeground)
        descriptionLabel.maxLines = size == .inline ? 1 : 0
        descriptionLabel.isHidden = false
        let inline = size == .inline
        titleLabel.alignment = inline ? .left : .center
        descriptionLabel.alignment = inline ? .left : .center
        p.icon?.isHidden = false
        p.icon?.strokeColor = Themed.color(\.mutedForeground)
        p.box.isHidden = inline || p.icon == nil
        var style = BoxStyle()
        style.radius = RedesignTokens.Radius.card
        style.fill = RedesignTokens.Card.fill
        style.border = RedesignTokens.Card.border
        p.box.boxStyle = style
        p.box.setNeedsDisplay()
        p.button?.isHidden = false
        let raw = rawDetails
        p.detailsButton.isHidden = raw == nil || inline
        p.detailsLabel.isHidden = raw == nil || !p.detailsOpen || inline
        p.detailsLabel.text = raw ?? ""
        p.detailsLabel.font = DSFont.mono(11)
        p.detailsLabel.lineHeight = 16
        p.detailsLabel.color = Themed.color(\.mutedForeground)
        p.detailsLabel.alignment = .center
        p.detailsButton.title = p.detailsOpen ? "Hide details" : "Details"
        needsLayout = true
    }

    private func textWidth(forWidth width: CGFloat) -> CGFloat {
        let m = redesignMetrics
        return width > 0 ? max(0, min(m.maxText, width - 2 * m.padding)) : m.maxText
    }

    private var showsDetailsLabel: Bool { !(redesignParts?.detailsLabel.isHidden ?? true) }

    private func stack(forWidth width: CGFloat) -> CGFloat {
        let m = redesignMetrics, w = textWidth(forWidth: width), p = parts
        var h: CGFloat = p.icon == nil ? 0 : m.box + m.mediaGap
        if let illustration { h += illustration.intrinsicContentSize.height + m.mediaGap }
        h += titleLabel.height(forWidth: w)
        if hasMessage { h += RedesignTokens.Space.xs + descriptionLabel.height(forWidth: w) }
        let buttons = [p.button, p.detailsButton].compactMap { $0 }.filter { !$0.isHidden }
        if !buttons.isEmpty { h += m.actionGap + buttons.map(\.intrinsicContentSize.height).max()! }
        if let content { h += m.actionGap + content.intrinsicContentSize.height }
        if showsDetailsLabel { h += RedesignTokens.Space.s + p.detailsLabel.height(forWidth: w) }
        return h
    }

    func partsHeight(forWidth width: CGFloat) -> CGFloat {
        let m = redesignMetrics
        if size == .inline { return max(RedesignTokens.Space.xxl, m.titleLine + 2 * m.padding) }
        return max(minimumHeight ?? 0, stack(forWidth: width) + 2 * m.padding)
    }

    func layoutParts() {
        size == .inline ? layoutInlineRow() : layoutStack()
    }

    private func layoutStack() {
        let m = redesignMetrics, p = parts, width = bounds.width, w = textWidth(forWidth: width)
        let textX = ((width - w) / 2).rounded()
        var y = ((bounds.height - stack(forWidth: width)) / 2).rounded()
        if let icon = p.icon {
            let boxRect = CGRect(x: ((width - m.box) / 2).rounded(), y: y, width: m.box, height: m.box)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            p.box.layout(boxSize: boxRect.size)
            p.box.frame = p.box.frame.offsetBy(dx: boxRect.minX, dy: boxRect.minY)
            CATransaction.commit()
            icon.frame = boxRect.insetBy(dx: (m.box - m.icon) / 2, dy: (m.box - m.icon) / 2)
            y += m.box + m.mediaGap
        }
        if let illustration {
            let s = illustration.intrinsicContentSize
            illustration.frame = NSRect(x: ((width - s.width) / 2).rounded(), y: y, width: s.width, height: s.height)
            y += s.height + m.mediaGap
        }
        let th = titleLabel.height(forWidth: w)
        titleLabel.frame = NSRect(x: textX, y: y, width: w, height: th)
        y += th
        if hasMessage {
            let dh = descriptionLabel.height(forWidth: w)
            descriptionLabel.frame = NSRect(x: textX, y: y + RedesignTokens.Space.xs, width: w, height: dh)
            y += RedesignTokens.Space.xs + dh
        }
        let buttons = [p.button, p.detailsButton].compactMap { $0 }.filter { !$0.isHidden }
        if !buttons.isEmpty {
            y += m.actionGap
            let sizes = buttons.map(\.intrinsicContentSize)
            let gap = RedesignTokens.Space.s
            var x = ((width - sizes.map(\.width).reduce(0, +) - gap * CGFloat(buttons.count - 1)) / 2).rounded()
            for (b, s) in zip(buttons, sizes) {
                b.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
                x += s.width + gap
            }
            y += sizes.map(\.height).max()!
        }
        if let content {
            let s = content.intrinsicContentSize
            let cw = s.width == NSView.noIntrinsicMetric ? w : min(s.width, width)
            content.frame = NSRect(x: ((width - cw) / 2).rounded(), y: y + m.actionGap, width: cw, height: s.height)
            y += m.actionGap + s.height
        }
        if showsDetailsLabel {
            let h = p.detailsLabel.height(forWidth: w)
            p.detailsLabel.frame = NSRect(x: textX, y: y + RedesignTokens.Space.s, width: w, height: h)
        }
    }

    private func layoutInlineRow() {
        let m = redesignMetrics, p = parts, mid = bounds.height / 2
        var x = RedesignTokens.Space.m
        var right = bounds.width - RedesignTokens.Space.m
        if let b = p.button {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: right - s.width, y: (mid - s.height / 2).rounded(), width: s.width, height: s.height)
            right -= s.width + m.actionGap
        }
        if let icon = p.icon {
            icon.frame = NSRect(x: x, y: (mid - m.icon / 2).rounded(), width: m.icon, height: m.icon)
            x += m.icon + m.mediaGap
        }
        let avail = max(0, right - x)
        let tw = min(titleLabel.naturalWidth.rounded(.up), avail)
        titleLabel.frame = NSRect(x: x, y: (mid - m.titleLine / 2).rounded(), width: tw, height: m.titleLine)
        let dx = x + tw + RedesignTokens.Space.s - 2
        descriptionLabel.frame = NSRect(x: dx, y: (mid - m.bodyLine / 2).rounded(), width: max(0, right - dx), height: m.bodyLine)
        descriptionLabel.isHidden = !hasMessage || right - dx < 40
    }
}
