import Foundation
import T3Protocol

/// One binding on the Keybindings page (KeybindingsSettings.logic.ts `KeybindingRow`).
public struct KeybindingRow: Equatable, Sendable {
    public enum Source: String, Sendable { case `default` = "Default", custom = "Custom", project = "Project" }
    public let id: String
    public let command: String
    /// The config-file form, such as `mod+shift+k`.
    public let key: String
    public let when: String
    public let source: Source
    public let defaultKey: String?
    public let defaultWhen: String
    public let binding: ResolvedKeybindingRule
    public var conflicts: [String]
}

public struct KeybindingGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let rows: [KeybindingRow]
}

/// `server.upsertKeybinding` and `server.removeKeybinding` inputs (contracts server.ts:740-758).
public struct KeybindingTarget: Equatable, Sendable {
    public var command: String
    public var key: String
    public var when: String?
    public init(command: String, key: String, when: String? = nil) { self.command = command; self.key = key; self.when = when }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["command": .string(command), "key": .string(key)]
        if let when { o["when"] = .string(when) }
        return .object(o)
    }
}

/// T3's Keybindings page logic (apps/web/src/components/settings/KeybindingsSettings.logic.ts).
public enum KeybindingsLogic {
    /// `STATIC_KEYBINDING_COMMANDS` (contracts keybindings.ts:59-116), in contract order.
    public static let staticCommands: [String] = [
        "sidebar.toggle", "navigation.back", "navigation.forward", "terminal.toggle", "terminal.split", "terminal.splitVertical",
        "terminal.new", "terminal.close", "rightPanel.toggle", "rightPanel.new", "threadPanel.toggle", "rightPanel.toggleMaximized",
        "rightPanel.close", "view.reopenClosed", "pullRequest.copyNumber", "diff.toggle", "preview.toggle", "preview.refresh",
        "preview.focusUrl", "preview.zoomIn", "preview.zoomOut", "preview.resetZoom", "commandPalette.toggle", "filePicker.toggle",
        "projectSearch.toggle", "usage.open", "theme.select", "appearance.cycle", "themeEditor.toggle", "composer.stash",
        "composer.sendAlternate", "composer.sendBackground", "composer.sendAndNewThread", "composer.host", "composer.cycleHost",
        "composer.effort", "composer.increaseEffort", "composer.decreaseEffort", "composer.mode", "composer.workspace",
        "composer.previousWorktree", "composer.branch", "chat.new",
        "chat.newLocal", "chat.newWithoutProject", "chat.find", "editor.openFavorite", "usage.cost", "usage.tokens", "usage.limits",
        "usage.period.day", "usage.period.week", "usage.period.month", "usage.period.quarter",
        "modelPicker.toggle", "modelPicker.previousProvider", "modelPicker.nextProvider",
    ] + Keymap.modelPickerJumpCommands + [
        "thread.stop", "thread.steerQueuedMessage", "thread.editQueuedMessage", "thread.previous", "thread.next",
        "thread.copyReference", "thread.settle", "thread.pin", "thread.undo",
    ] + Keymap.threadJumpCommands

    /// `keybindingSearchAnchorId`.
    public static func anchorId(_ command: String) -> String { "keybinding-\(command)" }

    /// Usage page commands sort as one block in page order (`METRIC_OPTIONS`, `WINDOW_OPTIONS`).
    static let usageOrder: [String: Int] = Dictionary(uniqueKeysWithValues: [
        "usage.open", "usage.cost", "usage.tokens", "usage.limits", "usage.period.day", "usage.period.week", "usage.period.month", "usage.period.quarter",
    ].enumerated().map { ($1, $0) })
    static let usageMetrics: [String: String] = ["usage.cost": "Cost", "usage.tokens": "Tokens", "usage.limits": "Limits"]
    static let usagePeriods: [String: String] = ["usage.period.day": "Past 24h", "usage.period.week": "7 days",
                                                 "usage.period.month": "30 days", "usage.period.quarter": "90 days"]

    /// `localeCompare` for ASCII command names and labels.
    static func compareStrings(_ l: String, _ r: String) -> Int {
        switch l.localizedCompare(r) { case .orderedAscending: -1; case .orderedDescending: 1; case .orderedSame: 0 }
    }

