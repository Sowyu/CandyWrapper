import Foundation
import T3Protocol

/// The theme a client hands an HTML render or MCP App (packages/shared/src/htmlRender.ts:170-260): T3's
/// standard palette (themePalettes.ts:137-262) mapped to the variables pages style against.
// ponytail: the standard light and dark palettes only; follow custom themes when the app gets them (WP-E)
public struct HtmlRenderTheme: Sendable, Equatable {
    public let dark: Bool
    public let variables: [String: String]

    public static let defaultSans = #"-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif"#
    public static let defaultMono = #""SF Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace"#

    public init(dark: Bool) {
        self.dark = dark
        // canvas, text, muted, mutedForeground, surface, surfaceOverlay, secondary, secondaryForeground, border,
        // input, focus, messageAction, messageActionForeground, accent, accentForeground, accentSurface,
        // accentSurfaceForeground, error, errorForeground, errorSurface, warning, warningForeground, warningSurface,
        // codeBackground, codeForeground.
        let c: [String: String] = dark ? [
            "canvas": "#0a0a0a", "text": "#f5f5f5", "muted": "#111111", "mutedForeground": "#818181", "surface": "#111111",
            "surfaceOverlay": "#111111", "secondary": "#111111", "secondaryForeground": "#f5f5f5", "border": "#191919",
            "input": "#1e1e1e", "focus": "#346bf1", "messageAction": "#346bf1", "messageActionForeground": "#ffffff",
            "accent": "#346bf1", "accentForeground": "#ffffff", "accentSurface": "#141414", "accentSurfaceForeground": "#f5f5f5",
            "error": "#fb414a", "errorForeground": "#ff6467", "errorSurface": "#301214", "warning": "#fe9a00",
            "warningForeground": "#ffb900", "warningSurface": "#312108", "codeBackground": "#111111", "codeForeground": "#f5f5f5",
        ] : [
            "canvas": "#fcfcfc", "text": "#27272a", "muted": "#fafafa", "mutedForeground": "#71717b", "surface": "#ffffff",
            "surfaceOverlay": "#ffffff", "secondary": "#fafafa", "secondaryForeground": "#27272a", "border": "#e4e4e7",
            "input": "#d4d4d8", "focus": "#1b4ed8", "messageAction": "#1b4ed8", "messageActionForeground": "#ffffff",
            "accent": "#1b4ed8", "accentForeground": "#ffffff", "accentSurface": "#f4f4f5", "accentSurfaceForeground": "#18181b",
            "error": "#fb2c36", "errorForeground": "#c10007", "errorSurface": "#fcebec", "warning": "#fe9a00",
            "warningForeground": "#bb4d00", "warningSurface": "#fcf4e8", "codeBackground": "#ffffff", "codeForeground": "#27272a",
        ]
        let chart = dark ? ["#2dd4bf", "#fbbf24", "#c084fc", "#fb7185", "#a3e635"] : ["#0d9488", "#d97706", "#9333ea", "#e11d48", "#65a30d"]
        var v: [String: String] = [
            "--background": c["canvas"]!, "--foreground": c["text"]!, "--muted": c["muted"]!, "--muted-foreground": c["mutedForeground"]!,
            "--card": c["surface"]!, "--card-foreground": c["text"]!, "--popover": c["surfaceOverlay"]!, "--popover-foreground": c["text"]!,
            "--secondary": c["secondary"]!, "--secondary-foreground": c["secondaryForeground"]!, "--border": c["border"]!,
            "--input": c["input"]!, "--ring": c["focus"]!, "--primary": c["messageAction"]!,
            "--primary-foreground": c["messageActionForeground"]!, "--accent": c["accent"]!, "--accent-foreground": c["accentForeground"]!,
            "--accent-surface": c["accentSurface"]!, "--accent-surface-foreground": c["accentSurfaceForeground"]!,
            "--destructive": c["error"]!, "--destructive-foreground": c["errorForeground"]!, "--destructive-surface": c["errorSurface"]!,
            "--warning": c["warning"]!, "--warning-foreground": c["warningForeground"]!, "--warning-surface": c["warningSurface"]!,
            "--success": "#10b981", "--success-foreground": dark ? "#34d399" : "#047857",
            "--info": "#3b82f6", "--info-foreground": dark ? "#60a5fa" : "#1d4ed8",
            "--code-background": c["codeBackground"]!, "--code-foreground": c["codeForeground"]!, "--chart-1": c["accent"]!,
            "--radius": "0.625rem", "--font-sans": Self.defaultSans, "--font-mono": Self.defaultMono,
        ]
        for (i, color) in chart.enumerated() { v["--chart-\(i + 2)"] = color }
        variables = v
    }

    var json: JSONValue {
        .object(["appearance": .string(dark ? "dark" : "light"), "variables": .object(variables.mapValues { .string($0) })])
    }

    /// `htmlRenderThemeFragment` (:323-326): hands the page its theme before first paint.
    public var fragment: String {
        let text = String(data: (try? JSONEncoder().encode(json)) ?? Data(), encoding: .utf8) ?? "{}"
        // `encodeURIComponent`'s unreserved set.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return "#t3-theme=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    /// `htmlRenderThemeMessage` (:329-335): posted into a mounted page when the theme changes.
    public var message: JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string("ui/notifications/host-context-changed"),
                 "params": .object(["theme": .string(dark ? "dark" : "light"), "styles": .object(["variables": json["variables"]!])])])
    }

    /// `readHtmlRenderContentHeight` (:283-293).
    public static func contentHeight(_ data: JSONValue) -> Double? {
        guard data["jsonrpc"]?.stringValue == "2.0", data["method"]?.stringValue == "ui/notifications/size-changed",
              let h = data["params"]?["height"]?.doubleValue, h.isFinite, h > 0 else { return nil }
        return h
    }

    /// `readHtmlRenderLinkRequest` (:296-307): a `ui/open-link` request with an http(s) URL.
    public static func linkRequest(_ data: JSONValue) -> (id: JSONValue, url: String)? {
        guard data["jsonrpc"]?.stringValue == "2.0", data["method"]?.stringValue == "ui/open-link", let id = data["id"],
              id.stringValue != nil || id.doubleValue != nil,
              let url = data["params"]?["url"]?.stringValue, url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        return (id, url)
    }

    /// `htmlRenderResult`: the empty result for a page's request.
    public static func result(_ id: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])]) }
}
