# Files and actions audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Reviewed 2026-10-26 at CandyWrapper `08e124456fd5853f25c1dcba4da5adf9dfad7d89` on `t3/audit-files-actions`. This is an audit only. No production edits, builds, tests, app launches, screen use, server calls or account operations occurred. All findings below are source-traced, not executed reproductions. The opt-in harness has also not been compiled or run; the parent owns execution.

Scope: `App/Sources/FilesController.swift`, `GitController.swift`, `PullRequestsController.swift`, `PullRequestsPage.swift`, and selected Files/Git/PR views and logic. P1 means a wrong destructive action or lost unsent text; P2 means incorrect displayed state or stale listings. No timing or performance claim follows from this source review.

## New findings

### F1. P1: Comment and close/reopen can act on a different pull request

**Trigger and reachability:** Open PR A, submit a comment with Close or Reopen, and switch to another PR B before A's comment RPC finishes. The shared binding changes target through `PullRequestsController.sync()` at `App/Sources/PullRequestsController.swift:695-698` or the standalone page's `syncDetail()` at `App/Sources/PullRequestsPage.swift:600-605`. `PullRequestDetailBinding.show()` replaces its environment and target at `App/Sources/PullRequestsController.swift:139-142` without canceling the write.

**Trace:** `commentAction` captures A's `shell` and reference at `App/Sources/PullRequestsController.swift:447`, posts A's comment at `:451`, then calls `self?.perform(action, mergeMethod: nil)` at `:460`. `perform` obtains the current shell/reference at `:327` and sends the state change at `:332`.

**User effect:** A receives the comment, but B receives Close or Reopen, even if B is on another environment. If the binding was cleared instead, the second step is silently omitted. Pending UI state does not prevent navigating between PR tabs or threads.

**T3 comparison:** Checked local T3 at `v0.1.2-nightly.20261021.3473`, commit `1688f96568`. `apps/web/src/components/pullRequest/PullRequestDetailPanel.tsx:673-685` retains the initiating render's `reference` and `finishAction`; `:615-625` sends that reference. CandyWrapper re-resolves the target after awaiting instead.

**Reproduction artifact:** `files-actions-harness.py` extracts `commentAction`, `perform`, and `comment` verbatim from the current production file. Its first case gates the comment, changes the binding's reference/environment, then observes the action payload. Not executed here.

### F2. P1: A late comment success erases another PR's unsent comment

**Trigger and reachability:** Submit an ordinary comment on A, switch to B while it is pending, open B's composer, and type an unsent comment before A replies. Ordinary comment submission does not set the shared `actionPending` flag (`App/Sources/PullRequestsController.swift:348-355`). Switching targets builds a composer with B's identity (`Packages/CandyKit/Sources/Features/PullRequests/PullRequestDetailView.swift:754-763`).

**Trace:** A's completion calls the current `view.composer?.commentPosted()` and `view.closeComposer()` at `App/Sources/PullRequestsController.swift:353-354`, without a generation, reference or composer-identity check. `commentPosted()` unconditionally empties `commentBox.text` at `Packages/CandyKit/Sources/Features/PullRequests/PullRequestComposerView.swift:196`.

**User effect:** B's unsent text disappears and its popover closes even though only A's comment was sent. This also occurs in the comment-and-action path at `App/Sources/PullRequestsController.swift:458-459`; an old review completion similarly acts on the current composer at `:369-370`, though this audit does not claim arbitrary new review text is cleared because the review store compares submitted text.

**Evidence:** Source-traced. The harness's second case gates production `comment`, swaps the current composer/target, and checks whether the new draft is cleared. Its view stub implements the actual one-line `commentPosted` behavior; this tests callback ownership, not AppKit navigation or persistence.

### F3. P2: Viewed-file reads and write completions are not scoped to their PR

**Trigger:** Open A's Code tab with a delayed `pullRequests.filesViewed` response, switch to B's Code tab, let B's response finish, then complete A's response. Use a changed file path present in both PRs and differing viewed states.

**Trace:** `loadViewed()` captures A's shell/reference at `App/Sources/PullRequestsController.swift:290` and starts the RPC at `:295`, but after awaiting checks only `self` at `:297`. It replaces the binding's `viewedStates`, settles the current overlay and feeds the current view at `:298-300`. The view uses that state to compute B's viewed flags/counts (`Packages/CandyKit/Sources/Features/PullRequests/PullRequestCodeView.swift:151-164`). Unlike diff slices (`App/Sources/PullRequestsController.swift:270`), this read has no generation or patch-key guard.

`setViewed()` also completes against mutable current state: `:313-319` removes a path from the current pending set and reloads/reverts the current PR's overlay. `show()` clears overlays at `:146-148` but does not clear `pendingViewed` (`:64`), so a write from A can affect pending ownership for the same path on B.

**User effect:** B can show A's viewed marks/counts until a subsequent read; stale failure handling can undo B's newer mark. No wrong-PR server write is claimed for this path: the initial write payload captures its reference correctly.

**T3 comparison:** `apps/web/src/components/pullRequest/usePullRequestFilesViewed.ts:43` keys the read by environment/reference. `:93-104` records a write's originating scope and rejects a completion from another scope. `:124-139` flushes the leaving target and clears per-scope tracking. Source-traced only; no new harness for this finding.

### F4. P2: Overlapping tree refreshes can restore an older directory listing

**Trigger:** Keep the Files pane open, delay listing R1, change the sandbox directory, press Refresh to start R2, finish R2 with the new entries, then finish R1 with the old entries. A leave-and-return sequence A → B → A can produce the same acceptance of an old A response.

