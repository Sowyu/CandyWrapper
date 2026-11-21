import CoreGraphics
import Foundation
import ImageIO
import Testing
import T3Protocol
import T3Store
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
        let savedResource = MarkdownImages.signAsset, savedTransfer = MarkdownImages.transfer
        MarkdownImages.signAsset = { resource in
            (URL(string: "http://127.0.0.1:1/\(resource["path"]?.stringValue ?? "x").png")!, nil, nil)
        }
        MarkdownImages.transfer = { _ in
            count.bump()
            try? await Task.sleep(for: delay)
            return Task.isCancelled ? nil : pngFile()
        }
        return { MarkdownImages.signAsset = savedResource; MarkdownImages.transfer = savedTransfer }
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

extension GalleryDownloadTests {
    /// Tool outputs and remote kept copies share the two download slots with reply images.
    @Test func toolOutputDownloadsTakeTheFetchQueue() async {
        let running = Count(), peak = Count()
        let gate = NSLock()
        nonisolated(unsafe) var now = 0
        let savedResource = MarkdownImages.signAsset, savedTransfer = MarkdownImages.transfer
        defer { MarkdownImages.signAsset = savedResource; MarkdownImages.transfer = savedTransfer }
        MarkdownImages.signAsset = { resource in (URL(string: "http://127.0.0.1:1/\(resource["path"]?.stringValue ?? "").png")!, nil, nil) }
        MarkdownImages.transfer = { _ in
            let n = gate.withLock { now += 1; return now }
            while peak.value < n { peak.bump() }
            running.bump()
            try? await Task.sleep(for: .milliseconds(80))
            gate.withLock { now -= 1 }
            return Self.pngFile()
        }
        let loaders = (0..<6).map { _ in
            let resource = Self.resource()
            return MarkdownImages.assetLoader(key: "media-file:" + (resource["path"]?.stringValue ?? ""), resource: resource)
        }
        let images = await withTaskGroup(of: Bool.self) { group in
            for load in loaders { group.addTask { await load(32) != nil } }
            var n = 0
            for await ok in group where ok { n += 1 }
            return n
        }
        #expect(images == 6)
        #expect(running.value == 6)
        #expect(peak.value <= 2, "at most the queue's two transfers at once")
    }
}

extension GalleryDownloadTests {
    /// A remote picture's tile and its kept copy (`keepRemote`) download the file once between them.
    @Test func aTileAndItsKeptCopyShareOneDownload() async throws {
        let count = Count()
        let restore = Self.stub(count)
        defer { restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-keep-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AgentImageCache(root: root)
        let resource = Self.resource()
        let key = "media-file:" + (resource["path"]?.stringValue ?? "")
        let keep = Task { await cache.keepRemote(env: "remote", thread: "t", item: "i", resource: resource) }
        await ThreadImageGalleryTests.pump { count.value == 1 }
        // The gallery opens while the copy is on its way: its tile's loader for the same file.
        let load = MarkdownImages.assetLoader(key: key, resource: resource)
        let image = await load(32)
        #expect(image != nil)
        #expect(await keep.value != nil)
        #expect(count.value == 1, "one transfer for the tile and the kept copy")
        // A kept-copy lookup that starts while the copy is on its way waits for it instead of reading nothing.
        let second = Task { await cache.keepRemote(env: "remote", thread: "t", item: "j", resource: Self.resource()) }
        await ThreadImageGalleryTests.pump { count.value == 2 }
        #expect(await cache.url(env: "remote", thread: "t", item: "j") != nil)
        _ = await second.value
    }

}
