# T3 Code reference screenshots, Nightly 3824

Source: official T3 Code web client **0.1.4-nightly.20261028.3824**, tag `v0.1.4-nightly.20261028.3824`, commit `eb751fa0730d6a51d56547cb7fcaf4822a7e0e3b`. Captured 2026-10-28 from its own server, with the new design and the default T3 Code theme. Headless Chrome 156.0.8078.70 renders 1100x780 CSS px at 2x (2200x1560 px). Narrow captures are 800x780 CSS px (1600x1560 px). Files retain the 3814 names. The browser color scheme selects light or dark; no custom theme is installed.

This directory contains 121 PNGs: every one of the 117 filenames in `../reference-3814/`, plus light/dark versions of 53 and 54. The original and 3814 directories are unchanged. The `-3473` filenames here are compatibility aliases of the corresponding **3824** images.

## Repeating the run

The isolated sandbox is `~/CandyWrapper-research/sandbox-3824-ref`. It is a copy of `sandbox-3814-ref`, made without stopping the 3814 server. The copied state database was replaced with a consistent SQLite backup of the source database, and the copied server PID, log, pairing file and bearer token were removed before startup. Only the copied project's workspace root was updated through `projects.mutate`, to `sandbox-3824-ref/demo-repo`. A fresh browser profile, `chrome-3824-profile`, avoids cached 3814 environment URLs. The unrelated `sandbox-3824` directory was not used.

The new server remains running at **http://127.0.0.1:47403**, PID **75594**, also recorded in `sandbox-3824-ref/server.pid`. Its bearer token is in `~/CandyWrapper-research/sandbox-3824-ref/session.token` (mode 0600); no credential is committed. Its log is `sandbox-3824-ref/server.log`. The runtime is `~/CandyWrapper-research/runtimes/t3-0.1.4-nightly.20261028.3824-darwin-arm64/t3`. It was started with `env -i`, `T3CODE_HOME=<copy>/t3home`, `serve --base-dir <copy>/t3home --port 47403 --host 127.0.0.1 --no-browser`. Reuse this server rather than the live home. The 3814 server remains running on 47402, PID 9835.

The existing Markdown, commands, question and changed-file threads were reused. Startup cancelled the copied active runs and expired the copied file approval; the question request survived. With the user's explicit approval, one tiny supervised Haiku turn recreated 05 in a new thread, without applying the proposed file. One further Haiku turn captured 01 and 29 in both themes. **Two new Claude Haiku 5.5 turns were used**, within the six-turn cap. The two queued messages were removed before execution, and the story run was interrupted after capture. The question and new approval remain unanswered. Thread IDs are in `plans/sandbox-ids.json`; the replacement approval ID differs from 3814.

Compile the runner outside the repo:

```sh
swiftc design/reference-3824/plans/capture-reference-extended.swift \
  -o ~/CandyWrapper-research/sandbox-3824-ref/capture-3824
python3 design/reference-3824/plans/gen.py
design/reference-3824/plans/run.sh design/reference-3824/plans/main.json design/reference-3824
```

`run.sh` mints a fresh pairing URL with `env -i <runtime> auth pairing create --base-dir <copy>/t3home --base-url http://127.0.0.1:47403 --json`. Pairing data stays in the sandbox. `CAPTURE_PROFILE`, `CAPTURE_PORT` and `CAPTURE_BIN` override the browser profile, DevTools port (default 9450) and compiled runner. `CAPTURE_TEXT_DIR` writes route/theme/text audit files outside the repo.

`gen.py` retains the established state definitions and updates routes and selectors. Run `main.json`, `narrow.json`, `diff-turn.json`, `extras.json`, and `composer-3824.json`. `panels-3824.json` repeats 05 and 06. The old exact effort selector now matches one word within `data-composer-shortcut`, since the effort control also owns the mode shortcut. 42 opens that combined menu instead of the removed standalone Runtime mode list. After capture, copy 05 and 48 to the historical `-3473` aliases. Never copy images from 3814 into this set.

The seed database came from the prior sandbox; do not rerun its seed prompts. `seed-approval-3824.json` records the single approved replacement turn. `running.json` costs one model turn and captures both themes in the same run. It explicitly queues two messages with alternate submit, removes them and stops the run afterward. The new Bars plan changes Appearance through the real UI and restores Word after each theme. Run it after the main set so a non-default preference cannot leak into other captures.

