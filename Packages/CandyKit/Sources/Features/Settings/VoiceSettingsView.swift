import AppKit
import DesignSystem

/// The Voice page's place in the nav (settingsSearch.ts:146, SettingsSidebarNav.tsx `MicIcon`). T3's page
/// (VoiceSettingsPanel.tsx) configures composer dictation, which CandyWrapper doesn't have yet, so the page says so.
// ponytail: notice only, port VoiceSettingsPanel.tsx when the composer gets dictation (`/api/voice/*`, composer.dictation).
public final class VoiceSettingsView: SettingsPageBase {
    public override init(context: SettingsPageContext) {
        super.init(context: context)
        // Redesign shows it as a state card like Archive's empty page, with what it will hold.
        if ThemeRuntime.isDither(dark: NSApp.effectiveAppearance.isDark) {
            let copy = StateCopy(title: "Dictation isn't here yet",
                                 detail: "CandyWrapper's composer can't take dictation yet. Its microphone and language settings will appear here.")
            items = [SettingsGroupView(rows: [KeybindingsSettingsView.EmptyMessageRow("Voice dictation isn't available in CandyWrapper yet.", redesign: copy)])]
        } else {
            items = [SettingsNoticeView("Voice dictation isn't available in CandyWrapper yet.")]
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension SettingsSection {
    /// lucide `mic` (lucide-static 0.564.0), outside the generated icon set.
    static let micIcon = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24), elements: [
        IconElement(.path(d: "M12 19v3")),
        IconElement(.path(d: "M19 10v2a7 7 0 0 1-14 0v-2")),
        IconElement(.rect(x: 9, y: 2, w: 6, h: 13, rx: 3, ry: 3)),
    ])
}
