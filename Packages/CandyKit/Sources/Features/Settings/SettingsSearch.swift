import Foundation
import T3Protocol

/// Where a setting can be edited (settingsSearch.ts `SettingsSearchScope`). Device-local rows have none.
public enum SettingsSearchScope: Sendable, Equatable {
    case environment, environmentDefaults, projectDefaults, project, checkout, connections
}

/// One searchable setting or destination (settingsSearch.ts `SettingsSearchItem`).
public struct SettingsSearchItem: Sendable, Equatable {
    public enum Flag: Sendable, Equatable {
        case desktopOnly, macOnly, windowsOnly, cloudOnly, environmentOnly, providerSettingsOnly, macProviderSettingsOnly
        case localBackendManagementOnly, localEnvironmentOnly, wslAvailableOnly, managedTunnelOnly, secondary, requiresThreadAutoSettlement
    }

    public let id: String
    public let title: String
    public let to: SettingsSection
    public let targetId: String?
    public let scope: SettingsSearchScope?
    public let searchTerms: [String]
    public let flags: Set<Flag>

    public init(id: String, title: String, to: SettingsSection, targetId: String? = nil, scope: SettingsSearchScope? = nil,
                searchTerms: [String] = [], flags: Set<Flag> = []) {
        self.id = id; self.title = title; self.to = to; self.targetId = targetId; self.scope = scope
        self.searchTerms = searchTerms; self.flags = flags
    }

    /// The anchor a result jumps to.
    public var anchor: String { targetId ?? id }
}

/// What this client can show (settingsSearch.ts `SettingsSearchAvailability`).
public struct SettingsSearchAvailability: Sendable, Equatable {
    public var localEnvironmentDisabled = false
    public var hasCloudPublicConfig = true
    public var hasEnvironment = true
    public var hasProviderSettingsEnvironment = true
    public var hasMacProviderSettingsEnvironment = true
    public var canManageLocalBackend = false
    public var isWslSettingsRowVisible = false
    public var hasThreadAutoSettlement = true
    public var managedTunnelActive = false
    public init() {}
}

/// T3's settings search (settingsSearch.ts): the catalog, availability filter and ranking.
public enum SettingsSearch {
    /// `KEYBINDING_SEARCH_ITEMS`: one result per built-in command, by label; default keys are searchable.
    static let keybindingItems: [SettingsSearchItem] = KeybindingsLogic.staticCommands
        .sorted { KeybindingsLogic.commandLabel($0).localizedCompare(KeybindingsLogic.commandLabel($1)) == .orderedAscending }
        .map { command in
            let keys = Keymap.defaultBindings.filter { $0.command == command }.map(\.key)
            return SettingsSearchItem(id: KeybindingsLogic.anchorId(command), title: KeybindingsLogic.commandLabel(command), to: .keybindings,
                                      targetId: keys.isEmpty ? "keybindings" : nil, searchTerms: [command] + keys, flags: [.secondary])
        }

    /// `SETTINGS_SEARCH_ITEMS` in result order.
    public static let items: [SettingsSearchItem] = catalogEntries.flatMap { entry -> [SettingsSearchItem] in
        switch entry {
        case .item(let item): [item]
        case .keybindings: keybindingItems
        }
    }

    public static func item(_ id: String) -> SettingsSearchItem? { items.first { $0.id == id } }
    /// `searchableSetting(id).title`.
    public static func title(_ id: String) -> String { item(id)?.title ?? id }

    /// `filterAvailableSettingsSearchItems`, plus the platform filter `searchSettings` applies (desktop, macOS).
    public static func available(_ a: SettingsSearchAvailability, items: [SettingsSearchItem] = items) -> [SettingsSearchItem] {
        items.filter { item in
            let f = item.flags
            return !f.contains(.windowsOnly)
                && (!f.contains(.cloudOnly) || a.hasCloudPublicConfig)
                && (!f.contains(.environmentOnly) || a.hasEnvironment)
                && (!f.contains(.providerSettingsOnly) || a.hasProviderSettingsEnvironment)
                && (!f.contains(.macProviderSettingsOnly) || a.hasMacProviderSettingsEnvironment)
                && (!f.contains(.localBackendManagementOnly) || a.canManageLocalBackend)
                && (!f.contains(.localEnvironmentOnly) || !a.localEnvironmentDisabled)
                && (!f.contains(.wslAvailableOnly) || a.isWslSettingsRowVisible)
                && (!f.contains(.requiresThreadAutoSettlement) || a.hasThreadAutoSettlement)
                && (!f.contains(.managedTunnelOnly) || a.managedTunnelActive)
        }
    }

    /// `normalizeSearchText` (lib/utils.ts:22): NFKD without marks, lowercased, single spaces.
    public static func normalize(_ value: String) -> String {
        let folded = value.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !$0.properties.generalCategory.isMark }
        return String(String.UnicodeScalarView(folded)).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `searchSettings`: every token must hit the title, section label or a search term; ranked by title
    /// match (exact, prefix, contains, all tokens, phrase in any field), secondary items last, then catalog order.
    public static func search(_ query: String, in items: [SettingsSearchItem] = items) -> [SettingsSearchItem] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let tokens = q.split(separator: " ").map(String.init)
        var hits: [(item: SettingsSearchItem, index: Int, rank: Int)] = []
        for (index, item) in items.enumerated() {
            let title = normalize(item.title)
            let fields = [title, normalize(item.to.label)] + item.searchTerms.map(normalize)
            guard tokens.allSatisfy({ t in fields.contains { $0.contains(t) } }) else { continue }
            let rank = title == q ? 5
                : title.hasPrefix(q) ? 4
                : title.contains(q) ? 3
                : tokens.allSatisfy({ title.contains($0) }) ? 2
                : fields.contains(where: { $0.contains(q) }) ? 1 : 0
            hits.append((item, index, rank))
        }
        return hits.sorted { l, r in
            let ls = l.item.flags.contains(.secondary), rs = r.item.flags.contains(.secondary)
            if ls != rs { return !ls }
            if l.rank != r.rank { return l.rank > r.rank }
            return l.index < r.index
        }.map(\.item)
    }
}

extension Unicode.GeneralCategory {
    var isMark: Bool { self == .nonspacingMark || self == .spacingMark || self == .enclosingMark }
}
