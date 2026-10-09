# T3 Code local server: discovery, launch and pairing (for a native macOS client)

Repository: /Users/mrm/CandyWrapper-research/t3code at tag v0.0.46-nightly.20261009.2861 (HEAD 3b6af0bd1).

Method: read-only reading of source and docs. Nothing was executed, no server was started, nothing under ~/.t3 was read. Citations are `path:line` relative to the repo root. The `effect` library sources were not installed in the checkout (no node_modules), so any behavior that depends on effect internals (effect/cli parsing, Config parsing, Console and Logger streams, HttpRouter middleware semantics, NodeRuntime signal handling) is marked UNVERIFIED.

Note: `apps/server/package.json` declares package name `t3`, version `0.0.45` and bin `t3 -> ./dist/bin.mjs` (line numbers not captured; the tag is v0.0.46-nightly, so release builds presumably stamp the version, UNVERIFIED).

---

## 0. Key facts

- The data directory flag on `t3` is `--base-dir` (env `T3CODE_HOME`). There is no `--home-dir` flag on `t3`; `--home-dir` exists only on the dev runner script (scripts/dev-runner.ts:851). Default home is `~/.t3` (apps/server/src/os-jank.ts:105-111).
- State dir is `<home>/userdata`, or `<home>/dev` when a dev URL is configured and the base dir was not given explicitly (apps/server/src/config.ts:139-142).
- Default port constant is 3773 (apps/server/src/config.ts:23). Web mode uses 3773 if free on loopback, otherwise an OS-assigned ephemeral port, not a scan (packages/shared/src/Net.ts:195-201). Desktop mode uses 3773 with no check (apps/server/src/cli/config.ts:305-307). The desktop app scans upward from 3773 (apps/desktop/src/app/DesktopApp.ts:75-109). 13773 is only the dev-runner base port (scripts/dev-runner.ts:27-28).
- Discovery file: `<stateDir>/server-runtime.json`, `{version:1, pid, host?, port, origin, devUrl?, startedAt, serviceManaged?}` (apps/server/src/serverRuntimeState.ts:11-27). Written by every server run (web, desktop, service) after activation; deleted on graceful shutdown (apps/server/src/server.ts:735-768).
- There is no per-home lock file. Only `t3` and `t3 start` in web mode refuse to start when server-runtime.json names a live pid (apps/server/src/cli/config.ts:333-342). `t3 serve`, desktop mode and the desktop app do not check.
- Readiness: `GET /.well-known/t3/environment` (unauthenticated) returning 2xx (apps/desktop/src/backend/DesktopBackendManager.ts:70, 378-399).
- Credentials: one-time pairing token (12 chars, default 5 min, single use, stored in SQLite) exchanged at `POST /oauth/token` (OAuth token-exchange form) for a 30-day bearer token, or at `POST /api/auth/browser-session` for a cookie. CLI: `t3 auth pairing create --json`, `t3 auth session issue --json` or `--token-only`.
- Desktop passes a one-line JSON bootstrap envelope on fd 3 (`--bootstrap-fd 3`), or on stdin (`--bootstrap-fd 0`) for WSL (apps/desktop/src/backend/DesktopBackendConfiguration.ts:589-606, 821-832). No env var carries the desktop credential.
- Background service (macOS): LaunchAgent label `com.t3tools.t3code.service`, plist `~/Library/LaunchAgents/com.t3tools.t3code.service.plist`, runs `<home>/runtime/versions/<v>/t3 __service-launcher`, which spawns `<home>/runtime/versions/<v>/t3 serve` with no flags (apps/server/src/cloud/bootService.ts:43-44, 309-314, 629-634; apps/server/src/serviceLauncher.ts:49-63).

---

## 1. Server CLI surface

### 1.1 Entry points and command tree

- `apps/server/src/bin.ts:12-27`: thin entry. If argv[2] is `acp-mcp-bridge` or `acp-mcp-call` it runs a fast path; otherwise it imports `binCli.ts` and calls `runCli()`.
- `apps/server/src/binCli.ts:57-90`: root command `t3` takes the shared server flags and runs `runDefaultServerCommand`. Subcommands: `help`, `acp-mcp-bridge`, `acp-mcp-call`, `start`, `serve`, `app`, `pair`, `auth`, `browser`, `project`, `service`, `update`, `uninstall`, `__service-launcher`, `__claude-history`, `__ssh-helper`, `__service-preflight`, `theme`, `trace`, `triage`, and `connect` (replaced by an unlisted stub when the build lacks T3 Connect public config, apps/server/src/cli/../binCli.ts:33-55, 88).
- `apps/server/src/binCli.ts:94-100`: `Command.run(cli, { version: packageJson.version })` under `NodeRuntime.runMain`.
- Global flags come from effect/cli. `GlobalFlag.LogLevel` is read by the server commands (apps/server/src/cli/server.ts:24) and `--log-level error` is passed by an in-repo script (scripts/mobile-showcase.ts:629-630); `t3 pair` comments "an explicit --log-level still wins" (apps/server/src/cli/pair.ts:494). Exact spelling of `--help` and `--version` and accepted log level values: UNVERIFIED.
- `t3 --version` output ends with `v<version>`, inferred from the regex the service installer uses to validate a runtime: `/\bv(\S+)\s*$/` (apps/server/src/cloud/bootService.ts:790). Full text UNVERIFIED.

### 1.2 Server-running commands

| Command | Handler | Refuses if a server is running | Startup presentation | Citation |
| --- | --- | --- | --- | --- |
| `t3 [cwd]` | runDefaultServerCommand | yes (web mode only) | browser | apps/server/src/cli/server.ts:29-53 |
| `t3 start` | runServerCommand | yes (web mode only) | browser | apps/server/src/cli/server.ts:55-58 |
| `t3 serve` | runServerCommand | no | headless, forceAutoBootstrapProjectFromCwd=false | apps/server/src/cli/server.ts:60-70 |

`t3 <word>` where the word is not an existing directory and not an explicit path fails with "Unknown command" (apps/server/src/cli/server.ts:30-50). The running-server check: `options.rejectRunningServer && mode === "web"`, reads server-runtime.json, fails if `pid > 0 && isProcessAlive(pid)` with the message "A T3 Code server is already running for <baseDir> (pid <pid>, <origin>). Connect to that server, stop it before starting another, or use a different --base-dir." (apps/server/src/cli/config.ts:333-342).

### 1.3 Shared server flags (root, start, serve)

All defined in apps/server/src/cli/config.ts:29-85 and grouped at apps/server/src/cli/config.ts:218-236. Env vars at apps/server/src/cli/config.ts:96-167. Resolution at apps/server/src/cli/config.ts:253-483.

| Flag | Type | Default | Env var | Bootstrap envelope key | Citation |
| --- | --- | --- | --- | --- | --- |
| `--mode` | literal `web` or `desktop` | `web` | `T3CODE_MODE` | `mode` | cli/config.ts:29-32, 126-129, 288-295; config.ts:25 |
| `--port` | int 1..65535 | web: findAvailablePort(3773); desktop: 3773 | `T3CODE_PORT` | `port` | cli/config.ts:33-37, 130, 297-312; packages/contracts/src/baseSchemas.ts:31 |
| `--host` | string | web: unset (server then binds 127.0.0.1); desktop: `127.0.0.1` | `T3CODE_HOST` | `host` | cli/config.ts:38-41, 131, 401-408; apps/server/src/server.ts:252 |
| `--base-dir` | string path | `~/.t3` | `T3CODE_HOME` | `t3Home` | cli/config.ts:42-47, 132, 319-327; os-jank.ts:105-111 |
| `cwd` (positional) | string, optional | process.cwd() | none | none | cli/config.ts:223-228, 328-329 |
| `--dev-url` | URL | none | `VITE_DEV_SERVER_URL` | none | cli/config.ts:48-52, 133, 313-316 |
| `--no-browser` | boolean | serve: forced true; web: false; desktop: true | `T3CODE_NO_BROWSER` | `noBrowser` | cli/config.ts:53-56, 143-146, 352-360 |
| `--bootstrap-fd` | int | none | `T3CODE_BOOTSTRAP_FD` | n/a | cli/config.ts:57-61, 147-150, 281-286 |
| `--auto-bootstrap-project-from-cwd` | boolean | web: true; serve: forced false; desktop: false | `T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD` | none | cli/config.ts:62-67, 151-154, 368-376 |
| `--log-websocket-events` (alias `--log-ws-events`) | boolean | true only if a dev URL is set | `T3CODE_LOG_WS_EVENTS` | none | cli/config.ts:68-74, 155-158, 377-383 |
| `--tailscale-serve` | boolean | false | `T3CODE_TAILSCALE_SERVE` | `tailscaleServeEnabled` | cli/config.ts:75-80, 159-162, 384-391 |
| `--tailscale-serve-port` | int 1..65535 | 443 | `T3CODE_TAILSCALE_SERVE_PORT` | `tailscaleServePort` | cli/config.ts:81-85, 163-166, 392-399 |

Precedence: flag, then env var, then bootstrap envelope, then default (`resolveOptionPrecedence` is `Option.firstSomeOf`, apps/server/src/cli/config.ts:238-240). Exceptions: `t3 serve` puts its forced `noBrowser=true` and `autoBootstrapProjectFromCwd=false` ahead of the flags (apps/server/src/cli/config.ts:352-360, 368-376). Base dir: flag or `T3CODE_HOME` counts as "explicit" (keeps `userdata` even with a dev URL), the envelope `t3Home` does not (apps/server/src/cli/config.ts:319-332). A whitespace-only base dir is ignored (apps/server/src/cli/config.ts:322).

