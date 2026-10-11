# WP7.10b thread leftovers, 2026-10-11

Worktree: astra-wp710b. This is partial work for review, not finished parity. No commits.
Official references below are relative to `/Users/mrm/CandyWrapper-research/t3code`.
`comp/` means `apps/web/src/components/`; `web/` means `apps/web/src/`.

## Implemented and remaining

| Rows | Official evidence | Result and remaining work |
| --- | --- | --- |
| 75 | `apps/web/src/index.css:2076-2084` | Shared 736/1152/full width for timeline and composer, responsive gutters, settings observation. Built. |
| 76 | `comp/chat/ChatHeader.tsx:58-73,179-216` | 500ms title-click menu, double-click and menu Rename, trimmed commit, Escape and thread-change cancellation. Reuses sidebar commands. Missing hover chevron, exact menu composition, empty-title toast and title fidelity states. |
| 77 | `comp/chat/ChatHeader.tsx:217-290` | Existing OpenInController and ProjectScriptsController already put controls in the details card. Audit notes were stale. Exact header placement remains partial. |
| 132 | `comp/chat/ThreadFindBar.tsx:27-122`, `comp/chat/useThreadFind.ts:53-250,315-360`, `packages/contracts/src/orchestrationV2.ts:3505-3551`, `apps/server/src/orchestration-v2/ThreadFind.ts:100-113` | Native 384x36 bar; existing chat.find registration, server query after 100ms, next/previous, Return/Shift-Return, Escape, retry and cancellation. Paints text-box matches without reconfiguring timeline rows; expands matching run/attempt and long message, asks for earlier history. Missing progressive responses/live refresh, selected occurrence, tool/code/chip coverage, restoration of temporary folds and reliable deep-history navigation. Unary result exposes count/index/entry/occurrence; only entry is used for scrolling. |
| 133 | `docs/user/composer.md:128-145`, `web/session-logic.ts:1045-1068`, `packages/client-runtime/src/operations/commands.ts:872-916`, `comp/ChatView.tsx:8380-8515,12035-12077`, `packages/contracts/src/orchestrationV2.ts:2974-2982` | Hover edit, previous ready checkpoint including baseline, confirmation, rollback command, keep files or worktree-only restore files. Retains unsent draft above restored prompt. Refuses attachment/context prompts before mutation. Missing staging/reupload, fork flow and exact eligibility visibility. Confirmation waits at most 10s during the operation; no idle polling. Thread switching after command acknowledgement restores the inactive draft without observing message removal there. Needs event-driven confirmation per scoped thread before complete parity. |
| 120 | `comp/chat/ComposerPlanFollowUpBanner.tsx:1-25`, `web/proposedPlan.ts:54-77`, `comp/ChatView.logic.ts:938-952`, `web/session-logic.ts:308-326`, `comp/ChatView.tsx:10472-10498`, `comp/chat/ComposerPrimaryActions.tsx:220-259` | Plan ready banner and Implement/Refine action. Empty draft implements exact plan prompt, default mode and sourcePlanRef; entered text refines in plan mode. Missing new-thread split action, plan menu, precise item-time sorting, exact banner icon slot and visual states. |
| 137 | `web/lib/contextWindow.ts:26-176`, `comp/ChatView.tsx:1718-1732,7421-7475,7660-7682`, `comp/chat/ContextWindowMeter.tsx:42-211`, `comp/chat/ContextWindowMeter.logic.ts:13-18` | Stream-driven 28pt control, 20pt ring, usage priority and token formatting, warning above 90%, popover, manual /compact. Keeps draft/attachments. Missing hover trigger, custom threshold wording, progress accessibility, exact popover and runtime/interaction persistence on standalone commands. No timer or idle animation. |
| 126-128 | `packages/client-runtime/src/state/threadExecution.ts:392-439`, `comp/chat/UsageLimitRecoveryBanner.tsx:21-85`, `comp/ChatView.tsx:7502-7541,7757-7777`, `packages/contracts/src/orchestrationV2.ts:339-359,2751` | Usage-limit failure enables existing Resume. Recovery metadata updates preserve omitted options. Goal status/objective/budget/time/checks and Resume/Clear. Remaining: pending actions, stoppedAt/reset/snooze state details, one-shot reset refresh, exact duration and standalone mode persistence, banner fidelity. |
| 141 | `comp/chat/workspaceFileDrop.ts:33-90`, `comp/chat/folderDrop.ts:1-30` | Whole panel accepts files through existing composer attachment handling. Missing drag overlay, folders as mentions and remote-host routing. |

## Researched rows not completed

