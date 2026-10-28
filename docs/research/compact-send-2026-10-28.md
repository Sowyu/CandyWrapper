# Compact and send

## Cause and fix

Redesign's split button copied `primary.isEnabled` only in `ComposerView.layout()`. The editor calls `refresh()` on every change, but a short edit need not change its height or request a layout. The regular send button became enabled while both visible split halves kept the disabled state from the empty draft. Send blockers could also leave their old state behind.

Both halves now copy the send state in `refresh()`. A change of primary action requests layout so Stop, Resume and busy states replace the split promptly. Each half uses the shared hover tooltip controller, including on disabled controls, and exposes its explanation as accessibility help. The reason follows the send status, then prompt-length validation, then empty input. An enabled main half explains compaction; the chevron says Send options. No periodic work or polling was added.

The chevron already had an action and the main button already received the editor's current expanded text. Neither needed a new target or draft source. The 3473 `threadStop` capability controls the standalone Stop command (`App/Sources/ComposerController.swift:2351,2604-2606`); compaction reads the selected provider's advertised `/compact` command and continuation group, without a build-number gate. No protocol or capability policy changed.

## Upstream behavior

Checked the source at `v0.1.3-nightly.20261025.3669` in the research checkout:

- `apps/web/src/components/ChatView.tsx:2490-2541` defines manual-compaction availability and the idle offer: an operable, loaded server thread with a project, compactable conversation and an available provider, no active work or request, an enabled idle-compaction setting, stale Claude usage, no held queue and no multi-model send.
- `apps/web/src/components/chat/ComposerPrimaryActions.tsx:266-307,320-326` shows Compact and send when the idle offer is present and full history is off, excluding Resume and queued edits. Sending is blocked by busy, send-disabled, connecting, disconnected or empty-content state. Its tooltip prioritizes the blocker.
- 3669 renders a token chip beside its round send button (`ComposerPrimaryActions.tsx:361-400`). Redesign deliberately retains the earlier split presentation. Its source, commit `655dfbe8ba`, `ComposerPrimaryActions.tsx:269-315`, enables both halves under the same send conditions and offers one item: Send with full history (N tokens). CandyWrapper already implements that action by selecting full history before sending; choosing Compact and send selects compaction again.

The user's existing 400k-token offer threshold and confirmation below 500k remain in place.

## Verification

The new short-edit regression failed before the fix: the regular send button was enabled and both split halves remained disabled. Coverage also checks empty text, attachments without text, loading, uploads, connecting, permission, disconnected environment, unavailable provider, in-flight send, prompt length, recovery, Stop/Resume transitions, opening the real popup host and choosing both send behaviors. Recorded 3473 and 3669 configs plus a simulated 3754 descriptor with an unknown capability verify forward-compatible compaction availability, including without threadStop.

Four `--snapshot` captures of the isolated app connected to sandbox 3669 on port 47397 show Redesign dark with both halves enabled, the open full-history menu, an empty-draft tooltip and an upload-blocker tooltip. They live in `~/CandyWrapper-research/sandbox/compact-send/` as `ready.png`, `menu.png`, `empty.png` and `blocked.png`, with corresponding logs. The sandbox's largest real context was 132k, so a temporary test-app-only setup made the selected thread's usage stale at 423k and supplied the draft or upload blocker. It used the real controller, compaction gate and views; the popup opened through its real accessibility press action. No message or compaction was dispatched. The temporary setup was removed and the app rebuilt successfully. These are direct layer snapshots, so the existing scrolling-content clipping artifact appears in the sidebar and header; the composer, popup and tooltip were checked.

The default concurrent full run hit `MarkdownBackgroundLayoutTests.viewLaysOutInBackground`'s 20-second wait after a main-actor backlog delayed the test to 240 seconds. The seven-test suite passed alone in 1.18 seconds; the same case passed in 0.12 seconds in the serial run. No Markdown code or timeout was changed.

Final verification: `scripts/test --no-parallel` passes 2,273 Swift Testing tests and 18 XCTest tests, including all fidelity checks. The final `scripts/test --fast` passes 2,078 and 18. The production diff was reviewed; the isolated app builds after removing the capture setup. Its build output was deleted and the screen lock returned. Not released.
