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
| Tables, #26449 | 3824 `index.css:2196-2250`; `components/chat/MarkdownTable.tsx:29-34`; `MarkdownExternalLink.tsx:57-70` | 14pt cells, wrap in every lane, cap cells at 24rem, no expand control, permit long external-link words to shrink while keeping short ones whole |
| Markdown file chips | `components/ContextChip.tsx:8-12,68-77`; `components/chat/MarkdownFileLink.tsx:324-332` | Remove the default pill and padding, inherit text size, baseline alignment and hover underline |
| Plans | `components/chat/ProposedPlanCard.tsx:161` | 16pt default corners |
| Details card | `components/chat/ThreadDetailsCard.tsx:104-117`; `threadDetailsPanelStyles.ts:19-47`; `ThreadDetailsSection.tsx:26-32` | 16pt card, 8pt controls, separators only on hover/open, wider heading inset |
| Changes totals | `components/GitActionsControl.tsx:1629-1649`; `components/chat/DiffStatLabel.tsx:29-49` | 12pt totals, 6pt gap, muted zeros, foreground diff roles |
| PR rows | `components/chat/ThreadDetailsPrRow.tsx:397-447`; `ThreadDetailsControl.tsx:53-78` | Wrap title to two lines, 20pt action row and solid primary/destructive action pills |
| Previous agents | `components/chat/ThreadRelationshipsControl.tsx:139-169` | Details row with Bot, failure count, total and disclosure chevron |
| Machine icon | `components/EnvironmentMachineIcon.tsx:8-29` | New Mac mini shape and stroke |
| Minimap | `components/chat/TimelineMinimap.tsx:218-242` | 60% current, 25% resting, 55% in-view strips |
| Narrow maximize, #25389 | `components/ChatView.tsx:3795-3804` | Expose maximize beside the sheet controls and draw the cluster above the sheet |
| Avatar verdict, #25829 | `components/pullRequest/pullRequestPresentation.tsx:350-370`; `PullRequestSummaryTab.tsx:690-703` | 12pt verdict glyph, 3pt canvas stroke, 50% stale opacity |

The VS Code brand image already has no frame in the native details row (#25321). Stopped-run tones (#25830) and skill popover behavior (#25432) were already ported in phase 1. No wire contract changed here.

Markdown layout now keeps the view's appearance through its background work and parallel block layout. The theme gate uses that appearance, including when one appearance uses Redesign and the other uses a default theme. No polling or idle animation was added.

## References and fixture data

Regenerated the scoped component references against the integration stylesheet. Generator helpers read the 3814 tag explicitly where the research checkout still holds 3669. The table markup uses 3824's single copy footer. Old screen references and all Redesign baseline PNGs remain unchanged.

`fixtures/transcripts/3814-design-threads.jsonl` records only read-only subscriptions for the seeded Markdown and commands threads behind the new screen references. It contains no HTTP auth exchange, provider config or newly generated turns. Sandbox paths are scrubbed. Only the default-theme screen tests use it; Redesign keeps the original ThreadPreview fixture.

## Verification

Pending final runs. The before counts below come from `nightly-3814-fidelity.md`, measured after the token refresh and before this implementation. They are failing case counts, excluding aggregate assertions. No ceiling or tolerance changed.

| Suite | Before | After |
|---|---:|---:|
| ThreadFidelityTests | 6 | pending |
| ThreadViewFidelityTests | 9 | pending |
| ThreadLeftoversFidelityTests | 7 | pending |
| ThreadLineageFidelityTests | 11 | pending |
| ThreadSweepFidelityTests | 4 | pending |
| ThreadCompletionFidelityTests | 7 | pending |
| TimelineGapsFidelityTests | 12 | pending |
| MarkdownFidelityTests | 9 | pending |
| MathFidelityTests | 76 | pending |
| ReferenceScreensFidelityTests | 5 | pending |
| WP717FidelityTests | 3 | pending |
| SmallAreasFidelityTests | 5 | pending |

## Integration dependencies

Shared controls remain owned by the primitives group: button variants, popup and glass surfaces, inputs, the command palette, toast details and selection toolbar glass buttons. Composer owns ComposerChipAttachment, its context-chip geometry and readable accent colors, image chip blue, primary action pills and quiet ThreadNow line rendering. The threadview spec now describes the new context-chip markup, so its shared-chip cases can fail until that work lands. DiffStatView's foreground-role change is in DiffRowViews.swift and needs to survive the diff group's merge.

The 3824 MessagesTimeline diff adds deferred-history loading, retry labels and skeletons. This design task does not add the missing deferred-history state/protocol path. The existing native folds still render their settled content. That loading path remains a follow-up, rather than showing a skeleton with no real request behind it.
