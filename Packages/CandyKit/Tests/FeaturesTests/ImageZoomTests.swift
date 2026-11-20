import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The gallery's zoom: the maths, the large view and the card resetting on a new picture, and the wall's density.
@MainActor
struct ImageZoomTests {
    @Test func theAnchorStaysUnderThePointer() {
        let origin = CGPoint(x: 40, y: 30), point = CGPoint(x: 210, y: 145)
        let size = CGSize(width: 300, height: 200)
        // The picture fraction under the pointer before and after zooming from 1 to 2.6.
        let before = CGPoint(x: (point.x - origin.x) / size.width, y: (point.y - origin.y) / size.height)
        let moved = ImageZoom.anchored(origin: origin, scale: 1, to: 2.6, about: point)
        let after = CGPoint(x: (point.x - moved.x) / (size.width * 2.6), y: (point.y - moved.y) / (size.height * 2.6))
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func clampingCentresASmallPictureAndKeepsALargeOneCovering() {
        let bounds = CGSize(width: 400, height: 300)
        #expect(ImageZoom.clamp(origin: CGPoint(x: -90, y: 70), size: CGSize(width: 200, height: 100), in: bounds) == CGPoint(x: 100, y: 100))
        // Wider than the view: no gap at either edge; shorter: centred.
        #expect(ImageZoom.clamp(origin: CGPoint(x: 50, y: 0), size: CGSize(width: 800, height: 100), in: bounds) == CGPoint(x: 0, y: 100))
        #expect(ImageZoom.clamp(origin: CGPoint(x: -900, y: 0), size: CGSize(width: 800, height: 100), in: bounds) == CGPoint(x: -400, y: 100))
    }

    @Test func doubleClickTogglesFitAndActualPixels() {
        // A 4K picture fitted 520pt wide on a 2x screen: 100% is about 3.7 times fit.
        let actual = ImageZoom.actual(natural: CGSize(width: 3840, height: 2160), fitted: CGSize(width: 520, height: 293), backing: 2)
        #expect(abs(actual - 3840 / 2 / 520) < 1e-9)
        #expect(ImageZoom.toggle(scale: 1, actual: actual) == actual)
        #expect(ImageZoom.toggle(scale: actual, actual: actual) == 1)
        // A picture fit already shows at 100% or larger goes to twice the fit.
        #expect(ImageZoom.toggle(scale: 1, actual: 1) == 2)
        #expect(ImageZoom.toggle(scale: 1, actual: 0.6) == 2)
        // Never below fit; up to 8x the pixels, at least 2x fit.
        #expect(ImageZoom.limits(actual: actual) == 1...(8 * actual))
        #expect(ImageZoom.limits(actual: 0.1) == 1...2)
    }

    @Test func decodesOnlyThePixelsTheZoomShows() {
        // A 4K picture at 100% on a 2x screen decodes its own pixels, not more.
        #expect(ImageZoom.decodeSide(shown: CGSize(width: 1920, height: 1080), backing: 2, natural: CGSize(width: 3840, height: 2160)) == 3840)
        #expect(ImageZoom.decodeSide(shown: CGSize(width: 7680, height: 4320), backing: 2, natural: CGSize(width: 3840, height: 2160)) == 3840)
        // In 256-pixel steps on the way.
        #expect(ImageZoom.decodeSide(shown: CGSize(width: 700, height: 400), backing: 2, natural: nil) == 1536)
    }

    @Test func zoomingTheViewKeepsThePointAndClamps() {
        let picture = AsyncImageView()
        let view = ZoomableImageView(picture: picture)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.naturalSize = { CGSize(width: 1600, height: 1200) }
        view.layoutSubtreeIfNeeded()
        #expect(picture.frame == NSRect(x: 0, y: 0, width: 400, height: 300))
        let point = CGPoint(x: 100, y: 75)
        view.zoom(to: 2, about: point)
        view.layoutSubtreeIfNeeded()
        #expect(picture.frame == NSRect(x: -100, y: -75, width: 800, height: 600))
        // Far past the cap: 8x the pixels is 1600 / 2 * 8 / 400 = 16x fit.
        view.zoom(to: 100)
        #expect(view.scale == 16)
        view.zoom(to: 0.2)
        view.layoutSubtreeIfNeeded()
        #expect(view.scale == 1 && picture.frame.origin == .zero)
    }

    @Test func theLargeViewFitsAgainOnANewPicture() {
        let window = ThreadImageWallTests.window()
        defer { window.contentView = nil; window.close() }
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.images = ThreadImageWallTests.measuredImages()
        wall.openViewer(at: 0)
        let viewer = try! #require(wall.viewer)
        viewer.layoutSubtreeIfNeeded()
        viewer.zoom.zoom(to: 2)
        #expect(viewer.zoom.isZoomed)
        viewer.step(1)
        #expect(!viewer.zoom.isZoomed && viewer.index == 1)
    }

    @Test func theCardFitsAgainOnANewPicture() {
        let window = ThreadImageWallTests.window()
        defer { window.contentView = nil; window.close() }
        let card = ThreadImageGalleryView()
        window.contentView!.addSubview(card)
        card.images = ThreadImageWallTests.measuredImages()
        card.large = 0
        card.layoutSubtreeIfNeeded()
        let frame = card.zoom.frame
        card.zoom.zoom(to: 3)
        card.layoutSubtreeIfNeeded()
        #expect(card.zoom.isZoomed && card.zoom.frame == frame, "the card keeps its size while zoomed")
        #expect(card.handleKey(.right))
        #expect(!card.zoom.isZoomed && card.large == 1)
    }

    @Test(arguments: [
        (5, 1.0, 6, 5), (5, 2.0, 6, 3), (5, 1.25, 6, 4), (5, 0.5, 6, 6), (3, 10.0, 6, 2), (2, 0.25, 6, 6), (4, 0.9, 1, 2),
    ])
    func pinchMapsToWholeColumns(_ c: (Int, Double, Int, Int)) {
        #expect(GalleryLayout.density(from: c.0, zoom: CGFloat(c.1), max: c.2) == c.3)
    }

    @Test func commandKeysStepTheWallsDensityForTheSession() {
        let saved = ThreadImageWallView.sessionColumns
        defer { ThreadImageWallView.sessionColumns = saved }
        ThreadImageWallView.sessionColumns = nil
        let window = ThreadImageWallTests.window(1200, 700)
        defer { window.contentView = nil; window.close() }
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.images = ThreadImageWallTests.measuredImages()
        wall.layoutSubtreeIfNeeded()
        let most = wall.masonry.maxColumns
        #expect(wall.masonry.columnCount == most && most > 3)
        func key(_ c: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
        }
        #expect(wall.performKeyEquivalent(with: key("=")))
        #expect(wall.masonry.columnCount == most - 1 && ThreadImageWallView.sessionColumns == most - 1)
        for _ in 0..<20 { _ = wall.performKeyEquivalent(with: key("=")) }
        #expect(wall.masonry.columnCount == 2)
        #expect(wall.performKeyEquivalent(with: key("-")))
        #expect(wall.masonry.columnCount == 3)
        // A new wall in the same session opens at the chosen density.
        let again = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(again)
        again.images = wall.images
        again.layoutSubtreeIfNeeded()
        #expect(again.masonry.columnCount == 3)
        #expect(wall.performKeyEquivalent(with: key("0")))
        #expect(wall.masonry.columnCount == most && ThreadImageWallView.sessionColumns == nil)
    }
}
