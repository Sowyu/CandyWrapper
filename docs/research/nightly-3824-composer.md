# Nightly 3824 composer, chips, queue and notices

Worktree task: design-composer. Local commits only. The 3824 scope update replaces the 3814 composer port with #25869 while retaining the chips, queue and notices from the earlier brief.

## Source

Read the diffs from 3669 to 3814 for the scoped files, then 3814 to 3824 for the replacement composer. References below name the 3824 tag unless marked 3814.

- `apps/web/src/components/chat/ComposerSurface.tsx:7-89`: 16px card, small light shadow, and a plain full-width context row. The removed tray also removes its seam mask and outline.
- `apps/web/src/components/chat/ChatComposer.tsx:3256-3488`: expanded desktop composer, 16px editor padding, 8px footer padding, attach at the left, grouped controls beside Send. The default composer no longer consumes the scroll-collapse preference.
- `apps/web/src/components/chat/ComposerControl.tsx:12-82`, `ComposerControlsBar.tsx:155-364` and `ProviderModelPicker.tsx:195-274`: text hover feedback, no chevrons, grouped model and effort, conditional permissions chip and overflow ownership.
- `apps/web/src/components/chat/EffortGlyph.tsx:19-85`, `TraitsPicker.tsx:514-744`: Word or Bars, special levels always named, Fast and Ultrafast bolts, Permissions in the effort menu.
- `apps/web/src/components/chat/ComposerFooterControls.tsx:93-247`: a horizontal Permissions toggle with previewed name and description. Full access uses shield-off (`runtimeModeConfig.ts:23-28`).
- `apps/web/src/components/ComposerContextPermissions.tsx:7-39`, `BranchToolbar.tsx`: draft permissions in the context row, one machine glyph and no folder beside it.
- `apps/web/src/components/settings/AppearanceSettingsPanel.tsx:273-309`, `packages/contracts/src/settings.ts:329-333,359,467`: `effortDisplay`, default `label`, with Word and Bars in Appearance. CandyWrapper retains its own collapse preference and row for Redesign.
- `apps/web/src/components/ContextChip.tsx:8-89`, `components/contextChipParts.tsx`, `lib/contextChipAccents.ts:1-26` at 3814: plain colored chips, fixed blue images, image borders, and hover underlines. The editor measures the new chip geometry separately from CandyWrapper's themes.
- `apps/web/src/components/ComposerPromptEditorTiptap.tsx:1077,1819` at 3814: two-line minimum and full-strength placeholder. `composerPlaceholder.ts:1` supplies the shorter copy (#26155).
- `apps/web/src/components/chat/ComposerBannerStack.tsx:35-52`, `ComposerBanner.tsx:65-103` at 3814: all notices stay attached and share edges. The obsolete peek disappears, taking its shadow with it (#25329). The bottom toolbar no longer has a separate tray fill (#25335, superseded by 3824).
- `apps/web/src/components/chat/QueuedRunsControl.tsx:218-555` at 3814: dashed queued bubbles, full text, sender attribution and Send now actions. The original row, grip and drag code remains for Redesign and Glass. `threadWorkflows.ts:130-174` retains the server-version gate for Send now during compaction. `ChatView.tsx:2948-2963` at 3824 mounts the queue after the thread status in the timeline footer, so it scrolls with the messages.
- `packages/provider-core/src/modelShortName.ts:1-71` and `packages/client-runtime/src/providerClients.ts:19-59` at 3814: spoken trigger labels. The old driverless naming API stays unchanged for CandyWrapper's existing surfaces.

The stylesheet and generated token changes match integration commit `b748ac6b`. No shared primitive implementation changed in this group.

## References and checks

Component generators identify their source version. Composer footer and Run on use 3824 markup; chips, editor, attachments, queue and notices retain the latest markup that 3824 ships. Queue now has component references for user, edit, agent, automation, server, guest and multiline rows.

The MCP hover-card fixture previously forced a 320px width even though `ThreadHoverCard.tsx:6-31` sets only `max-w-80`. Its wrapper now shrinks to the content, as the floating popup does. No ceiling or threshold changed.

The recorded 3814 token-only baseline in [nightly-3814-fidelity.md](nightly-3814-fidelity.md) is the before measurement. Counts below refer to distinct failing pixel cases; aggregate failures appear separately. The before and after references use different source versions because this task updates their markup and stylesheet as instructed.

| Suite | Before | After | Component cases checked |
|---|---:|---:|---:|
| ComposerFidelityTests | 2 | Deferred screens | 0 |
| ComposerAttachmentsFidelityTests | 4 | 0 | 10 |
| ComposerFooterFidelityTests | 7 | 0 pixels; 2 fit assertions | 16 |
| ComposerMenuFidelityTests | 6 | 0 | 12 |
| ComposerRichTextFidelityTests | 8 | 0 | 16 |
| PickersFidelityTests | 2 | Deferred screens; behavior passes | 0 |
| QueueFidelityTests | 0 | 0 components; screen deferred | 14 |
| BannerStackFidelityTests | 10 | 0 | 20 |
| NotificationsFidelityTests | 8 | 0 | 12 |
| McpFollowupsFidelityTests | 0 cases; mean failed at 48.05% | 0; mean 2.71% | 14 |
| RunOnFidelityTests | 11 | 0; mean 2.54% | 20 |

The original BannerStack report repeats its 10 failing cases, producing 20 assertions. The Pickers report has two failing cases, one emitted only by a direct assertion. No ceiling or threshold changed.

The remaining footer failures are `cluster.overflow-access.rest.light` and `.dark`, at the fit-state assertion. Both expect one hidden block and two icon-only blocks. In 3824 the compact permissions control is no wider than the overflow control; replacing it with overflow cannot create room, so fitting proceeds directly to hiding both blocks. The fixture's requested state is unreachable. Its pixel comparison passes, as do all 16 footer images. This task leaves those two assertions failing rather than deleting the case or adding a fitting exception.

Validation: `scripts/test --fast` passes 2,216 Swift Testing tests and 19 XCTest tests. `scripts/test --filter RedesignBaselineTests`, run alone, passes all 80 baseline images exactly. The scoped component run checks 134 images, with only the two footer fit assertions above failing. Queue keyboard behavior, its timeline-footer placement, effort mapping, overflow menu keyboard handling and live-turn layout checks pass. The isolated app builds with `scripts/build-test-app design-composer`. The empty timeline document now updates its height when the smaller composer changes its bottom inset, fixing the live-turn replay regression exposed by this design.

The Redesign baseline must run alone: combining it with the picker fidelity suite changes persisted picker settings before the two model-settings images render. Its standalone run is the required exact comparison. Glass continues to use its existing composer and frozen palette; the fast lane's palette baselines pass.

Screen comparisons against `design/reference/` remain for the integration pass: ComposerFidelityTests (01, 03a, 04, 04n), PickersFidelityTests (13, 41, 42, 03c), and QueueFidelityTests screen 29. This task does not replace those screens.

No primitive changes are required from the primitives group. #25316 and #25335 are superseded by 3824's plain context row and complete composer outline. #26252 and #26306 are included with the chip port; #26158 is included with the one-glyph machine control. #25270 was already ported in `f4d4d618` and needs no change here.

No screen interaction, release, push or live-server work ran. The integration session owns the new full-screen captures and full merged review. Shared merge points are `ThreadPanelView`, `TimelineView`, `ComposerController`, `GitController`, the Appearance and General settings pages, their search catalog and the settings schema.
