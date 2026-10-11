import AppKit
import DesignSystem
import T3Protocol

/// Settings > SnapShots (SnapShotSettings.tsx, SnapShotSettings.logic.ts): device-only rows, no scope sentence.
public final class SnapShotSettingsView: ScopedSettingsPage {
    public init(context: SettingsPageContext) {
        super.init(context: context, sentence: false)
        usesBoundary = false
        body = [snapShotSection()]
    }

    /// `snapShotModifierPairLabel` and the chord label for the saved shortcut.
    static func shortcutLabel(_ shortcut: JSONValue) -> String {
        let names = ["shift": "Shift", "meta": "Command", "control": "Control", "alt": "Option"]
        switch shortcut["kind"]?.stringValue {
        case "both-shift-keys": return "Shift + Shift"
        case "modifier-pair": let n = names[shortcut["modifier"]?.stringValue ?? "shift"] ?? "Shift"; return "\(n) + \(n)"
        default:
            var parts: [String] = []
            if shortcut["modKey"]?.boolValue == true || shortcut["metaKey"]?.boolValue == true { parts.append("⌘") }
            if shortcut["ctrlKey"]?.boolValue == true { parts.append("⌃") }
            if shortcut["altKey"]?.boolValue == true { parts.append("⌥") }
            if shortcut["shiftKey"]?.boolValue == true { parts.append("⇧") }
            parts.append((shortcut["key"]?.stringValue ?? "").uppercased())
            return parts.joined()
        }
    }

    private func snapShotSection() -> SettingsSectionView {
        let enable = SwitchView(isOn: false)
        enable.setAccessibilityLabel("Enable snapshots")
        let enabledRow = row("snap-shot-enabled", detail: "Capture a window and attach it to your current draft.", control: enable)
        enabledRow.accessories = [ResetSlot(label: "")]
        enable.onChange = { [weak self, weak enable] on in if on { enable?.isOn = self?.client.bool("snapShotEnabled") ?? false; self?.context.setupSnapShot?() } else { self?.context.writeClient?(["snapShotEnabled": .bool(false)]) } }

        let text = clientSwitch("snap-shot-accessibility", "Include text and controls when the app makes them available.",
                                key: "snapShotIncludeAccessibility", label: "Include app text in snapshots")
        let shortcutBox = ShortcutRecorderView()
        shortcutBox.preferredWidth = 176
        shortcutBox.onRecord = { [weak self] binding in
            guard let chord = SnapShotShortcutState.chord(binding) else { return }
            self?.context.writeClient?(["snapShotShortcut": chord])
        }
        let shortcut = row("snap-shot-shortcut", detail: "Capture the window you're using without switching apps.", control: shortcutBox)
        shortcut.accessories = [ResetSlot(label: "")]
        let sounds: [(String, String)] = [("off", "Off"), ("soft-pop", "Whoosh (Default)"), ("camera-shutter", "Click")]
        let sound = settingsSelect(sounds.map(\.1), width: nil, hideIndicator: false)
        sound.setAccessibilityLabel("Snapshot sound")
        let soundRow = row("snap-shot-sound", detail: "Choose the sound played when capture starts.", control: sound)
        soundRow.accessories = [ResetSlot(label: "")]
        // `snapShotSoundPatch`.
        sound.onChange = { [weak self] i in
            self?.context.writeClient?(i == 0 ? ["snapShotPlaySound": .bool(false)] : ["snapShotPlaySound": .bool(true), "snapShotSound": .string(sounds[i].0)])
        }
        let flash = clientSwitch("snap-shot-flash", "Show a gentle cue on the captured window.", key: "snapShotFlash", label: "Flash captured window")
        let animations = clientSwitch("snap-shot-animations", "Animate captured windows into your draft.", key: "snapShotAnimations", label: "Animate snapshots")
        binder.add { [weak self, weak enable, weak enabledRow, weak shortcutBox, weak sound] in
            guard let self else { return }
            let on = self.client.bool("snapShotEnabled")
            enable?.isOn = on
            enabledRow?.status = on ? (self.context.snapShotReady?() == true ? "Ready to capture" : "Finish shortcut setup") : "Turn this on to set up snapshots."
            for r in [text, shortcut, soundRow, flash, animations] { r.isHidden = !on }
            shortcutBox?.value = Self.shortcutLabel(self.client["snapShotShortcut"])
            let selection = self.client.bool("snapShotPlaySound") ? self.client.string("snapShotSound") : "off"
            sound?.selectedIndex = sounds.firstIndex { $0.0 == selection }
        }
        let s = section("snap-shot", "SnapShots", [enabledRow, text, shortcut, soundRow, flash, animations])
        binder.add { [weak s] in s?.group.rows = s?.group.rows ?? [] }
        return s
    }
}