    /// `compareCommands`.
    static func compareCommands(_ l: String, _ r: String, key: (String) -> String) -> Int {
        let lr = usageOrder[l], rr = usageOrder[r]
        if let lr, let rr { return lr - rr }
        return compareStrings(key(lr == nil ? l : "usage.cost"), key(rr == nil ? r : "usage.cost"))
    }

    /// `commandLabel`.
    public static func commandLabel(_ command: String) -> String {
        switch command {
        case "composer.sendAlternate": return "Composer: Opposite Queue or Steer Action"
        case "composer.sendBackground": return "Composer: Start in Background"
        case "composer.sendAndNewThread": return "Composer: Send and Start New Thread"
        case "thread.steerQueuedMessage": return "Queue: Send First Queued Message as Steer"
        case "thread.editQueuedMessage": return "Queue: Edit Last Queued Message"
        case "thread.copyReference": return "Pull Request: Copy Link or Thread ID"
        case "view.reopenClosed": return "Reopen Closed Tab"
        default: break
        }
        if let metric = usageMetrics[command] { return "Usage: \(metric)" }
        if let period = usagePeriods[command] { return "Usage: Period: \(period)" }
        if command.hasPrefix("script."), command.hasSuffix(".run") {
            return "Run Script: " + titleCase(String(command.dropFirst("script.".count).dropLast(".run".count)))
        }
        return command.split(separator: ".", omittingEmptySubsequences: false).map { titleCase(String($0)) }.joined(separator: ": ")
    }

