import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Whole-sidebar comparison: our sidebar at 256x780, 2x, with the reference dataset, against the left 256pt
/// of design/reference/02-sidebar-populated.{light,dark}.png. Writes ref, ours and diff PNGs plus
/// report-sidebar-whole.html to /tmp/candywrapper-fidelity. Text differs where the data differs.
@MainActor
struct SidebarFidelityTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/sidebar-whole")
    static let tolerance = 8

    static func render(dark: Bool) -> NSBitmapImageRep {
        let container = SidebarContainerView()
        let content = SidebarContentView()
        content.windowedMac = false // the reference is the web client: no traffic lights
        content.stage = .nightly
        content.now = { SidebarPreview.referenceNow }
        content.state = SidebarListState(activeThreadId: SidebarPreview.referenceActiveThread)
        content.setSnapshot(SidebarPreview.referenceSnapshot(), animated: false)
        container.content = content
        return Snapshot.image(of: container, size: NSSize(width: 256, height: 780), scale: 2, dark: dark)
    }

    static func crop(_ rep: NSBitmapImageRep, width: Int, height: Int) -> NSBitmapImageRep {
        let cg = rep.cgImage!.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))!
        return NSBitmapImageRep(cgImage: cg)
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

    /// Share of pixels over tolerance, overall and per horizontal band, plus a diff image.
    static func compare(_ ref: NSBitmapImageRep, _ ours: NSBitmapImageRep, bands: [(String, Int, Int)])
        -> (Double, [(String, Double)], NSBitmapImageRep) {
        let w = ref.pixelsWide, h = ref.pixelsHigh
        let a = pixels(ref, w, h), b = pixels(ours, w, h)
        let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let d = diff.bitmapData!
        var overRow = [Int](repeating: 0, count: h)
        for i in stride(from: 0, to: a.count, by: 4) {
            var m = 0
            for k in 0..<3 { m = max(m, abs(Int(a[i + k]) - Int(b[i + k]))) }
            let gray = UInt8((Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])) / 9 + 170)
            if m > tolerance { overRow[i / 4 / w] += 1; d[i] = 255; d[i + 1] = 60; d[i + 2] = 60 } else { d[i] = gray; d[i + 1] = gray; d[i + 2] = gray }
            d[i + 3] = 255
        }
        let total = Double(overRow.reduce(0, +)) / Double(w * h)
        let perBand = bands.map { name, y0, y1 in
            (name, Double(overRow[(y0 * 2)..<(y1 * 2)].reduce(0, +)) / Double(w * (y1 - y0) * 2))
        }
        return (total, perBand, diff)
    }

    @Test func wholeSidebar() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let bands = [("titlebar", 0, 52), ("search", 52, 100), ("first card", 100, 184), ("list", 100, 740), ("footer", 740, 780)]
        var lines: [String] = []
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: Self.repo.appendingPathComponent(
                "design/reference/02-sidebar-populated.\(theme).png"))))
            let ref = Self.crop(full, width: 512, height: 1560)
            let ours = Self.render(dark: theme == "dark")
            let (total, perBand, diff) = Self.compare(ref, ours, bands: bands)
            try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(theme).ref.png"))
            try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(theme).ours.png"))
            try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(theme).diff.png"))
            let line = "\(theme): \(String(format: "%.2f", total * 100))% differ; "
                + perBand.map { "\($0.0) \(String(format: "%.2f", $0.1 * 100))%" }.joined(separator: ", ")
            print("sidebar-whole", line)
            lines.append(line)
        }
        let html = "<!doctype html><title>Sidebar</title><body style='font:13px -apple-system'>" + lines.map { "<p>\($0)</p>" }.joined()
            + ["light", "dark"].map { t in "<p>" + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='sidebar-whole/\(t).\($0).png'>" }.joined() + "</p>" }.joined()
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-sidebar-whole.html"), atomically: true, encoding: .utf8)
    }
}
