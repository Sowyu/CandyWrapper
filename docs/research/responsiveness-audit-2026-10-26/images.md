# Image and media loading audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Date: 2026-10-26. Baseline: `0ced803c`. Area: images. Source inspection only; no builds, tests, app launches, network fixtures, live accounts or shared-screen work ran in this worktree. Product code and design are unchanged. The two new regression tests are opt-in and unexecuted. Severity P2 means a reachable user-facing correctness bug with a workaround, rather than a measured application-wide stall.

## Findings

### IMG-1: Cancelling an image preview can replace the next file with the old error (P2)

Evidence:

- `Packages/CandyKit/Sources/Features/Files/FileSurfaceView.swift:234-240` cancels the previous load when rebuilding a body.
- Its image task at `:304-310` handles a nil fetch by calling `self.replaceBody`, without checking cancellation, URL, path, or body identity. `replaceBody` at `:336-340` removes whichever body is current.
- `App/Sources/FilesController.swift:96-99` maps a cancelled `URLSession.data(from:)`, network error or HTTP failure to nil.
- The same stale-failure pattern exists for PDF at `FileSurfaceView.swift:323-328`.

Reachability and trigger: open a workspace image from the file tree or a file link, then select another file while its HTTP fetch is pending. Rebuilding cancels the first task; its cancellation is converted to nil and the first task replaces the new file's body with “Unable to load workspace image.” The header and `content` still identify the new file. A successful late old fetch only writes the detached old NSImageView; the destructive branch is its failure/cancellation branch.

User effect: a valid newly opened text/image preview disappears or shows an unrelated error. Switching away and back repairs it. This also occurs without changing environments. The controller's resource-identity guard at `FilesController.swift:454` protects the earlier asset-signing result, not this later HTTP task.

Reproduction added: `ImageLoadingAuditTests.cancelledImageCannotReplaceTheNextFileWithItsError`. It gates the old image response, mounts a new text editor, then releases nil and checks that the new editor stays mounted. No actual URL request or window is needed. Source-traced; test not executed.

This is distinct from the old 2026-10-18 audit's preview identity finding: the current controller now keys by environment/workspace/path and guards that read, but the child view has this separate completion path.

### IMG-2: Rejected after independent review

Changing the original file after a successful upload does not establish the proposed sent-image bug. `App/Sources/ComposerController.swift:3290-3308` copies ordinary images into the app-owned draft directory and replaces `fileURL`; the ready transition persists this copy before Send can select it. The original review missed that intervening ownership change. A failed copy would require a separate reproduction. This candidate is excluded from the final count; see [adjudication](adjudication.md).

### IMG-3: HTTP 200 with malformed image bytes leaves the file viewer blank (P3)

Evidence: `Packages/CandyKit/Sources/Features/Files/FileSurfaceView.swift:305-309` checks that a Data value exists, then assigns `NSImage(data:)` without checking the optional result. The fetch closure at `App/Sources/FilesController.swift:96-99` accepts any 2xx body. Invalid PNG/JPEG content therefore leaves an empty NSImageView, with neither an error nor loading feedback.

Reachability and trigger: open a workspace file named `broken.png` whose contents are text, truncated image bytes, or another undecodable payload, while the asset endpoint returns 200. User effect: a permanently blank image preview gives no explanation and looks unfinished. This differs from valid but very large images, which may eventually render.

T3 explicitly uses the image's error callback to show “Unable to load workspace image”: `apps/web/src/components/files/FilePreviewPanel.tsx:186-205` in the local pinned source.

Reproduction added: `ImageLoadingAuditTests.successfulHTTPWithMalformedImageReportsFailure`; it injects malformed Data and expects a failure view within two seconds. Source-traced; test not executed.

### IMG-4: Orchestrator can send before image preparation starts showing an attachment (P2)

Evidence:

- `App/Sources/OrchestratorController.swift:588-600` starts preparation asynchronously without reserving a pending attachment or tracking a preparation count.
- The attachment is first appended after preparation returns at `:601-605`.
- The composer only blocks for uploading attachments that already exist: `Packages/CandyKit/Sources/Features/Orchestrator/OrchestratorPaneView.swift:1602-1618`.
- Send snapshots only ready attachments at `OrchestratorController.swift:500-511`.

Trigger: type a prompt, select/paste a large HEIC or oversized PNG/JPEG requiring preparation, and immediately send before preparation finishes. The prompt is dispatched with no selected image; the image then appears in the next draft. The Orchestrator remains able to send during this interval because its attachment list is still empty. A batch can also send between preparation of its first and later images if earlier uploads finish quickly. Multiple add operations calculate room from only `pendingImages.count` at `:590`, so overlapping preparation can additionally oversubscribe the attachment limit.

User effect: a request such as “describe this picture” reaches the agent without the intended picture. Redesign with the experimental Orchestrator enabled is required. This is not claimed for the ordinary composer: `App/Sources/ComposerController.swift:1645-1648` explicitly blocks while its preparation count is nonzero.

T3 documents and guards this precise stranding problem in `apps/web/src/components/chat/ChatComposer.tsx:3457-3467` of the pinned local source. Orchestrator is CandyWrapper's feature, but should retain the same attachment-snapshot invariant. Source-traced; no timing measurement or end-to-end reproduction executed.

### IMG-5: Video/audio Save silently ignores signing and HTTP failures (P3)

Evidence: `Packages/CandyKit/Sources/Features/Thread/ThreadMediaAttachmentView.swift:74-86` returns silently when the signed-URL loader returns nil (`:80`) or the download returns a non-2xx response (`:83`). Only thrown errors update the button to “Retry save.” The app loader at `App/Sources/ComposerController.swift:4893-4899` converts signing failures to nil.

