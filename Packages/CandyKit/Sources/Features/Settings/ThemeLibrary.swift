import AppKit
import DesignSystem
import T3Protocol

/// The theme choice and the installed themes on this Mac, kept like T3 keeps them in local storage
/// (useTheme.ts and themePalette.ts): the theme preference (`t3code:theme`), the appearance mode
/// (`t3code:theme-appearance-mode`), the light and dark mix (`t3code:theme-halves:v1`) and the custom theme
/// library (`t3code:themes:v1`, raw entries kept as written). `apply` turns them, with the contrast and glass
/// opacity client settings, into `ThemeRuntime`'s palettes and the window appearance.
@MainActor
public final class ThemeLibrary {
    public static let shared = ThemeLibrary()

    public struct Halves: Equatable, Sendable {
        public var light: String?
        public var dark: String?
        public init(light: String? = nil, dark: String? = nil) { self.light = light; self.dark = dark }
        public subscript(_ a: ThemeAppearance) -> String? {
            get { a == .light ? light : dark }
            set { if a == .light { light = newValue } else { dark = newValue } }
        }
        var isEmpty: Bool { light == nil && dark == nil }
    }

    /// A draft the theme editor paints on the live app (`applyThemeColorPreview`).
    public struct Preview: Equatable {
        public var colors: [ThemeColorRole: String]
        public var appearance: ThemeAppearance
        public init(colors: [ThemeColorRole: String], appearance: ThemeAppearance) { self.colors = colors; self.appearance = appearance }
    }

    static let preferenceKey = "theme.preference"
    /// Shared with the command palette's `AppearanceMode`.
    public static let appearanceModeKey = "appearance.mode"
    static let halvesKey = "theme.halves.v1"
    static let customThemesKey = "theme.customThemes.v1"

    public private(set) var environmentThemes: [ThemeDefinition] = []
    private var publishedRaw: [JSONValue] = []
    private let defaults: UserDefaults
    private var observers: [(id: Int, block: @MainActor () -> Void)] = []
    private var nextObserver = 0
    public var preview: Preview? { didSet { if preview != oldValue { apply() } } }
    /// Off while a development flag pins the window appearance (`--appearance`).
    public var controlsAppearance = true

    /// `CANDY_THEME=<id>` pins the theme over the stored choice and its light and dark mix, for perf runs and
    /// snapshots. The stored choice stays as it was.
    public static let environmentPin: String? = ProcessInfo.processInfo.environment["CANDY_THEME"].flatMap { $0.isEmpty ? nil : $0 }
    let pinned: String?

    public init(defaults: UserDefaults = .standard, pinned: String? = ThemeLibrary.environmentPin) {
        self.defaults = defaults
        self.pinned = pinned
    }

