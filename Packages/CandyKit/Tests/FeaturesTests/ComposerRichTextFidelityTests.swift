import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Inline marks and blocks (lists, a nested list, a quote, headings, tasks) against T3's markup in Chromium
/// (spec from scripts/gen-composer-rich-spec.py, references in design/component-reference/composer-rich).
/// Writes ref, ours and diff PNGs plus report-composer-rich.html to /tmp/candywrapper-fidelity.
@MainActor
struct ComposerRichTextFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/composer-rich")

    @Test func composerRichText() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/composer-rich")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/composer-rich.json"))) as! [String: Any]
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
                let editor = ComposerEditor()
                editor.richTextEnabled = true
                editor.frame = NSRect(x: 8, y: 8, width: 560, height: max(ComposerEditor.lineHeight, css["height"]!))
                editor.textContainerInset = NSSize(width: 0, height: editor.lineTop)
                editor.setText((c["native"] as! [String: String])["text"]!)
                canvas.addSubview(editor)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='composer-rich/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("composer-rich", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY composer-rich: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Composer rich text</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-composer-rich.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