For `notice.json`, temporarily set the copied Markdown thread's branch metadata to `main` with `orchestration.dispatchCommand` (`thread.metadata.update`, fresh command ID), switch only the copied demo repo to `reference-banner`, refresh its local Git status with `vcs.refreshStatus` (`cwd` set to the copied demo repo, `localOnly: true`), and type its unsent draft. Without that refresh, the server can retain main as the cached current branch and omit the notice. Restore the copy to `main`, refresh local status again, and restore the thread metadata to `null` after capture. The plan clears its draft. No new turn is needed. `error.json` runs with `CAPTURE_NO_PAIR=1` and a fresh `chrome-3824-error-profile`, using an invalid pairing credential against the copy. It does not stop either server.

The capture runner is the 3814 runner with new sandbox defaults. It waits for fonts, reduces motion, parks the pointer at the top edge and supports continued states, per-state themes, audit output and cleanup after capture. All PNGs are actual browser output, with no edited pixels. Every final PNG was visually inspected, individually or in four-image sheets; incorrect or incomplete states were rejected and recaptured. `manifest.csv` records the final pixel dimensions and SHA-256 hashes.

## Differences from 3814

- The composer is simpler: attachment control on the left, grouped model/effort/send controls on the right, and effort words beside the spoken model label by default. Permissions that match the default no longer occupy a separate footer chip. Non-default Supervised still has a chip in 05. The new-thread strip names its permissions.
- The effort popup contains the horizontal Permissions toggle and its mode description. 41, 42 and the explicit new 53 capture this combined popup. 54 records the optional effort bars selected in Appearance.
- State 22 now opens a Commit changes confirmation modal, instead of the action-failed toast captured at 3814. The final commit action was not used.
- Chat tables fit their lane and wrap cells. The expand/collapse control is gone; the copy menu remains. This is visible in the reused Markdown seed, especially with a right panel open and in the narrow captures. There was no new Markdown turn or altered reply content.
- The copied pending approval cannot survive server startup as a live approval, so 05 uses the approved replacement seed. Relative ages and elapsed times differ, and copied interrupted attempts still appear in the sidebar. These are data differences, not a change to the theme.

## Captured states

Every row has both themes unless stated otherwise. File stems omit `.dark.png` and `.light.png`.

| # | State | Files | How reached | Notes |
|---|---|---|---|---|
| 01 | Running turn | 01-running-turn | New draft, select Haiku, send a lighthouse story prompt | Active Thinking/Working row and Stop, with a short thinking line. Same real run in both themes, stopped after 29 |
| 02 | Sidebar populated | 02-sidebar-populated | Open Markdown thread | Done, Input and Approval states; no accounts or live threads |
| 03a-c | Markdown top, middle, bottom | 03a-kitchen-sink-top, 03b-kitchen-sink-middle, 03c-kitchen-sink-bottom | Scroll the Markdown-only seed | Headings, table, tasks, Python/TypeScript/bash, Note alert and bullets. No tool calls in this reply |
| 03d | Commands | 03d-kitchen-sink-commands | Open commands seed | ls, git status and failing ls; collapsed Worked row |
| 04 | New draft | 04-new-thread-draft | Open `/` | Default unsent model is 6 Astra. No turn used that model |
| 05 | Approval | 05-approval-request | Recreated supervised file-create seed, leave approval pending | Inline waiting-for-approval controls and the new composer footer. `05-approval-request-3473` is a byte-identical 3824 alias |
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
| 22 | Commit confirmation | 22-commit-dialog | Details, Commit | Commit changes modal with files, optional message and commit actions. Final Commit left untouched; no commit was made |
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
| 41 | Reasoning picker | 41-traits-picker | Composer effort control | Medium default; Low through Ultrathink, with Permissions below |
| 42 | Access mode | 42-access-mode-picker | Composer effort menu | Permissions now share this menu: Supervised, Auto-accept edits, Auto, Full access |
| 43 | Find | 43-find-in-thread | Cmd+F, markdown | Highlighted matches |
| 44 | Thread details | 44-thread-details-panel | Toggle thread details | Floating environment, branch, Git and changes card |
| 45 | Go to file | 45-go-to-file | Cmd+P | Sandbox file picker |
| 46 | Project search | 46-project-search | Cmd+Shift+F, hello | Sandbox search |
| 47 | Changed files card | 47-changed-files-card | Open notes seed, center the changed-files card | hello.py +3, notes.md +3. Same copied seed and changed files as 3814 |
| 48 | Turn diff | 48-diff-turn-file | Click notes.md in 47's card | Latest turn, notes.md expanded, stacked layout. `48-diff-turn-file-3473` is a byte-identical 3824 alias |
| 03n, 04n, 11n | Narrow | 03n-kitchen-sink-narrow, 04n-new-thread-narrow, 11n-right-panel-narrow | narrow.json, 800 CSS px wide | Markdown, new draft, right-panel surface chooser |
| 49 | General modal over thread | 49-settings-modal-general | Open Settings from the Markdown thread | Explicit modal reference, with thread visible through the backdrop |
| 50 | Floating thread settings/details | 50-floating-thread-settings | Thread header details control | Actual floating thread card; not a second application Settings window. See source notes below |
| 51 | Notice above composer | 51-composer-branch-notice | Explicit main thread branch, change sandbox checkout, type unsent draft | Branch changed from main, Restore branch and dismiss controls. Repo/metadata restored afterward |
| 52 | Connection/authentication error | 52-connection-error.dark.png | Invalid pairing credential, fresh unpaired profile | Stable authentication error, no spinner. The unauthenticated surface stays dark even with a light browser scheme |

