import Foundation

/// The agents whose MCP servers and skills the Connectors tab manages.
public enum ConfigAgent: String, Codable, CaseIterable, Sendable {
    case claude, codex
    public var label: String { self == .claude ? "Claude" : "Codex" }
}

/// One MCP server as one agent sees it on one machine. Never carries a token or an env value.
public struct MCPServerEntry: Codable, Equatable, Sendable {
    public var name: String
    public var agent: ConfigAgent
    public var enabled: Bool
    /// `http`, `sse` or `stdio`.
    public var transport: String
    /// The URL or command line with anything that looks like a secret cut out, for display.
    public var summary: String
    public init(name: String, agent: ConfigAgent, enabled: Bool, transport: String, summary: String) {
        self.name = name; self.agent = agent; self.enabled = enabled; self.transport = transport; self.summary = summary
    }
}

public struct SkillEntry: Codable, Equatable, Sendable {
    /// The folder's name, which is also the name Claude matches in `skillOverrides`.
    public var name: String
    public var agent: ConfigAgent
    public var enabled: Bool
    public var description: String
    public init(name: String, agent: ConfigAgent, enabled: Bool, description: String) {
        self.name = name; self.agent = agent; self.enabled = enabled; self.description = description
    }
}

/// Everything the Connectors tab shows for one machine.
public struct AgentConfigSnapshot: Codable, Equatable, Sendable {
    public var servers: [MCPServerEntry] = []
    public var skills: [SkillEntry] = []
    /// One line per file that doesn't parse. Changes that need that file fail until it's fixed by hand.
    public var problems: [String] = []
    public init(servers: [MCPServerEntry] = [], skills: [SkillEntry] = [], problems: [String] = []) {
        self.servers = servers; self.skills = skills; self.problems = problems
    }
}

/// A new server for one or both agents. `url` or `command` is set, not both.
public struct NewMCPServer: Codable, Equatable, Sendable {
    public var name: String
    public var agents: [ConfigAgent]
    public var url: String?
    public var command: String?
    public var args: [String]
    /// Written into Claude's `headers` as `Authorization: Bearer …`, the way `claude mcp add --header` does. Codex
    /// never gets the token itself.
    public var bearerToken: String?
    /// The environment variable that holds the token: Codex's `bearer_token_env_var`, and `Bearer ${VAR}` for Claude
    /// when no token is given.
    public var tokenEnvVar: String?
    public init(name: String, agents: [ConfigAgent], url: String? = nil, command: String? = nil, args: [String] = [], bearerToken: String? = nil, tokenEnvVar: String? = nil) {
        self.name = name; self.agents = agents; self.url = url; self.command = command; self.args = args
        self.bearerToken = bearerToken; self.tokenEnvVar = tokenEnvVar
    }
}

public enum AgentConfigChange: Codable, Equatable, Sendable {
    case setServer(agent: ConfigAgent, name: String, enabled: Bool)
    case addServer(NewMCPServer)
    case removeServer(agent: ConfigAgent, name: String)
    case setSkill(agent: ConfigAgent, name: String, enabled: Bool)
}

/// Reads and edits the agents' config in one home folder (docs/connectors.md):
///
/// - Claude's servers: top-level `mcpServers` in `~/.claude.json`. Claude can only turn a user server off per project,
///   so turning one off here moves its entry to `~/.claude/candywrapper-off-mcp.json` and turning it on moves it back.
/// - Claude's skills: folders in `~/.claude/skills`, off with `skillOverrides: {name: "off"}` in `~/.claude/settings.json`.
/// - Codex's servers: `[mcp_servers.<name>]` in `~/.codex/config.toml`, off with `enabled = false`.
/// - Codex's skills: folders in `~/.agents/skills`, off with `[[skills.config]] path = ".../SKILL.md"`, `enabled = false`.
///
/// Every write goes to a temporary file next to the target and is renamed over it, and the first write to each file
/// copies it to `<file>.candywrapper-backup-<time>` first. A file that doesn't parse is never written.
public struct AgentConfigStore: Sendable {
    public let home: URL
    public init(home: URL) { self.home = home }

    var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    var claudeOff: URL { home.appendingPathComponent(".claude/candywrapper-off-mcp.json") }
    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    var claudeSkills: URL { home.appendingPathComponent(".claude/skills") }
    var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    var codexSkills: URL { home.appendingPathComponent(".agents/skills") }

