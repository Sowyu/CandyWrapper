# Fidelity at Nightly 5258

Written 2026-11-25 on the Mac mini M2 Pro (task repin-5258, branch `repin-5258`). `design/t3-source/main.css` is 5258's `client/assets/main-DY6PYWI3.css`, and 4928's stays as `main-4928.css`.

## Token changes from 4928

`scripts/extract-tokens --version v0.1.13-nightly.20261125.5258` with chrome-headless-shell 156.0.8078.70. No token changed value and none was removed. Every semantic color, radius, text size, shadow, easing, number and raw string resolves exactly as it did at 4928, so CandyWrapper's own frozen palettes and Redesign see no change.

Added:

- `--color-rose-300`, `#ffa1ad` in both themes.
- `--color-rose-700`, `#c60036`.
- `--color-sky-700`, `#0069a8`.
- `--color-violet-700`, `#7008e7`.
- `--html-preview-max-width`, `46rem`, as `Tokens.LengthRem.htmlPreviewMaxWidth`.

Tailwind emits a palette color only when a class uses it, so the four colors are new because 5258's Workflows run chips use them (`WorkflowRunFeed.tsx:139-143`). The Workflows chip view had a hand-converted copy of them, which now reads the extracted tokens.

Three new custom properties stay unresolved, like the other context-dependent ones: `--chat-lane-inset-end`, `--chat-lane-inset-start` and `--chat-timeline-gutter`.
