# T3 Code reference screenshots, Nightly 4928

Source: the official T3 Code web client **0.1.11-nightly.20261119.4928**, tag `v0.1.11-nightly.20261119.4928`, commit `e8c4824b70f3ea89b4dfb6cd98b6e17adade50cf`. I captured it on 2026-11-19 from its own server with the default T3 Code theme. chrome-headless-shell 156.0.8078.70 renders 1100x780 CSS px at 2x, so each image is 2200x1560 px. The narrow captures are 800x780 CSS px, 1600x1560 px. The browser color scheme picks light or dark. No custom theme is installed.

This folder holds 141 PNGs: 135 at 2200x1560 and the six narrow ones at 1600x1560. Every filename in `../reference-3824/` is here, so a test can switch folders by name. The `-3473` files are byte-identical copies of 05 and 48, as at 3824. States 55 to 64 are new at 4928. Nothing here was copied from an older set, and no pixel was edited.

## The sandbox

The old Mac's seed data did not come over, so I seeded a new sandbox from scratch.

- The server's home is `~/CandyWrapper-research/sandbox-4928-ref/t3home`. It ran on **http://127.0.0.1:47404**. The bearer token for scripts is in `sandbox-4928-ref/session.token` (mode 0600) and its log is `sandbox-4928-ref/server.log`. No credential is committed.
- I started it with `scripts/sandbox-server` through `env -i`, with `SANDBOX_DIR=~/CandyWrapper-research/sandbox-4928-ref`, `SANDBOX_PORT=47404` and `T3_BIN=sandbox-4928-ref/t3-wrapper`. The wrapper runs `runtimes/t3-0.1.11-nightly.20261119.4928-darwin-arm64/t3` with `ZDOTDIR=sandbox-4928-ref/zdot`.
- T3 names the environment after `scutil --get ComputerName`, which is this Mac's hostname (`ServerEnvironmentLabel.ts:155-215`). The `.zshrc` in `zdot` puts `sandbox-4928-ref/fakebin` first on the PATH T3 reads from the login shell, and its `scutil` answers "Sandbox Mac" for that one query. The same file sets the terminal prompt to `%1~ %#`, so 11 shows `demo-repo %` instead of the account and host.
- The project is `demo-repo` at **`/Users/Shared/cw-sandbox-4928/demo-repo`**, outside the home folder. Tool rows print absolute paths, and a path under the home folder shows the account name. The repo has `hello.py`, `notes.md` and `README.md`, one commit by `Demo <demo@example.com>`, and the notes turn's two uncommitted edits.
- Thread IDs are in `plans/sandbox-ids.json`.

### Model turns

The user approved up to 10 real turns on Claude Haiku 5.5. I used all 10. `plans/seed.py` writes the seed plans, and a guard clears the prompt unless Haiku is selected.

1. Markdown reply with no tools (03a to 03c, and the backdrop of most states).
2. `ls`, `git status --short` and `ls /nonexistent-dir` (03d, 62).
3. AskUserQuestion, left unanswered (06).
4. A Supervised file create. It printed the repo's old path under the home folder, so I deleted that thread and moved the repo.
5. Edits to `hello.py` and `notes.md` (09, 10, 22, 47, 48, 60).
6. The Supervised file create again, left waiting for approval (05).
7. A Low-effort follow-up in the notes thread with an image and a text file. It added a notice that printed the old working directory, so I rolled the thread back to turn 5 with `checkpoint.rollback` (`restoreFiles: false`).
8. The first lighthouse story. My killed trial run had left the sidebar collapsed in the browser profile, so its 01 and 29 were discarded. Its two steers became the burst in 57. After Stop the run kept working in the background, so the image and file I sent next joined it as a steer.
9. The second lighthouse story, for 01 and 29 (`plans/running.json`). It finished on its own after the queued notes were removed.
10. A Low-effort message with `sky.png` and `todo.txt` and no text, in the turn 9 thread (56).

No turn was spent on side chats. 62 shows the side chat panel before a question.

### Built without a model

I made these through RPC with `sandbox-4928-ref/tools/rpc` (`orchestration.dispatchCommand` and `projects.mutate`):

- The project and its move to `/Users/Shared`.
- "Plan release notes", settled.
- "Tidy the README", snoozed until 2027-01-04.
- "Old experiment", archived, so 35 lists one thread.
- "Scratch idea", which 61 settles from its row and then undoes with Cmd+Z.
- The markdown thread's permissions, set back to Full access after turn 1 ran Supervised.

## Repeating the run

```sh
swiftc design/reference-4928/plans/capture-reference-extended.swift -o ~/CandyWrapper-research/sandbox-4928-ref/capture-4928
python3 design/reference-4928/plans/gen.py
design/reference-4928/plans/capture-all.sh
```

