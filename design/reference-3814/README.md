# T3 Code reference screenshots, Nightly 3814

Source: official T3 Code web client **0.1.4-nightly.20261028.3814**, tag `v0.1.4-nightly.20261028.3814`, commit `ce66aab13fabde01b82deac4b4b3eaae53641988`. Captured 2026-10-28 from its own server, with the new design and the default T3 Code theme. Headless Chrome 156.0.8078.70 renders 1100x780 CSS px at 2x (2200x1560 px). Narrow captures are 800x780 CSS px (1600x1560 px). Files use the existing `NN-slug.dark.png` and `NN-slug.light.png` names. The browser color scheme selects the theme; no custom theme is installed.

This directory contains 117 PNGs: all 106 filenames from `../reference/`, ten new light/dark captures, and one dark error capture. The old directory is unchanged. The `-3473` filenames here are compatibility aliases of the corresponding **3814** images, not older captures.

## Repeating the run

The isolated sandbox is `~/CandyWrapper-research/sandbox-3814-ref`. Its fresh `t3home` and Chrome profiles were created for this capture. Only `demo-repo` and `git-demo` project folders were copied from the original sandbox, never its T3 home. The demo repo was restored to its own baseline before seeding. The project points to `sandbox-3814-ref/demo-repo`, not the repository above it.

The server remains running at **http://127.0.0.1:47402**, PID **9835**, also recorded in `sandbox-3814-ref/server.pid`. Its bearer token is in `~/CandyWrapper-research/sandbox-3814-ref/session.token` (mode 0600); no credential is committed. Its log is `sandbox-3814-ref/server.log`. The runtime is `~/CandyWrapper-research/runtimes/t3-0.1.4-nightly.20261028.3814-darwin-arm64/t3`. To reuse the server, first check the PID and port. To start it again, use the isolated environment and `--base-dir` pattern from `scripts/sandbox-server`, with `SANDBOX_DIR=~/CandyWrapper-research/sandbox-3814-ref`, `SANDBOX_PORT=47402` and version `0.1.4-nightly.20261028.3814`. Never attach a capture to the live home.

`plans/sandbox-ids.json` records this sandbox's project, environment and five seed thread IDs. `plans/seed-demo.json` records the five tiny prompts: Markdown, shell commands, unanswered questions, pending supervised approval, and two changed files. The model was explicitly selected as **Claude Haiku 5.5** for every send. There were **10 real Haiku turns** in total: five seeds, two running-state attempts, two accidental follow-up turns in the first queue attempt, and one final shared running/queue turn. Two final queued messages were removed before execution and are not model turns. Approval and input remain unanswered. The running turns were stopped after capture; an earlier sleep request finished after the model backgrounded it. No extra seed turns were needed.

Compile the tool once, outside the repo:

```sh
swiftc design/reference-3814/plans/capture-reference-extended.swift \
  -o ~/CandyWrapper-research/sandbox-3814-ref/capture
python3 design/reference-3814/plans/gen.py
design/reference-3814/plans/run.sh design/reference-3814/plans/main.json design/reference-3814
```

`run.sh` creates a fresh pairing URL with `env -i <runtime> auth pairing create --base-dir <sandbox>/t3home --base-url http://127.0.0.1:47402 --json`. The pairing JSON stays in the sandbox. `CAPTURE_PROFILE` defaults to `sandbox-3814-ref/chrome-profile`; alternate profiles used for recaptures also live there. `CAPTURE_PORT` selects the DevTools port, and `CAPTURE_BIN` can override the compiled tool. `CAPTURE_TEXT_DIR` optionally writes route/theme/text audit files outside the repo.

`gen.py` reads the original plans without editing them and adapts routes, selectors, scrolling and layout controls. Run `main.json`, `narrow.json`, `diff-turn.json`, then `extras.json`. `panels-3814.json` repeats only 05 and 06. `running.json` costs one new model turn: it captures both themes in the same run, explicitly queues two messages with the alternate submit action, then removes them and stops generation. Do not rerun seed or running plans just to review existing images. After capture, copy 05 and 48 to their `-3473` aliases.

