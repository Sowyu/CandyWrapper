import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Features

/// Reply images kept on disk (`MediaDiskCache`), the download queue's order (`MediaFetchQueue`), and the development link throttle.
@MainActor @Suite(.serialized) struct ReplyMediaCacheTests {
    @Test func leastRecentlyUsedGoesFirst() async {
        final class Clock: @unchecked Sendable { var now = 0.0 }
        let clock = Clock()
        let cache = MediaDiskCache(root: ReplyMediaFiles.folder(), capBytes: 2500, now: { clock.now })
        func file(_ bytes: Int) -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reply-media-\(UUID().uuidString)")
            try? Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
        for (i, name) in ["a", "b"].enumerated() {
            clock.now = Double(i)
            await cache.store(name, scope: "env", path: "/\(name)", file: file(1000), revision: nil, etag: nil, natural: nil)
        }
        clock.now = 5
        #expect(await cache.lookup("a") != nil)
        clock.now = 6
        await cache.store("c", scope: "env", path: "/c", file: file(1000), revision: nil, etag: nil, natural: nil)
        #expect(await cache.entry("b") == nil)
        #expect(await cache.entry("a") != nil)
        #expect(await cache.entry("c") != nil)
        #expect(await cache.totalBytes == 2000)
        await cache.clear()
        #expect(await cache.totalBytes == 0)
    }

    @Test func queueServesVisibleThenMostRecent() async {
        let queue = MediaFetchQueue(limit: 1)
        let tag = UUID().uuidString
        let low = "low-\(tag)", recent = "recent-\(tag)", visible = "visible-\(tag)"
        MediaPriority.set(low, visible: false, recency: -500)
        MediaPriority.set(recent, visible: false, recency: -100)
        MediaPriority.set(visible, visible: true, recency: -900)
        defer { [low, recent, visible].forEach(MediaPriority.forget) }
        #expect(await queue.acquire("first"))
        final class Log: @unchecked Sendable { let lock = NSLock(); var keys: [String] = [] }
        let log = Log()
        var waiters: [Task<Void, Never>] = []
        for key in [low, recent, visible] {
            waiters.append(Task {
                guard await queue.acquire(key) else { return }
                log.lock.withLock { log.keys.append(key) }
                await queue.release()
            })
            for _ in 0..<200 where await !queue.queued.contains(key) { try? await Task.sleep(for: .milliseconds(1)) }
        }
        await queue.release()
        for waiter in waiters { await waiter.value }
        #expect(log.lock.withLock { log.keys } == [visible, recent, low])
        #expect(await queue.inFlight == 0)
    }

    /// A burst of requests on free slots: the gather pause hands the slots to the pictures on screen, not to the first
    /// to ask.
    @Test func freeSlotsGoToTheBestRankedOfABurst() async {
        let queue = MediaFetchQueue(limit: 2, gather: .milliseconds(30))
        let tag = UUID().uuidString
        let keys = (0..<4).map { "burst-\($0)-\(tag)" }
        for (i, key) in keys.enumerated() { MediaPriority.set(key, visible: i == 3, recency: Double(i)) }
        defer { keys.forEach(MediaPriority.forget) }
        final class Log: @unchecked Sendable { let lock = NSLock(); var keys: [String] = [] }
        let log = Log()
        let tasks = keys.map { key in Task { if await queue.acquire(key) { log.lock.withLock { log.keys.append(key) } } } }
        for _ in 0..<200 where log.lock.withLock({ log.keys.count }) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(Set(log.lock.withLock { log.keys }) == [keys[3], keys[2]])
        // One slot at a time, so the order of the log is the order of the hand-outs.
        await queue.release()
        for _ in 0..<200 where log.lock.withLock({ log.keys.count }) < 3 { try? await Task.sleep(for: .milliseconds(5)) }
        await queue.release()
        for task in tasks { await task.value }
        #expect(log.lock.withLock { log.keys }.suffix(2) == [keys[1], keys[0]])
        await queue.release(); await queue.release()
        #expect(await queue.inFlight == 0)
    }

    @Test func cancelledWaiterFreesItsPlace() async {
        let queue = MediaFetchQueue(limit: 1)
        #expect(await queue.acquire("a"))
        let waiter = Task { await queue.acquire("b") }
        for _ in 0..<200 where await queue.queued.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(await queue.queued.isEmpty)
        await queue.release()
        #expect(await queue.inFlight == 0)
        #expect(await queue.acquire("c"))
        await queue.release()
    }

