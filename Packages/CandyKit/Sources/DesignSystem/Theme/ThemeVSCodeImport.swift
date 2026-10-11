import Foundation

/// vscodeThemeImport.ts:160-410. Imports only palette data; never installs extension code.
public enum ThemeVSCodeImport {
    public static func isTheme(_ value: Any) -> Bool {
        guard let object = value as? [String: Any], object["version"] as? Int != 1 else { return false }
        return (object["colors"] as? [String: Any])?.keys.contains(where: { $0.contains(".") }) == true || object["tokenColors"] is [Any]
    }

    public static func parse(_ value: Any) throws -> ThemeDefinition {
        guard let object = value as? [String: Any] else { throw ThemePalette.FileError(message: "Theme files must contain a JSON object.") }
        let colors = object["colors"] as? [String: String] ?? [:]
        typealias RGB = SIMD3<Double>
        func parsed(_ value: String?) -> (RGB, Double)? {
            guard var value else { return nil }
            if value.range(of: #"^[0-9a-fA-F]{3,8}$"#, options: .regularExpression) != nil { value = "#" + value }
            guard let c = ThemePalette.parse(value) else { return nil }
            return (ThemePalette.rgb(c.color), c.alpha)
        }
        func pick(_ keys: [String]) -> (RGB, Double)? { keys.compactMap { parsed(colors[$0]) }.first }
        guard let source = pick(["editor.background", "editorPane.background"]) else {
            throw ThemePalette.FileError(message: "That VS Code theme has no \"editor.background\" color, so there is nothing to build a palette from.")
        }
        let canvas = source.0, canvasHex = ThemePalette.hex(canvas)
        let type = (object["type"] as? String)?.lowercased()
        let appearance: ThemeAppearance = ["light", "hc-light"].contains(type ?? "") ? .light : ["dark", "hc-black"].contains(type ?? "") ? .dark : ThemePalette.luminance(canvas) < 0.179 ? .dark : .light
        func rgb(_ hex: String) -> RGB { ThemePalette.parseRGB(hex, fallback: .zero) }
        func solid(_ base: RGB, _ keys: [String]) -> String? { pick(keys).map { ThemePalette.hex(ThemePalette.mix(base, $0.0, $0.1)) } }
        func apart(_ a: String, _ b: String) -> Bool { ThemePalette.contrast(rgb(a), rgb(b)) >= 1.1 }
        let raised = solid(canvas, ["editorWidget.background", "dropdown.background"])
        let standard = ThemePalette.standardColors(appearance)
        let accents = ["focusBorder", "button.background", "textLink.foreground", "activityBarBadge.background", "progressBar.background", "badge.background"].compactMap { solid(canvas, [$0]) }
        let accent = (accents + [standard[.accent]!, "#ffffff", "#000000"]).first { apart($0, canvasHex) && (raised == nil || apart($0, raised!)) } ?? standard[.accent]!
        var result = ThemePalette.vividColors(appearance, background: canvasHex, accent: ThemePalette.hex(ThemePalette.mix(canvas, rgb(accent), 0.2)))
        let derived = result
        func readable(_ surface: String, _ fallback: String, _ keys: [String]) -> String {
            let base = rgb(surface)
            if let authored = solid(base, keys), ThemePalette.contrast(rgb(authored), base) >= 4.5 { return authored }
            if ThemePalette.contrast(rgb(fallback), base) >= 4.5 { return fallback }
            return ThemePalette.luminance(base) < 0.179 ? "#ffffff" : "#000000"
        }
        let surface = raised ?? derived[.surfaceRaised]!
        let button = solid(canvas, ["button.background"])
        let action = button.flatMap { apart($0, canvasHex) && apart($0, surface) ? $0 : nil } ?? accent
        let input = (["input.background", "input.border"].compactMap { solid(canvas, [$0]) } + [derived[.input]!, derived[.surfaceRaised]!, standard[.input]!, "#000000", "#ffffff", "#808080"]).first { apart($0, canvasHex) && apart($0, action) } ?? "#808080"
        let sidebar = solid(canvas, ["sideBar.background", "activityBar.background"]) ?? derived[.sidebar]!
        let terminal = solid(canvas, ["terminal.background", "panel.background"]) ?? derived[.terminalBackground]!
        result[.canvas] = canvasHex; result[.surfaceRaised] = surface; result[.input] = input
        result[.sidebar] = sidebar; result[.terminalBackground] = terminal
        result[.accent] = accent; result[.focus] = accent; result[.messageAction] = action
        let mappings: [(ThemeColorRole, [String])] = [
            (.surface, ["editorWidget.background"]), (.surfaceOverlay, ["menu.background", "quickInput.background", "dropdown.background"]),
            (.border, ["panel.border", "editorGroup.border", "contrastBorder"]), (.accentSurface, ["list.activeSelectionBackground", "list.hoverBackground"]),
            (.codeBackground, ["textCodeBlock.background"]), (.searchMatchBackground, ["editor.findMatchHighlightBackground"]), (.searchMatchActiveBackground, ["editor.findMatchBackground"])]
        for (role, keys) in mappings { result[role] = solid(canvas, keys) ?? derived[role] }
        for (role, keys) in [(ThemeColorRole.sidebarBorder, ["sideBar.border"]), (.sidebarRowHover, ["list.hoverBackground"]), (.sidebarRowActive, ["list.inactiveSelectionBackground", "list.hoverBackground"]), (.sidebarRowSelected, ["list.activeSelectionBackground"])] {
            result[role] = solid(rgb(sidebar), keys) ?? derived[role]
        }
        for (role, keys) in [(ThemeColorRole.terminalCursor, ["terminalCursor.foreground", "editorCursor.foreground"]), (.terminalSelection, ["terminal.selectionBackground", "editor.selectionBackground"]), (.terminalScrollbar, ["scrollbarSlider.background"])] {
            result[role] = solid(rgb(terminal), keys) ?? derived[role]
        }
        let texts: [(ThemeColorRole, String, [String])] = [
            (.text, canvasHex, ["editor.foreground", "foreground"]), (.textMuted, canvasHex, ["descriptionForeground", "disabledForeground"]),
            (.placeholder, surface, ["input.placeholderForeground"]), (.error, canvasHex, ["editorError.foreground", "errorForeground"]), (.warning, canvasHex, ["editorWarning.foreground"]),
            (.sidebarForeground, sidebar, ["sideBar.foreground"]), (.terminalForeground, terminal, ["terminal.foreground"]),
            (.messageActionForeground, action, ["button.foreground"]), (.accentForeground, accent, ["button.foreground"]),
            (.searchMatchForeground, result[.searchMatchBackground]!, ["editor.findMatchHighlightForeground", "editor.foreground", "foreground"]),
            (.searchMatchActiveForeground, result[.searchMatchActiveBackground]!, ["editor.findMatchForeground", "editor.foreground", "foreground"])]
        for (role, background, keys) in texts { result[role] = readable(background, derived[role]!, keys) }
        let name = [object["displayName"], object["name"]].compactMap { $0 as? String }.map { raw in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.contains(where: \.isWhitespace) ? s : s.components(separatedBy: CharacterSet(charactersIn: "-_.")).filter { !$0.isEmpty }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }.first { !$0.isEmpty }.map { String($0.prefix(48)) } ?? "VS Code theme"
        var id = ThemePalette.themeId(fromName: name)
        if ThemePalette.reservedIds.contains(id) { id += "-vscode" }
        return try ThemePalette.parseFile(["version": 1, "id": id, "name": name, "appearance": appearance.rawValue, "colors": Dictionary(uniqueKeysWithValues: result.map { ($0.key.rawValue, $0.value) })])
    }
}
