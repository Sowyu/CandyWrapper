import AppKit
import DesignSystem

/// What the theme editor opens on (themeEditorStore.ts `ThemeEditorSessionInput`).
public struct ThemeEditorSession: Equatable {
    public var editingThemeId: String?
    public var seedThemeId: String?
    public var seedName: String?
    public var initialAppearance: ThemeAppearance
    public init(editingThemeId: String?, seedThemeId: String?, seedName: String?, initialAppearance: ThemeAppearance) {
        self.editingThemeId = editingThemeId; self.seedThemeId = seedThemeId; self.seedName = seedName; self.initialAppearance = initialAppearance
    }
}

/// One color family of the advanced editor (ThemeEditorPanel.tsx:52-238).
public struct ThemeEditorFamily: Equatable, Sendable {
    public let id: String, label: String, role: ThemeColorRole, roles: [ThemeColorRole]

    public struct Group: Sendable {
        public let id: String, title: String, families: [ThemeEditorFamily]
        init(_ id: String, _ title: String, _ families: [ThemeEditorFamily]) { self.id = id; self.title = title; self.families = families }
    }

    public static let groups: [Group] = [
        .init("foundation", "Foundation", [
            .init(id: "background", label: "Background", role: .canvas, roles: [.canvas, .chrome, .toolbar]),
            .init(id: "surface", label: "Surface", role: .surface, roles: [.surface]),
            .init(id: "raised-surface", label: "Raised surface", role: .surfaceRaised, roles: [.surfaceRaised]),
            .init(id: "overlay", label: "Overlay", role: .surfaceOverlay, roles: [.surfaceOverlay]),
            .init(id: "text", label: "Text", role: .text, roles: [.text, .toolbarForeground, .toolbarControlForeground]),
            .init(id: "muted-text", label: "Muted text", role: .mutedForeground,
                  roles: [.textMuted, .mutedForeground, .placeholder, .secondaryLabel, .iconMuted, .sidebarMutedForeground]),
            .init(id: "border", label: "Border", role: .border, roles: [.border, .toolbarBorder, .sidebarBorder]),
            .init(id: "input", label: "Input", role: .input, roles: [.input]),
        ]),
        .init("brand-content", "Brand & content", [
            .init(id: "subtle-surface", label: "Subtle surface", role: .secondary, roles: [.secondary, .secondaryForeground, .muted, .toolbarControl]),
            .init(id: "highlight-surface", label: "Highlight surface", role: .accentSurface, roles: [.accentSurface, .accentSurfaceForeground, .toolbarControlHover]),
            .init(id: "accent", label: "Accent", role: .accent,
                  roles: [.accent, .accentForeground, .focus, .update, .updateForeground, .updateSurface, .terminalCursor]),
            .init(id: "action", label: "Action", role: .messageAction, roles: [.messageAction, .messageActionForeground, .messageActionHover]),
            .init(id: "message-surface", label: "Message surface", role: .messageSurface, roles: [.messageSurface, .messageForeground]),
            .init(id: "code-surface", label: "Code surface", role: .codeBackground, roles: [.codeBackground, .codeForeground]),
        ]),
        .init("search", "Search", [
            .init(id: "search-matches", label: "Search matches", role: .searchMatchBackground, roles: [.searchMatchBackground, .searchMatchForeground]),
            .init(id: "current-match", label: "Current match", role: .searchMatchActiveBackground,
                  roles: [.searchMatchActiveBackground, .searchMatchActiveForeground]),
        ]),
        .init("context", "Context", [
            .init(id: "sidebar-background", label: "Sidebar background", role: .sidebar, roles: [.sidebar, .sidebarForeground]),
            .init(id: "sidebar-controls", label: "Sidebar controls", role: .sidebarControlSurface, roles: [.sidebarControlSurface]),
            .init(id: "sidebar-selection", label: "Sidebar selection", role: .sidebarRowSelected, roles: [.sidebarRowHover, .sidebarRowActive, .sidebarRowSelected]),
            .init(id: "terminal-background", label: "Terminal background", role: .terminalBackground,
                  roles: [.terminalBackground, .terminalForeground, .terminalSelection, .terminalScrollbar, .terminalScrollbarHover]),
        ]),
        .init("status", "Status", [
            .init(id: "error", label: "Error", role: .error, roles: [.error, .errorForeground, .errorSurface]),
            .init(id: "warning", label: "Warning", role: .warning, roles: [.warning, .warningForeground, .warningSurface]),
        ]),
    ]

    public static func of(_ role: ThemeColorRole) -> ThemeEditorFamily? {
        groups.lazy.flatMap(\.families).first { $0.roles.contains(role) }
    }