`gen.py` loads the 3824 plans, swaps in the new IDs and port, changes the composer selectors and writes the 4928 states. `capture-all.sh` runs `main`, `narrow`, `diff-turn`, `extras`, `composer` and `new-4928`. Then it sets up the branch notice for 51, runs `notice.json`, restores the repo and thread, runs `error.json` without pairing and copies the `-3473` aliases. It writes `manifest.csv` last. `running.json` costs two turns, so the script leaves it out. Run it only with the user's approval.

`run.sh` mints a pairing URL with `env -i <runtime> auth pairing create --base-dir sandbox-4928-ref/t3home`. The profile is `sandbox-4928-ref/chrome-4928-profile` and the DevTools port 9461. `CAPTURE_PROFILE`, `CAPTURE_PORT`, `CAPTURE_BIN` and `CAPTURE_TEXT_DIR` work as at 3824.

The runner is the 3824 one with three changes. It finds the pinned Chrome under `~/CandyWrapper-research/tools` and adds `until` (wait for a JS condition), `upload` (`DOM.setFileInputFiles`) and `rightclick` actions. Every fresh state now begins with a layout reset that opens a collapsed sidebar and closes a pinned thread details card. Without it, 31's Cmd+B and 21's details card leaked into later states.

## Differences from 3824

- The model and effort live in one control, and clicking it opens the docked picker: models on the left, effort levels on the right, Speed, Ultracode and Permissions in the footer (`ComposerControlsBar.tsx:195-250`, `ProviderModelPicker.tsx:158`, `ComposerModelEffort.tsx:686-726`). 13 opens it by click, 41 and 53 with Cmd+Shift+E, and 42 with Cmd+Shift+A. All four show the same popup with focus in a different column. 55 opens its Permissions menu.
- 27 is the new Welcome page (`components/onboarding/WelcomePage.tsx:129`), not the three-step wizard.
- The thread details card (21, 44, 50, 60) shows environment, Open in Finder, project script, branch, Commit and Changes. Appearance chooses its sections (59, `settings/ThreadDetailsItemsRow.tsx:17-44`).
- Settings has new sections: Chat, Diffs & pull requests, Voice, Threads, Devices, Worktrees, Sharing & access, Labs and About. "Environments" and "Archive" keep their labels.
- The sidebar shows Working, Snoozed and Settled shelves in its footer.
- The data differs from 3824's seed: thread titles, reply text, the diff and relative ages.

## Captured states

Both themes unless stated. Stems omit `.dark.png` and `.light.png`.