Env-only settings (apps/server/src/cli/config.ts:87-142): `T3CODE_LOG_LEVEL` (default Info), `T3CODE_TRACE_MIN_LEVEL` (Info), `T3CODE_TRACE_TIMING_ENABLED` (true), `T3CODE_TRACE_FILE`, `T3CODE_TRACE_MAX_BYTES` (10 MiB), `T3CODE_TRACE_MAX_FILES` (10), `T3CODE_TRACE_BATCH_WINDOW_MS` (1000), `T3CODE_OTLP_TRACES_URL`, `T3CODE_OTLP_METRICS_URL`, `T3CODE_OTLP_LOGS_URL`, `T3CODE_OTLP_EXPORT_INTERVAL_MS` (10000), `T3CODE_OTLP_HEADERS`, `T3CODE_OTLP_PROTOCOL` (http/json), `T3CODE_DEV_ALLOWED_ORIGINS` (comma list).

Specific env vars asked about:

- `T3CODE_HOME`: base dir (apps/server/src/cli/config.ts:132). Also honored by the desktop (apps/desktop/src/app/DesktopConfig.ts:40), the installer (scripts/install.sh:11, 22) and required by the service launcher (apps/server/src/serviceLauncher.ts:629-633).
- `T3CODE_PORT`, `T3CODE_HOST`, `T3CODE_MODE`, `T3CODE_NO_BROWSER`: see table. The desktop also reads `T3CODE_PORT` for its own backend port (apps/desktop/src/app/DesktopConfig.ts:44; apps/desktop/src/app/DesktopApp.ts:78-83) and strips these vars from the backend child env (apps/desktop/src/backend/DesktopBackendConfiguration.ts:86-97, 141-142).
- `T3CODE_DEV_AUTH_TOKEN`: only read when mode is web and a dev URL is set; must be empty or at least 32 characters (apps/server/src/cli/config.ts:169-187, 317-318). It seeds a reusable administrative session (apps/server/src/auth/ReusableDevAuth.ts:13-32; apps/server/src/auth/SessionStore.ts:511-530). "Desktop and non-development servers ignore it" (docs/internals/environment-auth.md:86-88).
- `T3CODE_AUTH_TOKEN`: does not exist anywhere in the repo (repo-wide grep found no reference). No `T3CODE_DESKTOP_BOOTSTRAP*` env var exists either.
- `T3CODE_BOOTSTRAP_FD`: env equivalent of `--bootstrap-fd` (apps/server/src/cli/config.ts:147-150).
- `T3CODE_CLI_PATH`: absolute path of a launcher the server names in commands it asks a person to run; set by the desktop to its shim (apps/desktop/src/backend/DesktopBackendConfiguration.ts:600-601; read at apps/server/src/cli/invocation.ts:156-171).
- `T3_SERVICE_LAUNCHER_CONTEXT`: launcher-to-child context, never set it yourself (apps/server/src/cloud/serviceProtocol.ts:6; apps/server/src/cloud/serviceLauncherClient.ts:114-136).
- `T3_BOOT_SERVICE_UNIT`: written into the unit or plist (apps/server/src/cloud/bootService.ts:45, 109, 169-170); no reader found in TS source.
- `T3CODE_RELEASE_BASE_URL`: release mirror (packages/shared/src/cliRelease.ts:11; scripts/install.sh:13).

No auth or policy flags exist on `t3`/`start`/`serve`. The only flag containing "token" is `--token-only` on `t3 auth session issue` (apps/server/src/cli/auth.ts:80-83). Policy is derived from mode and host only (section 4.1).

### 1.4 Home directory and layout

`resolveBaseDir(raw)`: empty or missing gives `join(os.homedir(), ".t3")`; otherwise `path.resolve(expandHomePath(raw.trim()))`, where `~` and `~/` are expanded (apps/server/src/os-jank.ts:94-111). `deriveServerPaths` (apps/server/src/config.ts:133-168) and other writers give this layout:

```
<home>/                                  default ~/.t3
  userdata/                              stateDir (dev/ if dev URL and base dir not explicit), config.ts:139-142
    statev2.sqlite (+ -wal, -shm)        config.ts:143; WAL + busy_timeout 5000, persistence/Sqlite.ts:15-27
    keybindings.json                     config.ts:151
    settings.json                        config.ts:152
    themes/                              config.ts:153
    attachments/                         config.ts:144
    browser-artifacts/                   config.ts:157
    logs/                                config.ts:145
      server.trace.ndjson                config.ts:159
      provider/events.log                config.ts:146, 161
      terminals/                         config.ts:162
      boot-service.log                   background service stdout+stderr, cloud/bootService.ts:47, 604
      server-child.log                   desktop backend output, apps/desktop/src/app/DesktopObservability.ts:443-446
    anonymous-id                         config.ts:163
    environment-id                       UUIDv4 + "\n", config.ts:164; environment/ServerEnvironment.ts:129, 161
    server-runtime.json                  config.ts:165
    secrets/<name>.bin                   config.ts:166; dir chmod 0700, files 0600, auth/ServerSecretStore.ts:161-172, 227-248
                                         (bearer signing key name "server-signing-key", auth/SessionStore.ts:431, 498)
    desktop-settings.json                desktop only, apps/desktop/src/app/DesktopEnvironment.ts:209
    client-settings.json                 apps/desktop/src/app/DesktopEnvironment.ts:210
    saved-environments.json              apps/desktop/src/app/DesktopEnvironment.ts:211
  caches/                                config.ts:147
  worktrees/                             config.ts:155
  runtime/
    service-state.json                   cloud/serviceProtocol.ts:7; cloud/bootService.ts:605
    versions/<version>/t3                cloud/pinnedRuntime.ts:23-33, 59-71
    versions/<version>/.install-complete cloud/pinnedRuntime.ts:69
    db-backup/<updateId>/                serviceLauncher.ts:69-73
    .service-stopping                    cloud/serviceProtocol.ts:11
    .restart-pending                     cloud/serviceProtocol.ts:16
    desktop-update-restart               packages/contracts/src/desktopBootstrap.ts:36-40
  bin/t3                                 desktop CLI shim, apps/desktop/src/app/DesktopCliShim.ts:128-134
  ssh-launch/<stateKey>/                 only on SSH remotes, packages/ssh/src/tunnel.ts:544-553
```

(Paths without a prefix are under apps/server/src/.) Secret file contents were not read.

### 1.5 Port selection algorithms

- Server, web mode, no port given: `findAvailablePort(3773)` (apps/server/src/cli/config.ts:308-309). It uses 3773 only if there is no listener on 127.0.0.1 or ::1 (250 ms connect probe) and it can bind both; otherwise it does `listen(0, "127.0.0.1")`, reads the OS port and releases it (packages/shared/src/Net.ts:73-105, 107-152, 158-201). No sequential scan, and there is a small race between probe and bind.
- Server, desktop mode, no port given: 3773 without any check (apps/server/src/cli/config.ts:305-307).
- `--port 0` is rejected by PortSchema (min 1) (packages/contracts/src/baseSchemas.ts:31).
- Desktop app: `T3CODE_PORT` if set, else sequential scan 3773..65535 requiring `canListenOnHost` on `127.0.0.1`, `0.0.0.0` and `::` (apps/desktop/src/app/DesktopApp.ts:38-40, 75-109). In desktop development `T3CODE_PORT` is required (apps/desktop/src/app/DesktopApp.ts:204-206).
- SSH remote: preferred = saved port file or 3773, try 200 consecutive ports on 127.0.0.1 (packages/ssh/src/tunnel.ts:49-50, 252-283; apps/server/src/cli/sshHelper.ts:31-51).
- Dev runner: server 13773, web 5733 base ports plus offsets (scripts/dev-runner.ts:27-28).
- Server bind host when `--host` is unset: `127.0.0.1` (apps/server/src/server.ts:248-264).

### 1.6 `t3 pair`

Flags (apps/server/src/cli/pair.ts:453-486):

| Flag | Type | Default |
| --- | --- | --- |
| `--base-dir` | string | discovery order below |
| `--scope` | repeatable literal; replaces the default set | AuthStandardClientScopes (apps/server/src/cli/authScopes.ts:4-11) |
| `--ttl` | duration (`5m`, `1h`, `30d`, `2w`, `15 minutes`) | 5 minutes (apps/server/src/auth/PairingGrantStore.ts:254) |
| `--label` | string | `t3 pair` (apps/server/src/cli/pair.ts:440) |
| `--tailscale` | boolean | false |
| `--tailscale-serve-port` | int | 443 |

There is no `--base-url` and no `--json` on `t3 pair`. Duration syntax: apps/server/src/cli/config.ts:507-568.

Discovery (apps/server/src/cli/pair.ts:239-290): bases are the explicit base dir, otherwise the linked git worktree's own `.t3` (if cwd is inside one) followed by `T3CODE_HOME` or `~/.t3`. For each base it checks `userdata/server-runtime.json` then `dev/server-runtime.json`, skips dead pids, then probes `GET <origin>/.well-known/t3/environment` with a 2.5 s timeout (apps/server/src/cli/pair.ts:58-59, 205-230). 502, 503 and 504 count as unreachable; other non-descriptor responses mean "not a T3 server".

Minting: it builds a ServerConfig pointing at the discovered state dir and calls `EnvironmentAuth.createPairingLink` in-process, so it writes straight into that SQLite database and never calls the server over HTTP (apps/server/src/cli/pair.ts:292-349, 429-451).

Pairing base URL without `--tailscale`: the recorded `devUrl`, else `resolveHeadlessConnectionString(state.host, state.port)` (apps/server/src/cli/pair.ts:133-135), which is `http://localhost:<port>` when host is unset (apps/server/src/startupAccess.ts:45-51, 71-78).

