import AppKit
import DesignSystem
import T3Protocol

/// reviewCommentContext.ts:404-456, partial patches use rendered line indices.
public enum DiffReviewContext {
    public static func anchor(_ record: JSONValue, diff: UnifiedDiff) -> DiffAnnotation? {
        guard let id = record["contextId"]?.stringValue, let path = record["filePath"]?.stringValue,
              let file = diff.files.first(where: { $0.path == path }), let patch = record["diff"]?.stringValue else { return nil }
        let excerpt = UnifiedDiff("diff --git a/context b/context\n--- a/context\n+++ b/context\n" + patch + "\n")
        guard let last = excerpt.lines.last else { return nil }
        let indices = file.hunks.flatMap { Array($0.lines) }
        guard let index = indices.first(where: {
            let line = diff.lines[$0]
            return line.oldNumber == last.oldNumber && line.newNumber == last.newNumber && line.kind == last.kind && diff.text(line) == excerpt.text(last)
        }) else { return nil }
        let line = diff.lines[index]
        return DiffAnnotation(path: path, right: line.newNumber > 0, line: Int(line.newNumber > 0 ? line.newNumber : line.oldNumber), id: id)
    }

    public static func record(diff: UnifiedDiff, path: String, start: Int, end: Int, text: String, section: String, title: String, id: String) -> JSONValue? {
        guard let file = diff.files.first(where: { $0.path == path }) else { return nil }
        let indices = file.hunks.flatMap { Array($0.lines) }
        guard let a = indices.firstIndex(of: start), let b = indices.firstIndex(of: end) else { return nil }
        let lower = min(a, b), upper = max(a, b)
        let lines = indices[lower...upper].map { diff.lines[$0] }
        func range(_ right: Bool) -> (Int32, Int) {
            let values = lines.map { right ? $0.newNumber : $0.oldNumber }.filter { $0 > 0 }
            return (values.first ?? 0, values.count)
        }
        let old = range(false), new = range(true)
        let first = lines[0], last = lines[lines.count - 1]
        let marker = lines.allSatisfy { $0.kind == first.kind } ? first.kind == .addition ? "+" : first.kind == .deletion ? "-" : "" : ""
        let firstNumber = first.newNumber > 0 ? first.newNumber : first.oldNumber
        let lastNumber = last.newNumber > 0 ? last.newNumber : last.oldNumber
        let label = firstNumber == lastNumber ? "\(marker)\(firstNumber)" : "\(marker)\(firstNumber) to \(marker)\(lastNumber)"
        let base = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
        let chipRange = marker.isEmpty ? label : "L\(firstNumber)" + (firstNumber == lastNumber ? "" : " to L\(lastNumber)") + (marker == "-" ? " (before)" : "")
        let patch = (["@@ -\(old.0),\(old.1) +\(new.0),\(new.1) @@"] + lines.map {
            ($0.kind == .addition ? "+" : $0.kind == .deletion ? "-" : " ") + diff.text($0)
        }).joined(separator: "\n")
        return .object(["version": .number(1), "contextId": .string(ComposerContext.kindScopedId("review-comment", id)),
            "kind": .string("review-comment"), "label": .string(ComposerContext.sanitizeLabel("\(base) \(chipRange)", kind: "review-comment")),
            "sectionId": .string(section), "sectionTitle": .string(title), "filePath": .string(path),
            "startIndex": .number(Double(lower)), "endIndex": .number(Double(upper)), "rangeLabel": .string(label),
            "text": .string(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16000))),
            "diff": .string(String(patch.prefix(32000))), "fenceLanguage": .string("diff")])
    }
}

/// DiffCommentAnnotation.tsx:100-145. Uses the existing line annotation layout.
final class DiffReviewAnnotationView: DSView, DiffAnnotationContent {
    let editor = TextareaView(placeholder: "Add a comment…", size: .sm)
    let submit = ButtonView("Comment", size: .xs)
    let cancel = ButtonView("Cancel", variant: .ghostMuted, size: .xs)
    private let hint = LabelView("⌘/Ctrl Enter to send", font: DSFont.ui(10), color: Themed.color(\.mutedForeground, 0.7))
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        [editor, submit, cancel, hint].forEach(addSubview)
        submit.isEnabled = false
        editor.onChange = { [weak self] text in self?.submit.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        submit.action = { [weak self] in guard let self else { return }; self.onSubmit?(self.editor.text) }
        cancel.action = { [weak self] in self?.onCancel?() }
        editor.onCommand = { [weak self] command in
            if command == #selector(NSResponder.cancelOperation(_:)) { self?.onCancel?(); return true }
            if command == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.intersection([.command, .control]).isEmpty == false {
                if self?.submit.isEnabled == true { self?.submit.action?() }; return true
            }
            return false
        }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 114) }
    func height(forWidth width: CGFloat) -> CGFloat { 114 }
    override func layout() {
        super.layout()
        editor.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - 24), height: 68)
        hint.frame = NSRect(x: 12, y: 86, width: max(0, bounds.width - 176), height: 16)
        let submitWidth = submit.intrinsicContentSize.width, cancelWidth = cancel.intrinsicContentSize.width
        submit.frame = NSRect(x: bounds.width - 12 - submitWidth, y: 82, width: submitWidth, height: 24)
        cancel.frame = NSRect(x: submit.frame.minX - 4 - cancelWidth, y: 82, width: cancelWidth, height: 24)
    }
}

/// DiffCommentAnnotation.tsx:68-97. Editing is also available from the card's context menu.
final class DiffReviewCommentCardView: DSView, DiffAnnotationContent, FocusWithinObserver {
    private let message: TextBlockView
    private let icon = IconView(name: .messageCircle, size: 14, strokeColor: Themed.color(\.primary, 0.7))
    private let remove = ButtonView(nil, icon: .trash2, variant: .ghostMuted, size: .iconXs)
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    init(text: String) {
        message = TextBlockView(text, font: DSFont.ui(14))
        super.init(frame: .zero)
        [message, icon, remove].forEach(addSubview)
        remove.setAccessibilityLabel("Delete comment")
        remove.action = { [weak self] in self?.onDelete?() }
        remove.alphaValue = 0
        setAccessibilityLabel(text)
    }
    private var hover: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hover = area
    }
    // `opacity-0 transition-opacity group-hover/comment:opacity-100 focus-within:opacity-100` (DiffCommentAnnotation.tsx:70).
    private var hovered = false { didSet { HoverReveal.fade([remove], visible: hovered || focusWithin) } }
    private var focusWithin = false { didSet { HoverReveal.fade([remove], visible: hovered || focusWithin) } }
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onEdit?() } }
    override func rightMouseDown(with event: NSEvent) {
        var edit = MenuItem("Edit comment"); edit.action = { [weak self] in self?.onEdit?() }
        var delete = MenuItem("Delete comment"); delete.action = { [weak self] in self?.onDelete?() }
        MenuPopupView.show(onEdit == nil ? [delete] : [edit, delete], from: self, placement: .dropdown)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let rect = (message.text as NSString).boundingRect(with: NSSize(width: max(1, width - 76), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: DSFont.ui(14)])
        return max(40, ceil(rect.height) + 20)
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: 12, width: 14, height: 14)
        message.frame = NSRect(x: 38, y: 10, width: max(0, bounds.width - 76), height: bounds.height - 20)
        remove.frame = NSRect(x: bounds.width - 32, y: 6, width: 24, height: 24)
    }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        Themed.color(\.primary, 0.045).setFill(); bounds.fill()
        Themed.color(\.primary, 0.55).setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}
