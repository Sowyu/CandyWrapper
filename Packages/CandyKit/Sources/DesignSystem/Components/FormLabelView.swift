import AppKit

/// T3's `Label` (`apps/web/src/components/ui/label.tsx`): 14px/16px, weight 500, foreground.
/// Spec: docs/research/recovered/ui-components-a.md section 7.
@MainActor
public enum FormLabel {
    public static func make(_ text: String) -> LabelView {
        let label = LabelView(text, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastForeground))
        label.lineHeight = 16
        return label
    }
}
