import Foundation
import T3Protocol

// Providers and models from the server config, shaped for the composer's model picker and traits
// menu. Ported from apps/web/src/providerInstances.ts, components/chat/ModelPickerContent.tsx,
// modelPickerSearch.ts, modelOrdering.ts, TraitsPicker.tsx and packages/shared/src/model.ts.
// Research notes: docs/research/I-composer-flow.md section 5.

/// One configured provider instance (`ProviderInstanceEntry`, providerInstances.ts:116-140).
public struct ProviderInstanceEntry: Hashable, Sendable, Identifiable {
    public let provider: ServerProvider
    public var id: ProviderInstanceId { provider.instanceId }
    public var driver: String { provider.driver }
    public var models: [ServerProviderModel] { provider.models }

    // ponytail: displayName or the humanized instance id; T3 also maps driver slugs to brand names
    // (PROVIDER_DISPLAY_NAMES) when a server omits displayName, add that table when one does
    public var displayName: String {
        if let name = provider.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return provider.instanceId.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public var isAvailable: Bool { provider.availability != "unavailable" }
    /// `isProviderInstancePickerReady`: enabled, available and `ready`.
    public var isReady: Bool { provider.enabled && isAvailable && provider.status == .ready }
    /// Enabled and available: may be chosen even before its probe says ready.
    public var isSelectable: Bool { provider.enabled && isAvailable }
    /// Picker rails show enabled instances only.
    public var isVisibleInPicker: Bool { provider.enabled }

    /// `getDefaultProviderInstanceModel`: declared default, first built-in, first model.
    public var defaultModel: String? {
        models.first { $0.isDefault == true && !$0.isCustom }?.slug ?? models.first { !$0.isCustom }?.slug ?? models.first?.slug
    }

    public func model(_ slug: String) -> ServerProviderModel? {
        models.first { $0.slug == slug } ?? models.first { $0.aliases?.contains(slug) == true }
    }

    /// Runtime modes offered for this provider, in T3's order (ChatComposer.tsx:2161-2174).
    public var runtimeModes: [RuntimeMode] {
        guard let supported = provider.supportedRuntimeModes, !supported.isEmpty else { return RuntimeMode.all }
        return RuntimeMode.all.filter(supported.contains)
    }
}

/// Every provider instance in server order.
public struct ProviderCatalog: Hashable, Sendable {
    public let entries: [ProviderInstanceEntry]

    public init(_ providers: [ServerProvider]) { entries = providers.map(ProviderInstanceEntry.init) }

    public func entry(_ id: ProviderInstanceId?) -> ProviderInstanceEntry? { id.flatMap { id in entries.first { $0.id == id } } }

    /// `resolveSelectableProviderInstanceEntry` (providerInstances.ts:296-310): the first requested
    /// candidate that is selectable, else the first ready instance, else a selectable one not in error.
    public func resolveInstance(_ candidates: [ProviderInstanceId?]) -> ProviderInstanceEntry? {
        for id in candidates { if let e = entry(id), e.isSelectable { return e } }
        return entries.first(where: \.isReady) ?? entries.first { $0.isSelectable && $0.provider.status != .error }
    }
}

// MARK: - Display names

public enum ModelNames {
    /// `getDisplayModelName` (providerIconUtils.ts): the short name when preferred, without a leading
    /// sub-provider qualifier.
    public static func display(_ model: ServerProviderModel, preferShortName: Bool = false) -> String {
        let name = preferShortName ? (model.shortName ?? model.name) : model.name
        guard let q = model.subProvider?.trimmingCharacters(in: .whitespaces), !q.isEmpty,
              name.lowercased().hasPrefix(q.lowercased()) else { return name }
        var rest = name.dropFirst(q.count)
        guard let first = rest.first, first.isWhitespace || ".:/-".contains(first) else { return name }
        rest = rest.drop { $0.isWhitespace || ".:/-".contains($0) }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// The model trigger's label (`getTriggerDisplayModelName`).
    public static func trigger(_ model: ServerProviderModel) -> String { display(model, preferShortName: true) }
}

// MARK: - Favorites

/// A favorite model, stored like T3's client setting `favorites: [{provider, model}]`
/// (contracts settings.ts:414-429). `provider` holds an instance id.
public struct ModelFavorite: Codable, Hashable, Sendable {
    public var provider: ProviderInstanceId
    public var model: String
    public init(provider: ProviderInstanceId, model: String) { self.provider = provider; self.model = model }
}

// MARK: - Search

/// `scoreModelPickerSearch` (modelPickerSearch.ts) on `scoreQueryMatch` (packages/shared/src/searchRanking.ts).
/// Lower is better; nil means no match.
public enum ModelPickerSearch {
    static let favoriteBoost = 24

