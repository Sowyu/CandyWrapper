import AppKit

/// ImageIO can allocate a full source buffer while shrinking a PNG. Decode one image at a time
/// off the UI thread so a gallery does not multiply that transient memory by its image count.
actor ImageDecodeWorker {
    static let shared = ImageDecodeWorker()

    func run<T: Sendable>(_ work: @Sendable () -> T?) -> T? {
        guard !Task.isCancelled else { return nil }
        let result = autoreleasepool(invoking: work)
        return Task.isCancelled ? nil : result
    }
}

/// Shares immutable image work between visible views. The last consumer cancels the loader;
/// completed pixels live only in the bounded, pressure-sensitive cache.
@MainActor
enum ImageDecodeCache {
    final class Cached {
        let image: CGImage
        let side: Int
        init(_ image: CGImage, side: Int) { self.image = image; self.side = side }
    }

    static let memory: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.name = "AsyncImageView.memory"
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    /// The full gallery's tile decodes, kept apart from the timeline's so 80 tiles never push its pictures out. A
    /// tile that scrolls back, or a gallery reopened soon after closing, shows at once. Emptied a minute after the
    /// gallery closes and on memory pressure, so a closed gallery holds nothing for long.
    // ponytail: 64 MB holds about 80 screenshots at a 400px column; raise it if galleries with hundreds reload on scroll
    static let gallery: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.name = "ThreadImageWallView.tiles"
        cache.totalCostLimit = 64 << 20
        return cache
    }()
    /// The pending release; tests await it.
    private(set) static var galleryRelease: Task<Void, Never>?
    private static var pressure: DispatchSourceMemoryPressure?

    /// The gallery opened: keep its decodes, and empty them when memory runs low.
    static func holdGallery() {
        galleryRelease?.cancel(); galleryRelease = nil
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { gallery.removeAllObjects() } }
        source.resume()
        pressure = source
    }

    /// The gallery closed: its decodes go after `delay` unless it opens again first.
    static func releaseGallery(after delay: Duration = .seconds(60)) {
        galleryRelease?.cancel()
        galleryRelease = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            gallery.removeAllObjects()
            galleryRelease = nil
        }
    }

    private final class Request {
        let id = UUID()
        let side: Int
        var users: Set<UUID> = []
        var task: Task<CGImage?, Never>?
        init(side: Int) { self.side = side }
    }
    private static var requests: [String: [Request]] = [:]

    /// A cover decode still contains the full source image. It can fill the fitted viewer while
    /// that viewer requests its sharper fit decode, without treating the cover quality as sufficient.
    static func preview(for key: String) -> CGImage? {
        memory.object(forKey: "\(key)|fit" as NSString)?.image
            ?? memory.object(forKey: "\(key)|cover" as NSString)?.image
    }

    /// Drops one source's decoded pixels, both fits, when its bytes changed.
    static func remove(_ key: String) {
        memory.removeObject(forKey: "\(key)|fit" as NSString)
        memory.removeObject(forKey: "\(key)|cover" as NSString)
    }

    static func clear() {
        memory.removeAllObjects()
        gallery.removeAllObjects()
        for request in requests.values.joined() { request.task?.cancel() }
        requests.removeAll()
    }

    static func store(_ image: CGImage, side: Int, key: String, in memory: NSCache<NSString, Cached> = memory) {
        let key = key as NSString
        guard memory.object(forKey: key).map({ $0.side < side }) ?? true else { return }
        memory.setObject(Cached(image, side: side), forKey: key, cost: image.bytesPerRow * image.height)
    }

    static func load(key: String, side: Int, in memory: NSCache<NSString, Cached> = memory, loader: @escaping AsyncImageView.Loader) async -> Cached? {
        guard !Task.isCancelled else { return nil }
        if let hit = memory.object(forKey: key as NSString), hit.side >= side { return hit }
        let request: Request
        if let active = requests[key]?.filter({ $0.side >= side }).min(by: { $0.side < $1.side }) {
            request = active
        } else {
            request = Request(side: side)
            requests[key, default: []].append(request)
            request.task = Task {
                let image = await loader(side)
                if let image, !Task.isCancelled { store(image, side: side, key: key, in: memory) }
                return Task.isCancelled ? nil : image
            }
        }
        let user = UUID()
        request.users.insert(user)
        let requestID = request.id, requestSide = request.side, task = request.task
        return await withTaskCancellationHandler {
            let image = await task?.value
            release(key: key, request: requestID, user: user)
            guard !Task.isCancelled else { return nil }
            // `clear()` cancelled the shared request under a consumer that still wants it: a cancel is not a failure,
            // or the view would show "Image unavailable" until it is rebuilt.
            if image == nil, task?.isCancelled == true { return await load(key: key, side: side, in: memory, loader: loader) }
            guard let image else { return nil }
            return Cached(image, side: requestSide)
        } onCancel: {
            Task { @MainActor in release(key: key, request: requestID, user: user) }
        }
    }

    private static func release(key: String, request id: UUID, user: UUID) {
        guard let request = requests[key]?.first(where: { $0.id == id }) else { return }
        request.users.remove(user)
        guard request.users.isEmpty else { return }
        request.task?.cancel()
        requests[key]?.removeAll { $0.id == id }
        if requests[key]?.isEmpty == true { requests[key] = nil }
    }
}
