import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct WallpaperBackdropTests {
    typealias W = WallpaperBlur

    @Test func optionsMapToTheDesktopsPlacements() {
        #expect(W.placement(scaling: nil, clip: nil) == .fill)
        #expect(W.placement(scaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, clip: true) == .fill)
        #expect(W.placement(scaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, clip: false) == .fit)
        #expect(W.placement(scaling: NSImageScaling.scaleAxesIndependently.rawValue, clip: true) == .stretch)
        #expect(W.placement(scaling: NSImageScaling.scaleNone.rawValue, clip: false) == .center)
    }

    @Test func layoutMaths() {
        let screen = CGSize(width: 1920, height: 1080), wide = CGSize(width: 4000, height: 1000)
        // Fill covers the screen and crops the sides.
        #expect(W.imageRect(image: wide, screen: screen, placement: .fill) == CGRect(x: -1200, y: 0, width: 4320, height: 1080))
        // Fit shows all of it, bands above and below.
        #expect(W.imageRect(image: wide, screen: screen, placement: .fit) == CGRect(x: 0, y: 300, width: 1920, height: 480))
        #expect(W.imageRect(image: wide, screen: screen, placement: .stretch) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(W.imageRect(image: CGSize(width: 200, height: 100), screen: screen, placement: .center)
            == CGRect(x: 860, y: 490, width: 200, height: 100))
        // Tiles start at the top left; y is up.
        #expect(W.imageRect(image: CGSize(width: 200, height: 100), screen: screen, placement: .tile)
            == CGRect(x: 0, y: 980, width: 200, height: 100))
        #expect(W.imageRect(image: .zero, screen: screen, placement: .fill) == .zero)
    }

    @Test func guardedFolders() {
        let home = "/Users/someone"
        for path in ["/Users/someone/Desktop/a.jpg", "/Users/someone/Documents", "/Users/someone/Downloads/x/y.heic",
                     "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/a.png", "/Users/someone/Library/CloudStorage/D/a.png",
                     "/Users/someone/Library/Containers/x/a.png", "/Volumes/USB/a.png", "/System/Volumes/Data/Users/someone/Desktop/a.png",
                     "/Users/someone/Pictures/Photos Library.photoslibrary/originals/a.heic", "/Users/someone/Desktop/../Desktop/a.png"] {
            #expect(W.isGuarded(path, home: home), "\(path)")
        }
        for path in ["/System/Library/Desktop Pictures/a.heic", "/Users/someone/Pictures/a.jpg", "/Users/someone/DesktopPictures/a.jpg",
                     "/Library/Desktop Pictures/a.png", "/Users/someone/Library/Application Support/com.apple.wallpaper/a.heic"] {
            #expect(!W.isGuarded(path, home: home), "\(path)")
        }
    }

    /// A link out of a plain folder into a guarded one is caught without looking inside the guarded folder.
    @Test func symlinksIntoGuardedFoldersAreCaught() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wallpaper-guard-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/home/Desktop", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/home/Pictures", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(filePath: root + "/home/Pictures/ok.png"))
        try fm.createSymbolicLink(atPath: root + "/home/Pictures/sneaky", withDestinationPath: "../Desktop")
        try fm.createSymbolicLink(atPath: root + "/home/Pictures/fine.png", withDestinationPath: "ok.png")
        let home = try #require(W.unguardedPath(root + "/home", home: "/nowhere"))
        #expect(W.unguardedPath(home + "/Pictures/sneaky/a.png", home: home) == nil)
        #expect(W.unguardedPath(home + "/Desktop/a.png", home: home) == nil)
        #expect(W.unguardedPath(home + "/Pictures/fine.png", home: home) == home + "/Pictures/ok.png")
    }

    @Test func dynamicPicturesPickByAppearance() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["l": 2, "d": 5], format: .binary, options: 0)
        let pair = try #require(W.appearanceIndices(plist.base64EncodedString()))
        #expect(pair.light == 2 && pair.dark == 5)
        #expect(W.appearanceIndices("not base64") == nil)
    }

    @Test func rendersAtAnEighthAndFallsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wallpaper-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "red.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)

        var request = W.Request(url: url, placement: .fill, fill: [0, 0, 0], pixels: CGSize(width: 1920, height: 1080), scale: 1, dark: false)
        let image = try #require(W.render(request))
        #expect(image.width == 240 && image.height == 135)
        request.url = dir.appending(path: "missing.png")
        #expect(W.render(request) == nil)
        // The same picture in the Desktop folder of a home it pretends is the user's is never read.
        try FileManager.default.createDirectory(at: dir.appending(path: "home/Desktop"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dir.appending(path: "home/Desktop/red.png"))
        request.url = dir.appending(path: "home/Desktop/red.png")
        #expect(W.render(request, home: "/nowhere") != nil)
        #expect(W.render(request, home: dir.appending(path: "home").path) == nil)
        request.url = URL(filePath: "/Library/Application Support/com.apple.wallpaper/aerials/videos/x.heic")
        #expect(W.render(request) == nil)
    }

    @Test func storeRendersOnlyWhenTheRequestChanges() async throws {
        let store = WallpaperStore(render: { _ in Self.pixel() })
        var request = W.Request(url: URL(filePath: "/a.png"), placement: .fill, fill: [0, 0, 0], pixels: CGSize(width: 100, height: 100),
                                scale: 1, dark: false)
        guard case .pending = store.lookup(1, request) else { Issue.record("expected pending"); return }
        try await waitUntilReady(store, 1, request)
        _ = store.lookup(1, request)
        #expect(store.renders == 1)
        request.dark = true
        _ = store.lookup(1, request)
        #expect(store.renders == 2)
        request.pixels = CGSize(width: 200, height: 200)
        _ = store.lookup(1, request)
        #expect(store.renders == 3)
        if case .unavailable = store.lookup(1, nil) {} else { Issue.record("no request means no picture") }
    }

    /// Moving the window only moves layers; appearance, Space, screen and activation changes look again, and an
    /// unchanged desktop renders nothing new.
    @Test func recomputeTriggers() async throws {
        let store = WallpaperStore(render: { _ in Self.pixel() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let view = WallpaperBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.store = store
        view.appearance = NSAppearance(named: .aqua)
        view.screens = { dark in
            [WallpaperScreen(display: 7, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                             request: W.Request(url: URL(filePath: "/a.png"), placement: .fill, fill: [0, 0, 0],
                                                pixels: CGSize(width: 1920, height: 1080), scale: 1, dark: dark))]
        }
        window.contentView = view
        try await waitUntilReady(store, 7, nil)
        let base = view.refreshes
        #expect(store.renders == 1)

        window.setFrameOrigin(NSPoint(x: 50, y: 60))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        #expect(view.refreshes == base)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(view.refreshes == base + 3)
        #expect(store.renders == 1)

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        #expect(store.renders == 2)
        window.contentView = nil
    }

    private nonisolated static func pixel() -> CGImage? {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }

    /// Waits for the store's background render, which always finishes.
    private func waitUntilReady(_ store: WallpaperStore, _ display: CGDirectDisplayID, _ request: W.Request?) async throws {
        if await !eventually({ !store.isPending(display) }) { Issue.record("render never finished") }
    }
}
