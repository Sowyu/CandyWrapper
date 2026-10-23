import Foundation
import Testing
@testable import Features

/// Which Dock image each app icon and appearance pick, and that every one ships in AppIconVariants.xcassets.
@MainActor
struct AppIconChoiceTests {
    @Test func autoFollowsTheSystem() {
        #expect(AppIconChoice.imageName("pink", appearance: "auto", systemDark: false) == "IconPinkLight")
        #expect(AppIconChoice.imageName("pink", appearance: "auto", systemDark: true) == "IconPinkDark")
        #expect(AppIconChoice.dockImageName("classic", appearance: "auto", systemDark: true, styledIcons: true) == "IconClassicDark")
    }

    @Test func lightAndDarkIgnoreTheSystem() {
        #expect(AppIconChoice.imageName("grape", appearance: "light", systemDark: true) == "IconGrapeLight")
        #expect(AppIconChoice.imageName("grape", appearance: "dark", systemDark: false) == "IconGrapeDark")
    }

    @Test func stickerInAutoKeepsTheBundleIconOnlyForClearAndTinted() {
        #expect(AppIconChoice.dockImageName("sticker", appearance: "auto", systemDark: true, styledIcons: true) == nil)
        #expect(AppIconChoice.dockImageName("sticker", appearance: "auto", systemDark: true, styledIcons: false) == "IconStickerDark")
        #expect(AppIconChoice.dockImageName("sticker", appearance: "light", systemDark: true, styledIcons: true) == "IconStickerLight")
        #expect(AppIconChoice.dockImageName("sticker", appearance: "dark", systemDark: false, styledIcons: true) == "IconStickerDark")
    }

    @Test func everyImageShips() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/Resources/AppIconVariants.xcassets").standardized
        for (value, _) in AppIconChoice.options {
            for dark in [false, true] {
                let name = AppIconChoice.imageName(value, appearance: dark ? "dark" : "light", systemDark: false)
                #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("\(name).imageset/icon.png").path), "\(name)")
            }
        }
    }
}
