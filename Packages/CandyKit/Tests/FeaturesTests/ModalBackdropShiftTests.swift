import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The window behind a route modal stays where it was: the views keep their frames, and the backdrop snapshot draws
/// the sidebar where it sits on screen. Redesign's brand once left a `saveGState` open, so every sidebar view drawn
/// after it landed 16pt right and 56pt down in the backdrop (the user's "why did the crap move in the background").
@MainActor
struct ModalBackdropShiftTests {
    @Test(arguments: [true, false]) func sidebarStaysPutBehindSettings(dark: Bool) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let size = NSSize(width: 256, height: 640)
        let content = SidebarContentView()
        content.hideWorkingShelf()
        content.now = { SidebarPreview.referenceNow }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        defer { window.contentView = nil }
        content.frame = container.bounds
        container.addSubview(content)
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("t1", "History of lighthouses", project: "p1", kind: .done, minutesAgo: 5),
        ]), animated: false)
        content.layoutSubtreeIfNeeded()
        #expect(content.brand.markOnly)

        let watched: [NSView] = [content, content.search, content.trigger, content.navSection] + content.navRows
        func frames() -> [NSRect] { watched.map { $0.convert($0.bounds, to: nil) } }
        let closed = frames()
        let modal = AppRouteModalView.present(label: "Settings", content: NSView(), in: window)
        #expect(frames() == closed)
        container.setFrameSize(NSSize(width: size.width, height: size.height - 40))
        container.setFrameSize(size)
        content.layoutSubtreeIfNeeded()
        #expect(frames() == closed)
        modal.close(animated: false)
        #expect(frames() == closed)

        // The backdrop draws everything under the brand row exactly where the brand-less window has it.
        let withBrand = try #require(ModalHost.snapshot(of: container))
        content.brand.isHidden = true
        let withoutBrand = try #require(ModalHost.snapshot(of: container))
        content.brand.isHidden = false
        let a = NSBitmapImageRep(cgImage: withBrand), b = NSBitmapImageRep(cgImage: withoutBrand)
        let firstRow = Int((content.search.frame.minY / 2).rounded(.down))
        var differing = 0
        for y in firstRow..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { differing += 1 }
        }
        #expect(differing == 0, "\(differing) backdrop pixels under the brand row moved")
    }
}
