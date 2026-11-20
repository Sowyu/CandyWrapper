import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The agent image card's fit rule and the full gallery's masonry, hover and lifetime.
@MainActor
struct ThreadImageWallTests {
    // MARK: Fit rule

    @Test func oneImageViewFitsEveryProportion() {
        let area = CGSize(width: 520, height: 600)
        let fit = { (w: CGFloat, h: CGFloat, scale: CGFloat) in GalleryLayout.fit(CGSize(width: w, height: h), in: area, scale: scale) }
        // A wide strip and a 4K screenshot take the full width.
        #expect(fit(2040, 600, 2) == CGSize(width: 520, height: 153))
        #expect(fit(3840, 2160, 2) == CGSize(width: 520, height: 293))
        // A tall phone screenshot takes the full height.
        #expect(fit(1179, 2556, 2) == CGSize(width: 277, height: 600))
        // A small picture grows to a third of the area rather than sit at its 32pt.
        let icon = fit(64, 64, 2)
        #expect(icon == CGSize(width: 322, height: 322))
        #expect(icon.width * icon.height >= area.width * area.height / 3 - 400)
        // Big enough at its own pixels: never stretched past them.
        #expect(GalleryLayout.fit(CGSize(width: 1600, height: 1200), in: CGSize(width: 2000, height: 2000), scale: 1) == CGSize(width: 1600, height: 1200))
        #expect(GalleryLayout.fit(CGSize(width: 1600, height: 1200), in: CGSize(width: 2000, height: 2000), scale: 2) == CGSize(width: 1333, height: 1000))
    }

    // MARK: Masonry

    static let aspects: [CGFloat] = [1, 0.5, 2, 1, 0.75, 1.5, 1]

    @Test(arguments: [
        (CGFloat(400), 2, [CGRect(x: 0, y: 0, width: 192, height: 192), CGRect(x: 208, y: 0, width: 192, height: 96),
                           CGRect(x: 208, y: 112, width: 192, height: 384), CGRect(x: 0, y: 208, width: 192, height: 192),
                           CGRect(x: 0, y: 416, width: 192, height: 144), CGRect(x: 208, y: 512, width: 192, height: 288),
                           CGRect(x: 0, y: 576, width: 192, height: 192)], CGFloat(800)),
        (CGFloat(700), 4, [CGRect(x: 0, y: 0, width: 163, height: 163), CGRect(x: 179, y: 0, width: 163, height: 82),
                           CGRect(x: 358, y: 0, width: 163, height: 326), CGRect(x: 537, y: 0, width: 163, height: 163),
                           CGRect(x: 179, y: 98, width: 163, height: 122), CGRect(x: 0, y: 179, width: 163, height: 245),
                           CGRect(x: 537, y: 179, width: 163, height: 163)], CGFloat(424)),
        (CGFloat(1000), 5, [CGRect(x: 0, y: 0, width: 187, height: 187), CGRect(x: 203, y: 0, width: 187, height: 94),
                            CGRect(x: 406, y: 0, width: 187, height: 374), CGRect(x: 609, y: 0, width: 187, height: 187),
                            CGRect(x: 812, y: 0, width: 187, height: 140), CGRect(x: 203, y: 110, width: 187, height: 281),
                            CGRect(x: 812, y: 156, width: 187, height: 187)], CGFloat(391)),
    ])
    func masonryPlacesEachImageInTheShortestColumn(width: CGFloat, columns: Int, frames: [CGRect], height: CGFloat) {
        let n = GalleryLayout.columns(width: width, minColumn: 160, gap: 16)
        #expect(n == columns)
        let laid = GalleryLayout.masonry(aspects: Self.aspects, width: width, columns: n, gap: 16)
        #expect(laid.frames == frames)
        #expect(laid.height == height)
    }

    @Test func neverFewerThanTwoColumns() {
        #expect(GalleryLayout.columns(width: 120, minColumn: 160, gap: 16) == 2)
    }

    // MARK: The wall

