import AppKit

/// The Panel animations setting (`panelAnimationDurationMs`), resolved on change. `PanelSlide` runs the
/// sidebar, right panel and terminal slides over it.
@MainActor public enum SettingsPanelMotion {
    public static var durationMs = 0
    public static var duration: TimeInterval {
        Motion.reduced ? 0 : Double(min(400, max(0, durationMs))) / 1000
    }
}
