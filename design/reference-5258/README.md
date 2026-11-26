# T3 Code reference screenshots, Nightly 5258

Source: the official T3 Code web client **0.1.13-nightly.20261125.5258**, served by its own runtime. I captured it on 2026-11-25 with the default theme, at 1100x780 CSS px and 2x, like `../reference-4928/`. Only the states whose 4928 capture no longer matches the 5258 client are here.

| File | State | Test |
|---|---|---|
| 02-sidebar-populated | The markdown thread open, sidebar at its natural scroll | `FeaturesTests/SidebarFidelityTests.wholeSidebar` |
| 62-side-chat-panel | A new side chat open beside "Run Shell Commands" (`plans/side-chat.json`, the 4928 plan's state on port 47398): Add to chat in place of Bring back | `FeaturesTests/SideChatFidelityTests.sideChatPanel` |

## The sandbox

`~/CandyWrapper-research/sandbox-5258-ref` is a copy of `sandbox-4928-ref`, made with `rsync -a --exclude 'chrome-*' --exclude server.pid --exclude server.log`. Never start 5258 on the 4928 folder: it migrates the shared database. The copy's `t3-wrapper` and `zdot/.zshrc` point at the copy and at the 5258 runtime, so the environment still reads "Sandbox Mac".

```sh
SANDBOX_DIR=~/CandyWrapper-research/sandbox-5258-ref SANDBOX_PORT=47398 \
  T3_BIN=~/CandyWrapper-research/sandbox-5258-ref/t3-wrapper scripts/sandbox-server 0.1.13-nightly.20261125.5258
CAPTURE_PORT=9468 design/reference-5258/plans/run.sh design/reference-5258/plans/sidebar.json design/reference-5258
```

`plans/sidebar.json` is the 02 state of `../reference-4928/plans/main.json` with the port changed. `plans/run.sh` is the 4928 runner pointed at the copy, port 47398 and the profile `chrome-5258-profile`. It reuses the copied `capture-4928` binary. Stop the server by the PID in `sandbox-5258-ref/server.pid` when done.

## How the data differs from 4928

The capture ran six days after the 4928 seed, so every row reads "6d". The pending approval expired when the 5258 server first started, so only Input keeps a status. Approval and Input sort first because `sortInboxThreadsByReturn` (client-runtime `state/threadInbox.ts:57-75`) takes their latest run's time. The sidebar scrolls to reveal the open thread, as CandyWrapper does. `Screen3824Fixtures.sidebar` mirrors these rows.

5258 also drops the filter button next to the folder button (#33057, port item 3.3). The test leaves the search band out, so that does not count against it.
