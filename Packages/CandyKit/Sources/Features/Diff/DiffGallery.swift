import AppKit
import DesignSystem

/// The Diff panel sections of the component gallery: the panel in the unified and split layouts
/// with the sample files expanded, one gallery column wide.
@MainActor
public enum DiffGallery {
    public static var sections: [ComponentGallery.Section] {
        [DiffViewStyle.unified, .split].map { style in
            ComponentGallery.Section(title: style == .unified ? "Diff panel (unified)" : "Diff panel (split)", height: 560) {
                let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 518, height: 560))
                panel.layoutStyle = style
                panel.showPatch(DiffPreview.sample, scopeLabel: "Latest turn", collapsed: false)
                return panel
            }
        }
    }
}
