# CandyWrapper codebase audit

2026-10-18. Product source reviewed at `cc9d077`, with no product changes. This audit found three high-priority file-save defects and five medium-priority state, lifetime and resource defects. Fix file identity and save ownership first. The module boundaries support targeted repairs; the evidence does not justify a rewrite.

## Scope and evidence

The inventory covers 583 first-party Swift files and 161,884 lines across the app and CandyKit. Excluding generated files leaves 575 files and 157,206 lines. The review combined repository-wide searches for unsafe conversions, concurrency escapes, timers, blocking I/O, subscriptions, resource ownership and duplicate blocks with detailed inspection of selected paths. It was not a line-by-line review of every file. Vendored SwiftTerm and generated assets were excluded from the detailed audit.

Detailed inspection covered file previews and autosave, environment replacement, RPC transport and cancellation, shell and thread stores, caches, composer submission and attachment staging, browser and device lifetimes, updates and rollback, authentication callbacks, HTML frame isolation, notifications, and selected Git and pull-request actions. Findings below distinguish source traces from an executed reproduction. Source traces establish a reachable code path; they do not claim an on-screen reproduction.

Validation results are recorded at the end. The live T3 home and the user's app were left untouched. No agent turns or account sign-ins were needed.

## High-priority findings

### 1 Switching workspaces can save the previous file into the new workspace

**Source trace:** `App/Sources/FilesController.swift:400-411`, `Packages/CandyKit/Sources/Features/Files/FileSurfaceView.swift:159-165`, and `App/Sources/FilesController.swift:480-497`.

`showActiveFile` decides whether content is current from `surface.path == path`. When the text is already loaded, it returns before reading the new workspace. `surface.show` also resets content only when the path changes. Switching to another thread or a changed worktree with the same relative filename updates the controller's workspace and header but retains the old editor contents. Editing then calls `edited`, which selects the current workspace and writes the retained contents there.

To reproduce, open `README.md` in two threads from different workspaces with distinct text. Open the first preview, switch to the second thread's existing `README.md` tab, and edit one character. The first file's body can replace the second file's body. This does not require matching absolute workspace roots or multiple environments.

Track the displayed resource as environment, workspace root, path and resource kind. Invalidate the editor and cancel its outstanding load when that identity changes. Bind edits to that identity rather than looking it up from mutable navigation state. Test the switch with both loaded and in-flight previews, including attachment-to-workspace transitions with matching names.

T3 keys its preview resource by environment, cwd and relative path: `apps/web/src/components/files/FilePreviewPanel.tsx:1184`.

### 2 File buffers collide between environments

**Source trace:** `App/Sources/FilesController.swift:349`, `:414-418`, `:480-505`, and `:577-583`.

The buffer and read key contains only cwd and path. Two machines can both have `/repo/README.md`. Unsaved text from one machine then occupies the other machine's buffer slot. A delayed save confirmation from the first machine can also repopulate the shared read key after navigation cleared the read cache. Environment removal clears panel tabs but leaves these buffers behind.

With a slow or failing save in environment A, switch to environment B with the same cwd and filename. After forcing a preview reload to get past finding 1, B can display A's unsaved text. Editing that text creates a writer for B. The persistent save closure and the shared buffer may consequently represent different machines.

Use a typed file key containing environment, cwd and path for reads, edits, writer ownership and cleanup. Test matching paths on two environments and a confirmation arriving after switching or removing the first environment.

T3 includes environment in optimistic file identity: `apps/web/src/components/files/projectFilesQueryState.ts:27-32`, `:78-99`.

### 3 Reopening an editor can let an old writer overwrite the newest save

**Executed reproduction:** the unchanged `FileSaveCoordinator` class from `Packages/CandyKit/Sources/Features/Files/FilesLogic.swift:243-317`, exercised in a standalone Swift harness. Controller handoff: `App/Sources/FilesController.swift:513-519`.

`dispose` starts or drains outstanding work without waiting for completion. The controller immediately clears the coordinator reference. Reopening the file and editing creates another coordinator, so the one-write-at-a-time guarantee no longer holds for the file as a whole.

The deterministic reproduction held the first write open, queued a second edit, disposed the first coordinator, and saved a third edit through its replacement. Releasing the old writer produced:

```text
New editor saved: edit-3-newest
After old editor drains: edit-2
Newest edit overwritten: true
```

Keep one writer per file identity across editor lifetimes, or explicitly drain the old writer before allowing the replacement to send. Test this with controlled continuations, including failures and a close while debounce is pending. Existing `FilesLogicTests.saveCoordinatorNewestWins` only exercises changes within one coordinator.

