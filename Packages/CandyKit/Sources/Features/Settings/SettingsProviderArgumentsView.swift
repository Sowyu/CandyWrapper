import AppKit
import DesignSystem

/// ProviderSettingsForm.tsx:148-225. Each field is one literal argument, including empty strings.
final class SettingsProviderArgumentsView: DSView, SettingsGroupRow {
    private var arguments: [String]
    private let enabled: Bool
    private let change: ([String]) -> Void
    private var rows: [SettingsRowView] = []
    var onHeightChange: (() -> Void)?
    init(_ arguments: [String], enabled: Bool = true, change: @escaping ([String]) -> Void) {
        self.arguments = arguments; self.enabled = enabled; self.change = change
        super.init(frame: .zero); rebuild()
    }
    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }; rows = []
        let add = ButtonView("Add argument", icon: .plus, variant: .outline, size: .sm)
        add.isEnabled = enabled
        add.action = { [weak self] in
            guard let self else { return }; arguments.append(""); change(arguments); rebuild()
        }
        rows.append(SettingsRowView(title: "Arguments", detail: "One literal argument per row, in launch order.", control: add))
        for (index, argument) in arguments.enumerated() {
            let input = InputView(text: argument, size: .sm, font: .mono)
            input.frame.size = NSSize(width: 256, height: 28)
            input.isEnabled = enabled; input.setAccessibilityLabel("Argument \(index + 1)")
            input.onCommit = { [weak self] text in
                guard let self, arguments.indices.contains(index) else { return }
                arguments[index] = text; change(arguments)
            }
            let remove = ButtonView(nil, icon: .trash2, variant: .ghostMuted, size: .iconXs)
            remove.isEnabled = enabled; remove.setAccessibilityLabel("Remove argument \(index + 1)")
            remove.action = { [weak self] in
                guard let self, arguments.indices.contains(index) else { return }
                arguments.remove(at: index); change(arguments); rebuild()
            }
            rows.append(SettingsRowView(title: "", control: SettingsControlGroup([input, remove])))
        }
        rows.forEach(addSubview); needsLayout = true; onHeightChange?()
    }
    func height(forWidth width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + $1.height(forWidth: width) } }
    override func layout() {
        super.layout(); var y: CGFloat = 0
        for row in rows { let h = row.height(forWidth: bounds.width); row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h); y += h }
    }
}
