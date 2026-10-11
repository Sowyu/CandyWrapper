import AppKit
import DesignSystem
import T3Protocol

/// reviewCommentContext.ts:404-456, partial patches use rendered line indices.
public enum DiffReviewContext {
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
