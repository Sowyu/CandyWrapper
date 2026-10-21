import AppKit
import DesignSystem
import T3Protocol

/// The theme choice and the installed themes on this Mac, kept like T3 keeps them in local storage
/// (useTheme.ts and themePalette.ts): the theme preference (`t3code:theme`), the appearance mode
/// (`t3code:theme-appearance-mode`), the light and dark mix (`t3code:theme-halves:v1`) and the custom theme
/// library (`t3code:themes:v1`, raw entries kept as written). `apply` turns them, with the contrast and glass
/// client settings, into `ThemeRuntime`'s palettes and the window appearance.
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

    /// Applies the saved choice and follows the contrast and glass settings from then on.
    public func start() {
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("appearanceContrast") || keys.contains("glassOpacity") || keys.contains("diffColorScheme") || keys.contains("hydration") || keys.contains("panelAnimationDurationMs") { self?.apply() }
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
            return ThemeDefinition(id: id, label: name, appearance: appearance, colors: colors, variants: variants,
                                   managed: seeded && value["colors"] == nil && value["variants"] == nil)
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

    private func changed() {
        apply()
        for o in observers { o.block() }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: The gallery's pair model (ThemeSettings.tsx:610-660)

    /// The card that owns an appearance; nil is the standard T3 Code card.
    public func ownerCard(_ appearance: ThemeAppearance) -> String? { halves[appearance] ?? definition(preference)?.id }

    /// Rings on a card's circles: the appearances it owns (`pickedModesFor`).
    public func pickedModes(_ cardId: String?) -> [ThemeAppearance] {
        ThemeAppearance.allCases.filter { ownerCard($0) == cardId }
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
    /// and glass settings.
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
        if let preview {
            // `applyThemeColorPreview`: the draft on both sides, in its own appearance.
            input.light = ThemeRuntimeHalf(colors: preview.colors)
            input.dark = input.light
            return (input, preview.appearance.rawValue)
        }
        for a in ThemeAppearance.allCases {
            guard let id = owner(of: a), let d = definition(id) else { continue }
            if d.isWindowGlass {
                // Glass wears the stock palette over a frosted window and frosts every surface.
                if a == .light { input.glassLight = true } else { input.glassDark = true }
                continue
            }
            if d.isDither {
                // Dither wears the stock palette, with its picture in the main panel.
                if a == .light { input.ditherLight = true } else { input.ditherDark = true }
                input.ditherPicture = DitherPicture.path
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
