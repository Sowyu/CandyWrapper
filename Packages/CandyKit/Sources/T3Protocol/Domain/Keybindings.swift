import Foundation

// T3's keybinding system, ported from packages/contracts/src/keybindings.ts (wire types),
// packages/shared/src/keybindings.ts (defaults, parsing, compiling, merging) and
// apps/web/src/keybindings.ts (when-clause evaluation, resolution, conflicts, labels).
// macOS only: `mod` is Command.

/// `KeybindingShortcut` (contracts keybindings.ts:157-165).
public struct KeybindingShortcut: Codable, Hashable, Sendable {
    public var key: String
    public var metaKey = false
    public var ctrlKey = false
    public var shiftKey = false
    public var altKey = false
    public var modKey = false

    public init(key: String, metaKey: Bool = false, ctrlKey: Bool = false, shiftKey: Bool = false, altKey: Bool = false, modKey: Bool = false) {
        self.key = key; self.metaKey = metaKey; self.ctrlKey = ctrlKey
        self.shiftKey = shiftKey; self.altKey = altKey; self.modKey = modKey
    }

    /// Modifiers as the Mac sees them: `mod` is Command.
    public var meta: Bool { metaKey || modKey }

    /// `shortcutConflictKey` (web keybindings.ts:87-101) on macOS.
    public var conflictKey: String {
        [key, meta ? "meta" : "", ctrlKey ? "ctrl" : "", shiftKey ? "shift" : "", altKey ? "alt" : ""].joined(separator: "|")
    }

    /// `formatShortcutLabel` (web keybindings.ts:197-222) on macOS, for example `⌥⇧⌘A`.
    public var label: String {
        (ctrlKey ? "\u{2303}" : "") + (altKey ? "\u{2325}" : "") + (shiftKey ? "\u{21E7}" : "") + (meta ? "\u{2318}" : "")
            + Self.keyLabel(key)
    }

    /// `formatShortcutKeyLabel` (web keybindings.ts:187-195).
    public static func keyLabel(_ key: String) -> String {
        switch key {
        case " ": "Space"
        case "escape": "Esc"
        case "arrowup": "Up"
        case "arrowdown": "Down"
        case "arrowleft": "Left"
        case "arrowright": "Right"
        default: key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// `parseKeybindingShortcut` (shared keybindings.ts:224-282).
    public static func parse(_ value: String) -> KeybindingShortcut? {
        var tokens = value.lowercased().components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var trailingEmpty = 0
        while tokens.last == "" { trailingEmpty += 1; tokens.removeLast() }
        if trailingEmpty > 0 { tokens.append("+") }
        if tokens.isEmpty || tokens.contains(where: \.isEmpty) { return nil }
        var shortcut = KeybindingShortcut(key: "")
        var key: String?
        for token in tokens {
            switch token {
            case "cmd", "meta": shortcut.metaKey = true
            case "ctrl", "control": shortcut.ctrlKey = true
            case "shift": shortcut.shiftKey = true
            case "alt", "option": shortcut.altKey = true
            case "mod": shortcut.modKey = true
            default:
                if key != nil { return nil }
                key = token == "space" ? " " : token == "esc" ? "escape" : token
            }
        }
        guard let key else { return nil }
        shortcut.key = key
        return shortcut
    }
}

/// `KeybindingWhenNode` (contracts keybindings.ts:173-197).
public indirect enum KeybindingWhenNode: Codable, Hashable, Sendable {
    case identifier(String)
    case not(KeybindingWhenNode)
    case and(KeybindingWhenNode, KeybindingWhenNode)
    case or(KeybindingWhenNode, KeybindingWhenNode)

    private enum CodingKeys: String, CodingKey { case type, name, node, left, right }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "identifier": self = .identifier(try c.decode(String.self, forKey: .name))
        case "not": self = .not(try c.decode(KeybindingWhenNode.self, forKey: .node))
        case "and": self = .and(try c.decode(KeybindingWhenNode.self, forKey: .left), try c.decode(KeybindingWhenNode.self, forKey: .right))
        case "or": self = .or(try c.decode(KeybindingWhenNode.self, forKey: .left), try c.decode(KeybindingWhenNode.self, forKey: .right))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown when node \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identifier(let name): try c.encode("identifier", forKey: .type); try c.encode(name, forKey: .name)
        case .not(let node): try c.encode("not", forKey: .type); try c.encode(node, forKey: .node)
        case .and(let l, let r): try c.encode("and", forKey: .type); try c.encode(l, forKey: .left); try c.encode(r, forKey: .right)
        case .or(let l, let r): try c.encode("or", forKey: .type); try c.encode(l, forKey: .left); try c.encode(r, forKey: .right)
        }
    }

