# Session actions audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Reviewed 2026-10-26 at `d8f8cc11e385c4703586ae4b38c770ef43fee316` on
`t3/audit-session-actions`. This is an audit, with no product or visual changes.
No builds, tests, app launches, network requests, shared screen use, live server
access, or real account access ran in this worktree. All findings below are
source-traced, not runtime reproductions. Severity uses P1 for a file corruption
path and P2 for broken user actions or persistent stale state.

T3 citations below refer to the local read-only checkout at
`~/CandyWrapper-research/t3code`, tag `v0.1.2-nightly.20261021.3473`, which matches
this checkout's `T3_VERSION`. No web research was needed for repository behavior.

## Findings

### SA1: A failed browser download can replace an existing file with an error body

**P1, source-traced.** `App/Sources/BrowserController.swift:580-585` discards the
HTTP response from `URLSession.shared.download`, removes the destination, and
moves the downloaded temporary file there. HTTP 404 and 403 responses normally
return downloaded bodies rather than throw a transport error. There is no status
check or error toast on that path.

Reachability: download a file in the integrated browser, click its toast's Save
action, choose an existing destination and approve replacement. If the server
returns an HTTP error, the previous file becomes the error body. Missing or
evicted downloads and the wrong-target path in SA2 give concrete 404 triggers;
revoked authorization gives another error response. No pre-existing destination
is needed to get a corrupt new download, but replacement makes the consequence
more serious.

T3's `apps/server/src/preview/ServerBrowserStream.ts:229-238` explicitly returns
404 text when `openDownload` finds no match. The match includes thread, tab and
download id in `apps/server/src/preview/ServerBrowser.ts:1101-1108`. This is not a
hypothetical server protocol response.

Suggested repair boundary: validate a successful HTTP response before touching
the destination, and replace the destination with a file operation that preserves
the original if the replacement fails. This audit does not implement the repair.

Added `scripts/audit-session-actions`, an opt-in extraction harness for the actual
`saveDownload` method, with local UI and HTTP fakes. It checks a successful 200
replacement and preservation plus feedback for 404 and 403. It compiles one tiny
Swift file, runs at most 15 seconds, and removes its temporary sandbox directory.
It performs no real networking. **The harness was not compiled or executed here**
under the parent's centralized execution instruction. Expected current result,
pending execution: 200 passes; 404 and 403 fail because the original file is lost.

### SA2: Download Save targets the current browser rather than the browser that downloaded

**P2, source-traced.** `App/Sources/BrowserController.swift:468-471` captures only
download id and file name in the toast action. `saveDownload` later resolves the
current panel tab, current thread and current environment at `:570-575`. It also
prefers the panel tab even when the download event came from the floating player.

Trigger: download in tab A, switch to tab B or another thread/environment before
clicking Save, then save the offered file. The request combines A's download id
with B's thread/tab/route. A simultaneous floating player and browser panel can
trigger it without any navigation. Closing the panel can instead make Save do
nothing because the guard no longer resolves a tab.

User effect: an offered download cannot be saved after ordinary navigation; a
server 404 can also reach SA1. The server does not search globally by download id:
`apps/server/src/preview/ServerBrowser.ts:1101-1108`.

T3 keeps the download's already bound URL in the action closure,
`apps/web/src/browser/ServerBrowserSurface.tsx:119-130`. CandyWrapper should retain
the originating shell, thread and tab with the offered download, or an equivalent
origin reference. No runtime test was added for toast origin capture.

### SA3: Script auto-preview opens on the newly selected thread or machine

**P2, source-traced.** `App/Sources/TerminalController.swift:427-456` correctly
captures the script's originating thread and shell for terminal open/write, but
`:457` calls `onScriptStarted` with only the script. The callback in
`App/Sources/ThreadSession.swift:632-638` invokes `browser.openURL`. That method
uses the browser's current thread and shell in
`App/Sources/BrowserController.swift:657-663`.

Trigger: run a project script with `autoOpenPreview` and `previewUrl` in thread A;
switch to B while terminal open/write is pending; let the write finish. B must
have browser support for the callback's availability guard to pass. The command
runs in A, but its preview is created and shown under B. When B is on another
machine, a loopback URL points at the wrong machine and can fail to load or show
an unrelated service.

T3 carries the original `activeThreadRef` through the async script function:
`apps/web/src/components/ChatView.tsx:2637-2653,2710-2732`. Its preview call receives
that reference explicitly. Preserve the origin in the callback and open its
preview against that origin, with a deliberate reveal policy after navigation.
No live script or UI reproduction ran.

### SA4: Browser server discovery stays on the old session after replacement

**P2, source-traced.** `App/Sources/BrowserController.swift:63` stores environment,
configured URLs and task for discovery, without an owning session.
`startDiscovery` reuses that task solely by environment and URL equality at
`:355-361`. `sessionChanged` cancels the preview event stream and starts it again,
then renders, but never cancels discovery (`:887-895`).

Trigger: leave an empty browser panel visible for environment E, then replace E's
`ShellSession`, such as re-pairing or changing its session route. Keep the same
project and configured URLs. `Environments.attach` stops the old shell at
`App/Sources/Environments.swift:515-518`; `ShellSession.stop` disconnects its
supervisor at `App/Sources/ShellSession.swift:396-404`. Rendering the same empty
panel calls `startDiscovery`, which returns early with its old task handle.

