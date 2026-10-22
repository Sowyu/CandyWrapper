# T3 Code reference screenshots

Source: official T3 Code web client 0.0.46-nightly.20261009.2861, sandbox server at 127.0.0.1:47391, headless Chrome at 1100x780 CSS px, 2x (2200x1560 px). Narrow captures are 800 CSS px wide (1600x1560). Files are `NN-slug.dark.png` and `NN-slug.light.png`. Theme comes from the browser color scheme. All turns used Claude Haiku 5.5.

## Repeating the run
Plans are in `plans/`. `plans/capture-reference-extended.swift` is the repo capture tool plus these changes: alt and ctrl modifiers, Enter/Tab/arrow key codes, and `"log": true` on `js` actions to print the result. `plans/run.sh <plan> <outdir>` mints a fresh pairing URL for each run (the profile does not keep the session) and runs the tool. `plans/gen.py` is the plan generator; the JSON files are its output. Each state in `main.json` first clears the panel, terminal, diff and draft keys in localStorage, then reloads, so states do not leak into each other. Thread IDs in the plans belong to this sandbox. The `seed-*.json` plans created the demo threads (they cost model turns, run them once). `running.json` creates new threads on every run.

## Captured states
| # | State | Files | How reached | Notes |
|---|---|---|---|---|
| 01 | Running turn | 01-running-turn | New draft, Haiku, send story prompt, capture 3.5 s later | Shows Thinking row and Stop button, not streamed text or tool calls |
| 02 | Sidebar populated | 02-sidebar-populated | Open markdown thread | Done, Input, Approval and Working rows. No pinned, snoozed or settled rows |
| 03a-c | Kitchen-sink thread top, middle, bottom | 03a/03b/03c-kitchen-sink-* | Markdown-only thread, scrolled to 0, 0.5, 1 | Headings, table, task list, py/ts/bash code, Note alert, bullets. No images, mermaid, or tool cards |
| 03d | Command thread | 03d-kitchen-sink-commands | Thread that ran ls, git status, failing ls | Short, no scroll. Commands are inside the collapsed "Worked for" row |
| 04 | New-thread draft | 04-new-thread-draft | Path `/` | Default model Claude Fable 5.1 |
| 05 | Approval request | 05-approval-request | Supervised thread, file create, approval left open | File change approval, composer replaced |
| 06 | User input request | 06-user-input-request | Thread using AskUserQuestion, left unanswered | 1/2 question with 4 options. Recaptured 2026-10-14 from the 3105 web client (sandbox-3105, port 47393), because 3105 renders the question as Markdown (ComposerPendingUserInputPanel.tsx:257-262). Same questions, asked again in thread f0fb2cc2; the turn is still running, so the composer shows Stop |
| 07 | Palette default | 07-palette-default | Cmd+K | |
| 08 | Palette search | 08-palette-search | Cmd+K, type "hello" | |
| 09 | Diff split | 09-diff-split | Cmd+D, Changes menu, Uncommitted, split button | See diff caveat |
| 10 | Diff unified | 10-diff-unified | Same, default layout | No review comment annotation |
| 11 | Terminal drawer | 11-terminal-drawer | Cmd+J | One terminal, no split, no colored output |
| 12 | Right panel Files | 12-right-panel-files | Cmd+Alt+B, Files | File tree only. Click on hello.py did not hit, so no file is open |
| 13 | Model picker | 13-model-picker | Cmd+Shift+M | |
| 14 | Slash menu | 14-composer-slash-menu | Type "/" | Lists this machine's skills |
| 15 | @ mention menu | 15-composer-at-mention | Type "@hel" | |
| 16a-c | Settings General top, middle, bottom | 16a/16b/16c-settings-general* | /settings/general, scrolled | |
| 17 | Settings Appearance | 17-settings-appearance | | No custom theme |
| 18 | Settings Providers | 18-settings-providers | | Real providers only |
| 19 | Settings Keybindings | 19-settings-keybindings | | No conflict row |
| 20 | Thread context menu | 20-sidebar-thread-context-menu | Synthetic contextmenu event on a thread row | |
| 21 | Git actions menu | 21-git-actions-menu | Thread details button, Commit chevron | Commit and Publish repository entries |
| 22 | Commit action | 22-commit-dialog | Details panel, Commit | Not a dialog: shows an "Action failed" toast (commit message generation needs Codex). Treat as error variant |
| 26 | Usage | 26-usage-limits | /usage | Opens on Limits view. Cost and Tokens views are behind a "Limits" dropdown, not captured |
| 27 | Welcome wizard | 27-welcome | /welcome | Step 1 (Connect) only |
| 29 | Queued messages | 29-queued-messages | Send story prompt, then two more messages while running | Queued list with Steer |
| 31 | Sidebar collapsed | 31-sidebar-collapsed | Cmd+B | extra |
| 32-40 | Settings pages | 32-settings-source-control, 33-settings-projects, 34-settings-connections, 35-settings-archived, 36-settings-scheduled-tasks, 37-settings-snapshots, 38-settings-storage, 39-settings-diagnostics, 40-settings-integrations | /settings/<page> | extra, numbers 31 and up are not from the inventory |
| 41 | Traits picker | 41-traits-picker | Click Medium | extra |
| 42 | Access mode picker | 42-access-mode-picker | Click Full access | extra |
| 43 | Find in thread | 43-find-in-thread | Cmd+F, type "markdown" | extra |
| 44 | Thread details panel | 44-thread-details-panel | Header details button | extra |
| 45 | Go to file | 45-go-to-file | Cmd+P | extra |
| 46 | Project search | 46-project-search | Cmd+Shift+F, type "hello" | extra |
| 47 | Changed files card | 47-changed-files-card | `plans/diff-turn.json`: thread "Add notes and docstring", toast closed, card scrolled to the middle (top at 317.5 CSS px) | Captured 2026-10-10. Turn 1 changed hello.py and notes.md. No folders in this card |
| 48 | Turn diff from the card | 48-diff-turn-file | Same, then click notes.md in the card; pointer parked on the empty panel | Right panel inline at 484 px, scope "Turn 1", files collapsed (turn diffs only scroll to the file). Layout toggle shows split because the 09 capture changed the setting |
| 48-3473 | Turn diff from the card, 3473 | 48-diff-turn-file-3473 | plans/diff-turn.json against the 0.1.2-nightly.20261021.3473 web client (sandbox-3473, port 47396), fresh browser profile | Recaptured 2026-10-21: 3473 expands a file opened from the card (DiffPanel.tsx:551-580), and the fresh profile shows the default unified layout. `ChangedFilesFidelityTests` compares only the panel with it; the chat column shows a "Scroll to end" pill that CandyWrapper delays 150ms |
| 05-3473 | Approval request, 3473 | 05-approval-request-3473 | Seeded with plans/seed-approval.json against the 0.1.2-nightly.20261021.3473 web client (sandbox-3473, port 47396): Haiku 5.5 picked through the model search, Supervised, file create, approval left open; then the 05 state of plans/main.json on the new thread, toast closed, fresh browser profile | Recaptured 2026-10-22: since T3 a93b03c8a5 a send declines pending approvals and redirects the agent, so the composer keeps its footer and Stop button and reads "Send a message to decline and redirect the agent" (ChatComposer.tsx:6175-6177). The banner is unchanged; the composer top moved from 694 to 616 css px. `PanelsFidelityTests` compares 05 with this capture |
| 03n, 04n, 11n | Narrow (800 px) kitchen sink, new thread, right panel | *-narrow | narrow.json | extra |