    /// `evaluateWhenNode` (web keybindings.ts:66-79). Unknown keys are false.
    public func evaluate(_ context: KeybindingContext) -> Bool {
        switch self {
        case .identifier("true"): true
        case .identifier("false"): false
        case .identifier(let name): context[name]
        case .not(let node): !node.evaluate(context)
        case .and(let l, let r): l.evaluate(context) && r.evaluate(context)
        case .or(let l, let r): l.evaluate(context) || r.evaluate(context)
        }
    }

    /// `parseKeybindingWhenExpression` (shared keybindings.ts:333-427): `!`, `&&`, `||`, parentheses.
    public static func parse(_ expression: String) -> KeybindingWhenNode? {
        enum Token: Equatable { case id(String), not, and, or, lparen, rparen }
        var tokens: [Token] = []
        let chars = Array(expression)
        var i = 0
        func isIdentStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
        func isIdent(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-") }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "&", i + 1 < chars.count, chars[i + 1] == "&" { tokens.append(.and); i += 2; continue }
            if c == "|", i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.or); i += 2; continue }
            if c == "!" { tokens.append(.not); i += 1; continue }
            if c == "(" { tokens.append(.lparen); i += 1; continue }
            if c == ")" { tokens.append(.rparen); i += 1; continue }
            guard isIdentStart(c) else { return nil }
            var j = i + 1
            while j < chars.count, isIdent(chars[j]) { j += 1 }
            tokens.append(.id(String(chars[i..<j])))
            i = j
        }
        guard !tokens.isEmpty else { return nil }
        let maxDepth = 64 // MAX_WHEN_EXPRESSION_DEPTH
        var index = 0
        func primary(_ depth: Int) -> KeybindingWhenNode? {
            guard depth <= maxDepth, index < tokens.count else { return nil }
            switch tokens[index] {
            case .id(let name): index += 1; return .identifier(name)
            case .lparen:
                index += 1
                guard let node = or(depth + 1), index < tokens.count, tokens[index] == .rparen else { return nil }
                index += 1
                return node
            default: return nil
            }
        }
        func unary(_ depth: Int) -> KeybindingWhenNode? {
            var nots = 0
            while index < tokens.count, tokens[index] == .not {
                index += 1; nots += 1
                if nots > maxDepth { return nil }
            }
            guard var node = primary(depth) else { return nil }
            for _ in 0..<nots { node = .not(node) }
            return node
        }
        func and(_ depth: Int) -> KeybindingWhenNode? {
            guard var left = unary(depth) else { return nil }
            while index < tokens.count, tokens[index] == .and {
                index += 1
                guard let right = unary(depth) else { return nil }
                left = .and(left, right)
            }
            return left
        }
        func or(_ depth: Int) -> KeybindingWhenNode? {
            guard var left = and(depth) else { return nil }
            while index < tokens.count, tokens[index] == .or {
                index += 1
                guard let right = and(depth) else { return nil }
                left = .or(left, right)
            }
            return left
        }
        guard let ast = or(0), index == tokens.count else { return nil }
        return ast
    }
}

/// The `when` context keys (docs/user/keybindings.md "When conditions"). Unset keys read false.
public struct KeybindingContext: Sendable, Equatable {
    public var values: [String: Bool]
    public init(_ values: [String: Bool] = [:]) {
        // `resolveContext` (web keybindings.ts:54-64): the desktop app.
        self.values = ["isDesktop": true, "isWeb": false].merging(values) { $1 }
    }
    public subscript(_ key: String) -> Bool {
        get { values[key] ?? false }
        set { values[key] = newValue }
    }
}