    /// `getThemeRoleLabel` (ThemeColorPicker.tsx:10-31).
    public static func roleLabel(_ role: ThemeColorRole) -> String {
        let labels: [ThemeColorRole: String] = [
            .canvas: "Background", .toolbar: "Toolbar background", .toolbarForeground: "Toolbar text", .toolbarBorder: "Toolbar border",
            .toolbarControl: "Toolbar control", .toolbarControlForeground: "Toolbar control text", .toolbarControlHover: "Toolbar control hover",
            .accent: "Accent color", .errorForeground: "Error text", .errorSurface: "Error background", .warningForeground: "Warning text",
            .warningSurface: "Warning background", .updateForeground: "Update text", .updateSurface: "Update background",
        ]
        if let l = labels[role] { return l }
        let spaced = role.rawValue.replacing(#/[A-Z]/#) { " " + $0.output }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// The theme editor's session and draft (ThemeEditorPanel.tsx and ThemeEditorHost.tsx). It lives above the
/// pages, like T3's host above the router: the draft is painted on the live app while it is open, and the stored
/// theme comes back when it closes.
@MainActor
public final class ThemeEditorController {
    public static let shared = ThemeEditorController()
    static let simpleRoles: [ThemeColorRole] = [.canvas, .accent]

    /// The window content the floating panel sits in.
    public weak var host: NSView?
    public var toast: ((String, String?, ToastQueue.Kind) -> Void)?
    let library: ThemeLibrary

    public private(set) var session: ThemeEditorSession?
    private(set) var panel: ThemeEditorPanelView?

    // The draft.
    var editing: ThemeDefinition?
    var name = ""
    var active: ThemeAppearance = .light
    var isAdvanced = false
    var colors: [ThemeAppearance: [ThemeColorRole: String]] = [:]
    var simpleDirty: Set<ThemeAppearance> = []
    var shouldRegenerate = false
    var error: String?
    var selectedRole: ThemeColorRole?
    var roleQuery = ""
    var isMinimized = false
    var isInspecting = false
    /// A half-typed hex keeps the last good value on screen instead of blanking the role.
    private var lastGoodPreview: [ThemeColorRole: String] = [:]

    public init(library: ThemeLibrary = .shared) { self.library = library }

    public var isOpen: Bool { session != nil }

    // MARK: Session

    public func open(_ s: ThemeEditorSession) {
        session = s
        seed(s)
        if panel == nil, let host {
            let p = ThemeEditorPanelView(controller: self)
            host.addSubview(p, positioned: .above, relativeTo: nil)
            panel = p
        }
        changed(structure: true)
        panel?.focusName()
    }

    public func close() {
        guard session != nil else { return }
        session = nil
        isInspecting = false
        panel?.closePopups()
        panel?.removeFromSuperview()
        panel = nil
        lastGoodPreview = [:]
        library.preview = nil
    }

    /// `toggleThemeEditorForTheme` (themeEditorStore.ts:53-68).
    public func toggle(initialAppearance: ThemeAppearance) {
        if isOpen { close(); return }
        let seed = library.ownerCard(initialAppearance).flatMap(library.definition)?.id
        open(ThemeEditorSession(editingThemeId: nil, seedThemeId: seed, seedName: nil, initialAppearance: initialAppearance))
    }

    /// The open-time seeding (ThemeEditorPanel.tsx:385-430).
    func seed(_ s: ThemeEditorSession) {
        editing = s.editingThemeId.flatMap(library.definition)
        let source = editing ?? s.seedThemeId.flatMap(library.definition)
        var next: [ThemeAppearance: [ThemeColorRole: String]] = [.light: ThemePalette.standardColors(.light), .dark: ThemePalette.standardColors(.dark)]
        if let source {
            next[source.appearance] = source.colors
            for (a, c) in source.variants { next[a] = c }
        }
        active = source.map { $0.colors(for: s.initialAppearance) != nil ? s.initialAppearance : $0.appearance } ?? s.initialAppearance
        name = editing?.label ?? s.seedName ?? ""
        isAdvanced = source != nil && !source!.managed
        shouldRegenerate = source != nil && !source!.managed
        simpleDirty = []
        colors = next
        selectedRole = nil
        roleQuery = ""
        error = nil
        isInspecting = false
        isMinimized = false
        lastGoodPreview = [:]
    }

    // MARK: Draft rules

    /// An installed theme the name already belongs to (ThemeEditorPanel.tsx:437-449).
    var mergeTarget: ThemeDefinition? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let target = ThemePalette.themeId(fromName: name)
        return library.customThemes.first {
            $0.id != editing?.id && ($0.id == target || $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized)
        }
    }

    /// `appearanceLockReason` (ThemeEditorPanel.tsx:456-464).
    func lockReason(_ a: ThemeAppearance) -> String? {
        if let editing, !editing.modes.contains(a) {
            return "“\(editing.label)” has no \(a.rawValue) palette. Create a theme with the same name to add one."
        }
        if editing == nil, let target = mergeTarget, target.modes.contains(a) {
            return "“\(target.label)” already has a \(a.rawValue) palette."
        }
        return nil
    }

    func setName(_ value: String) {
        name = value
        error = nil
        // A name whose theme owns the selected side flips the draft to the free one (466-478).
        if editing == nil, let target = mergeTarget, target.modes.count == 1, target.modes.contains(active) {
            active = active.other
            changed(structure: true)
        } else {
            changed(structure: false)
        }
    }

    func setAppearance(_ a: ThemeAppearance) {
        guard lockReason(a) == nil, a != active else { return }
        active = a
        changed(structure: true)
    }

    /// `getManagedEditorColors`: the guided editor derives everything from Background and Accent.
    func managed(_ a: ThemeAppearance, _ c: [ThemeColorRole: String]) -> [ThemeColorRole: String] {
        let d = ThemePalette.standardColors(a)
        let canvas = c[.canvas].flatMap { ThemePalette.isThemeColor($0.trimmingCharacters(in: .whitespaces)) ? $0 : nil } ?? d[.canvas]!
        let accent = c[.accent].flatMap { ThemePalette.isThemeColor($0.trimmingCharacters(in: .whitespaces)) ? $0 : nil } ?? d[.accent]!
        return ThemePalette.vividColors(a, background: canvas, accent: accent)
    }

    /// `updateColor` (ThemeEditorPanel.tsx:499-524).
    func updateColor(_ role: ThemeColorRole, _ value: String) {
        var current = colors[active] ?? [:]
        current[role] = value
        let valid = ThemePalette.isThemeColor(value.trimmingCharacters(in: .whitespaces))
        let guided = !isAdvanced && Self.simpleRoles.contains(role) && valid
        if isAdvanced {
            colors[active] = ThemePalette.updateFamily(active, colors[active] ?? [:], role: role, value: value)
            shouldRegenerate = true
        } else {
            colors[active] = guided ? managed(active, current) : current
            if guided { simpleDirty.insert(active) }
        }
        changed(structure: false)
    }

    /// `selectThemeRole`: an advanced role opens Advanced and clears the filter.
    func selectRole(_ role: ThemeColorRole, reveal: Bool = false) {
        let visible = ThemeEditorFamily.of(role)?.role ?? role
        selectedRole = visible
        var structure = false
        if !Self.simpleRoles.contains(visible), !isAdvanced { isAdvanced = true; roleQuery = ""; structure = true }
        changed(structure: structure)
        if reveal { panel?.reveal(visible) }
    }

    func toggleRole(_ role: ThemeColorRole) {
        selectedRole = selectedRole == role ? nil : role
        changed(structure: false)
    }

    func setQuery(_ q: String) {
        roleQuery = q
        changed(structure: true)
    }

    /// `handleAdvancedChange` (ThemeEditorPanel.tsx:745-775).
    func setAdvanced(_ on: Bool) {
        isAdvanced = on
        if !on {
            if let r = selectedRole, !Self.simpleRoles.contains(r) { selectedRole = nil }
            if shouldRegenerate {
                let appearances: [ThemeAppearance] = editing.map { $0.modes.count > 1 } == true ? [.light, .dark] : [active]
                for a in appearances {
                    simpleDirty.insert(a)
                    colors[a] = managed(a, colors[a] ?? [:])
                }
                shouldRegenerate = false
            }
        }
        changed(structure: true)
    }

    // MARK: Saving (ThemeEditorPanel.tsx:777-931, ThemeEditorHost.tsx:33-104)

    var submitTitle: (icon: IconName?, title: String) {
        if editing != nil { return (nil, mergeTarget.map { "Merge into “\($0.label)”" } ?? "Save changes") }
        if mergeTarget != nil { return (.plus, "Add \(active.rawValue) palette") }
        return (.paintbrush, "Create theme")
    }

    func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Name your theme first."; changed(structure: false); return }
        let forSave: [ThemeAppearance: [ThemeColorRole: String]] = isAdvanced ? colors : Dictionary(uniqueKeysWithValues: ThemeAppearance.allCases.map { a in
            (a, simpleDirty.contains(a) ? managed(a, colors[a] ?? [:]) : colors[a] ?? [:])
        })
        let managedFlag = !isAdvanced
        func file(id: String, name: String, appearance: ThemeAppearance, colors c: [ThemeColorRole: String],
                  variants: [ThemeAppearance: [ThemeColorRole: String]], managed: Bool) throws -> ThemeDefinition {
            var o: [String: Any] = ["version": ThemePalette.fileVersion, "id": id, "name": name, "appearance": appearance.rawValue,
                                    "colors": Dictionary(uniqueKeysWithValues: c.map { ($0.key.rawValue, $0.value) })]
            if !variants.isEmpty {
                o["variants"] = Dictionary(uniqueKeysWithValues: variants.map { ($0.key.rawValue, Dictionary(uniqueKeysWithValues: $0.value.map { ($0.key.rawValue, $0.value) })) })
            }
            if managed { o["managed"] = true }
            return try ThemePalette.parseFile(o)
        }
        let target = mergeTarget
        do {
            var saved: ThemeDefinition
            var merged: ThemeAppearance?
            if let editing, let target {
                let edited = editing.modes
                if let collision = edited.first(where: { target.modes.contains($0) }) {
                    error = "“\(target.label)” already has a \(collision.rawValue) palette. Pick another name."
                    changed(structure: false)
                    return
                }
                merged = edited.first
                var variants = target.variants
                for m in edited { variants[m] = forSave[m] }
                var def = try file(id: target.id, name: target.label, appearance: target.appearance, colors: target.colors,
                                   variants: variants.filter { $0.key != target.appearance }, managed: target.managed && managedFlag)
                def.collection = target.collection
                saved = try library.update(def)
                library.remove([editing.id])
            } else if let editing {
                let other = editing.appearance.other
                var def = try file(id: editing.id, name: name, appearance: editing.appearance, colors: forSave[editing.appearance] ?? [:],
                                   variants: editing.modes.count > 1 ? [other: forSave[other] ?? [:]] : [:], managed: managedFlag)
                def.collection = editing.collection
                saved = try library.update(def)
            } else if let target {
                if target.modes.contains(active) {
                    error = "“\(target.label)” already has light and dark palettes. Pick another name."
                    changed(structure: false)
                    return
                }
                merged = active
                var variants = target.variants
                variants[active] = forSave[active]
                var def = try file(id: target.id, name: target.label, appearance: target.appearance, colors: target.colors,
                                   variants: variants.filter { $0.key != target.appearance }, managed: target.managed && managedFlag)
                def.collection = target.collection
                saved = try library.update(def)
            } else {
                saved = try library.install(file(id: ThemePalette.themeId(fromName: name), name: name, appearance: active,
                                                 colors: forSave[active] ?? [:], variants: [:], managed: managedFlag))
            }
            didSave(saved, created: editing == nil && merged == nil, merged: merged)
            close()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? (editing == nil ? "Could not create the theme." : "Could not save the theme.")
            changed(structure: false)
        }
    }

    /// `handleSaved` (ThemeEditorHost.tsx:33-104).
    private func didSave(_ theme: ThemeDefinition, created: Bool, merged: ThemeAppearance?) {
        if let merged {
            library.setTheme(theme.id)
            toast?("\(theme.label) updated", "Its \(merged.rawValue) palette was added.", .success)
        } else if !created {
            let wasActive = library.definition(library.preference)?.id == theme.id || library.halves.light == theme.id || library.halves.dark == theme.id
            toast?("\(theme.label) saved", wasActive ? "Your changes are now active." : "Your changes are saved.", .success)
        } else {
            library.setTheme(theme.id)
            toast?("\(theme.label) created", "It’s now active.", .success)
        }
    }

    // MARK: Preview

    /// Paints the draft for the selected appearance on the live app (ThemeEditorPanel.tsx:483-486).
    private func preview() {
        guard session != nil else { return }
        for (role, value) in colors[active] ?? [:] where ThemePalette.isThemeColor(value) { lastGoodPreview[role] = value }
        library.preview = ThemeLibrary.Preview(colors: lastGoodPreview, appearance: active)
    }

    private func changed(structure: Bool) {
        preview()
        panel?.update(structure: structure)
    }

    // MARK: Inspect

    /// Inspect picks the role whose draft color is nearest the clicked pixel.
    // ponytail: T3 reads the clicked element's computed styles (themeInspector.ts) and counts every use; CandyWrapper
    // samples one pixel, which finds flat surfaces and text-free areas. Track token use per view if this proves too coarse
    func inspect(color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        var best: (ThemeColorRole, Double)?
        for (role, value) in colors[active] ?? [:] {
            guard let v = ThemeCSSColor.nsColor(value)?.usingColorSpace(.sRGB) else { continue }
            let d = pow(v.redComponent - c.redComponent, 2) + pow(v.greenComponent - c.greenComponent, 2) + pow(v.blueComponent - c.blueComponent, 2)
            if best == nil || d < best!.1 { best = (role, d) }
        }
        isInspecting = false
        if let best { selectRole(best.0, reveal: true) } else { changed(structure: false) }
    }

    func setInspecting(_ on: Bool) {
        isInspecting = on
        if !on { selectedRole = nil }
        changed(structure: false)
    }
}
