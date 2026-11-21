# Warm builds for new worktrees, 2026-11-20

Up to five agents build this repo at once, each in a new worktree, and each new worktree used to build CandyKit and the app from nothing. These notes record where that time goes, what does not make a new worktree warm, and the slot scheme in `scripts/warm-worktree` that does.

Measured on the Mac mini M2 Pro (12 cores, 32 GB), Xcode 27.2, with four or five other agents building at the same time, so load averages ran from 5 to 25. Wall times move with the load; CPU seconds (user) move less.

## Cold numbers

| Build | Wall | CPU | Load at the start |
|---|---|---|---|
| `scripts/check-app-build`, new worktree, new derived data | 91 s | 387 s | 5 |
| `scripts/test --filter KeybindingsTests`, new worktree, no `.build` | 145 s | not measured | 22 |
| Same `check-app-build` again, nothing changed | 11 s | 3 s | 25 |
| `swift build --build-tests` again, nothing changed, then the one suite | 2 s + 2 s | 3 s | 18 |

In the cold app build, 97 Swift compile tasks took 707 s summed, emitting modules 49 s, the asset catalog 4 s and linking 2 s. The CandyKit modules, which the app target compiles itself through Xcode, are most of it. In the cold test build SwiftPM runs 574 steps over the five library targets and five test targets. Running the one suite takes under a second, and test discovery adds about a second.

## What does not make a new worktree warm

- An APFS clone of a finished derived-data folder, used from another worktree: full rebuild, 362 s CPU. Xcode keys its build database on the source path.
- The same clone used from the same worktree under a new folder name: full rebuild, 358 s CPU. The derived-data path counts too.
- An APFS clone of `Packages/CandyKit/.build` in another worktree: full rebuild, 635 s CPU. SwiftPM keys on absolute paths the same way.
- Xcode's compilation cache (`COMPILATION_CACHE_ENABLE_CACHING=YES` with a shared `COMPILATION_CACHE_CAS_PATH` and the `*_PREFIX_MAPPING` settings): from another path it missed every task. From the same path it hit, and then the build service crashed on every replay that carried a warning (`swift::CachingDiagnosticsProcessor::replayCachedDiagnostics`, `bad_optional_access`). Retries crashed the same way. Each crash also leaves a "SWBBuildService quit unexpectedly" dialog on screen.
- Prefix maps (`-file-prefix-map`, `-fdebug-prefix-map`) only rewrite paths in outputs. They don't change how Xcode or SwiftPM decide what is stale.

A different `PRODUCT_BUNDLE_IDENTIFIER` does not invalidate anything: switching the bundle id in a warm folder took 3 s. So `scripts/build-test-app` and `scripts/check-app-build` can share one folder per worktree. Before this change `check-app-build` used one folder, `/tmp/cw-check-app-build`, for every worktree, so each agent's check rebuilt everything another agent's check had built.

## The slot scheme

Since paths decide warmth, the paths stay put and the tasks move. `scripts/warm-worktree <task>` takes one of six slots, `/tmp/cw-slot-1` to `/tmp/cw-slot-6`, checks out branch `<task>` there and links `/tmp/cw-<task>` to it. A slot keeps `Packages/CandyKit/.build` inside it and `/tmp/cw-dd-slot-N` beside it from task to task, so a build recompiles only what differs from the slot's last build. `scripts/warm-worktree --done <task>` frees the slot after the task committed. `scripts/warm-refresh` builds main in every free slot at `nice 10`, so the next task starts from current main; run it after merges.

Limits:

- A slot's first build is cold. `scripts/warm-refresh --slots N` makes N slots ahead of time.
- Six slots at about 4 GB each. A seventh task at once gets a cold worktree, and `scripts/warm-worktree` prints the command for it.
- A change to a module many files import, such as DesignSystem, still recompiles most of Features. That is Swift's dependency tracking, not the slot.
- `git worktree remove /tmp/cw-<task>` would remove the slot and its builds. Finish with `--done`.
- `scripts/preflight` counts slots apart from task builds, with their own 30 GB ceiling. Slots hold no clones, so `du` counts them right.

## Warm numbers

Slot 1 was built cold at main 34f9c53c by `scripts/warm-refresh --slots 1`: 163 s wall and 1,028 s CPU for the package with its tests plus the app, at load 15 to 19. A task branch then took the slot. It started 15 merges behind that main, so 44 Swift files differed, DesignSystem and T3Protocol among them.

| Build | Cold, new worktree | Warm slot, 44 files differ | Warm slot, one Features file changed |
|---|---|---|---|
| `scripts/check-app-build` | 91 s | 41 s | 15 s |
| `scripts/build-test-app <task>` after it | 91 s, into a second folder | 5 s | not measured |
| `scripts/test --filter KeybindingsTests` | 145 s | 66 s | about 13 s, the package build |
| `scripts/test --mine` | not measured | not measured | 104 s for a Sidebar view (38 suites), 18 s for `T3Store/WorkLog.swift` (4 suites) |

Before this change a task built the app twice from nothing: `build-test-app` into `/tmp/cw-dd-<task>` and `check-app-build` into the shared `/tmp/cw-check-app-build`, which the previous worktree had left at its own path.

In the 104 s `--mine` run, `RedesignBaselineTests` took 72 s. It failed on `image-gallery` and `settings-general`, two baselines that earlier merges changed without re-recording, so the failures were there before the edit.
