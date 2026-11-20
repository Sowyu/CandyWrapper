import AppKit
import Testing
import DesignSystem
@testable import Features

/// #32683 (ComposerBanner.tsx:83, index.css:220 at 4928): in dark mode only the attachment touching the
/// composer draws the seam shade; one with another attachment docked under it draws none, so a stack of
/// notices shows no dark bands.
@MainActor
struct ComposerBannerSeamTests {
    /// Two attached notices as ThreadPanelView docks them, the lower one 17pt over the upper one's bottom.
    /// Returns the brightness just above the upper one's overlap line, against a row 6pt higher in it.
    private func upperSeam(dockedBelow: Bool) -> (seam: CGFloat, body: CGFloat) {
        let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
        let width: CGFloat = 400, height: CGFloat = 51, overlap = ComposerBannerView.overlap
        func notice(_ title: String) -> ComposerNoticeBannerView {
            let v = ComposerNoticeBannerView()
            v.apply(.init(variant: .neutral, icon: .info, title: title, description: nil))
            v.placement = .attached
            return v
        }
        let upper = notice("Server update available"), lower = notice("Goal")
        upper.dockedBelow = dockedBelow
        lower.joinsAbove = true
        upper.frame = NSRect(x: 8, y: 8, width: width, height: height)
        lower.frame = NSRect(x: 8, y: 8 + height - overlap, width: width, height: height)
        canvas.addSubview(upper)
        canvas.addSubview(lower)
        let image = Snapshot.image(of: canvas, size: NSSize(width: width + 16, height: 2 * height + 16), scale: 2, dark: true)
        // Right of the text, clear of the outline; the seam is the 10pt band just above the overlap line.
        let x = Int((8 + width - 40) * 2)
        func brightness(_ y: CGFloat) -> CGFloat { image.colorAt(x: x, y: Int(y * 2))?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1 }
        let line = 8 + height - overlap
        return (brightness(line - 2), brightness(line - 12))
    }

    @Test func onlyTheAttachmentTouchingTheComposerShadesItsSeam() {
        let touching = upperSeam(dockedBelow: false)
        #expect(touching.seam < touching.body - 0.01, "the seam shade darkens the band above the overlap")
        let stacked = upperSeam(dockedBelow: true)
        #expect(abs(stacked.seam - stacked.body) < 0.005, "a stacked notice draws no band: \(stacked)")
    }
}
