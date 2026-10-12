import DesignSystem
import Foundation

@MainActor public enum SettingsFontRuntime {
    private static var observation: Int?
    public static func start() {
        guard observation == nil else { return }
        observation = ClientSettingsStore.shared.observe { keys in
            if keys.contains("hydration") || keys.contains(where: { $0.hasPrefix("font") }) { apply() }
        }
        apply()
    }
    public static func apply() {
        let c = ClientSettingsStore.shared.current
        var p = FontRuntimeInput()
        p.interfaceFamily = c.string("fontFamilySans")
        p.promptFamily = c.string("fontFamilyComposer")
        p.codeFamily = c.string("fontFamilyCode")
        p.terminalFamily = c.string("fontFamilyTerminal")
        p.interfaceSize = CGFloat(c.int("fontSizeInterface"))
        p.promptSize = CGFloat(c.int("fontSizePrompt"))
        p.codeSize = CGFloat(c.int("fontSizeCode"))
        p.terminalSize = CGFloat(c.int("fontSizeTerminal"))
        // T3's `fontSmoothing` on means `-webkit-font-smoothing: antialiased`, thinner grayscale text
        // (appearanceFonts.ts:125-133); off restores the heavier macOS smoothing. Measured on screen against
        // T3 Nightly, CandyWrapper's labels carried 12 to 27% more ink with Core Text smoothing on.
        p.smoothing = !c.bool("fontSmoothing")
        p.advanced = UserDefaults.standard.bool(forKey: AppearanceSettingsView.advancedKey)
        FontRuntime.apply(p)
    }
}