/// `ResolvedKeybindingRule` (contracts keybindings.ts:199-204), the form `server.getConfig` sends.
public struct ResolvedKeybindingRule: Codable, Hashable, Sendable {
    public var command: String
    public var shortcut: KeybindingShortcut
    public var whenAst: KeybindingWhenNode?

    public init(command: String, shortcut: KeybindingShortcut, whenAst: KeybindingWhenNode? = nil) {
        self.command = command; self.shortcut = shortcut; self.whenAst = whenAst
    }

    /// `compileResolvedKeybindingRule` (shared keybindings.ts:429-447).
    public init?(key: String, command: String, when: String? = nil) {
        guard let shortcut = KeybindingShortcut.parse(key) else { return nil }
        var ast: KeybindingWhenNode?
        if let when {
            guard let parsed = KeybindingWhenNode.parse(when) else { return nil }
            ast = parsed
        }
        self.init(command: command, shortcut: shortcut, whenAst: ast)
    }
}

/// A key press as T3's matcher sees it (`ShortcutEventLike`). `key` is the layout key, lowercased
/// (`event.key`); `physicalKey` is what `shortcutKeyFromEvent` reads from `event.code` for digits,
/// punctuation and letters, so Shift+[ still matches `[`.
public struct KeyStroke: Sendable, Equatable {
    public var key: String
    public var physicalKey: String?
    public var meta = false
    public var ctrl = false
    public var shift = false
    public var alt = false
    public var isRepeat = false

    public init(key: String, physicalKey: String? = nil, meta: Bool = false, ctrl: Bool = false, shift: Bool = false, alt: Bool = false, isRepeat: Bool = false) {
        self.key = key; self.physicalKey = physicalKey
        self.meta = meta; self.ctrl = ctrl; self.shift = shift; self.alt = alt; self.isRepeat = isRepeat
    }

    /// `resolveEventKeys` (shared keybindings.ts:72-81).
    public var candidateKeys: Set<String> {
        var keys: Set<String> = [key]
        let isLetter = key.count == 1 && key.first!.isASCII && key.first!.isLetter
        // The physical key joins when the layout key isn't a letter (Option combinations, Shift+digit).
        if let physicalKey, !isLetter { keys.insert(physicalKey) }
        return keys
    }

    /// `matchesKeybindingShortcut` (shared keybindings.ts:83-112) on macOS.
    public func matches(_ shortcut: KeybindingShortcut) -> Bool {
        meta == shortcut.meta && ctrl == shortcut.ctrlKey && shift == shortcut.shiftKey && alt == shortcut.altKey
            && candidateKeys.contains(shortcut.key)
    }
}

/// A compiled keybinding config and the queries T3 runs on it.
public struct Keymap: Sendable, Equatable {
    public var rules: [ResolvedKeybindingRule]

    public init(rules: [ResolvedKeybindingRule]) { self.rules = rules }

    /// `MAX_KEYBINDINGS_COUNT`.
    public static let maxCount = 256

    /// T3's defaults merged with the server's resolved rules (`primaryServerKeybindingsAtom`,
    /// web state/server.ts:109-111): a command the server names drops every default rule for it.
    public static func merged(withServer custom: [ResolvedKeybindingRule]) -> Keymap {
        guard !custom.isEmpty else { return Keymap(rules: defaultRules) }
        let overridden = Set(custom.map(\.command))
        let merged = defaultRules.filter { !overridden.contains($0.command) } + custom
        return Keymap(rules: Array(merged.suffix(maxCount)))
    }

    public static let `default` = Keymap(rules: defaultRules)

    /// `resolveShortcutCommand` (web keybindings.ts:155-171): the last rule whose when-clause and
    /// shortcut both match wins, whatever its command.
    public func resolve(_ stroke: KeyStroke, context: KeybindingContext) -> String? {
        for rule in rules.reversed() where rule.whenAst?.evaluate(context) ?? true {
            if stroke.matches(Self.shortcut(rule, context)) { return rule.command }
        }
        return nil
    }

