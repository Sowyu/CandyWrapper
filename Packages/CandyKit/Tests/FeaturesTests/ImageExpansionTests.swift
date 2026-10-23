import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Features

// Keep cache-mutating view checks in the cache suite's serialized lane.
extension AsyncImageCacheTests {
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !open { await withCheckedContinuation { waiters.append($0) } }
        }
        func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }

    func image(in preview: ExpandedImagePreviewView) throws -> AsyncImageView {
        try #require(preview.subviews.flatMap(\.subviews).compactMap { $0 as? AsyncImageView }.first)
    }

    @Test func loadedCoverPixelsShowBeforeTheFullImageFinishes() async throws {
        let window = AsyncImageCacheTests().window(), key = UUID().uuidString
        let thumbnail = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        thumbnail.cacheable = true
        thumbnail.set(key: key, fallbackText: "thumb", loader: AsyncImageCacheTests.loader(.init()))
        window.contentView!.addSubview(thumbnail)
        #expect(await eventually { thumbnail.image != nil })
        MarkdownImages.record(CGSize(width: 1200, height: 1200), for: key)
        let gate = Gate(), full = AsyncImageCacheTests.loader(.init())
        defer { Task { await gate.release() } }
        let item = ExpandedImagePreviewView.Item(key: key, name: "image", cacheable: true, load: { side in
            await gate.wait()
            return await full(side)
        }).withPreview(from: thumbnail)
        AsyncImageView.memory.removeObject(forKey: "\(key)|cover" as NSString)
        AsyncImageView.memory.removeObject(forKey: "\(key)|fit" as NSString)
        let preview = ExpandedImagePreviewView(items: [item], index: 0)
        preview.present(in: window)
        let view = try image(in: preview)
        #expect(view.image === thumbnail.image, "the clicked image must appear in the same synchronous pass")
        #expect(view.fallback.isHidden)
        preview.layoutSubtreeIfNeeded()
        let frame = view.frame
        #expect(frame.width > 64, "source dimensions fit the thumbnail to the viewer")
        await gate.release()
        #expect(await eventually { preview.layoutSubtreeIfNeeded(); return view.loadedSide > 64 })
        #expect(view.frame == frame)
        preview.dismiss(); thumbnail.removeFromSuperview()
    }

    @Test func uncachedWorkspaceImageSharesItsOriginalLoaderAndPixels() async throws {
        let window = AsyncImageCacheTests().window(), calls = AsyncImageCacheTests.Calls(), unused = AsyncImageCacheTests.Calls()
        let pixels = AsyncImageCacheTests.loader(calls)
        let thumbnail = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        thumbnail.cover = false
        thumbnail.set(key: UUID().uuidString, fallbackText: "", loader: pixels)
        window.contentView!.addSubview(thumbnail)
        #expect(await eventually { thumbnail.image != nil })
        let item = ExpandedImagePreviewView.Item(key: thumbnail.key!, name: "workspace image", load: AsyncImageCacheTests.loader(unused))
            .withPreview(from: thumbnail, sharingLoader: true)
        let preview = ExpandedImagePreviewView(items: [item], index: 0)
        preview.present(in: window)
        let view = try image(in: preview)
        #expect(view.image === thumbnail.image)
        #expect(await eventually { view.loadedSide > 64 })
        #expect(calls.all.count >= 2)
        #expect(unused.all.isEmpty, "expansion uses the inline view's existing source loader")
        preview.dismiss(); thumbnail.removeFromSuperview()
    }

    @Test func loadingIsNotReportedAsAnUnavailableFile() async throws {
        let window = AsyncImageCacheTests().window(), gate = Gate()
        defer { Task { await gate.release() } }
        let preview = ExpandedImagePreviewView(items: [.init(key: UUID().uuidString, name: "slow image", load: { _ in
            await gate.wait(); return nil
        })], index: 0)
        preview.present(in: window)
        let view = try image(in: preview)
        #expect(view.image == nil)
        #expect(view.fallback.text == "Loading image…")
        await gate.release()
        #expect(await eventually { view.fallback.text.hasPrefix("Image unavailable.") })
        preview.dismiss()
    }

    @Test func failedUpgradeKeepsTheVisibleThumbnail() async throws {
        let window = AsyncImageCacheTests().window()
        let thumbnail = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        thumbnail.set(key: UUID().uuidString, fallbackText: "", loader: AsyncImageCacheTests.loader(.init()))
        window.contentView!.addSubview(thumbnail)
        #expect(await eventually { thumbnail.image != nil })
        let calls = AsyncImageCacheTests.Calls()
        let item = ExpandedImagePreviewView.Item(key: thumbnail.key!, name: "image", load: { side in calls.record(side); return nil })
            .withPreview(from: thumbnail)
        let preview = ExpandedImagePreviewView(items: [item], index: 0)
        preview.present(in: window)
        let view = try image(in: preview)
        #expect(await eventually { !calls.all.isEmpty })
        #expect(view.image === thumbnail.image)
        #expect(view.fallback.isHidden)
        preview.dismiss(); thumbnail.removeFromSuperview()
    }

    @Test func previewDoesNotRetainHiddenPixels() async {
        let window = AsyncImageCacheTests().window()
        var thumbnail: AsyncImageView? = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        thumbnail!.set(key: UUID().uuidString, fallbackText: "", loader: AsyncImageCacheTests.loader(.init()))
        window.contentView!.addSubview(thumbnail!)
        #expect(await eventually { thumbnail?.image != nil })
        let item = ExpandedImagePreviewView.Item(key: thumbnail!.key!, name: "image", load: { _ in nil })
            .withPreview(from: thumbnail!)
        thumbnail!.set(key: "reused-" + UUID().uuidString, fallbackText: "", loader: nil)
        #expect(item.preview?() == nil, "a reused cell must never supply a different image")
        thumbnail!.removeFromSuperview(); thumbnail = nil
        #expect(item.preview?() == nil)
    }
}

