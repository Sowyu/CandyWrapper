import AppKit
import ImageIO
import DesignSystem
import T3Protocol

/// Where a Markdown image's bytes come from (`classifyMarkdownImageSource`, client-runtime/src/markdownImages.ts:34-73).
/// Host paths never load directly: they become signed asset URLs first.
enum MarkdownImageSource: Equatable, Sendable {
    /// http(s), `data:`, `blob:` and protocol-relative sources.
    case direct(String)
    /// An absolute path on the environment's host.
    case workspaceFile(String)
    case blocked

    static func classify(_ value: String, workspaceRoot: String?) -> MarkdownImageSource {
        var source = value.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("<"), source.hasSuffix(">") { source = String(source.dropFirst().dropLast()) }
        if source.isEmpty || source.hasPrefix("#") || source.hasPrefix("?") { return .blocked }
        let lower = source.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("data:") || lower.hasPrefix("blob:") || source.hasPrefix("//") {
            return .direct(source)
        }
        if lower.hasPrefix("file:") {
            guard let parsed = FileLinks.parseLink(source) else { return .blocked }
            return .workspaceFile(FileLinks.stripSlashPrefixedWindowsDrive(parsed.path))
        }
        var path = source
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        path = FileLinks.stripSlashPrefixedWindowsDrive(path.removingPercentEncoding ?? path)
        if path.isEmpty { return .blocked }
        if path.hasPrefix("/") || FileLinks.isWindowsAbsolutePath(path) { return .workspaceFile(path) }
        if path.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil || path.hasPrefix("~/") || path.hasPrefix("~\\") {
            return .blocked
        }
        guard let workspaceRoot, !workspaceRoot.isEmpty else { return .blocked }
        // `joinWorkspacePath`
        let windows = FileLinks.isWindowsAbsolutePath(workspaceRoot)
        var root = workspaceRoot
        while root.hasSuffix("/") || root.hasSuffix("\\") { root.removeLast() }
        var relative = path.replacingOccurrences(of: windows ? "/" : "\\", with: windows ? "\\" : "/")
        while relative.hasPrefix("/") || relative.hasPrefix("\\") { relative.removeFirst() }
        return .workspaceFile(root + (windows ? "\\" : "/") + relative)
    }

    /// The cache key: the file's identity, not the URL that loads it (ChatMarkdown.tsx:1393-1402).
    var key: String {
        switch self {
        case .direct(let uri): uri
        case .workspaceFile(let path): "media-file:" + path
        case .blocked: ""
        }
    }

    /// Workspace media draws in `rounded-lg border border-border/40` (`CHAT_MARKDOWN_WORKSPACE_IMAGE_CLASS_NAME`).
    var framed: Bool { if case .workspaceFile = self { true } else { false } }
}

/// Images in chat Markdown: their natural sizes, so a decoded image takes its own box instead of the 16:9
/// loading slot (ChatMarkdown.tsx:1386-1400, `max-h-[30rem] max-w-[min(100%,30rem)] w-auto h-auto`), and loaders
/// that decode off the main thread at a bounded size.
@MainActor
public enum MarkdownImages {
    /// A signed URL for a host file (`assets.createUrl`, resource `media-file` on the open thread) and the
    /// pixel size the server read from its header. Set by the app; nil without an open thread.
    public static var assetURL: ((_ path: String) async -> (url: URL, size: CGSize?)?)?
    /// Opens a workspace-relative file in the right panel's file viewer ("Open in file viewer").
    public static var openInFileViewer: ((_ relativePath: String) -> Void)?

    /// Natural pixel sizes by source key. Posts `didMeasure` when one arrives.
    // ponytail: grows with every image seen this session (a few bytes each); cap it if threads show thousands of images
    private(set) static var sizes: [String: CGSize] = [:]
    /// Sources that failed to load: their slot shows the unavailable label.
    static var failed: Set<String> = []
    public static let didMeasure = Notification.Name("MarkdownImages.didMeasure")

    static func record(_ size: CGSize, for key: String) {
        guard size.width > 0, size.height > 0, sizes[key] != size else { return }
        sizes[key] = size
        NotificationCenter.default.post(name: didMeasure, object: nil, userInfo: ["key": key])
    }

    /// The image's box: its natural size scaled down to at most 30rem and the message's width, ratio kept.
    /// `border` is added around the picture inside those limits (the workspace frame).
    static func displaySize(natural: CGSize, maxWidth: CGFloat, border: CGFloat) -> CGSize {
        let boxWidth = min(maxWidth, MarkdownStyle.imageMaxWidth)
        let scale = min(1, max(0, boxWidth - 2 * border) / natural.width, (MarkdownStyle.imageMaxWidth - 2 * border) / natural.height)
        return CGSize(width: natural.width * scale + 2 * border, height: natural.height * scale + 2 * border)
    }

    /// Decodes `source` for a pixel side and records its natural size on the way.
    nonisolated static func loader(_ source: MarkdownImageSource) -> AsyncImageView.Loader {
        { side in
            let key = source.key
            let decoded: (image: CGImage, natural: CGSize)?
            switch source {
            case .blocked: decoded = nil
            case .direct(let uri):
                if uri.lowercased().hasPrefix("data:") {
                    decoded = await decodeData(uri, side: side)
                } else if let url = URL(string: uri.hasPrefix("//") ? "https:" + uri : uri) {
                    decoded = await download(url, side: side)
                } else { decoded = nil }
            case .workspaceFile(let path):
                guard let asset = await signedURL(path) else { decoded = nil; break }
                if let size = asset.size { await record(size, for: key) }
                decoded = await download(asset.url, side: side)
            }
            guard let decoded else { return nil }
            await record(decoded.natural, for: key)
            return decoded.image
        }
    }

