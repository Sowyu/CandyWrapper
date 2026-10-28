# Thread design, Nightly 3814 and 3824

Task: design-thread, taken 2026-10-28. Local worktree commits only. Default themes follow the new design; Glass and Redesign keep their existing styling. The integration stylesheet was advanced to 3824 during this task.

## Source audit

Read the 3669 to 3814 diffs for MessagesTimeline, TimelineUserMessageRow, TimelineWorkEntryRow, TimelineWorkGroupRows, TimelineV2EventRow, V2LifecycleRow, WorkLog, TimelineToolActivityIcon, ChatMarkdown, MarkdownDetails, MarkdownCodeBlock, MarkdownTable, MarkdownFileLink, ProposedPlanCard, DiffStatLabel, TimelineMinimap, ChatHeader, ChatCanvas, ChatView, ThreadRouteView, ThreadDetailsCard, ThreadDetailsControl, ThreadDetailsPanel, ThreadDetailsSection, ThreadDetailsPrRow, ThreadRelationshipsControl, threadDetailsPanelStyles, GitActionsControl, OpenInPicker and EnvironmentMachineIcon. Also read the 3669 to 3824 diffs for MessagesTimeline, MarkdownTable and MarkdownExternalLink, and the 3814 to 3824 CSS diff.

Citations below refer to `apps/web/src/` at `v0.1.4-nightly.20261028.3814` unless marked 3824.

| Area | Source | Native change |
|---|---|---|
| Sent messages, #25323 | `index.css:1136-1139,1203-1205`; `components/chat/TimelineUserMessageRow.tsx:468-478` | The integration's opaque message palette, with 16pt corners in default themes |
| Markdown body and details | `components/ChatMarkdown.tsx:1650-1656`; `components/chat/MarkdownDetails.tsx:53-58` | 90% body text; retain 80% for Glass and Redesign |
| Inline code and strong | `index.css:2118-2133` | Transparent border, 10% foreground fill, 4pt corners, relative padding, semibold strong text |
| Code blocks | `index.css:2135-2143` | 8pt default corners |
| Tables, #26449 | 3824 `index.css:2196-2250`; `components/chat/MarkdownTable.tsx:29-34`; `MarkdownExternalLink.tsx:57-70` | 14pt cells, wrap in every lane, cap cells at 24rem, no expand control, permit long external-link words to shrink while keeping short ones whole; preserve uncapped formula cells |
| Markdown file chips | `components/ContextChip.tsx:8-12,68-77`; `components/chat/MarkdownFileLink.tsx:324-332` | Remove the default pill and padding, inherit text size, baseline alignment and hover underline |
| Plans | `components/chat/ProposedPlanCard.tsx:161` | 16pt default corners |
| Details card | `components/chat/ThreadDetailsCard.tsx:104-117`; `threadDetailsPanelStyles.ts:19-47`; `ThreadDetailsSection.tsx:26-32` | 16pt card, 8pt controls, separators only on hover/open, wider heading inset |
| Changes totals | `components/GitActionsControl.tsx:1629-1649`; `components/chat/DiffStatLabel.tsx:29-49` | 12pt totals, 6pt gap, muted zeros, foreground diff roles |
| PR rows | `components/chat/ThreadDetailsPrRow.tsx:397-447`; `ThreadDetailsControl.tsx:53-78` | Wrap title to two lines, 20pt action row and solid primary/destructive action pills |
| Previous agents | `components/chat/ThreadRelationshipsControl.tsx:139-169` | Details row with Bot, failure count, total and disclosure chevron |
| Machine icon | `components/EnvironmentMachineIcon.tsx:8-29` | New Mac mini shape; 1.75pt custom Mac mini and Mac Studio strokes |
| Minimap | `components/chat/TimelineMinimap.tsx:218-242` | 60% current, 25% resting, 55% in-view strips |
| Narrow maximize, #25389 | `components/ChatView.tsx:3795-3804` | Expose maximize beside the sheet controls and draw the cluster above the sheet |
| Avatar verdict, #25829 | `components/pullRequest/pullRequestPresentation.tsx:350-370`; `PullRequestSummaryTab.tsx:690-703` | 12pt verdict glyph, 3pt canvas stroke, 50% stale opacity |

