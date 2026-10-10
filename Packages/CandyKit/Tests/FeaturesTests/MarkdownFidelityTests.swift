import AppKit
import Testing
import DesignSystem
@testable import Features

/// MarkdownView against T3's ChatMarkdown markup rendered in Chromium with T3's Shiki
/// (spec from scripts/gen-markdown-spec.py, references in design/component-reference/markdown).
/// Writes ref, ours and diff PNGs plus /tmp/candywrapper-fidelity/report-markdown.html.
@MainActor
struct MarkdownFidelityTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity")
    static let tolerance = 8

    final class Canvas: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    @Test func markdown() throws {
        let refDir = Self.repo.appendingPathComponent("design/component-reference/markdown")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("design/component-reference/markdown.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let dir = Self.out.appendingPathComponent("markdown")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rows = "", lines: [String] = [], total = 0.0, count = 0
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! [String: String]
            let width = CGFloat(Double(native["width"]!)!)
            for theme in ["light", "dark"] {
                let file = "\(name).rest.\(theme).png"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(file))))
                let view = MarkdownView(frame: .zero)
                view.cwd = native["cwd"]
                view.setMarkdown(native["markdown"]!)
                let height = view.height(forWidth: width)
                let canvas = Canvas(frame: .zero)
                canvas.addSubview(view)
                view.frame = NSRect(x: 8, y: 8, width: width, height: height)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (share, diff) = Self.compare(ref, ours)
                let base = "\(name).\(theme)"
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                let refHeight = manifest[name]?["height"] ?? 0
                let line = String(format: "%@ %@: %.2f%% differ, height ref %.2f ours %.2f", name, theme, share * 100, refHeight, height)
                lines.append(line)
                total += share; count += 1
                rows += "<tr><td>\(line)</td>" + ["ref", "ours", "diff"].map { "<td><img src='markdown/\(base).\($0).png'></td>" }.joined() + "</tr>"
            }
        }
        for line in lines { print("MARKDOWN", line) }
        print(String(format: "FIDELITY Markdown: %d cases, mean differing %.2f%%", count, total / Double(max(count, 1)) * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Markdown fidelity</title><style>body{font:13px -apple-system}td{vertical-align:top}img{zoom:.5}</style>"
            + "<p>T3 in Chromium, ours, diff (red where a channel differs by more than \(Self.tolerance)/255).</p><table>\(rows)</table>"
        try html.write(to: Self.out.appendingPathComponent("report-markdown.html"), atomically: true, encoding: .utf8)
        #expect(count > 0)
    }

    static func pixels(_ rep: NSBitmapImageRep, _ w: Int, _ h: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let image = rep.cgImage!
            ctx.draw(image, in: CGRect(x: 0, y: h - image.height, width: image.width, height: image.height))
        }
        return buffer
    }

    /// Share of pixels where a channel differs by more than `tolerance`, and a diff image.
    static func compare(_ ref: NSBitmapImageRep, _ ours: NSBitmapImageRep) -> (Double, NSBitmapImageRep) {
        let w = ref.pixelsWide, h = ref.pixelsHigh
        let a = pixels(ref, w, h), b = pixels(ours, w, h)
        let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let d = diff.bitmapData!
        var over = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            var m = 0
            for k in 0..<3 { m = max(m, abs(Int(a[i + k]) - Int(b[i + k]))) }
            let gray = UInt8((Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])) / 9 + 170)
            if m > tolerance { over += 1; d[i] = 255; d[i + 1] = 60; d[i + 2] = 60 } else { d[i] = gray; d[i + 1] = gray; d[i + 2] = gray }
            d[i + 3] = 255
        }
        return (Double(over) / Double(w * h), diff)
    }
}
