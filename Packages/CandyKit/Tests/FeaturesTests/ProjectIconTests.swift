import AppKit
import Testing
import T3Protocol
@testable import Features

/// Project icons: T3's override rules, decoding at icon size, and the store's monogram fallback.
@MainActor
struct ProjectIconTests {
    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func decodesAtIconSize() throws {
        let wide = try #require(ProjectIconStore.decode(Self.png(width: 512, height: 256)))
        #expect(wide.width == 32 && wide.height == 32)
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#0a0"/></svg>"##
        let fromSVG = try #require(ProjectIconStore.decode(Data(svg.utf8)))
        #expect(fromSVG.width == 32)
        #expect(ProjectIconStore.decode(Data("not an image".utf8)) == nil)
        #expect(ProjectIconStore.grayscale(wide) != nil)
    }

    @Test func overrides() {
        func parse(_ json: String) -> ProjectIconSource.Override? {
            ProjectIconSource.override(try? JSONValue(parsing: Data(json.utf8)))
        }
        #expect(parse(#"{"kind":"monogram","text":"AB","color":"red"}"#) == .monogram(text: "AB", color: "red"))
        #expect(parse(#"{"kind":"lucide","name":"rocket","color":"blue","monogramText":"RK"}"#) == .monogram(text: "RK", color: "blue"))
        #expect(parse(#"{"kind":"lucide","name":"rocket","color":"blue"}"#) == .lucide(name: "rocket", color: "blue"))
        #expect(parse(#"{"kind":"emoji","emoji":"🍬"}"#) == .emoji("🍬"))
        #expect(parse(#"{"kind":"image","url":"https://example.com/a.png"}"#) == nil)
    }

    /// The monogram shows until the icon arrives; a missing icon never asks again within the recheck window.
    @Test func storeLoadsOnceAndFallsBack() async throws {
        // Its own store: sidebar rows in other suites ask the shared one.
        let store = ProjectIconStore()
        let calls = Counter()
        let png = Self.png(width: 64, height: 64)
        store.loader = { _, cwd, _ in await calls.bump(cwd); return cwd == "/has-icon" ? png : nil }
        let withIcon = ProjectIconSource(title: "A", workspaceRoot: "/has-icon")
        let without = ProjectIconSource(title: "B", workspaceRoot: "/none")
        #expect(store.image(for: withIcon) == nil)
        #expect(store.image(for: without) == nil)
        _ = await eventually { store.image(for: withIcon) != nil }
        #expect(store.image(for: withIcon)?.width == 32)
        #expect(store.image(for: withIcon, grayscale: true) != nil)
        #expect(store.image(for: without) == nil)
        // A chosen icon wins over the file.
        #expect(store.image(for: ProjectIconSource(title: "A", workspaceRoot: "/has-icon", override: .emoji("x"))) == nil)
        _ = await eventually { await calls.value["/none"] != nil }
        let counts = await calls.value
        #expect(counts["/has-icon"] == 1 && counts["/none"] == 1)
    }

    actor Counter {
        var value: [String: Int] = [:]
        func bump(_ cwd: String) { value[cwd, default: 0] += 1 }
    }
}
