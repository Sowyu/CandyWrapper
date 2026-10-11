import Foundation
import T3Protocol

/// Edge-triggered modifier pairs. Device-side flag bits distinguish left and right keys.
/// DesktopSnapShot.ts and MacModifierPairShortcutProcess.ts:16-34 use the same rising edge.
public struct SnapShotShortcutState: Sendable {
    private var held = false
    public init() {}
    public static func chord(_ binding: String) -> JSONValue? {
        let parts = binding.lowercased().components(separatedBy: "+")
        guard let key = parts.last, !key.isEmpty, parts.count > 1 else { return nil }
        return .object(["key": .string(key),
                        "modKey": .bool(parts.contains("mod")), "metaKey": .bool(parts.contains("meta")),
                        "ctrlKey": .bool(parts.contains("ctrl")), "altKey": .bool(parts.contains("alt")),
                        "shiftKey": .bool(parts.contains("shift"))])
    }
    public mutating func reset() { held = false }
    public mutating func update(flags: UInt64, shortcut: JSONValue) -> Bool {
        let modifier = shortcut["kind"]?.stringValue == "both-shift-keys" ? "shift" : shortcut["modifier"]?.stringValue ?? "shift"
        let mask: UInt64
        switch modifier {
        case "meta": mask = 0x08 | 0x10
        case "control": mask = 0x01 | 0x2000
        case "alt": mask = 0x20 | 0x40
        default: mask = 0x02 | 0x04
        }
        let down = flags & mask == mask
        defer { held = down }
        return down && !held
    }
}
