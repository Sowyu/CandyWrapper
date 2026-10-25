import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// Pixels of immutable HTML attachments while their document is shown. A returning row can draw at once,
/// then hand interaction back to its live page. WebKit owns the HTML byte cache, in the shared ephemeral store.
@MainActor
final class HtmlRenderPreviewCache {
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

    private struct Entry {
        var data: Data
        var cost: Int
        var used: UInt64
    }

    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    private(set) var generation = 0
    private(set) var isActive = false
    private var spare: ThreadWebView?
    private var clearing: ThreadWebView?
    private var cleanup: Task<Void, Never>?
    private struct Active { weak var web: ThreadWebView? }
    private var active: [Active] = []

    init(limit: Int = 8 * 1024 * 1024) { self.limit = limit }

    func image(for key: Key) -> NSImage? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.used = clock
        entries[key] = entry
        return NSImage(data: entry.data)
    }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// A capture finishing after hide or Force Reload cannot refill the cache.
    func insert(_ data: Data, for key: Key, generation: Int) {
        guard isActive, generation == self.generation, !data.isEmpty else { return }
        let bytes = data.count
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard bytes <= limit else { return }
        while cost + bytes > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            cost -= oldest.value.cost
            entries[oldest.key] = nil
        }
        clock &+= 1
        entries[key] = Entry(data: data, cost: bytes, used: clock)
        cost += bytes
    }

    func clear() {
        generation &+= 1
        entries.removeAll()
        cost = 0
        discardSpare()
    }

    private func discardSpare() {
        cleanup?.cancel()
        cleanup = nil
        spare?.stopLoading()
        clearing?.navigationDelegate = nil
        clearing?.stopLoading()
        spare = nil
        clearing = nil
    }

    func activated(_ web: ThreadWebView) {
        active.removeAll { $0.web == nil || $0.web === web }
        active.append(Active(web: web))
        // Two visible frames already keep WebKit warm. Keeping an empty third host adds memory needlessly.
        if active.count >= 2 { discardSpare() }
    }

    func takeWebView() -> ThreadWebView? {
        guard isActive else { return nil }
        let web = spare ?? clearing
        spare = nil
        clearing = nil
        if web != nil { cleanup?.cancel(); cleanup = nil }
        return web
    }

    /// One empty host keeps WebKit warm while this pane is shown. Removing its iframe discards the page's
    /// scripts and browsing context without adding whole documents to WebKit's back-forward cache.
    func recycle(_ web: ThreadWebView, reusable: Bool = true) {
        active.removeAll { $0.web == nil || $0.web === web }
        guard isActive, reusable, active.count < 2, spare == nil, clearing == nil else { return }
        spare = web
        cleanup = Task { [weak self, weak web] in
            await Task.yield()
            guard !Task.isCancelled, let self, let web, self.spare === web else { return }
            self.spare = nil
            self.clearing = web
            web.callAsyncJavaScript("document.getElementById('f')?.remove(); return true;", arguments: [:], in: nil,
                                    in: .world(name: "t3-host")) { [weak self, weak web] result in
                guard let self, let web, self.clearing === web else { return }
                self.clearing = nil
                if case .success = result, self.isActive { self.spare = web }
            }
            self.cleanup = nil
        }
    }

    /// Keep WebKit's HTTP cache through gaps between visible rows, without keeping offscreen pages running.
    /// The last shown document lets the ephemeral store go when it hides, as the last live frame did before.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { ThreadWebFrameBudget.retainCache(self) }
        else { clear(); ThreadWebFrameBudget.releaseCache(self) }
    }

    isolated deinit {
        cleanup?.cancel()
        clearing?.navigationDelegate = nil
        clearing?.stopLoading()
        spare?.stopLoading()
        ThreadWebFrameBudget.releaseCache(self)
    }
}

/// Snapshots own immutable pixels. Encode serially away from AppKit and release their WebKit bitmap surfaces.
actor HtmlRenderPreviewEncoder {
    static let shared = HtmlRenderPreviewEncoder()
    struct Pixels: @unchecked Sendable { let image: CGImage }

    func png(_ pixels: Pixels) -> Data? {
        autoreleasepool {
            guard !Task.isCancelled else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, pixels.image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}
