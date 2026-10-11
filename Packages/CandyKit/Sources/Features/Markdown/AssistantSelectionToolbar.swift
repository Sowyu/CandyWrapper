import AppKit
import DesignSystem

/// AssistantSelectionToolbar.tsx:142-173, glass xs button with a 14pt quote glyph.
@MainActor
public enum AssistantSelectionToolbar {
    public static func button(tooLong: Bool) -> ButtonView {
        let button = ButtonView(tooLong ? "Shorten selection" : "Cite", icon: .quote, variant: .glass, size: .xs)
        button.iconSize = 14
        button.isEnabled = !tooLong
        button.setAccessibilityLabel(tooLong ? "Selection is too long to cite" : "Cite selection in composer")
        return button
    }
}
