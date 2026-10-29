# Redesign pixel baseline

Recorded from `979c85e5a6a0e47429af04291880d05bd3a69792` on macOS 27 with Xcode 27, before the default-theme design changes. These are CandyWrapper's own Redesign (Experimental), `candywrapper-dither`, never T3 references. No production code changes form part of the recording.

Run the guard from the repository root:

```sh
scripts/test --filter RedesignBaselineTests
```

Regenerate deliberately on the baseline revision, with the test harness present:

```sh
CANDY_RECORD_REDESIGN_BASELINE=1 scripts/test --filter RedesignBaselineTests
```

Run through `scripts/test` in the background with a 30 minute limit, as AGENTS.md requires. Keep at least 40 GB free. Run this filter alone when recording or reviewing the baseline. Recording overwrites the PNGs; never record simply to accept a regression.

The 80 PNGs cover 40 surfaces in light and dark at 2x: composer empty, typing, queued, approval, question and attachments; markdown top, code bottom and command timelines; populated sidebar; model, traits and access pickers; git menu; PR detail panel; usage chart; notice and banner stack; toast; command palette; thread toolbar; unified and split diffs; all 17 Redesign settings tabs, including General, Appearance, Models and providers, Orchestrator, Connectors, Experimental and About. Settings capture the first 1,800 points at most, rather than an unbounded document.

Fixtures and builders come from the existing fidelity suites and recorded transcripts. The command palette root fixture is copied from DesignSystemTests because FeaturesTests cannot import another test target. Both palettes use `ThemeDefinition.dither`'s matching variant. Fonts, appearance, accent, dimming, motion and panel animation duration are pinned and restored. Timeline time is fixed at 2026-10-28 12:00 UTC; sidebar and PR clocks and usage dates use the existing fixed fixtures.

The renderer follows `Snapshot.image`'s offscreen layer capture. It draws the existing composer attachment fixture synchronously through `DitherArt.render`, sets its art frame explicitly, and supplies the same thumbnail as a completed preview to asynchronous attachment views. This avoids desktop wallpaper, decode timing and transient loading frames. It removes layer animations before capturing model end states. The guard does not exercise loading skeletons, image decoding or wallpaper selection.

Every decoded sRGB RGBA channel must match, with zero tolerance, including alpha. Missing images and changed dimensions fail. Pixel failures write magenta diff and actual PNGs into the per-process temporary folder printed by the test. Keep the same OS, fonts and rendering environment when comparing; platform rasterization changes require deliberate baseline review.

No requested surface was dropped for nondeterminism. Relative-time usage-limit banners and scheduled-task countdown states are outside this baseline; the usage chart and settings tabs use fixed or empty existing fixtures instead.

Validation: recording and two consecutive fresh-process guard runs passed. Both comparisons found zero differing pixels across all 80 images. `scripts/test --fast` passed; it excludes this longer visual guard.

Phase 3 (2026-10-29) re-recorded 18 images on purpose: the six composer states and the three thread timelines now show Nightly 3824's grouped composer controls and placeholder, and chat tables at their natural size with only Copy. Every other image stayed byte-identical.
