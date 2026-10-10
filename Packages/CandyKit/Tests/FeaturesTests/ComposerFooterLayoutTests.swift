import CoreGraphics
import Testing
@testable import Features

/// Ports of apps/web/src/components/composerFooterLayout.test.ts:37-63 and :224-420.
struct ComposerFooterLayoutTests {
    // Picker 140 natural / 96 minimum plus a 9px separator, traits 60, mode 140, overflow 24, gap 4.
    let base = ComposerFooterLayout.Measurement(gap: 4, naturalFixedWidth: 149, minimumFixedWidth: 105,
                                                blockWidths: [60, 140], overflowWidth: 24)
    typealias Fit = ComposerFooterLayout.Fit

    func fit(_ host: CGFloat, _ previous: Fit? = nil, _ m: ComposerFooterLayout.Measurement? = nil) -> Fit {
        ComposerFooterLayout.resolve(m ?? base, hostWidth: host, previous: previous)
    }

    @Test func compactBreakpoints() {
        #expect(ComposerFooterLayout.isCompact(width: 619, hasWideActions: false))
        #expect(!ComposerFooterLayout.isCompact(width: 620, hasWideActions: false))
        #expect(ComposerFooterLayout.isCompact(width: 779, hasWideActions: true))
        #expect(!ComposerFooterLayout.isCompact(width: 780, hasWideActions: true))
    }

    @Test func overflowSteps() {
        #expect(fit(357) == Fit())
        #expect(fit(356) == Fit(hiddenCount: 1))
        #expect(fit(241) == Fit(hiddenCount: 1))
        #expect(fit(240) == Fit(hiddenCount: 2))
        #expect(fit(176) == Fit(hiddenCount: 2))
        #expect(fit(133) == Fit(hiddenCount: 2))
        #expect(fit(132) == Fit(hiddenCount: 2, visible: false))
        #expect(fit(0) == Fit(hiddenCount: 2, visible: false))
        let single = ComposerFooterLayout.Measurement(gap: 4, naturalFixedWidth: 140, minimumFixedWidth: 140, blockWidths: [], overflowWidth: 0)
        #expect(fit(139, nil, single) == Fit(visible: false))
    }

    @Test func hysteresis() {
        #expect(fit(357, Fit(hiddenCount: 1)) == Fit(hiddenCount: 1))
        #expect(fit(358, Fit(hiddenCount: 1)) == Fit())
        let partly = fit(357, Fit(hiddenCount: 2))
        #expect(partly == Fit(hiddenCount: 1))
        #expect(fit(357, partly) == partly)
        #expect(fit(358, partly) == Fit())
    }

    /// Labels go first, last block first, then blocks move into overflow.
    @Test func iconOnlySteps() {
        var m = base
        m.iconOnlyBlockWidths = [40, 100]
        #expect(fit(357, nil, m) == Fit())
        #expect(fit(356, nil, m) == Fit(iconOnlyCount: 1)) // 149 + 60 + 100 + 8 = 317
        #expect(fit(317, nil, m) == Fit(iconOnlyCount: 1))
        #expect(fit(316, nil, m) == Fit(iconOnlyCount: 2)) // 149 + 40 + 100 + 8 = 297
        #expect(fit(296, nil, m) == Fit(hiddenCount: 1, iconOnlyCount: 2)) // 149 + 40 + 24 + 8 = 221
        #expect(fit(220, nil, m) == Fit(hiddenCount: 2, iconOnlyCount: 2))
        #expect(fit(317, Fit(iconOnlyCount: 2), m) == Fit(iconOnlyCount: 2))
        #expect(fit(318, Fit(iconOnlyCount: 2), m) == Fit(iconOnlyCount: 1))
    }
}