**Trace:** Refresh calls `loadDirectories` unconditionally at `App/Sources/FilesController.swift:322-325`. Each call starts an independent task group at `:279-288`. Completion validates only environment/cwd at `:292`, then removes the loading marker and applies entries at `:294-297`. There is no model-instance identity, request generation or per-directory sequence. `FileTreeModel.setChildren` unconditionally replaces a directory's children (`Packages/CandyKit/Sources/Features/Files/FileTreeModel.swift:35-42`).

**User effect:** A deleted file can reappear, or a newly created file disappear, after the newer refresh already completed. An older completion also clears the loading marker while a newer request is still outstanding. This is a distinct refresh-order defect, not the October 18 same-checkout thread-switch loading defect. No T3 parity difference is asserted; this is a source-traced correctness finding, not executed under delayed networking.

## Revalidation of October 18 findings

The earlier report is `docs/research/codebase-audit-2026-10-18.md`. Do not count these as new findings.

| Earlier finding | Current source result |
| --- | --- |
| 1: Same relative filename across workspaces can overwrite the destination | Addressed by source inspection. Full `FileKey` identity includes environment/cwd/path (`FilesController.swift:55-58`). `showActiveFile` compares it, invalidates the shown file before loading and guards response identity (`:430-454`). `edited` writes using the shown file key (`:509-521`). Same-path `FileSurfaceView.show` still retains content by itself, but the controller now explicitly resets it (`:436`). |
| 2: Buffers collide between environments | Addressed by source inspection. Reads, buffers and `shownFile` use `FileKey` (`:63-71`); captured environment/cwd drive persistence (`:510-521`). |
| 3: Close/reopen creates concurrent writers | Addressed by source inspection. `flushEdits` retains the coordinator and calls `flush` (`:549-554`); `edited` reuses it (`:511-516`). The coordinator serializes persistence (`FilesLogic.swift:304-320`). Existing `FilesLogicTests.saveCoordinatorFlushKeepsNewestLast`, lines 129-147, covers a single retained writer, not the app controller wiring. |
| 4: Settled editors retain their save buffers | Addressed on the successful-save path. The confirmation drops the buffer only once the coordinator has no newer unsaved revision (`FilesController.swift:530-540`). Failed/pending edits remain intentionally retained. No memory measurement performed or required for this review. |
| 5: Switching same-checkout threads leaves directory loading stuck | Addressed by source inspection. Directory completion checks environment/cwd only (`:292`), rather than equality of a Workspace containing thread ID, then clears loading (`:294`). F4 concerns independent refreshes that share that identity. |

## Other checks and coverage limits

- Main Git stacked actions and Pull set their busy state synchronously before starting tasks (`GitController.swift:953-962`, `:1043-1048`). Branch-result metadata is explicitly applied to the initiating target (`:784-794`, `:811-829`), and checkout preparation updates the initiating draft (`:1215-1226`). No wrong-target mutation was established in those inspected paths.
- Git action/status/ref refresh completions use workspace keys, not a connection/request generation (`GitController.swift:202-207`, `:219-224`, `:269-275`). A same-key old-session or A → B → A response is a useful follow-up stress scenario, but this report does not assert a reproduced branch/status corruption from it.
- PR list refreshes reject old generations (`PullRequestsPage.swift:261-262`, `:313`, `:327`). Paging's button disables while loading (`PullRequestsPageView.swift:228-230`), so absence of a controller paging guard alone is not a reachable rapid-click finding.
- PR list Shift quick-action buttons remain enabled while requests run (`PullRequestsPageView.swift:734-739`); `PullRequestsPage.speedAction` has no per-row pending guard (`:610-624`). Rapid clicks can dispatch repeated host requests. The host's handling and user effect need sandbox/fake-transport execution before treating this as a separate destructive-action finding. T3's corresponding speed actions use pending/busy state (`PullRequestSpeedActions.tsx:81-94`).
- Search workspace reset assigns the input's empty text (`FilesController.swift:192`). That setter calls `textChanged` and `onChange` (`FieldView.swift:35-37`, `:119-121`), which reaches `searchTree` cancellation and clears `searchPending` (`FilesController.swift:333-336`). A speculative stuck-search report based only on missing explicit cancellation in `updateWorkspace` would be incorrect.
- No network latency, real server ordering, host permissions, account mutations, modal navigation, native file editors, media previews, visual states or screen interactions were exercised. The package excludes app controllers; package test success alone cannot validate their wiring.

## Central execution handoff

No commands below were run here. The harness is opt-in, has bounded subprocess timeouts and scheduler waits, uses no real files/server beyond reading its production source, and removes temporary compile artifacts. It exits 0 only when both current F1/F2 bugs reproduce. A future repair should replace those reproduction expectations with correct-target/draft-preservation invariants.

```sh
python3 docs/research/responsiveness-audit-2026-10-26/files-actions-harness.py --run
scripts/test --filter FilesLogicTests
```

Run those only in the parent's centralized lane, after its normal preflight and energy-run coordination. The harness compiles three extracted app methods with transport/payload/view stubs; it does not compile the application, test real JSON payload construction, or prove AppKit navigation. Source reachability is documented above separately.

Useful controlled stress cases: (1) gate comment/action completions while switching PR and environment; (2) save a file, close/reopen during the write, then undo to the same contents before completion; (3) complete files-viewed reads and writes in reverse order across PRs sharing paths; (4) overlap root and nested directory refreshes, including A → B → A; (5) rapidly click Shift quick actions and inspect outbound counts and host outcomes. Keep all filesystem and live-server variants inside the sandbox.
