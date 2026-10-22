import AppKit
import CoreGraphics
import ImageIO
import Testing

@testable import DesignSystem

@MainActor
struct IconTests {
    @Test func everyIconParsesWithNonEmptyBounds() throws {
        #expect(IconName.allCases.count > 200)
        for name in IconName.allCases {
            let def = name.definition
            #expect(!def.elements.isEmpty, "\(name) has no elements")
            #expect(def.viewBox.width > 0 && def.viewBox.height > 0, "\(name) viewBox")
            for (i, e) in def.elements.enumerated() {
                do {
                    let path = try e.cgPath()
                    let b = path.boundingBoxOfPath
                    #expect(!b.isNull && !b.isInfinite && (b.width > 0 || b.height > 0), "\(name)[\(i)] empty bounds")
                } catch {
                    Issue.record("\(name)[\(i)] failed to parse: \(error)")
                }
            }
        }
    }

    @Test func pathParserBasics() throws {
        // implicit lineto after moveto, packed arc flags, scientific notation
        #expect(try SVGPath.parse("M0 0 10 0 10 10z").boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
        let arc = try SVGPath.parse("M0 0a5 5 0 0010 0")
        #expect(abs(arc.boundingBoxOfPath.width - 10) < 0.01)
        #expect(abs(arc.boundingBoxOfPath.height - 5) < 0.01)
        #expect(throws: SVGPathError.self) { try SVGPath.parse("L1 1") }
        #expect(throws: SVGPathError.self) { try SVGPath.parse("M1") }
    }

    /// An export tool, not a test: runs only with CW_EXPORT=1. Writes icons.png under `Fidelity.root`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_EXPORT"] != nil, "export tool, set CW_EXPORT=1"))
    func contactSheet() throws {
        let names = IconName.allCases
        let cols = 24, cell = 28.0, scale = 2.0
        let rows = (names.count + cols - 1) / cols
        let w = Double(cols) * cell, h = Double(rows) * cell
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (n, name) in names.enumerated() {
            let view = IconView(name: name, size: 16, strokeColor: .black)
            view.layoutSubtreeIfNeeded()
            let x = Double(n % cols) * cell + (cell - 16) / 2
            let y = h - Double(n / cols + 1) * cell + (cell - 16) / 2
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            view.layer?.render(in: ctx)
            ctx.restoreGState()
        }
        let image = try #require(ctx.makeImage())
        try FileManager.default.createDirectory(at: Fidelity.root, withIntermediateDirectories: true)
        let url = Fidelity.root.appendingPathComponent("icons.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        print("icon contact sheet:", url.path)
    }
}
