import AppKit
import Testing

@testable import DesignSystem

/// Redesign (Dither) shape: one glyph size and stroke per context, and continuous corners.
@MainActor
struct DitherShapeTests {
    private func withDither(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        try body()
    }

    @Test func glyphsInOneContextShareSizeAndStroke() {
        withDither {
            // The row's snooze clock and settle check at 14, its pull request glyph at 12, a menu glyph passed as a
            // definition: all draw 14pt glyphs with one stroke.
            let views = [IconView(name: .clock, size: 14), IconView(name: .check, size: 14),
                         IconView(name: .gitPullRequestArrow, size: 12), IconView(definition: IconName.trash2.definition, size: 12)]
            for v in views {
                v.layoutSubtreeIfNeeded()
                let strokes = v.shapeLayers.filter { !$0.isHidden && $0.strokeColor != nil }
                #expect(!strokes.isEmpty)
                for l in strokes { #expect(l.lineWidth == IconView.ditherStroke) }
                // No duotone tint at row size, so a closed glyph reads no heavier than an open one.
                #expect(v.shapeLayers.allSatisfy { $0.isHidden || $0.strokeColor != nil || $0.opacity == 1 })
            }
            #expect(IconView.ditherGlyphSize(box: 12) == 14)
            #expect(IconView.ditherGlyphSize(box: 16) == 16)
            #expect(IconView.ditherGlyphSize(box: 24) == 24)
        }
    }

    @Test func menuDefinitionsFindTheirIcon() {
        #expect(IconName.lucide(drawing: IconName.trash2.definition) == .trash2)
        var restroked = IconName.chevronDown.definition
        restroked.elements = restroked.elements.map { var e = $0; e.paint.strokeWidth = 2.25; return e }
        #expect(IconName.lucide(drawing: restroked) == .chevronDown)
    }

    @Test func continuousCornersReachPastTheCircularArc() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let path = SmoothCorners.path(rect, 12, flipped: true)
        #expect(path.boundingBoxOfPath.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        // The top edge runs straight until 1.53 radii from the corner, then eases off it sooner than a circular arc:
        // 0.9 radii in, the circular arc is 0.06pt below the edge and the continuous curve 0.22pt.
        #expect(path.contains(CGPoint(x: 100 - 12 * 1.6, y: 0.05)))
        let probe = CGPoint(x: 100 - 12 * 0.9, y: 0.15)
        #expect(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil).contains(probe))
        #expect(!path.contains(probe))
        // A pill stays a pill.
        let pill = SmoothCorners.path(CGRect(x: 0, y: 0, width: 80, height: 20), 10, flipped: true)
        #expect(pill.contains(CGPoint(x: 40, y: 0.5)) && !pill.contains(CGPoint(x: 1, y: 1)))
    }

    @Test func layersTakeContinuousCornersOnlyUnderDither() {
        let plain = CALayer()
        plain.cornerRadius = 8
        withDither {
            let smooth = CALayer()
            smooth.cornerRadius = 8
            #expect(smooth.cornerCurve == .continuous)
        }
        let after = CALayer()
        after.cornerRadius = 8
        #expect(after.cornerCurve == .circular)
        #expect(plain.cornerCurve == .circular)
    }

    @Test func cornersFollowOneScaleAndNestConcentrically() {
        // T3's controls, cards and `rounded-3xl` surfaces (the composer's and the details card's 22) map to 8, 12, 16.
        #expect([4, 6, 10, 18, 22, 24, 999].map(DitherChrome.radius) == [4, 8, 12, 12, 16, 16, 999])
        // A shape `inset` inside another takes the outer corner less the inset, never under 4.
        #expect(DitherChrome.nested(in: DitherChrome.windowRadius, inset: 8) == 8)
        #expect(DitherChrome.nested(in: 8, inset: 8) == 4)
    }
}
