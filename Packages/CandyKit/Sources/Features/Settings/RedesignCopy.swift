import AppKit
import DesignSystem

/// Copy that T3 writes for every platform, in macOS words under Redesign (round-1 review X6, 2026-11-26: "Ctrl",
/// "Cmd-click" and "D:\worktrees" on a Mac). The default themes keep T3's words.
@MainActor public enum RedesignCopy {
    public static func mac(_ t3: String, _ macOS: String) -> String { isOn ? macOS : t3 }

    /// Redesign draws the app's current appearance.
    public static var isOn: Bool { ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true) }

    /// `mac` for a label read off the main actor: Redesign's words while either appearance draws Redesign.
    public nonisolated static func word(_ t3: String, _ redesign: String) -> String {
        ThemeRuntime.isDither(dark: true) || ThemeRuntime.isDither(dark: false) ? redesign : t3
    }

    /// Where Redesign names its pages (round-2 review X6 and G5): Environments, not T3's Connections; Scheduled tasks,
    /// not Automations; Snapshots in sentence case.
    public static var environments: String { mac("Connections", "Environments") }
    public static var scheduledTasks: String { mac("Automations", "Scheduled tasks") }
}
