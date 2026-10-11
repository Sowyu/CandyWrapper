# Milestone 7 code review, second pass

Scope: `git diff d4dee7d 73b439e -- App Packages/CandyKit/Sources` (the right panels and composer sweep, the Settings sweep, the workspace HTML sandbox and the small areas sweep), 2376 added lines, hunted by category with grep and targeted reading like the first pass (`m7-code-review.md`). Verified with `swift test` (whole suite passes) and the app build.

## Fixed

- `Packages/CandyKit/Sources/Features/Settings/SettingsBrowserViewportControl.swift:73`, crash, medium: the default browser viewport's width and height went through `Int(_:)` from a synced setting, so a value like `1e300` trapped when Settings opened. Uses `JSONValue.intValue` now.
- `Packages/CandyKit/Sources/T3Protocol/Domain/Preview.swift:443,458`, crash, medium: a preview stream `pointer` sequence or `control` generation past Int's range trapped. Both read `intValue` and drop the message instead. Test in `PreviewTests`.
- `Packages/CandyKit/Sources/T3Protocol/Domain/Usage.swift:187`, crash, low: same for the usage report's `contractVersion`.
- `Packages/CandyKit/Sources/T3Store/ThreadActions.swift:94`, crash, low: same for a dispatch result's `sequence`.
- `Packages/CandyKit/Sources/Features/Thread/ThreadContextWindowMeterView.swift:116`, crash, low: an auto-compact threshold past Int's range trapped in the details popover; it now falls back to the generic line.

## Left as notes

- `App/Sources/ComposerController.swift:1419`, fidelity, low: a failed fan-out marks every failed model as possibly started. T3 exempts `wasBootstrapThreadDeleted` and `wasBootstrapThreadNotCreated` errors (ChatView.tsx:9566), sends the other models of a retry while one is held, and puts "Open thread" on the toast with "Allow retry" behind a confirm. CandyWrapper holds the whole retry and puts both choices in its dialog.
- `App/Sources/ComposerController.swift:1175`, correctness, low: a send waiting on the `t3.json` read clears `settingsWorkspaceSendPending` when it resumes, even if another draft set it meanwhile. A double send is still blocked by `pendingMessageId`.
- `App/Sources/ComposerController.swift:291`, fidelity, low: published environment themes clear when the primary environment disconnects. T3 keeps them until a capable server sends its own set (serverConfigProjection.ts:30-35).
- Security: every new URL open goes through `SafeExternalURL` or opens in the integrated browser after `PreviewURL.normalize`; `OpenInController.openFile` opens editor deep links built by `OpenInEditors.remoteURL`. No new `Process`, event monitors, timers or polling; `SidebarCheckoutStatus` keeps one VCS stream per hovered checkout for 10 s like T3's idle TTL.
- Leaks: no new block observers or monitors. New `Task`s capture `self` weakly except two short request tasks.
- Wire compatibility: every RPC method added in this range (`device.list`, `orchestration.launchThread`, `projects.readFile`, `projects.searchEntries`, `shell.openInEditor`, `subscribeVcsStatus`) exists in `packages/contracts`.
- Duplicates found while merging the small areas sweep and removed: a second project favicon picker, a second file chip reveal path and a second keybindings warning (see the commit message of 73b439e).