For `notice.json`, set only the sandbox Markdown thread's `branch` metadata to `main` through `orchestration.dispatchCommand` (`thread.metadata.update`, fresh `commandId`), switch the sandbox demo repo to `reference-banner`, and type the unsent draft. The command contract is at `packages/contracts/src/orchestrationV2.ts:2972-2982` in the source tag above. Restore the demo repo to `main` and the thread's branch metadata to `null` afterward. The capture plan clears its draft after each theme. This state costs no model turn.

Run `error.json` with `CAPTURE_NO_PAIR=1` and a fresh profile. It uses an intentionally invalid pairing credential against this sandbox, without stopping the server. The error profile is separate from the authenticated capture profile.

The capture tool adds independent DevTools ports, optional text/DOM audit output, per-state theme overrides, continued states and actions after capture to the original tool. It waits for fonts, reduces motion and parks the pointer at the top edge before each screenshot. All captures are actual browser PNGs; no image pixels were edited. Every final image was opened and visually reviewed, individually or in inspection sheets. Incorrect modal routes, the first queue attempt, missing notices and a misleading light error duplicate were rejected and recaptured or omitted.

## Captured states

Every row has both themes unless stated otherwise. File stems omit `.dark.png` and `.light.png`.

| # | State | Files | How reached | Notes |
|---|---|---|---|---|
| 01 | Running turn | 01-running-turn | New draft, select Haiku, send a lighthouse story prompt | Active Thinking/Working row and Stop. Light includes the beginning of thinking text. Same real run in both themes, stopped after 29 |
| 02 | Sidebar populated | 02-sidebar-populated | Open Markdown thread | Done, Input and Approval states; no accounts or live threads |
| 03a-c | Markdown top, middle, bottom | 03a-kitchen-sink-top, 03b-kitchen-sink-mid, 03c-kitchen-sink-bottom | Scroll the Markdown-only seed | Headings, table, tasks, Python/TypeScript/bash, Note alert and bullets. No tool calls in this reply |
| 03d | Commands | 03d-kitchen-sink-commands | Open commands seed | ls, git status and failing ls; collapsed Worked row |
| 04 | New draft | 04-new-thread-draft | Open `/` | Default unsent model is 6 Astra. No turn used that model |
| 05 | Approval | 05-approval-request | Supervised file-create seed, leave approval pending | New banner, composer and footer. `05-approval-request-3473` is a byte-identical 3814 alias |
| 06 | User input | 06-user-input-request | AskUserQuestion seed, leave unanswered | Purpose and Language questions; four choices on the visible first question |
| 07 | Palette | 07-palette-default | Cmd+K | Default palette |
| 08 | Palette search | 08-palette-search | Cmd+K, hello | Search results |
| 09 | Split diff | 09-diff-split | Cmd+D, select Split diff view, expand files | Only sandbox hello.py and notes.md, +6 lines |
| 10 | Stacked diff | 10-diff-unified | Cmd+D, select Stacked diff view, expand files | Keeps old filename; no review annotation |
| 11 | Terminal | 11-terminal-drawer | Cmd+J | Sandbox terminal; no split or colored output |
| 12 | Files | 12-right-panel-files | Cmd+Alt+B, Files | Tree only; no open file preview |
| 13 | Model picker | 13-model-picker | Click the composer model control | Claude models and selected Haiku |
| 14 | Slash menu | 14-composer-slash-menu | Type / | Locally installed skills are listed |
| 15 | Mention menu | 15-composer-at-mention | Type @hel | Sandbox hello.py match |
| 16a-c | General settings | 16a-settings-general-top, 16b-settings-general-mid, 16c-settings-general-bottom | Open Settings, General; scroll the modal's content | Large modal over the thread, not the old full-page settings layout |
| 17 | Appearance | 17-settings-appearance | Settings, Appearance | System scheme and default T3 Code theme selected |
| 18 | Providers | 18-settings-providers | Settings, Providers, Claude; scroll | Model/runtime controls. Account status is outside the captured scroll position |
| 19 | Keybindings | 19-settings-keybindings | Settings, Keybindings | Default bindings; no edit or conflict interaction |
| 20 | Thread context menu | 20-sidebar-thread-context-menu | Contextmenu event on the Markdown thread row | Pin, settle, snooze, rename, archive, delete and project settings entries |
| 21 | Git menu | 21-git-actions-menu | Open thread details, Git action options | Commit and Publish repository |
| 22 | Commit action error | 22-commit-dialog | Details, Commit | Real action-failed toast because commit message generation requires configured Codex. No commit was made |
| 26 | Usage Limits | 26-usage-limits | Open /usage, deselect All providers, Limits | Empty state, avoids machine-wide account history |
| 26b | Usage Cost and Tokens | 26b-usage-cost, 26b-usage-tokens | Same modal, switch Cost/Tokens | Zero totals, 30 days, Model breakdown, No providers selected |
| 27 | Welcome | 27-welcome | Open /welcome | Connect step over blurred thread; sandbox environment only |
| 29 | Queued messages | 29-queued-messages | Alternate submit twice during 01's run | Two dashed bubbles with Send now, edit and remove. Both removed before execution |
| 31 | Sidebar collapsed | 31-sidebar-collapsed | Cmd+B | Details card also visible in the wider workspace |
| 32 | Source control | 32-settings-source-control | /settings/source-control | Modal, repository defaults and Git availability |
| 33 | Projects | 33-settings-projects | /settings/projects | One sandbox project with its correct folder |
| 34 | Environments | 34-settings-connections | Settings, Environments | Keeps old filename; empty saved-remote list |
| 35 | Archive | 35-settings-archived | Settings, Archive | Empty list |
| 36 | Scheduled tasks | 36-settings-scheduled-tasks | Settings, Scheduled tasks | Empty list |
| 37 | SnapShots | 37-settings-snapshots | Settings, SnapShots | Desktop-only notice in the official web client |
| 38 | Maintenance | 38-settings-storage | Settings, Maintenance | Storage route has moved; filename retained |
| 39 | Diagnostics | 39-settings-diagnostics | Maintenance, View diagnostics | Sandbox resource monitor summary. Counters vary; no process command lines shown |
| 40 | Browser | 40-settings-integrations | Settings, Browser | Old Integrations route now maps to Browser. Desktop-only controls stay disabled |
| 41 | Reasoning picker | 41-traits-picker | Composer effort control | Medium default; Low through Ultrathink |
| 42 | Access mode | 42-access-mode-picker | Composer Runtime mode | Supervised, Auto-accept edits, Auto, Full access |
| 43 | Find | 43-find-in-thread | Cmd+F, markdown | Highlighted matches |
| 44 | Thread details | 44-thread-details-panel | Toggle thread details | Floating environment, branch, Git and changes card |
| 45 | Go to file | 45-go-to-file | Cmd+P | Sandbox file picker |
| 46 | Project search | 46-project-search | Cmd+Shift+F, hello | Sandbox search |
| 47 | Changed files card | 47-changed-files-card | Open notes seed, center the changed-files card | hello.py +3, notes.md +3. Card top about 351 CSS px; seed wording differs from the old set |
| 48 | Turn diff | 48-diff-turn-file | Click notes.md in 47's card | Latest turn, notes.md expanded, stacked layout. `48-diff-turn-file-3473` is a byte-identical 3814 alias |
| 03n, 04n, 11n | Narrow | 03n-kitchen-sink-narrow, 04n-new-thread-narrow, 11n-right-panel-narrow | narrow.json, 800 CSS px wide | Markdown, new draft, right-panel surface chooser |
| 49 | General modal over thread | 49-settings-modal-general | Open Settings from the Markdown thread | Explicit modal reference, with thread visible through the backdrop |
| 50 | Floating thread settings/details | 50-floating-thread-settings | Thread header details control | Actual floating thread card; not a second application Settings window. See source notes below |
| 51 | Notice above composer | 51-composer-branch-notice | Explicit main thread branch, change sandbox checkout, type unsent draft | Branch changed from main, Restore branch and dismiss controls. Repo/metadata restored afterward |
| 52 | Connection/authentication error | 52-connection-error.dark.png | Invalid pairing credential, fresh unpaired profile | Stable authentication error, no spinner. The unauthenticated surface stays dark even with a light browser scheme |

