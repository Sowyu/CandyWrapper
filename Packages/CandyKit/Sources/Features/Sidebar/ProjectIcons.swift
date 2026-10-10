import AppKit
import ImageIO
import T3Protocol

/// The slice of a project that decides its icon (ProjectFavicon.tsx `ProjectFaviconProject`).
public struct ProjectIconSource: Hashable, Sendable {
    /// `projectIcon`, the user's chosen icon (contracts project.ts `ProjectIconOverride`).
    public enum Override: Hashable, Sendable {
        case monogram(text: String, color: String)
        case emoji(String)
        case lucide(name: String, color: String)
    }

    public var title: String
    public var workspaceRoot: String
    public var faviconPath: String?
    public var override: Override?

    public init(title: String, workspaceRoot: String, faviconPath: String? = nil, override: Override? = nil) {
        self.title = title; self.workspaceRoot = workspaceRoot; self.faviconPath = faviconPath; self.override = override
    }

    public init(_ project: ProjectShell) {
        self.init(title: project.title, workspaceRoot: project.workspaceRoot, faviconPath: project.faviconPath,
                  override: Self.override(project.projectIcon))
    }

    /// `ReceivedProjectIcon`: unknown kinds mean no override; a lucide icon carrying `monogramText` or
    /// `monogram` is a monogram from an older server.
    static func override(_ json: JSONValue?) -> Override? {
        guard let o = json?.objectValue, case .string(let kind)? = o["kind"] else { return nil }
        func string(_ key: String) -> String? { if case .string(let s)? = o[key] { s } else { nil } }
        let color = string("color") ?? "gray"
        switch kind {
        case "monogram": return string("text").map { .monogram(text: $0, color: color) }
        case "emoji": return string("emoji").map(Override.emoji)
        case "lucide":
            if let text = string("monogramText") ?? string("monogram") { return .monogram(text: text, color: color) }
            return string("name").map { .lucide(name: $0, color: color) }
        default: return nil
        }
    }
}

/// Project icons found in each project's files (T3's `assets.createUrl` with a `project-favicon` resource,
/// then the signed URL; client-runtime state/assets.ts `createProjectFaviconUrlAtomFamily`). Views ask
/// for an image and draw the monogram until one arrives, as T3 does while its image loads.
///
/// Memory: each icon is decoded off the main thread straight to 32px (16pt at 2x, the largest size T3
/// draws it), so an icon costs 4 KB, and the store keeps only those small bitmaps.
// ponytail: memory only, no disk cache like T3's localStorage data URLs; icons show once the shell connects.
// Add a disk cache if cold launches show monograms first for long.
@MainActor
public final class ProjectIconStore {
    public static let shared = ProjectIconStore()
    public static let didChange = Notification.Name("ProjectIconStore.didChange")

    /// Fetches the icon's bytes for a workspace root and optional `faviconPath`. Returns nil when the
    /// server reports no icon (the `project-favicon-missing` marker). Throws on any failure.
    public typealias Loader = @Sendable (_ cwd: String, _ faviconPath: String?) async throws -> Data?

    /// Set by the app when a shell connects; changing it drops every cached icon.
    public var loader: Loader? {
        didSet { entries.removeAll(); generation += 1; NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    struct Key: Hashable { var cwd: String; var path: String? }
    enum State { case loading, missing(Date), image(CGImage, gray: CGImage?) }

    /// Pixel size icons decode to.
    nonisolated static let pixels = 32
    /// How long a missing or failed icon is believed before asking again: T3's asset URL stale time.
    static let recheck: TimeInterval = 5 * 60

    private var entries: [Key: State] = [:]
    private var generation = 0

    /// The decoded icon, or nil while loading or when the project has none. Starts a load on first ask.
    public func image(for source: ProjectIconSource, grayscale: Bool = false) -> CGImage? {
        guard source.override == nil else { return nil }
        let key = Key(cwd: source.workspaceRoot, path: source.faviconPath)
        switch entries[key] {
        case .image(let image, let gray):
            guard grayscale else { return image }
            if let gray { return gray }
            let made = Self.grayscale(image)
            entries[key] = .image(image, gray: made)
            return made
        case .loading: return nil
        case .missing(let at) where Date().timeIntervalSince(at) < Self.recheck: return nil
        case .missing, nil: load(key)
        }
        return nil
    }

    private func load(_ key: Key) {
        guard let loader else { return }
        entries[key] = .loading
        let generation = generation
        Task.detached(priority: .utility) {
            let image: CGImage?
            do { image = try await loader(key.cwd, key.path).flatMap(Self.decode) } catch { image = nil }
            await MainActor.run {
                let store = ProjectIconStore.shared
                guard store.generation == generation else { return }
                store.entries[key] = image.map { .image($0, gray: nil) } ?? .missing(Date())
                if image != nil { NotificationCenter.default.post(name: Self.didChange, object: store) }
            }
        }
    }

    /// Decodes at icon size: ImageIO thumbnails for bitmaps and ICO, AppKit for SVG. `object-contain` in a square.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) {
            return fit(thumb)
        }
        // SVG: AppKit renders it (NSSVGImageRep).
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let ctx = context() else { return nil }
        let scale = CGFloat(pixels) / max(image.size.width, image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: (CGFloat(pixels) - w) / 2, y: (CGFloat(pixels) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    nonisolated private static func context() -> CGContext? {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Centers a thumbnail in a square bitmap, so drawing never needs the aspect ratio.
    nonisolated private static func fit(_ image: CGImage) -> CGImage? {
        if image.width == pixels, image.height == pixels { return image }
        guard let ctx = context() else { return nil }
        ctx.interpolationQuality = .high
        let scale = min(CGFloat(pixels) / CGFloat(image.width), CGFloat(pixels) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(pixels) - w) / 2, y: (CGFloat(pixels) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// CSS `grayscale(1)`: luminance with the Rec. 709 weights, alpha kept.
    nonisolated static func grayscale(_ image: CGImage) -> CGImage? {
        guard let ctx = context(), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let p = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        for i in stride(from: 0, to: pixels * pixels * 4, by: 4) {
            let y = 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2])
            let v = UInt8(min(255, y.rounded()))
            p[i] = v; p[i + 1] = v; p[i + 2] = v
        }
        return ctx.makeImage()
    }
}
