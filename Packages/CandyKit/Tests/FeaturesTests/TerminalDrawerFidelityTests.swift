import AppKit
import Testing
import DesignSystem
@testable import Features

/// The terminal drawer's chrome (with one terminal, and empty) against T3's markup in Chromium
/// (spec from scripts/gen-terminal-drawer-spec.py, references in design/component-reference/
/// terminal-drawer). Writes ref, ours and diff PNGs plus report-terminal-drawer.html to
/// /tmp/candywrapper-fidelity.
@MainActor
struct TerminalDrawerFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/terminal-drawer")

    static func view(_ name: String, size: CGSize) -> NSView {
        let drawer = TerminalDrawerView(frame: NSRect(x: 8, y: 8, width: size.width, height: size.height))
        drawer.emptyButton.title = "New Terminal (⌘N)"
        if name == "drawer" {
            let surface = TerminalSurfaceView()
            // The reference's canvas is empty, so only the surface's padding box and background
            // are compared; SwiftTerm's cells paint white in offscreen snapshots.
            surface.terminal.isHidden = true
            drawer.surface = surface
        }
        return drawer
    }

    @Test func terminalDrawer() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/terminal-drawer")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/terminal-drawer.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view = Self.view(name, size: CGSize(width: css["width"]!, height: css["height"]!))
                canvas.addSubview(view)
                canvas.frame = NSRect(x: 0, y: 0, width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                view.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='terminal-drawer/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("terminal-drawer", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY terminal-drawer: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Terminal drawer</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-terminal-drawer.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
