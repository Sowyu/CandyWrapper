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
