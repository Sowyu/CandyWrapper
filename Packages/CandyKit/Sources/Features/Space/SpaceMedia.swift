import AppKit
import ImageIO
import SpaceModel
import UniformTypeIdentifiers

/// Images outside page blocks: page icons and Files & media cells. Bytes come from the encrypted blob cache through
/// `source` and decode only in memory, at thumbnail size. Views redraw on `didLoad`.
@MainActor
public final class SpaceMedia {
    public static let shared = SpaceMedia()
    public static let didLoad = Notification.Name("SpaceMedia.didLoad")
    /// Enough pixels for a 48pt icon at 2x and a table thumbnail.
    nonisolated static let thumbPixels: CGFloat = 160
    static let imageLimit = 20_000_000
    static let fileLimit = 50_000_000

    /// The app sets this while Space is open. Changing it drops every decoded thumbnail.
    public weak var source: SpaceBlobSource? {
        didSet { if source !== oldValue { thumbs.removeAllObjects(); loading = []; failed = [] } }
    }
    /// ponytail: NSCache evicts under memory pressure only; add a cost limit if icon-heavy spaces grow large.
    private let thumbs = NSCache<NSString, NSImage>()
    private var loading: Set<String> = []
    private var failed: Set<String> = []

    /// The decoded thumbnail, or nil while it loads. A finished load posts `didLoad`.
    func thumbnail(_ blob: BlobReference) -> NSImage? {
        if let image = thumbs.object(forKey: blob.id as NSString) { return image }
        guard blob.mime.hasPrefix("image/"), let source, !failed.contains(blob.id), loading.insert(blob.id).inserted else { return nil }
        Task { @MainActor [weak self] in
            let data = await source.data(for: blob)
            let image = await Task.detached { data.flatMap { SpacePageEditor.decode($0, maxPixels: Self.thumbPixels) } }.value
            guard let self, self.source === source else { return }
            self.loading.remove(blob.id)
            guard let image else { self.failed.insert(blob.id); return }
            self.thumbs.setObject(image, forKey: blob.id as NSString)
            NotificationCenter.default.post(name: Self.didLoad, object: self, userInfo: ["id": blob.id])
        }
        return nil
    }

    /// The full image for the large viewer, decoded at `side` pixels.
    static func loader(_ blob: BlobReference) -> AsyncImageView.Loader {
        { side in await full(blob, side: side) }
    }

    private static func full(_ blob: BlobReference, side: Int) async -> CGImage? {
        guard let data = await shared.source?.data(for: blob) else { return nil }
        return await Task.detached { SpacePageEditor.decode(data, maxPixels: CGFloat(max(side, 256)))?.cgImage(forProposedRect: nil, context: nil, hints: nil) }.value
    }

    /// Opens images in the shared large viewer, starting at `index`.
    static func expand(_ blobs: [BlobReference], index: Int, in window: NSWindow) {
        let images = blobs.filter { $0.mime.hasPrefix("image/") }
        guard !images.isEmpty else { return }
        let start = images.firstIndex(of: blobs[min(index, blobs.count - 1)]) ?? 0
        ExpandedImagePreviewView(items: images.map { .init(key: "space:" + $0.id, name: $0.name, load: loader($0)) }, index: start).present(in: window)
    }

    /// Checks limits, turns SVGs into PNGs and stores each file encrypted. Refused files beep and are skipped.
    func add(_ files: [(data: Data, name: String)]) async -> [BlobReference] {
        guard let source else { return [] }
        var out: [BlobReference] = []
        for file in files {
            let prepared: SpaceImageImport.Prepared
            do { prepared = try await Task.detached { try SpaceImageImport.prepare(file.data, name: file.name) }.value }
            catch { NSSound.beep(); continue }
            guard prepared.data.count <= (prepared.mime.hasPrefix("image/") ? Self.imageLimit : Self.fileLimit) else { NSSound.beep(); continue }
            guard var ref = try? await source.store(prepared.data, name: prepared.name, mime: prepared.mime) else { continue }
            ref.w = prepared.w
            ref.h = prepared.h
            out.append(ref)
        }
        return out
    }

