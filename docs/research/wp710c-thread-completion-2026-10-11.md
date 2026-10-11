# WP7.10c thread completion, 2026-10-11

Implementation lives in the astra-wp710c worktree. No commits were made. Broad checklist rows remain partial; the implemented controls do not establish full thread parity.

## Source and implementation

Paths below are relative to the read-only official checkout `/Users/mrm/CandyWrapper-research/t3code`. `comp/` means `apps/web/src/components/`.

| Checklist row | Official source | Implementation and remaining work |
| --- | --- | --- |
| 132, find | `packages/contracts/src/server.ts:687-688`; `comp/chat/ThreadFindBar.tsx:43-50`; `comp/chat/useThreadFind.ts:130-245` | Decode top-level threadFind/threadFindProgressive flags. Consume progressive results, fall back to unary search, cancel stale subscriptions, refresh after pushed changes, keep selection while counting, highlight the selected Markdown text occurrence and restore find-opened folds. Existing sandbox supports this; the earlier negative conclusion came from client capability decoding. Remaining: tool/code/chip highlights, robust paging/reveal of old matches and complete fidelity coverage. |
| 133, prompt rewind | `comp/ChatView.logic.ts:743-778`; `comp/ChatView.tsx:8380-8515` | Download signed attachment bytes and upload fresh copies before checkpoint.rollback, as required by this brief. The official path stages downloads before rollback and registers uploads later through its draft store. Re-key only matching context links, preserve unrelated context and the unsent draft, suppress image-only bootstrap text. Retain provider/busy/checkpoint/upload guards and recheck before mutation. A scoped subscription waits for the source prompt before dispatch and its removal afterward; bounded deadlines replace repeated polling. Before dispatch, failures remove staged uploads/files. After an ambiguous dispatch, preserve the recovered draft rather than deleting its only bytes. Remaining: fork variant, exact eligibility/visibility and old-source paging. |
| 90, inspector | `comp/chat/V2ItemInspector.tsx:222-425` | Add safe web result links/snippets, file result previews, syntax-highlighted structured JSON and Open diff using the existing diff callback; preserve failed patch detail. Remaining: full rich block layout, inline patches and scrollable long bodies; current body is capped at 320 points. |
| 104, media | `comp/media/MediaVideoPlayer.tsx:31-125`; `comp/media/MediaActions.tsx:116-155` | User audio/video attachments offer Play and Save. Resolve signed URLs with the existing asset RPC. AVPlayerView is created only after Play while the actual viewport and window are visible, and released on scroll-out, occlusion, recycle or detach. Remaining: Markdown embeds, thumbnails, web-matched controls, all context actions and playback error states. No background polling. |
| 107, citations | `packages/shared/src/assistantCitations.ts:38-112`; `packages/contracts/src/assistantCitations.ts:4-35`; `comp/chat/AssistantCitationChip.tsx:34-75`; `comp/chat/AssistantCitationCommentEditor.tsx` | Strict URL/UTF-16 offset and length validation, serializer, collapsed quote/comment labels, composer chips and a comment editor reached by double-click. Markdown links show quote labels and a quote/comment dialog; source opens the thread and reveals an already loaded entry. Remaining: selection-to-quote creation, anchored popovers, deep source paging, Save-and-send and exact chip decoration. Comment UI is deliberately a dialog until selection mapping exists. |
| 114, tasks | `apps/web/src/session-logic.ts:260-281,631`; `comp/ChatView.tsx:2469-2476`; `comp/chat/ComposerTasksBadge.tsx:13-222` | Latest todo_list plan supplies badge count, segmented progress, summary and bounded expanded task list. Official timeline suppresses standalone todo items, so none was invented. Remaining: wrapped task labels, exact status icons, duration formatting and all visual states. No idle elapsed-time timer. |
| 130, minimap | `comp/chat/timelineMinimapItems.ts:15-77`; `comp/chat/MessagesTimeline.tsx:1785-1934`; `comp/chat/MessagesTimeline.logic.ts:288-479` | Pair each user entry with its last assistant response, strip hover widths, current marker, click and local keyboard navigation. Structural changes rebuild the lightweight index; streaming updates locate the owning entry. No new key monitor or idle animation. Remaining: native tooltip replaces rich preview, no narrow-gutter reveal or previous/next controls, and viewport bands differ. |
| 91, setup | `packages/contracts/src/worktreeSetup.ts:34-121`; `comp/chat/WorktreeSetupCard.tsx:334-438`; `comp/ChatView.tsx:3976-4077` | Thread-scoped subscribeWorktreeSetup, monotonic snapshot sequence, stage/status/progress, bounded log tail, Details, worktreeSetup.cancel and existing terminal drawer selection. Remaining: recorded fallback, retry/work-locally, complete logs/durations, exact timeline placement and retirement after follow-up. |
| 122, permissions | `packages/contracts/src/auth.ts:130-163,195-202`; `comp/PermissionUpdateNotice.tsx:20-75` | Explicit legacy grants trigger one notice per environment using authenticated session data. Persistent dismissal covers close, swipe and Open Connections. Remaining: stacked secondary Dismiss button and visual coverage. |

