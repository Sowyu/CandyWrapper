import CoreGraphics
import Foundation
import ImageIO
import Testing
import T3Protocol
@testable import Features

/// Gallery downloads in the 1.16.0 build restarted from their first byte whenever a tile was rebuilt, and a remote
/// kept copy downloaded the same file a second time.
@MainActor @Suite(.serialized) struct GalleryDownloadTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    /// A small PNG in a temporary file, owned by the returned download file.
    nonisolated static func pngFile() -> ImageDownloadFile? {
        guard let image = GalleryTileLifetimeTests.pixels() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cw-test-" + UUID().uuidString + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ImageDownloadFile(url)
    }

    /// Signs every resource and counts transfers, each taking `delay`.
    static func stub(_ count: Count, delay: Duration = .milliseconds(400)) -> () -> Void {
        let savedResource = MarkdownImages.resourceURL, savedTransfer = MarkdownImages.transfer
        MarkdownImages.resourceURL = { resource in
            (URL(string: "http://127.0.0.1:1/\(resource["path"]?.stringValue ?? "x").png")!, nil, nil)
        }
        MarkdownImages.transfer = { _ in
            count.bump()
            try? await Task.sleep(for: delay)
            return Task.isCancelled ? nil : pngFile()
        }
        return { MarkdownImages.resourceURL = savedResource; MarkdownImages.transfer = savedTransfer }
    }

    static func resource() -> JSONValue {
        .object(["_tag": .string("media-file"), "threadId": .string("t"), "path": .string("/big-" + UUID().uuidString)])
    }

    @Test func aTileRebuiltWithinTheGraceStartsNoSecondTransfer() async throws {
        let count = Count()
        let restore = Self.stub(count)
        defer { restore() }
        let resource = Self.resource()
        let load = MarkdownImages.assetLoader(key: "media-file:" + (resource["path"]?.stringValue ?? ""), resource: resource)
        let first = Task { await load(64) }
        await ThreadImageGalleryTests.pump { count.value == 1 }
        // The tile scrolls out or the list changes: its request is cancelled mid-transfer, and the new tile asks again.
        first.cancel()
        _ = await first.value
        try await Task.sleep(for: .milliseconds(100))
        let image = await load(64)
        #expect(image != nil)
        #expect(count.value == 1, "one transfer, not a restart from the first byte")
    }
}
