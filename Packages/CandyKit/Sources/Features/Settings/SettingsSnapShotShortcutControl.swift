import AppKit
import DesignSystem
import T3Protocol

/// snapShotShortcut.ts:110-121. Use the existing recorder and the app's sole key monitor.
final class SettingsSnapShotShortcutControl: DSView {
    var value: JSONValue = .object(["kind": .string("both-shift-keys")]) { didSet { recorder.value = SnapShotSettingsView.shortcutLabel(value) } }
    var onChange: ((JSONValue) -> Void)?
    var onConflict: ((String?) -> Void)?
    private let recorder = ShortcutRecorderView()
    private let reset = ButtonView(nil, icon: .rotateCcw, variant: .ghostMuted, size: .iconXs)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(recorder); addSubview(reset)
        recorder.setAccessibilityLabel("Capture shortcut")
        reset.setAccessibilityLabel("Reset capture shortcut")
        reset.action = { [weak self] in self?.save(.object(["kind": .string("both-shift-keys")])) }
        recorder.onModifierPair = { [weak self] modifier in self?.save(.object(["kind": .string("modifier-pair"), "modifier": .string(modifier)])) }
        recorder.onRecord = { [weak self] binding in
            guard let self, let parsed = KeybindingShortcut.parse(binding), let chord = SnapShotShortcutState.chord(binding) else { return }
            if let conflict = ActiveKeymap.keymap.rules.first(where: { $0.shortcut.conflictKey == parsed.conflictKey }) {
                onConflict?("This shortcut is used by " + KeybindingsLogic.commandLabel(conflict.command) + ".")
                recorder.value = SnapShotSettingsView.shortcutLabel(value)
            } else { save(chord) }
        }
        self.frame.size = intrinsicContentSize
    }
    private func save(_ next: JSONValue) { value = next; onConflict?(nil); onChange?(next) }
    override var intrinsicContentSize: NSSize { NSSize(width: 208, height: 28) }
    override func layout() {
        super.layout(); recorder.frame = NSRect(x: 0, y: 0, width: 176, height: 28)
        reset.frame = NSRect(x: 180, y: 0, width: 28, height: 28)
    }
}
