import AppKit
import DesignSystem
import T3Store

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
    /// What a thread row ranks by (`threadSearch`, CommandPalette.logic.ts:431-439).
    public var threadSearch: PaletteScoring.ThreadSearchSubject?
    /// Why the row matched when its title shows no match ("Branch: fix-sidebar"), set by `filter`.
    public var matchHint: PaletteScoring.SearchMatchHint?
    public var icon: IconName
    public var isDisabled = false
    public var note: String?
    public var shortcutCommand: String?
    public var secondary = false
    public var action: Action
    /// The file picker's rows: a file type glyph and fuzzy highlights.
    public var glyph: (IconDefinition, NSColor)?
    /// A project row's icon in place of `icon` (`projectFaviconIcon`, CommandPalette.tsx:346-348).
    public var projectIcon: ProjectIconSource?
    public var titleHighlights: [Int]?
    public var descriptionHighlights: [Int]?
    /// A message match (`ThreadSearchMatchExcerpt`): `match` is "You: <snippet>" or "Agent: <snippet>",
    /// and every ASCII-case-insensitive hit of `matchQuery` in the snippet draws semibold.
    public var matchIsUser: Bool?
    public var matchQuery: String?
    /// A context row (the new project preview, the repository being cloned): drawn, never highlighted or run.
    public var isStatic = false
    /// `titleTrailingContent`: a check (the chosen machine), a checkbox, or a warning note ("Setup Required").
    public var trailingIcon: IconName?
    public var trailingCheckbox: Bool?
    public var noteIsWarning = false
    /// `ThreadSearchPullRequestNumber`: a thread row's pull request badge, drawn without its controls.
    public var pullRequestBadge: SidebarPullRequestBadge?
    /// The thread is settled: the badge takes `text-secondary-label`.
    public var pullRequestBadgeSettled = false

    /// The second line: a message match (`ThreadSearchMatchExcerpt`), else a match hint ("Branch: fix-sidebar",
    /// `SearchMatchHintLine`), with UTF-16 offsets of the hits and the length of the "Label:" tag.
    var matchLine: (text: String, highlights: [Int], hintLabelLength: Int?)? {
        if let match, let isUser = matchIsUser, let query = matchQuery {
            let tag = isUser ? "You: " : "Agent: "
            guard match.hasPrefix(tag) else { return (match, [], nil) }
            let snippet = String(match.dropFirst(tag.count))
            let ranges = PaletteScoring.findSearchTokenRanges(snippet, query: query)
            return (match, Self.offsets(ranges, shift: tag.utf16.count), nil)
        }
        if let match { return (match, [], nil) }
        guard let hint = matchHint else { return nil }
        let label = hint.label + ":"
        return ("\(label) \(hint.text)", Self.offsets(hint.ranges, shift: label.utf16.count + 1), label.utf16.count)
    }

    static func offsets(_ ranges: [PaletteScoring.SearchRange], shift: Int) -> [Int] {
        ranges.flatMap { ($0.start..<$0.end).map { $0 + shift } }
    }

    public init(value: String, searchTerms: [String], title: String, titleEmphasis: String? = nil, description: String? = nil,
                match: String? = nil, timestamp: String? = nil, icon: IconName, isDisabled: Bool = false,
                note: String? = nil, shortcutCommand: String? = nil, secondary: Bool = false, action: Action) {
        self.value = value; self.searchTerms = searchTerms; self.title = title; self.titleEmphasis = titleEmphasis
        self.description = description; self.match = match; self.timestamp = timestamp
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
    /// A step whose rows follow the query (New project's name, the clone steps), in place of `groups`.
    public var mode: CommandPaletteController.Mode?
    public init(addonIcon: IconName, groups: [PaletteGroup], initialQuery: String? = nil, mode: CommandPaletteController.Mode? = nil) {
        self.addonIcon = addonIcon; self.groups = groups; self.initialQuery = initialQuery; self.mode = mode
    }
}

