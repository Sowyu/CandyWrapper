# CandyWrapper

A native macOS client for T3 Code (Swift 6, AppKit, custom drawn, no webviews). It talks to the official T3 server and T3 Connect with the same protocol as the official app, and must look identical to it.

Start every session in this order:

1. Read `PROGRESS.md`. It names the current milestone, what is done, what is next and every open question.
2. Read `docs/spec.md`, the user's original brief. It is the source of truth for scope, hard rules and targets.
3. Before writing protocol code, read `docs/protocol.md`. It is the contract.

Update `PROGRESS.md` before you stop: tick what you finished, add what you learned, and set the next action. A new agent with no chat history must be able to continue from that file alone.

## Hard rules from the user

- No Electron, Chromium, WKWebView, Tauri, React Native, Flutter or JS UI frameworks in the app. Ask before anything that would ship or launch a browser engine. The user approved one exception, headless Chromium for capturing reference screenshots of the official web client. It is a capture tool only.
- Read the T3 source before writing code that depends on it. Do not guess protocol details.
- Stay wire compatible with official T3 Code. Ask before anything that could break compatibility.
- Demo each milestone to the user before starting the next. Milestone 2 needs the user's visual sign-off.

## Cost rules (the user pays per token)

- Delegate research and mechanical edits to `sonnet-medium`. Use `opus-medium` only when the agent must make a judgement call. Use `opus-high` almost never.
- Every agent brief must say "Do not use the Agent tool". Nested agents multiplied the cost once already.
- Run at most two agents at a time. Check signs of life within 2 minutes and kill stalled ones.
- Read files in slices. Do not dump large JSON or whole files into context.

## Machine facts

- Remote Mac mini M4, macOS 27, 16 GB RAM, on AC power. No battery.
- Hosted by MyRemoteMac. No display is attached. WindowServer exposes a virtual 1920x1080 screen at 1x and 60 Hz. Screen Sharing is on, reachable at `vnc://<mac-public-ip>:59010` (the public IPv4 is the local address in `netstat -an | grep '\.22 '`; keep it out of committed files). The provider's pf anchor `com.myremotemac.vnc` drops TCP to port 5900, so SSH tunnels to 5900 hang. Don't edit the provider's pf, fail2ban or LaunchDaemons. A GUI login needs the user to connect over VNC. See `PROGRESS.md` for the state of that.
- Passwordless sudo works. Use it only for things the user asked for.
- Only Command Line Tools are installed. Xcode is pending, so there is no xcodebuild, XCTest or Instruments yet. `swift build`, `swiftc` and Swift Testing work.
- No node, npm or bun. Python 3.9 at /usr/bin/python3, Homebrew python3.14 at /opt/homebrew/bin.

## The live T3 install belongs to the user

The user runs T3 Code from this machine, and this chat runs inside it.

- `~/.t3` holds the user's real data and the running service (`com.t3tools.t3code.service`, port 3773). Never write to it, never open its SQLite files, never start a server against it, never restart the service.
- Never kill processes by name or pattern. Kill only a PID you started and recorded.
- Shells inherit `T3CODE_HOME`, `T3_SERVICE_LAUNCHER_CONTEXT` and `T3_BOOT_SERVICE_UNIT` from the live service. Use `env -i` when starting any T3 binary, or it will try to attach to the live service launcher.

## Sandbox T3 server for testing

`scripts/sandbox-server` starts an isolated server from the installed runtime binary with its own home in `../CandyWrapper-research/sandbox/t3home`, port 47391 and telemetry off. Its PID goes in `../CandyWrapper-research/sandbox/server.pid`. Always use that script. It detaches the server into its own session. A server started through the harness's background-command feature gets killed at the 30-minute limit, and `nohup` fails here because there is no controlling terminal. `scripts/record-transcript.swift` pairs with it and records real HTTP and WebSocket traffic as JSONL. Recorded fixtures live in `fixtures/transcripts/`, with tokens, paths and e-mail scrubbed.

The sandbox has a demo git repo (`sandbox/demo-repo`) and a project and threads created by the recorder. Real turns use the user's Claude subscription, so keep test prompts tiny and use `claude-haiku-5-5`.

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