Output, human only (apps/server/src/cli/pair.ts:175-193, 509-519):

```
Pairing with <descriptor.label> (<state.origin>).

<QR code>

Pairing URL: http://localhost:3773/pair#token=<TOKEN>
Token: <TOKEN>
Expires: <ISO-8601>

Note: This URL is only reachable from this machine. Re-run with --tailscale, or restart the server with a reachable --host.
```

Default log level is Warn unless `--log-level` is given (apps/server/src/cli/pair.ts:492-495). When nothing is found it fails with "No running T3 Code server found." plus the checked paths (apps/server/src/cli/pair.ts:71-84).

### 1.7 `t3 auth`

All `t3 auth` subcommands accept `--base-dir` and `--dev-url` (apps/server/src/cli/config.ts:209-212). They resolve config like a server (`resolveCliAuthConfig`, apps/server/src/cli/config.ts:485-505), open the SQLite database in-process (apps/server/src/cli/auth.ts:30-52; apps/server/src/auth/EnvironmentAuth.ts:1310-1315) and never contact a running server. SQLite runs WAL with `busy_timeout = 5000` because "CLI and server write from separate processes", and migrations run when the DB is opened (apps/server/src/persistence/Sqlite.ts:15-27).

`t3 auth pairing create` (apps/server/src/cli/auth.ts:85-116): flags `--scope` (repeatable, default AuthStandardClientScopes), `--ttl`, `--label`, `--base-url`, `--json`. Subject is `one-time-token`. With `--json` logs are limited to Error (apps/server/src/cli/auth.ts:111-113). JSON output, 2-space indented, then newline (apps/server/src/cliAuthFormat.ts:44-57):

```json
{
  "id": "<uuid>",
  "credential": "<12-char token>",
  "label": "<only if set>",
  "scopes": ["orchestration:read", "..."],
  "expiresAt": "<ISO-8601 UTC>",
  "pairUrl": "<only with --base-url>"
}
```

`pairUrl` is `new URL("/pair", baseUrl)` with `?token` removed and fragment `token=<urlencoded>` (apps/server/src/cliAuthFormat.ts:34-42); any path on the base URL is replaced. Human output: `Issued client pairing token <id>.`, `Token: <credential>`, optional `Pair URL: <url>`, `Expires at: <expiresAt>` (apps/server/src/cliAuthFormat.ts:59-66; the human `Expires at` value is a template string of a DateTime object, format UNVERIFIED; use `--json`).

`t3 auth pairing list [--json]` (apps/server/src/cli/auth.ts:118-138): hides the internal `administrative-bootstrap` subject; JSON array of `{id, label?, scopes, createdAt, expiresAt}`, no secrets (apps/server/src/cliAuthFormat.ts:69-105).

`t3 auth pairing revoke <id>` (apps/server/src/cli/auth.ts:140-157): prints `Revoked pairing credential <id>.` or `No active pairing credential found for <id>.`

`t3 auth session issue` (apps/server/src/cli/auth.ts:164-197): flags `--scope` (repeatable, default AuthAdministrativeScopes), `--ttl` (default 30 days, apps/server/src/auth/SessionStore.ts:432), `--label`, `--subject` (default `cli-issued-session`, apps/server/src/auth/EnvironmentAuth.ts:47), `--token-only`, `--json`. Method `bearer-access-token`, client `{label?, deviceType: "bot"}` (apps/server/src/auth/EnvironmentAuth.ts:1029-1056). `--token-only` prints only `<token>` plus newline (apps/server/src/cliAuthFormat.ts:114-116). `--json` (apps/server/src/cliAuthFormat.ts:118-132):

```json
{
  "sessionId": "<uuid>",
  "token": "<base64url claims>.<base64url HMAC>",
  "method": "bearer-access-token",
  "scopes": ["..."],
  "subject": "cli-issued-session",
  "client": { "label": "...", "deviceType": "bot" },
  "expiresAt": "<ISO-8601 UTC>"
}
```

`t3 auth session list [--json]` (apps/server/src/cli/auth.ts:199-217; apps/server/src/cliAuthFormat.ts:146-192) and `t3 auth session revoke <session-id>` (apps/server/src/cli/auth.ts:219-239).

Scopes (packages/contracts/src/auth.ts:82-128, 205-225):

- Standard client scopes: `orchestration:read`, `orchestration:operate`, `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `diagnostics:read`, `terminal:read`, `terminal:operate`, `source-control:write`, `filesystem:read`, `filesystem:write`, `relay:read`.
- Administrative scopes: standard plus `access:read`, `access:write`, `relay:write`.
- `review:write` decodes but cannot be granted (packages/contracts/src/auth.ts:94-95, 123-125).

Token formats:

- Pairing token: 12 characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (apps/server/src/auth/PairingGrantStore.ts:273-306), stored in the DB, consumed atomically once (apps/server/src/auth/PairingGrantStore.ts:559-586), default TTL 5 minutes (apps/server/src/auth/PairingGrantStore.ts:254, 407-410).
- Bearer session token: `<base64url(JSON claims)>.<HMAC-SHA256 base64url>` signed with the `server-signing-key` secret (apps/server/src/auth/SessionStore.ts:431-446, 659-698, 756). Verification also requires a non-revoked DB row (apps/server/src/auth/SessionStore.ts:804-849), so a token cannot be minted from the key alone.

### 1.8 `t3 service`

Subcommands `install`, `restart`, `uninstall`, `status`, plus hidden deprecated `update` (apps/server/src/cli/service.ts:290-299). All take `--base-dir`.

- `install [--allow-downgrade]`: prints `Installed T3 Code service with t3@<v>.` or `Updated ...` then `Logs: <path>`, or `T3 Code service is already installed with t3@<v>.` (apps/server/src/cli/service.ts:113-140).
- `restart`: restarts only if the installed unit's `T3CODE_HOME` equals this base dir (apps/server/src/cli/service.ts:167-186; apps/server/src/cloud/bootService.ts:904-922).
- `uninstall` (apps/server/src/cli/service.ts:188-202; apps/server/src/cloud/bootService.ts:930-944).
- `status`: human text only, no `--json` (apps/server/src/cli/service.ts:66-102, 204-215).
- Supported only on Linux with systemd and macOS with launchd (apps/server/src/cloud/bootService.ts:385-416).

### 1.9 `t3 connect` (T3 Connect cloud relay)

Present only in builds with public cloud config (apps/server/src/binCli.ts:57, 88). Commands (apps/server/src/cli/connect.ts:487-712): `t3 connect [--base-dir] [--headless]`, `login [--headless]`, `link [--headless] [--publish-only]`, `publish [--disable]`, `status [--json]`, `unlink`, `logout`. `--headless` uses the OAuth device flow and is implied when `SSH_CONNECTION` or `SSH_TTY` is set (apps/server/src/cli/connect.ts:57-72). `status --json` prints `{desired, authenticated, linked, cloudUserId, relayUrl, publishAgentActivity, relayClient}` (apps/server/src/cli/connect.ts:139-147, 174-177). Live unlink reads server-runtime.json, issues a temporary bearer session with scope `relay:write` directly in the DB, calls the server at `runtimeState.origin` with `Authorization: Bearer`, then revokes it (apps/server/src/cli/connect.ts:260-302).

### 1.10 Other commands

- `t3 project add|remove|rename` (apps/server/src/cli/project.ts:445-575): when server-runtime.json exists it issues a temporary administrative bearer (label `t3 project cli`) in the DB, calls the live server over HTTP and revokes it afterwards; if the live call fails it deletes server-runtime.json and runs offline (apps/server/src/cli/project.ts:213-224, 346-376).
- `t3 app [path]` talks to the desktop app, not the server, over a Unix socket `<os.tmpdir()>/t3code-<uid>/<hex of first 12 bytes of sha256(stateDir)>.sock` (packages/shared/src/desktopAppControl.ts:19-41; apps/server/src/cli/app.ts:205-214).
- `t3 update [version] [--channel] [--allow-downgrade] [--yes]` (apps/server/src/cli/update.ts:223-253); it tells foreground and service servers apart (apps/server/src/cli/update.ts:287-329).
- `t3 uninstall [--yes]`, `t3 browser setup`, `t3 theme set|clear|show`, `t3 trace summary`, `t3 triage`.
- Hidden: `__service-launcher` (apps/server/src/cli/serviceLauncher.ts:16-27); `__service-preflight --database-path --launcher-protocol` prints JSON `{status:"ready", version, launcherProtocol}` or `{status:"blocked", version, reason}` (apps/server/src/cli/servicePreflight.ts:7-17; apps/server/src/cloud/servicePreflight.ts:4-33); `__ssh-helper pick-port|wait-ready|runtime-port` (apps/server/src/cli/sshHelper.ts:31-126); `__claude-history`; `acp-mcp-bridge`; `acp-mcp-call`.

---

## 2. server-runtime.json

Path: `<stateDir>/server-runtime.json`, default `~/.t3/userdata/server-runtime.json` (apps/server/src/config.ts:165).

Schema (apps/server/src/serverRuntimeState.ts:11-27):

```ts
export const PersistedServerRuntimeState = Schema.Struct({
  version: Schema.Literal(1),
  pid: Schema.Int,
  host: Schema.optional(Schema.String),
  port: Schema.Int,
  origin: Schema.String,
  // Present when the server fronts a dev web server (VITE_DEV_SERVER_URL).
  devUrl: Schema.optional(Schema.String),
  startedAt: Schema.String,
  serviceManaged: Schema.optional(Schema.Boolean),
});
```

Field semantics (apps/server/src/serverRuntimeState.ts:47-70; apps/server/src/server.ts:740-751):

- `pid`: `process.pid` of the server process.
- `host`: only present when a host was configured (flag, env or envelope; the desktop always sets one).
- `port`: the actually bound port (taken from the HTTP server address).
- `origin`: `http://<host>:<port>` if host is set and not a wildcard (IPv6 bracketed), else `http://127.0.0.1:<port>`.
- `devUrl`: dev web origin when fronting a dev server.
- `startedAt`: `DateTime.formatIso(now)` (exact format UNVERIFIED, expected ISO-8601 UTC).
- `serviceManaged: true`: only when launched by the boot-service launcher with a valid `T3_SERVICE_LAUNCHER_CONTEXT` and a connected IPC channel (apps/server/src/cloud/serviceLauncherClient.ts:114-136).
- There is no version, environment id or auth information in the file. Use the well-known descriptor for those.

