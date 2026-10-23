import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Features

struct ImageDecodeTests {
    @Test func panoramaDecodeHasABoundedPixelSide() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-decode-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try #require(CGContext(data: nil, width: 8000, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        let key = UUID().uuidString
        let cover = try #require(await ComposerImageIO.thumbnail(file, side: 64, cover: true, measurementKey: key))
        #expect(await MarkdownImages.sizes[key] == CGSize(width: 8000, height: 80))
        #expect(cover.width <= 4096)
        let fitted = try #require(await ComposerImageIO.thumbnail(file, side: 256, cover: false))
        #expect(fitted.width == 256)
        #expect(fitted.height > 0)
    }

    final class Activity: @unchecked Sendable {
        let lock = NSLock()
        private var active = 0
        private var peak = 0
        private var mainThread = false
        func decode() -> Int {
            lock.withLock { active += 1; peak = max(peak, active); mainThread = mainThread || Thread.isMainThread }
            Thread.sleep(forTimeInterval: 0.005)
            lock.withLock { active -= 1 }
            return 1
        }
        var maximum: Int { lock.withLock { peak } }
        var usedMainThread: Bool { lock.withLock { mainThread } }
    }

    @Test func galleryDecodesStayOffMainWithoutMultiplyingPeakMemory() async {
        let activity = Activity()
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<16 { group.addTask { await ImageDecodeWorker.shared.run { activity.decode() } } }
            for await result in group { #expect(result == 1) }
        }
        #expect(activity.maximum == 1)
        #expect(!activity.usedMainThread)
    }

    @Test func cancelledRequestsSkipImageIO() async {
        let activity = Activity()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ImageDecodeWorker.shared.run { activity.decode() }
        }
        #expect(await task.value == nil)
        #expect(activity.maximum == 0)
    }
}