## Source notes

All citations refer to the 3814 tag, read with `git show`, not the research checkout's current files.

- Application Settings uses `AppRouteModal` in `apps/web/src/routes/_chat.settings.tsx:120-142`. Settings and Usage share the large modal implementation in `apps/web/src/components/AppRouteModal.tsx:10-14,38-55`; at this width its viewport has 40 CSS px padding. Modal scrolling must target its content, rather than the blurred thread underneath.
- The floating card captured as 50 is `apps/web/src/components/chat/ThreadDetailsCard.tsx:104-117,119-184`. It has both inline and popover modes and contains the environment, branch and Git controls. No separate small application Settings popover was found; application Settings is the large modal captured as 49. State 50 explicitly records this distinction.
- The notice is `apps/web/src/components/chat/ThreadActivityBanners.tsx:186-225`. Its visibility also depends on composer content in `apps/web/src/components/chat/useThreadLifecycle.tsx:281-297`. A null thread branch does not produce the mismatch, which is why merely switching the demo checkout was insufficient.
- Alternate submit chooses queue instead of the default steer action in `apps/web/src/components/chat/ChatComposer.tsx:2162-2174`; labels and submit behavior are in `apps/web/src/components/chat/ComposerPrimaryActions.tsx:277-308`.

## Caveats