    static func signedURL(_ path: String) async -> (url: URL, size: CGSize?)? {
        await assetURL?(path)
    }

    nonisolated static func download(_ url: URL, side: Int) async -> (image: CGImage, natural: CGSize)? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        do {
            let (file, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard !Task.isCancelled, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { decode($0, side: side) }
            }.value
        } catch { return nil }
    }

    /// A `data:` URL; Foundation reads base64 and percent-encoded payloads.
    nonisolated static func decodeData(_ uri: String, side: Int) async -> (image: CGImage, natural: CGSize)? {
        await Task.detached(priority: .userInitiated) {
            guard let url = URL(string: uri), let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return decode(source, side: side)
        }.value
    }

    /// A thumbnail whose longer side is at most `side` (and 4096) pixels, orientation applied, plus the natural size.
    nonisolated static func decode(_ source: CGImageSource, side: Int) -> (image: CGImage, natural: CGSize)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: min(4096, max(1, side)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h))
    }

    /// The failed slot's label (`ChatMarkdownMediaUnavailableLabel`, ChatMarkdown.tsx:1345-1357).
    // ponytail: no TriangleAlert icon before the label; add it when the slot draws its own label
    static func unavailableLabel(_ alt: String) -> String { alt.isEmpty ? "Image unavailable" : "Image unavailable · " + alt }
}

/// The authored media location behind an image, for its tooltip and menu (client-runtime/src/mediaReference.ts).
public enum MediaReference: Sendable, Equatable {
    case file(path: String, relativePath: String?)
    case url(String)

    /// `mediaFileReference`: the path relative to the workspace when it lies inside it (compared lexically).
    public static func file(_ path: String, workspaceRoot: String?) -> MediaReference {
        func parts(_ p: String) -> (root: String, segments: [String], windows: Bool)? {
            let windows = FileLinks.isWindowsAbsolutePath(p) || p.hasPrefix("//")
            let normalized = windows ? p.replacingOccurrences(of: "\\", with: "/") : p
            let prefix: String
            if windows {
                guard let match = normalized.range(of: #"^(?:[a-zA-Z]:/|//[^/]+/[^/]+(?:/|$))"#, options: .regularExpression) else { return nil }
                prefix = String(normalized[match])
            } else {
                guard normalized.hasPrefix("/") else { return nil }
                prefix = "/"
            }
            var segments: [String] = []
            for segment in normalized.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false) {
                if segment.isEmpty || segment == "." { continue }
                if segment == ".." { _ = segments.popLast() } else { segments.append(String(segment)) }
            }
            var root = prefix
            if root.hasSuffix("/") { root.removeLast() }
            return (windows ? root.lowercased() : root, segments, windows)
        }
        guard let target = parts(path), let root = workspaceRoot, let workspace = parts(root),
              target.windows == workspace.windows, target.root == workspace.root, target.segments.count > workspace.segments.count,
              zip(workspace.segments, target.segments).allSatisfy({ workspace.windows ? $0.lowercased() == $1.lowercased() : $0 == $1 })
        else { return .file(path: path, relativePath: nil) }
        return .file(path: path, relativePath: target.segments.dropFirst(workspace.segments.count).joined(separator: "/"))
    }

    /// `mediaUrlReference`: only http(s) and protocol-relative URLs; a `data:` image has no address to copy.
    public static func link(_ url: String) -> MediaReference? {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || url.hasPrefix("//") else { return nil }
        return .url(url)
    }

    /// The tooltip: the file path or the URL (MediaActions.tsx `tooltip`).
    public var tooltip: String {
        switch self {
        case .file(let path, _): path
        case .url(let url): url
        }
    }
}

/// External link favicons (ChatMarkdown.tsx:1228-1270 `MarkdownLinkFavicon`): GitHub's mark in the link color,
/// Google's favicon service for public hosts, and lucide's globe when there is no favicon or it failed.
@MainActor
enum MarkdownFavicons {
    enum Face { case brand(IconName), image(CGImage), globe, loading }

    private static var images: [String: CGImage] = [:]
    /// `failedFaviconHosts`: hosts whose favicon failed this session go straight to the globe.
    private static var failed: Set<String> = []
    private static var waiting: [String: [@MainActor () -> Void]] = [:]

    /// The host of an http(s) or protocol-relative link (`resolveExternalWebLinkHost`).
    static func host(_ url: URL) -> String? {
        let raw = url.absoluteString
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || (scheme == nil && raw.hasPrefix("//")) else { return nil }
        let host = url.host ?? URL(string: "https:" + raw)?.host
        return host?.isEmpty == false ? host : nil
    }

    /// What to draw for `host` now. A host not loaded yet starts loading and calls `ready` when it settles.
    static func face(_ host: String, ready: @escaping @MainActor () -> Void) -> Face {
        let lowered = host.lowercased()
        if lowered == "github.com" || lowered.hasSuffix(".github.com") { return .brand(.brandGitHub) }
        if let image = images[lowered] { return .image(image) }
        if failed.contains(lowered) { return .globe }
        guard let url = PreviewURL.faviconURL(for: "https://" + lowered) else { return .globe }
        if waiting[lowered] != nil { waiting[lowered]!.append(ready); return .loading }
        waiting[lowered] = [ready]
        Task {
            // 14px at 2x; Google answers with a 32px PNG.
            let decoded = await MarkdownImages.download(url, side: 32)
            if let image = decoded?.image { images[lowered] = image } else { failed.insert(lowered) }
            for callback in waiting.removeValue(forKey: lowered) ?? [] { callback() }
        }
        return .loading
    }
}
