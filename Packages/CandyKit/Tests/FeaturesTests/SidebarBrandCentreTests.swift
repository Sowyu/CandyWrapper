import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's candy centres between the traffic lights and the search icon, measured from the window's own close
/// button, and the collapse button shares its centre line (the user, r6-logo-between-lights-and-search.png).
@MainActor
struct SidebarBrandCentreTests {
    private func laidOut(styleMask: NSWindow.StyleMask, width: CGFloat) -> (SidebarContentView, NSWindow) {
        let size = NSSize(width: width, height: 640)
        let content = SidebarContentView()
        content.hideWorkingShelf()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        content.frame = container.bounds
        container.addSubview(content)
        content.layoutSubtreeIfNeeded()
        return (content, window)
    }

    @Test(arguments: [SidebarMetrics.minWidth, 480]) func candyCentresBetweenLightsAndSearch(width: CGFloat) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let (content, window) = laidOut(styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable], width: width)
        defer { window.contentView = nil }
        let close = try #require(window.standardWindowButton(.closeButton))
        let lights = content.convert(close.bounds, from: close)
        let searchIconTop = content.search.frame.minY + (content.search.frame.height - 16) / 2
        let centre = content.brand.frame.minY + content.brand.markCentreY
        #expect(abs(centre - (lights.maxY + searchIconTop) / 2) <= 0.5)
        #expect(content.trigger.frame.midY == centre)
        #expect(content.trigger.frame.maxX == width - 10) // its 16pt icon ends 16 in, like the rows' action icons
        #expect(content.brand.frame.minX == 16)
    }

    @Test func withoutLightsTheCandyCentresInTheHeaderBand() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let (content, window) = laidOut(styleMask: [.borderless], width: 256)
        defer { window.contentView = nil }
        // A borderless offscreen window stands in for the windowed look: the lights' usual place.
        let lightsAssumed = content.search.frame.minY + (content.search.frame.height - 16) / 2
        #expect(abs(content.brand.frame.minY + content.brand.markCentreY - (33 + lightsAssumed) / 2) <= 0.5)
        content.windowedMac = false
        content.layoutSubtreeIfNeeded()
        let searchIconTop = content.search.frame.minY + (content.search.frame.height - 16) / 2
        #expect(abs(content.brand.frame.minY + content.brand.markCentreY - searchIconTop / 2) <= 0.5)
        #expect(SidebarContentView.brandCentre(lightsBottom: nil, searchIconTop: 94) == 47)
        #expect(SidebarContentView.brandCentre(lightsBottom: 33, searchIconTop: 94) == 64)
    }
}
