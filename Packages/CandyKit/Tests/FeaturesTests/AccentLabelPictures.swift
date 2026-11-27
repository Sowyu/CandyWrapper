import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Review pictures for X8's accent labels: the same accent-filled controls with the shipped rule
/// (`DitherAccent.foreground`, white only at 4.5:1) and with white labels, one row per accent, dark and light, each
/// captioned with the label's contrast measured from the pixels. White is applied to the palette here only; nothing
/// that ships changes. Opt in with CANDY_ACCENT_LABEL_PICTURES=<folder>.
@MainActor @Suite struct AccentLabelPictures {
    static let accents = ["teal", "pink", "violet", "blue", "orange", "amber"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDY_ACCENT_LABEL_PICTURES"] != nil))
    func render() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANDY_ACCENT_LABEL_PICTURES"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance; Motion.reducedOverride = motion }
        Motion.reducedOverride = true
        for dark in [true, false] {
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var rows: [[Strip]] = []
            for id in Self.accents {
                let accent = DitherAccent.named(id)
                rows.append(try [false, true].map { white in try strip(accent, dark: dark, white: white) })
            }
            let sheet = Self.sheet(rows, dark: dark)
            try Snapshot.writePNG(sheet, to: folder.appendingPathComponent("X8-accent-labels.\(dark ? "dark" : "light").png"))
        }
    }

    struct Piece { let image: CGImage; let caption: String }
    struct Strip { let title: String; let pieces: [Piece] }