The VS Code brand image already has no frame in the native details row (#25321). Stopped-run tones (#25830) and skill popover behavior (#25432) were already ported in phase 1. No wire contract changed here.

Markdown layout now keeps the view's appearance through its background work and parallel block layout. The theme gate uses that appearance, including when one appearance uses Redesign and the other uses a default theme. No polling or idle animation was added.

## References and fixture data

Regenerated the scoped component references against the integration stylesheet. Generator helpers read the 3814 tag explicitly where the research checkout still holds 3669. The table markup uses 3824's single copy footer. The two screen suites now read `design/reference-3824/` at the existing crops, after merging capture commit `e3acefd1`. The wide fixture preserves the panel's window origin before cropping, so AppKit does not reserve traffic-light space inside the panel. Old screen references and all Redesign baseline PNGs remain unchanged.

`fixtures/transcripts/3814-design-threads.jsonl` records only read-only subscriptions for the seeded Markdown and commands threads behind the new screen references. It contains no HTTP auth exchange, provider config or newly generated turns. Sandbox paths are scrubbed while preserving their shape and monospace character count. The narrow screen fixture follows its capture plan at 30% scroll, with appearance selected before layout. Only the default-theme screen tests use it; Redesign keeps the original ThreadPreview fixture.

## Verification

The final 3824 run checks 308 pixel cases across 12 suites: 298 component cases pass, and 7 of 10 screen cases pass. The before counts below come from `nightly-3814-fidelity.md`, measured after the token refresh and before this implementation. They are failing case counts, excluding aggregate assertions. No ceiling or tolerance changed.

| Suite | Before | After |
|---|---:|---:|
| ThreadFidelityTests | 6 | 2 |
| ThreadViewFidelityTests | 9 | 0 |
| ThreadLeftoversFidelityTests | 7 | 0 |
| ThreadLineageFidelityTests | 11 | 0 |
| ThreadSweepFidelityTests | 4 | 0 |
| ThreadCompletionFidelityTests | 7 | 0 |
| TimelineGapsFidelityTests | 12 | 0 |
| MarkdownFidelityTests | 9 | 0 |
| MathFidelityTests | 76 | 0 |
| ReferenceScreensFidelityTests | 5 | 1 |
| WP717FidelityTests | 3 | 0 |
| SmallAreasFidelityTests | 5 | 0 |


The failing-case total falls from **154 to 3**. All aggregate checks pass beyond those three case assertions. ThreadView's mean is 4.80%, including six new avatar-verdict cases; its existing 8% all-cases assertion also passes. No case, ceiling, threshold or exception was loosened.

| Remaining case | Difference | Existing ceiling |
|---|---:|---:|
| `ThreadFidelityTests.wholePanel / 03c-kitchen-sink-bottom.light` | 5.79% | 5.50% |
| `ThreadFidelityTests.wholePanel / 03c-kitchen-sink-bottom.dark` | 5.61% | 5.50% |
| `ReferenceScreensFidelityTests.referenceScreens / 03n-narrow.light` | 5.51% | 5.50% |

The remaining screen renders show a small accumulated vertical offset through the table, code and callout, plus differences in code token colors, font weight and wrapping. The references are the current 3824 captures, and the seeded reply content matches. These native renderer differences remain unresolved; the narrow light case still fails despite its small excess. No pixel masking or fixture-specific offset was added.

Required checks on the merged branch:

- All 12 scoped fidelity suites ran in `/tmp/design-thread-3824-fidelity.log`; three screen cases fail as listed above.
- `scripts/test --filter RedesignBaselineTests --no-parallel --jobs 2` passes all 80 images exactly. Log: `/tmp/design-thread-3824-baseline.log`.
- The parallel fast run reports one failure in `MarkdownBackgroundLayoutTests.viewLaysOutInBackground`: its background signature contains ten legacy table toggles while the default-theme expected signature contains none. Legacy table tests temporarily change global theme flags; the same background test passes in the serial run. This is a test-isolation race, not a relaxed assertion. `scripts/test --fast --no-parallel --jobs 2` passes all 2,220 Swift Testing tests and 19 XCTest tests. Log: `/tmp/design-thread-3824-fast-serial.log`. Glass palette baselines pass in this lane.
- Secret scan and `git diff --check` pass. Offscreen renders were inspected; no GUI app, new server or sandbox turn was started by this task.

The settings-row changes merged into `catchup-new-design` after capture integration are left for the main session's combined validation. This branch integrates through the 3824 capture merge `e3acefd1`.

The final images and reports are in `/tmp/design-thread-3824/`. This task did not run a release or a full integration performance review; the main integration session owns that review across groups.

## Integration dependencies

Merged the primitives group through `26f6fc7b` and the composer group through `7ed5202f` from `catchup-new-design`. The chip references use inline accent values, as the compiled stylesheet does not include arbitrary literal-accent utility classes. Attachment details sit inside ContextChipLabel, matching upstream. The retained task drawer reference reuses the composer group's current attached-surface helper. DiffStatView's foreground-role change is in DiffRowViews.swift and needs to survive the diff group's merge.

The 3824 MessagesTimeline diff (`apps/web/src/components/chat/MessagesTimeline.tsx:1574-1720`) adds deferred-history loading, retry labels and skeletons. This design task does not add the missing deferred-history state/protocol path. The existing native folds still render their settled content. That loading path remains a follow-up. No further primitives or composer implementation is needed for the passing component cases. The main session still needs to preserve the diff foreground roles when merging the diff group and include the later Settings-row changes in its combined validation.

## Local implementation commits

The branch also contains integration merges for the stylesheet, shared primitives, composer, Settings and 3824 screen captures. No commits were pushed.

| Commit | Subject |
|---|---|
| `e7f57ea7` | docs: claim 3814 thread design port |
| `c0ae2a2a` | fix(thread): show reviewer verdict glyphs on avatars (#25829) |
| `4966f7d1` | fix(thread): keep maximize visible in the narrow panel sheet (#25389) |
| `aa93c97f` | fix(thread): draw narrow sheet controls above the panel (#25389) |
| `1fd4b2fe` | fix(thread): apply the new default timeline and details design (#24865) |
| `cb7aa56d` | fix(thread): finish avatar verdict painting (#25829) |
| `1a86e6d7` | fix(markdown): adopt wrapping tables and the new chat typography (#26449) |
| `ab86e874` | fix(thread): keep verdict glyphs outside the avatar clip (#25829) |
| `2bda130d` | fix(thread): cover scrolled content with the default header (#24865) |
| `c1680a5a` | test(thread): refresh default design component references |
| `4b407fec` | test(thread): refresh references with the shared primitives |
| `b3851c9d` | fix(markdown): keep formula cells at their natural width (#26449) |
| `142c2cc7` | test(thread): match capture states and chip accent markup |
| `96a41f27` | test(thread): use the current attached banner surface |
| `3fd86b1e` | fix(thread): use the lighter workstation icon stroke (#24865) |
| `a389259b` | fix(markdown): include formula boxes in table minimum widths (#26449) |
| `606b2fd8` | fix(markdown): align image chip borders to the text baseline (#24865) |
| `5f374c27` | test(thread): keep the captured panel at its real window origin |
| `a5617290` | test(thread): compare default thread screens with Nightly 3824 |