The disposal/drain algorithm also exists in T3's `apps/web/src/components/files/fileSaveCoordinator.ts:33-36,87-95`. This finding concerns ownership across coordinator instances; it is not evidence that the Swift port alone introduced the algorithm's limitation. Any repair should preserve ordinary debounce and pending-state behavior.

## Medium-priority findings

### 4 Successfully saved file editors retain their full contents after closure

**Source trace:** `App/Sources/FilesController.swift:480-519`, `Packages/CandyKit/Sources/Features/Files/FilesLogic.swift:253-255,299-306`.

After confirmation, `buffer.edited` becomes nil, but its coordinator still holds `latestContents`. `flushEdits` skips coordinators with no unsaved changes, so their buffer entries never leave the dictionary. Closing tabs, changing workspaces and removing environments do not release these saved editors. Memory therefore grows with distinct files edited during the app session, even when the read cache is cleared.

Release settled buffers when no editor uses them. Preserve failed or pending edits, and coordinate the cleanup with finding 3 so releasing a view does not create another writer. Verify object release and retained content after saving and closing many distinct files. This is separate from the already documented progressive-blur memory increase; this audit does not identify that increase's cause.

### 5 Switching threads during a directory load can leave the tree stuck loading

**Source trace:** `App/Sources/FilesController.swift:168-189`, `:250-284`.

The tree is reused when cwd and environment stay the same. The in-flight directory request, however, guards its completion with equality of `Workspace`, which also includes the thread id. Switching between two threads in the same checkout rejects the result before removing the directory from `model.loading`. `ensureTree` sees the outstanding root marker and does not request it again.

Delay the first root listing, switch to a second thread in the same checkout, then complete the listing. The reused tree can stay unready until a manual refresh. Accept results by the tree's environment/cwd identity, or reset and cancel all loading state together when changing its owner. Cover root and nested listings and repeated refreshes.

T3's directory loader is scoped by environment and cwd: `apps/web/src/components/files/useDirectoryEntries.ts:9,29,91`.

### 6 Scheduled task lists do not follow replaced sessions

**Source trace:** `App/Sources/ScheduledTasksStore.swift:14`, `:26-57`; replacement in `App/Sources/Environments.swift:496-524`.

The store remembers a task by environment id but not the `ShellSession` that owns it. `environmentsChanged` subscribes only when that dictionary entry is nil. Stopping and replacing a shell leaves the old task entry present, so watched scheduled-task lists remain attached to the old supervisor. Its subscription can end or wait there, but it cannot follow the new supervisor. Normal socket reconnection inside the same supervisor is a different case and is already handled.

Track the owning session, cancel and replace subscriptions when it changes, and clear task handles on terminal completion with an ownership guard. Keep a watcher open across a session replacement in the regression test. `TerminalController.sessionChanged` already demonstrates the session-identity comparison.

### 7 Device state has the same session replacement gap

**Source trace:** `App/Sources/DevicePanelController.swift:91-109`, `App/Sources/ThreadSession.swift:794-805`.

Device subscription reuse checks only the environment id and whether a task exists. The central session-change handler refreshes the browser, terminal and other controllers but does not reset device state. Even a subsequent device `sync` with a new shell for the same environment retains the old subscription.

After replacing a shell for an open device environment, device additions, removals and session changes can stop appearing. Give the device controller an explicit session-change path and compare the subscription's shell identity. Test replacement with a device pane open and while it is hidden, then reveal it.

This is a separate consumer from finding 6, so both require a repair. A small shared subscription owner may prevent future drift, but the browser's existing session-aware handling should remain the behavioral reference.

### 8 The asset size limit applies after downloading the entire response

**Source trace:** `Packages/CandyKit/Sources/T3Client/EnvironmentHTTP.swift:138-156`; caller: `App/Sources/ShellSession.swift:121`.

`asset(maxBytes:)` uses `URLSession.data(for:)` and checks `data.count` only after the response is fully buffered. Its 4 MB project-icon limit therefore rejects a large icon after paying its entire download and memory cost. It does not bound memory while receiving it.

Check declared size and enforce a running byte limit while consuming the response, cancelling at the limit. Test a chunked oversized body without Content-Length as well as a declared oversized response. This is a resource-bound defect, not a demonstrated credential leak.

T3's equivalent checks both Content-Length and accumulated bytes: `packages/client-runtime/src/projectFaviconCache.ts:51-74`.

## Redundancy and architecture

### Small duplicated behaviors are better candidates than broad view consolidation