Not every extra image was opened. Looked at: 01, 02, 03a, 03b, 04, 05, 06, 07, 09, 11, 12, 13, 14, 16a, 18, 20, 21, 22, 26, 27, 29, 44. Settings pages 32-40, 45, 46, 41 to 43 and the narrow set were not checked, so verify them before relying on them.

## Caveats
- Diff panel (09, 10): it listed files from /Users/mrm/CandyWrapper (the repo above the sandbox), about +21k lines, not demo-repo's own change (+4 shown in the details panel). The numbers change as that repo changes. Recapture after fixing the sandbox if exact diff content matters.
- The sidebar contains extra story threads from repeated 01 and 29 runs, and a leftover draft row is gone after the localStorage reset. Relative times ("13m") are not fixed.
- The sandbox server went down briefly around 11:38. The first seed attempt failed and was redone.

## Blocked or not captured
- 24 PR detail, 23 Pull requests page: /pull-requests redirects to a new thread, no GitHub credentials. 23 files were removed.
- 25 Proposed plan card: no plan-mode toggle found in the web UI (no /plan command, no Shift+Tab binding, runtime mode list has no plan). The "/plan" try picked a skill instead.
- 28 Sidebar drag: the capture tool has no drag action.
- 30 Limited thread: needs a real usage limit hit.
- 10 review comment annotation: needs gutter click, not scripted.
- 26 Cost and Tokens views: dropdown not driven.
- 27 wizard steps 2 and 3, fresh-data first-run, seeded import list: need a fresh data directory.
- Pinned, snoozed, settled, archived, goal, PR-linked, forked, subagent threads: not seeded.
- Codex provider states, second environment, remote badges: not possible here.
- Browser panel, Mermaid, HTML render, MCP app, device panel: webview items, not attempted.
- Hover/focus/pressed states, queued-run Steer hover, toasts other than 22: not attempted.