    // MARK: Reading

    public func snapshot() -> AgentConfigSnapshot {
        var snap = AgentConfigSnapshot()
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { snap.problems.append("\(error)") }
        }
        attempt {
            let on = try readJSON(claudeJSON)?["mcpServers"]?.members ?? []
            let off = try readJSON(claudeOff)?["mcpServers"]?.members ?? []
            for m in on { snap.servers.append(Self.claudeEntry(m, enabled: true)) }
            for m in off where !on.contains(where: { $0.key == m.key }) { snap.servers.append(Self.claudeEntry(m, enabled: false)) }
        }
        attempt {
            let overrides = try readJSON(claudeSettings)?["skillOverrides"]
            for (name, description) in Self.skills(in: claudeSkills) {
                snap.skills.append(SkillEntry(name: name, agent: .claude, enabled: overrides?[name]?.stringValue != "off", description: description))
            }
        }
        attempt {
            let doc = try readTOML(codexConfig)
            for name in doc?.value(at: ["mcp_servers"])?.tableKeys ?? [] {
                guard let t = doc?.value(at: ["mcp_servers", name]) else { continue }
                snap.servers.append(Self.codexEntry(name, t))
            }
            let configs = doc?.arrayOfTables(["skills", "config"]) ?? []
            for (name, description) in Self.skills(in: codexSkills) {
                let path = codexSkillPath(name)
                let off = configs.contains { Self.samePath($0["path"]?.stringValue, path) && $0["enabled"]?.boolValue == false }
                snap.skills.append(SkillEntry(name: name, agent: .codex, enabled: !off, description: description))
            }
        }
        return snap
    }

    static func claudeEntry(_ m: OrderedJSON.Member, enabled: Bool) -> MCPServerEntry {
        let v = m.value
        let url = v["url"]?.stringValue
        let type = v["type"]?.stringValue ?? (url == nil ? "stdio" : "http")
        let summary = url.map(redactURL) ?? redactCommand(v["command"]?.stringValue ?? "", v["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return MCPServerEntry(name: m.key, agent: .claude, enabled: enabled, transport: type, summary: summary)
    }

    static func codexEntry(_ name: String, _ t: TOMLValue) -> MCPServerEntry {
        let url = t["url"]?.stringValue
        let summary = url.map(redactURL) ?? redactCommand(t["command"]?.stringValue ?? "", t["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return MCPServerEntry(name: name, agent: .codex, enabled: t["enabled"]?.boolValue ?? true, transport: url == nil ? "stdio" : "http", summary: summary)
    }

    /// Every `<dir>/<name>/SKILL.md`, sorted by name, with the description from its front matter.
    static func skills(in dir: URL) -> [(String, String)] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let file = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: file.path) else { return nil }
            return (name, frontMatterDescription(file))
        }
    }

    /// The `description:` line of a SKILL.md's front matter, cut to one short line. Reads only the first 8 KB.
    static func frontMatterDescription(_ file: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? h.close() }
        let text = String(decoding: h.readData(ofLength: 8192), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---" else { return "" }
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard line.hasPrefix("description:") else { continue }
            var d = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            if d.count >= 2, let f = d.first, f == d.last, f == "\"" || f == "'" { d = String(d.dropFirst().dropLast()) }
            if d == "|" || d == ">" { return "" }
            return d.count > 120 ? String(d.prefix(119)) + "…" : d
        }
        return ""
    }

    func codexSkillPath(_ name: String) -> String { codexSkills.appendingPathComponent(name).appendingPathComponent("SKILL.md").path }

    /// A `[[skills.config]]` path names this SKILL.md, written absolute or from `~`, with or without the file name.
    static func samePath(_ written: String?, _ path: String) -> Bool {
        guard var w = written else { return false }
        if w.hasPrefix("~/") { w = FileManager.default.homeDirectoryForCurrentUser.path + w.dropFirst(1) }
        let dir = (path as NSString).deletingLastPathComponent
        return w == path || w == dir || w == dir + "/"
    }

    // MARK: Redaction

    /// Scheme, host and path, with the query, any user info and long path segments cut, since links like Craft's
    /// carry their secret in the path.
    public static func redactURL(_ s: String) -> String {
        guard let c = URLComponents(string: s), let host = c.host else { return "URL" }
        let port = c.port.map { ":\($0)" } ?? ""
        let path = c.path.split(separator: "/").map { $0.count > 12 ? String($0.prefix(6)) + "…" : String($0) }
        return "\(c.scheme ?? "https")://\(host)\(port)" + (path.isEmpty ? "" : "/" + path.joined(separator: "/")) + (c.query == nil ? "" : "?…")
    }

    /// The command and its arguments, with the value after a flag that names a key, token, secret or password, any
    /// `NAME=value` and anything long and random-looking replaced by `…`.
    public static func redactCommand(_ command: String, _ args: [String]) -> String {
        let sensitive = ["key", "token", "secret", "password", "auth", "bearer"]
        var out = [command]
        var hideNext = false
        for a in args {
            if hideNext { out.append("…"); hideNext = false; continue }
            let lower = a.lowercased()
            if a.hasPrefix("-") {
                if let eq = a.firstIndex(of: "="), sensitive.contains(where: lower.contains) { out.append(String(a[...eq]) + "…"); continue }
                hideNext = sensitive.contains(where: lower.contains)
                out.append(a)
            } else if a.contains("="), !a.contains("/") {
                out.append(String(a[...a.firstIndex(of: "=")!]) + "…")
            } else if a.count >= 24, !a.contains("/"), !a.contains("@"), a.rangeOfCharacter(from: .decimalDigits) != nil {
                out.append("…")
            } else {
                out.append(a)
            }
        }
        return out.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Writing

    /// Applies the changes in order and returns the new snapshot. Stops at the first change that fails, after
    /// keeping the ones before it.
    @discardableResult
    public func apply(_ changes: [AgentConfigChange]) throws -> AgentConfigSnapshot {
        for change in changes { try apply(change) }
        return snapshot()
    }

    func apply(_ change: AgentConfigChange) throws {
        switch change {
        case .setServer(.claude, let name, let enabled):
            try setClaudeServer(name, enabled: enabled)
        case .setServer(.codex, let name, let enabled):
            try editTOML { doc in
                let path = ["mcp_servers", name]
                guard doc.value(at: path) != nil else { throw AgentConfigError.cannotEdit("Codex has no server named \(name).") }
                if enabled { try doc.set("enabled", to: "true", inTable: path) } else { try doc.set("enabled", to: "false", inTable: path) }
            }
        case .addServer(let s):
            try validate(s)
            if s.agents.contains(.claude) { try addClaudeServer(s) }
            if s.agents.contains(.codex) { try addCodexServer(s) }
        case .removeServer(.claude, let name):
            for file in [claudeJSON, claudeOff] {
                try editJSON(file) { root in
                    guard root["mcpServers"]?[name] != nil else { return false }
                    root["mcpServers"]?[name] = nil
                    return true
                }
            }
        case .removeServer(.codex, let name):
            try editTOML { doc in try doc.removeTable(["mcp_servers", name]) }
        case .setSkill(.claude, let name, let enabled):
            try editJSON(claudeSettings, create: true) { root in
                if enabled {
                    guard root["skillOverrides"]?[name]?.stringValue == "off" else { return false }
                    root["skillOverrides"]?[name] = nil
                    if root["skillOverrides"]?.members?.isEmpty == true { root["skillOverrides"] = nil }
                } else {
                    if root["skillOverrides"] == nil { root["skillOverrides"] = .object([]) }
                    guard root["skillOverrides"]?[name]?.stringValue != "off" else { return false }
                    root["skillOverrides"]?[name] = .string("off")
                }
                return true
            }
        case .setSkill(.codex, let name, let enabled):
            let path = codexSkillPath(name)
            try editTOML { doc in
                let entries = doc.arrayOfTables(["skills", "config"])
                if let i = entries.firstIndex(where: { Self.samePath($0["path"]?.stringValue, path) }) {
                    if enabled, Set(entries[i].tableKeys ?? []).isSubset(of: ["path", "enabled"]) {
                        try doc.removeArrayEntry(["skills", "config"], index: i)
                    } else {
                        try doc.set("enabled", to: TOMLDocument.literal(enabled), inArrayOfTables: ["skills", "config"], index: i)
                    }
                } else if !enabled {
                    try doc.appendArrayEntry(["skills", "config"], entries: [("path", TOMLDocument.literal(path)), ("enabled", "false")])
                }
            }
        }
    }

    func validate(_ s: NewMCPServer) throws {
        guard !s.name.isEmpty, s.name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            throw AgentConfigError.cannotEdit("A server name uses only letters, digits, - and _.")
        }
        guard (s.url == nil) != (s.command == nil) else { throw AgentConfigError.cannotEdit("A server needs a URL or a command.") }
        if let v = s.tokenEnvVar, v.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
            throw AgentConfigError.cannotEdit("\(v) isn't an environment variable name.")
        }
        let existing = snapshot()
        for agent in s.agents where existing.servers.contains(where: { $0.agent == agent && $0.name == s.name }) {
            throw AgentConfigError.cannotEdit("\(agent.label) already has a server named \(s.name).")
        }
    }

    /// Moves the entry between `~/.claude.json` and the parking file. The copy is written before the original goes,
    /// so a crash between the two leaves the server in both files, never in neither.
    func setClaudeServer(_ name: String, enabled: Bool) throws {
        let (from, to) = enabled ? (claudeOff, claudeJSON) : (claudeJSON, claudeOff)
        guard let entry = try readJSON(from)?["mcpServers"]?[name] else {
            if try readJSON(to)?["mcpServers"]?[name] != nil { return }
            throw AgentConfigError.cannotEdit("Claude has no server named \(name).")
        }
        try editJSON(to, create: true) { root in
            if root["mcpServers"] == nil { root["mcpServers"] = .object([]) }
            root["mcpServers"]?[name] = entry
            return true
        }
        try editJSON(from) { root in
            root["mcpServers"]?[name] = nil
            return true
        }
    }

    func addClaudeServer(_ s: NewMCPServer) throws {
        var members: [OrderedJSON.Member] = []
        if let url = s.url {
            members.append(.init(key: "type", value: .string("http")))
            members.append(.init(key: "url", value: .string(url)))
            let auth = s.bearerToken.map { "Bearer \($0)" } ?? s.tokenEnvVar.map { "Bearer ${\($0)}" }
            if let auth { members.append(.init(key: "headers", value: .object([.init(key: "Authorization", value: .string(auth))]))) }
        } else if let command = s.command {
            members.append(.init(key: "type", value: .string("stdio")))
            members.append(.init(key: "command", value: .string(command)))
            members.append(.init(key: "args", value: .array(s.args.map { .string($0) })))
            members.append(.init(key: "env", value: .object([])))
        }
        try editJSON(claudeJSON, create: true) { root in
            if root["mcpServers"] == nil { root["mcpServers"] = .object([]) }
            root["mcpServers"]?[s.name] = .object(members)
            return true
        }
    }

    func addCodexServer(_ s: NewMCPServer) throws {
        var entries: [(key: String, literal: String)] = []
        if let url = s.url {
            entries.append(("url", TOMLDocument.literal(url)))
            if let v = s.tokenEnvVar { entries.append(("bearer_token_env_var", TOMLDocument.literal(v))) }
        } else if let command = s.command {
            entries.append(("command", TOMLDocument.literal(command)))
            if !s.args.isEmpty { entries.append(("args", TOMLDocument.literal(s.args))) }
        }
        try editTOML { doc in try doc.appendTable(["mcp_servers", s.name], entries: entries) }
    }

    // MARK: Files

    /// Nil when the file doesn't exist.
    func readJSON(_ url: URL) throws -> OrderedJSON? {
        guard let text = try readText(url) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([]) }
        do { return try OrderedJSON.parse(text) } catch let e as AgentConfigError { throw e.inFile(display(url)) }
    }

    func readTOML(_ url: URL) throws -> TOMLDocument? {
        guard let text = try readText(url) else { return nil }
        do { return try TOMLDocument(text) } catch let e as AgentConfigError { throw e.inFile(display(url)) }
    }

    func readText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try String(contentsOf: url, encoding: .utf8) } catch { throw AgentConfigError.io("Couldn't read \(display(url)): \(error.localizedDescription)") }
    }

    /// `~/.claude.json` rather than the full path, for messages.
    func display(_ url: URL) -> String {
        let h = home.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    /// Reads, edits and writes back a JSON file whose root is an object. `edit` returns false when nothing changed.
    /// Claude rewrites `~/.claude.json` often, so the write retries when the file changed under the edit.
    func editJSON(_ url: URL, create: Bool = false, _ edit: (inout OrderedJSON) throws -> Bool) throws {
        try withRetry(url) {
            let original = try readText(url)
            guard original != nil || create else { return nil }
            var root = try readJSON(url) ?? .object([])
            guard root.members != nil else { throw AgentConfigError.cannotEdit("\(display(url)) isn't a JSON object.") }
            guard try edit(&root) else { return nil }
            let indent = original.map(OrderedJSON.detectIndent) ?? "  "
            let trailing = original.map { $0.hasSuffix("\n") } ?? true
            return root.serialized(indent: indent) + (trailing ? "\n" : "")
        }
    }

    func editTOML(_ edit: (inout TOMLDocument) throws -> Void) throws {
        try withRetry(codexConfig) {
            let original = try readTOML(codexConfig)
            var doc = try original ?? TOMLDocument("")
            try edit(&doc)
            return doc.text == original?.text ? nil : doc.text
        }
    }

    /// Runs `make` for the new text (nil: nothing to write) and writes it, again when the file changed meanwhile.
    func withRetry(_ url: URL, _ make: () throws -> String?) throws {
        for attempt in 0..<3 {
            let before = Self.stamp(url)
            guard let text = try make() else { return }
            if Self.stamp(url) != before, attempt < 2 { continue }
            try write(text, to: url)
            return
        }
    }

    static func stamp(_ url: URL) -> [String] {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [] }
        return ["\(a[.modificationDate] ?? "")", "\(a[.size] ?? "")"]
    }

    /// Backs the file up once, then writes beside it and renames over it with the same permissions. A symlink stays a
    /// symlink: the write goes to the file it points at.
    func write(_ text: String, to link: URL) throws {
        let fm = FileManager.default
        let url = link.resolvingSymlinksInPath()
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var permissions: Any? = nil
            if fm.fileExists(atPath: url.path) {
                permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
                try backUpOnce(url)
            }
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).candywrapper-\(ProcessInfo.processInfo.processIdentifier).tmp")
            try Data(text.utf8).write(to: tmp)
            try fm.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: tmp.path)
            if rename(tmp.path, url.path) != 0 {
                try? fm.removeItem(at: tmp)
                throw AgentConfigError.io("Couldn't replace \(display(link)): \(String(cString: strerror(errno)))")
            }
        } catch let e as AgentConfigError {
            throw e
        } catch {
            throw AgentConfigError.io("Couldn't write \(display(link)): \(error.localizedDescription)")
        }
    }

    public static let backupMarker = ".candywrapper-backup-"

    /// Copies the file to `<file>.candywrapper-backup-<yyyyMMdd-HHmmss>` unless a backup of it is already there.
    func backUpOnce(_ url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + Self.backupMarker
        if (try fm.contentsOfDirectory(atPath: dir.path)).contains(where: { $0.hasPrefix(prefix) }) { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        try fm.copyItem(at: url, to: dir.appendingPathComponent(prefix + f.string(from: Date())))
    }
}

