import AppKit
import DesignSystem

/// `PullRequestMarkdownEditor` (PullRequestMarkdownEditor.tsx:24-152): the box a description or a
/// posted remark is rewritten in. Write and Preview (`space-y-2`), the textarea or the rendered
/// draft in a `rounded-lg border px-3 py-2` box, then Cancel and Save. ⌘Enter saves, Escape
/// cancels. It owns the draft only; the caller sends the request and sets `saving`.
public final class PullRequestMarkdownEditorView: DSView {
    private let modes = ToggleGroupView(variant: .segmented, items: [("Write", nil), ("Preview", nil)], selected: 0)
    public let textarea = TextareaView()
    private let preview = MarkdownView()
    private let previewBox = DSView()
    private let nothing = LabelView("Nothing to preview.", font: DSFont.ui(12))
    private let cancel = ButtonView("Cancel", variant: .ghost, size: .xs)
    private let save = ButtonView("Save", variant: .outline, size: .xs)
    private let allowEmpty: Bool
    private var previewing = false
    public var saving = false { didSet { update() } }
    public var canWrite = true { didSet { update() } }
    public var onSave: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    /// The height changed (preview toggled, text grew); the host relays out.
    public var onResize: (() -> Void)?

    public init(value: String, label: String, placeholder: String? = nil, allowEmpty: Bool = false, cwd: String? = nil) {
        self.allowEmpty = allowEmpty
        super.init(frame: .zero)
        textarea.text = value
        textarea.placeholder = placeholder ?? ""
        textarea.setAccessibilityLabel(label)
        preview.cwd = cwd
        nothing.lineHeight = 16
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 8
        previewBox.layer?.borderWidth = 1
        previewBox.addSubview(preview)
        previewBox.addSubview(nothing)
        modes.setAccessibilityLabel("Markdown editor mode")
        [modes, textarea, previewBox, cancel, save].forEach(addSubview)
        modes.onChange = { [weak self] i in
            guard let self else { return }
            guard let i else { self.modes.selectedIndex = self.previewing ? 1 : 0; return }
            self.previewing = i == 1
            if self.previewing { self.preview.setMarkdown(self.textarea.text) }
            self.update()
            self.onResize?()
        }
        textarea.onChange = { [weak self] _ in self?.update(); self?.onResize?() }
        textarea.onCommand = { [weak self] sel in
            guard let self else { return false }
            if sel == #selector(NSResponder.cancelOperation(_:)), !self.saving { self.onCancel?(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if self.save.isEnabled { self.onSave?(self.textarea.text) }
                return true
            }
            return false
        }
        cancel.action = { [weak self] in self?.onCancel?() }
        save.action = { [weak self] in
            guard let self, self.save.isEnabled else { return }
            self.onSave?(self.textarea.text)
        }
        update()
    }

    public func focus() { window?.makeFirstResponder(textarea) }

    private var empty: Bool { textarea.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func update() {
        textarea.isHidden = previewing
        previewBox.isHidden = !previewing
        nothing.isHidden = !empty
        preview.isHidden = empty
        modes.items.forEach { $0.isEnabled = !saving }
        textarea.isEnabled = !saving
        cancel.isEnabled = !saving
        save.isEnabled = canWrite && !saving && (!empty || allowEmpty)
        save.title = saving ? "Saving..." : "Save"
        needsLayout = true
    }

    private func bodyHeight(_ width: CGFloat) -> CGFloat {
        if previewing { return 8 + (empty ? 16 : preview.height(forWidth: width - 24 - 2)) + 8 + 2 }
        textarea.frame.size.width = width
        return textarea.intrinsicContentSize.height
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 28 + 8 + bodyHeight(width) + 8 + 24 }

    public override func layout() {
        super.layout()
        let w = bounds.width
        modes.frame = NSRect(x: 0, y: 0, width: modes.intrinsicContentSize.width, height: 28)
        let bh = bodyHeight(w)
        textarea.frame = NSRect(x: 0, y: 36, width: w, height: bh)
        previewBox.frame = NSRect(x: 0, y: 36, width: w, height: bh)
        preview.frame = NSRect(x: 13, y: 9, width: max(0, w - 26), height: max(0, bh - 18))
        nothing.frame = NSRect(x: 13, y: 9, width: max(0, w - 26), height: 16)
        let y = 36 + bh + 8
        let sw = ceil(save.intrinsicContentSize.width), cw = ceil(cancel.intrinsicContentSize.width)
        save.frame = NSRect(x: w - sw, y: y, width: sw, height: 24)
        cancel.frame = NSRect(x: w - sw - 8 - cw, y: y, width: cw, height: 24)
    }

    public override func updateLayer() {
        previewBox.layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self)
        nothing.color = Themed.color(\.mutedForeground)
    }
}