The duplicate scan compared normalized 12-line windows across all non-generated first-party Swift files, requiring at least 350 characters and matches in different files. It found a small set of exact duplicates. This detects exact blocks, not every semantic duplication; it is not a dead-code detector.

- Device keyboard handling is repeated in `Features/Device/DeviceThreeDView.swift:132` and `Features/Device/DevicePanelView.swift:176`. A shared modifier/key translation function would keep the two display modes consistent.
- Dialog animation setup repeats in `DesignSystem/Components/ModalHost.swift:181` and `Features/CommandPalette/CommandPaletteController.swift:485`. Share the animation primitive if either path changes, while preserving sheet and nested-dialog transforms.
- Tracking-area construction repeats in five view files, including `Features/Files/FilesPanelView.swift:383` and `Features/Thread/RightPanelView.swift:712`. This is a lower-priority candidate because hover ownership and recycled-row behavior differ. Prefer the established HoverSync lifecycle over introducing another global event monitor.
- Similar empty-state layouts and picker scaffolding also appeared. Their small size and differing layout contracts do not justify a refactor by themselves.

The paths in this section are relative to `Packages/CandyKit/Sources`. Generated icons and tokens are intentional data repetition and should not be hand-deduplicated. No deletion recommendation is based only on a symbol having few textual references; selectors, protocol witnesses, callbacks and public package APIs make that unsafe.

### The largest risk is app integration that the package tests cannot exercise

The app has 44 Swift files and 23,504 lines. `ComposerController.swift` alone has 4,514 lines and owns submission, drafts, attachment staging, questions, context, selection and recovery. `ThreadSession.swift` has 1,307 lines and combines stream lifecycle with much of the controller wiring. This concentration makes navigation and ownership invariants harder to review.

CandyKit has five test targets and 262 Swift test files. `Package.swift` does not include `App/Sources`, and `project.yml` declares the app without an app test target. The package's file-save and file-rendering tests consequently do not cover the `FilesController` interactions identified above. A passing package suite cannot establish their correctness.

Extract a small file-session model and session-bound subscription owner into testable code, or add an app integration test target. Start with the three high-priority cases. Split the composer by coherent state ownership when changing those areas, rather than moving arbitrary extensions just to shorten the file.

### Module boundaries remain useful

Repository-wide import checks found no Features import of T3Client and no UI or T3Client import in T3Store or T3Protocol. Package dependencies preserve the intended separation. Keep transport and credentials in T3Client, pure state in T3Store, and controller wiring in the app.

The inspected RPC stream path has acknowledgement backpressure and cancellation. The timeline pipeline resets its mutable worker on a thread change, avoiding simultaneous use of one worker across thread generations. HTML frames use sandboxing, an isolated script world, and source-window checks; no new frame-isolation defect was established. Runtime trials arm database recovery before trying an update and verify authenticated RPC before discarding the backup. These checks narrow the audit's conclusions; they are not a security certification.

## Existing work and validation limits

The unresolved blur memory increase, first-open Markdown stalls, narrow composer banners, remaining 3234 parity and known multi-environment image-cache limitation remain in `PROGRESS.md`. They were not counted as new findings. UI timing and host-account behavior were not exhaustively retested. No live account, remote host, update installation, rollback or release was exercised in this audit.

The audit did not run `scripts/perf-review`: no product implementation changed, and the resource findings above concern source-level lifetimes and bounds. It makes no new CPU, energy or memory benchmark claim.

## Validation

- Disk preflight passed with 98 GB free at the start.
- The standalone save-handoff reproduction confirmed that the old coordinator overwrites the newer save. It uses the production coordinator class verbatim with a controlled persistence callback, rather than real files or a server.
- Full package tests: passed through `scripts/test`, exit 0. All 1,532 Swift Testing tests and 17 XCTest tests passed (1,549 total).
- Isolated Debug application build: passed through `scripts/build-test-app codebase-audit`. The build emitted 95 distinct source warning diagnostics, including deprecated accessibility APIs and concurrency/capture warnings. These are maintenance debt; build success does not establish that each warning is benign.
- Native sandbox snapshot smoke check: passed. The isolated app rendered the connected sandbox's sidebar and new-thread screen, then quit. The PNG was inspected. This checks launch and rendering, not the eight bug scenarios.

Repair order: file identity and buffer scope, writer handoff and settled-buffer release, session replacement for scheduled tasks and devices, directory-load ownership, then streaming asset limits. Keep each repair small and add tests around the failing ownership boundary before broad cleanup.
