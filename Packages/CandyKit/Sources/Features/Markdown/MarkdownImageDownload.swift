import Foundation

/// A loader owns its downloaded file until its last view lets go of the loader. Resizing and
/// expanding that image read the same bytes; a newly created loader still fetches current bytes.
/// A file the disk cache keeps (`owned: false`) stays when the loader lets go.
final class ImageDownloadFile: Sendable {
    let url: URL
    let owned: Bool
    init(_ url: URL, owned: Bool = true) { self.url = url; self.owned = owned }
    deinit {
        guard owned else { return }
        let url = url
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }
}

actor MarkdownImageDownload {
    typealias Fetch = @Sendable () async -> ImageDownloadFile?
    private let fetch: Fetch
    private var file: ImageDownloadFile?
    private var task: Task<ImageDownloadFile?, Never>?
    private var requestID: UUID?
    private var users: Set<UUID> = []
    /// How long the fetch outlives its last user. A reply's views leave and rejoin the window while a thread opens;
    /// cancelling at once restarted every download from its first byte.
    private let grace: Duration

    init(grace: Duration = .zero, fetch: @escaping Fetch) { self.grace = grace; self.fetch = fetch }
    deinit { task?.cancel() }

    func value() async -> ImageDownloadFile? {
        guard !Task.isCancelled else { return nil }
        if let file { return file }
        if task == nil {
            let fetch = self.fetch
            requestID = UUID()
            task = Task { await fetch() }
        }
        guard let task, let requestID else { return nil }
        let user = UUID()
        users.insert(user)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.release(user, request: requestID) }
        }
        guard !Task.isCancelled, self.requestID == requestID, users.contains(user) else {
            release(user, request: requestID)
            return nil
        }
        if let result { file = result }
        release(user, request: requestID)
        return result
    }

    private func release(_ user: UUID, request: UUID) {
        guard requestID == request else { return }
        users.remove(user)
        guard users.isEmpty else { return }
        if grace == .zero { cancelIfIdle(request); return }
        let grace = grace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.cancelIfIdle(request)
        }
    }

    private func cancelIfIdle(_ request: UUID) {
        guard requestID == request, users.isEmpty else { return }
        task?.cancel(); task = nil; requestID = nil
    }

    nonisolated static func fetch(_ url: URL) async -> ImageDownloadFile? {
        guard !Task.isCancelled, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        ImageTiming.mark("download", url.lastPathComponent)
        guard let result = await MediaTransfer.shared.download(url) else { return nil }
        // Adopt the temporary file before checking cancellation, so every exit removes it.
        let downloaded = ImageDownloadFile(result.file)
        ImageTiming.mark("downloaded", "\(url.lastPathComponent) \(result.response.expectedContentLength)")
        return Task.isCancelled ? nil : downloaded
    }
}
