import AppKit
import DesignSystem
import T3Protocol

/// MessagesTimeline.tsx:2453-2490. Preview and download use attachment bytes, not a workspace path.
final class ThreadSentFileRowView: DSView {
    var onOpen: ((Bool) -> Void)?
    private let label: LabelView
    private let icon: IconView
    private let preview = ControlView()
    private let eye = IconView(name: .eye, size: 16)
    private let download = ButtonView(icon: .download, variant: .ghostMuted, size: .iconXs)
    init(file: JSONValue) {
        let name = file["name"]?.stringValue ?? "Attachment"
        let meta = FileLinkMeta(filePath: name, targetPath: name, workspaceRelativePath: name, basename: name, line: nil, column: nil)
        let (definition, color) = FileChipStyle.icon(for: meta)
        icon = IconView(definition: definition, size: 16, color: color)
        label = LabelView(name, font: DSFont.ui(14))
        label.lineHeight = 20
        super.init(frame: .zero)
        addSubview(preview); [icon, label, eye].forEach(preview.addSubview); addSubview(download)
        preview.setAccessibilityLabel("Preview " + name)
        download.setAccessibilityLabel("Download " + name)
        preview.action = { [weak self] in self?.onOpen?(false) }
        download.action = { [weak self] in self?.onOpen?(true) }
        preview.isEnabled = file["downloadable"]?.boolValue != false
        eye.isHidden = !preview.isEnabled; download.isHidden = !preview.isEnabled
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 24 + ceil(label.textWidth) + (preview.isEnabled ? 52 : 0), height: 28) }
    override func layout() {
        super.layout()
        preview.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - (download.isHidden ? 0 : 28)), height: 28)
        icon.frame = NSRect(x: 0, y: 6, width: 16, height: 16)
        label.frame = NSRect(x: 24, y: 4, width: max(0, preview.bounds.width - 24 - (eye.isHidden ? 0 : 24)), height: 20)
        eye.frame = NSRect(x: max(24, preview.bounds.width - 16), y: 6, width: 16, height: 16)
        download.frame = NSRect(x: max(0, bounds.width - 24), y: 2, width: 24, height: 24)
    }
}
