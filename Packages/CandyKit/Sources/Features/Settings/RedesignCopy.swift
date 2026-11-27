import AppKit
import DesignSystem

/// Copy that T3 writes for every platform, in macOS words under Redesign (round-1 review X6, 2026-11-26: "Ctrl",
/// "Cmd-click" and "D:\worktrees" on a Mac). The default themes keep T3's words.
@MainActor enum RedesignCopy {
    static func mac(_ t3: String, _ macOS: String) -> String {
        ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true) ? macOS : t3
    }
}
