import AppKit
import Testing
@testable import DesignSystem

/// Compares native components with T3's own markup rendered in Chromium, state by state and
/// theme by theme. References come from scripts/component-reference (design/component-reference).
/// Output: /tmp/candywrapper-fidelity/report.html plus ours and diff PNGs per case.
/// Records numbers only; thresholds come later.
@MainActor
struct FidelityTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity")
    /// A channel difference above this counts the pixel as different.
    static let tolerance = 8

    struct Result {
        var name: String
        var differing: Double  // share of pixels over tolerance
        var maxDiff: Int
        var meanDiff: Double   // mean absolute channel difference, 0...255
        var refSize: String
        var oursSize: String
        var files: (ref: String, ours: String, diff: String)
    }

    @Test func button() throws {
        let refDir = Self.repo.appendingPathComponent("design/component-reference/button")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("design/component-reference/button.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let dir = Self.out.appendingPathComponent("button")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var results: [Result] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! [String: String]
            for state in spec["states"] as! [String] {
                for theme in spec["themes"] as! [String] {
                    let file = "\(name).\(state).\(theme).png"
                    guard let ref = NSBitmapImageRep(data: try Data(contentsOf: refDir.appendingPathComponent(file))) else { continue }
                    let button = ButtonView(native["title"].flatMap { $0.isEmpty ? nil : $0 },
                                            icon: native["icon"].flatMap(IconName.init(rawValue:)),
                                            variant: ButtonView.Variant(rawValue: native["variant"]!)!,
                                            size: ButtonView.Size(rawValue: native["size"]!)!)
                    let ours = Self.render(button, state: Self.controlState(state), pixels: (ref.pixelsWide, ref.pixelsHigh), dark: theme == "dark")
                    let (stats, diff) = Self.compare(ref, ours)
                    let base = "\(name).\(state).\(theme)"
                    try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), toReplace: dir.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                    let refCSS = manifest[name].map { String(format: "%.2fx%.0f", $0["width"]!, $0["height"]!) } ?? "?"
                    let size = button.intrinsicContentSize
                    results.append(Result(name: base, differing: stats.0, maxDiff: stats.1, meanDiff: stats.2,
                                          refSize: refCSS, oursSize: String(format: "%.2fx%.0f", size.width, size.height),
                                          files: ("button/\(base).ref.png", "button/\(base).ours.png", "button/\(base).diff.png")))
                }
            }
        }
        results.sort { $0.differing > $1.differing }
        try Self.writeReport(results, title: "Button")
        print(String(repeating: "-", count: 96))
        print("case".padding(toLength: 48, withPad: " ", startingAt: 0), "diff%   max   mean   ref css      ours")
        for r in results {
            print(r.name.padding(toLength: 48, withPad: " ", startingAt: 0),
                  String(format: "%5.2f  %4d  %5.2f", r.differing * 100, r.maxDiff, r.meanDiff),
                  " ", r.refSize.padding(toLength: 12, withPad: " ", startingAt: 0), r.oursSize)
        }
        let mean = results.map(\.differing).reduce(0, +) / Double(max(1, results.count))
        print(String(format: "%d cases, mean differing %.2f%%, report: %@", results.count, mean * 100,
                     Self.out.appendingPathComponent("report.html").path))
        #expect(!results.isEmpty)
    }

    static func controlState(_ name: String) -> ControlView.State {
        var s = ControlView.State()
        switch name {
        case "hover": s.hovered = true
        case "active": s.hovered = true; s.active = true
        case "focus-visible": s.focusVisible = true
        case "disabled": s.enabled = false
        default: break
        }
        return s
    }

    /// Our view at its intrinsic size, 8pt in from the top-left, on `--background`, like the reference clip.
    /// The state is set after the frame, as in a live window, so the press scale survives.
    static func render(_ view: ControlView, state: ControlView.State, pixels: (Int, Int), dark: Bool) -> NSBitmapImageRep {
        let canvas = Canvas(frame: .zero)
        canvas.addSubview(view)
        view.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: view.intrinsicContentSize)
        view.previewState(state)
        return Snapshot.image(of: canvas, size: NSSize(width: CGFloat(pixels.0) / 2, height: CGFloat(pixels.1) / 2), scale: 2, dark: dark)
    }

    final class Canvas: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    /// RGBA8 sRGB pixels of `rep`, drawn into a `width` x `height` buffer at the top-left.
    static func pixels(_ rep: NSBitmapImageRep, _ width: Int, _ height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let image = rep.cgImage!
            ctx.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
        return buffer
    }

    /// (share over tolerance, max channel diff, mean abs diff) and a diff image: the reference
    /// dimmed to gray, red where the pixels differ.
    static func compare(_ ref: NSBitmapImageRep, _ ours: NSBitmapImageRep) -> ((Double, Int, Double), NSBitmapImageRep) {
        let w = ref.pixelsWide, h = ref.pixelsHigh
        let a = pixels(ref, w, h), b = pixels(ours, w, h)
        let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let d = diff.bitmapData!
        var over = 0, maxDiff = 0, total = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            var m = 0
            for k in 0..<3 {
                let delta = abs(Int(a[i + k]) - Int(b[i + k]))
                total += delta
                m = max(m, delta)
            }
            maxDiff = max(maxDiff, m)
            let gray = UInt8((Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])) / 3 / 3 + 170)
            if m > tolerance {
                over += 1
                d[i] = 255; d[i + 1] = UInt8(max(0, 200 - m)); d[i + 2] = UInt8(max(0, 200 - m))
            } else {
                d[i] = gray; d[i + 1] = gray; d[i + 2] = gray
            }
            d[i + 3] = 255
        }
        let n = w * h
        return ((Double(over) / Double(n), maxDiff, Double(total) / Double(n * 3)), diff)
    }

    static func writeReport(_ results: [Result], title: String) throws {
        var rows = ""
        for r in results {
            rows += """
            <tr><td><b>\(r.name)</b><br>\(String(format: "%.2f%% differ<br>max %d, mean %.2f", r.differing * 100, r.maxDiff, r.meanDiff))<br>ref \(r.refSize)<br>ours \(r.oursSize)</td>
            <td><img src="\(r.files.ref)"></td><td><img src="\(r.files.ours)"></td><td><img src="\(r.files.diff)"></td></tr>\n
            """
        }
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(title) fidelity</title>
        <style>body{font:13px -apple-system;margin:20px}td{padding:6px;vertical-align:top;border-bottom:1px solid #ddd}
        img{zoom:.5;image-rendering:pixelated;border:1px dashed #ccc}td:first-child{width:220px}</style>
        <h1>\(title) fidelity, worst first</h1>
        <p>Columns: T3 in Chromium, ours, diff (red where a channel differs by more than \(tolerance)/255). Images are 2x, shown at 1x.</p>
        <table><tr><th>case</th><th>reference</th><th>ours</th><th>diff</th></tr>\(rows)</table>
        """
        try html.write(to: out.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
    }
}

private extension FileManager {
    func copyItem(at src: URL, toReplace dst: URL) throws {
        try? removeItem(at: dst)
        try copyItem(at: src, to: dst)
    }
}
