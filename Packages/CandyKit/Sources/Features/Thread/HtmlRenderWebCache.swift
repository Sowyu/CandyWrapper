import AppKit
import WebKit

/// A shown HTML chat shares WebKit's ephemeral HTTP cache and purgeable pixels through scroll transitions.
/// Offscreen documents release their browsing contexts. Hiding the chat discards its pixels and shared store.
@MainActor
final class HtmlRenderWebCache {
    struct Key: Hashable {
        var attachmentId: String
        var width: CGFloat
        var height: CGFloat
        var dark: Bool
        var scale: CGFloat

        init(attachmentId: String, size: NSSize, dark: Bool, scale: CGFloat) {
            self.attachmentId = attachmentId
            width = size.width
            height = size.height
            self.dark = dark
            self.scale = scale
        }
    }

    /// Only the access counter changes after creation. Core Graphics can release its immutable provider
    /// on another thread, so both ends of the purgeable access are protected by this lock.
    private final class Pixels: @unchecked Sendable {
        let data: NSPurgeableData
        let cost: Int
        let lock = NSLock()

        init(_ bytes: CFData) {
            cost = CFDataGetLength(bytes)
            data = NSPurgeableData(data: bytes as Data)
            data.endContentAccess()
        }

        func read() -> Data? {
            lock.lock()
            guard data.beginContentAccess() else { lock.unlock(); return nil }
            let pointer = data.mutableBytes
            lock.unlock()
            return Data(bytesNoCopy: pointer, count: cost, deallocator: .custom { [self] _, _ in
                lock.withLock { data.endContentAccess() }
            })
        }

        var discarded: Bool { lock.withLock { data.isContentDiscarded() } }
        func discard() { lock.withLock { data.discardContentIfPossible() } }
    }

    private struct Entry {
        let pixels: Pixels
        let width: Int
        let height: Int
        let rowBytes: Int
        let componentBits: Int
        let pixelBits: Int
        let space: CGColorSpace
        let bitmap: CGBitmapInfo
        let interpolate: Bool
        let intent: CGColorRenderingIntent
        var used: UInt64
    }

    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    private(set) var generation = 0
    private(set) var isActive = false
    init(limit: Int = 32 * 1024 * 1024) { self.limit = limit }

    func contains(_ key: Key) -> Bool {
        guard let entry = entries[key] else { return false }
        return !entry.pixels.discarded
    }

    func image(for key: Key) -> NSImage? {
        guard var entry = entries[key] else { return nil }
        guard let bytes = entry.pixels.read(), let provider = CGDataProvider(data: bytes as CFData) else {
            cost -= entry.pixels.cost
            entries[key] = nil
            return nil
        }
        guard let image = CGImage(width: entry.width, height: entry.height, bitsPerComponent: entry.componentBits, bitsPerPixel: entry.pixelBits,
                                  bytesPerRow: entry.rowBytes, space: entry.space, bitmapInfo: entry.bitmap,
                                  provider: provider, decode: nil, shouldInterpolate: entry.interpolate, intent: entry.intent) else { return nil }
        clock &+= 1
        entry.used = clock
        entries[key] = entry
        return NSImage(cgImage: image, size: NSSize(width: key.width, height: key.height))
    }

    /// Keep ordinary WebKit bitmap pixels losslessly, without PNG encoding or permanently pinning their bytes.
    /// Discarded pixels are a cache miss; the live iframe still loads and supplies a fresh capture.
    func insert(_ image: CGImage, for key: Key, generation: Int) {
        guard isActive, generation == self.generation, image.decode == nil, !image.isMask,
              let space = image.colorSpace, let bytes = image.dataProvider?.data else { return }
        let (size, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, size > 0, size <= limit, CFDataGetLength(bytes) == size else { return }
        if let old = entries.removeValue(forKey: key) { cost -= old.pixels.cost }
        while cost + size > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            cost -= oldest.value.pixels.cost
            entries[oldest.key] = nil
        }
        clock &+= 1
        entries[key] = Entry(pixels: Pixels(bytes), width: image.width, height: image.height, rowBytes: image.bytesPerRow,
                             componentBits: image.bitsPerComponent, pixelBits: image.bitsPerPixel,
                             space: space, bitmap: image.bitmapInfo, interpolate: image.shouldInterpolate,
                             intent: image.renderingIntent, used: clock)
        cost += size
    }

    func discardUnusedPixels() { entries.values.forEach { $0.pixels.discard() } }

    func clear() {
        generation &+= 1
        entries.removeAll()
        cost = 0
    }

    /// Keep WebKit's HTTP cache through gaps between visible rows, without keeping offscreen pages running.
    /// The last shown document lets the ephemeral store go when it hides, as the last live frame did before.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { ThreadWebFrameBudget.retainCache(self) }
        else { clear(); ThreadWebFrameBudget.releaseCache(self) }
    }

    isolated deinit { ThreadWebFrameBudget.releaseCache(self) }
}