/// Search and ranking from CommandPalette.logic.ts.
public enum PaletteSearch {
    /// `RECENT_THREAD_LIMIT`.
    public static let recentThreadLimit = 12

    /// `pullRequestMatchesSearchQuery` (Sidebar.logic.ts:1011-1019): every word of the query is in the
    /// pull request terms.
    public static func pullRequestMatches(_ terms: [String], query: String) -> Bool {
        let q = normalize(query)
        guard !q.isEmpty else { return false }
        let haystack = normalize(terms.joined(separator: " "))
        return q.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    /// `normalizeSearchText` (lib/utils.ts:22-24): NFKD without marks, lowercased, single spaces.
    public static func normalize(_ value: String) -> String {
        // Printable ASCII, tabs and line breaks have nothing to decompose: lowercase and collapse spaces in one
        // pass. The palette runs this over every thread's terms on each key, and the Unicode path took 0.4 s
        // for 1,000 threads.
        if let ascii = normalizeASCII(value) { return ascii }
        let folded = value.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
        return String(String.UnicodeScalarView(folded)).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `normalize` for text of bytes 0x09 to 0x0D and 0x20 to 0x7E, or nil for anything else.
    static func normalizeASCII(_ value: String) -> String? {
        var value = value
        return value.withUTF8 { bytes -> String? in
            var out = [UInt8]()
            out.reserveCapacity(bytes.count)
            var pendingSpace = false
            for b in bytes {
                switch b {
                case 0x09...0x0D, 0x20:
                    pendingSpace = !out.isEmpty
                case 0x21...0x7E:
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(b >= 0x41 && b <= 0x5A ? b + 0x20 : b)
                default:
                    return nil
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// `rankPaletteItem` and `scorePaletteItem` (CommandPalette.logic.ts:458-497): a thread by
    /// `scoreThreadSearch`, anything else by its title with its search terms as keywords. A secondary row
    /// doesn't decide where its group sits.
    @MainActor static func score(_ item: PaletteEntry, query: String, now: Double, typos: Bool) -> PaletteScoring.SearchMatch? {
        var match: PaletteScoring.SearchMatch?
        if let subject = item.threadSearch {
            match = PaletteScoring.scoreThreadSearch(query, subject, now: now, typos: typos)
        } else {
            let terms = item.title != item.searchTerms.first ? [item.title] + item.searchTerms : item.searchTerms
            match = PaletteScoring.scoreSearchTerms(query, terms, typos: typos)
        }
        if item.secondary { match?.groupQuality = 0 }
        return match
    }

    /// `filterCommandPaletteGroups` (CommandPalette.logic.ts:499-603). Equal match classes put commands before
    /// threads, so "new" runs "New thread". A leading `>` keeps actions only. With `rootGroups`, submenu options
    /// join the root search as "Suggestions", and a submenu with no match falls back to it. Message matches come
    /// last, as "In messages", so late results can't move the rows above them.
    @MainActor public static func filter(_ activeGroups: [PaletteGroup], query: String, isInSubmenu: Bool,
                                         rootGroups: [PaletteGroup]? = nil, projectItems: [PaletteEntry],
                                         settingsItems: [PaletteEntry] = [], threadItems: [PaletteEntry],
                                         threadMessageItems: [PaletteEntry] = [], now: Double? = nil) -> [PaletteGroup] {
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if let rootGroups, isInSubmenu {
            let scoped = filter(activeGroups, query: query, isInSubmenu: true, projectItems: projectItems,
                                settingsItems: settingsItems, threadItems: threadItems)
            if !scoped.isEmpty || !hasQuery { return scoped }
            return filter(rootGroups, query: query, isInSubmenu: false, rootGroups: rootGroups, projectItems: projectItems,
                          settingsItems: settingsItems, threadItems: threadItems, threadMessageItems: threadMessageItems, now: now)
        }
        let actionsOnly = query.hasPrefix(">")
        let normalized = PaletteScoring.foldSearchQuery(actionsOnly ? String(query.dropFirst()) : query)
        if normalized.isEmpty {
            return actionsOnly ? activeGroups.filter { $0.value == "actions" } : activeGroups
        }
        var groups = activeGroups
        if actionsOnly {
            groups = groups.filter { $0.value == "actions" }
        } else if !isInSubmenu {
            groups = groups.filter { $0.value != "recent-threads" }
        }
        let searchesEverything = !isInSubmenu && !actionsOnly
        // On equal match classes groups keep this order: threads, what people search for most, right after commands.
        if searchesEverything {
            if let rootGroups, hasQuery {
                let nested = nestedSearchItems(rootGroups.first { $0.value == "actions" }?.items ?? [], query: query)
                if !nested.isEmpty { groups.append(PaletteGroup(value: "nested-search", label: "Suggestions", items: nested)) }
            }
            if !threadItems.isEmpty { groups.append(PaletteGroup(value: "threads-search", label: "Threads", items: threadItems)) }
            if !projectItems.isEmpty { groups.append(PaletteGroup(value: "projects-search", label: "Projects", items: projectItems)) }
            if !settingsItems.isEmpty { groups.append(PaletteGroup(value: "settings-search", label: "Settings", items: settingsItems)) }
        }
        let now = now ?? Double(TimestampFormat.nowMs())
        let ranked = PaletteScoring.rankSearchGroups(groups.map { (group: $0, items: $0.items) }) { item, typos, _ in
            score(item, query: normalized, now: now, typos: typos)
        }
        let threadsMatch = ranked.contains { $0.group.value == "threads-search" }
        var result = ranked.map { entry -> PaletteGroup in
            let value = entry.group.value
            let limit = value == "threads-search" ? PaletteScoring.paletteThreadLimit
                : value == "nested-search" || (searchesEverything && threadsMatch) ? PaletteScoring.paletteSecondaryLimit
                : entry.ranked.count
            // Secondary rows stay below the rest, in score order. Hints are built only for the rows shown.
            let items = (entry.ranked.filter { !$0.item.secondary } + entry.ranked.filter { $0.item.secondary })
                .prefix(limit).map { row -> PaletteEntry in
                    guard row.match.ranges.isEmpty, let hint = row.match.explain?() else { return row.item }
                    var item = row.item
                    item.matchHint = hint
                    return item
                }
            return PaletteGroup(value: value, label: entry.group.label, items: Array(items))
        }
        guard searchesEverything else { return result }
        let listed = Set(result.flatMap { $0.items.map(\.value) })
        let messageItems = threadMessageItems.filter { !listed.contains($0.value) }
        if !messageItems.isEmpty { result.append(PaletteGroup(value: "threads-messages", label: "In messages", items: messageItems)) }
        return result
    }

    /// `buildNestedSearchItems` (CommandPalette.logic.ts:605-632): every option inside a root submenu as one row,
    /// such as "New thread in t3code" or "Change theme: Dracula".
    public static func nestedSearchItems(_ items: [PaletteEntry], query: String) -> [PaletteEntry] {
        let topLevelNames = Set(items.map(\.title))
        let folded = PaletteScoring.foldSearchQuery(query)
        return items.flatMap { parent -> [PaletteEntry] in
            guard case .submenu(let page) = parent.action else { return [] }
            var stem = parent.title
            if stem.hasSuffix("...") { stem.removeLast(3) } else if stem.hasSuffix("\u{2026}") { stem.removeLast() }
            // A query that only names the submenu ("new thread in") wants the submenu row itself.
            if PaletteScoring.foldSearchQuery(stem).hasPrefix(folded) { return [] }
            let prefix = stem == parent.title ? "\(stem): " : "\(stem.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)) "
            return page.groups.flatMap(\.items).compactMap { child in
                guard !child.isSubmenu, !child.isStatic else { return nil }
                let title = prefix + child.title
                guard !topLevelNames.contains(title) else { return nil }
                var row = child
                row.title = title
                // Only the combined title: child keywords like "theme" would list every theme.
                row.searchTerms = [title]
                return row
            }
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