- These images show 3814's new default design. They are stored alongside the classic references and do not replace CandyWrapper's experimental design references or change any fidelity test input.
- Dynamic ages, Working seconds, diagnostics counters, the machine's local provider/skill list and reply wording are not frozen. Repeated running attempts add a few sandbox-only sidebar threads.
- Usage normally reads machine-wide provider history. The committed Usage references deliberately select No providers and contain no account usage. Populated subscription limits and usage charts are not represented.
- All diff paths and edits belong to the copied sandbox demo repo. The old reference set's parent-repository diff issue does not apply here.
- The sandbox remains seeded for follow-up work, including the pending approval and questions, and the two changed files. Capture Chromium processes were closed; the sandbox server remains running.
- Validation covered PNG decoding, exact pixel sizes, old filename coverage, JSON parsing, runner syntax, source review and visual inspection. No app behavior changed, so app builds, performance runs and Swift tests were not needed for this artifact-only task.

## Blocked or not captured

- 23 Pull requests page and 24 PR detail: absent from the old PNG set; no GitHub account was connected. No PR fixtures were created.
- 25 proposed plan, 28 drag state and 30 real usage limit: absent from the old PNG set and not seeded, to keep the model budget at 10 turns and avoid a real usage-limit event.
- 52 light: rejected because the unauthenticated pairing error renders dark regardless of the browser scheme. No mislabeled duplicate is included. This is the auth error variant, not a server-offline overlay.
- A separate floating application Settings panel: not found in the 3814 source. State 50 captures the available floating thread details/settings card and cites its implementation.
- Populated usage, real sign-in, remote environments and PR-linked threads were not attempted. No real accounts were signed in.
- Wizard steps after Connect, review comment annotations, browser/Mermaid/HTML/MCP surfaces, and hover/pressed variants remain outside this set, as in the original run.
