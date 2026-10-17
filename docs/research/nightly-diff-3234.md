# T3 Code Nightly: 3105 to 3234

Range: v0.0.46-nightly.20261014.3105 .. v0.1.1-nightly.20261017.3234, 207 commits. Target commit bf990c625e. Line numbers refer to the 3234 source tree. The wire and the main UI changes are implemented; remaining parity work is listed below.

## 1. Wire changes

### Breaks

No removed wire schema was found. The complete contracts diff was read again after stripping comments and whitespace. Commit 86534db4d3 (#19559) removes 2,833 lines and adds 208 across 73 contract files. A token comparison leaves only a trailing comma in worktreeMcp.ts. The remaining changes below are additive.

### Additions

- `server.getDatabaseStorage`: nullable database size, reclaimable size, incremental vacuum state and compact command. `packages/contracts/src/settings.ts:977-994` defines DatabaseStorageStatus. A notice recommends compaction only without incremental vacuum and with at least 1 GiB reclaimable. CW: T3Protocol/Domain/CommandOutput.swift and StorageSettingsView.
- `orchestration.subscribeCommandOutput`: replace/append text frames with truncated/running flags, and OrchestrationV2CommandOutputError (orchestrationV2.ts:3064-3089). CW: command output frame and visible work inspector subscription. RPC errors already retain arbitrary tags.
- HTTP thread transcript route for cross-environment dropped threads, with thread_transcript_too_large. CW: dropped thread context.
- `thread.update.expectedBranch`, `delete-branch` PR action and optional provider deleteBranch capability. CW: orchestration payloads and PullRequestDetailView.
- Client `pullRequestLinksOpenInApp` defaults true (settings.ts:403). Server `sidebarAutoSettleKeepPullRequests` defaults false (settings.ts:1107); project overrides support it. Worktree cleanup gains nullable worktreeSettledAfterDays (settings.ts:1023). Each server feature has a capability flag.
- Environment links add optional linkRevoked. Desktop stage labels add Beta. MCP delegated tasks add hasPendingQuestion, which is server-owned.

## 2. Visible changes

Implementation and verification are tracked here while the catch-up is open.

- [x] Linked PR drag into the composer (#20102), linked PRs in # suggestions (#19357), stacked PR children (#20160). Drag source: apps/web/src/components/pullRequest/ThreadPullRequestsPanel.tsx:162.
- [x] PR link preference and middle-click (#19719, #19854): IntegrationsSettings.tsx:603-634, useOpenChangeRequestLink. CW: IntegrationsSettingsView, PullRequestsController and PR rows.
- [x] Delete branch after merge or close (#19257): pullRequestDetail.logic.ts:1141-1154 and PullRequestDetailPanel.tsx:1467-1481, 2238-2265. Requires both capability and viewer permission. CW: PullRequestDetailView and wire capability.
- [x] Compaction follow-ups queue (#20184): apps/web/src/components/chat/ChatComposer.tsx:3974,3997,4009,4173 and packages/client-runtime/src/state/composerDispatch.ts. CW: ComposerLogic and ComposerController.
- [x] HTML image viewer (#20036): apps/web/src/components/files/BrowserDocumentFrame.tsx:254-269. CW: HTML render view and native expanded image preview.
- [x] Newest models first (#18494): apps/web/src/components/chat/modelPickerSearch.ts:55-114. Exact full names precede fuzzy matches; equal scores preserve provider order. CW: ModelCatalog.
- [x] Single-line activity banners (#20194): ComposerBannerStack.tsx. CW: Composer banners.
- [x] Breadcrumb parent navigation (#15045): apps/web/src/components/files/FileBreadcrumbs.tsx:102-125,280 and filePath.ts. CW: FileBreadcrumbsView, FileSurfaceView and FilesController.
- [x] Keep threads with a PR (#14642): SettingsPanels.tsx:2433-2450. CW: GeneralSettingsView and settings schema.
- [x] Beta stage (#20032): branding.logic.ts. CW: SidebarStage fallback.
- [x] Database storage notice (#19437), settled worktree cleanup (#15208), command output streaming (#15094).
- [ ] Smaller changes: sent queue badge reads "from queue" (#19849), waiting icon (#19617), update-everything progress (#19837), no handoff banner before a sent message (#20033), PR project filter order/excluding Scratch (#19180/#19179), subagent banner wrapping (#19170), Mermaid toggle anchoring (#19601), T3 Connect publish-only repair (#19389) and re-enable pairing (#19354).

## 3. Client performance

- [x] Final PR summaries avoid periodic refresh (#19374). T3 only treats merged as final; the user explicitly requests both merged and closed. Explicit refresh remains available.
- [x] Unchanged provider data avoids composer/picker rebuilds (#20392, packages/client-runtime/src/state/serverConfigProjection.ts:25,101). CW keeps the newest check timestamp while comparing visible provider content.

## 4. Method and validation

The release archive was downloaded from GitHub and checked against SHA256SUMS. The new sandbox uses its own home inside CandyWrapper-research/sandbox and port 47394. Existing sandbox and live service processes remain untouched. Compatibility, screenshots, tests and performance results will be recorded before completion.

## 5. Review and remaining work

The review covered all changed Swift files, the recorded transcript and the recorder. It fixed a partial-policy default that incorrectly filled the new retention period with a Boolean, retained the breadcrumb trail when navigating upward, guarded branch deletion with both host and viewer permissions, bounded terminal escape parameters and released command-output subscriptions when rows or the window hide. The drag reader rejects malformed, oversized and non-HTTP references. PR chips use URL-scoped IDs (pullRequestDetail.logic.ts:947-952), so two repositories with the same PR number stay distinct. Database storage and live command output are capability-gated for older servers.

Implemented from the smaller-change list: queue badge wording, waiting icon and elapsed duration, empty-thread handoff suppression, and PR project ordering without Scratch. Native composer activity labels already truncate on one line.

Still open from the full 207-commit inventory:

- Cross-environment dropped-thread transcript attachments. The new HTTP route is additive; the client still refuses those drops.
- Per-machine Update everything pipelines (#19837), Connect publish-only repair (#19389) and re-enable pairing (#19354, optional environmentHttp.ts:419 linkRevoked).
- Subagent banner wrapping, Mermaid toggle anchoring, and the smaller suggestion/review-guide labels identified in the commit inventory need a focused visual comparison.
- Live command output normalizes terminal cursor moves and retains a bounded tail, but uses plain text. ANSI color and follow-end scrolling need the matching terminal renderer.
- PR drag, branch deletion and HTML image preview have logic coverage and code review, but have not been driven end to end against a signed-in PR host. Tests must continue to use sandbox fixtures, not real account sign-in.

The main UI checks used isolated builds against 3234 and 3105. Each completed a tiny Haiku turn. The 3234 check opened a thread, settings, Storage, Integrations and the command palette in light and dark themes and toggled the sidebar. Screenshots stay outside the repository. The recorded 3234 config, database stream and thread snapshot are in `fixtures/transcripts/20-nightly-3234.jsonl`; tokens and host paths were scrubbed. Test and performance totals are recorded in PROGRESS.md.

Final checks for this piece: the full suite ran 1,527 tests. Its remaining failure was the old breadcrumb root expectation; after correcting it and completing the review fixes, all 107 focused checks passed. A fresh debug app build checks the app target as well. The performance review against the wide-table baseline reports no threshold regressions: 182 ms median window launch, 0.047% idle CPU, 34.2 MB idle footprint and 364.8 ms scroll CPU. No scroll sample stalled for 50 ms; one thread-open sample stalled for 51 ms. The release app measurements preceded the final small PR and command-lifetime review fixes; the final audit after the runtime task will measure the completed tree again. See `docs/perf/2026-10-17-1d8f066-dirty-w1.md`.