/// How the helper's `config` command and the app talk through a terminal: base64 JSON on single lines, so no
/// character in a name or path can reach the shell or break a line.
public enum ConfigWire {
    /// Built from parts where it's typed, like CWH-RESULT, so the echoed command never reads as an answer.
    public static let marker = "CWH-CONFIG "

    public static func encode(_ snapshot: AgentConfigSnapshot) -> String {
        (try? JSONEncoder().encode(snapshot))?.base64EncodedString() ?? ""
    }
    public static func decodeSnapshot(_ base64: String) -> AgentConfigSnapshot? {
        Data(base64Encoded: base64).flatMap { try? JSONDecoder().decode(AgentConfigSnapshot.self, from: $0) }
    }
    /// The changes as lines of at most 512 characters, then a lone dot: a terminal in canonical mode cuts lines
    /// at 1,024 bytes on macOS.
    public static func encodeChanges(_ changes: [AgentConfigChange]) -> String {
        var rest = Substring((try? JSONEncoder().encode(changes))?.base64EncodedString() ?? "")
        var lines: [String] = []
        while !rest.isEmpty { lines.append(String(rest.prefix(512))); rest = rest.dropFirst(512) }
        return lines.joined(separator: "\n") + "\n.\n"
    }
    public static func decodeChanges(_ base64: String) -> [AgentConfigChange]? {
        Data(base64Encoded: base64).flatMap { try? JSONDecoder().decode([AgentConfigChange].self, from: $0) }
    }
}