Reachability and trigger: choose Save video/audio on a sent media attachment, accept a destination, then have asset signing fail or serve a 403/404/500. No destination file appears, and the control gives no failure indication. A network exception follows a different path and does say “Retry save.” Source-traced; no save panel or HTTP fixture executed.

## Existing findings and recent fixes

- First-open duplication: the fix remains present. `ExpandedImagePreviewView.Item.withPreview` at `Packages/CandyKit/Sources/Features/Composer/ExpandedImagePreviewView.swift:28-34` checks identity and takes weakly referenced visible pixels; `:149-151` seeds the expanded view. Markdown expansion at `MarkdownView.swift:621-624` shares its original loader. `MarkdownImageDownload.swift:25-47` coalesces fetches and retains the downloaded file across decode sizes. The recorded three-second-source measurement in `docs/perf/image-first-open-2026-10-23.md` is prior evidence, not a measurement repeated by this audit. No new finding for the already repaired blank-first-expansion path.
- The shared decode cache keeps sharper completed entries, shares an adequate in-flight request, and cancels when its last consumer leaves: `ImageDecodeCache.swift:54-94`. AsyncImageView checks cancellation and its generation before applying results at `ComposerImageShelfView.swift:171`, and keeps visible pixels after a failed upgrade at `:174-181`. These guards do not cover IMG-1's separate NSImageView path.
- The 2026-10-18 asset-size-limit finding is repaired: `Packages/CandyKit/Sources/T3Transport/EnvironmentHTTP.swift:160-168` checks Content-Length and accumulated bytes while receiving, and cancels above the limit. `App/Sources/ShellSession.swift:426` still passes the 4 MB icon limit. No duplicate finding.
- Multi-environment attachment/image cache identity remains a known limitation, acknowledged in `docs/research/codebase-audit-2026-10-18.md:134`. Current examples include raw attachment-ID disk/decode keys at `ComposerController.swift:3959-3962` and `TimelineMessageRows.swift:985-986`, plus global Markdown signing closures bound to `openThreadId` at `App/Sources/ThreadSession.swift:758-766`. Do not count it again as new.
- Gallery persistence uses environment/thread/item identity in `AgentImageCache.swift:42-61` and tries server/kept/source loaders in `ThreadImageGalleryView.swift:202-218`. Its background tasks and global signing glue need a controlled cross-environment test; source inspection alone does not establish the outcome of every navigation race.

## Execution handoff

Two opt-in tests were added in `Packages/CandyKit/Tests/FeaturesTests/ImageLoadingAuditTests.swift`. They assert desired behavior and are expected to fail on this baseline. They do not create a window, use the screen, access a server or write fixture files. The cancellation case uses a continuation gate and yields to the main actor after the fetch returns; all waits are bounded. They have not been compiled or executed, per the parent's centralized-execution rule.

Run centrally after the normal preflight and Origin-run checks:

```sh
CW_IMAGE_AUDIT_REGRESSIONS=1 scripts/test --filter ImageLoadingAuditTests
scripts/test --filter 'AsyncImageCacheTests|MarkdownImageDownloadTests|ImageDecodeTests|MarkdownMediaTests|ThreadImageGalleryTests'
```

Useful sandbox stress scenarios, not executed here:

1. Gate a workspace image HTTP response, navigate image to text/image/PDF, release cancellation or 404, and check the new body and its header still agree. Repeat in the same workspace before adding environment switches.
2. Send a known small PNG, overwrite its source with a different image, expand cold fit and hot cover variants, clear the decode cache, switch away/back, and Save. Compare exported bytes with the server's immutable copy.
3. Open 200/404/500, empty, truncated and non-image bodies for file-viewer images, Markdown images, sent images and tool output images. Require a terminal success or visible failure, then test retry/Force Reload.
4. Use the existing three-second HTTP fixture with `Cache-Control: no-store`: count requests for inline display, first expansion, zoom, dismissal during fetch, and reopen. Test one shared consumer cancelled while another remains and all consumers cancelled before completion. Existing suites cover the worker/download abstractions, not every app glue path.
5. Open many distinct large PNG/JPEGs and extreme panoramas, then immediately open a small uncached image. Measure the small image's wait behind `ImageDecodeWorker`'s serial queue (`ImageDecodeCache.swift:5-11`) and repeat after cancelling all large-image views. ImageIO work already running is synchronous; no numerical responsiveness claim is made here.
6. Rapidly scroll through more cold sent attachments than the HTTP connection limit and then expand a final image. `ComposerController.attachmentSource` owns an unstructured fetch (`:3965-3989`) with no consumer cancellation, unlike MarkdownImageDownload. Check whether no-longer-visible transfers delay that final image before treating this as a measured loading finding.
7. Send immediately after adding a large image to the Orchestrator; repeat with two batches and a nearly full 100-image draft. Check actual message attachment IDs, not just the thumbnails that eventually appear.

Coverage limitations: no runtime timing, malformed-image decoder stress, HTTP fault injection, main-thread stall sampling, cache eviction under pressure, EXIF/animated GIF/WebP visual behavior, or app-glue automation ran. FileSurfaceView uses `NSImage(data:)` on its main-actor continuation (`:309`) instead of the downsampler, but its load/decode/draw latency must be measured before calling it a confirmed large-image stall. Project icon fetch/coalescing/invalidation, gallery persistence, attachment uploads and downloads, Markdown sources, composer previews, expanded previews, and app wiring received source review; encrypted Space blob images and browser remote frame rendering were not exhaustively audited in this area.
