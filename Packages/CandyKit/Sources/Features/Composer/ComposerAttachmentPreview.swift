import AppKit
import DesignSystem

/// `AttachmentFilePreview` (AttachmentFilePreview.tsx:58-363) for a file on this Mac: a draft attachment or a
/// question answer's file. Its header holds `Draft › name size` and the icon actions; the body reuses the file
/// renderer. The captured bytes are read independently of workspace paths, at most the first 1 MB, and
/// released when the preview closes.
public final class ComposerAttachmentPreview: DSView {
    public let surface = FileSurfaceView()
    private var load: Task<Void, Never>?
    private let file: URL
    private let sizeBytes: Int

    public init(name: String, file: URL, sizeBytes: Int, origin: String = "Draft",
                onSave: (@MainActor () -> Void)? = nil, onRemove: (@MainActor () -> Void)? = nil, onClose: (@MainActor () -> Void)? = nil) {
        self.file = file; self.sizeBytes = sizeBytes
        super.init(frame: .zero)
        addSubview(surface)
        surface.attachment = .init(origin: origin, name: name, sizeBytes: sizeBytes, inline: false,
                                   onSave: onSave, onRemove: onRemove, onClose: onClose)
        surface.show(path: name, revealLine: nil)
        surface.fetchData = { url in await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value }
        surface.onNeedsReload = { [weak self] in self?.reload() }
        reload()
    }
    public override func layout() { super.layout(); surface.frame = bounds }
    public func close() { load?.cancel(); load = nil; surface.setContent(.loading) }
    private func reload() {
        load?.cancel()
        if surface.wantsAsset { surface.setContent(.asset(file)); return }
        let file = file, sizeBytes = sizeBytes
        surface.setContent(.loading)
        load = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                defer { try? handle.close() }
                return try? handle.read(upToCount: AttachmentPreviewText.maxBytes)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.surface.setContent(AttachmentPreviewText.content(data, sizeBytes: sizeBytes))
        }
    }

    /// The dialog around it (ChatComposer.tsx:7399-7434): `max-w-4xl`, `h-[min(85vh,52rem)]`, no close button,
    /// nothing but the preview.
    @discardableResult
    public static func present(_ preview: ComposerAttachmentPreview, in window: NSWindow) -> ModalHost {
        let dialog = DialogView(title: "")
        dialog.maxWidth = 896
        dialog.showsCloseButton = false
        dialog.fillHeight = min(((window.contentView?.bounds.height ?? 800) * 0.85).rounded(.down), 832)
        dialog.fillContent = preview
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak preview, weak dialog] in preview?.close(); dialog?.fillContent = nil }
        return host
    }
}

/// `readFilePreviewResponse` (client-runtime file-preview): the first 1 MB as UTF-8 text, flagged when cut.
public enum AttachmentPreviewText {
    public static let maxBytes = 1024 * 1024

    public static func content(_ data: Data?, sizeBytes: Int) -> FileSurfaceView.Content {
        guard let data else { return .failure("The attachment is unavailable.", attemptedPath: nil, cwd: nil) }
        let truncated = data.count >= maxBytes && (sizeBytes == 0 || sizeBytes > maxBytes)
        var bytes = data.prefix(maxBytes)
        let cut = bytes.count
        // A cut can split a UTF-8 sequence, leaving at most 3 of its bytes; drop that partial tail.
        var text = String(data: bytes, encoding: .utf8)
        while text == nil, truncated, !bytes.isEmpty, cut - bytes.count < 3 {
            bytes = bytes.dropLast()
            text = String(data: bytes, encoding: .utf8)
        }
        guard let text else { return .failure("Could not load this file.", attemptedPath: nil, cwd: nil) }
        return .text(text, truncated: truncated, byteLength: sizeBytes > 0 ? sizeBytes : data.count, editable: false)
    }
}