    /// Applies the saved choice and follows the contrast and glass opacity settings from then on.
    public func start() {
        migrateRemovedGlass()
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("appearanceContrast") || keys.contains("glassOpacity") || keys.contains("ditherAccent") || keys.contains("redesignGradientAnimate") || keys.contains("redesignInsetPanel") || keys.contains("redesignProjectAvatars") || keys.contains("diffColorScheme") || keys.contains("hydration") || keys.contains("panelAnimationDurationMs") { self?.apply() }
        }
        SettingsFontRuntime.start()
        apply()
    }

    // MARK: Stored state

    /// "system", "light", "dark" or a theme id (`readThemePreference`, canonical ids).
    public var preference: String {
        let raw = pinned ?? defaults.string(forKey: Self.preferenceKey) ?? "system"
        let canonical = raw == "t3-chat-dark" ? raw : ThemePalette.normalizedId(raw)
        return ["system", "light", "dark"].contains(canonical) || definition(canonical) != nil ? canonical : "system"
    }

    public var appearanceMode: String {
        let raw = defaults.string(forKey: Self.appearanceModeKey) ?? "system"
        return ["system", "light", "dark"].contains(raw) ? raw : "system"
    }

    /// `parseThemeHalves`: halves naming a theme that can't render that side are dropped.
    public var halves: Halves {
        let raw = pinned == nil ? rawHalves : Halves()
        var out = Halves()
        for a in ThemeAppearance.allCases {
            if let id = raw[a], let d = definition(id), d.colors(for: a) != nil { out[a] = d.id }
        }
        return out
    }

    var rawHalves: Halves {
        guard let data = defaults.data(forKey: Self.halvesKey),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Halves() }
        return Halves(light: o["light"] as? String, dark: o["dark"] as? String)
    }

    /// Raw stored entries, so a write never drops what this build can't read.
    private var storedThemes: [Any] {
        guard let data = defaults.data(forKey: Self.customThemesKey),
              let a = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return a
    }

    /// `parseStoredThemes`: valid entries, first one per id.
    public var customThemes: [ThemeDefinition] {
        var out: [ThemeDefinition] = []
        for v in storedThemes {
            if let t = ThemePalette.parseStored(v), !out.contains(where: { $0.id == t.id }) { out.append(t) }
        }
        return out
    }

    /// `getThemeDefinition`: built-ins first, then saved themes.
    public func definition(_ id: String) -> ThemeDefinition? {
        let id = ThemePalette.normalizedId(id)
        return ThemeDefinition.pickerBuiltIns.first { $0.id == id } ?? customThemes.first { $0.id == id } ?? environmentThemes.first { $0.id == id }
    }

    /// useEnvironmentTheme.ts:24-96. Published themes are transient and cannot replace reserved ids.
    public func setEnvironmentThemes(_ values: [JSONValue]) {
        guard values != publishedRaw else { return }
        publishedRaw = values
        environmentThemes = values.compactMap(Self.publishedTheme)
        changed()
    }

    /// The background image revision for `themeId` (`EnvironmentTheme.background`, themeBackground.ts:61-66),
    /// or nil when the theme has none, its CSS never shows it, or a saved theme owns the id.
    public func backgroundRevision(_ themeId: String?) -> String? {
        guard let themeId, !customThemes.contains(where: { $0.id == themeId }),
              let raw = publishedRaw.first(where: { $0["id"]?.stringValue == themeId }),
              environmentThemes.contains(where: { $0.id == themeId }),
              let revision = raw["background"]?.stringValue, !revision.isEmpty,
              ThemeCSSVariables.usesBackgroundImage(raw["css"]?.stringValue) else { return nil }
        return revision
    }

    /// One published theme, or nil when it is invalid or claims a reserved id.
    public static func publishedTheme(_ value: JSONValue) -> ThemeDefinition? {
            guard let id = value["id"]?.stringValue, ThemePalette.isThemeId(id), !ThemePalette.reservedIds.contains(id),
                  let name = value["name"]?.stringValue, let raw = value["appearance"]?.stringValue,
                  let appearance = ThemeAppearance(rawValue: raw) else { return nil }
            func overrides(_ v: JSONValue?) -> [ThemeColorRole: String] {
                var result: [ThemeColorRole: String] = [:]
                for (key, value) in v?.objectValue ?? [:] {
                    if let role = ThemeColorRole(rawValue: key), let text = value.stringValue, let color = ThemePalette.canonical(text) { result[role] = color }
                }
                return result
            }
            let canvas = value["canvas"]?.stringValue, accent = value["accent"]?.stringValue
            let seeded = canvas.flatMap(ThemePalette.canonical) != nil && accent.flatMap(ThemePalette.canonical) != nil
            let own = overrides(value["colors"]), other = overrides(value["variants"]?[appearance.other.rawValue])
            guard seeded || !own.isEmpty || !other.isEmpty else { return nil }
            var colors = seeded ? ThemePalette.vividColors(appearance, background: canvas!, accent: accent!) : ThemePalette.defaultColors(appearance)
            colors.merge(own) { _, new in new }
            var variants: [ThemeAppearance: [ThemeColorRole: String]] = [:]
            if value["variants"]?[appearance.other.rawValue] != nil {
                var base = ThemePalette.defaultColors(appearance.other); base.merge(other) { _, new in new }; variants[appearance.other] = base
            }
            // The color variables its `css` sets (ThemeCSSVariables); a side the theme lacks stays unpainted.
            let css = ThemeCSSVariables.overrides(value["css"]?.stringValue)
            if !css.isEmpty {
                colors.merge(css.colors(for: appearance)) { $1 }
                variants[appearance.other]?.merge(css.colors(for: appearance.other)) { $1 }
            }
            return ThemeDefinition(id: id, label: name, appearance: appearance, colors: colors, variants: variants,
                                   managed: seeded && value["colors"] == nil && value["variants"] == nil)
        }

    // MARK: Removed Glass theme (1.17.0)

    /// Set when `migrateRemovedGlass` moved a saved Glass choice to the default theme, until the app shows its note.
    static let glassRemovedNoticeKey = "theme.glassRemovedNotice"

    /// Moves every saved choice of the removed Glass theme to the default T3 Code theme in that appearance: the
    /// theme preference, each light or dark side, and the selection Redesign sits over. Returns whether it changed
    /// anything, and then leaves the one-time note pending. A second run finds nothing to move.
    @discardableResult
    func migrateRemovedGlass() -> Bool {
        let removed = ThemePalette.removedGlassIds
        var moved = false
        if let p = defaults.string(forKey: Self.preferenceKey), removed.contains(p) {
            defaults.set(appearanceMode, forKey: Self.preferenceKey)
            moved = true
        }
        let raw = rawHalves
        if raw.light.map(removed.contains) == true || raw.dark.map(removed.contains) == true {
            var o: [String: String] = [:]
            if let l = raw.light, !removed.contains(l) { o["light"] = l }
            if let d = raw.dark, !removed.contains(d) { o["dark"] = d }
            if o.isEmpty { defaults.removeObject(forKey: Self.halvesKey) }
            else { defaults.set(try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), forKey: Self.halvesKey) }
            moved = true
        }
        if let data = defaults.data(forKey: Self.preRedesignKey),
           var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
           o.values.contains(where: removed.contains) {
            if let p = o["preference"], removed.contains(p) { o["preference"] = appearanceMode }
            for side in ["light", "dark"] where o[side].map(removed.contains) == true { o[side] = nil }
            defaults.set(try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), forKey: Self.preRedesignKey)
            moved = true
        }
        if moved { defaults.set(true, forKey: Self.glassRemovedNoticeKey) }
        return moved
    }

    /// Whether the "Glass theme removed" note is still due. Taking it clears it, so it shows once.
    public func takeGlassRemovedNotice() -> Bool {
        guard defaults.bool(forKey: Self.glassRemovedNoticeKey) else { return false }
        defaults.removeObject(forKey: Self.glassRemovedNoticeKey)
        return true
    }

    // MARK: Writes (useTheme.ts setters)

    /// `setTheme`: keeps the appearance mode, clears the mix.
    public func setTheme(_ preference: String) {
        defaults.set(appearanceMode, forKey: Self.appearanceModeKey)
        defaults.removeObject(forKey: Self.halvesKey)
        defaults.set(preference, forKey: Self.preferenceKey)
        changed()
    }

    public func setAppearanceMode(_ mode: String) {
        defaults.set(mode, forKey: Self.appearanceModeKey)
        changed()
    }

    /// `setThemeHalf`: nil removes that side.
    public func setThemeHalf(_ appearance: ThemeAppearance, _ id: String?) {
        var next = rawHalves
        next[appearance] = id
        if next.isEmpty {
            defaults.removeObject(forKey: Self.halvesKey)
        } else {
            var o: [String: String] = [:]
            if let l = next.light { o["light"] = l }
            if let d = next.dark { o["dark"] = d }
            defaults.set(try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), forKey: Self.halvesKey)
        }
        changed()
    }

    public func clearThemeHalves() {
        defaults.removeObject(forKey: Self.halvesKey)
        changed()
    }

    /// `installCustomTheme` (1225-1240).
    @discardableResult
    public func install(_ theme: ThemeDefinition) throws -> ThemeDefinition {
        if ThemePalette.reservedIds.contains(theme.id) { throw ThemePalette.FileError(message: "The theme id \"\(theme.id)\" is reserved.") }
        let stored = storedThemes
        if ThemeDefinition.pickerBuiltIns.contains(where: { $0.id == theme.id }) || stored.contains(where: { Self.id(of: $0) == theme.id }) {
            throw ThemePalette.FileError(message: "A theme named \"\(theme.label)\" is already installed.")
        }
        save(stored + [ThemePalette.storedObject(theme)])
        return customThemes.first { $0.id == theme.id } ?? theme
    }

    /// `updateCustomTheme` (1242-1270): replaces the first entry with the id and drops duplicates.
    @discardableResult
    public func update(_ theme: ThemeDefinition) throws -> ThemeDefinition {
        if ThemePalette.reservedIds.contains(theme.id) { throw ThemePalette.FileError(message: "The theme id \"\(theme.id)\" is reserved.") }
        guard customThemes.contains(where: { $0.id == theme.id }) else {
            throw ThemePalette.FileError(message: "The theme \"\(theme.label)\" is not installed.")
        }
        var next: [Any] = []
        var replaced = false
        for v in storedThemes {
            if Self.id(of: v) != theme.id { next.append(v) } else if !replaced { next.append(ThemePalette.storedObject(theme)); replaced = true }
        }
        save(next)
        return customThemes.first { $0.id == theme.id } ?? theme
    }

    /// `removeCustomThemes` (1333-1348).
    public func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        save(storedThemes.filter { v in Self.id(of: v).map { !ids.contains($0) } ?? true })
    }

    private static func id(of stored: Any) -> String? { (stored as? [String: Any])?["id"] as? String }

    private func save(_ stored: [Any]) {
        defaults.set(try? JSONSerialization.data(withJSONObject: stored), forKey: Self.customThemesKey)
        changed()
    }

    // MARK: Observing

    @discardableResult
    public func observe(_ block: @escaping @MainActor () -> Void) -> Int {
        nextObserver += 1
        observers.append((nextObserver, block))
        return nextObserver
    }

    public func removeObserver(_ id: Int) { observers.removeAll { $0.id == id } }

    /// Posted after any change to the stored choice or the library.
    public static let didChange = Notification.Name("CandyThemeLibraryDidChange")

    private var holding = 0, heldChange = false

    /// Runs `body` with one change notification at the end, so a switch made of several writes applies once.
    func batch(_ body: () -> Void) {
        holding += 1
        body()
        holding -= 1
        if holding == 0, heldChange { heldChange = false; changed() }
    }

    private func changed() {
        if holding > 0 { heldChange = true; return }
        apply()
        for o in observers { o.block() }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: The gallery's pair model (ThemeSettings.tsx:610-660)

    /// The card that owns an appearance; nil is the standard T3 Code card.
    public func ownerCard(_ appearance: ThemeAppearance) -> String? { halves[appearance] ?? definition(preference)?.id }

    /// The card that owns an appearance where Redesign is off: what the grid shows and edits. Redesign has no card;
    /// it is turned on and off in Settings > Redesign.
    public func underlyingOwnerCard(_ appearance: ThemeAppearance) -> String? {
        let u = underlying
        if let id = u[appearance], let d = definition(id), d.colors(for: appearance) != nil { return d.id }
        return definition(u.preference)?.id
    }

    /// Rings on a card's circles: the appearances it owns where Redesign is off (`pickedModesFor`).
    public func pickedModes(_ cardId: String?) -> [ThemeAppearance] {
        ThemeAppearance.allCases.filter { underlyingOwnerCard($0) == cardId }
    }

    /// `persistTheme(appearanceMode === "system" ? "system" : appearanceMode)`: back to the standard look.
    public func useStandard() { setTheme(appearanceMode) }

    /// `assignHalf`: one appearance to a card. Picking the standard card over a themed base turns the base
    /// into an explicit half on the other side.
    public func assignHalf(_ appearance: ThemeAppearance, _ cardId: String?) {
        let base = definition(preference)?.id
        if cardId == nil, let base {
            let other = rawHalves[appearance.other] ?? base
            setTheme(appearanceMode)
            setThemeHalf(appearance.other, other)
            return
        }
        setThemeHalf(appearance, cardId)
    }

    /// A saved or imported theme's card click: a one-appearance theme takes its side, others become the base.
    public func use(_ theme: ThemeDefinition) {
        if let single = theme.singleAppearance { assignHalf(single, theme.id) } else { setTheme(theme.id) }
    }

    /// `handleConfirmRemoveTheme` (ThemeSettings.tsx:560-597): moves the selection off removed themes first.
    public func removeThemes(_ ids: Set<String>) {
        let removesBase = ids.contains(definition(preference)?.id ?? "")
        let stored = rawHalves
        if removesBase { setTheme(appearanceMode) }
        for a in ThemeAppearance.allCases {
            guard let half = stored[a] else { continue }
            if ids.contains(half) { setThemeHalf(a, nil) } else if removesBase { setThemeHalf(a, half) }
        }
        remove(ids)
    }

    // MARK: The Redesign switch (Settings > Redesign)

    /// The theme in use before Redesign turned on: `{preference, light?, dark?}`. It is what applies where Redesign
    /// is off, and what the Themes grid edits while Redesign is on.
    static let preRedesignKey = "theme.preRedesign"
    /// Settings > Redesign's "Use in": "both", "dark" or "light", kept while Redesign is off for the next switch on.
    static let redesignUseInKey = "theme.redesignUseIn"

    /// A theme choice: the base preference and the halves over it.
    public struct Selection: Equatable, Sendable {
        public var preference: String
        public var light: String?
        public var dark: String?
        public subscript(_ a: ThemeAppearance) -> String? { a == .light ? light : dark }
    }

    /// Redesign paints either appearance, whether the switch or an older build's theme card chose it.
    public var isRedesignOn: Bool { !redesignAppearances.isEmpty }

    /// The appearances Redesign paints.
    public var redesignAppearances: Set<ThemeAppearance> {
        Set(ThemeAppearance.allCases.filter { owner(of: $0) == ThemeDefinition.dither.id })
    }

    /// The appearances "Use in" turns Redesign on for: both unless the user chose one.
    public var redesignUseIn: Set<ThemeAppearance> {
        switch defaults.string(forKey: Self.redesignUseInKey) {
        case "dark": [.dark]
        case "light": [.light]
        default: Set(ThemeAppearance.allCases)
        }
    }

    private func usableUnder(_ id: String?) -> Bool {
        guard let id else { return false }
        return ["system", "light", "dark"].contains(id) || (definition(id).map { !$0.isDither } ?? false)
    }

    /// The selection where Redesign is off: the stored one while Redesign is off, else the one it replaced. A
    /// Redesign chosen from an older build's card saved nothing, so the standard look stands under it.
    public var underlying: Selection {
        let ditherId = ThemeDefinition.dither.id
        let raw = rawHalves
        guard isRedesignOn else { return Selection(preference: preference, light: raw.light, dark: raw.dark) }
        if let o = defaults.data(forKey: Self.preRedesignKey).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }),
           usableUnder(o["preference"]) {
            return Selection(preference: o["preference"]!, light: usableUnder(o["light"]) ? o["light"] : nil,
                             dark: usableUnder(o["dark"]) ? o["dark"] : nil)
        }
        return Selection(preference: preference == ditherId ? appearanceMode : preference,
                         light: raw.light == ditherId ? nil : raw.light, dark: raw.dark == ditherId ? nil : raw.dark)
    }

    private func write(_ s: Selection) {
        setTheme(s.preference)
        if let l = s.light { setThemeHalf(.light, l) }
        if let d = s.dark { setThemeHalf(.dark, d) }
    }

    /// Settings > Redesign's "Use in": saved for the next switch on, and applied at once while Redesign is on.
    public func setRedesignUseIn(_ appearances: Set<ThemeAppearance>) {
        guard !appearances.isEmpty else { return }
        defaults.set(appearances.count > 1 ? "both" : appearances.contains(.dark) ? "dark" : "light", forKey: Self.redesignUseInKey)
        if isRedesignOn { setRedesign(in: appearances) } else { changed() }
    }

    /// The master switch: on in the appearances "Use in" names, or off, bringing back the theme Redesign replaced.
    public func setRedesign(_ on: Bool) { setRedesign(in: on ? redesignUseIn : []) }

    /// Redesign in exactly these appearances; the others show the underlying selection.
    public func setRedesign(in appearances: Set<ThemeAppearance>) {
        guard appearances != redesignAppearances else { return }
        let u = underlying
        batch {
            guard !appearances.isEmpty else {
                defaults.removeObject(forKey: Self.preRedesignKey)
                write(u)
                return
            }
            var o = ["preference": u.preference]
            o["light"] = u.light
            o["dark"] = u.dark
            defaults.set(try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), forKey: Self.preRedesignKey)
            if appearances.count == ThemeAppearance.allCases.count {
                setTheme(ThemeDefinition.dither.id)
            } else {
                write(u)
                for a in appearances { setThemeHalf(a, ThemeDefinition.dither.id) }
            }
        }
    }

    /// Runs a Themes grid change on the selection Redesign sits over, then puts Redesign back where it was, so a
    /// card picked while Redesign is on takes effect where Redesign is off and when it is turned off.
    public func keepingRedesign(_ body: () -> Void) {
        let on = redesignAppearances
        guard !on.isEmpty, pinned == nil else { body(); return }
        let u = underlying
        batch {
            defaults.removeObject(forKey: Self.preRedesignKey)
            write(u)
            body()
            setRedesign(in: on)
        }
    }

    // MARK: Applying (applyTheme, useTheme.ts:375-412)

    /// The theme that paints an appearance (`resolveThemeHalf`).
    public func owner(of appearance: ThemeAppearance) -> String? {
        let base = definition(preference)?.id
        return halves[appearance] ?? base
    }

    /// `resolveDesktopTheme` (1593-1619): what the window wears; a theme that can't render one side pins it.
    public func desktopAppearance() -> String {
        let mode = appearanceMode
        let halves = halves
        let d = definition(preference)
        if mode == "system" {
            let hasLight = halves.light != nil || d?.colors(for: .light) != nil
            let hasDark = halves.dark != nil || d?.colors(for: .dark) != nil
            return d != nil && (!hasLight || !hasDark) ? d!.appearance.rawValue : "system"
        }
        let a = ThemeAppearance(rawValue: mode)!
        if halves[a] != nil { return mode }
        if let d, d.colors(for: a) == nil { return d.appearance.rawValue }
        return mode
    }

    /// The palettes and window appearance for the stored choice (or the editor's draft), with the contrast
    /// and glass opacity settings.
    public func apply(client: ClientSettings = ClientSettingsStore.shared.current, app: NSApplication? = NSApp) {
        SettingsPanelMotion.durationMs = client.int("panelAnimationDurationMs")
        let (input, forced) = runtimeInput(client: client)
        if let app, controlsAppearance {
            let target: NSAppearance? = forced == "light" ? NSAppearance(named: .aqua) : forced == "dark" ? NSAppearance(named: .darkAqua) : nil
            if app.appearance?.name != target?.name { app.appearance = target }
        }
        ThemeRuntime.apply(input)
    }

    /// What `apply` hands the theme runtime, and the appearance the window must wear ("system" for either).
    func runtimeInput(client: ClientSettings) -> (ThemeRuntimeInput, forced: String) {
        var input = ThemeRuntimeInput(contrast: client.int("appearanceContrast"), glassOpacity: client.int("glassOpacity"))
        input.blueOrangeDiff = client.string("diffColorScheme") == "blue-orange"
        // Gradient is Redesign's one background (the user, 2026-11-27: "lets just only do the gradient theme"). A stored
        // `redesignBackground`, picture, ink, dot size, dim, tint or thread flower stays in the settings and is ignored.
        input.ditherGradientAnimates = client.bool("redesignGradientAnimate")
        input.projectSprites = client.string("redesignProjectAvatars") != "letters"
        input.insetPanel = client.bool("redesignInsetPanel")
        let accent = DitherAccent.named(client.string("ditherAccent"))
        input.ditherAccent = accent.id
        if let preview {
            // `applyThemeColorPreview`: the draft on both sides, in its own appearance.
            input.light = ThemeRuntimeHalf(colors: preview.colors)
            input.dark = input.light
            return (input, preview.appearance.rawValue)
        }
        for a in ThemeAppearance.allCases {
            guard let id = owner(of: a), let d = definition(id) else { continue }
            if d.isDither {
                // Dither wears its own palette (after Capy), with Gradient in the main panel.
                if a == .light { input.ditherLight = true } else { input.ditherDark = true }
                var colors = d.colors(for: a) ?? d.colors
                // The accent replaces its roles once, so every accent use follows, teal included: skipping teal left
                // the default dark send button and Approve white on teal at 3.7:1 (X8, 2026-11-27).
                colors.merge(accent.colors(dark: a == .dark)) { $1 }
                let half = ThemeRuntimeHalf(colors: colors)
                if a == .light { input.light = half } else { input.dark = half }
                continue
            }
            // `applyThemePalette` falls back to the base colors for a side the theme lacks.
            let half = ThemeRuntimeHalf(colors: d.colors(for: a) ?? d.colors, builtInId: d.isBuiltIn ? d.id : nil)
            if a == .light { input.light = half } else { input.dark = half }
        }
        return (input, desktopAppearance())
    }

    /// The appearance on screen now (T3's `resolvedTheme`).
    public var resolvedAppearance: ThemeAppearance {
        (NSApp?.effectiveAppearance.isDark ?? false) ? .dark : .light
    }
}