| # | Files | State | How | Notes |
|---|---|---|---|---|
| 01 | 01-running-turn | Running turn | `running.json`: new draft, Haiku Medium, Full access, send the story prompt | Turn 9. Thinking row and Stop |
| 02 | 02-sidebar-populated | Sidebar | Open the markdown thread | Done, Approval, Input, Working, Snoozed and Settled |
| 03a-c | 03a-kitchen-sink-top, 03b-kitchen-sink-middle, 03c-kitchen-sink-bottom | Markdown reply | Scroll to 0, 50% and 100% | Headings, table, task list, three code blocks, Note alert |
| 03d | 03d-kitchen-sink-commands | Commands | Open the commands thread | Collapsed Worked row |
| 04 | 04-new-thread-draft | New draft | Open `/` | Default 6 Astra. No turn used it |
| 05 | 05-approval-request, 05-approval-request-3473 | Approval | Turn 6, left pending | Supervised `printf` under `/Users/Shared` |
| 06 | 06-user-input-request | Question | Turn 3, left unanswered | Language question, four choices |
| 07, 08 | 07-palette-default, 08-palette-search | Palette | Cmd+K, then `hello` | |
| 09, 10 | 09-diff-split, 10-diff-unified | Diff panel | Cmd+D, Split or Stacked, expand files | hello.py +1 and notes.md +1 |
| 11 | 11-terminal-drawer | Terminal | Cmd+J | Prompt `demo-repo %` |
| 12 | 12-right-panel-files | Files | Cmd+Alt+B, Files | Tree only |
| 13 | 13-model-picker | Docked picker | Click the model control | Claude tab, Haiku selected, Medium |
| 14, 15 | 14-composer-slash-menu, 15-composer-at-mention | Composer menus | Type `/` or `@hel` | The slash menu lists the commands installed on this Mac |
| 16a-c | 16a-settings-general, 16b-settings-general-mid, 16c-settings-general-bottom | General | Settings modal, scrolled | |
| 17-19 | 17-settings-appearance, 18-settings-providers, 19-settings-keybindings | Settings pages | Settings modal | 18 scrolls past account status |
| 20 | 20-sidebar-thread-context-menu | Thread menu | contextmenu on the markdown row | |
| 21 | 21-git-actions-menu | Git menu | Details card, Git action options | |
| 22 | 22-commit-dialog | Commit dialog | Notes thread, details, Commit | Nothing committed |
| 26, 26b | 26-usage-limits, 26b-usage-cost, 26b-usage-tokens | Usage | `/usage`, no providers selected | Empty data, no account history |
| 27 | 27-welcome | Welcome page | `/welcome` | "Setting up Sandbox Mac" |
| 29 | 29-queued-messages | Queued messages | Turn 9, alternate submit twice | Both removed before they ran |
| 31 | 31-sidebar-collapsed | Collapsed sidebar | Cmd+B | Restored after capture |
| 32-40 | 32-settings-source-control, 33-settings-projects, 34-settings-connections, 35-settings-archived, 36-settings-scheduled-tasks, 37-settings-snapshots, 38-settings-storage, 39-settings-diagnostics, 40-settings-integrations | Settings pages | Route or modal | 32 is "Source control & issues". 35 lists "Old experiment" |
| 41, 42, 53 | 41-traits-picker, 42-access-mode-picker, 53-effort-menu-permissions | Docked picker | Cmd+Shift+E, Cmd+Shift+A | Same popup as 13 |
| 43-46 | 43-find-in-thread, 44-thread-details-panel, 45-go-to-file, 46-project-search | Find, details, go to file, search | As at 3824 | |
| 47, 48 | 47-changed-files-card, 48-diff-turn-file, 48-diff-turn-file-3473 | Changed files and turn diff | `diff-turn.json` | |
| 03n, 04n, 11n | 03n-kitchen-sink-narrow, 04n-new-thread-narrow, 11n-right-panel-narrow | Narrow | 800 CSS px | |
| 49, 50 | 49-settings-modal-general, 50-floating-thread-settings | Settings modal, details card | `extras.json` | |
| 51 | 51-composer-branch-notice | Branch notice | Thread branch `main`, checkout on `reference-banner`, `vcs.refreshStatus`, unsent draft | Restored after capture |
| 52 | 52-connection-error.dark | Pairing error | Invalid pairing token, fresh profile | Dark only, as at 3824 |
| 54 | 54-composer-effort-bars | Effort bars | Appearance, Effort display, Bars | Restored to Word |
| 55 | 55-picker-permissions-menu | **New.** Picker footer Permissions menu | Click the model control, then Permissions | Four modes with icons |
| 56 | 56-model-switch-media | **New.** Model switch row, image and file card | Turn 10 thread, scrolled to the Medium → Low row | Image above the bubble, `todo.txt` card |
| 57 | 57-user-message-burst | **New.** Two steers in a row | Turn 8 thread, scrolled to the steers | One Steer label, joined corners, both marked cancelled by the Stop |
| 58 | 58-issues-page | **New.** Issues page | `/issues` | "No trackers to read": the sandbox repo has no remote |
| 59 | 59-settings-thread-details-items | **New.** Thread details sections | Appearance, open the Thread details menu | 10 of 12 on, Usage limits and Context window off |
| 60 | 60-thread-details-notes | **New.** Details card on the notes thread | Toggle thread details | Uncommitted +2 -0 |
| 61 | 61-sidebar-undo-notice | **New.** Undo notice in the sidebar footer | Settle "Scratch idea" from its row, Cmd+Z after | At this width the notice shrinks to its undo icon |
| 62 | 62-side-chat-panel | **New.** Side chat panel | Commands thread, Cmd+Alt+B, Side chat | Empty side chat with "Context from Run Shell Commands" |
| 64a, 64b | 64a-scheduled-task-once-top, 64b-scheduled-task-once | **New.** New task editor, Once | Settings, Scheduled tasks, New task, fill name and prompt, Once, run on 2026-12-01 09:00 | Not saved |

## Hostname, account and e-mail

The visible text of every capture, written with `CAPTURE_TEXT_DIR`, contains neither this Mac's hostname, nor its account name, nor an e-mail address.

39 (Diagnostics) has the Claude agents' command lines further down the page, with `--add-dir` paths under the home folder. The captured scroll position ends above them, so the image does not show them.

The server config still carries the hostname, the account name and the provider account e-mails (`hostname`, `remoteOpenTargets`, provider auth). None of the captured pages render them. A state that opens provider account status or remote-open targets would show them.

## Limitations

- The Claude agent on this Mac reads the user's own `~/.claude` setup. The story turn's thinking line mentions the user's style guidelines.
- Relative ages, Working seconds, diagnostics counters and the slash menu's installed commands are not frozen.
- 41, 42 and 53 show the same docked popup as 13, since 4928 has no separate effort or mode menu.
- The notes thread's collapsed work rows hold absolute paths under the home folder from before the move. No capture expands them.
- 57's steers are marked cancelled because Stop came before Claude confirmed them. Two warning rows follow.

## Not captured

- Thread tags. 4928's web client has no tagging UI. Tags come from `thread.tag.set` (`orchestrationV2.ts:3226-3232`) and only hide threads while recording, which is desktop only.
- A side chat with a reply. It needs an 11th turn.
- A populated Issues page. It needs a repository on a supported tracker and a signed-in account.
- 52 light, as at 3824. The unauthenticated page stays dark.
- 23 to 25, 28 and 30, as at 3824.
