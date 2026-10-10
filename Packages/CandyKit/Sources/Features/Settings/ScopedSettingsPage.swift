import AppKit
import DesignSystem
import T3Protocol

extension AlertView: SettingsGroupRow {}

/// A server-backed settings page (`SettingsPageContainer`): the scope sentence, then the body, which the
/// scope boundary's notice replaces when the selection can't be edited (settings.tsx `SettingsScopeBoundary`).
public class ScopedSettingsPage: SettingsPageBase {
    let sentence: SettingsScopeSentenceView
    let boundary = SettingsNoticeView("")
    /// Pages that handle their own unavailable states (Project) skip the boundary.
    var usesBoundary = true

    init(context: SettingsPageContext, sentence showsSentence: Bool = true) {
        sentence = SettingsScopeSentenceView(context: context)
        super.init(context: context)
        sentence.isHidden = !showsSentence
        binder.add { [weak self] in
            guard let self else { return }
            self.sentence.refresh()
            let message = self.usesBoundary ? self.context.scope.boundaryMessage : nil
            self.boundary.isHidden = message == nil
            self.boundary.message = message ?? ""
            for item in self.body { item.isHidden = message != nil || self.hiddenItems.contains(ObjectIdentifier(item)) }
        }
    }

    /// The page's sections under the sentence.
    var body: [NSView & SettingsGroupRow] = [] {
        didSet { items = (sentence.isHidden ? [] : [sentence as NSView & SettingsGroupRow]) + [boundary] + body }
    }

    /// Items a page hides on its own; the boundary binder keeps them hidden.
    private var hiddenItems: Set<ObjectIdentifier> = []
    func setHidden(_ item: NSView & SettingsGroupRow, _ hidden: Bool) {
        if hidden { hiddenItems.insert(ObjectIdentifier(item)) } else { hiddenItems.remove(ObjectIdentifier(item)) }
        item.isHidden = hidden || !boundary.isHidden
    }

    /// A section without a visible header (`SettingsSection hideTitle`): the card alone.
    func headless(_ id: String?, _ rows: [any SettingsGroupRow]) -> SettingsGroupView {
        let g = SettingsGroupView(rows: rows)
        if let id { anchors[id] = g }
        return g
    }
}

/// A line of text inside a settings card (`p className="px-3 py-2 text-base text-muted-foreground sm:px-4 sm:text-sm"`).
final class SettingsGroupNote: DSView, SettingsGroupRow {
    private let text = TextBlockView()
    var message: String { get { text.text } set { text.text = newValue; needsLayout = true } }
    var paddingY: CGFloat = 8

    init(_ message: String, color: NSColor = Themed.color(\.mutedForeground), size: CGFloat = 14) {
        super.init(frame: .zero)
        text.text = message
        text.font = DSFont.ui(size)
        text.lineHeight = size == 14 ? 20 : 16
        text.color = color
        addSubview(text)
    }

    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: max(0, width - 32)) + 2 * paddingY }
    override func layout() { super.layout(); text.frame = NSRect(x: 16, y: paddingY, width: max(0, bounds.width - 32), height: bounds.height - 2 * paddingY) }
}

/// `SettingsScopeNotice`: an alert with the message and one outline button per target (`AlertAction flex-wrap`).
final class SettingsScopeNoticeView: DSView, SettingsGroupRow {
    private let box = BoxView()
    private let text = TextBlockView()
    private var buttons: [ButtonView] = []

    init(_ message: String, choices: [(String, @MainActor () -> Void)]) {
        super.init(frame: .zero)
        var style = BoxStyle()
        style.radius = 12
        style.border = Themed.color(\.border)
        style.fill = Themed.color(\.card)
        box.boxStyle = style
        addSubview(box)
        text.text = message
        text.font = DSFont.ui(14)
        text.lineHeight = 20
        text.color = Themed.color(\.mutedForeground)
        addSubview(text)
        for (label, action) in choices {
            let b = ButtonView(label, variant: .outline, size: .sm)
            b.action = action
            buttons.append(b)
            addSubview(b)
        }
    }

    private func layoutButtons(_ width: CGFloat, place: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0
        for b in buttons {
            let w = min(width, b.intrinsicContentSize.width)
            if x > 0, x + w > width { x = 0; y += 32 + 4 }
            if place { b.frame = NSRect(x: 14 + x, y: 12 + text.height(forWidth: width) + 8 + y, width: w, height: 32) }
            x += w + 4
        }
        return buttons.isEmpty ? 0 : y + 32
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 28
        return 12 + text.height(forWidth: inner) + (buttons.isEmpty ? 0 : 8 + layoutButtons(inner, place: false)) + 12
    }

    override func layout() {
        super.layout()
        box.frame = bounds
        let inner = bounds.width - 28
        text.frame = NSRect(x: 14, y: 12, width: inner, height: text.height(forWidth: inner))
        _ = layoutButtons(inner, place: true)
    }
}

/// `ConfirmDialogHost`'s copy: the question line is the title, the rest the description.
public enum ConfirmCopy {
    public static func resolve(_ message: String) -> (title: String, description: String?) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = normalized.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") }) {
            let description = lines.enumerated().filter { $0.offset != i }.map(\.element).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (lines[i].trimmingCharacters(in: .whitespaces), description.isEmpty ? nil : description)
        }
        if let q = normalized.firstIndex(of: "?") {
            let rest = normalized[normalized.index(after: q)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (String(normalized[...q]).trimmingCharacters(in: .whitespaces), rest.isEmpty ? nil : rest)
        }
        return ("Confirm action", normalized.isEmpty ? "This action requires your confirmation." : normalized)
    }
}
