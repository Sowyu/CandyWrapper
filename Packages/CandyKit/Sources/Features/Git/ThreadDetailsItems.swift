import DesignSystem
import Foundation
import T3Protocol

/// What the thread details card shows (4928 components/chat/threadDetailsItems.ts, #26904). Ids are stored
/// in the `threadDetailsItems` client setting, so they never change.
public enum ThreadDetailsItems {
    public struct Item: Sendable, Equatable {
        public let id: String
        public let label: String
        public let defaultVisible: Bool
    }

    /// `THREAD_DETAILS_ITEMS`, in T3's order.
    public static let all: [Item] = [
        Item(id: "environment", label: "Environment and worktree", defaultVisible: true),
        Item(id: "openIn", label: "Open in editor", defaultVisible: true),
        Item(id: "scripts", label: "Project scripts", defaultVisible: true),
        Item(id: "branch", label: "Branch and pull request", defaultVisible: true),
        Item(id: "gitActions", label: "Git actions", defaultVisible: true),
        Item(id: "changes", label: "Changes", defaultVisible: true),
        Item(id: "servers", label: "Servers", defaultVisible: true),
        Item(id: "automations", label: "Automations", defaultVisible: true),
        Item(id: "lineage", label: "Lineage", defaultVisible: true),
        Item(id: "sideChats", label: "Side chats", defaultVisible: true),
        Item(id: "usage", label: "Usage limits", defaultVisible: false),
        Item(id: "context", label: "Context window", defaultVisible: false),
    ]

    /// Items that change nothing under Redesign: its environment and worktree sit in the machine row under the composer,
    /// which always shows, and it has no context window section. Their stored choices stay for the other themes.
    public static let redesignInert: Set<String> = ["environment", "context"]

    /// The items a theme offers: all of them, or under Redesign those it shows in the header pill, its actions menu
    /// and the Thread details dropdown.
    public static func items(redesign: Bool) -> [Item] { redesign ? all.filter { !redesignInert.contains($0.id) } : all }

    /// People who turned on the retired Labs toggle keep Usage and Context until they change them (threadDetailsItems.ts:41-46).
    static func defaultVisible(_ item: Item, _ settings: ClientSettings) -> Bool {
        item.id == "usage" || item.id == "context" ? settings.bool("threadDetailsUsageEnabled") : item.defaultVisible
    }

    /// `resolveThreadDetailsVisibility`.
    public static func visibility(_ settings: ClientSettings) -> [String: Bool] {
        let stored = settings["threadDetailsItems"].objectValue ?? [:]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, stored[$0.id]?.boolValue ?? defaultVisible($0, settings)) })
    }

    /// `setThreadDetailsItem`: stores only choices that differ from the default, so a later default change reaches everyone else.
    public static func setting(_ settings: ClientSettings, _ item: Item, visible: Bool) -> JSONValue {
        var stored = settings["threadDetailsItems"].objectValue ?? [:]
        stored[item.id] = nil
        if visible != defaultVisible(item, settings) { stored[item.id] = .bool(visible) }
        return .object(stored)
    }

    /// `isDefaultThreadDetailsVisibility`.
    public static func isDefault(_ visibility: [String: Bool], redesign: Bool = false) -> Bool {
        items(redesign: redesign).allSatisfy { visibility[$0.id] == $0.defaultVisible }
    }

    /// `RESET_THREAD_DETAILS_ITEMS`: also clears the retired Labs flag, so Usage and Context return to off.
    public static let reset: [String: JSONValue] = ["threadDetailsItems": .object([:]), "threadDetailsUsageEnabled": .bool(false)]

    /// The reset a theme offers. Under Redesign it leaves the items Redesign doesn't offer as they show now, so the
    /// other themes get them back unchanged.
    public static func reset(_ settings: ClientSettings, redesign: Bool) -> [String: JSONValue] {
        guard redesign else { return reset }
        let shown = visibility(settings)
        var kept: [String: JSONValue] = [:]
        for item in all where redesignInert.contains(item.id) && shown[item.id] != item.defaultVisible {
            kept[item.id] = .bool(shown[item.id] ?? item.defaultVisible)
        }
        return ["threadDetailsItems": .object(kept), "threadDetailsUsageEnabled": .bool(false)]
    }

    /// `ThreadDetailsItemsMenuItems`: the card's context menu and the Settings row share it. `settings` reads the
    /// latest values when an item toggles, `write` saves a patch.
    /// `redesign` lists only the items Redesign shows, under a label that names where they show.
    @MainActor
    public static func menuItems(redesign: Bool = false, settings: @escaping @MainActor () -> ClientSettings = { ClientSettingsStore.shared.current },
                                 write: @escaping @MainActor ([String: JSONValue]) -> Void = { ClientSettingsStore.shared.update($0) }) -> [MenuItem] {
        let shown = visibility(settings())
        var rows: [MenuItem] = [.label(redesign ? "Show in the header and Thread details" : "Show in thread details")]
        for item in items(redesign: redesign) {
            var row = MenuItem.checkbox(item.label, checked: shown[item.id] ?? false) { on in
                write(["threadDetailsItems": setting(settings(), item, visible: on)])
            }
            row.keepsOpen = true
            rows.append(row)
        }
        rows.append(.separator)
        rows.append(MenuItem("Reset to default", disabled: isDefault(shown, redesign: redesign)) { write(reset(settings(), redesign: redesign)) })
        return rows
    }
}
