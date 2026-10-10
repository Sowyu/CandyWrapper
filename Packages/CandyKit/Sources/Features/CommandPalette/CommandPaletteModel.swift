import DesignSystem
import Foundation

/// One palette entry (`CommandPaletteActionItem` / `CommandPaletteSubmenuItem`,
/// apps/web/src/components/CommandPalette.logic.ts:131-171).
public struct PaletteEntry {
    public enum Action {
        /// `run`; `keepOpen` leaves the palette open afterwards.
        case run(@MainActor () -> Void, keepOpen: Bool)
        case submenu(PalettePage)
    }

    public var value: String
    public var searchTerms: [String]
    public var title: String
    public var titleEmphasis: String?
    public var description: String?
    public var match: String?
    public var timestamp: String?
    /// Thread recency; also makes the first search term a title that ties with other non-exact title matches.
    public var searchRecency: Int64?
    public var icon: IconName
    public var isDisabled = false
    public var note: String?
    public var shortcutCommand: String?
    public var secondary = false
    public var action: Action

    public init(value: String, searchTerms: [String], title: String, titleEmphasis: String? = nil, description: String? = nil,
                match: String? = nil, timestamp: String? = nil, searchRecency: Int64? = nil, icon: IconName, isDisabled: Bool = false,
                note: String? = nil, shortcutCommand: String? = nil, secondary: Bool = false, action: Action) {
        self.value = value; self.searchTerms = searchTerms; self.title = title; self.titleEmphasis = titleEmphasis
        self.description = description; self.match = match; self.timestamp = timestamp; self.searchRecency = searchRecency
        self.icon = icon; self.isDisabled = isDisabled; self.note = note; self.shortcutCommand = shortcutCommand
        self.secondary = secondary; self.action = action
    }

    public var isSubmenu: Bool { if case .submenu = action { true } else { false } }
}

public struct PaletteGroup {
    public var value: String
    public var label: String
    public var items: [PaletteEntry]
    public init(value: String, label: String, items: [PaletteEntry]) { self.value = value; self.label = label; self.items = items }
}

/// A pushed view (`CommandPaletteView`): a submenu's groups.
public struct PalettePage {
    public var addonIcon: IconName
    public var groups: [PaletteGroup]
    public var initialQuery: String?
    public init(addonIcon: IconName, groups: [PaletteGroup], initialQuery: String? = nil) {
        self.addonIcon = addonIcon; self.groups = groups; self.initialQuery = initialQuery
    }
}

/// Search and ranking from CommandPalette.logic.ts.
public enum PaletteSearch {
    /// `RECENT_THREAD_LIMIT`.
    public static let recentThreadLimit = 12

    /// `normalizeSearchText` (lib/utils.ts:22-24): NFKD without marks, lowercased, single spaces.
    public static func normalize(_ value: String) -> String {
        let folded = value.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
        return String(String.UnicodeScalarView(folded)).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `rankSearchFieldMatch` (CommandPalette.logic.ts:416-438).
    static func rankField(_ field: String, query: String, tokens: [String]) -> Int? {
        let f = normalize(field)
        guard !f.isEmpty, tokens.allSatisfy({ f.contains($0) }) else { return nil }
        if f == query { return 3 }
        if f.hasPrefix(query) { return 2 }
        if f.contains(query) { return 1 }
        return 0
    }

    /// `rankCommandPaletteItemMatch` (CommandPalette.logic.ts:440-461).
    static func rank(_ item: PaletteEntry, query: String, tokens: [String]) -> Int {
        let terms = item.searchTerms.filter { !$0.isEmpty }
        for (index, field) in terms.enumerated() {
            guard let fieldRank = rankField(field, query: query, tokens: tokens) else { continue }
            // All non-exact thread title matches share a tier so recency breaks the tie.
            if index == 0, item.searchRecency != nil { return 1_000 + (fieldRank == 3 ? 1 : 0) }
            return 1_000 - index * 100 + fieldRank
        }
        return 0
    }

    /// `filterCommandPaletteGroups` (CommandPalette.logic.ts:463-541). A leading `>` keeps actions only.
    public static func filter(_ activeGroups: [PaletteGroup], query: String, isInSubmenu: Bool,
                              projectItems: [PaletteEntry], settingsItems: [PaletteEntry] = [], threadItems: [PaletteEntry]) -> [PaletteGroup] {
        let actionsOnly = query.hasPrefix(">")
        let normalized = normalize(actionsOnly ? String(query.dropFirst()) : query)
        if normalized.isEmpty {
            return actionsOnly ? activeGroups.filter { $0.value == "actions" } : activeGroups
        }
        let tokens = normalized.components(separatedBy: " ")
        var groups = activeGroups
        if actionsOnly {
            groups = groups.filter { $0.value == "actions" }
        } else if !isInSubmenu {
            groups = groups.filter { $0.value != "recent-threads" }
        }
        if !isInSubmenu, !actionsOnly {
            if !projectItems.isEmpty { groups.append(PaletteGroup(value: "projects-search", label: "Projects", items: projectItems)) }
            if !settingsItems.isEmpty { groups.append(PaletteGroup(value: "settings-search", label: "Settings", items: settingsItems)) }
            if !threadItems.isEmpty { groups.append(PaletteGroup(value: "threads-search", label: "Threads", items: threadItems)) }
        }
        return groups.compactMap { group in
            let ranked = group.items.enumerated().compactMap { index, item -> (PaletteEntry, Int, Int)? in
                let haystack = normalize(item.searchTerms.joined(separator: " "))
                guard tokens.allSatisfy({ haystack.contains($0) }) else { return nil }
                return (item, index, rank(item, query: normalized, tokens: tokens))
            }
            let items = ranked.sorted { l, r in
                if l.0.secondary != r.0.secondary { return !l.0.secondary }
                if l.2 != r.2 { return l.2 > r.2 }
                let lr = l.0.searchRecency ?? 0, rr = r.0.searchRecency ?? 0
                if lr != rr { return lr > rr }
                return l.1 < r.1
            }.map(\.0)
            return items.isEmpty ? nil : PaletteGroup(value: group.value, label: group.label, items: items)
        }
    }

    /// `enumerateCommandPaletteItems` (CommandPalette.logic.ts:226-236): the first nine get `thread.jump.N`.
    public static func enumerate(_ items: [PaletteEntry]) -> [PaletteEntry] {
        items.enumerated().map { index, item in
            var item = item
            item.shortcutCommand = index < 9 ? "thread.jump.\(index + 1)" : nil
            return item
        }
    }

    /// `getCommandPaletteInputPlaceholder`.
    public static func placeholder(inSubmenu: Bool) -> String {
        inSubmenu ? "Search..." : CommandPaletteView.rootPlaceholder
    }
}