| 53 | Effort menu with permissions | 53-effort-menu-permissions | Click the composer effort word | TraitsPicker reasoning choices and the four Permissions segments in one popup |
| 54 | Effort bars | 54-composer-effort-bars | Settings, Appearance, Effort display, Bars; return to thread | Real setting, restored to Word after each capture. Four bars for Haiku, two filled at Medium |

## Source notes

All citations refer to the 3824 tag, read with `git show`, not the research checkout's current files.

- Composer grouping and menu ownership: `apps/web/src/components/chat/ComposerControlsBar.tsx:153-190,195-212`. The permissions section lives inside the effort popup, while the separate chip is hidden for the default permissions. `apps/web/src/components/chat/ComposerFooterControls.tsx:156-240` defines the four-segment Permissions section. The new-thread strip's control is `apps/web/src/components/ComposerContextPermissions.tsx:11-38`.
- Word versus bars: `apps/web/src/components/chat/TraitsPicker.tsx:618-683`; the combined menu appends its Permissions section at `721-740`. `apps/web/src/components/chat/EffortGlyph.tsx:17-38,52-84` maps ordinary effort levels to bars. The actual Appearance selector is `apps/web/src/components/settings/AppearanceSettingsPanel.tsx:276-305`.
- Commit confirmation text: `apps/web/src/components/GitActionsControl.tsx:273-275,1664-1669`.
- Tables: `apps/web/src/index.css:2196-2247` fits and wraps the table within the lane. `apps/web/src/components/chat/MarkdownTable.tsx:36-66` has only the copy menu below it; the expansion toggle was removed.
- Application Settings remains the large modal in `apps/web/src/routes/_chat.settings.tsx:120-142`, using `apps/web/src/components/AppRouteModal.tsx:10-14,38-55`. State 50 remains the floating thread details card, implemented in `apps/web/src/components/chat/ThreadDetailsCard.tsx:104-184`, not a separate small application Settings window.
- The branch notice is `apps/web/src/components/chat/ThreadActivityBanners.tsx:186-225`, gated by composer content in `apps/web/src/components/chat/useThreadLifecycle.tsx:281-297`. Alternate submit still selects queue instead of steer in `apps/web/src/components/chat/ChatComposer.tsx:2105-2116`. The local status refresh schema is `packages/contracts/src/rpc.ts:1411-1416`.

## Caveats

- These references show the official default themes at 3824. No CandyWrapper application code, old reference directory or fidelity test input changed.
- Dynamic ages, Working seconds, diagnostics counters, installed skills and provider lists are not frozen. Interrupted copied attempts remain sandbox-only sidebar rows.
- Usage deliberately selects No providers. All three views contain empty/zero data and no machine-wide account usage. Providers is scrolled away from account status.
- Diff and file browsing use the copied sandbox repo. Historical message text can still mention `sandbox-3814-ref`, because the existing replies were reused unchanged. New actions and terminal working directories use `sandbox-3824-ref`.
- The copied sandbox remains ready for follow-up work, with the question, replacement approval and the existing two-file diff. Capture Chromium processes were closed; both reference servers remain running.
- Validation covered image decoding, exact sizes, complete 3814 filename coverage, JSON parsing, runner syntax, source review, visual inspection and secret scanning. This artifact-only task did not require app builds, performance measurements or Swift tests.

## Blocked or not captured

- 52 light remains absent: the unauthenticated pairing error stays dark with a light browser scheme. The existing dark error filename is recaptured at 3824; no mislabeled duplicate is included.
- No separate small application Settings popup was found. 49 captures application Settings as a large modal, and 50 captures the actual floating thread details/settings card.
- 23 Pull requests, 24 PR detail, 25 proposed plan, 28 drag and 30 real usage limit were absent from 3814 and remain outside this set. No real account was connected or usage limit deliberately hit.
- Populated usage, later onboarding steps, review annotations, browser/Mermaid/HTML/MCP surfaces and hover/pressed variants remain outside this set.
