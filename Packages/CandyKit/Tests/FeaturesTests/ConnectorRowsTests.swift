import AgentConfig
import Testing
@testable import Features

/// "Every machine" merges each machine's servers by name and sends each machine only the changes it needs.
@MainActor struct ConnectorRowsTests {
    func server(_ name: String, _ agent: ConfigAgent, _ on: Bool) -> MCPServerEntry {
        MCPServerEntry(name: name, agent: agent, enabled: on, transport: "http", summary: "https://x.dev")
    }

    @Test func mergesAcrossMachinesAndAgents() {
        let a = AgentConfigSnapshot(servers: [server("gh", .claude, true), server("gh", .codex, false)])
        let b = AgentConfigSnapshot(servers: [server("gh", .claude, true)], problems: ["~/.codex/config.toml doesn't parse at line 3: x"])
        let rows = ConnectorRows([("a", "miniko", .loaded(a)), ("b", "aniko", .loaded(b)), ("c", "MacBook", .failed("MacBook didn't answer in time."))], prefixProblems: true)
        #expect(rows.problems == ["aniko: ~/.codex/config.toml doesn't parse at line 3: x", "MacBook: MacBook didn't answer in time."])
        let gh = rows.servers[0]
        #expect(gh.agents == [.claude, .codex])
        #expect(gh.isOn(.claude) == true && gh.isOn(.codex) == false && gh.isOn == nil)
        // Turning everything on touches only machine a's Codex copy.
        #expect(gh.changes(to: true, skill: false) == ["a": [.setServer(agent: .codex, name: "gh", enabled: true)]])
        let off = gh.changes(to: false, agent: .claude, skill: false)
        #expect(off["a"] == [.setServer(agent: .claude, name: "gh", enabled: false)] && off["b"] == [.setServer(agent: .claude, name: "gh", enabled: false)])
        #expect(gh.removals()["a"] == [.removeServer(agent: .claude, name: "gh"), .removeServer(agent: .codex, name: "gh")])
    }
}
