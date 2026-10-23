import Foundation

/// A loader owns its downloaded file until its last view lets go of the loader. Resizing and
/// expanding that image read the same bytes; a newly created loader still fetches current bytes.
final class ImageDownloadFile: Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
    deinit {
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

    init(fetch: @escaping Fetch) { self.fetch = fetch }
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
        if users.isEmpty {
            task?.cancel(); task = nil; requestID = nil
        }
    }

    nonisolated static func fetch(_ url: URL) async -> ImageDownloadFile? {
        guard !Task.isCancelled, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        do {
            let (file, response) = try await URLSession.shared.download(from: url)
            // Adopt the temporary file before checking cancellation or HTTP failure, so every exit removes it.
            let downloaded = ImageDownloadFile(file)
            guard !Task.isCancelled, let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            return downloaded
        } catch { return nil }
    }
}