    @Test func throttleIsInertWithoutItsVariable() {
        #expect(SlowLink.parse([:]) == nil)
        #expect(SlowLink.parse(["CANDY_SLOW_LINK": "80:5"]) == SlowLink.Link(rtt: 80, mbps: 5))
        #expect(SlowLink.parse(["CANDY_SLOW_LINK": "fast"]) == nil)
        #expect(ProcessInfo.processInfo.environment["CANDY_SLOW_LINK"] != nil || SlowLink.link == nil)
        if SlowLink.link == nil { #expect(SlowLink.reserve(bytes: 10_000_000) == 0) }
    }
}

/// Files for the cache tests.
enum ReplyMediaFiles {
    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reply-media-\(UUID().uuidString)")
    }

    /// A small PNG on disk, `width` by `height`.
    static func png(width: Int = 40, height: Int = 20) -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reply-media-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
}

/// These swap `MarkdownImages.assetURL`, so they run in the suite that already owns those globals: suites run in
/// parallel, and two suites swapping the same stubs answer each other's calls.
extension ImageSigningDeadlockTests {
    @Test func cacheHitSkipsSignAndDownload() async {
        let savedShared = MediaDiskCache.shared, savedAsset = MarkdownImages.assetURL, savedScope = MarkdownImages.cacheScope
        defer { MediaDiskCache.shared = savedShared; MarkdownImages.assetURL = savedAsset; MarkdownImages.cacheScope = savedScope }
        let cache = MediaDiskCache(root: ReplyMediaFiles.folder())
        MediaDiskCache.shared = cache
        let path = "/hit/\(UUID().uuidString).png"
        let id = MediaDiskCache.key(scope: "env", path: path)
        await cache.store(id, scope: "env", path: path, file: ReplyMediaFiles.png(), revision: "r1", etag: nil, natural: CGSize(width: 40, height: 20))
        let signs = ReplyMediaFiles.Counter()
        MarkdownImages.assetURL = { _ in signs.bump(); return nil }
        // Another environment is open, so the kept copy is not checked against the server either.
        MarkdownImages.cacheScope = "other"
        let image = await MarkdownImages.loader(.workspaceFile(path), scope: "env")(40)
        #expect(image?.width == 40)
        #expect(signs.count == 0)
        // The decoded picture is kept as the timeline's thumbnail, and the next view draws from it.
        for _ in 0..<200 where await cache.entry(id)?.thumbSide == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await cache.entry(id)?.thumbSide == 40)
        #expect(await cache.thumbnail(id, side: 40) != nil)
        #expect(await MarkdownImages.loader(.workspaceFile(path), scope: "env")(40)?.width == 40)
        #expect(signs.count == 0)
    }

    @Test func changedFileInvalidatesAndUnchangedStays() async {
        let savedShared = MediaDiskCache.shared, savedAsset = MarkdownImages.assetURL, savedScope = MarkdownImages.cacheScope
        defer { MediaDiskCache.shared = savedShared; MarkdownImages.assetURL = savedAsset; MarkdownImages.cacheScope = savedScope }
        let cache = MediaDiskCache(root: ReplyMediaFiles.folder())
        MediaDiskCache.shared = cache
        MarkdownImages.cacheScope = "env"
        let same = "/same/\(UUID().uuidString).png", changed = "/changed/\(UUID().uuidString).png"
        for path in [same, changed] {
            await cache.store(MediaDiskCache.key(scope: "env", path: path), scope: "env", path: path, file: ReplyMediaFiles.png(), revision: "r1", etag: nil, natural: nil)
        }
        MarkdownImages.assetURL = { path in
            (URL(string: "http://127.0.0.1:1/x.png")!, nil, path == changed ? "r2" : "r1")
        }
        var reloaded: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: MarkdownImages.didChange, object: nil, queue: .main) { note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated { if let key { reloaded.append(key) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for path in [same, changed] {
            #expect(await MarkdownImages.loader(.workspaceFile(path), scope: "env")(40) != nil)
        }
        let changedID = MediaDiskCache.key(scope: "env", path: changed)
        for _ in 0..<400 where reloaded.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(reloaded == ["media-file:" + changed])
        #expect(await cache.entry(changedID) == nil)
        #expect(await cache.entry(MediaDiskCache.key(scope: "env", path: same)) != nil)
    }
}
