import CoreGraphics

/// The composer footer's narrow-width rules (apps/web/src/components/composerFooterLayout.ts).
public enum ComposerFooterLayout {
    /// `COMPOSER_FOOTER_COMPACT_BREAKPOINT_PX` and the wide-actions one (a question or plan follow-up).
    public static let compactBreakpoint: CGFloat = 620, wideActionsCompactBreakpoint: CGFloat = 780

    /// `shouldUseCompactComposerFooter`: compares the composer form's width.
    public static func isCompact(width: CGFloat, hasWideActions: Bool) -> Bool {
        width < (hasWideActions ? wideActionsCompactBreakpoint : compactBreakpoint)
    }

    /// `RestingComposerControlsMeasurement`: widths of the left cluster's parts. `blockWidths` are the
    /// trailing blocks (traits, then access), each its separator, `gap-1` and trigger.
    public struct Measurement: Equatable {
        public var gap: CGFloat
        public var naturalFixedWidth: CGFloat
        public var minimumFixedWidth: CGFloat
        public var blockWidths: [CGFloat]
        /// Nil when the blocks have no label to drop (no icon-only steps).
        public var iconOnlyBlockWidths: [CGFloat]?
        public var overflowWidth: CGFloat

        public init(gap: CGFloat, naturalFixedWidth: CGFloat, minimumFixedWidth: CGFloat, blockWidths: [CGFloat],
                    iconOnlyBlockWidths: [CGFloat]? = nil, overflowWidth: CGFloat) {
            self.gap = gap; self.naturalFixedWidth = naturalFixedWidth; self.minimumFixedWidth = minimumFixedWidth
            self.blockWidths = blockWidths; self.iconOnlyBlockWidths = iconOnlyBlockWidths; self.overflowWidth = overflowWidth
        }
    }

    /// How many trailing blocks show only their icon, how many moved into the overflow menu, and
    /// whether the cluster fits at all (the expanded footer ignores `visible` and lets the model shrink).
    public struct Fit: Equatable {
        public var hiddenCount = 0
        public var iconOnlyCount = 0
        public var visible = true
        public init(hiddenCount: Int = 0, iconOnlyCount: Int = 0, visible: Bool = true) {
            self.hiddenCount = hiddenCount; self.iconOnlyCount = iconOnlyCount; self.visible = visible
        }
    }

    /// `RESTING_CONTROLS_SLACK_PX`: promotions need a pixel of slack so the layout doesn't flicker.
    static let slack: CGFloat = 1

    static func width(_ m: Measurement, hidden: Int, fixed: CGFloat, iconOnly: Int) -> CGFloat {
        let n = m.blockWidths.count, visible = n - hidden
        var sum = fixed
        for i in 0..<visible {
            sum += i >= n - iconOnly ? (m.iconOnlyBlockWidths?[safe: i] ?? m.blockWidths[i]) : m.blockWidths[i]
        }
        return sum + (hidden > 0 ? m.overflowWidth : 0) + m.gap * CGFloat(visible + (hidden > 0 ? 1 : 0))
    }

    /// `resolveRestingComposerControlsLayout`: drop the last block's label, then the next one's, then
    /// move the last block into overflow, then the next. Demotions are immediate, promotions need slack.
    public static func resolve(_ m: Measurement, hostWidth: CGFloat, previous: Fit?) -> Fit {
        let n = m.blockWidths.count
        let iconSteps = m.iconOnlyBlockWidths == nil ? 0 : n
        let previousStep = previous.map { $0.hiddenCount > 0 ? iconSteps + min($0.hiddenCount, n) : min($0.iconOnlyCount, iconSteps) } ?? 0
        func at(_ step: Int, fixed: CGFloat? = nil) -> CGFloat {
            width(m, hidden: max(0, step - iconSteps), fixed: fixed ?? m.naturalFixedWidth, iconOnly: min(step, iconSteps))
        }
        var step = 0
        while step < iconSteps + n, at(step) > hostWidth - (step < previousStep ? slack : 0) { step += 1 }
        let minimum = at(step, fixed: m.minimumFixedWidth)
        let visible = previous.map { !$0.visible } == true ? minimum <= hostWidth - slack : minimum <= hostWidth
        return Fit(hiddenCount: max(0, step - iconSteps), iconOnlyCount: min(step, iconSteps), visible: visible)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
