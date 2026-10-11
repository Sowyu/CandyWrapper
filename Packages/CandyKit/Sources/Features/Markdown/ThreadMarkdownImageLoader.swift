import AppKit

/// Visible Markdown images use the same downsampler as attachment images.
enum ThreadMarkdownImageLoader {
    static func load(_ url: URL, side: Int) async -> CGImage? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        do {
            let (file, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard !Task.isCancelled, let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            return await ComposerImageIO.thumbnail(file, side: min(4096, max(1, side)), cover: false)
        } catch { return nil }
    }
}
