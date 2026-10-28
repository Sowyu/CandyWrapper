import AppKit
import DesignSystem
import Quartz

/// A binary host file uses native Quick Look. The signed URL stays on the host's asset route;
/// the local preview copy and Quick Look view exist only while this pane is visible.
final class NativeFilePreviewView: DSView {
    private let source: URL
    private let name: String
    private let notice = LabelView("Loading file preview…", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var preview: QLPreviewView?
    private var load: Task<Void, Never>?
    private var directory: URL?

    init(source: URL, name: String) {
        self.source = source; self.name = name
        super.init(frame: .zero)
        addSubview(notice)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
    override func viewDidHide() { super.viewDidHide(); close() }

    private func refresh() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { close(); return }
        guard load == nil, preview == nil else { return }
        notice.text = "Loading file preview…"
        notice.isHidden = false
        let source = source
        load = Task { [weak self] in
            do {
                let (temporary, response) = try await URLSession.shared.download(from: source, delegate: PreviewDownloadBudget())
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard !Task.isCancelled, let self else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CocoaError(.fileReadUnknown) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cw-file-preview-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.directory = directory
                let file = directory.appendingPathComponent((name as NSString).lastPathComponent.isEmpty ? "File" : (name as NSString).lastPathComponent)
                try FileManager.default.moveItem(at: temporary, to: file)
                guard let preview = QLPreviewView(frame: bounds, style: .normal) else { throw CocoaError(.fileReadUnknown) }
                preview.autostarts = false
                preview.previewItem = file as NSURL
                self.preview = preview
                addSubview(preview)
                notice.isHidden = true
                load = nil
                needsLayout = true
            } catch {
                guard !Task.isCancelled, let self else { return }
                close()
                notice.text = "No preview available. Save the file to open it in another app."
            }
        }
    }
    private func close() {
        load?.cancel(); load = nil
        preview?.previewItem = nil
        preview?.removeFromSuperview(); preview = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    isolated deinit {
        load?.cancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    override func layout() {
        super.layout()
        preview?.frame = bounds
        notice.frame = NSRect(x: 24, y: max(24, (bounds.height - 36) / 2), width: max(0, bounds.width - 48), height: 36)
    }
}

/// Quick Look needs a local file. Large binaries still have Save without an automatic full download.
private final class PreviewDownloadBudget: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // ponytail: 50 MB Quick Look copies, add streamed previews if larger binaries need them
    private let limit: Int64 = 50 * 1024 * 1024
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
}
