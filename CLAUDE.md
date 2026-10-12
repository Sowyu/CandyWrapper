# CandyWrapper

A native macOS client for T3 Code (Swift 6, AppKit, custom drawn, no webviews). It talks to the official T3 server and T3 Connect with the same protocol as the official app, and must look identical to it.

Start every session in this order:

1. Read `PROGRESS.md`. It names the current milestone, what is done, what is next and every open question.
2. Read `docs/spec.md`, the user's original brief. It is the source of truth for scope, hard rules and targets.
3. Before writing protocol code, read `docs/protocol.md`. It is the contract.

Update `PROGRESS.md` before you stop: tick what you finished, add what you learned, and set the next action. A new agent with no chat history must be able to continue from that file alone.

## Hard rules from the user

- No Electron, Chromium, Tauri, React Native, Flutter or JS UI frameworks in the app. WKWebView is allowed only for features that render web content in the official app (built-in browser, HTML replies, MCP apps, Mermaid, HTML file preview, Clerk sign-in), created while its pane is visible and destroyed when hidden. Nothing may run in the background. Headless Chromium is allowed as a build-time tool (reference captures, token extraction), never shipped.
- Read the T3 source before writing code that depends on it. Do not guess protocol details.
- Stay wire compatible with official T3 Code. Ask before anything that could break compatibility.
- Demo each milestone to the user before starting the next. Milestone 2 needs the user's visual sign-off.

## Cost rules (the user pays per token)

- Delegate research and mechanical edits to `sonnet-medium`. Use `opus-medium` only when the agent must make a judgement call. Use `opus-high` almost never.
- Every agent brief must say "Do not use the Agent tool". Nested agents multiplied the cost once already.
- Run at most four Claude agents at a time (the user raised it from two on 2026-10-11, "for now"). Check signs of life within 2 minutes and kill stalled ones.
- Read files in slices. Do not dump large JSON or whole files into context.

## Machine facts

- Remote Mac mini M4, macOS 27, 16 GB RAM, on AC power. No battery.
- Hosted by MyRemoteMac. No display is attached; the GUI session (user mrm, automatic login) draws to a virtual screen of 1920x1080 points at 2x (3840x2160 pixels) and 60 Hz, as of 2026-10-10 (it was 1x before); on 2026-10-12 it reported 1x again (1920x1080 pixels), so check with system_profiler SPDisplaysDataType before you assume a scale. Screen Sharing is reachable at `vnc://<mac-public-ip>:59010` (the public IPv4 is the local address in `netstat -an | grep '\.22 '`; keep it out of committed files). The provider's pf anchor `com.myremotemac.vnc` drops TCP to port 5900, so SSH tunnels to 5900 hang. Don't edit the provider's pf, fail2ban or LaunchDaemons.
- Run GUI work inside the desktop session with `sudo launchctl asuser 502 sudo -u mrm <cmd>`.
- Since 2026-10-10 the user granted Screen Recording and Accessibility to `t3`, the app this shell runs under, so `screencapture` works directly and `scripts/ui/` (build with `scripts/ui/build`) can click, scroll, type, press buttons by title and bring an app forward. Check the real window this way: offscreen snapshots draw synchronously and miss on-screen-only bugs. The user may be watching that screen.
- Passwordless sudo works. Use it only for things the user asked for.
- Xcode 27.0 is installed and selected (license accepted). xcodebuild, XCTest and xctrace work. XcodeGen 2.46 lives at `../CandyWrapper-research/tools/xcodegen/bin/xcodegen` (Homebrew can't install it: `/opt/homebrew/var/log` belongs to root for the provider's fail2ban).
- No node, npm or bun. Python 3.9 at /usr/bin/python3, Homebrew python3.14 at /opt/homebrew/bin.

## The live T3 install belongs to the user

The user runs T3 Code from this machine, and this chat runs inside it.

- `~/.t3` holds the user's real data. One T3 server runs it: T3's login agent `com.t3tools.t3code.service` in `gui/502`. Its port changes between restarts; read `~/.t3/userdata/server-runtime.json`. Never write to `~/.t3`, never open its SQLite files, never start a server against it, never restart the service.
- A custom headless daemon and root watchdog (`com.t3tools.t3code.daemon`, `.watchdog`) ran a second server until 2026-10-09. The user chose to keep only the login agent. Their plists and scripts are backed up in `../CandyWrapper-research/backups/t3-daemon-2026-10-09/`. Two servers on one `~/.t3` is the failure to watch for: check `ps` for more than one `t3 serve` without `--base-dir`.
- Never kill processes by name or pattern. Kill only a PID you started and recorded.
- Shells inherit `T3CODE_HOME`, `T3_SERVICE_LAUNCHER_CONTEXT` and `T3_BOOT_SERVICE_UNIT` from the live service. Use `env -i` when starting any T3 binary, or it will try to attach to the live service launcher.

## Sandbox T3 server for testing

`scripts/sandbox-server` starts an isolated server from the installed runtime binary with its own home in `../CandyWrapper-research/sandbox/t3home`, port 47391 and telemetry off. Its PID goes in `../CandyWrapper-research/sandbox/server.pid`. Always use that script. It detaches the server into its own session. A server started through the harness's background-command feature gets killed at the 30-minute limit, and `nohup` fails here because there is no controlling terminal. `scripts/record-transcript.swift` pairs with it and records real HTTP and WebSocket traffic as JSONL. Recorded fixtures live in `fixtures/transcripts/`, with tokens, paths and e-mail scrubbed.

The sandbox has a demo git repo (`sandbox/demo-repo`) and a project and threads created by the recorder. Real turns use the user's Claude subscription, so keep test prompts tiny and use `claude-haiku-5-5`.

Build every test app with its own bundle id and URL scheme, so it shares no UserDefaults (drafts, prompts, per-thread state) with the user's demo app or other agents' apps: `xcodebuild -project CandyWrapper.xcodeproj -scheme CandyWrapper -derivedDataPath /tmp/cw-dd-<task> PRODUCT_BUNDLE_IDENTIFIER=dev.candywrapper.test.<task> CANDY_URL_SCHEME=candywrapper-<task> build`, then launch it with `CANDY_APP=/tmp/cw-dd-<task>/Build/Products/Debug/CandyWrapper.app scripts/run-app ...`.

## Reference source

`scripts/fetch-t3-source` clones pingdotgg/t3code at the tag in `T3_VERSION` into `.t3code-src/`, which is gitignored. The research clone at `../CandyWrapper-research/t3code` is the same tag. The T3 repo's own `AGENTS.md` and `docs/internals/` explain its architecture and are worth reading first.

## Layout

- `docs/spec.md` is the brief, `docs/protocol.md` the wire contract, `docs/parity-checklist.md` the feature list, `docs/design.md` tokens and components, `docs/benchmarks.md` measurements.
- `docs/research/` holds raw research notes with file:line citations into the T3 source. They are partial. Prefer `docs/protocol.md` once it exists, and verify against source when they disagree.
- `fixtures/transcripts/` holds real server recordings for protocol tests.
- `design/reference/` holds reference screenshots of the official app.
- `scripts/` holds tools: transcript recorder, `procstat` (per-process CPU, wakeups and footprint from kernel counters), sandbox and fetch scripts.

## Writing style

Plain words, active voice, sentence-case headings, no em dashes. Mark deliberate shortcuts in code with `// ponytail: <ceiling>, <upgrade trigger>`. Commits carry no AI attribution lines.
