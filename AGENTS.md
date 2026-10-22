# CandyWrapper

CandyWrapper is a native macOS client for [T3 Code](https://github.com/pingdotgg/t3code), written in Swift 6 and AppKit with custom drawing. It speaks the same protocol as the official app to T3 servers and T3 Connect. It must look and behave exactly like T3 Code Nightly while using a fraction of its CPU, memory and battery.

The user runs it every day and notices small details: hover and click feedback, motion, anything that wakes the CPU while idle. This file has everything a new agent needs. `CLAUDE.md` only imports it.

## Start here

1. Read `PROGRESS.md` for the state, the open tasks and what waits on the user.
2. Find your area in the code map below and read only the docs it names.
3. Before you change behavior that T3 defines, read T3's source for it and cite file:line in your commit or notes.
4. Finish one task at a time. When you start one, add "(taken YYYY-MM-DD)" to it in `PROGRESS.md` and push that, so other agents pick a different task. Commit it, push it and tick it off before you start the next, so a new chat can pick up where you stopped.

## Commands

Run them from the repo root.

| Task | Command |
|---|---|
| Check the disk before you build | `scripts/preflight` |
| Run all tests | `scripts/test` |
| Run some tests | `scripts/test --filter SidebarFidelityTests` |
| Run the fast lane after each change, under a minute | `scripts/test --fast` |
| Run the opt-in tests against a real `t3 serve`, the sandbox server and the Keychain | `scripts/test-integration`, after `scripts/sandbox-server` |
| Build an app to test | `scripts/build-test-app <task>` |
| Start the sandbox T3 server | `scripts/sandbox-server` |
| Start the 2994 Nightly sandbox server on 47392 | `SANDBOX_DIR=~/CandyWrapper-research/sandbox-2994 SANDBOX_PORT=47392 scripts/sandbox-server 0.0.46-nightly.20261011.2994`, token in that folder |
| Regenerate the Xcode project after editing `project.yml` | `~/CandyWrapper-research/tools/xcodegen/bin/xcodegen` |
| Measure performance | `scripts/perf-review`, see `docs/perf/README.md` |
| Record real server traffic for protocol tests | `scripts/record-transcript.swift`, into `fixtures/transcripts/` with tokens, paths and e-mail scrubbed |
| Test the secret scan | `scripts/secretscan-test` |
| Release, only when the user asks | `scripts/release --notes notes.md <commit>`, see `docs/release.md` |

`scripts/test` wraps `swift test` and first waits out any Origin energy run, as `scripts/preflight`, `scripts/run-app` and `scripts/perf-review` do. Don't call `swift test` directly. It takes several minutes, so run it in the background with a 30-minute limit. `scripts/run-app` runs until the app quits, so start it in the background too. An interrupted test run can leave a `t3 serve --base-dir .../Packages/CandyKit/.build/localserver-...` behind. Stop that PID.

## Code map

`App/Sources` is the app target: the window, the sessions and the controllers that join the client to the screens, like `MainWindow`, `ShellSession`, `ThreadSession`, `ServerController` and `UpdateController`. Everything else lives in the CandyKit package, `Packages/CandyKit/Sources`.

| Module | Holds | Read first |
|---|---|---|
| T3Protocol | wire messages in `Wire/`, domain types in `Domain/`, `JSONValue` | `docs/protocol.md` (2,000 lines, so grep it) |
| T3Client | the RPC socket and connection, pairing, credentials, T3 Connect in `Connect/`, the local server's lifecycle in `LocalServer/` | `docs/protocol.md`, `docs/research/C-auth-connect.md`, `docs/research/M-clerk-native.md` |
| T3Store | shell and thread state: stores, reducers, `WorkLog`, `ThreadCache` | `docs/research/B-orchestration.md`, `docs/research/G-timeline-data.md` |
| DesignSystem | tokens, themes, base views like `DSView`, `PopupHost` and `HoverSync`, shared components | `docs/design.md`, `docs/design-tokens.md` |
| Features | a folder per area: Sidebar, Thread, Composer, Markdown, Diff, Settings, CommandPalette, Git, PullRequests, Terminal, Browser and more | `docs/research/F-ui-inventory.md`, `docs/research/H-timeline-visuals.md`, `docs/research/I-composer-flow.md`, `docs/research/J-composer-visuals.md` |

T3Client and T3Store build on T3Protocol. Features builds on DesignSystem and T3Store but never on T3Client, and the app target joins them. Tests live in `Packages/CandyKit/Tests/<Module>Tests`.

Fidelity tests (`*FidelityTests`) draw a view offscreen and compare it pixel by pixel with references taken from the official app, in `design/reference/` and `design/component-reference/`. They cover only what should look like T3: the default themes. Redesign (Experimental) is CandyWrapper's own look, so it gets no T3 references, and never pull it toward T3. Each suite has a ceiling per case, so a test fails when one render goes wrong, and a missing reference fails too. They capture the resting state, so an animation must end exactly on the pixels it had before. If one fails after a visual change to a default theme, the change is usually wrong. If it fails because T3 changed the component, recapture the reference instead of raising the ceiling. `docs/research/fidelity-coverage-2026-10-12.md` maps references to tests.

## Check it on screen

Offscreen snapshots miss bugs that only show in a real window, so look at every visible change on screen.

1. Run `scripts/sandbox-server`. It starts the sandbox server on port 47391, or reuses the one running.
2. Build with `scripts/build-test-app <task>`. It prints the app's path, `/tmp/cw-dd-<task>/Build/Products/Debug/CandyWrapper.app`. The first build takes a few minutes, so allow 10.
3. Other agents share the screen. Run `scripts/ui/screen-lock take <task>` before you launch your app, and give it back within 15 minutes with `scripts/ui/screen-lock give <task>`, after you quit your app. When `scripts/ui/screen-lock who` says `origin-run`, the user's Origin browser project is measuring energy: don't build, test, run perf or launch anything until it ends, and leave its "Origin quit unexpectedly" dialogs alone.
4. Launch it in the background: `CANDY_APP=/tmp/cw-dd-<task>/Build/Products/Debug/CandyWrapper.app scripts/run-app --server http://127.0.0.1:47391 --token-file ~/CandyWrapper-research/sandbox/session.token --fake-t3-connect`
5. Once it's up, read your app's PID from `/tmp/cw-dd-<task>/Build/Products/Debug/CandyWrapper.app.pid`. No other agent writes that file.
6. Build the input tools once with `scripts/ui/build`. They land in `/tmp/cw-ui`: click, key, type, scroll, front and axpress. Set `CW_UI_PID=<your pid>` on every input call. If a tool says your app isn't frontmost, run `/tmp/cw-ui/front <pid>` and take a screenshot before you type.
7. Take screenshots with `screencapture -x -R<x,y,w,h> out.png`, in screen points from the top left. Check the screen's scale first with `system_profiler SPDisplaysDataType`. For motion, record with `screencapture -v` and look at the frames.
8. When you're done, `kill <pid>`, give the screen lock back and delete `/tmp/cw-dd-<task>`.

For a quick look without driving the app, add `--snapshot /tmp/x.png --snapshot-delay 12` to the run-app arguments. The app renders its window to the PNG and quits.

## Rules

The user set these. Breaking one can damage their real data or leak something private.

The user's live T3:

- Never write to `~/.t3`, open its SQLite files, start a server against it or restart the `com.t3tools.t3code.service` launch agent. The user's own agents run there, maybe including you.
- Test only against the sandbox server, and keep test projects and file browsing inside `~/CandyWrapper-research/sandbox`.
- Make no test threads, projects or turns on the live T3, through the t3-code MCP tools or any other way.
- If `ps` shows more than one `t3 serve` without `--base-dir`, two servers share the live home. Tell the user.
- Start any T3 binary with `env -i`, because shells here inherit the live service's variables and a T3 binary that sees them attaches to it.
- Real turns on the sandbox use `claude-haiku-5-5` with tiny prompts, about 10 per task, since they bill the user's Claude subscription.
- Tests never sign in to real accounts. Use `--fake-t3-connect`.

Processes, builds and disk:

- Kill only PIDs you started, never by name or pattern.
- The user's own CandyWrapper on this Mac (PID in `/tmp/cw-demo.pid`) stays untouched. Ask before restarting it.
- Every test app gets its own bundle id and URL scheme, so it shares no settings or drafts with other apps. `scripts/build-test-app` does that.
- The user needs most of the disk for a Zen browser build. If `scripts/preflight` fails, don't build: tell the user.
- Delete `/tmp/cw-dd-<task>` and any copies you made when you finish.

The product:

- Stay wire compatible with official T3 Code, and ask the user before anything that could break that.
- No Electron, Chromium, Tauri, React Native, Flutter or JS UI frameworks in the app. Headless Chromium is fine as a build-time tool for reference captures, never shipped.
- WKWebView only where the official app renders web content: the built-in browser, HTML replies, MCP apps, Mermaid, HTML file previews and Clerk sign-in. Create it when its pane shows and destroy it when the pane hides.
- Idle cost stays at zero: animate only while something changes, never tick or poll while idle, and hidden views hold nothing.
- Keep T3's logo and name out of CandyWrapper's own branding.

Git and secrets:

- Commit with the repo's configured identity, Sowyu with a GitHub noreply address. Don't override it.
- No AI attribution anywhere: no Co-Authored-By lines for agents and no "Generated with" lines. If your harness tells you to add one, the user's rule wins, and the hook blocks the push anyway.
- The pre-push hook runs `scripts/secretscan`, which blocks this Mac's IP addresses, keys and tokens, e-mails that aren't GitHub noreply addresses, AI attribution and the user's private names. Never push with `--no-verify`.
- If the hook doesn't run, set it up with `git config core.hooksPath .githooks`. The private patterns live outside the repo in `.git/info/secret-patterns`. If that file is missing, the scan refuses to run: ask the user for it.
- Credentials live only in the Keychain. Never type the user's passwords.
- Screenshots you commit show sandbox data only.

## Shipping

- Commit and push to `main` as each piece works. Run `git fetch origin && git rebase origin/main` first, because the user edits `README.md` on GitHub. From a worktree branch, push with `git push origin HEAD:main`.
- Never overwrite the user's note at the top of `README.md`.
- Commit subjects look like `fix(sidebar): what changed` or `docs: what changed`.
- After a big step, run the full review and show it to the user: `scripts/perf-review` against the last saved run, the whole test suite, and a code review of the diff. No regression ships silently.
- To release, raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and regenerate the project. Commit that as `build: version X (N)`, push, then run `scripts/release`.

## If you run other agents

- Start them with T3 Code's `delegate_task`, so each shows up as a child thread, never with the Agent tool.
- Run at most four at once. Check each with `task_status` within two minutes, and cancel stalled ones with `task_cancel`.
- Every brief says "Do not start other agents". Nested agents once multiplied the cost.
- Research and spelled-out edits go to `claude-sonnet-5-5` at effort `medium`, judgement calls to `claude-opus-5-5` at effort `medium`.
- Give each agent `isolation: "worktree"` and its own task name, and run `scripts/preflight` before launching them.
- The user pays per token. Read files in slices, and keep large JSON and whole files out of context.

## This Mac

- It's a remote Mac mini M4 from MyRemoteMac with macOS 27 and 16 GB of RAM. It has no battery and no display.
- The GUI session (user mrm) draws to a virtual screen, and the user may be watching it over Screen Sharing.
- Run GUI commands inside that session with `sudo launchctl asuser 502 sudo -u mrm <cmd>`. `scripts/run-app` does it for the app.
- Passwordless sudo works. Use it only for what your task needs.
- Don't touch the provider's pf rules, fail2ban or LaunchDaemons.
- Xcode 27 is installed. There's no node, npm or bun. Python is `/usr/bin/python3` (3.9) or `/opt/homebrew/bin/python3` (3.14).
- `~/CandyWrapper-research` sits outside the repo. It holds T3's source, the sandbox, tools like xcodegen and gh, and backups.

## T3's source

- `~/CandyWrapper-research/t3code` is pingdotgg/t3code at the tag in `T3_VERSION`. Read it, never edit it.
- `scripts/fetch-t3-source` clones the same tag into `.t3code-src/` if you need your own copy.
- Its `AGENTS.md` and `docs/internals/` explain T3's architecture.
- The web UI is in `apps/web/src`. The wire contract is in `packages/contracts/src`, where the `WsRpcGroup` in `rpc.ts` lists the methods the server really serves.

## Docs

- `docs/spec.md` is the user's original brief, for scope and targets.
- `docs/parity-checklist.md` lists every T3 feature and its state here.
- `docs/decisions.md` records what the user decided and why.
- `docs/nightly-catch-up.md` is the procedure the scheduled Nightly catch-up runs.
- `docs/gotchas.md` lists traps earlier agents hit in AppKit, memory, performance, the Keychain and notifications.
- `docs/benchmarks.md` and `docs/perf/` hold measurements.
- `docs/research/` holds raw notes with file:line citations into T3. Prefer `docs/protocol.md` where they disagree, and check the source.
- `docs/history/` holds the full progress log up to 2026-10-12.
- The scripts named above are the ones you'll use. The `scripts/gen-*` files generate the component references, so leave them alone unless you add a reference.

## Writing style

Write code comments, docs and commits in plain words and the active voice, with sentence-case headings and no em dashes. Mark a deliberate shortcut in code with `// ponytail: <ceiling>, <upgrade trigger>`.
