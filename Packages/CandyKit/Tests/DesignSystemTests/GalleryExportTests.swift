import AppKit
import Testing
@testable import DesignSystem

/// Exports every gallery section in light and dark at 2x for side-by-side review with
/// design/reference. Output: /tmp/candywrapper-gallery/<section>.<theme>.png
@MainActor
struct GalleryExportTests {
    @Test func exportsEverySection() throws {
        let dir = URL(fileURLWithPath: "/tmp/candywrapper-gallery")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for section in ComponentGallery.sections {
            for dark in [false, true] {
                let rep = ComponentGallery.render(section, width: 640, dark: dark)
                #expect(rep.pixelsWide == 1280)
                let slug = section.title.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(2).joined(separator: "-")
                try Snapshot.writePNG(rep, to: dir.appendingPathComponent("\(slug).\(dark ? "dark" : "light").png"))
            }
        }
    }
}
