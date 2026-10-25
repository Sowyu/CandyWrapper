import AppKit

/// The recovery key as the first-run sheet shows it: for reading and writing down only. A wrapping label is
/// selectable by default, and ⌘C would put the key on the pasteboard, which any process of this user can read.
@MainActor
public enum SpaceRecoveryKeyLabel {
    public static func make(_ key: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: key)
        field.isSelectable = false
        field.isEditable = false
        field.refusesFirstResponder = true
        field.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        field.frame = NSRect(x: 0, y: 0, width: 440, height: 65)
        return field
    }
}
