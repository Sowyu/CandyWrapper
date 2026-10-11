import AppKit
import DesignSystem

/// AttachmentFilePreview.tsx:58-158. Reuses the file renderer, reads the captured
/// attachment independently of workspace paths, and releases it when dismissed.
// ponytail: draft attachments only; add sent/question sources and Copy with attachment preview parity.
public final class ComposerAttachmentPreview: DSView {
    private let surface = FileSurfaceView()
    private var load: Task<Void, Never>?
    private let file: URL
    private let sizeBytes: Int
    public init(name: String, file: URL, sizeBytes: Int) {
        self.file = file; self.sizeBytes = sizeBytes
        super.init(frame: .zero)
        addSubview(surface)
        surface.attachmentMode = true
        surface.projectName = "Attachments"
        surface.show(path: name, revealLine: nil)
        surface.fetchData = { url in await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value }
        surface.onNeedsReload = { [weak self] in self?.reload() }
        reload()
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: 720, height: 480) }
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
                return try? handle.read(upToCount: 1024 * 1024)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                self.surface.setContent(.failure("The attachment is unavailable or is not UTF-8 text.", attemptedPath: nil, cwd: nil)); return
            }
            self.surface.setContent(.text(text, truncated: sizeBytes > data.count, byteLength: sizeBytes, editable: false))
        }
    }
}