@MainActor
@Suite(.serialized)
struct MarkdownImageDownloadTests {
    func fixture() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-download-\(UUID().uuidString).png")
        let context = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        return file
    }

    @Test func resizingAndExpandingFetchTheSourceOnce() async throws {
        let url = try fixture(), calls = AsyncImageCacheTests.Calls()
        defer { try? FileManager.default.removeItem(at: url) }
        let download = MarkdownImageDownload { calls.record(1); return ImageDownloadFile(url) }
        for side in [64, 1024, 2048] {
            let file = try #require(await download.value())
            let decoded = try #require(await MarkdownImages.decodeFile(file.url, side: side))
            #expect(decoded.image.width > 0)
            #expect(decoded.natural == CGSize(width: 1200, height: 800))
        }
        #expect(calls.all == [1])
    }

    @Test func simultaneousSizesShareTheFetch() async throws {
        let url = try fixture(), calls = AsyncImageCacheTests.Calls(), gate = AsyncImageCacheTests.Gate()
        defer { try? FileManager.default.removeItem(at: url); Task { await gate.release() } }
        let download = MarkdownImageDownload { calls.record(1); await gate.wait(); return ImageDownloadFile(url) }
        let a = Task { await download.value() }, b = Task { await download.value() }
        #expect(await eventually { !calls.all.isEmpty })
        await gate.release()
        let first = try #require(await a.value), second = try #require(await b.value)
        #expect(first === second)
        #expect(calls.all == [1])
    }

    @Test func cancellingOneConsumerKeepsTheSharedFetchAlive() async throws {
        let url = try fixture(), calls = AsyncImageCacheTests.Calls(), gate = AsyncImageCacheTests.Gate()
        defer { try? FileManager.default.removeItem(at: url); Task { await gate.release() } }
        let download = MarkdownImageDownload { calls.record(1); await gate.wait(); return ImageDownloadFile(url) }
        let a = Task { await download.value() }, b = Task { await download.value() }
        #expect(await eventually { !calls.all.isEmpty })
        a.cancel()
        await gate.release()
        #expect(await a.value == nil)
        #expect(await b.value != nil)
        #expect(calls.all == [1])
    }

    @Test func lastCancelledConsumerStopsTheFetch() async {
        let calls = AsyncImageCacheTests.Calls()
        let download = MarkdownImageDownload {
            calls.record(1)
            do { try await Task.sleep(for: .seconds(30)) }
            catch { calls.record(-1) }
            return nil
        }
        let task = Task { await download.value() }
        #expect(await eventually { calls.all == [1] })
        task.cancel()
        #expect(await eventually { calls.all == [1, -1] })
        #expect(await task.value == nil)
    }

    @Test func lastLoaderReleaseRemovesTheDownloadedFile() async throws {
        let url = try fixture()
        weak var released: ImageDownloadFile?
        do {
            let download = MarkdownImageDownload { ImageDownloadFile(url) }
            let file = try #require(await download.value())
            released = file
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(await eventually { released == nil })
        #expect(await eventually { !FileManager.default.fileExists(atPath: url.path) })
    }
}