Encoding: one line of `JSON.stringify(state)` plus `\n` (apps/server/src/serverRuntimeState.ts:76-79), written via sibling temp dir and rename (packages/shared/src/atomicWrite.ts:11-38).

Examples built from the code above:

- Background service: `{"version":1,"pid":12345,"port":3773,"origin":"http://127.0.0.1:3773","startedAt":"...","serviceManaged":true}`
- Desktop local-only: `{"version":1,"pid":12346,"host":"127.0.0.1","port":3774,"origin":"http://127.0.0.1:3774","startedAt":"..."}`
- Desktop network-accessible: `host` is `0.0.0.0`, `origin` is still `http://127.0.0.1:<port>`.

When written: in every server run (web, desktop, service), after the activation gate, the same moment the server starts accepting commands (apps/server/src/server.ts:735-760; apps/server/src/serverRuntimeStartup.ts:637-639; apps/server/src/serverActivation.ts:12-32). Write failures are only logged.

When removed: the layer finalizer deletes the path on graceful shutdown, unconditionally, even if another process rewrote it (apps/server/src/server.ts:761-766; apps/server/src/serverRuntimeState.ts:90-113). Not removed on crash or SIGKILL, so stale files are normal. `t3 project` also deletes it after a failed live call (apps/server/src/cli/project.ts:373).

Liveness: `isProcessAlive` uses `process.kill(pid, 0)`; EPERM counts as alive (apps/server/src/serverRuntimeState.ts:115-128). Docs advise confirming with `ps -p <pid> -o command=` before signalling (docs/operations/observability.md:660-669).

Readers:

| Reader | What it does | Citation |
| --- | --- | --- |
| `t3`, `t3 start` (web) | refuse if pid alive | apps/server/src/cli/config.ts:333-342 |
| `t3 pair` | pid alive + well-known probe, then mint into that DB | apps/server/src/cli/pair.ts:239-290 |
| `t3 project` | live mode via origin with temp bearer | apps/server/src/cli/project.ts:346-376 |
| `t3 connect unlink/logout` | live unlink via origin | apps/server/src/cli/connect.ts:279-302 |
| `t3 update` | finds foreground servers; ignores serviceManaged, and on macOS treats a parent command containing `__service-launcher` as the service | apps/server/src/cli/update.ts:287-329 |
| `t3 triage` | describes running or stale | apps/server/src/cli/triage.ts:80-94 |
| SSH launch script | `__ssh-helper runtime-port` prints `<pid> <port>` for reuse | apps/server/src/cli/sshHelper.ts:90-121; packages/ssh/src/tunnel.ts:604-629 |
| scripts/migrate-dev-db.ts | guards a dev DB in use | scripts/migrate-dev-db.ts:176-201 |
| Desktop app | does not read it (no reference in apps/desktop/src) | grep |

Caveat: the desktop backend, the background service and any `t3 serve` on the same home all write the same file. Last writer wins, and any of them shutting down deletes it.

---

## 3. Background service

### 3.1 macOS LaunchAgent

- Label: `com.t3tools.t3code.service` (apps/server/src/cloud/bootService.ts:41-43). The comment says the `.service` suffix keeps it distinct from the desktop bundle id `com.t3tools.t3code`.
- Plist path: `~/Library/LaunchAgents/com.t3tools.t3code.service.plist` (apps/server/src/cloud/bootService.ts:44, 303-314).
- Rendered plist (apps/server/src/cloud/bootService.ts:136-192), placeholders in braces:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.t3tools.t3code.service</string>
  <key>ProgramArguments</key>
  <array>
    <string>{base}/runtime/versions/{cliVersion}/t3</string>
    <string>__service-launcher</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>{installer PATH dirs}:{dir of installing executable}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>T3CODE_HOME</key>
    <string>{base}</string>
    <key>T3_BOOT_SERVICE_UNIT</key>
    <string>com.t3tools.t3code.service.plist</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>{HOME}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>ExitTimeOut</key>
  <integer>90</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>{base}/userdata/logs/boot-service.log</string>
  <key>StandardErrorPath</key>
  <string>{base}/userdata/logs/boot-service.log</string>
</dict>
</plist>
```

- ProgramArguments come from the plan `[runtimePaths.entryPath, "__service-launcher"]` (apps/server/src/cloud/bootService.ts:627-634; apps/server/src/cloud/pinnedRuntime.ts:59-71). PATH composition: apps/server/src/cloud/bootService.ts:575-594. Log path: apps/server/src/cloud/bootService.ts:47, 604, with logsDir from the CLI config (apps/server/src/cli/service.ts:16-25; apps/server/src/config.ts:145).
- To learn the service's home, parse `T3CODE_HOME` from the plist like `bootServiceBaseDirOf` does (apps/server/src/cloud/bootService.ts:66-81).
- launchctl steps (apps/server/src/cloud/bootService.ts:315-381): stop `launchctl bootout --wait gui/<uid>/com.t3tools.t3code.service` (optional, 120 s timeout); activate `launchctl enable gui/<uid>/com.t3tools.t3code.service` (optional) then `launchctl bootstrap gui/<uid> <plist>`; uninstall is bootout then plist removal; no `launchctl disable`.
- The agent starts at login and stops at logout (docs/user/background-service.md:49-52).

### 3.2 Linux systemd user unit

`~/.config/systemd/user/t3code.service` (apps/server/src/cloud/bootService.ts:237-247), rendered at apps/server/src/cloud/bootService.ts:97-128: `Description=T3 Code server`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `Type=simple`, `WorkingDirectory=%h`, `Environment=T3CODE_HOME=<base>`, `Environment=T3_BOOT_SERVICE_UNIT=t3code.service`, `ExecStart=<runtime t3> __service-launcher`, `KillMode=mixed`, `OOMPolicy=continue`, `Restart=always`, `RestartSec=5`, `StandardOutput=append:<log>`, `StandardError=append:<log>`, `WantedBy=default.target`. Steps: `systemctl --user daemon-reload`, `enable`, `restart` (apps/server/src/cloud/bootService.ts:248-300). Lingering via `loginctl enable-linger --no-ask-password` when needed (apps/server/src/cloud/bootService.ts:731-747).

### 3.3 Launcher, child command and protocol

- `t3 __service-launcher` runs `serviceLauncher.main()` outside runMain so it owns SIGTERM (apps/server/src/cli/serviceLauncher.ts:6-27). It requires `T3CODE_HOME` and reads `<home>/runtime/service-state.json` (apps/server/src/serviceLauncher.ts:629-637).
- `service-state.json` (apps/server/src/cloud/serviceProtocol.ts:28-32), written by install as pretty JSON `{"protocol": 3, "activeVersion": "<exact semver>"}` (apps/server/src/cloud/bootService.ts:863-874). The launcher adds `update` records: pending `{id, fromVersion, targetVersion, dbPath, status:"pending"}` or terminal `{id, fromVersion, targetVersion, status:"committed"|"rolled-back"|"failed", reason?}` (apps/server/src/cloud/serviceProtocol.ts:18-26, 79-110). `SERVICE_LAUNCHER_PROTOCOL = 3` (apps/server/src/cloud/serviceProtocol.ts:5).
- Child: `<home>/runtime/versions/<activeVersion>/t3 serve` and nothing else (apps/server/src/serviceLauncher.ts:49-63), env = launcher env plus `T3_SERVICE_LAUNCHER_CONTEXT={"protocol":3,"childVersion":"<v>","update":...}`, stdio `["inherit","inherit","inherit","ipc"]` (apps/server/src/serviceLauncher.ts:416-432).
- Effective service server: web mode, headless, bound to 127.0.0.1, port 3773 if free else ephemeral, base dir from the unit's `T3CODE_HOME`, cwd = HOME. Its startup pairing block (section 4.3) is written to `boot-service.log`.
- Launcher protocol: Node child_process IPC only. Child to parent `request-update {targetVersion, dbPath}` and `prepared {updateId}`; parent to child `update-accepted {updateId}`, `update-rejected {reason}`, `committed {updateId}` (apps/server/src/cloud/serviceProtocol.ts:41-64; apps/server/src/cloud/serviceLauncherClient.ts:80-112, 145-251). It is not a socket; third-party clients cannot use it. Setting `T3_SERVICE_LAUNCHER_CONTEXT` wrongly makes startup fail (decode-context, version-mismatch or ipc-unavailable, apps/server/src/cloud/serviceLauncherClient.ts:122-132).
- Timers: handoff 2000 ms, prepared timeout 120000 ms, terminate grace 5000 ms (apps/server/src/serviceLauncher.ts:33-35). An explicit stop writes `<home>/runtime/.service-stopping` (apps/server/src/serviceLauncher.ts:331-342).
- Recognizing a service server: `serviceManaged:true` in server-runtime.json, or (older servers) parent process command containing `__service-launcher` (apps/server/src/cli/update.ts:309-326). The descriptor advertises `serverSelfUpdate: "boot-service"` for launcher-managed servers and `"desktop-managed"` for desktop mode (apps/server/src/cloud/selfUpdate.ts:190).

---

## 4. Startup access, auth policy, pairing URLs, auth endpoints

### 4.1 Auth policy selection

From apps/server/src/auth/EnvironmentAuthPolicy.ts:21-52:

- `isRemoteReachableHost(host)`: `0.0.0.0`, `::`, `[::]` true; unset or empty false; `localhost`, `127.*`, `::1`, `[::1]` false; anything else (LAN IP, tailnet IP, hostname) true (apps/server/src/auth/utils.ts:67-81).
- Mode desktop: `remote-reachable` if reachable host, else `desktop-managed-local`. Mode web: `remote-reachable` or `loopback-browser`.
- bootstrapMethods: `desktop-managed-local` gives `["desktop-bootstrap"]`; desktop + `remote-reachable` gives `["desktop-bootstrap","one-time-token"]`; otherwise `["one-time-token"]`.
- sessionMethods always `["browser-session-cookie","bearer-access-token","dpop-access-token"]`, `serverUpdateScope: "environment:maintain"`.
- `unsafe-no-auth` is declared in contracts (packages/contracts/src/auth.ts:25-40) but no server code selects it and no flag or env enables it.
- The advertised bootstrapMethods are not enforced by the server: `bootstrapMethods` appears only in EnvironmentAuthPolicy.ts, and PairingGrantStore.consume accepts seeded desktop tokens and DB one-time tokens regardless of policy (apps/server/src/auth/PairingGrantStore.ts:455-623). This is code behavior, not a documented contract.
- Session cookie names (apps/server/src/auth/utils.ts:26-65): desktop `t3_session_<port>`; web, remote-reachable, non-dev `t3_session_<first 12 hex of sha256(environmentId)>` plus legacy `t3_session`; otherwise `t3_session_<port>_<first 12 hex of sha256(stateDir)>`.

### 4.2 What each startup mode does

- `t3` and `t3 start` (web, browser presentation): issue an administrative startup pairing credential, log "Authentication required. Open T3 Code using the pairing URL." with a `pairingUrl` annotation, and open the browser unless noBrowser (apps/server/src/serverRuntimeStartup.ts:316-345, 595-604). Target is `http://localhost:<port>`, or `http://<host>:<port>` for a specific non-wildcard host, or the dev URL, turned into `/pair#token=...` (apps/server/src/serverRuntimeStartup.ts:316-328; apps/server/src/auth/EnvironmentAuth.ts:1143-1153).
- `t3 serve` (headless): prints the block in 4.3 to stdout with `Console.log` (apps/server/src/serverRuntimeStartup.ts:588-594).
- Desktop mode: no token, no browser, no auth log line (apps/server/src/serverRuntimeStartup.ts:325-327, 598).
- These run in a parked fiber that starts after activation (apps/server/src/serverRuntimeStartup.ts:580-606; apps/server/src/serverActivation.ts:29-32).