    public static func normalize(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func searchText(_ m: ServerProviderModel, _ e: ProviderInstanceEntry) -> String {
        normalize([m.name, m.shortName, m.subProvider, e.driver, e.displayName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
    }

    public static func score(_ m: ServerProviderModel, entry e: ProviderInstanceEntry, query: String, isFavorite: Bool) -> Int? {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty { return 0 }
        let fields = [normalize(m.name)] + [m.shortName, m.subProvider].compactMap { $0.map(normalize) }
            + [normalize(e.driver), normalize(e.displayName), searchText(m, e)]
        var score = 0
        for token in tokens {
            var best: Int?
            for (i, field) in fields.enumerated() {
                let base = i * 10
                if let s = queryMatch(field, token, exact: base, prefix: base + 2, boundary: base + 4, includes: base + 6,
                                      fuzzy: token.count >= 3 ? base + 100 : nil) {
                    best = min(best ?? .max, s)
                }
            }
            guard let best else { return nil }
            score += best
        }
        return isFavorite ? score - favoriteBoost : score
    }

    static func lengthPenalty(_ value: [Character], _ query: [Character]) -> Int { min(64, max(0, value.count - query.count)) }

    /// `scoreQueryMatch`: exact, prefix, word boundary, substring, then subsequence.
    static func queryMatch(_ valueString: String, _ queryString: String, exact: Int, prefix: Int, boundary: Int, includes: Int, fuzzy: Int?) -> Int? {
        let value = Array(valueString), query = Array(queryString)
        guard !value.isEmpty, !query.isEmpty else { return nil }
        if value == query { return exact }
        if valueString.hasPrefix(queryString) { return prefix + lengthPenalty(value, query) }
        var bestBoundary: Int?
        for marker in [" ", "-", "_", "/"] {
            if let r = valueString.range(of: marker + queryString) {
                let index = valueString.distance(from: valueString.startIndex, to: r.lowerBound) + 1
                bestBoundary = min(bestBoundary ?? .max, index)
            }
        }
        if let b = bestBoundary { return boundary + b * 2 + lengthPenalty(value, query) }
        if let r = valueString.range(of: queryString) {
            return includes + valueString.distance(from: valueString.startIndex, to: r.lowerBound) * 2 + lengthPenalty(value, query)
        }
        if let fuzzy, let s = subsequence(value, query) { return fuzzy + s }
        return nil
    }

    /// `scoreSubsequenceMatch`.
    static func subsequence(_ value: [Character], _ query: [Character]) -> Int? {
        var qi = 0, first = -1, previous = -1, gaps = 0
        for (vi, c) in value.enumerated() where c == query[qi] {
            if first == -1 { first = vi }
            if previous != -1 { gaps += vi - previous - 1 }
            previous = vi
            qi += 1
            if qi == query.count {
                let span = vi - first + 1 - query.count
                return first * 2 + gaps * 3 + span + min(64, value.count - query.count)
            }
        }
        return nil
    }
}

// MARK: - Picker sections

/// Which rail entry is selected: the Favorites pseudo-entry or one instance.
public enum ModelPickerRail: Hashable, Sendable {
    case favorites
    case instance(ProviderInstanceId)
}

/// One row of the model list.
public enum ModelPickerRow: Hashable, Sendable {
    case model(ModelPickerItem)
    /// The "Legacy models" expander of one instance.
    case legacy(instance: ProviderInstanceId, count: Int, expanded: Bool)
}

public struct ModelPickerItem: Hashable, Sendable {
    public let model: ServerProviderModel
    public let entry: ProviderInstanceEntry
    public let isFavorite: Bool
    public let isSelected: Bool
    public var key: String { "\(entry.id.rawValue):\(model.slug)" }
}

/// One rail button (ModelPickerSidebar.tsx).
public struct ModelPickerRailEntry: Hashable, Sendable {
    public let entry: ProviderInstanceEntry
    /// Not ready and not reachable: drawn at 50% and not clickable.
    public let isDisabled: Bool
    public let tooltip: String
}

/// The picker's derived state for one render: rail entries and list rows. Pure; the view keeps the
/// rail choice, the query and the expanded legacy sections.
public struct ModelPickerSections: Sendable {
    public let rail: [ModelPickerRailEntry]
    public let rows: [ModelPickerRow]
    /// The rail hides while searching (`showSidebar`).
    public let showsRail: Bool

    /// `selectedKeys` (`instance:slug`): the models a multi-model draft picked, each shown selected
    /// (`selectedModelKeySet`, ModelPickerContent.tsx:219-235); nil marks only the active model.
    public init(catalog: ProviderCatalog, active: ProviderInstanceId, activeModel: String, favorites: [ModelFavorite],
                rail selected: ModelPickerRail, query: String, expandedLegacy: Set<ProviderInstanceId>, selectedKeys: Set<String>? = nil) {
        let favoriteKeys = Set(favorites.map { "\($0.provider.rawValue):\($0.model)" })
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let visible = catalog.entries.filter(\.isVisibleInPicker)
        rail = visible.map { e in
            ModelPickerRailEntry(entry: e, isDisabled: !e.isReady, tooltip: Self.tooltip(e))
        }
        showsRail = !searching && !visible.isEmpty

        // `shouldIncludeModelPickerOption`: models of ready instances only.
        // ponytail: the OpenCode and Antigravity "unavailable but selected" exception is skipped; add it with those drivers
        var flat: [ModelPickerItem] = []
        for e in catalog.entries where e.isReady {
            for m in e.models {
                let key = "\(e.id.rawValue):\(m.slug)"
                flat.append(ModelPickerItem(model: m, entry: e, isFavorite: favoriteKeys.contains(key),
                                            isSelected: selectedKeys.map { $0.contains(key) }
                                                ?? (e.id == active && (m.slug == activeModel || m.aliases?.contains(activeModel) == true))))
            }
        }

        if searching {
            let ranked = flat.compactMap { item -> (ModelPickerItem, Int, String)? in
                guard let s = ModelPickerSearch.score(item.model, entry: item.entry, query: query, isFavorite: item.isFavorite) else { return nil }
                return (item, s, ModelPickerSearch.searchText(item.model, item.entry))
            }
            rows = ranked.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.isFavorite != b.0.isFavorite { return a.0.isFavorite }
                return a.2.localizedStandardCompare(b.2) == .orderedAscending
            }.map { .model($0.0) }
            return
        }

        switch selected {
        case .favorites:
            // `sortProviderModelItems` with the instance order; favorites are not grouped.
            let order = Dictionary(uniqueKeysWithValues: catalog.entries.enumerated().map { ($1.id, $0) })
            rows = flat.enumerated().filter { $0.element.isFavorite }
                .sorted { (order[$0.element.entry.id] ?? .max, $0.offset) < (order[$1.element.entry.id] ?? .max, $1.offset) }
                .map { .model($0.element) }
        case .instance(let id):
            // Favorites first, then server order; legacy models fold under one expander.
            let items = flat.enumerated().filter { $0.element.entry.id == id }
                .sorted { ($0.element.isFavorite ? 0 : 1, $0.offset) < ($1.element.isFavorite ? 0 : 1, $1.offset) }
                .map(\.element)
            let current = items.filter { $0.model.isLegacy != true }
            let legacy = items.filter { $0.model.isLegacy == true }
            if legacy.isEmpty {
                rows = items.map { .model($0) }
            } else {
                let expanded = expandedLegacy.contains(id)
                rows = current.map { .model($0) } + [.legacy(instance: id, count: legacy.count, expanded: expanded)]
                    + (expanded ? legacy.map { .model($0) } : [])
            }
        }
    }

    /// `describeUnavailableInstance` (ModelPickerSidebar.tsx:19-31).
    static func tooltip(_ e: ProviderInstanceEntry) -> String {
        let label = e.displayName
        if !e.provider.enabled || e.provider.status == .disabled { return "\(label) — Disabled in settings." }
        if e.isReady { return label }
        let kind = e.provider.status == .error ? "Unavailable" : e.provider.status == .warning ? "Limited" : "Not ready"
        if let msg = e.provider.message?.trimmingCharacters(in: .whitespaces), !msg.isEmpty { return "\(label) — \(kind). \(msg)" }
        return "\(label) — \(kind)."
    }

    /// Initial rail choice (ModelPickerContent.tsx:254-266): Favorites when any exist, else the active instance.
    public static func initialRail(active: ProviderInstanceId, favorites: [ModelFavorite], catalog: ProviderCatalog) -> ModelPickerRail {
        if let e = catalog.entry(active), !e.isReady { return .instance(active) }
        return favorites.isEmpty ? .instance(active) : .favorites
    }

    /// `adjacentModelPickerProvider`: Favorites, then the ready instances, wrapping around.
    public static func adjacentRail(_ current: ModelPickerRail, direction: Int, catalog: ProviderCatalog) -> ModelPickerRail {
        let order: [ModelPickerRail] = [.favorites] + catalog.entries.filter { $0.isVisibleInPicker && $0.isReady }.map { .instance($0.id) }
        guard let i = order.firstIndex(of: current) else { return direction > 0 ? order[0] : order[order.count - 1] }
        return order[(i + direction + order.count) % order.count]
    }
}

// MARK: - Traits

/// Option descriptors resolved against a selection, and the selections a pick or a send produces
/// (packages/shared/src/model.ts:124-300, composerProviderState.tsx:73-155, TraitsPicker.tsx:494-566).
public enum ModelTraits {
    static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func defaultChoice(_ d: ProviderOptionDescriptor) -> String? { d.options.first { $0.isDefault == true }?.id }

    /// `resolveDescriptorChoiceValue`.
    static func resolveChoice(_ d: ProviderOptionDescriptor, _ raw: String?) -> String? {
        guard let t = trimmed(raw) else { return d.currentValue?.string ?? defaultChoice(d) }
        if d.options.isEmpty { return t }
        if d.promptInjectedValues?.contains(t) == true, d.options.contains(where: { $0.id == t }) { return defaultChoice(d) }
        if d.options.contains(where: { $0.id == t }) { return t }
        return d.currentValue?.string ?? defaultChoice(d)
    }

    /// `getProviderOptionDescriptors`: the model's descriptors with `currentValue` set from the selections.
    public static func descriptors(_ model: ServerProviderModel?, selections: [ProviderOptionSelection]?) -> [ProviderOptionDescriptor] {
        (model?.optionDescriptors ?? []).compactMap { base in
            var d = base
            let raw = selections?.first { $0.id == d.id }?.value ?? d.currentValue
            switch d.type {
            case .boolean:
                if case .bool(let b) = raw { d.currentValue = .bool(b) }
            case .select:
                let v = raw?.string.map { resolveChoice(d, $0) } ?? resolveChoice(d, d.currentValue?.string)
                d.currentValue = v.map { .string($0) }
            default:
                return nil
            }
            return d
        }
    }

    /// `getProviderOptionCurrentValue` without reported selections.
    public static func currentValue(_ d: ProviderOptionDescriptor) -> ProviderOptionValue? {
        if d.type == .boolean { return d.currentValue }
        if let v = d.currentValue?.string { return .string(v) }
        return defaultChoice(d).map { .string($0) }
    }

    /// `getProviderOptionCurrentLabel`.
    public static func currentLabel(_ d: ProviderOptionDescriptor) -> String? {
        if d.type == .boolean { return d.currentValue?.bool.map { $0 ? "On" : "Off" } }
        let v = currentValue(d)?.string
        return d.options.first { $0.id == v }?.label
    }

    /// `buildProviderOptionSelectionsFromDescriptors`: every descriptor's current value.
    public static func selections(from descriptors: [ProviderOptionDescriptor]) -> [ProviderOptionSelection]? {
        let out = descriptors.compactMap { d in currentValue(d).map { ProviderOptionSelection(id: d.id, value: $0) } }
        return out.isEmpty ? nil : out
    }

    /// What a trait pick stores: the descriptors with one value replaced, flattened to selections
    /// (TraitsPicker.tsx `updateDescriptors(replaceDescriptorCurrentValue(...))`).
    public static func pick(_ descriptors: [ProviderOptionDescriptor], id: String, value: ProviderOptionValue) -> [ProviderOptionSelection]? {
        selections(from: descriptors.map { d in
            guard d.id == id else { return d }
            var n = d
            switch (d.type, value) {
            case (.boolean, .bool), (.select, .string): n.currentValue = value
            default: break
            }
            return n
        })
    }

    /// `withImplicitFastModeDefault`: a `fastMode:false` when the model has the switch and nothing set it.
    public static func withImplicitFastMode(_ model: ServerProviderModel?, _ selections: [ProviderOptionSelection]?) -> [ProviderOptionSelection]? {
        if selections?.contains(where: { $0.id == "fastMode" }) == true { return selections }
        guard model?.optionDescriptors.contains(where: { $0.type == .boolean && $0.id == "fastMode" }) == true else { return selections }
        return (selections ?? []) + [ProviderOptionSelection(id: "fastMode", value: .bool(false))]
    }

    /// The options a send carries (`modelOptionsForDispatch`): only ids that were set explicitly,
    /// resolved against the descriptors, plus the implicit fast mode default.
    public static func dispatchOptions(_ model: ServerProviderModel?, _ selections: [ProviderOptionSelection]?) -> [ProviderOptionSelection]? {
        let withFast = withImplicitFastMode(model, selections)
        guard let withFast, !withFast.isEmpty else { return nil }
        let ids = Set(withFast.map(\.id))
        let out = (Self.selections(from: descriptors(model, selections: withFast)) ?? []).filter { ids.contains($0.id) }
        return out.isEmpty ? nil : out
    }

    static let reasoningIds: Set<String> = ["reasoningEffort", "reasoning", "effort", "variant", "thinking"]

    /// `buildTraitsTriggerDisplay`: labels joined by " · ", Fast merged into the reasoning label.
    /// `ultrathink` is true when the prompt carries the Ultrathink prefix or word.
    // ponytail: the Codex `serviceTier` speed rule is skipped; add it when a Codex instance is ready
    public static func triggerLabel(_ descriptors: [ProviderOptionDescriptor], ultrathink: Bool = false) -> String {
        var fastFallback: String?, speed: String?, reasoningIndex = -1
        var labels: [String] = []
        let primary = descriptors.first { $0.type == .select }?.id
        for d in descriptors {
            if d.id == "fastMode", d.type == .boolean {
                speed = d.currentValue?.bool == true ? "Fast" : nil
                fastFallback = speed ?? "Normal"
                continue
            }
            let label = ultrathink && d.id == primary ? "Ultrathink"
                : d.type == .boolean ? "\(d.label) \(d.currentValue?.bool == true ? "On" : "Off")" : currentLabel(d)
            guard let label, !label.isEmpty else { continue }
            if reasoningIndex == -1, d.type == .select, reasoningIds.contains(d.id) { reasoningIndex = labels.count }
            labels.append(label)
        }
        if labels.isEmpty, let fastFallback { return fastFallback }
        if let speed {
            if reasoningIndex >= 0 { labels[reasoningIndex] += " \(speed)" } else { labels.append(speed) }
        }
        return labels.joined(separator: " · ")
    }

    // MARK: Ultrathink (packages/shared/src/model.ts:302-305, 510-529)

    public static let ultrathinkPrefix = "Ultrathink:\n"

    /// `isClaudeUltrathinkPrompt`: the word "ultrathink" anywhere.
    public static func isUltrathinkPrompt(_ text: String) -> Bool {
        text.range(of: #"\bultrathink\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when the body (without our prefix) names ultrathink, which locks the effort control.
    public static func ultrathinkInBody(_ text: String) -> Bool {
        isUltrathinkPrompt(text.replacingOccurrences(of: #"^Ultrathink:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }

    /// `applyClaudePromptEffortPrefix` for `ultrathink`: prefixes the prompt unless it is a slash command.
    public static func applyUltrathinkPrefix(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return ultrathinkPrefix }
        if t.range(of: #"^/[^\s/]+(\s|$)"#, options: .regularExpression) != nil || t.hasPrefix("Ultrathink:") { return t }
        return ultrathinkPrefix + t
    }

    /// Picking another effort strips the prefix.
    public static func stripUltrathinkPrefix(_ text: String) -> String {
        text.replacingOccurrences(of: #"^Ultrathink:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
}
