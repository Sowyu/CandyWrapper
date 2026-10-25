import Foundation
import Testing
@testable import AgentConfig

/// Every test runs in its own throwaway home folder; nothing here reads or writes a real config.
@Suite struct AgentConfigStoreTests {
    let home: URL
    let store: AgentConfigStore

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        store = AgentConfigStore(home: home)
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func read(_ path: String) -> String? { try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }
    func backups(_ path: String) -> [String] {
        let url = home.appendingPathComponent(path)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasPrefix(url.lastPathComponent + AgentConfigStore.backupMarker) }
    }

    static let claudeJSON = """
    {
      "numStartups": 412,
      "projects": {
        "/Users/x/app": {
          "allowedTools": [],
          "disabledMcpServers": ["github"]
        }
      },
      "mcpServers": {
        "craft": {
          "type": "http",
          "url": "https://api.craft.do/v1/links/Zri0wpSECRETSECRET/mcp",
          "headers": {
            "Authorization": "Bearer fake-claude-value"
          }
        },
        "github": {
          "type": "stdio",
          "command": "npx",
          "args": ["-y", "@github/mcp-server", "--token", "fake-arg-value"],
          "env": {
            "GITHUB_TOKEN": "fake-env-value"
          }
        }
      },
      "zUnknownKey": {"keep": true, "n": 1.50}
    }

    """

    static let codexTOML = """
    # My Codex config. Keep this comment.
    model = "gpt-5"   # default model

    [mcp_servers.github]
    command = "npx"
    args = [
      "-y", # yes
      "@github/mcp-server",
    ]

    [mcp_servers.github.env]
    GITHUB_TOKEN = "fake-arg-value"

    # Figma, on purpose
    [mcp_servers.figma]
    url = "https://mcp.figma.com/mcp"
    bearer_token_env_var = "FIGMA_TOKEN"
    enabled = true  # keep

    [profiles.fast]
    model = "gpt-5-mini"

    """

    // MARK: Reading

    @Test func readsServersAndSkillsWithoutSecrets() throws {
        try write(".claude.json", Self.claudeJSON)
        try write(".codex/config.toml", Self.codexTOML)
        try write(".claude/skills/unslop/SKILL.md", "---\nname: unslop\ndescription: \"Plain writing rules\"\n---\nbody")
        try write(".agents/skills/review/SKILL.md", "---\ndescription: Review code\n---\n")
        try write(".agents/skills/not-a-skill/README.md", "x")
        let snap = store.snapshot()
        #expect(snap.problems.isEmpty)
        #expect(snap.servers.map { "\($0.agent.rawValue):\($0.name):\($0.enabled)" } == ["claude:craft:true", "claude:github:true", "codex:github:true", "codex:figma:true"])
        #expect(snap.skills.map { "\($0.agent.rawValue):\($0.name):\($0.description)" } == ["claude:unslop:Plain writing rules", "codex:review:Review code"])
        let wire = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        for secret in ["fake-claude-value", "fake-arg-value", "fake-env-value", "SECRETSECRET"] { #expect(!wire.contains(secret)) }
    }

    @Test func invalidFilesReportAndNeverWrite() throws {
        try write(".claude.json", "{\"mcpServers\": {\"a\": {},}}")
        try write(".codex/config.toml", "[mcp_servers.x]\ncommand = \"unterminated\n")
        let snap = store.snapshot()
        #expect(snap.problems.count == 2)
        #expect(snap.problems.contains { $0.contains("~/.claude.json") })
        #expect(snap.problems.contains { $0.contains("~/.codex/config.toml") })
        #expect(throws: AgentConfigError.self) { try store.apply([.setServer(agent: .claude, name: "a", enabled: false)]) }
        #expect(throws: AgentConfigError.self) { try store.apply([.setServer(agent: .codex, name: "x", enabled: false)]) }
        #expect(throws: AgentConfigError.self) { try store.apply([.addServer(NewMCPServer(name: "n", agents: [.codex], url: "https://x.dev/mcp"))]) }
        #expect(read(".claude.json") == "{\"mcpServers\": {\"a\": {},}}")
        #expect(read(".codex/config.toml") == "[mcp_servers.x]\ncommand = \"unterminated\n")
        #expect(backups(".claude.json").isEmpty && backups(".codex/config.toml").isEmpty)
    }

    // MARK: Claude

    @Test func claudeOffParksTheEntryAndOnBringsItBackByteForByte() throws {
        try write(".claude.json", Self.claudeJSON)
        try store.apply([.setServer(agent: .claude, name: "github", enabled: false)])
        let off = try #require(read(".claude.json"))
        #expect(!off.contains("@github/mcp-server"))
        #expect(off.contains("\"zUnknownKey\": {\n    \"keep\": true,\n    \"n\": 1.50\n  }"))
        #expect(off.contains("\"disabledMcpServers\": [\n        \"github\"\n      ]"))
        #expect(read(".claude/candywrapper-off-mcp.json")?.contains("fake-arg-value") == true)
        #expect(store.snapshot().servers.first { $0.agent == .claude && $0.name == "github" }?.enabled == false)
        try store.apply([.setServer(agent: .claude, name: "github", enabled: true)])
        let parsedBack = try OrderedJSON.parse(try #require(read(".claude.json")))
        let parsedOriginal = try OrderedJSON.parse(Self.claudeJSON)
        // Same keys and values; github moved to the end of mcpServers, which Claude doesn't care about.
        #expect(parsedBack["mcpServers"]?["github"] == parsedOriginal["mcpServers"]?["github"])
        #expect(parsedBack["zUnknownKey"] == parsedOriginal["zUnknownKey"])
        #expect(parsedBack["projects"] == parsedOriginal["projects"])
        #expect(read(".claude/candywrapper-off-mcp.json")?.contains("github") == false)
    }

    @Test func firstWriteKeepsOneBackupWithTheOriginal() throws {
        try write(".claude.json", Self.claudeJSON)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".claude.json").path)
        try store.apply([.setServer(agent: .claude, name: "craft", enabled: false)])
        try store.apply([.setServer(agent: .claude, name: "craft", enabled: true)])
        let list = backups(".claude.json")
        #expect(list.count == 1)
        let backup = try String(contentsOf: home.appendingPathComponent(list[0]), encoding: .utf8)
        #expect(backup == Self.claudeJSON)
        let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func symlinkedConfigStaysALink() throws {
        try write("dotfiles/claude.json", Self.claudeJSON)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".claude.json").path, withDestinationPath: home.appendingPathComponent("dotfiles/claude.json").path)
        try store.apply([.setServer(agent: .claude, name: "craft", enabled: false)])
        let attrs = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude.json").path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(read("dotfiles/claude.json")?.contains("craft") == false)
    }

    @Test func claudeSkillOverrides() throws {
        try write(".claude/settings.json", "{\n    \"model\": \"opus\",\n    \"skillOverrides\": {\n        \"deploy\": \"name-only\"\n    }\n}\n")
        try write(".claude/skills/unslop/SKILL.md", "---\ndescription: x\n---\n")
        try store.apply([.setSkill(agent: .claude, name: "unslop", enabled: false)])
        #expect(read(".claude/settings.json") == "{\n    \"model\": \"opus\",\n    \"skillOverrides\": {\n        \"deploy\": \"name-only\",\n        \"unslop\": \"off\"\n    }\n}\n")
        #expect(store.snapshot().skills.first?.enabled == false)
        try store.apply([.setSkill(agent: .claude, name: "unslop", enabled: true)])
        #expect(read(".claude/settings.json") == "{\n    \"model\": \"opus\",\n    \"skillOverrides\": {\n        \"deploy\": \"name-only\"\n    }\n}\n")
    }

    @Test func claudeSkillOffCreatesSettingsWhenMissing() throws {
        try write(".claude/skills/unslop/SKILL.md", "---\ndescription: x\n---\n")
        try store.apply([.setSkill(agent: .claude, name: "unslop", enabled: false)])
        #expect(read(".claude/settings.json") == "{\n  \"skillOverrides\": {\n    \"unslop\": \"off\"\n  }\n}\n")
    }

    // MARK: Codex

    @Test func codexToggleKeepsEveryOtherByte() throws {
        try write(".codex/config.toml", Self.codexTOML)
        try store.apply([.setServer(agent: .codex, name: "github", enabled: false), .setServer(agent: .codex, name: "figma", enabled: false)])
        let expected = Self.codexTOML
            .replacingOccurrences(of: "  \"@github/mcp-server\",\n]\n", with: "  \"@github/mcp-server\",\n]\nenabled = false\n")
            .replacingOccurrences(of: "enabled = true  # keep", with: "enabled = false  # keep")
        #expect(read(".codex/config.toml") == expected)
        #expect(backups(".codex/config.toml").count == 1)
        #expect(store.snapshot().servers.filter { $0.agent == .codex }.allSatisfy { !$0.enabled })
    }

    @Test func codexRemoveTakesTheEnvTableAndNothingElse() throws {
        try write(".codex/config.toml", Self.codexTOML)
        try store.apply([.removeServer(agent: .codex, name: "github")])
        let text = try #require(read(".codex/config.toml"))
        #expect(!text.contains("github") && !text.contains("fake-arg-value"))
        #expect(text.hasPrefix("# My Codex config. Keep this comment.\nmodel = \"gpt-5\"   # default model\n"))
        #expect(text.contains("# Figma, on purpose\n[mcp_servers.figma]"))
        #expect(text.contains("[profiles.fast]\nmodel = \"gpt-5-mini\""))
    }

    @Test func codexSkillsConfig() throws {
        try write(".codex/config.toml", Self.codexTOML)
        try write(".agents/skills/review/SKILL.md", "---\ndescription: Review\n---\n")
        try store.apply([.setSkill(agent: .codex, name: "review", enabled: false)])
        let path = home.appendingPathComponent(".agents/skills/review/SKILL.md").path
        #expect(read(".codex/config.toml") == Self.codexTOML + "\n[[skills.config]]\npath = \"\(path)\"\nenabled = false\n")
        #expect(store.snapshot().skills.first?.enabled == false)
        try store.apply([.setSkill(agent: .codex, name: "review", enabled: true)])
        #expect(read(".codex/config.toml")?.trimmingCharacters(in: .newlines) == Self.codexTOML.trimmingCharacters(in: .newlines))
    }

    // MARK: Adding

    @Test func addingKeepsTheTokenOutOfCodex() throws {
        try write(".claude.json", Self.claudeJSON)
        try write(".codex/config.toml", Self.codexTOML)
        let server = NewMCPServer(name: "zapier", agents: [.claude, .codex], url: "https://mcp.zapier.com/api/mcp", bearerToken: "fake-zapier-value", tokenEnvVar: "ZAPIER_TOKEN")
        try store.apply([.addServer(server)])
        let claude = try OrderedJSON.parse(try #require(read(".claude.json")))
        #expect(claude["mcpServers"]?["zapier"]?["headers"]?["Authorization"]?.stringValue == "Bearer fake-zapier-value")
        let codex = try #require(read(".codex/config.toml"))
        #expect(!codex.contains("fake-zapier-value"))
        #expect(codex.hasSuffix("\n[mcp_servers.zapier]\nurl = \"https://mcp.zapier.com/api/mcp\"\nbearer_token_env_var = \"ZAPIER_TOKEN\"\n"))
        #expect(throws: AgentConfigError.self) { try store.apply([.addServer(server)]) }
    }

    @Test func addingToAnEmptyHomeCreatesTheFiles() throws {
        try store.apply([.addServer(NewMCPServer(name: "fs", agents: [.claude, .codex], command: "npx", args: ["-y", "@mcp/fs", "/tmp"]))])
        #expect(read(".claude.json") == "{\n  \"mcpServers\": {\n    \"fs\": {\n      \"type\": \"stdio\",\n      \"command\": \"npx\",\n      \"args\": [\n        \"-y\",\n        \"@mcp/fs\",\n        \"/tmp\"\n      ],\n      \"env\": {}\n    }\n  }\n}\n")
        #expect(read(".codex/config.toml") == "[mcp_servers.fs]\ncommand = \"npx\"\nargs = [\"-y\", \"@mcp/fs\", \"/tmp\"]\n")
    }

    @Test func badNamesAndVariablesAreRefused() {
        #expect(throws: AgentConfigError.self) { try store.apply([.addServer(NewMCPServer(name: "a b", agents: [.claude], url: "https://x.dev"))]) }
        #expect(throws: AgentConfigError.self) { try store.apply([.addServer(NewMCPServer(name: "a", agents: [.codex], url: "https://x.dev", tokenEnvVar: "$(rm)"))]) }
        #expect(read(".claude.json") == nil)
    }

    // MARK: Redaction and wire

    @Test func redaction() {
        #expect(AgentConfigStore.redactURL("https://api.craft.do/v1/links/Zri0wpSECRETSECRET/mcp?key=1") == "https://api.craft.do/v1/links/Zri0wp…/mcp?…")
        #expect(AgentConfigStore.redactURL("https://user:pw@mcp.figma.com/mcp") == "https://mcp.figma.com/mcp")
        #expect(AgentConfigStore.redactCommand("npx", ["-y", "@github/mcp-server", "--token", "fake-flag-value", "--api-key=abc", "FOO=bar"]) == "npx -y @github/mcp-server --token … --api-key=… FOO=…")
    }

    @Test func wireRoundTripSplitsLongLines() throws {
        let changes: [AgentConfigChange] = [.addServer(NewMCPServer(name: "x", agents: [.claude], url: "https://x.dev/" + String(repeating: "a", count: 2000), bearerToken: "t"))]
        let text = ConfigWire.encodeChanges(changes)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.last == "." && lines.dropLast().allSatisfy { $0.count <= 512 })
        #expect(ConfigWire.decodeChanges(lines.dropLast().joined()) == changes)
        let snap = AgentConfigSnapshot(servers: [MCPServerEntry(name: "a", agent: .codex, enabled: false, transport: "http", summary: "s")])
        #expect(ConfigWire.decodeSnapshot(ConfigWire.encode(snap)) == snap)
    }
}