### 4.3 Exact `t3 serve` stdout block

From apps/server/src/startupAccess.ts:122-131 (values illustrative):

```
T3 Code server is ready.
Connection string: http://localhost:3773
Token: ABCDEFGH2345
Pairing URL: http://localhost:3773/pair#token=ABCDEFGH2345

<QR code rows drawn with full block, upper half block and lower half block characters>

```

- Connection host: unset host gives `localhost`; wildcard gives the first non-internal IPv4, else IPv6, else `localhost`; otherwise the host itself (apps/server/src/startupAccess.ts:45-78). Port is the actually bound port (apps/server/src/startupAccess.ts:80-90, 137-140).
- Token: `issueStartupPairingCredential`, AuthAdministrativeScopes, subject `administrative-bootstrap`, purpose `startup`, TTL 5 minutes (24 hours when a dev URL is set), single use (apps/server/src/auth/EnvironmentAuth.ts:47-48, 1086-1113; apps/server/src/auth/PairingGrantStore.ts:254-272, 407-410). Hidden from `t3 auth pairing list` (apps/server/src/cli/auth.ts:128-130).
- QR: ECC MEDIUM, margin 2, two rows per text line (apps/server/src/startupAccess.ts:100-120).
- Server logs use `Logger.consolePretty` (apps/server/src/serverLogger.ts:38-46). Whether logs and Console.log go to stdout or stderr is UNVERIFIED, so parse by line prefix (`Token: `, `Pairing URL: `, `Connection string: `).

### 4.4 Pairing URL formats and builders

- `buildPairingUrl(connectionString, token)`: pathname `/pair`, delete `?token`, fragment `token=<URLSearchParams encoded>` (apps/server/src/startupAccess.ts:92-98). Same logic in `issueStartupPairingUrl` (apps/server/src/auth/EnvironmentAuth.ts:1143-1153) and `setPairingTokenOnUrl` (packages/shared/src/remote.ts:165-170).
- `t3 auth pairing create --base-url`: `new URL("/pair", baseUrl)` plus `#token=` (apps/server/src/cliAuthFormat.ts:34-42).
- Hosted app link: `https://app.t3.codes/pair?host=<backend url>&label=<label>#token=<token>` (apps/web/src/hostedPairing.ts:73-87; packages/shared/src/connectAuth.ts:15).
- Parsing accepts the fragment `#token=` first, then the query `?token=` (packages/shared/src/remote.ts:144-152); hosted links also carry `host` and `label` query params (packages/shared/src/remote.ts:172-186).
- The contracts comment mentions `/pair?token=...` (packages/contracts/src/auth.ts:53-54) but every builder uses the fragment.
- Canonical form: `http(s)://<host>:<port>/pair#token=<TOKEN>`.

### 4.5 HTTP auth endpoints

Defined in packages/contracts/src/environmentHttp.ts:449-529; handlers in apps/server/src/auth/http.ts:262-530.

| Method and path | Auth | Request | Response |
| --- | --- | --- | --- |
| GET /.well-known/t3/environment | none | none | ExecutionEnvironmentDescriptor `{environmentId, label, platform{os, arch, machine?}, serverVersion, orchestrationProtocolVersion?, capabilities}` (packages/contracts/src/environment.ts:47-54, 218-226; handler apps/server/src/http.ts:302-315) |
| GET /api/auth/session | optional | cookie or Authorization | AuthSessionState `{authenticated, auth: ServerAuthDescriptor, scopes?, permissions?, sessionMethod?, expiresAt?}`; unauthenticated callers still get the policy descriptor (packages/contracts/src/auth.ts:461-468; apps/server/src/auth/EnvironmentAuth.ts:770-789) |
| POST /api/auth/browser-session | none | JSON `{"credential":"<token>"}` | sets HttpOnly, SameSite=Lax, Path=/ cookie; JSON `{authenticated:true, scopes, permissions, sessionMethod, expiresAt}` (packages/contracts/src/auth.ts:263-273; apps/server/src/auth/http.ts:298-352) |
| POST /oauth/token | none (optional DPoP header) | form-urlencoded token exchange, below | `{access_token, issued_token_type, token_type:"Bearer" or "DPoP", expires_in, scope}` (packages/contracts/src/auth.ts:298-316; apps/server/src/auth/http.ts:353-414) |
| POST /api/auth/websocket-ticket | session | none | `{ticket, expiresAt}`, 5-minute ticket (apps/server/src/auth/SessionStore.ts:433; apps/server/src/auth/http.ts:415-428) |
| POST /api/auth/pairing-token | session with `access:write` and every delegated scope | JSON `{label?, scopes?}` | `{id, credential, label?, expiresAt}` (packages/contracts/src/auth.ts:325-330, 455-458; apps/server/src/auth/http.ts:429-453) |
| GET /api/auth/pairing-links | `access:read` | none | AuthPairingLink[] |
| POST /api/auth/pairing-links/revoke | `access:write` | `{id}` | `{revoked}` |
| GET /api/auth/clients | `access:read` | none | AuthClientSession[] |
| POST /api/auth/clients/revoke | `access:write` | `{sessionId}` | `{revoked}` |
| POST /api/auth/clients/revoke-others | `access:write` | none | `{revokedCount}` |

Token exchange body (packages/contracts/src/auth.ts:227-231, 298-307; client builder packages/client-runtime/src/authorization/remote.ts:115-140):

```
grant_type=urn:ietf:params:oauth:grant-type:token-exchange
subject_token=<pairing token or desktop bootstrap token>
subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap
requested_token_type=urn:ietf:params:oauth:token-type:access_token
scope=<optional, space separated>
client_label=<optional>
client_device_type=<optional: desktop, mobile, tablet, bot, unknown>
client_os=<optional>
```

- Scope: absent means the full grant; unparsable or empty gives 400 `invalid_scope`; no overlap with the grant gives `scope_not_granted` (apps/server/src/auth/http.ts:359-365; apps/server/src/auth/EnvironmentAuth.ts:899-907; packages/shared/src/oauthScope.ts:22-52).
- Bearer TTL 30 days; DPoP-bound tokens 1 hour (apps/server/src/auth/SessionStore.ts:432; apps/server/src/auth/EnvironmentAuth.ts:908-918).
- Exchanging a desktop-bootstrap grant revokes earlier bearer sessions for the same subject and method (apps/server/src/auth/EnvironmentAuth.ts:919-921; docs/internals/environment-auth.md:77-82).
- Credential responses carry `cache-control: no-store` and `pragma: no-cache` (apps/server/src/auth/http.ts:41-48).
- Client status mapping used by the web app: invalid request 400, auth invalid 401, scope required or forbidden 403, not found 404, internal 500 (apps/web/src/environments/primary/auth.ts:207-221).
- Request credential precedence: session cookie, `Authorization: Bearer`, `Authorization: DPoP`, legacy cookie (apps/server/src/auth/EnvironmentAuth.ts:650-676).