    static func window(_ width: CGFloat = 900, _ height: CGFloat = 700) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = DSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        return window
    }

    /// Pictures whose sizes the signed URL already gave: each places at once, before its pixels.
    static func measuredImages() -> [GalleryImage] {
        let images = ThreadImageGalleryTests.fakeImages()
        for image in images { MarkdownImages.record(CGSize(width: 320, height: 220), for: image.key) }
        return images
    }

    @Test func pixelsArrivingMoveNothing() async throws {
        let window = Self.window()
        defer { window.contentView = nil; window.close() }
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.images = Self.measuredImages()
        wall.layoutSubtreeIfNeeded()
        wall.masonry.relayout()
        let before = wall.masonry.frames
        #expect(before.count == 10, "every measured picture is placed before any pixels")
        #expect(wall.masonry.tiles.values.allSatisfy { $0.thumb.image == nil })
        await ThreadImageGalleryTests.pump { wall.masonry.tiles.values.allSatisfy { $0.thumb.image != nil } }
        // Other suites clear the shared decode cache in parallel, so whether every tile got its pixels within the wait
        // is not asserted; what is asserted is that nothing moved, with pixels or without.
        wall.masonry.relayout()
        #expect(wall.masonry.frames == before)
        #expect(wall.masonry.tiles.allSatisfy { $0.value.frame == before[$0.key] })
    }

    @Test func unmeasuredPicturesPlaceInOrderOnceMeasured() async throws {
        let window = Self.window()
        defer { window.contentView = nil; window.close() }
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        // Fresh keys: nothing is measured until the first load.
        let tag = UUID().uuidString.prefix(6)
        let images = ThreadImageGalleryTests.fakeImages().enumerated().map { i, image -> GalleryImage in
            var image = image
            image.source = .url(ThreadImageGalleryTests.dataURI(CGFloat(i) / 10, "\(tag)\(i)"))
            return image
        }
        wall.images = images
        wall.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(30)
        while wall.masonry.frames.count < images.count, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(wall.masonry.frames.count == images.count)
        let placed = wall.masonry.frames
        wall.masonry.relayout()
        #expect(wall.masonry.frames == placed)
    }

    @Test func closingTheWallReleasesItsTilesAndDecodes() async throws {
        let window = Self.window()
        defer { window.contentView = nil; window.close() }
        let (gallery, pill) = ThreadImageGalleryTests.controller(fileExists: true)
        window.contentView!.addSubview(pill)
        pill.frame = NSRect(x: 700, y: 12, width: 160, height: 30)
        let projection = try ThreadImageGalleryTests.projection("t", items: [], messages: Self.measuredImages().enumerated().map { i, image in
            guard case .url(let uri) = image.source else { return ("m\(i)", "", "2026-10-23T10:00:00Z") }
            return ("m\(i)", "![x](\(uri))", "2026-10-23T10:0\(i):00Z")
        })
        gallery.update(threadId: "t", projection: projection)
        #expect(gallery.images.count == 10)
        gallery.openWall(showing: nil)
        weak var wall = gallery.wall
        #expect(wall != nil && gallery.isWallOpen)
        wall?.layoutSubtreeIfNeeded()
        await ThreadImageGalleryTests.pump { (wall?.masonry.tiles.values.allSatisfy { $0.thumb.image != nil } ?? true) && !(wall?.masonry.tiles.isEmpty ?? true) }
        let tiles = wall?.masonry.tiles.values.map { $0 } ?? []
        #expect(!tiles.isEmpty)
        autoreleasepool { gallery.closeWall(animated: false) }
        // The run loop drains what AppKit autoreleased while the views left the window.
        try await Task.sleep(for: .milliseconds(50))
        #expect(!gallery.isWallOpen)
        #expect(wall == nil, "nothing holds the wall once it closes")
        #expect(tiles.allSatisfy { $0.window == nil && $0.thumb.image == nil }, "its tiles left the window with their pixels")
    }

    // MARK: Count and hover

    @Test func theCountSitsOnTheCardsRightPadding() {
        let view = ThreadImageGalleryView()
        view.images = ThreadImageGalleryTests.fakeImages()
        view.layoutSubtreeIfNeeded()
        #expect(view.count.frame.maxX == view.bounds.width - ThreadImageGalleryView.inset - 4)
        #expect(view.count.alignment == .right)
        #expect(view.title.frame.minX == ThreadImageGalleryView.inset + 4)
        #expect(view.expand.frame.maxX < view.count.frame.minX && !view.expand.isHidden)
        #expect(view.expand.accessibilityLabel() == "Open gallery")
    }

    /// Hover shows the strip; leaving, the keyboard ring moving on and the tile leaving the window each put it back to
    /// rest, for the wall's tiles and the card's.
    @Test(arguments: [true, false])
    func everyHoverStateClears(wallTile: Bool) async throws {
        let window = Self.window()
        defer { window.contentView = nil; window.close() }
        let masonry: GalleryMasonryView
        if wallTile {
            let wall = ThreadImageWallView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(wall)
            wall.images = Self.measuredImages()
            wall.layoutSubtreeIfNeeded()
            masonry = wall.masonry
        } else {
            let card = ThreadImageGalleryView()
            window.contentView!.addSubview(card)
            card.images = Self.measuredImages()
            card.layoutSubtreeIfNeeded()
            masonry = card.grid
        }
        masonry.relayout()
        let tile = try #require(masonry.tiles[0])
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        // Pointer leaves.
        tile.mouseEntered(with: event)
        #expect(tile.showsCaption && tile.shade.opacity == 1)
        tile.mouseExited(with: event)
        #expect(!tile.showsCaption && tile.shade.opacity == 0)
        // The keyboard ring moves to another tile.
        masonry.focused = 0
        #expect(tile.showsCaption)
        masonry.focused = 1
        #expect(!tile.showsCaption && tile.shade.opacity == 0)
        // A picture opened large by a click and closed again leaves no ring on its tile.
        masonry.focused = nil
        if wallTile, let wall = masonry.superview?.superview?.superview?.superview as? ThreadImageWallView ?? window.contentView?.subviews.first as? ThreadImageWallView {
            wall.openViewer(at: 0)
            wall.closeViewer()
            #expect(masonry.focused == nil && !tile.showsCaption)
        }
        // Scrolling a hovered tile out of the live rect drops it, so a still pointer can't keep it lit.
        tile.mouseEntered(with: event)
        masonry.images = []
        #expect(tile.superview == nil && masonry.tiles.isEmpty)
    }
}
