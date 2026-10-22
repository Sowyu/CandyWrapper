import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Sent images used to decode again, or stay blurry, after a thread switch: a cell that left its
/// window dropped its pixels and decoded anew, and a cell placed before its frame decoded at 16pt.
@MainActor
@Suite(.serialized)
struct AsyncImageCacheTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var sides: [Int] = []
        func record(_ side: Int) { lock.withLock { sides.append(side) } }
        var all: [Int] { lock.withLock { sides } }
    }

    static func loader(_ calls: Calls) -> AsyncImageView.Loader {
        { side in
            calls.record(side)
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()
        }
    }

    func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = DSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    func waitForImage(_ view: AsyncImageView) async {
        _ = await eventually { view.image != nil }
    }

    /// Thread A, then B, then A again: the rebuilt cell shows A's image in the same pass, with no new decode.
    @Test func switchBackShowsCachedImageAtOnce() async throws {
        AsyncImageView.clearMemory()
        let window = window(), calls = Calls(), key = "switch-back-\(UUID().uuidString)"
        let first = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 101, height: 76))
        first.cacheable = true
        first.set(key: key, fallbackText: "a.png", loader: Self.loader(calls))
        window.contentView!.addSubview(first)
        await waitForImage(first)
        #expect(first.image != nil)
        #expect(calls.all.count == 1)

        first.removeFromSuperview()
        #expect(first.image == nil, "a view outside a window holds no pixels")

        let again = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 101, height: 76))
        again.cacheable = true
        again.set(key: key, fallbackText: "a.png", loader: Self.loader(calls))
        window.contentView!.addSubview(again)
        #expect(again.image != nil, "no fallback flash on the way back")
        #expect(again.fallback.isHidden)
        #expect(calls.all.count == 1, "no second decode")
    }

    /// Without `cacheable` a key decodes again, so workspace files that change on disk show their new bytes.
    @Test func uncachedViewsDecodeAgain() async throws {
        AsyncImageView.clearMemory()
        let window = window(), calls = Calls(), key = "plain-\(UUID().uuidString)"
        for _ in 0..<2 {
            let view = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            view.set(key: key, fallbackText: "", loader: Self.loader(calls))
            window.contentView!.addSubview(view)
            await waitForImage(view)
            view.removeFromSuperview()
        }
        #expect(calls.all.count == 2)
    }

    /// A smaller cached decode shows at once, then a sharp one replaces it.
    @Test func smallerCachedImageIsAPlaceholder() async throws {
        AsyncImageView.clearMemory()
        let window = window(), calls = Calls(), key = "grow-\(UUID().uuidString)"
        let small = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        small.cacheable = true
        small.set(key: key, fallbackText: "", loader: Self.loader(calls))
        window.contentView!.addSubview(small)
        await waitForImage(small)
        let big = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        big.cacheable = true
        big.set(key: key, fallbackText: "", loader: Self.loader(calls))
        window.contentView!.addSubview(big)
        #expect(big.image?.width == small.image?.width)
        _ = await eventually { (big.image?.width ?? 0) >= 200 }
        #expect((big.image?.width ?? 0) >= 200)
        #expect(calls.all.count == 2)
    }

    /// A cell added to its window before its frame waits for the frame instead of decoding at the 16pt floor.
    @Test func decodeWaitsForTheFrame() async throws {
        let window = window(), calls = Calls()
        let view = AsyncImageView()
        view.set(key: "frame-\(UUID().uuidString)", fallbackText: "", loader: Self.loader(calls))
        window.contentView!.addSubview(view)
        // `start` needs a decode side, so no decode can be on its way yet.
        #expect(view.decodeSide == nil)
        #expect(calls.all.isEmpty)
        view.frame = NSRect(x: 0, y: 0, width: 101, height: 76)
        await waitForImage(view)
        let scale = Int(window.backingScaleFactor)
        #expect(calls.all == [101 * scale])
    }

    /// The image grid reserves its 4:3 cells before any image arrives, so the row keeps its height.
    @Test func attachmentGridReservesItsSize() async throws {
        let images: [JSONValue] = (0..<3).map { i in
            .object(["type": .string("image"), "id": .string("reserve-\(i)"), "name": .string("p\(i).jpg"), "mimeType": .string("image/jpeg")])
        }
        let message = ChatMessage(id: MessageId("m"), role: .user, text: "hi", createdAt: "2026-10-14T00:00:00Z", attachments: images)
        let grid = UserMessageAttachmentsView(frame: NSRect(x: 0, y: 0, width: 210, height: 0))
        grid.configure(message, model: nil)
        // Two 101pt columns of 4:3 cells over two rows, gap 8, then the block's 8pt margin.
        let cell = (210 - UserMessageAttachmentsView.gap) / 2 * 3 / 4
        #expect(grid.height(forWidth: 210) == cell * 2 + UserMessageAttachmentsView.gap + 8)
    }
}