WebSocket: `GET /ws` requires query `orchestrationProtocol=2`, else HTTP 426 with code `orchestration_protocol_incompatible` (apps/server/src/ws.ts:3136-3151; packages/contracts/src/environment.ts:13-16; clients add it in packages/client-runtime/src/connection/compatibility.ts:40). Auth uses `wsTicket=<ticket>` and falls back to cookie, Bearer or DPoP headers on the upgrade (apps/server/src/auth/EnvironmentAuth.ts:1173-1194). Clients build `ws://host:port/ws?wsTicket=...` (packages/client-runtime/src/authorization/remote.ts:201-224). Some HTTP endpoints require header `x-t3-orchestration-protocol: 2` (packages/contracts/src/environmentHttp.ts:80-84). CORS uses the default wildcard origin outside dev (apps/server/src/http.ts:239-262).

Readiness gate: a global HTTP middleware holds every request until command readiness (apps/server/src/server.ts:661-667). A TCP accept therefore happens earlier than the first HTTP answer; a 2xx from the well-known route means the server is ready. (Global middleware semantics of effect HttpRouter: UNVERIFIED, inferred from this code and the desktop's use of the route.)

---

## 5. Desktop local server bootstrap

### 5.1 Whether the desktop starts a server

- Setting `localEnvironmentEnabled`, default true, parsed as `!== false` (apps/desktop/src/settings/DesktopAppSettings.ts:77-84, 235). When false the bootstrap skips port selection, exposure and every backend, and opens the window (apps/desktop/src/app/DesktopApp.ts:191-197; docs/internals/remote.md:92-102). The folder picker returns null (apps/desktop/src/ipc/methods/window.ts:196-199).
- Otherwise it always spawns its own primary backend (apps/desktop/src/app/DesktopApp.ts:199-263). It never reads server-runtime.json and never reuses the background service (no reference to either in apps/desktop/src).
- The Electron app is single-instance per profile through the Clerk SDK bridge lock (apps/desktop/src/app/DesktopClerk.ts:97-139). That does not prevent a desktop backend and a CLI or service server sharing a home.

### 5.2 Locations

- T3 home: `T3CODE_HOME` (trimmed) else `~/.t3` (apps/desktop/src/app/DesktopStatePaths.ts:13-21; apps/desktop/src/app/DesktopConfig.ts:40). State dir `<home>/userdata`, or `<home>/dev` in development without `T3CODE_HOME` (apps/desktop/src/app/DesktopStatePaths.ts:23-32). This is the same home the CLI and service use by default, so they share DB, secrets, environment-id and server-runtime.json.
- Electron userData on macOS: `~/Library/Application Support/t3code-v2` (dev `t3code-dev`) (apps/desktop/src/app/DesktopEnvironment.ts:159-166; apps/desktop/src/app/DesktopUserData.ts:34-60).
- CLI shim: `<home>/bin/t3`, rewritten on each packaged primary start (apps/desktop/src/app/DesktopCliShim.ts:128-187; apps/desktop/src/backend/DesktopBackendConfiguration.ts:913-927). Content: marker comment `# Written by T3 Code: runs the desktop app's bundled t3 CLI.`, `export T3CODE_CLI_PATH=...`, `export T3CODE_HOME="${T3CODE_HOME:-<home>}"`, `export ELECTRON_RUN_AS_NODE=1`, then `exec "<Electron executable>" "<serverRoot>/apps/server/dist/bin.mjs" "$@"` (apps/desktop/src/app/DesktopCliShim.ts:17, 82-96). An optional Settings action links it into `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` or `~/bin` on macOS (apps/desktop/src/app/DesktopCliCommand.ts:27-31).

### 5.3 Port and bind host

- Port: `T3CODE_PORT` or the scan from 3773 (section 1.5).
- Exposure (apps/desktop/src/backend/DesktopServerExposure.ts:104-137): `local-only` binds 127.0.0.1; `network-accessible` binds 0.0.0.0 and advertises the first usable LAN IPv4 (not 127.x, 169.254.x or Tailscale) or `T3CODE_DESKTOP_LAN_HOST`; it falls back to local-only when no address exists (apps/desktop/src/backend/DesktopServerExposure.ts:367-408). The desktop always talks to `http://127.0.0.1:<port>` (apps/desktop/src/backend/DesktopServerExposure.ts:110, 359).

### 5.4 Spawn of the primary backend

From apps/desktop/src/backend/DesktopBackendConfiguration.ts:547-612:

- Executable: `process.execPath` (the Electron binary) with `ELECTRON_RUN_AS_NODE=1`.
- Args: `[--require <dirname>/compileCache.cjs]` (packaged only) then `<serverRoot>/apps/server/dist/bin.mjs --bootstrap-fd 3` (apps/desktop/src/backend/DesktopBackendConfiguration.ts:589-594; apps/desktop/src/app/DesktopEnvironment.ts:218, 222). No subcommand, so the root `t3` handler runs (apps/server/src/binCli.ts:57-60). Exact macOS value of serverRoot (Electron appPath) UNVERIFIED.
- cwd: home directory when packaged (apps/desktop/src/app/DesktopEnvironment.ts:220).
- Env: process.env merged (extendEnv true), with `T3CODE_PORT`, `T3CODE_MODE`, `T3CODE_NO_BROWSER`, `T3CODE_HOST`, `T3CODE_DESKTOP_WS_URL`, `T3CODE_DESKTOP_LAN_ACCESS`, `T3CODE_DESKTOP_LAN_HOST`, `T3CODE_DESKTOP_HTTPS_ENDPOINTS`, `T3CODE_TAILSCALE_SERVE`, `T3CODE_TAILSCALE_SERVE_PORT` set to undefined, plus `ELECTRON_RUN_AS_NODE=1` and `T3CODE_CLI_PATH` (apps/desktop/src/backend/DesktopBackendConfiguration.ts:86-97, 141-142, 597-604). `T3CODE_HOME` is kept. (Whether undefined removes a var in effect ChildProcess: UNVERIFIED.)
- Extra fds: fd3 input = bootstrap JSON line; fd4 telemetry input; fd5 telemetry control output; fd6 desktop browser input; fd7 browser control output (apps/desktop/src/backend/DesktopBackendConfiguration.ts:572-575; apps/desktop/src/backend/DesktopBackendManager.ts:462-492). stdin ignored, stdout and stderr piped and logged to `<stateDir>/logs/server-child.log` (apps/desktop/src/backend/DesktopBackendManager.ts:493-503; apps/desktop/src/app/DesktopObservability.ts:443-446). Stop: SIGTERM, SIGKILL after 2 s (apps/desktop/src/backend/DesktopBackendManager.ts:68, 502-503).

### 5.5 Bootstrap envelope

Schema `DesktopBackendBootstrap` (packages/contracts/src/desktopBootstrap.ts:5-32):

```ts
mode: "desktop"                       // literal, required
noBrowser: boolean
port: int 1..65535
t3Home?: string
host: string
desktopBootstrapToken: string
desktopBootstrapSecret?: string
tailscaleServeEnabled: boolean
tailscaleServePort: int 1..65535
otlpTracesUrl?: string
otlpMetricsUrl?: string
otlpLogsUrl?: string
desktopTelemetryFd?: int >= 1
desktopTelemetryControlFd?: int >= 1
desktopBrowserFd?: int >= 1
desktopBrowserControlFd?: int >= 1
resourceMonitorPath?: non-empty string
```

- Values the desktop sends: `mode:"desktop"`, `noBrowser:true`, port, `t3Home` = home, `host` = bind host, `desktopBootstrapToken` = current window token, `desktopBootstrapSecret` = 64 hex chars, tailscale settings, fds 4 to 7, resourceMonitorPath, OTLP URLs (apps/desktop/src/backend/DesktopBackendConfiguration.ts:562-581).
- Delivery: encoded with `Schema.fromJsonString` plus one `\n` (apps/desktop/src/backend/DesktopBackendManager.ts:440, 449-462).
- Server read: exactly one line from `/dev/fd/<n>` on macOS or `/proc/self/fd/<n>` on Linux, decoded with the schema, giving up after 1000 ms and continuing without a bootstrap (apps/server/src/bootstrap.ts:74-146, 233-241). An unavailable fd (EBADF or ENOENT) means no bootstrap (apps/server/src/bootstrap.ts:148-167). A line that fails to decode is a fatal BootstrapEnvelopeDecodeError (apps/server/src/bootstrap.ts:120-134).
- WSL variant: `wsl.exe [-d <distro>] --exec env PATH=... <t3 | node bin.mjs> --bootstrap-fd 0 [--dev-url ...]`, envelope on stdin, host `0.0.0.0`, no `t3Home` (apps/desktop/src/backend/DesktopBackendConfiguration.ts:642-665, 758-777, 821-832). This proves stdin delivery works with the standalone `t3` executable.

### 5.6 The desktop bootstrap credential

- Secret: 32 random bytes as hex, generated once per desktop process and kept in memory (apps/desktop/src/backend/DesktopBackendConfiguration.ts:847-866). Not written to disk as far as the code shows.
- Token: `HMAC-SHA256(secret, "t3-desktop-bootstrap:" + floor(nowMs / 43200000))` as hex; window 12 hours; the server accepts the previous, current and next window (packages/shared/src/desktopBootstrapToken.ts:16-45).
- Server: with a secret, any valid window token is accepted as method `desktop-bootstrap` with AuthAdministrativeScopes (apps/server/src/auth/PairingGrantStore.ts:327-333, 455-467). Without a secret, `desktopBootstrapToken` is seeded in memory with unbounded uses for 24 hours (apps/server/src/auth/PairingGrantStore.ts:255-263, 335-351).
- Exchange: the desktop main process POSTs `/oauth/token` with the current window token, `client_label=T3 Code Desktop`, `client_device_type=desktop`, no scope (full administrative grant), retrying 502, 503, 504 and network errors every 500 ms for up to 15 s (apps/desktop/src/backend/DesktopLocalEnvironmentAuth.ts:19-37, 77-129). The bearer is handed to the renderer over IPC `getLocalEnvironmentBearerToken` (apps/desktop/src/ipc/methods/window.ts:175-183; apps/web/src/environments/primary/desktopAuth.ts:1-17; apps/web/src/connection/platform.ts:265-274) and used for the primary connection (packages/client-runtime/src/connection/resolver.ts:86-117).
- Cookie path also exists in the renderer: `POST /api/auth/browser-session` with a URL token or the primary `bootstrapToken` from `getLocalEnvironmentBootstraps()` (apps/web/src/environments/primary/auth.ts:170-179, 223-248, 312-337; apps/desktop/src/ipc/methods/window.ts:94-161). Which path the packaged desktop exercises at runtime besides the resolver is UNVERIFIED.
- Stale comments: apps/desktop/src/backend/DesktopBackendPool.ts:36-62 mention `/api/auth/bootstrap/bearer` and `/api/auth/ws-token`; those endpoints do not exist in the current API (packages/contracts/src/environmentHttp.ts:455-529).

### 5.7 Readiness

`GET <httpBaseUrl>/.well-known/t3/environment`, success on 2xx, 100 ms interval, 1 s per probe, 60 s per round, rounds repeated while the child is alive (apps/desktop/src/backend/DesktopBackendManager.ts:65-70, 378-399, 608-633; packages/shared/src/httpReadiness.ts:51-133).

### 5.8 Locks

No per-home server lock in the server or the desktop (repo grep for lock files found only unrelated git, ACP, WSL and device locks). Concurrency relies on SQLite WAL with `busy_timeout = 5000` (apps/server/src/persistence/Sqlite.ts:15-27), atomic file writes, and `link()` based environment-id creation so concurrent initializers agree (apps/server/src/environment/ServerEnvironment.ts:119-175). The only "already running" check is the web-mode preflight in `t3` and `t3 start` (apps/server/src/cli/config.ts:333-342). Docs tell users to connect to a running server instead of starting another, or use another `--base-dir` (docs/user/install.md:40-42).

---

## 6. SSH flow (packages/ssh)

- SSH command form: `ssh -o BatchMode=<yes|no> -o ConnectTimeout=10 [-p <port>] <user@host> <remote args>`, script on stdin (packages/ssh/src/command.ts:105-116, 201-226).
- Launch or reuse: remote args `sh -l -s -- <stateKey>`, stdin = REMOTE_LAUNCH_SCRIPT (packages/ssh/src/tunnel.ts:861-886). `stateKey` = first 16 hex chars of SHA-256 of `alias\0hostname\0username\0port` (packages/ssh/src/command.ts:71-84). Timeouts: 90 s for dev node scripts, 900 s for archive installs (packages/ssh/src/tunnel.ts:55-65).
- Runner `~/.t3/ssh-launch/<key>/run-t3.sh` installs the exact desktop version archive into `$HOME/.t3/runtime/versions/<v>` (downloads `<base>/v<v>/SHA256SUMS` and `t3-<v>-<darwin|linux>-<arm64|x64>.tar.gz`, verifies the checksum, runs `t3 --version`, writes `.install-complete`) under an mkdir lock, then `exec "$T3_RUNTIME_DIR/t3" "$@"` (packages/ssh/src/tunnel.ts:427-540). Dev mode runs `node <script>` instead (packages/ssh/src/tunnel.ts:430-440; apps/desktop/src/main.ts:107-127).
- Reuse: reads `$HOME/.t3/userdata/server-runtime.json` via `run-t3.sh __ssh-helper runtime-port <file>`, which prints `<pid> <port>` only if pid > 0 is alive and origin is `http:` on `127.0.0.1` or `localhost`; then waits up to 2 s for `GET http://127.0.0.1:<port>/` to return 2xx. If ready, that server is used as `external`, and a server this key had launched (`managed`) is killed (packages/ssh/src/tunnel.ts:546-547, 604-666; apps/server/src/cli/sshHelper.ts:53-121).
- Launch otherwise: pick a port (saved port or 3773, 200 tries), then
  `nohup env T3CODE_NO_BROWSER=1 "$RUNNER_FILE" serve --host 127.0.0.1 --port "$REMOTE_PORT" --base-dir "$DEFAULT_SERVER_HOME" >>"$LOG_FILE" 2>&1 < /dev/null &`
  with `DEFAULT_SERVER_HOME="$HOME/.t3"`, records pid, port and `managed`, waits up to 60 s for readiness (packages/ssh/src/tunnel.ts:692-719). Final stdout line: `{"remotePort":<n>,"serverKind":"managed"|"external"}` (packages/ssh/src/tunnel.ts:720; lenient JSON decode at 168-201).
- Credential: a second SSH call `sh -s` with REMOTE_PAIRING_SCRIPT running `"$RUNNER_FILE" auth pairing create --base-dir "$PAIRING_BASE_DIR" --json` where `PAIRING_BASE_DIR="$HOME/.t3"`; the client reads `credential` from the JSON (packages/ssh/src/tunnel.ts:723-734, 922-977). The desktop main process then POSTs `/oauth/token` through the tunnel (apps/desktop/src/ipc/methods/sshEnvironment.ts:171-186) and the renderer stores the bearer (apps/web/src/connection/platform.ts:184-225, 288-318). It does not use `t3 pair` and does not read secrets.
- Port forward: local port from `reserveLoopbackPort()` (listen(0) on 127.0.0.1); command `ssh <base args> -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none -o ControlPersist=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -n -N -L <local>:127.0.0.1:<remote> <host>`; `httpBaseUrl = http://127.0.0.1:<local>/`, `wsBaseUrl = ws://127.0.0.1:<local>/`; readiness `GET /` for up to 20 s (packages/ssh/src/tunnel.ts:51, 1095-1098, 1140-1161, 1259-1264, 1512-1514).
- Stop: REMOTE_STOP_SCRIPT kills only `managed` servers (packages/ssh/src/tunnel.ts:736-757). Docs: removing the connection stops a server T3 launched and leaves an already running one (docs/user/remote-access.md:157-177; docs/internals/remote.md:78-84).

---

## 7. Tailscale (packages/tailscale)

- Create mapping: `tailscale serve --bg --https=<servePort> http://<localHost>:<localPort>`, localHost default `127.0.0.1`, 10 s timeout. Remove: `tailscale serve --https=<servePort> off` (packages/tailscale/src/tailscale.ts:10-13, 341-363). Executable `tailscale` (`tailscale.exe` on Windows), spawned directly (packages/tailscale/src/tailscale.ts:15-18).
- Server with `--tailscale-serve`: after activation runs ensureTailscaleServe with the bound port, `servePort`, `localHost: "127.0.0.1"`; failures are only logged; the finalizer disables the mapping on shutdown (apps/server/src/server.ts:769-821).
- URL: MagicDNS name from `tailscale status --json`, `Self.DNSName` with the trailing dot removed, 1.5 s timeout (packages/tailscale/src/tailscale.ts:158-166, 217-273). Base URL `https://<name>/` for port 443, else `https://<name>:<port>/` (packages/tailscale/src/tailscale.ts:275-286). Tailnet IPv4 = 100.64.0.0/10 (packages/tailscale/src/tailscale.ts:176-192).
- `t3 pair --tailscale`: probe the HTTPS URL; same environmentId means reuse; a different T3 environment or a non-T3 responder is an error; otherwise create the mapping to the server's local port (or the dev web port; a server bound to a specific non-loopback interface is targeted directly), re-probe 5 times 1 s apart, and add notes, including that the mapping persists (apps/server/src/cli/pair.ts:58-63, 154-173, 363-427).
- Advertisement: the server returns `directEndpoints` in its config RPC (the code comment calls it server.getConfig) (apps/server/src/ws.ts:1680-1712). Entries: bound LAN or tailnet IPv4 as `http://<ip>:<port>/` (none for a loopback-only server), and, when `tailscaleServeEnabled` and the HTTPS URL answers the well-known probe within 3 s, `{kind:"tailnet", httpBaseUrl:"https://<name>/"}` (apps/server/src/environment/DirectEndpoints.ts:54-136). The desktop advertises "Tailscale IP" (`http://100.x.y.z:<port>`) and "Tailscale HTTPS" endpoints (apps/desktop/src/backend/tailscaleEndpointProvider.ts:19-146), and avoids spawning `tailscale` unless exposure or serve is on, caching status for 60 s because the Mac App Store Tailscale CLI triggers a TCC prompt per spawn (apps/desktop/src/backend/DesktopServerExposure.ts:29, 428-438, 547-552).
- User docs: `t3 serve --tailscale-serve`, `t3 pair --tailscale`, remove with `tailscale serve --https=443 off` (docs/user/remote-access.md:119-145).

---

## 8. Practical recommendations for a native macOS client

### 8.a Connect to an already running local server (service, desktop backend or manual `t3 serve`)

1. Resolve the home: `$T3CODE_HOME` (trim, expand `~`) else `~/.t3` (apps/server/src/os-jank.ts:94-111). For the background service, read `T3CODE_HOME` from `~/Library/LaunchAgents/com.t3tools.t3code.service.plist` (apps/server/src/cloud/bootService.ts:66-81, 163-168).
2. Read `<home>/userdata/server-runtime.json` (and `<home>/dev/server-runtime.json` as `t3 pair` does). Require `version == 1`. Check liveness with `kill(pid, 0)`, treating EPERM as alive (apps/server/src/serverRuntimeState.ts:115-128).
3. `GET <origin>/.well-known/t3/environment` with about 2.5 s timeout; require 2xx and a descriptor; keep `environmentId` and `serverVersion`; treat 502, 503, 504 as not running (apps/server/src/cli/pair.ts:205-230). Use `origin` (it is `http://127.0.0.1:<port>` for loopback servers). Inference: prefer 127.0.0.1 over the printed `localhost`, because the server binds IPv4 127.0.0.1 by default (apps/server/src/server.ts:252) while connection strings say `localhost` (apps/server/src/startupAccess.ts:49-51).
4. If the file is missing or stale but a server may still be up (shared home, file deleted by another server's shutdown), a heuristic is to probe 127.0.0.1:3773 and compare the descriptor's environmentId with `<home>/userdata/environment-id` (environment-id is per state dir, apps/server/src/config.ts:164). This heuristic is not something the official clients do.
5. Get a credential without the desktop app by running the CLI that matches the server version:
   - service: `<home>/runtime/versions/<activeVersion>/t3`, with activeVersion from `<home>/runtime/service-state.json` (apps/server/src/cloud/serviceProtocol.ts:28-32);
   - desktop backend: `<home>/bin/t3` shim (apps/desktop/src/app/DesktopCliShim.ts:128-134);
   - otherwise `~/.local/bin/t3`, the installer symlink to `<home>/runtime/versions/<v>/t3` (scripts/install.sh:12, 23, 219-221).
   - There is no darwin-x64 CLI build (packages/shared/src/cliRelease.ts:20-27; docs/user/install.md:47-60); on Intel Macs only the desktop shim or a source build exists.
   Recommended, same as the desktop SSH flow:
   `t3 auth pairing create --base-dir <home> --label "<App>" --json`
   then extract JSON from the first `{` to the last `}` (as scripts/mobile-showcase.ts:643-665 and packages/ssh/src/tunnel.ts:180-198 do), then `POST <origin>/oauth/token` with the form in section 4.5, `client_label=<App>`, `client_device_type=desktop`, `client_os=macOS`, and optionally `scope=...`. Keep `access_token` (Bearer, 30 days). It appears in the server's Connections list and can be revoked there.
   Alternative: `t3 auth session issue --base-dir <home> --label "<App>" [--scope ...] --token-only` returns a bearer directly (default administrative scopes, 30 days, subject `cli-issued-session`, deviceType `bot`).
   `t3 pair` has no machine-readable output.
   These commands write into the same SQLite DB the server uses; the server checks pairing links and sessions against the DB on each use (apps/server/src/auth/PairingGrantStore.ts:559-586; apps/server/src/auth/SessionStore.ts:834-849), so the running server accepts them immediately.
6. WebSocket: `POST /api/auth/websocket-ticket` with `Authorization: Bearer <token>`, then connect `ws://127.0.0.1:<port>/ws?wsTicket=<ticket>&orchestrationProtocol=2` (or send the Authorization header on the upgrade, apps/server/src/auth/EnvironmentAuth.ts:1173-1194).
7. Do not scrape `boot-service.log` for the startup token (single use, 5 minutes, administrative) and do not read `secrets/` (a token also needs a DB row).

### 8.b Spawn its own headless server

Option 1, recommended (mirrors the desktop's SSH-managed launch, packages/ssh/src/tunnel.ts:702, 733):

- Use a dedicated base dir (for example under `~/Library/Application Support/<App>/`) unless you deliberately want to share `~/.t3`. Sharing means the same DB, environment id and server-runtime.json as the desktop app and the service, with no lock between them.
- Choose a port (scan from 3773 on 127.0.0.1 like the desktop, or omit `--port` and read the bound port from server-runtime.json or the stdout `Connection string:` line).
- Command: `<t3> serve --base-dir <dir> --host 127.0.0.1 --port <p>` (optionally `--log-level error` and a positional working directory), env `T3CODE_NO_BROWSER=1` (redundant for serve). Flags beat inherited `T3CODE_PORT`, `T3CODE_HOST`, `T3CODE_MODE`, `T3CODE_HOME`, but stripping them is safer. Never set `T3_SERVICE_LAUNCHER_CONTEXT`.
- Readiness: poll `GET /.well-known/t3/environment` (100 ms interval, 1 s per request, up to 60 s). An open TCP port is not readiness; the repo's own showcase script notes the server listens before the environment id is persisted (scripts/mobile-showcase.ts:1551-1558).
- Initial credential, any of:
  - before or after start: `t3 auth session issue --base-dir <dir> --token-only` (creates the DB and signing key on demand; secrets use exclusive create, apps/server/src/auth/ServerSecretStore.ts:227-290; apps/server/src/auth/SessionStore.ts:498);
  - after readiness: `t3 auth pairing create --base-dir <dir> --json` then `/oauth/token`;
  - parse the stdout `Token: ` line (single use, administrative, 5 minutes) and exchange it at `/oauth/token`.
- Stop with SIGTERM; finalizers delete server-runtime.json and remove a Tailscale mapping (apps/server/src/server.ts:761-766, 803-818). Signal handling detail of NodeRuntime.runMain: UNVERIFIED.

Option 2, desktop-faithful bootstrap envelope:

- `<t3> --bootstrap-fd 0 --base-dir <dir>` (or `serve --bootstrap-fd 0`), and write one line to stdin within 1 s:
  `{"mode":"desktop","noBrowser":true,"port":<p>,"host":"127.0.0.1","t3Home":"<dir>","desktopBootstrapToken":"<random>","tailscaleServeEnabled":false,"tailscaleServePort":443}`
  then exchange the token at `/oauth/token` (unbounded uses for 24 h). For long runs send `desktopBootstrapSecret` instead and derive window tokens with the HMAC in 5.6. Foundation `Process` cannot easily hand over fd 3 (posix_spawn file actions would be needed); fd 0 works, as the WSL path shows.
- Side effects of `mode: desktop`: policy `desktop-managed-local`, cookie `t3_session_<port>`, `serverSelfUpdate: "desktop-managed"`, analytics client type `desktop-app`, default port 3773 with no availability check, and no running-server preflight (apps/server/src/auth/EnvironmentAuthPolicy.ts:23-37; apps/server/src/auth/utils.ts:34-36; apps/server/src/cloud/selfUpdate.ts:190; apps/server/src/telemetry/AnalyticsService.ts:138; apps/server/src/cli/config.ts:305-307, 335). Adding `--mode web` overrides the envelope's mode while the token is still seeded (apps/server/src/cli/config.ts:288-295; apps/server/src/auth/PairingGrantStore.ts:335-351). That is code-level behavior, not a documented interface.
- If such a server shares a home with the real desktop app, exchanging a desktop-bootstrap grant revokes the other's `desktop-bootstrap` bearer sessions (apps/server/src/auth/EnvironmentAuth.ts:919-921), another reason to use a dedicated base dir.

Locking summary: none. `t3 serve` and desktop mode start even if another server uses the same home; only `t3` and `t3 start` in web mode refuse. Port conflicts surface only at bind time (exact error and exit code UNVERIFIED).

---

## 9. UNVERIFIED items and open questions

1. effect/cli details: exact names and values of global flags (`--help`, `--version`, `--log-level`), boolean flag syntax such as `--no-browser=false`, repeated `--scope` syntax, exit codes on failure.
2. effect Config parsing of booleans (for example `T3CODE_NO_BROWSER=1`) and `Config.Port` ranges.
3. Which stream (stdout or stderr) `Logger.consolePretty` and `Console.log` write to.
4. Exact `DateTime.formatIso` output and the human `Expires at:` format of `t3 auth pairing create`.
5. Effect HttpRouter global middleware semantics for the well-known route (inferred from apps/server/src/server.ts:661-667 and the desktop readiness probe).
6. NodeRuntime.runMain signal handling and graceful shutdown timing for SIGTERM and SIGINT.
7. Whether setting an env key to undefined removes it in effect ChildProcess (desktop env patch).
8. Effect Migrator behavior when CLI and server versions differ: a newer CLI running `t3 auth ...` could migrate a DB under an older running server, and an older CLI may meet a newer schema. Match CLI and server versions (descriptor `serverVersion` vs `t3 --version`).
9. Behavior and message when `--port` is already taken.
10. Exact macOS Electron appPath (serverRoot) for the desktop backend entry `apps/server/dist/bin.mjs`.
11. Which renderer auth path (IPC bearer via `/oauth/token` or cookie via `/api/auth/browser-session`) the packaged desktop uses in every situation.
12. apps/server/package.json line numbers were not captured; version 0.0.45 there vs tag v0.0.46-nightly.
13. `T3_BOOT_SERVICE_UNIT` has no reader in TS source; purpose unknown.
14. Doc inconsistency: docs/user/thread-migration.md:43 says a server started with `--home-dir <path>`, but `t3` only has `--base-dir`; `--home-dir` is a dev-runner flag (scripts/dev-runner.ts:851; docs/operations/development.md:24-31).
15. `startedAt` and `expiresAt` timezone formatting assumed UTC ISO-8601.
16. Whether `boot-service.log` is rotated and what file permissions it has (it can contain a short-lived administrative startup token).
17. The server does not enforce advertised `bootstrapMethods`; this could change in later versions, so do not rely on cross-mode token acceptance.
18. Remote SSH requirements per docs: Linux or Apple Silicon Mac with curl or wget, tar, sha256sum or shasum (docs/user/remote-access.md:164-166), not verified against code beyond the runner script.