    /// `shortcutForContext` (web keybindings.ts:108-124): with a send that needs a modifier, a plain
    /// Mod+Enter `composer.sendAlternate` would clash with send, so it reads as Mod+Shift+Enter. Saved
    /// and remapped rules stay as they are.
    static func shortcut(_ rule: ResolvedKeybindingRule, _ context: KeybindingContext) -> KeybindingShortcut {
        var s = rule.shortcut
        if context["composerRequiresModifier"], rule.command == "composer.sendAlternate", s.key == "enter", s.modKey,
           !s.metaKey, !s.ctrlKey, !s.altKey, !s.shiftKey {
            s.shiftKey = true
        }
        return s
    }

    /// `effectiveShortcutsForCommand` (web keybindings.ts:103-130): shortcuts that still reach
    /// `command` in `context`, newest rule first; a later rule on the same keys claims them.
    public func effectiveShortcuts(for command: String, context: KeybindingContext = KeybindingContext()) -> [KeybindingShortcut] {
        var claimed = Set<String>()
        var result: [KeybindingShortcut] = []
        for rule in rules.reversed() where rule.whenAst?.evaluate(context) ?? true {
            let shortcut = Self.shortcut(rule, context)
            guard claimed.insert(shortcut.conflictKey).inserted else { continue }
            if rule.command == command { result.append(shortcut) }
        }
        return result
    }

    /// `shortcutLabelForCommand` (web keybindings.ts:224-240).
    public func label(for command: String, context: KeybindingContext = KeybindingContext()) -> String? {
        effectiveShortcuts(for: command, context: context).first?.label
    }

    /// `THREAD_JUMP_KEYBINDING_COMMANDS` and `MODEL_PICKER_JUMP_KEYBINDING_COMMANDS`.
    public static let threadJumpCommands = (1...9).map { "thread.jump.\($0)" }
    public static let modelPickerJumpCommands = (1...9).map { "modelPicker.jump.\($0)" }

    /// `threadJumpIndexFromCommand` and `modelPickerJumpIndexFromCommand`: 0 based.
    public static func jumpIndex(_ command: String?, prefix: String) -> Int? {
        guard let command, command.hasPrefix(prefix), let n = Int(command.dropFirst(prefix.count)), (1...9).contains(n) else { return nil }
        return n - 1
    }