    /// `titleCaseCommandSegment`.
    static func titleCase(_ segment: String) -> String {
        let spaced = segment.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// `shortcutToKeybindingInput`.
    public static func input(_ s: KeybindingShortcut) -> String {
        var parts: [String] = []
        if s.modKey { parts.append("mod") }
        if s.metaKey { parts.append("meta") }
        if s.ctrlKey { parts.append("ctrl") }
        if s.altKey { parts.append("alt") }
        if s.shiftKey { parts.append("shift") }
        parts.append(s.key == " " ? "space" : s.key == "escape" ? "esc" : s.key)
        return parts.joined(separator: "+")
    }

    /// `whenAstToExpression`.
    public static func expression(_ node: KeybindingWhenNode?) -> String {
        guard let node else { return "" }
        func wrap(_ n: KeybindingWhenNode) -> String {
            switch n { case .identifier, .not: expression(n); default: "(\(expression(n)))" }
        }
        switch node {
        case .identifier(let name): return name
        case .not(let n): return "!" + wrap(n)
        case .and(let l, let r): return "\(wrap(l)) && \(wrap(r))"
        case .or(let l, let r): return "\(wrap(l)) || \(wrap(r))"
        }
    }

    public enum WhenDraft: Equatable { case ok(KeybindingWhenNode?), invalid(String) }

    /// `parseWhenExpressionDraft`.
    public static func parseWhen(_ text: String) -> WhenDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .ok(nil) }
        guard let ast = KeybindingWhenNode.parse(trimmed) else { return .invalid("Use variables with !, &&, ||, and parentheses.") }
        return .ok(ast)
    }

    static let defaultRows = Keymap.defaultRules.map { (rule: $0, key: input($0.shortcut), when: expression($0.whenAst)) }

    static func source(_ b: ResolvedKeybindingRule) -> KeybindingRow.Source {
        if b.command.hasPrefix("script.") { return .project }
        let key = input(b.shortcut), when = expression(b.whenAst)
        return defaultRows.contains { $0.rule.command == b.command && $0.key == key && $0.when == when } ? .default : .custom
    }

    /// `defaultBindingForBinding`: same keys and when, else same when, else any default of the command.
    static func defaultBinding(_ b: ResolvedKeybindingRule) -> (rule: ResolvedKeybindingRule, key: String, when: String)? {
        let key = input(b.shortcut), when = expression(b.whenAst)
        return defaultRows.first { $0.rule.command == b.command && $0.key == key && $0.when == when }
            ?? defaultRows.first { $0.rule.command == b.command && $0.when == when }
            ?? defaultRows.first { $0.rule.command == b.command }
    }

    static func conflictsWithWhen(_ l: String, _ r: String) -> Bool { l.isEmpty || r.isEmpty || l == r }

    /// `keybindingConflictLabels`: commands on the same keys whose conditions can both hold.
    public static func conflictLabels(_ rows: [KeybindingRow], rowId: String, key: String, when: String) -> [String] {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let labels = rows.filter { $0.id != rowId && $0.key == key && conflictsWithWhen($0.when, when) }.map { commandLabel($0.command) }
        return Array(Set(labels)).sorted()
    }

    /// `buildKeybindingRows`: one row per rule, conflicts marked, sorted by command then keys, filtered by `query`.
    public static func rows(_ keybindings: [ResolvedKeybindingRule], query: String = "") -> [KeybindingRow] {
        var rows = keybindings.enumerated().map { index, b -> KeybindingRow in
            let key = input(b.shortcut), when = expression(b.whenAst)
            let d = defaultBinding(b)
            return KeybindingRow(id: "\(b.command)\u{0}\(key)\u{0}\(when)\u{0}\(index)", command: b.command, key: key, when: when,
                                 source: source(b), defaultKey: d?.key, defaultWhen: d?.when ?? "", binding: b, conflicts: [])
        }
        let snapshot = rows
        for i in rows.indices { rows[i].conflicts = conflictLabels(snapshot, rowId: rows[i].id, key: rows[i].key, when: rows[i].when) }
        rows.sort { l, r in
            let c = compareCommands(l.command, r.command) { $0 }
            return c != 0 ? c < 0 : compareStrings(l.key, r.key) < 0
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.command.lowercased().contains(q) || commandLabel($0.command).lowercased().contains(q) || $0.key.lowercased().contains(q)
                || $0.when.lowercased().contains(q) || $0.source.rawValue.lowercased().contains(q)
        }
    }

    /// `KEYBINDING_GROUPS`: a command joins the first group listing its prefix.
    static let groups: [(id: String, title: String, prefixes: [String])] = [
        ("navigation", "Navigation", ["sidebar", "rightPanel", "commandPalette", "filePicker", "projectSearch", "editor"]),
        ("threads", "Threads", ["thread", "chat", "pullRequest"]),
        ("composer", "Composer", ["composer", "modelPicker"]),
        ("terminal", "Terminal", ["terminal"]),
        ("preview", "Preview & diff", ["preview", "diff"]),
        ("appearance", "Appearance", ["theme", "appearance", "themeEditor"]),
        ("scripts", "Project scripts", ["script"]),
    ]

    /// `groupKeybindingRows`: page sections in order, empty ones dropped, the rest under Other.
    public static func group(_ rows: [KeybindingRow]) -> [KeybindingGroup] {
        var buckets: [String: [KeybindingRow]] = [:]
        for row in rows {
            let prefix = String(row.command.split(separator: ".").first ?? "")
            let id = groups.first { $0.prefixes.contains(prefix) }?.id ?? "other"
            buckets[id, default: []].append(row)
        }
        return (groups.map { ($0.id, $0.title) } + [("other", "Other")]).compactMap { id, title in
            buckets[id].map { KeybindingGroup(id: id, title: title, rows: $0) }
        }
    }

    /// `buildKeybindingCommandOptions`: every static command plus the config's, sorted by label.
    public static func commandOptions(_ keybindings: [ResolvedKeybindingRule]) -> [String] {
        var seen = Set<String>(), commands: [String] = []
        for c in staticCommands + keybindings.map(\.command) where seen.insert(c).inserted { commands.append(c) }
        return commands.sorted { compareCommands($0, $1, key: commandLabel) < 0 }
    }

    static let coreWhenVariables = ["terminalFocus", "terminalOpen", "isWeb", "isDesktop", "true", "false"]

    static func identifiers(_ node: KeybindingWhenNode?, into set: inout [String]) {
        guard let node else { return }
        switch node {
        case .identifier(let name): if !set.contains(name) { set.append(name) }
        case .not(let n): identifiers(n, into: &set)
        case .and(let l, let r), .or(let l, let r): identifiers(l, into: &set); identifiers(r, into: &set)
        }
    }

    /// `KNOWN_WHEN_VARIABLES`: the core names plus every name the defaults use.
    static let knownWhenVariables: [String] = {
        var names = coreWhenVariables
        for rule in Keymap.defaultRules { identifiers(rule.whenAst, into: &names) }
        return names
    }()

    /// `buildWhenVariableOptions`: core names first in their order, then the rest by name.
    public static let whenVariableOptions: [String] = knownWhenVariables.sorted { l, r in
        let li = coreWhenVariables.firstIndex(of: l), ri = coreWhenVariables.firstIndex(of: r)
        if li != nil || ri != nil { return (li ?? .max) < (ri ?? .max) }
        return l < r
    }

    /// `DEFAULT_WHEN_VARIABLE`.
    public static let defaultWhenVariable = knownWhenVariables.first { $0 != "true" && $0 != "false" } ?? "terminalFocus"

    /// `unknownWhenVariables`.
    public static func unknownVariables(_ node: KeybindingWhenNode?) -> [String] {
        var names: [String] = []
        identifiers(node, into: &names)
        return names.filter { !knownWhenVariables.contains($0) }.sorted()
    }

    /// `normalizeShortcutKeyToken`: modifiers alone record nothing.
    static func keyToken(_ key: String) -> String? {
        let k = key.lowercased()
        if ["meta", "control", "ctrl", "shift", "alt", "option"].contains(k) { return nil }
        if k == " " { return "space" }
        if k == "escape" { return "esc" }
        if k.count == 1 { return k }
        if k.range(of: "^f\\d{1,2}$", options: .regularExpression) != nil { return k }
        let named: Set<String> = ["arrowup", "arrowdown", "arrowleft", "arrowright", "enter", "tab", "backspace", "delete", "home", "end", "pageup", "pagedown"]
        return named.contains(k) ? k : nil
    }

    /// `keybindingFromKeyboardEvent` on macOS: Command records as `mod`, Control as `ctrl`.
    public static func binding(from stroke: KeyStroke) -> String? {
        let isLetter = stroke.key.count == 1 && stroke.key.first!.isASCII && stroke.key.first!.isLetter
        // `shortcutKeyFromEvent`: a layout letter, else the physical digit or punctuation key, else the layout key.
        let physical = stroke.physicalKey.flatMap { $0.count == 1 && $0.first!.isLetter ? nil : $0 }
        guard let token = keyToken(isLetter ? stroke.key : physical ?? stroke.key) else { return nil }
        var parts: [String] = []
        if stroke.meta { parts.append("mod") }
        if stroke.ctrl { parts.append("ctrl") }
        if stroke.alt { parts.append("alt") }
        if stroke.shift { parts.append("shift") }
        parts.append(token)
        return parts.joined(separator: "+")
    }

    /// `KeybindingPill` part labels on macOS.
    public static func pillParts(_ value: String) -> [String] {
        value.split(separator: "+", omittingEmptySubsequences: false).map { part in
            switch part {
            case "mod": "⌘"
            case "shift": "⇧"
            case "alt": "⌥"
            case "ctrl": "⌃"
            default: part.count == 1 ? part.uppercased() : String(part)
            }
        }
    }

    /// `KeybindingConflictWarning`'s text.
    public static func conflictDescription(_ labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        if labels.count == 1 { return "Conflicts with \(labels[0])." }
        return "Conflicts with \(labels.prefix(3).joined(separator: ", "))\(labels.count > 3 ? ", and more" : "")."
    }

    /// The upsert that saves a row's draft (`useKeybindingRowEditor.save`).
    public static func saveInput(row: KeybindingRow, key: String, when: String) -> (KeybindingTarget, replace: KeybindingTarget?) {
        let trimmed = when.trimmingCharacters(in: .whitespaces)
        return (KeybindingTarget(command: row.command, key: key.trimmingCharacters(in: .whitespaces), when: trimmed.isEmpty ? nil : trimmed),
                removeInput(row))
    }

    /// `rowKeybindingTarget`.
    public static func removeInput(_ row: KeybindingRow) -> KeybindingTarget {
        KeybindingTarget(command: row.command, key: row.key, when: row.when.trimmingCharacters(in: .whitespaces).isEmpty ? nil : row.when)
    }

    /// `resetKeybinding`: the default keys and when, replacing the row.
    public static func resetInput(_ row: KeybindingRow) -> (KeybindingTarget, replace: KeybindingTarget?)? {
        guard let key = row.defaultKey else { return nil }
        return (KeybindingTarget(command: row.command, key: key, when: row.defaultWhen.isEmpty ? nil : row.defaultWhen), removeInput(row))
    }

    /// The `server.upsertKeybinding` payload.
    public static func upsertPayload(_ target: KeybindingTarget, replace: KeybindingTarget?) -> JSONValue {
        guard case .object(var o) = target.json else { return target.json }
        if let replace { o["replace"] = replace.json }
        return .object(o)
    }
}
