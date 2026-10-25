# Space reminder notifications

Piece 17 of [the Space plan](space.md), section 6. `SpaceReminderController` in Features consumes `SpacePlanning.ReminderPlanner`; it does not calculate a second set of dates. The planner stays Foundation-only. `SpaceNotificationCenter` is the test seam; its system implementation uses `UNUserNotificationCenter`.

## Setting one

A to-do's date menu has Remind me… once it has a date. It asks for a time on the due day and writes `{"at": "YYYY-MM-DDTHH:MM"}`; Remove reminder clears it, and the date label shows an alarm clock while one is set. Added on 2026-10-25 in the release check, since nothing in the app wrote `remind` before. The table can't set reminders yet.

## Scheduling and withdrawal

The app enables reminders after the encrypted local store opens, even while the Space pane is hidden. An enabled cold launch keeps existing OS requests and delivered reminders during loading; loading is not a switch-off transition. It reconciles the complete plan at startup, on store changes, foreground delivery, activation, wake, day changes and system time-zone changes. One one-shot timer at the next scheduled fire refills the plan while the app runs. No polling runs at idle. macOS owns the requests and delivers them while CandyWrapper is closed, within the planner's 50-request, 30-day window.

Each request preserves the planner's identifier and exact calendar components. Timed components keep their zone; date-only components keep neither a zone nor an embedded calendar. Titles show the item title. Bodies show the item's time in the device's zone, using the current locale; a date-only item has no time, and its reminder can fire at any hour, so its body names the day, like "Mon 26 Oct". The first reminder, including one beyond the planning window, asks for permission if its status is undetermined. Denial schedules nothing; activation checks permission again.

Reconciliation compares pending requests and adds only new or changed requests. It withdraws obsolete pending requests and invalid delivered notifications, including changes to dates, titles, parent titles, completion, removal and ancestor trash. A SHA-256 digest detects item changes across launches without putting the encrypted record into notification metadata. Turning Space off, or leaving Redesign, removes all pending and delivered `space.` notifications. Cold startup with Space off does the same without opening its key or files. Other notification ids remain untouched.

Notification text is stored by macOS outside Space's encrypted files, as the user accepted in the plan. No key or full page contents enter notification metadata.

## Delegate and actions

`ThreadNotificationCoordinator` remains the single system delegate, including when thread desktop notifications are off. It hands only `space.` requests to Space. An immutable `SpaceReminderResponse` copies strings out of Apple's non-Sendable notification objects before crossing to the main actor. Thread notifications keep their original navigation, badge, sound and foreground behavior. The source for that behavior is T3's `apps/web/src/components/ThreadNotificationCoordinator.tsx:215-237`.

A click activates the main window and opens the item. Mark done writes `props.done` through the document store's apply path and awaits the encrypted writer's flush before the response completes. The notification delegate waits for any in-flight local-store open before handling a cold-launch response. Stale, disabled, malformed or unrelated responses cannot edit an item.

Snooze 10 min schedules a device-local time-interval request. It does not edit or sync the page. Its request survives relaunch through the system notification center, shares the plan's 50-request limit, and is withdrawn when its item changes. Category registration preserves other categories.

## Validation

The focused tests exercise planner-to-calendar mapping, localized text, floating and pinned zones, idempotent scheduling, the request cap and refill, pending and delivered withdrawal, cold disabled cleanup, permission denial, edits during permission and scheduling, open and stale actions, repeat snoozing and encrypted persistence of Mark done. They run against an in-memory notification center, never the system center.

The isolated Debug app accepts `--space-reminder-fixture` only with a `dev.candywrapper.test.` bundle id and an empty local copy. After the normal recovery acknowledgement it creates a checklist item due in two minutes. The fixture uses the same persistent store, planner, center, delegate and actions as real items. Release builds omit it. For notification authorization on this Mac, copy the built test app outside `/tmp`, ad hoc sign it and register it with LaunchServices, as described in `docs/gotchas.md`. Persist the test bundle's `CandyDevServer`, `CandyDevTokenFile`, `CandyT3Home` and `CandyDevFakeConnect` defaults before testing notification-driven relaunch, so it stays on the sandbox.

