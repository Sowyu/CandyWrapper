import AppKit
import os

/// appearanceFonts.ts:35-51, 97-136. Resolve once per settings change, never on a timer.
public struct FontRuntimeInput: Equatable, Sendable {
    public var interfaceFamily = "", promptFamily = "", codeFamily = "", terminalFamily = ""
    public var interfaceSize: CGFloat = 16, promptSize: CGFloat = 14, codeSize: CGFloat = 13, terminalSize: CGFloat = 12
    public var advanced = false, smoothing = true
    public init() {}
}

/// The terminal reads `input` itself (TerminalFontSettings): it needs a fixed-pitch family and glyph fallbacks.
public enum FontRuntimeRole: Sendable { case interface, prompt, code }

public struct FontRuntimeRecipe: Sendable {
    public let role: FontRuntimeRole
    public let size: CGFloat
    public let weight: NSFont.Weight
    public func resolve() -> NSFont { FontRuntime.font(role, size: size, weight: weight) }
}

public enum FontRuntime {
    /// A struct key: string interpolation of the role went through reflection on every lookup.
    private struct FontKey: Hashable { let role: FontRuntimeRole; let size: CGFloat; let weight: CGFloat }
    private struct State {
        var input = FontRuntimeInput()
        var fonts: [FontKey: NSFont] = [:]
        var recipes: [NSFont: FontRuntimeRecipe] = [:]
    }
    private static let state = OSAllocatedUnfairLock(uncheckedState: State())
    nonisolated(unsafe) public private(set) static var interfaceScale: CGFloat = 1
    nonisolated(unsafe) public private(set) static var codeScale: CGFloat = 1
    nonisolated(unsafe) public private(set) static var promptSize: CGFloat = 14
    /// A synchronous offscreen render may choose smoothing without changing live font recipes.
    @TaskLocal public static var smoothingOverride: Bool?
    nonisolated(unsafe) private static var configuredSmoothing = true
    /// Core Text font smoothing (stem darkening), the heavier macOS default. True by default so offscreen
    /// renders match the fidelity references (Chromium without `-webkit-font-smoothing`); the app sets it from
    /// T3's `fontSmoothing` setting, whose default `antialiased` turns it off (SettingsFontRuntime).
    public static var smoothing: Bool { smoothingOverride ?? configuredSmoothing }
    public static var input: FontRuntimeInput { state.withLock { $0.input } }
    @MainActor public private(set) static var generation = 0
    @MainActor public static func apply(_ next: FontRuntimeInput) {
        let changed = state.withLock { s -> Bool in
            guard s.input != next else { return false }
            s.input = next
            s.fonts.removeAll()
            s.recipes.removeAll()
            return true
        }
        guard changed else { return }
        interfaceScale = next.interfaceSize / 16
        codeScale = next.codeSize / 13
        promptSize = next.promptSize
        configuredSmoothing = next.smoothing
        DSFont.clearCache()
        generation += 1
        // ponytail: refresh the whole window tree on changes; filter by role when views expose role ownership.
        for window in NSApp?.windows ?? [] {
            if let root = window.contentView { refresh(root) }
        }
    }

    @MainActor private static func refresh(_ view: NSView) {
        if let view = view as? DSView { view.fontRuntimeDidChange() }
        if let view = view as? FontRuntimeConsumer { view.applyFontRuntime() }
        for child in view.subviews { refresh(child) }
    }

    public static func recipe(for font: NSFont) -> FontRuntimeRecipe? { state.withLockUnchecked { $0.recipes[font] } }

    public static func font(_ role: FontRuntimeRole, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        state.withLockUnchecked { s in
            let key = FontKey(role: role, size: size, weight: weight.rawValue)
            if let font = s.fonts[key] { return font }
            let p = s.input
            let family: String
            let resolvedSize: CGFloat
            switch role {
            case .interface: family = p.interfaceFamily; resolvedSize = size * p.interfaceSize / 16
            case .prompt: family = p.promptFamily.isEmpty ? p.interfaceFamily : p.promptFamily; resolvedSize = size * p.promptSize / 14
            case .code: family = p.codeFamily; resolvedSize = size * p.codeSize / 13
            }
            var chosen: NSFont?
            for item in family.split(separator: ",") {
                let name = item.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                if let font = NSFont(name: name, size: resolvedSize) {
                    chosen = weight >= .semibold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
                    break
                }
            }
            let font = chosen ?? {
                if role == .interface || role == .prompt { return NSFont.systemFont(ofSize: resolvedSize, weight: weight) }
                let base = CTFontCreateUIFontForLanguage(.userFixedPitch, resolvedSize, nil).map { $0 as NSFont }
                    ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: weight)
                return weight >= .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
            }()
            s.fonts[key] = font
            // Prompt owns its refresh hook. Avoid aliasing the system UI recipe.
            if role == .interface || role == .code { s.recipes[font] = FontRuntimeRecipe(role: role, size: size, weight: weight) }
            return font
        }
    }
}

@MainActor public protocol FontRuntimeConsumer: AnyObject {
    func applyFontRuntime()
}
