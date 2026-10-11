import AppKit
import DesignSystem

final class SettingsDiagnosticsExpandableCell: ControlView {
    private let text: TextBlockView
    private let lines: Int
    var onExpand: (() -> Void)?
    init(text: TextBlockView, lines: Int) {
        self.text = text; self.lines = lines
        super.init(frame: .zero)
        addSubview(text)
        scalesWhenPressed = false
        setAccessibilityLabel("Expand diagnostic text")
        action = { [weak self] in
            guard let self else { return }
            self.text.maxLines = self.text.maxLines == 0 ? self.lines : 0
            self.setAccessibilityLabel(self.text.maxLines == 0 ? "Collapse diagnostic text" : "Expand diagnostic text")
            self.onExpand?()
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: width) }
    override func layout() { super.layout(); text.frame = bounds }
}