    private func strip(_ accent: DitherAccent, dark: Bool, white: Bool) throws -> Strip {
        var colors = ThemeDefinition.dither.colors(for: dark ? .dark : .light)!
        colors.merge(accent.colors(dark: dark)) { $1 }
        if white { colors[.accentForeground] = "#ffffff"; colors[.messageActionForeground] = "#ffffff" }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: colors), dark: ThemeRuntimeHalf(colors: colors))
        input.ditherLight = true; input.ditherDark = true; input.ditherAccent = accent.id
        ThemeRuntime.apply(input)
        let fill = accent.accent(dark: dark)

        let panel = ComposerFidelityTests.panel(width: 640, dark: dark)
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.composer.footerControls = [try PickersFidelityTests.pickers().controlsView]
        panel.composer.text = "Refactor the upload queue so retries keep their place"
        let full = try #require(RedesignBaselineTests.image(panel, size: NSSize(width: 640, height: 560), dark: dark).cgImage)
        let scale = CGFloat(full.width) / 640
        let composerHeight: CGFloat = 170
        let composer = try #require(full.cropping(to: CGRect(x: 0, y: CGFloat(full.height) - composerHeight * scale,
                                                             width: CGFloat(full.width), height: composerHeight * scale)))

        func render(_ view: NSView, _ size: NSSize) throws -> CGImage {
            try #require(RedesignBaselineTests.image(view, size: size, dark: dark).cgImage)
        }
        let button = try render(Self.padded(ButtonView("Open thread")), NSSize(width: 150, height: 56))
        let iconButton = try render(Self.padded(ButtonView("New thread", icon: .plus)), NSSize(width: 160, height: 56))
        let group = ToggleGroupView(items: [("Large", nil), ("Small", nil)], selected: 0)
        let toggle = try render(Self.padded(group), NSSize(width: 190, height: 56))

        let label = white ? "white labels" : "shipped rule"
        return Strip(title: "\(accent.label), \(label)", pieces: [
            Piece(image: composer, caption: "send arrow " + Self.measure(composer, fill: fill)),
            Piece(image: button, caption: Self.measure(button, fill: fill)),
            Piece(image: iconButton, caption: Self.measure(iconButton, fill: fill)),
            Piece(image: toggle, caption: Self.measure(toggle, fill: fill)),
        ])
    }

    /// The control centered on a 12pt margin, so its ring and shadow fit.
    private static func padded(_ control: NSView) -> NSView {
        let box = PaddedBox(); box.addSubview(control); return box
    }

    final class PaddedBox: NSView {
        override func layout() {
            super.layout()
            guard let child = subviews.first else { return }
            let size = child.fittingSize.width > 0 ? child.fittingSize : child.intrinsicContentSize
            child.frame = NSRect(x: 12, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width - 24), height: size.height)
        }
    }

    /// The label's contrast on the fill, from the pixels: the box of accent pixels (within 6/255) that sit in a run of
    /// at least 16 pixels across, so the Flower's lone accent dots don't count, shrunk by a quarter of its height on
    /// every side to leave the rounded corners and the edge out, then the pixel inside farthest from the fill in
    /// contrast. "not on the accent" when nothing matches, as a dark segmented control draws its selection on the
    /// track's own gray.
    static func measure(_ image: CGImage, fill hex: String) -> String {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let v = Int(hex.dropFirst(), radix: 16)!
        let f = (v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff)
        var minX = w, minY = h, maxX = -1, maxY = -1
        func matches(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return abs(Int(px[i]) - f.0) <= 6 && abs(Int(px[i + 1]) - f.1) <= 6 && abs(Int(px[i + 2]) - f.2) <= 6
        }
        for y in 0..<h {
            var run = 0
            for x in 0..<w {
                run = matches(x, y) ? run + 1 : 0
                if run >= 16 { minX = min(minX, x - run + 1); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0 else { return "not on the accent" }
        let inset = (maxY - minY) / 4
        minX += inset; maxX -= inset; minY += inset; maxY -= inset
        guard maxX > minX, maxY > minY else { return "not on the accent" }
        func lum(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
            func lin(_ c: UInt8) -> Double { let s = Double(c) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let lf = lum(UInt8(f.0), UInt8(f.1), UInt8(f.2))
        var best = 1.0
        for y in minY...maxY { for x in minX...maxX {
            let i = (y * w + x) * 4
            let l = lum(px[i], px[i + 1], px[i + 2])
            best = max(best, (max(l, lf) + 0.05) / (min(l, lf) + 0.05))
        } }
        return String(format: "%.1f:1", best)
    }

    /// One row per accent, the shipped rule on the left and white on the right, captions under each piece.
    static func sheet(_ rows: [[Strip]], dark: Bool) -> NSBitmapImageRep {
        let scale: CGFloat = 2, gap: CGFloat = 16, captionH: CGFloat = 18, titleH: CGFloat = 24
        let pieceW = { (s: Strip) in s.pieces.reduce(CGFloat(0)) { $0 + CGFloat($1.image.width) / scale + gap } }
        let stripW = rows.flatMap { $0 }.map(pieceW).max() ?? 0
        let pieceH = rows.flatMap { $0 }.flatMap { $0.pieces }.map { CGFloat($0.image.height) / scale }.max() ?? 0
        let rowH = titleH + pieceH + captionH + gap
        let size = NSSize(width: gap + 2 * (stripW + gap), height: gap + CGFloat(rows.count) * rowH)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ink = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        (dark ? NSColor(white: 0.04, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink]
        let caption: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ink]
        let ctx = NSGraphicsContext.current!.cgContext
        for (r, row) in rows.enumerated() {
            let top = size.height - gap - CGFloat(r) * rowH
            for (c, strip) in row.enumerated() {
                var x = gap + CGFloat(c) * (stripW + gap)
                (strip.title as NSString).draw(at: NSPoint(x: x, y: top - titleH + 6), withAttributes: title)
                for piece in strip.pieces {
                    let w = CGFloat(piece.image.width) / scale, h = CGFloat(piece.image.height) / scale
                    let y = top - titleH - h
                    ctx.draw(piece.image, in: CGRect(x: x, y: y, width: w, height: h))
                    (piece.caption as NSString).draw(at: NSPoint(x: x, y: y - captionH + 2), withAttributes: caption)
                    x += w + gap
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
