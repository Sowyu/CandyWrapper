import AppKit
import DesignSystem

/// One attached file above the composer's editor (ChatComposer.tsx:7313-7386).
public struct ComposerFileRow: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case uploading(Double)
        case ready
        /// The reason shows as the retry button's tooltip.
        case failed(String)
    }
    public var id: String
    public var name: String
    public var sizeBytes: Int
    public var status: Status
    public init(id: String, name: String, sizeBytes: Int, status: Status) {
        self.id = id; self.name = name; self.sizeBytes = sizeBytes; self.status = status
    }

    /// `formatAttachmentSize` (packages/client-runtime/src/state/attachments.ts:221-225).
    public static func formatSize(_ bytes: Int) -> String {
        bytes >= 1024 * 1024 ? String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) : "\(max(1, Int((Double(bytes) / 1024).rounded(.up)))) KB"
    }

    /// `formatAttachmentUploadProgress`: whole percent, clamped.
    public static func formatProgress(_ p: Double) -> String { "\(Int((max(0, min(1, p.isFinite ? p : 0)) * 100).rounded(.down)))%" }

    /// The trailing label: progress while uploading, else the size.
    public var detail: String {
        if case .uploading(let p) = status { return Self.formatProgress(p) }
        return Self.formatSize(sizeBytes)
    }
}

/// The file list (`mb-3 flex flex-col gap-1`): rows `flex items-center gap-2 py-1 text-sm`, each the
/// pierre file icon, the name, the size or upload progress in `text-xs text-secondary-label`, a
/// ghost `icon-xs` retry after a failed upload and a ghost `icon-xs` remove.
// ponytail: the name doesn't open T3's file preview dialog; add it with the composer's attachments
public final class ComposerFileListView: DSView {
    static let rowHeight: CGFloat = 32, gap: CGFloat = 4, marginBottom: CGFloat = 12

    public var rows: [ComposerFileRow] = [] { didSet { if rows != oldValue { rebuild() } } }
    public var onRemove: ((String) -> Void)?
    public var onRetry: ((String) -> Void)?

    /// Height including the 12pt bottom margin; 0 without files.
    public var preferredHeight: CGFloat {
        rows.isEmpty ? 0 : CGFloat(rows.count) * Self.rowHeight + CGFloat(rows.count - 1) * Self.gap + Self.marginBottom
    }

    private var views: [RowView] = []
    /// Fidelity tests: the reference has a blank box where the pierre sprite would be.
    var hidesIconsForTests = false { didSet { rebuild() } }

    private func rebuild() {
        while views.count > rows.count { views.removeLast().removeFromSuperview() }
        while views.count < rows.count {
            let v = RowView()
            addSubview(v)
            views.append(v)
        }
        for (row, view) in zip(rows, views) {
            view.configure(row)
            view.hidesIcon = hidesIconsForTests
            view.onRemove = { [weak self] in self?.onRemove?(row.id) }
            view.onRetry = { [weak self] in self?.onRetry?(row.id) }
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for (i, v) in views.enumerated() {
            v.frame = NSRect(x: 0, y: CGFloat(i) * (Self.rowHeight + Self.gap), width: bounds.width, height: Self.rowHeight)
        }
    }

    private final class RowView: DSView {
        var onRemove: (() -> Void)?
        var onRetry: (() -> Void)?
        private var icon: IconView?
        private var path = ""
        var hidesIcon = false { didSet { icon?.isHidden = hidesIcon } }
        private let name = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground))
        private let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.secondaryLabel))
        private let retry = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconXs)
        private let remove = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
        private lazy var retryTip = TooltipController.attach(to: retry, text: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // The composer is a backdrop-filter layer: Chromium draws its text without smoothing.
            for l in [name, detail] { l.smoothsFont = false }
            name.lineHeight = 20
            detail.lineHeight = 16
            retry.action = { [weak self] in self?.onRetry?() }
            remove.action = { [weak self] in self?.onRemove?() }
            [name, detail, retry, remove].forEach(addSubview)
        }

        func configure(_ row: ComposerFileRow) {
            if row.name != path {
                path = row.name
                icon?.removeFromSuperview()
                let v = FileTypeIcon.view(for: row.name, size: 16)
                v.isHidden = hidesIcon
                addSubview(v)
                icon = v
            }
            name.text = row.name
            detail.text = row.detail
            retry.setAccessibilityLabel("Retry upload for \(row.name)")
            remove.setAccessibilityLabel("Remove \(row.name)")
            if case .failed(let reason) = row.status {
                retry.isHidden = false
                retryTip.text = reason
            } else {
                retry.isHidden = true
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            var right = bounds.width
            for b in [remove, retry] where !b.isHidden {
                right -= 24
                b.frame = NSRect(x: right, y: (h - 24) / 2, width: 24, height: 24)
                right -= 8
            }
            let dw = ceil(detail.textWidth)
            right += 8
            detail.frame = NSRect(x: right - 8 - dw, y: (h - 16) / 2, width: dw, height: 16)
            icon?.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
            name.frame = NSRect(x: 24, y: (h - 20) / 2, width: max(0, detail.frame.minX - 8 - 24), height: 20)
        }
    }
}