The existing goal, usage recovery and plan follow-up views were laid out but not mounted in the panel hierarchy. They now join the composer dock. Their other WP7.10b gaps remain.

## Verification

- Whole CandyKit suite: 901 tests passed, including the isolated owned-server lifecycle integration test. Eleven focused logic tests cover capability decoding, progressive identity/count, context re-keying, image-only prompts, citation validity, minimap pairing, tasks, legacy permissions, setup stages and inspector equality.
- Integration tests accept `CANDY_TEST_LOCALSERVER_HOME` and `CANDY_TEST_LOCALSERVER_BINARY`; existing defaults remain unchanged. This run used sandbox/astra710c-localserver/t3home and `/tmp/candywrapper-bin/t3`, avoiding shared lifecycle ownership.
- App build passed with `/tmp/cw-dd-astra710c`, bundle `dev.candywrapper.test.astra710c`, scheme URL `candywrapper-astra710c`.
- Final focused run: 12 tests passed, including the incremental minimap preview assertion. The explicit Fidelity filter passed all 104 tests (43 feature and 61 design-system tests). Final app build and git diff --check passed after the minimap/editor follow-ups.
- Fourteen new reference cases (seven light/dark controls) cover task badges, minimap resting strips and inspector diff actions. Mean pixel error 2.78%, worst 4.48%. These are component cases, not full-thread coverage. Source markup and Lucide SVGs are in `scripts/gen-thread-completion-spec.py`; generated references are in `design/component-reference/thread-completion/`.
- On-screen sandbox search showed selected match 1/10, then Return selected 2/10. Minimap strips were visible. Escape closed find.
- Created sandbox thread `2f865e7e-d755-4cd0-bdf9-e22d93d72295`, titled "WP7.10c attachment rewind sandbox", using one tiny claude-haiku-5-5 turn. Uploaded a 36-byte `wp710c-note.txt`, asked "Reply OK", then entered an unsent draft. Edit/Revert keep changes removed that thread's history and restored its prompt with a fresh ready file chip while retaining the unsent draft. No other thread was rolled back. No recovered prompt was sent again.
- New setup, media playback, citation editing and permission states were not exercised on screen. Their coverage is narrower than the search/rewind path; do not infer otherwise from the successful build or component tests.

Reproduction commands, from this worktree:

```sh
CANDY_TEST_LOCALSERVER_HOME=/Users/mrm/CandyWrapper-research/sandbox/astra710c-localserver/t3home CANDY_TEST_LOCALSERVER_BINARY=/tmp/candywrapper-bin/t3 swift test --package-path Packages/CandyKit
swift test --package-path Packages/CandyKit --filter Fidelity
xcodebuild -project CandyWrapper.xcodeproj -scheme CandyWrapper -derivedDataPath /tmp/cw-dd-astra710c PRODUCT_BUNDLE_IDENTIFIER=dev.candywrapper.test.astra710c CANDY_URL_SCHEME=candywrapper-astra710c build
```

## Side effects and handoff

The shared sandbox server PID 32675 was reused and left running. Only the owned app PID 53926 was stopped. The test thread, its original/reuploaded asset, pending recovered draft, isolated app defaults/cache and owned lifecycle-test sandbox home remain. No macOS permission dialog appeared; the app logged a sandbox-extension warning but continued to render and upload. No real install, service or user thread was modified. Reference captures used the documented build-time headless Chrome workflow. No additional agents or T3 MCP tools were used.

Next work should finish the remaining behavior in each row, add source-matched states for media/citations/setup/permissions, and exercise those states on screen before marking the broad rows complete.
