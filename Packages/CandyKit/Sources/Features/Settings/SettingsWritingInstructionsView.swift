import AppKit
import DesignSystem

/// SourceControlWritingSettings.tsx:181-229: mixed instructions never silently overwrite another host.
final class SettingsWritingInstructionsView: DSView, SettingsGroupRow {
    private let write = ButtonView("Write custom instructions for all", variant: .outline, size: .sm)
    private let apply = ButtonView("Apply instructions to all", variant: .outline, size: .sm)
    private let input = TextareaView(placeholder: "Write the instructions each selected environment should use.")
    private var editing = false
    var onApply: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        [write, apply, input].forEach(addSubview)
        input.setAccessibilityLabel("Custom source control instructions for all selected environments")
        input.isHidden = true; apply.isHidden = true; apply.isEnabled = false
        write.action = { [weak self] in
            guard let self else { return }
            self.editing = true; self.write.isHidden = true; self.input.isHidden = false; self.apply.isHidden = false
            self.input.text = ""; self.apply.isEnabled = false
            self.onHeightChange?()
        }
        input.onChange = { [weak self] _ in self?.apply.isEnabled = true; self?.onHeightChange?() }
        apply.action = { [weak self] in
            guard let self else { return }
            self.onApply?(self.input.text.trimmingCharacters(in: .whitespacesAndNewlines))
            self.editing = false; self.write.isHidden = false; self.input.isHidden = true; self.apply.isHidden = true
            self.onHeightChange?()
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        input.setFrameSize(NSSize(width: min(672, width), height: input.frame.height))
        return editing ? input.intrinsicContentSize.height + 8 + 28 + 14 : 42
    }
    override func layout() {
        super.layout()
        write.frame = NSRect(origin: .zero, size: write.intrinsicContentSize)
        input.frame = NSRect(x: 0, y: 0, width: min(bounds.width, 672), height: input.intrinsicContentSize.height)
        apply.frame = NSRect(x: 0, y: input.frame.maxY + 8, width: apply.intrinsicContentSize.width, height: 28)
    }
}
