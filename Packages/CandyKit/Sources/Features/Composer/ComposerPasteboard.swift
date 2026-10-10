import AppKit

/// A file handed to the composer by the picker, a drop or a paste.
public struct ComposerIncomingFile: Sendable {
    public var url: URL
    public var name: String
    public var mimeType: String
    public init(url: URL, name: String? = nil, mimeType: String? = nil) {
        self.url = url
        self.name = name ?? (url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent)
        self.mimeType = mimeType ?? ComposerAttachmentRules.mimeType(for: url)
    }
}

public enum ComposerPasteboard {
    /// Files on a pasteboard: file URLs first, else raw image data (a copied screenshot) written
    /// to a PNG in `tempDir` named `image.png`, as Chromium names a pasted image.
    public static func files(_ pboard: NSPasteboard, tempDir: URL) -> [ComposerIncomingFile] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map { ComposerIncomingFile(url: $0) } }
        let png = pboard.data(forType: .png) ?? pboard.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        guard let png else { return [] }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? png.write(to: url)) != nil else { return [] }
        return [ComposerIncomingFile(url: url, name: "image.png", mimeType: "image/png")]
    }

    /// True when the drag carries files.
    static func hasFiles(_ pboard: NSPasteboard) -> Bool {
        pboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}

/// Files dragged over the composer (ChatComposer.tsx `onDrop`, `isDragOverComposer`): the
/// surface lights up while they hover and takes them on drop.
@MainActor
final class ComposerFileDrop {
    var onHighlight: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Void)?

    static func hasFiles(_ info: any NSDraggingInfo) -> Bool { ComposerPasteboard.hasFiles(info.draggingPasteboard) }

    func entered(_ info: any NSDraggingInfo) -> NSDragOperation {
        onHighlight?(true)
        return .copy
    }

    func exited() { onHighlight?(false) }

    func perform(_ info: any NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
}