    public typealias Binding = (key: String, command: String, when: String?)
    /// `DEFAULT_KEYBINDINGS` (packages/shared/src/keybindings.ts:123-210).
    private static let staticBindings: [Binding] = [
        ("mod+b", "sidebar.toggle", nil),
        ("mod+[", "navigation.back", "!terminalFocus"),
        ("mod+]", "navigation.forward", "!terminalFocus"),
        ("mod+j", "terminal.toggle", nil),
        ("mod+alt+b", "rightPanel.toggle", nil),
        // New in 2994 (b1508672a, packages/shared/src/keybindings.ts:129). A client default, so 2861 servers get it too.
        ("mod+shift+b", "threadPanel.toggle", "!terminalFocus"),
        ("mod+t", "rightPanel.new", "rightPanelOpen && !terminalFocus"),
        ("mod+d", "terminal.split", "terminalFocus"),
        ("mod+shift+d", "terminal.splitVertical", "terminalFocus"),
        ("mod+n", "terminal.new", "terminalFocus"),
        ("mod+w", "terminal.close", "terminalFocus"),
        ("mod+w", "rightPanel.close", "!terminalFocus"),
        ("mod+shift+t", "view.reopenClosed", nil),
        ("mod+d", "diff.toggle", "!terminalFocus"),
        ("mod+shift+j", "preview.toggle", nil),
        ("mod+r", "preview.refresh", "previewFocus"),
        ("mod+l", "preview.focusUrl", "previewFocus"),
        ("mod+=", "preview.zoomIn", "previewFocus"),
        ("mod++", "preview.zoomIn", "previewFocus"),
        ("mod+-", "preview.zoomOut", "previewFocus"),
        ("mod+0", "preview.resetZoom", "previewFocus"),
        ("mod+k", "commandPalette.toggle", "!terminalFocus"),
        ("mod+p", "filePicker.toggle", "!terminalFocus"),
        ("mod+shift+f", "projectSearch.toggle", "!terminalFocus"),
        ("mod+alt+a", "theme.select", "!terminalFocus"),
        ("mod+alt+shift+a", "appearance.cycle", "!terminalFocus"),
        ("mod+alt+shift+t", "themeEditor.toggle", nil),
        ("mod+s", "composer.stash", "!terminalFocus"),
        ("mod+shift+enter", "thread.steerQueuedMessage", "!terminalFocus"),
        ("alt+arrowup", "thread.editQueuedMessage", "composerFocus"),
        ("mod+enter", "composer.sendAlternate", "composerFocus && turnRunning"),
        ("mod+enter", "composer.sendBackground", "composerFocus && draftThreadRoute"),
        ("mod+alt+enter", "composer.sendBackground", "composerFocus && draftThreadRoute"),
        ("mod+alt+enter", "composer.sendAndNewThread", "composerFocus && !draftThreadRoute"),
        ("mod+n", "chat.new", "!terminalFocus"),
        ("mod+shift+o", "chat.new", "!terminalFocus"),
        ("mod+shift+n", "chat.newLocal", "!terminalFocus"),
        ("mod+alt+n", "chat.newWithoutProject", "!terminalFocus"),
        ("mod+f", "chat.find", "!terminalFocus && !previewFocus"),
        ("mod+shift+m", "modelPicker.toggle", "!terminalFocus"),
        ("mod+shift+h", "composer.host", "!terminalFocus"),
        ("mod+shift+e", "composer.effort", "!terminalFocus"),
        ("mod+shift+a", "composer.mode", "!terminalFocus"),
        ("mod+shift+x", "composer.workspace", "!terminalFocus"),
        ("mod+shift+g", "composer.branch", "!terminalFocus"),
        ("mod+shift+l", "composer.previousWorktree", "!terminalFocus"),
        ("mod+shift+k", "pullRequest.copyNumber", "!terminalFocus"),
        ("mod+shift+arrowup", "modelPicker.previousProvider", "modelPickerOpen"),
        ("mod+shift+arrowdown", "modelPicker.nextProvider", "modelPickerOpen"),
        ("mod+o", "editor.openFavorite", nil),
        ("mod+shift+[", "thread.previous", nil),
        ("mod+shift+]", "thread.next", nil),
        ("mod+shift+c", "thread.copyReference", "!terminalFocus"),
        ("mod+shift+s", "thread.settle", "!terminalFocus"),
        ("mod+shift+p", "thread.pin", "!terminalFocus"),
        ("mod+z", "thread.undo", "!terminalFocus && !editableFocus"),
    ]
    private static let usageBindings: [Binding] = [
        ("mod+u", "usage.open", "!terminalFocus"),
        ("c", "usage.cost", "usagePageOpen"),
        ("t", "usage.tokens", "usagePageOpen"),
        ("l", "usage.limits", "usagePageOpen"),
        ("mod+shift+1", "usage.period.day", "usagePageOpen"),
        ("mod+shift+2", "usage.period.week", "usagePageOpen"),
        ("mod+shift+3", "usage.period.month", "usagePageOpen"),
        ("mod+shift+4", "usage.period.quarter", "usagePageOpen"),
    ]
    public static let defaultBindings: [Binding] = {
        let threadJumps: [Binding] = threadJumpCommands.enumerated().map { ("mod+\($0.offset + 1)", $0.element, "isDesktop") }
        let modelJumps: [Binding] = modelPickerJumpCommands.enumerated().map { ("mod+\($0.offset + 1)", $0.element, "modelPickerOpen && isDesktop") }
        return staticBindings + threadJumps + modelJumps + usageBindings
    }()

    /// `DEFAULT_RESOLVED_KEYBINDINGS`.
    public static let defaultRules: [ResolvedKeybindingRule] = defaultBindings.compactMap {
        ResolvedKeybindingRule(key: $0.key, command: $0.command, when: $0.when)
    }

    /// `ForwardCompatibleArray(ResolvedKeybindingRule)`: rules this client cannot decode are dropped.
    public static func decodeRules(_ json: JSONValue?) -> [ResolvedKeybindingRule] {
        guard case .array(let items)? = json else { return [] }
        return Array(items.compactMap { try? $0.decode(as: ResolvedKeybindingRule.self) }.prefix(maxCount))
    }
}
