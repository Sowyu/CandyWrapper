# Connectors tab

Redesign's Settings > Connectors lists the MCP servers and skills that Claude Code and Codex use on each machine, and turns them on or off, adds servers and removes them. T3 has no RPC for any of this: skills come read-only in the provider snapshot (`packages/contracts/src/server.ts:108`), and T3 adds its own `t3-code` server to every thread at run time, so the tab shows that one as "Always on". Built 2026-10-25.

## How a machine is read and changed

1. The app opens a hidden T3 terminal on the machine (`HiddenTerminal`, the same path the helper's install uses, docs/orchestrator-helper.md section 2). T3 doesn't check the terminal's thread id, and the folder is `/`.
2. It types `HelperInstall.configCommand`. The line reuses `$d/versions/<version>/candywrapper-helper` when this app's helper release is there, or downloads it and checks its SHA-256 first. It installs no service.
3. `candywrapper-helper config get` prints `CWH-CONFIG <base64 JSON>` and `CWH-RESULT ok config`. `config set` turns echo off, prints `CWH-READY`, reads the changes as base64 JSON lines of at most 512 characters ending in a lone dot, applies them and prints the new snapshot.
4. `ConnectorsController` runs one command at a time per machine and hands the snapshot to `ConnectorsStore`. Nothing is cached between launches.

macOS and Linux run the same `AgentConfigStore` code, in the AgentConfig module (Foundation only).

## What each switch edits

| | Servers | Off | Skills | Off |
|---|---|---|---|---|
| Claude | top-level `mcpServers` in `~/.claude.json` | the entry moves to `~/.claude/candywrapper-off-mcp.json` | `~/.claude/skills/<name>/SKILL.md` | `skillOverrides: {name: "off"}` in `~/.claude/settings.json` |
| Codex | `[mcp_servers.<name>]` in `~/.codex/config.toml` | `enabled = false` | `~/.agents/skills/<name>/SKILL.md` | `[[skills.config]]` with `path` to the SKILL.md and `enabled = false` |

Claude can only turn a user server off per project (`disabledMcpServers` inside `projects`, code.claude.com/docs/en/mcp), so the tab parks the entry in its own file instead. The copy is written before the original goes, so a crash leaves the server in both files, never in neither. Turning a Claude skill back on removes only an `"off"` override and leaves `name-only` and the other values alone.

## Safety

- JSON keeps every key in file order and number literals as written (`OrderedJSON`). It's rewritten in `JSON.stringify` style with the file's own indent.
- TOML is edited line by line (`TOMLDocument`): comments, blank lines and untouched values stay byte for byte, and every edit is parsed again before it counts. Removing a table keeps the comments above the next table.
- A file that doesn't parse shows as an error on the tab and is never written.
- Each write goes to a temporary file beside the target and is renamed over it with the same permissions. A symlinked file stays a link. The first write to a file copies it to `<file>.candywrapper-backup-<yyyyMMdd-HHmmss>` next to it.
- Removing is its own action with a confirm. Turning off never deletes.
- Snapshots carry no token, header value or env value. URLs lose their query and long path segments, and command arguments after flags like `--token` show as `…`.
- A new server's token goes to Claude's `headers` as `Bearer …`, as `claude mcp add --header` writes it. Codex gets only `bearer_token_env_var`. The token travels on the echo-off stdin, so it never reaches the terminal's scrollback.

## Testing

`scripts/connectors-sandbox` builds a local helper release and a throwaway home at `~/CandyWrapper-research/sandbox/connectors-home`, and prints the three variables for `scripts/run-app`. `CANDY_CONNECTORS_CONFIG_HOME` passes `--config-home`, so the sandbox server's terminal, which runs with the real HOME, never touches a real config. Tests live in `AgentConfigTests` and `ConnectorRowsTests`.

## Not done yet

- A machine that's offline misses a change made under Every machine. The helper can't replay it: its sessions hold only `orchestration:*` scopes, not `terminal:operate`.
- Skills in `~/.codex/skills`, project-scope servers and `.mcp.json` aren't listed.
- The first run on a machine downloads the helper, which needs this release published. Each change takes a few seconds, the time a terminal needs to open.
