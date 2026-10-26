# Composer responsiveness and correctness audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

2026-10-26. Product source at `64bbb242`, branch `t3/composer-send-audit`. No product edits, builds, tests, app launches, screen use, server requests or account access. All findings below are source-traced, not executed reproductions. The opt-in extraction harness is supplied for the parent's execution lane and has not been compiled or run here.

Scope: `App/Sources/ComposerController.swift`, composer send gates and editor ownership, draft launch/restore, queue edits, approvals and answers, attachment upload/staging, machine selection and retry. Image decoding, thumbnails, cosmetic fidelity and energy are outside this review.

Local upstream: `~/CandyWrapper-research/t3code`, checked out at `v0.1.2-nightly.20261021.3473`, matching `T3_VERSION`. Upstream paths below are relative to that checkout. CandyWrapper paths and line numbers below refer to the reviewed product source.

## Findings

### C1. P1: send failure restores the old prompt into a different thread

**Reachable entry:** ordinary Enter or Send, `Packages/CandyKit/Sources/Features/Composer/ComposerView.swift:745-748`, through `ComposerController.swift:302`. Both existing-thread dispatch failure (`ComposerController.swift:1959-1961`) and foreground draft-launch failure (`:1908-1913`) reach `sendFailed`.

**Defect:** `App/Sources/ComposerController.swift:2210-2211` checks only whether the currently displayed editor is empty. It writes failed text into that editor and calls `remember`, which persists against the current `draftKey` (`:1248-1253`). The captured original `key` is used for error reporting, not text restoration. `showThread` explicitly permits navigation and changes the target while a request runs (`:838-851`). Attachments, in contrast, restore to the original key (`:1960`, `:3842-3845`).

**Trigger:** hold A's dispatch response, switch to empty thread B, then reject A's request. B gains A's text and saves it as B's draft; A's text is not recovered to A. Pressing Enter in B can send A's prompt to B's agent/workspace. With attachments, A retains the attachments while B gets references whose records no longer have those uploads in its draft. If B contains text, A's original text is simply not recovered. Transport failures take the same restoration path before the silent return (`:2213`).

**Deterministic parent scenario:** pause/fail the dispatch response for A, call the normal thread-navigation path to B, release the failure, inspect both drafts and the editor. Cover existing threads and foreground first-send launch; repeat with B empty, B typed, and A carrying a file. No real provider turn is needed if dispatch is rejected before it starts.

**Upstream check:** `apps/web/src/components/ChatView.tsx:5741-5765` inspects and restores the captured `composerDraftTarget`, and updates the live editor only if `currentRouteThreadKeyRef.current === routeThreadKey`. This is a port ownership defect, not the upstream policy of preserving a newer draft on the same target.

**Harness:** cases one and two extract the actual `sendFailed` body. They check no write to B and recovery to A. Persistence and rendering are in-memory collaborators, so this is narrower than an app integration test.

### C2. P2: switching machine keeps attachment uploads on the previous machine

**Reachable entry:** Run on menu callback, `App/Sources/ComposerController.swift:321`, or keyboard machine cycling (`:742-749`). The control locks for an in-flight message, not for attachments (`:1049`).

**Defect:** `changeEnvironment` (`:1145-1160`) retargets the session without migrating, invalidating or refusing existing attachments. `retarget` changes only project/thread identifiers (`:991-994`). Attachments remain keyed by the unchanged draft ID and retain their original `environmentId`. `startUpload` deliberately uploads using that attachment environment (`:3728-3738`). At send, the controller obtains `currentAttachments`, validates status and size, and serializes `chatAttachment` without checking environment (`:1706`, `:1723-1730`). `ComposerAttachment.chatAttachment` also checks only ready status and upload ID (`Packages/CandyKit/Sources/Features/Composer/ComposerAttachments.swift:213-219`).

**Trigger:** attach a small file on machine A, wait until ready, choose machine B for the same project group, send. B receives A's pending upload ID. Separate sandbox servers have separate upload storage, so B rejects the send as an attachment it cannot find. Retrying the unchanged draft repeats the bad ID. An image being prepared when the machine changes has the same ownership issue: completion appends to the stable draft key with the captured old environment (`ComposerController.swift:3672-3688`).

