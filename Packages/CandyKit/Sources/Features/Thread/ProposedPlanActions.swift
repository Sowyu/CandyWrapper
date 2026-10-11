import AppKit
import DesignSystem

/// The proposed plan's text helpers (apps/web/src/proposedPlan.ts, packages/shared/src/proposedPlanText.ts,
/// packages/shared/src/String.ts).
public enum ProposedPlanText {
    /// `proposedPlanTitle`: the first Markdown heading, or nil.
    public static func title(_ markdown: String) -> String? {
        let heading = /(?m)^\s{0,3}#{1,6}\s+(.+)$/
        guard let match = markdown.firstMatch(of: heading) else { return nil }
        let title = String(match.1).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// `stripDisplayedPlanMarkdown`: the plan without its title heading and a leading "Summary" heading.
    public static func displayed(_ markdown: String) -> String {
        var lines = markdown.replacing(/\s+$/, with: "").components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if let first = lines.first, first.contains(/^\s{0,3}#{1,6}\s+/) { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if let first = lines.first, let m = first.firstMatch(of: /^\s{0,3}#{1,6}\s+(.+)$/),
           m.1.trimmingCharacters(in: .whitespaces).lowercased() == "summary" {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }

    /// `buildCollapsedProposedPlanPreviewMarkdown` with `maxLines: 10` (ProposedPlanCard.tsx:83): the first
    /// visible lines (blank lines ride along without counting), then "..." when more follows.
    public static func collapsedPreview(_ markdown: String, maxLines: Int = 10) -> String {
        let lines = displayed(markdown).replacing(/\s+$/, with: "").components(separatedBy: "\n")
            .map { $0.replacing(/\s+$/, with: "") }
        var preview: [String] = []
        var visible = 0, more = false
        for line in lines {
            let isVisible = !line.trimmingCharacters(in: .whitespaces).isEmpty
            if isVisible && visible >= maxLines { more = true; break }
            preview.append(line)
            if isVisible { visible += 1 }
        }
        while preview.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { preview.removeLast() }
        if preview.isEmpty { return title(markdown) ?? "Plan preview unavailable." }
        if more { preview += ["", "..."] }
        return preview.joined(separator: "\n")
    }

    /// `buildProposedPlanMarkdownFilename`.
    public static func filename(_ markdown: String) -> String {
        var s = (title(markdown) ?? "plan").lowercased()
        s = s.replacing(/[`'".,!?()\[\]{}]+/, with: "")
        s = s.replacing(/[^a-z0-9]+/, with: "-")
        s = s.replacing(/^-+|-+$/, with: "")
        return (s.isEmpty ? "plan" : s) + ".md"
    }

    /// `normalizePlanMarkdownForExport`.
    public static func export(_ markdown: String) -> String { markdown.replacing(/\s+$/, with: "") + "\n" }

    /// `buildPlanImplementationPrompt`.
    public static func implementationPrompt(_ markdown: String) -> String {
        "PLEASE IMPLEMENT THIS PLAN:\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `truncate(buildPlanImplementationThreadTitle(...))`: 50 characters, then "...".
    public static func implementationThreadTitle(_ markdown: String) -> String {
        let full = title(markdown).map { "Implement " + $0 } ?? "Implement plan"
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let utf16 = Array(trimmed.utf16)
        guard utf16.count > 50 else { return trimmed }
        return (String(utf16CodeUnits: utf16, count: 50)) + "..."
    }
}

/// The plan card's "Save plan to workspace" dialog (ProposedPlanCard.tsx:244-283): `max-w-xl`, the
/// Workspace path field seeded with the download name, Cancel and Save ("Saving..." while it writes).
@MainActor
public enum ProposedPlanSaveDialog {
    /// `save` writes the relative path and returns nil, or the error to toast; the dialog stays open on failure.
    @discardableResult
    public static func present(in window: NSWindow, workspaceRoot: String, filename: String,
                               save: @escaping @MainActor (String) async -> Bool, emptyPath: @escaping @MainActor () -> Void) -> ModalHost {
        let dialog = DialogView(title: "Save plan to workspace", message: "Enter a path relative to \(workspaceRoot).")
        dialog.maxWidth = 576
        let form = ProposedPlanSaveForm(filename: filename)
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
        let commit = ButtonView("Save", size: .sm)
        dialog.footerButtons = [cancel, commit]
        let host = ModalHost.present(dialog, in: window)
        var saving = false
        func setSaving(_ on: Bool) {
            saving = on
            host.allowsUserDismissal = !on
            dialog.showsCloseButton = !on
            cancel.isEnabled = !on
            commit.isEnabled = !on
            commit.title = on ? "Saving..." : "Save"
            form.input.isEnabled = !on
        }
        cancel.action = { [weak host] in if !saving { host?.close() } }
        let submit: @MainActor () -> Void = { [weak host, weak form] in
            guard !saving, let form else { return }
            let path = form.input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { emptyPath(); return }
            setSaving(true)
            Task { @MainActor in
                let ok = await save(path)
                setSaving(false)
                if ok { host?.close() }
            }
        }
        commit.action = submit
        form.input.onSubmit = submit
        DispatchQueue.main.async { [weak form] in
            guard let form else { return }
            form.window?.makeFirstResponder(form.input)
        }
        return host
    }
}

/// `grid gap-1.5`: the `text-xs font-medium` label over the input.
final class ProposedPlanSaveForm: DSView {
    let label = LabelView("Workspace path", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    let input: InputView

    init(filename: String) {
        input = InputView(placeholder: filename, text: filename)
        super.init(frame: .zero)
        label.lineHeight = 16
        input.setAccessibilityLabel("Workspace path")
        addSubview(label)
        addSubview(input)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 16 + 6 + input.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        input.frame = NSRect(x: 0, y: 22, width: bounds.width, height: input.intrinsicContentSize.height)
    }
}
