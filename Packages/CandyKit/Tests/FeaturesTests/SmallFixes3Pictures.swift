import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Opt-in before and after pictures for the small-fixes-3 batch, under Redesign:
/// `SF3_PICTURES=<dir> SF3_TAG=after scripts/test --filter SmallFixes3Pictures`. It uses only APIs main already has,
/// so the same file renders the "before" state on main. `SF3_CARD_MAX` is the card's tallest (main's room below the
/// pill, or the new cap).
@MainActor
struct SmallFixes3Pictures {
    nonisolated static let folder = ProcessInfo.processInfo.environment["SF3_PICTURES"]
    static var tag: String { ProcessInfo.processInfo.environment["SF3_TAG"] ?? "after" }

    static func redesign(dark: Bool) -> ThemeRuntimeInput {
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        return input
    }

    static func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        let dir = URL(fileURLWithPath: folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name)-\(tag).png"))
    }

    /// The sidebar with the traffic lights drawn where the window puts them (x 16, 36, 56, centred in 52).
    @Test(.enabled(if: folder != nil)) func sidebarTop() throws {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        for dark in [true, false] {
            ThemeRuntime.apply(Self.redesign(dark: dark))
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [SidebarMetrics.minWidth, 420] {
                let sidebar = SidebarContentView()
                sidebar.now = { SidebarPreview.referenceNow }
                sidebar.setSnapshot(SidebarPreview.referenceSnapshot(), animated: false)
                let rep = RedesignBaselineTests.image(sidebar, size: NSSize(width: width, height: 900), dark: dark)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let flip = NSAffineTransform()
                flip.translateX(by: 0, yBy: 900); flip.scaleX(by: 1, yBy: -1); flip.concat()
                for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(i) * 20, y: 26 - 7, width: 14, height: 14)).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                try Self.write(rep, "1-sidebar-top-\(dark ? "dark" : "light")-\(Int(width))")
            }
        }
    }

    /// The Agent images card with 30 pictures in a 900pt-tall window.
    @Test(.enabled(if: folder != nil)) func imagesCard() async throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(Self.redesign(dark: true))
        let images = (0..<3).flatMap { round in
            ThreadImageGalleryTests.fakeImages().enumerated().map { i, image in
                GalleryImage(source: image.source, threadId: "t", agent: image.agent, entryId: "r\(round)-\(i)",
                             at: T3Timestamp(ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-(round * 10 + i) * 190)))))
            }
        }
        let gallery = ThreadImageGalleryView()
        gallery.maxHeight = CGFloat(Double(ProcessInfo.processInfo.environment["SF3_CARD_MAX"] ?? "") ?? 820)
        gallery.images = images
        let window = ThreadImageWallTests.window(600, 900)
        defer { window.contentView = nil; window.close() }
        let root = window.contentView!
        root.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        let card = PopoverView(content: gallery, padding: .none)
        let size = card.intrinsicContentSize
        card.frame = NSRect(x: 30, y: 30, width: size.width, height: size.height)
        root.addSubview(card)
        root.layoutSubtreeIfNeeded()
        await ThreadImageGalleryTests.pump { gallery.grid.tiles.values.filter { $0.thumb.image != nil }.count >= min(6, gallery.grid.tiles.count) }
        let shown = NSSize(width: card.frame.maxX + 30, height: card.frame.maxY + 30)
        window.contentView = nil
        try Self.write(Snapshot.image(of: root, size: shown, dark: true), "2-images-card-30")
        window.contentView = root
    }

    /// The gallery wall opened under a pointer that rests on the first tile.
    @Test(.enabled(if: folder != nil)) func wallAtRest() async throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(Self.redesign(dark: true))
        let window = ThreadImageWallTests.window(1100, 780)
        defer { window.contentView = nil; window.close() }
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.images = ThreadImageWallTests.measuredImages()
        wall.layoutSubtreeIfNeeded()
        wall.masonry.relayout()
        await ThreadImageGalleryTests.pump { wall.masonry.tiles.values.allSatisfy { $0.thumb.image != nil } }
        let tile = try #require(wall.masonry.tiles[0])
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        // AppKit's entered event for a tile that appears under the still pointer.
        tile.mouseEntered(with: event)
        wall.removeFromSuperview()
        try Self.write(Snapshot.image(of: wall, size: wall.frame.size, dark: true), "3-gallery-at-rest")
    }

    /// The Usage chart's fixture, dark and light.
    @Test(.enabled(if: folder != nil)) func usageChart() throws {
        let motion = Motion.reducedOverride
        defer { Motion.reducedOverride = motion }
        Motion.reducedOverride = true
        for dark in [true, false] {
            try UsageDitherChartTests.withRedesign(dark: dark) {
                let (host, _) = UsageDitherChartPictures.host(UsageDitherChartTests.model())
                try Self.write(RedesignBaselineTests.image(host, size: NSSize(width: 946, height: 330), dark: dark), "5-usage-chart-\(dark ? "dark" : "light")")
            }
        }
    }

    /// Settings' route modal under Redesign at 1100 and 840 wide, dark and light, on four pages.
    @Test(.enabled(if: folder != nil)) func settingsModal() throws {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        let context = SettingsPagesFidelityTests.context()
        context.nowMs = { TimestampFormat.nowMs(RedesignBaselineTests.now) }
        for dark in [true, false] {
            ThemeRuntime.apply(Self.redesign(dark: dark))
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for section in [DitherSettingsSection.general, .appearance, .projects, .about] {
                for width in [1100, 840] as [CGFloat] {
                    let page = SettingsPageView()
                    page.header.isRouteModal = true
                    var pages: [NSView & SettingsGroupRow] = []
                    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                        pages = section.slices.map { RedesignBaselineTests.page($0.page, context: context) as NSView & SettingsGroupRow }
                    }
                    page.header.section = section.slices.first?.page ?? .general
                    page.header.restore.isHidden = section != .general
                    page.ditherHeading = (section.label, section.subtitle)
                    page.page = DitherSettingsSectionView(section: section, pages: pages)
                    let nav = SettingsSidebarView()
                    nav.isRouteModal = true
                    nav.selected = section.slices.first?.page ?? .general
                    let modal = AppRouteModalView(label: "Settings", content: page, navigation: nav)
                    try Self.write(RedesignBaselineTests.image(modal, size: NSSize(width: width, height: 780), dark: dark),
                                   "14-settings-\(section.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
    }
}