**User effect:** a normal machine choice leaves apparently ready attachments unsendable until removed and reattached on B. No cross-machine data disclosure is established; the concrete failure is use of an upload ID absent from B. Add-to-another-machine also retargets without attachment handling (`:1069-1082`).

**Upstream check:** `apps/web/src/components/ChatView.tsx:5113-5135` starts/awaits uploads for the selected environment. `apps/web/src/lib/attachmentUploadQueue.ts:406-446` treats an upload belonging to another environment as needing a new job, and `:595-603` refuses to serialize a ready upload belonging to another environment. Server `apps/server/src/orchestration-v2/AttachmentClaims.ts:85-93` claims against that server's attachments directory; `apps/server/src/attachmentStore.ts:238-243` rejects an absent ID.

**Parent scenario:** two sandbox environments for one logical project; ready file and image separately; switch A to B then send. Inspect upload destination and dispatch attachment IDs. Also delay image preparation before switching, and delay auto-balance completion while adding an attachment. The latter is a useful stress scenario rather than a separately confirmed finding.

### C3. P1: upload retry sends an old snapshot and clears newer typing

**Reachable entry:** Send with a retryable failed upload. Failed status intentionally does not block Send (`Packages/CandyKit/Sources/Features/Composer/ComposerAttachments.swift:135-143`). The controller saves `(text, mode, background)` in `sendAfterRetry` and starts retrying (`App/Sources/ComposerController.swift:1715-1721`).

**Defect:** while retrying, the editor stays editable (`Packages/CandyKit/Sources/Features/Composer/ComposerView.swift:507-510`); no message is pending yet. Completion calls `resumeSendAfterRetry` (`ComposerController.swift:3753`). That method verifies the draft key and upload statuses, then sends the captured text without comparing the current prompt or attachment identity (`:3758-3769`). The send clears the live editor and stored prompt (`:1852-1854`).

**Trigger:** failed image upload, type `original`, press Send, delay the retry POST, replace or extend the text to `newer correction`, complete the retry successfully. The agent receives `original`; the newer correction disappears from the composer and its saved draft. New attachments and a newly selected model can also be combined with the stale text, because the resumed `send` reads the current attachments and picks (`:1706`, `:1736`).

**User effect:** silent loss of edits made during an ordinary visible upload wait. This needs a successful retry and no intervening send, so the newer text cannot be recovered as a failed-send draft.

**Upstream check:** `apps/web/src/components/ChatView.tsx:5101-5135` marks a send in flight and waits against a captured attachment snapshot. This audit does not claim upstream necessarily preserves every edit during its own upload wait; the concrete defect above follows from CandyWrapper's stale retry text combined with clearing the live mutable editor. Its approval redirect already demonstrates a local changed-draft guard (`ComposerController.swift:1791-1813`).

**Harness:** case three extracts `resumeSendAfterRetry`. A dispatch collaborator records its text and models the exact editor-clear side effect at `:1853-1854`. It demonstrates the mismatch without uploading files; package/UI send gating and the full network path remain source-traced.

### C4. P2: a successful foreground launch takes navigation back after the user leaves

**Reachable entry:** first Send in a local draft, then click another thread while `orchestration.launchThread` is pending (`App/Sources/ComposerController.swift:1861-1888`, `:838-851`).

**Defect:** the success continuation unconditionally invokes `openThread` for every foreground launch (`:1898-1899`), regardless of the current target. Existing-thread background-send completion, by comparison, checks its target before navigation (`:1958`).

**Trigger and effect:** delay draft A's launch response, navigate to thread B and begin typing, complete A successfully. The app jumps to A despite the user's newer selection. B's text is flushed by normal navigation, so this finding establishes focus/navigation theft rather than data loss. The active destination changes just before subsequent input and Send can be processed.

**Upstream check:** `apps/web/src/components/ChatView.tsx:5694-5700` distinguishes a promoted draft still on screen from navigation away, finalizing a background/left draft instead of treating it as the current route. Its failure continuation also route-guards live-editor mutation (`:5755`).

**Parent scenario:** delay only launch response, navigate away, complete success, assert the selected thread remains B. Repeat A to B to a new draft, and launch success arriving while B's editor has focus. Source-traced only; no UI timing measurements here.

