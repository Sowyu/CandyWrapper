import AppKit
import Testing
@testable import DesignSystem

/// Redesign reads the desktop picture only outside the folders macOS asks about (`WallpaperBlur.unguardedPath`).
@MainActor
struct DesktopPictureTests {
    typealias W = WallpaperBlur

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
}
