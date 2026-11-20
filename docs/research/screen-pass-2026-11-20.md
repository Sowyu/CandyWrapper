# Screen pass, 2026-11-20

The first look at the Nightly 4928 port in a real window, on branch `screen-pass` from `catchup-4928` (8b1ecd8f). Images live in `~/CandyWrapper-research/sandbox/screen-pass-2026-11-20/`.

## Build fix

`1bc5ebfa fix(app): load Issues pages with one main-actor task per host` makes `scripts/build-test-app` pass with Xcode 27.2. `IssuesPageController.reload` used a task group whose `@MainActor [weak self]` children tripped the region-based isolation checker at `IssuesPage.swift:262`. Each host now loads in its own main-actor `Task`, and a `pendingLoads` count clears `loading` when the current generation's last host answers. No other build error showed.

## Checklist

Collected from the "could not check on screen" lines of every PROGRESS.md entry dated 2026-11-19, plus the items the task brief names.

Thread, from thread-messages, thread-markdown, look-4928 and composer-3:

- Message bursts from two quick sends, 4pt apart and joined.
- The model or effort switch divider above a message.
- Stop shows "Stopping…", Resume ignores clicks for 500 ms, hides while a request is pending, Enter on an empty prompt resumes.
- A steer keeps the final answer, and a queued message can steer.
- Media and file cards in sent messages, the quote card and its hover.
- The `★ Insight` callout.
- Inline-code file chips and their hover.
- The viewed-images row and the image viewer stepping.
- The reply button and the reply banner, reply cards and model chips in sent messages.
- The fresh-session banner slot.

Composer, from composer-pickers, composer-3 and composer-rest:

- The model and effort trigger, one control.
- The docked model picker, its side menus and keyboard flow.
- `/clear`.
- List editing with Tab and Shift+Tab.
- @-mention a model.
- The prompt suggestion.
- Send while an upload is running, and expired upload recovery.

Sidebar, from sidebar-4928 and look-4928:

- The undo notice in the footer's utility row at narrow widths, and its hover.
- The title glimmer.
- Folder drop, the rename field, the project filter notice.
- The snooze menu and dialog.
- The issue badge.

Settings, from settings-4928:

- The thread details items row.
- Scheduled tasks with a one-time schedule and its calendar.
- Connections.
- Keybindings Unassigned.
- Tool calls hidden.

Other surfaces:

- The thread details card with its usage and context sections and right-click menu.
- Dialogs.
- The Issues page, its empty "No trackers to read" state and its menus (issues).
- The message rail at rest and hovered, and its exits (rail-fix, rail-colors).
- The reconnecting banner after network changes and sleep, a T3 Connect session past the hour, a send that fails after 60 s (connection). These need a network change or an hour, so this pass does not reach them.

App checks from docs/nightly-catch-up.md step 9: send one tiny turn, toggle the sidebar fast, open Settings and the command palette, in both default themes.