## On-screen check on 2026-10-25

The isolated app created “Check the Space reminder” due at 01:59, about two minutes after setup, against the sandbox on 47391 with fake T3 Connect. Notification permission was granted for that test bundle. The app quit before the due time. macOS delivered the title and “Reminder check · 01:59” while it was closed; Notification Center exposed Mark done and Snooze 10 min. Mark done launched the registered test app with no command-line arguments. Its delegate waited for the encrypted local copy, applied Done and flushed it. The checklist tick and zero remaining to-dos appeared, and stayed after another quit and relaunch. The delivered reminder disappeared.

Screenshots, outside the repository, under `~/CandyWrapper-research/notes/space-17-reminders/`:

- `reminder-closed.png`: the delivered reminder while the app was closed.
- `actions.png`: the expanded reminder with both actions.
- `done.png`: the checked item after Mark done.
- `done-after-relaunch.png`: the same saved tick after another launch.

The test app was unregistered and deleted, along with its separate local files, Keychain item, defaults and Debug build. The user's app and live T3 home stayed untouched.

Diff review checked delegate ownership and Swift 6 handoff, request identity and time zones, the off and cold-launch paths, permission and scheduling races, encrypted action completion, stale response validation, category preservation and the 50-request cap. It found one reconciliation defect before push: removing an old delivered version also removes a current pending version with the same identifier. Reconciliation now re-adds a desired request whose id was withdrawn; a dedicated regression test preserves that pending version.

The complete retry passed 2,160 Swift Testing tests and 18 XCTest tests. The final fast retry passed 1,979 Swift Testing tests and 18 XCTest tests, including all 12 reminder tests. An earlier serial full run reached its 30-minute limit under shared build load without an assertion failure. One fast run hit the unchanged `FrameDecoderTests.deliversNewestFrame` timing assertion: it delivered width 40 but more than two intermediate frames. The subsequent full and fast runs passed that check without decoder changes. No reference ceiling was raised.

The [performance review](perf/2026-10-25-90b4c8e-dirty-w1.md) combines the app scenarios and 48 Release micro-benchmarks against the last saved local-wiring run. No metric crosses a regression threshold. One launch per scenario measured 0.059% idle CPU and 42.9 MB footprint; the first idle quiet wait expired, so this is a noisy comparison, not a clean attribution control. App scenarios kept Space off and preceded the final permission and quit guards. These guards affect unfinished reminder work; Space's active workspace budgets still belong to piece 19. The benchmark launcher repeated its build, as in the earlier local-store review, so measurement used the same prebuilt Release test binary through `scripts/test --skip-build`, with the workload and thresholds unchanged.

Quit now drains pending scheduling and withdrawal after encrypted writes. It does not start or wait for a notification permission prompt. A cancelled quit resumes normal planning. Dismissing a reminder does not request a background app launch; only its explicit actions do. Gate-controlled tests cover scheduling still in progress at quit, withdrawal, and both permission cases.

## Final rebased app check

After rebasing the Board, Timetable and Orchestrator changes from main, the isolated Debug app built successfully. Its fixture uses UTC internally so a two-minute check remains unambiguous during the repeated daylight-saving hour, while the body shows local time. The reminder due at 02:57 CET fired while the app was closed. Reopening the app kept the unchanged delivered reminder. After quitting again, Mark done launched the app, checked the item and saved it; another relaunch kept the tick. The test app, its files, Keychain item and Debug build were removed, and the screen lock was returned.

Current screenshots under `~/CandyWrapper-research/notes/space-17-reminders/`: `final-reminder-closed.png`, `final-preserved.png`, `final-actions.png`, `final-done.png` and `final-done-after-relaunch.png`. The rebased fast lane passes 2,024 Swift Testing tests and 18 XCTest tests, including all 14 reminder tests and the quit handoff. The final serial full suite passes 2,205 Swift Testing tests and 18 XCTest tests with no failures. The parallel run exposed the existing shared-state risk: Files fidelity averaged 52.32% difference in parallel, then 1.44% in the passing serial run, with no file UI or ceiling changes. The follow-up is recorded in PROGRESS.md.
