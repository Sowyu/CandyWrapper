import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Features

/// Opt-in comparison of independent decodes with immutable-image sharing, on identical pixels.
@MainActor
@Suite(.serialized)
struct ImageRenderingBenchmarks {
    @Test func repeatedGalleryImage() async throws {
        guard ProcessInfo.processInfo.environment["CW_IMAGE_BENCH"] == "1" else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-bench-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try #require(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.red.cgColor, NSColor.blue.cgColor] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 2400, y: 1600), options: [])
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        for shared in [false, true] {
            var times: [Double] = []
            var decodes = 0, bytes = 0
            for _ in 0..<7 {
                AsyncImageView.clearMemory()
                let key = UUID().uuidString, calls = AsyncImageCacheTests.Calls()
                let views = (0..<20).map { _ in AsyncImageView(frame: NSRect(x: 0, y: 0, width: 192, height: 128)) }
                let start = ContinuousClock.now
                for view in views {
                    view.requestedSide = 192
                    view.cover = false
                    view.cacheable = shared
                    view.set(key: key, fallbackText: "", loader: { side in
                        calls.record(side)
                        return await ComposerImageIO.thumbnail(file, side: side, cover: false)
                    })
                    window.contentView!.addSubview(view)
                }
                #expect(await eventually { views.allSatisfy { $0.image != nil } })
                let elapsed = ContinuousClock.now - start
                times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                decodes = calls.all.count
                var seen: Set<ObjectIdentifier> = []
                bytes = views.compactMap(\.image).reduce(0) { total, image in
                    total + (seen.insert(ObjectIdentifier(image)).inserted ? image.bytesPerRow * image.height : 0)
                }
                for view in views { view.removeFromSuperview() }
            }
            times.sort()
            print("IMAGE_BENCH shared=\(shared) median_ms=\(times[3]) min_ms=\(times[0]) max_ms=\(times[6]) decodes=\(decodes) decoded_bytes=\(bytes)")
        }
    }
}