### C5. P2: retrying a restored upload can finish without completing the queued Send

**Reachable entry:** relaunch with a saved pending upload. Restoration marks it unverified (`App/Sources/ComposerController.swift:3274-3278`); a failed initial verification leaves a retryable failure (`:3339-3343`). Pressing Send queues `sendAfterRetry` (`:1715-1721`).

**Defect:** `retryAttachment` chooses `verifyRestoredUpload` for this unverified upload (`:3783-3786`). Verification changes the attachment to ready (`:3345-3348`) but never calls `resumeSendAfterRetry`. Normal upload completion does (`:3753`). There is no other general resume hook in `updateAttachment` (`:3367-3371`).

**Trigger and effect:** saved file upload whose server verification first fails transiently, then succeeds when Send retries it. The attachment becomes ready but the message never dispatches; the user must Send again. The retained intent can instead be resumed by an unrelated later upload completion on the same draft. This is a missing continuation, not evidence of a permanently disabled editor.

**Parent scenario:** restore one saved upload, fail its first `assets.createUrl`, succeed its next verification after Send, assert exactly one message dispatch. Repeat verification-not-found, where reattach guidance is expected. Source-traced only; no extraction harness for this async method.

## Previous findings and checks that did not produce new findings

- `docs/research/codebase-audit-2026-10-18.md` contains no composer-specific numbered defect. Its app-controller test-coverage limitation still applies: package composer tests do not instantiate `ComposerController`.
- `docs/research/m7-code-review-2.md` already records conservative fan-out retry handling. It remains at `ComposerController.swift:2114-2121`, `:2179-2195` and is not counted again. It can block a retry after a definite launch refusal, but the user explicitly chooses Allow retry.
- The same older review records the workspace-default pending-flag race. The shared flag is still cleared at `:1656` without request ownership. Current draft checks (`:1657`) and the synchronous `pendingMessageId` guard (`:1703`, `:1849`) still prevent an ordinary double dispatch on that path. Not a new finding here.
- Plain rapid double Enter/Send on an existing thread is synchronously guarded by `pendingMessageId` before any suspension. Queue commands and edits set `queueBusy` before awaiting (`:2352-2360`, `:2395-2404`); responses set request-keyed `responding` before awaiting (`:1553-1560`). No supported duplicate-send finding from those ordinary paths.
- Ordinary image completion after switching between different draft keys appends to its captured key (`:3684`), and normal upload updates use captured attachment/key pairs (`:3739-3751`). The demonstrated ownership gaps concern machine changes preserving a draft key, and send recovery's use of the live editor.

## Parent execution and coverage limits

No tests were run here under the explicit execution restriction. New opt-in harness:

```sh
scripts/preflight
CW_COMPOSER_AUDIT_REPRO=1 /usr/bin/python3 scripts/audit-composer-recovery
```

It extracts two current controller methods, compiles a small Swift executable in a temporary sandbox folder, runs it, and removes that folder. Compilation timeout is 120 seconds, execution timeout 15 seconds. It uses no package build, server, credentials, shared screen or persistent preferences. **Expected current exit: 1**, with failing ownership invariants for C1 and C3. Compile success and output remain unverified. The substituted collaborators are explicitly labeled; this must not be reported as execution of the entire controller or app. It is opt-in and outside normal test discovery.

Existing package checks useful after any later repair, run by the parent with a bounded background execution as AGENTS.md requires:

```sh
scripts/test --filter ComposerAttachmentsTests
scripts/test --filter ComposerLogicTests
scripts/test --filter NewThreadDraftLaunchTests
```

These cover supporting rules, not the integration defects above. A repair needs a real controller integration seam or deterministic sandbox UI interception at the response boundaries specified per finding.

Additional useful stress matrix: Enter/click bursts around dispatch acknowledgement and newly arriving approval; two pending approvals with navigation after the first decline; queued edit starting while Save is delayed; attachment removal/discard during mint, POST and verification; moving a draft to another machine during preparation; environment removal/replacement during dispatch; failure after a background launch opens a fresh draft; partial fan-out with fresh typing and model selection. This review inspected those branches but did not exhaustively validate every event ordering. No claim about measured responsiveness, server latency or thumbnail readiness is made.