    /// Files from a pasteboard: file URLs first, then image data such as a screenshot or a copied SVG.
    static func files(from pasteboard: NSPasteboard) -> [(data: Data, name: String)] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { url in (try? Data(contentsOf: url)).map { ($0, url.lastPathComponent) } }
        }
        if let svg = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.svg.identifier)) { return [(svg, "Image.svg")] }
        if let png = pasteboard.data(forType: .png) { return [(png, "Image.png")] }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return [(png, "Image.png")]
        }
        return []
    }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType(UTType.svg.identifier)]) != nil
    }

    /// An open panel; `images` limits it to images.
    static func choose(in window: NSWindow, images: Bool, multiple: Bool, _ done: @escaping @MainActor ([(data: Data, name: String)]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        if images { panel.allowedContentTypes = [.image, .svg] }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let files = panel.urls.compactMap { url in (try? Data(contentsOf: url)).map { (data: $0, name: url.lastPathComponent) } }
            MainActor.assumeIsolated { done(files) }
        }
    }
}

/// What an attachment becomes before it's stored. SVGs never reach the blob store as SVG: they're sanitized, drawn
/// once into a PNG and stored as that, so nothing downstream ever parses SVG, runs a script or fetches a resource.
enum SpaceImageImport {
    struct Prepared: Sendable, Equatable {
        var data: Data
        var name: String
        var mime: String
        var w: Int?
        var h: Int?
    }
    enum Failure: Error { case unreadableSVG }

    /// The long edge, in pixels, an SVG is drawn at.
    static let svgPixels = 1024

    static func prepare(_ data: Data, name: String) throws -> Prepared {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "svg" || looksLikeSVG(data) {
            guard let clean = sanitizeSVG(data), let png = rasterize(clean, longEdge: svgPixels) else { throw Failure.unreadableSVG }
            return Prepared(data: png.data, name: name, mime: "image/png", w: png.w, h: png.h)
        }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let rotated = (props[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
            return Prepared(data: data, name: name, mime: mime, w: rotated ? h : w, h: rotated ? w : h)
        }
        // Not decodable as an image: keep it as a plain file.
        return Prepared(data: data, name: name, mime: mime.hasPrefix("image/") ? "application/octet-stream" : mime)
    }

    static func looksLikeSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }

    private static let bannedElements: Set<String> = [
        "script", "foreignobject", "iframe", "object", "embed", "audio", "video", "handler", "listener",
        "set", "animate", "animatemotion", "animatetransform", "animatecolor",
    ]
    /// `url(` that points anywhere but a fragment in the same file.
    private static let externalURL = try! NSRegularExpression(pattern: #"url\(\s*['"]?\s*(?!#)"#, options: .caseInsensitive)
    private static let safeHref = ["#", "data:image/png", "data:image/jpeg", "data:image/gif", "data:image/webp"]

    /// Drops scripts, event handlers, animations, foreign content and anything that could load a resource. Documents
    /// with a DTD are refused outright, so no entity ever expands.
    static func sanitizeSVG(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        let lower = text.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else { return nil }
        guard let doc = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement(), root.localName?.lowercased() == "svg" else { return nil }
        // Processing instructions such as xml-stylesheet can name external files.
        for node in (doc.children ?? []).reversed() where node.kind == .processingInstruction || node.kind == .comment {
            doc.removeChild(at: node.index)
        }
        clean(root)
        return doc.xmlData(options: [.nodeCompactEmptyElement])
    }

    private static func clean(_ element: XMLElement) {
        for attr in element.attributes ?? [] {
            let name = (attr.localName ?? attr.name ?? "").lowercased()
            let value = (attr.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(value.startIndex..., in: value)
            let drop = name.hasPrefix("on")
                || (name == "href" && !safeHref.contains { value.lowercased().hasPrefix($0) })
                || externalURL.firstMatch(in: value, range: range) != nil
                || value.lowercased().contains("javascript:")
            if drop, let full = attr.name { element.removeAttribute(forName: full) }
        }
        for child in (element.children ?? []).reversed() {
            switch child.kind {
            case .element:
                guard let e = child as? XMLElement else { continue }
                let name = (e.localName ?? "").lowercased()
                let css = name == "style" ? (e.stringValue ?? "") : ""
                let range = NSRange(css.startIndex..., in: css)
                if bannedElements.contains(name) || css.lowercased().contains("@import") || externalURL.firstMatch(in: css, range: range) != nil {
                    element.removeChild(at: child.index)
                } else {
                    clean(e)
                }
            case .processingInstruction, .comment:
                element.removeChild(at: child.index)
            default: break
            }
        }
    }

    /// Draws a sanitized SVG into a PNG with `longEdge` pixels on its long side.
    static func rasterize(_ svg: Data, longEdge: Int) -> (data: Data, w: Int, h: Int)? {
        guard let image = NSImage(data: svg), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(longEdge) / max(image.size.width, image.size.height)
        let w = max(1, Int((image.size.width * scale).rounded())), h = max(1, Int((image.size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, w, h)
    }
}