User effect: local server suggestions stop updating on the new session, so a
newly started dev server does not appear and old entries may remain. Hiding and
revealing the panel or changing discovery configuration can recover by forcing a
new subscription. Ordinary socket reconnection within the same supervisor is
handled by `ConnectionSupervisor.subscribe` and is not this bug.

T3 exposes discovery as an environment RPC subscription at
`packages/client-runtime/src/state/preview.ts:35-40`. The comparison in
CandyWrapper's own preview event subscription (`BrowserController.swift:158-165`)
and browser video client (`:379-383`) already shows the required owner boundary.
No session replacement reproduction ran.

## Revalidated October 18 findings

- Finding 6, scheduled-task session replacement: addressed in current source.
  `ScheduledTasksStore.swift:15-16,43-46,60-67` records shell ownership, rejects an
  old shell's delivery and restarts subscriptions when the environment's session
  identity changes. `AppDelegate.swift:248-249` connects environment changes to
  the store. This is a source revalidation, not a fresh execution pass.
- Finding 7, device session replacement: addressed in current source.
  `DevicePanelController.swift:87-109` compares `subscribedShell` as well as the
  environment; `ThreadSession.swift:934-935` calls `devices.sync` on session
  change. State resets and rendering stops a stream when its state disappears.
  The main old finding should not be repeated as a new bug. The device event
  callback at `:109` still guards only the environment, unlike the scheduled
  store's shell guard. An already queued old delivery deserves a deterministic
  replacement test, but no stale delivery was demonstrated in this audit.

## Coverage and existing tests

Source tracing covered terminal creation, attach, input outbox, close, session
replacement and script completion; browser open/list/events, navigation, stream
ownership, file picker upload, download, reconnect and discovery; device
subscription, open, tools and video; scheduled lists and automation actions;
Dither navigation flags; sidebar lifecycle and palette routing.

Useful existing coverage, read but not run here:

- `TerminalStateTests.swift:26-34,68-107`: reusable script terminals and attach,
  exit and snapshot semantics. `TerminalLifetimeTests.swift:8-25`: view release
  after hiding a pane. These do not exercise app-controller pending writes or
  script auto-preview after switching.
- `PreviewStateTests.swift:14-55`: revision ordering, server epochs and optimistic
  close rollback. `PreviewStreamClientTests.swift:35-67`: stopped client lifetime.
  Neither covers origin-bound download toasts or discovery owner replacement.
- `SidebarMultiMachineTests.swift:44-85`: row identity and click targets with
  repeated local ids across machines. Sidebar settle and delete completion also
  explicitly recheck the selected route before navigating
  (`SidebarCommands.swift:346-347,731-735`). No new wrong-target bug was established
  in those inspected routes.
- `CommandPaletteTests.swift:128-167`: keyboard result/action routing.
  `PaletteCommands.swift:701-715` cancels old message searches and guards their
  query. `ThreadAutomationsController.swift:63-74` captures the environment before
  awaiting and uses a busy guard. No wrong-environment write was established.
- `DitherTabListTests.swift:11-55` tests the list model, not asynchronous draft
  creation. A failed scratch draft never invokes its success callback
  (`PaletteCommands.swift:575-594`), leaving the new-tab flag set
  (`DitherTabsController.swift:130-132`). Treat the visible consequence and rapid
  repeated + clicks as a follow-up stress scenario, not an executed finding.

Browser frame capture, file chooser target changes while a native picker is open,
partial terminal paste delivery during detachment, repeated script starts before
metadata updates, and device action completion across rapid A/B/A switches were
not executed. No latency percentiles or end-to-end responsiveness claims can be
made from this source audit. There is no app-controller test target in the package
test lane; the extraction harness closes only the download-save gap.

## Parent execution commands and stress scenarios

Run only when the parent's disk floor and centralized execution lane permit:

```sh
CW_SESSION_ACTIONS_AUDIT_REPRO=1 scripts/audit-session-actions
scripts/test --filter TerminalStateTests
scripts/test --filter PreviewStateTests
scripts/test --filter SidebarMultiMachineTests
scripts/test --filter CommandPaletteTests
scripts/test --filter DitherTabListTests
```

The opt-in harness is intentionally allowed to fail on current production code;
it is not part of the normal suite. It is unexecuted, so compilation compatibility
and its predicted results remain to be confirmed by the parent.

For sandbox integration, prioritize these bounded cases:

1. Download distinct tiny fixtures from panel A and floating tab B, switch
   thread/environment, then Save each toast. Include a missing download and an
   existing disposable sandbox destination. Verify exact bytes and preservation.
2. Delay terminal open/write, start one script in A, switch to B on another
   sandbox machine, release the reply, and inspect both preview lists. Use a
   harmless command and a fixture preview URL.
3. Keep empty-browser discovery, a device panel and a scheduled-task watcher open
   across three same-environment shell replacements. Change server suggestions,
   device state and task enabled state after each replacement. Deliver one old
   queued event after installing the new shell to test ownership guards.
4. Burst ten terminal inputs/resizes, switch A/B/A and reconnect while requests
   are pending; compare acknowledged bytes against server input. Burst two
   script starts before terminal metadata changes. Check for duplicate command
   starts, truncation and unexpected reuse without running costly agent turns.
5. Fail scratch-project creation after Dither +, then select an existing thread;
   verify tab count and selection. Repeat + twice with replies in reverse order.

No production repair, progress edit, main push, or temporary build artifact was
made by this reviewer. Parent can cherry-pick this report and harness together.