These need separate implementation work. Existing behavior is retained, and checklist statuses stay partial or pending.

| Rows | Official evidence | Remaining |
| --- | --- | --- |
| 80 | `comp/chat/MessagesTimeline.tsx`, `comp/composerInlineChip.ts` | Inline chips, file preview/download and video shelf. Existing image/file rows retained. |
| 90, 112 | `comp/chat/V2ItemInspector.tsx:222-285` | Rich detail blocks, JSON/search links and Open diff. Existing details and ChangedFilesCardView do not add inline patch rendering here. |
| 91 | `comp/chat/WorktreeSetupCard.tsx:334-397` | Running stages, terminal script tail, failed/cancel/retry and completed collapse. Requires setup-operation projection wiring; not added. |
| 98 | `comp/chat/ProviderStatusBanner.tsx:19-113` | Already built in WP7.11 through ProviderStatusBannerLogic. Corrected stale pending checklist status. |
| 103 | `comp/chat/ZoomableImage.tsx:18-81`, `comp/chat/ExpandedImageDialog.tsx:72-126` | Existing sent-image dialog retained. Markdown image loading/gallery, pan/zoom parity and gallery keyboard wrapping still need work. |
| 104 | `comp/media/MediaVideoPlayer.tsx:31-76`, `comp/media/MediaActions.tsx:116-155` | Inline audio/video and scoped media actions; preserve playback URL/playhead while refreshing credentials. Existing AVKit file tabs are not inline media. |
| 105 | `comp/chat/externalLinkContextMenu.ts:87-116`, `web/markdown-links.ts` | Existing file/external link handlers retained. Editor modifiers, chip reveal/open, integrated browser and favicon details remain. |
| 107, 110 | `comp/chat/AssistantCitationChip.tsx:34-75`, `comp/chat/AssistantSelectionToolbar.tsx:21-65` | Selection range/source mapping, quote toolbar, citation comment persistence and rendering need a shared model. Not added. |
| 108 | `comp/chat/SkillInlineText.tsx:8-55`, `comp/chat/ShellCommandBlock.tsx:61-83` | Skill matching outside links/code and shell control-character/highlighting behavior. |
| 114 | `comp/chat/ComposerTasksBadge.tsx:1-50,102-222` | Plan-step badge, segment count/durations, details and tasks drawer. |
| 122 | `comp/PermissionUpdateNotice.tsx:20-75` | Once-per-environment successful legacy-session notice, durable dismissal, Open Connections action. |
| 130 | `comp/chat/timelineMinimapItems.ts:11-77` | User/last-assistant pairing and lazy hover previews; needs native scroll-position marker layout. |

## Verification

- Full `swift test --package-path Packages/CandyKit`: 882 tests total, 881 passed. T3Store 262, protocol 96, features 318, design system 82 passed. T3Client 123/124 passed; `LocalServerIntegrationTests.launchAuthenticateConnectStopRestart` failed at line 44, “expected a server we own”. The unchanged test uses a shared `sandbox-localserver` home across worktrees. A concurrent discovery race is plausible but not established. No server was stopped to force a passing result.
- After final logic changes: all eight ThreadLeftoversTests pass. Rewind test has explicit baseline/previous/current checkpoint fixtures and missing-baseline rejection.
- New fidelity: 14 cases, mean 2.39%, worst 4.25%. Find empty/matches/no-results/loading and ring 0/25/95, light and dark. These numbers cover those controls only, not the full thread or the partial banners. Full suite includes all existing fidelity tests, which passed.
- Required isolated xcodebuild succeeds. Bundle `dev.candywrapper.test.astra710b`, scheme `candywrapper-astra710b`, derived data `/tmp/cw-dd-astra710b`.
- Native on-screen checks against existing sandbox server PID 32675: title actions menu, context popover showing 3.9%, 39k/1m and Compact context, and Cmd+F showing unsupported-server notice. Server version `0.0.46-nightly.20261009.2861` does not advertise `threadFind`, so search RPC/highlight navigation could not be checked live.
- No real turn, rewind, rename, compact or recovery mutation was sent. No sandbox project/file was created for UI checks. No macOS permission dialog appeared. Own app PID 10717 was stopped, existing sandbox server retained.
- The existing integration test reads the installed runtime path and creates its shared test home before discovering another server. This was only discovered after the required full-suite run. It was not rerun. Other verification uses the existing sandbox and explicitly selected headless Chromium; no live server mutation was performed.

Reference generation adds `CANDY_REFERENCE_CHROME` to the existing capture script, allowing an explicit sandbox Chromium path without inspecting the live installation. No new key monitor, agent, or T3 MCP call was introduced.
