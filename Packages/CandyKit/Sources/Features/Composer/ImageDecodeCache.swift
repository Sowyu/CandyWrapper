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

    private final class Request {
        let id = UUID()
        let side: Int
        var users: Set<UUID> = []
        var task: Task<CGImage?, Never>?
        init(side: Int) { self.side = side }
    }
    private static var requests: [String: [Request]] = [:]

    static func clear() {
        memory.removeAllObjects()
        for request in requests.values.joined() { request.task?.cancel() }
        requests.removeAll()
    }

    static func store(_ image: CGImage, side: Int, key: String) {
        let key = key as NSString
        guard memory.object(forKey: key).map({ $0.side < side }) ?? true else { return }
        memory.setObject(Cached(image, side: side), forKey: key, cost: image.bytesPerRow * image.height)
    }

    static func load(key: String, side: Int, loader: @escaping AsyncImageView.Loader) async -> Cached? {
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
                if let image, !Task.isCancelled { store(image, side: side, key: key) }
                return Task.isCancelled ? nil : image
            }
        }
        let user = UUID()
        request.users.insert(user)
        let requestID = request.id, requestSide = request.side, task = request.task
        return await withTaskCancellationHandler {
            let image = await task?.value
            release(key: key, request: requestID, user: user)
            guard !Task.isCancelled, let image else { return nil }
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
