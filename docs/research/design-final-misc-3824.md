# Final miscellaneous design fixes at 3824

Task design-final-misc, taken 2026-10-28, starts at 3b27d2f6. Local commits only. Offscreen checks only. Diff panels and turn-chat screen crops belong to the parallel task.

## Redesign constructor color isolation

The initial parallel `scripts/test --filter 'Fidelity|RedesignBaselineTests'` reproduces the reported failure exactly: 132 light pixels and 124 dark pixels in settings-models. Pixel inspection finds the same cause in both images: the baseline dot is RGB (251, 44, 54), and the failing dot is RGB (251, 65, 74), the dark destructive color. No provider status, geometry or animation changes.

`ProviderListRow.init` converts the shared dynamic destructive NSColor directly to CGColor before the row has a window or an explicit appearance. The resulting fixed layer color depends on AppKit's ambient drawing appearance left by previous snapshots. Setting NSApp.appearance does not scope that conversion. The original standalone baseline construction resolves it in Aqua in both themes; later drawing the dark canvas cannot update that fixed CGColor.

The Redesign fixture now scopes settings-page construction with `NSAppearance.performAsCurrentDrawingAppearance` in Aqua. That preserves the original construction colors and restores the prior drawing appearance immediately. Theme globals remain pinned and restored synchronously, with no suspension during the test. Production rendering, baseline images and the zero-pixel assertion are unchanged.

The first focused parallel check passes all 80 exact images. Final repeated combined verification follows after the two layout fixes.

## Source audit

All T3 paths below refer to the read-only tag v0.1.4-nightly.20261028.3824, read with git show because the checkout has an older tag checked out.

- apps/web/src/components/chat/ComposerControl.tsx:12-16: desktop 14pt font-medium composer controls.
- apps/web/src/components/chat/ComposerFooterControls.tsx:96-153: the permissions chip and interaction-mode control.
- apps/web/src/components/chat/TraitsPicker.tsx:653-672: the effort control's negative start margin, padding and muted word.
- apps/web/src/components/chat/ProviderModelPicker.tsx:183-207,233-264: model control, 16pt provider mark and label.
- apps/web/src/components/settings/ProviderModelsSection.tsx:294-348,470-475,499-528: model toolbar, negative trailing button margin, grid spacing and inline text metrics.
- apps/web/src/components/settings/ProviderSettingsPanel.tsx:1031-1059: provider list dividers and editor padding.
- apps/web/src/components/settings/ProviderInstanceCard.tsx:818-821,1134-1167: status dot, Status and Display name rows.

## Providers panel

The status line was one point shorter because the screen fixture omitted its authenticated account. T3's masked account uses 11pt monospace with 1.5 line height, aligned on the baseline with 12/16 status spans (`components/settings/RedactedSensitiveText.tsx:44-54` and `ProviderInstanceCard.tsx:831-849,1078-1086`). That makes the mixed line 17pt tall. The default provider status row now reserves that line height when an authenticated account is present. The fixture supplies a synthetic account address. Redesign keeps its original single Display name row and status metrics.

The one-point correction aligns Runtime, Environment and Models with the recorded DOM: -64.5, 405.5 and 535.5pt respectively, at the unchanged 665.5pt scroll offset. The model toolbar now includes the source's -8pt trailing margin on Add custom model. Model name, slug and capability columns retain fractional text widths instead of adding a rounded extra point. Classic themes keep their old widths.

The stacked provider card also measured its list at the 272pt desktop-column width even when it rendered at 716pt. That produced 20pt of unused height below the editor. The default layout now measures the list at its actual width; the classic layout keeps its existing measurements.

The focused panel comparison improves from 5.25% to 3.39% light and 5.48% to 3.62% dark, under the unchanged 5% ceiling. Reviewed the offscreen ref/ours/diff artifacts in `/tmp/design-final-misc-footer4/settings-screens/`. The panel crop, scroll offset, image references and comparison tolerance are unchanged.

## Footer controls

AppKit's named medium resolves to SF's weight-510 instance. T3 requests CSS 500 (`ComposerControl.tsx:16`). The default SF composer controls now use a cached weight-505 instance, calibrated against the captured glyphs. The exact weight-500 Core Text instance renders farther from the browser capture; 505 improves both coverage and advance widths. The code marks this native-renderer compensation with its scope and removal trigger.

This applies to the shared default composer control style, not to one fixture or appearance. Glass, Redesign and custom font families retain their previous fonts. The control re-resolves its font when font preferences change; a regression test checks scaling and switching to a custom family. Font instances share the existing DSFont cache, so layout and hover do not create new descriptors and nothing runs while idle.

The unchanged 03c crop is still (841.5, 721, 155.5, 28) CSS points. Its native flow width improves from 155.188659 to 155.052902pt; the existing half-point enclosure remains 155.5pt. No test crop, ceiling, tolerance, reference or exception changed. The real picker check improves from 4.87% to 4.73% light and from 5.18% to 4.87% dark. Final images are in `/tmp/design-final-misc-fidelity-3/pickers/`.
