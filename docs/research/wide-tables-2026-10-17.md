# Wide Markdown tables

Source: T3 Nightly 3105, `apps/web/src/components/ChatMarkdown.tsx:562-692`, `apps/web/src/index.css:2031-2075`, `apps/web/src/components/ui/scroll-area.tsx:57-65`, and `apps/web/src/markdown-clipboard.ts:88-130,345-366`.

Tables use the code block's horizontal wheel, gesture latch, track paging and thumb dragging. Negative scroll IDs separate tables from code blocks. The clipped edges use the ScrollArea's 24-point alpha fade, shortened to the remaining overflow. Drawing the fade needs no timer and works over Classic Glass.

Cells start collapsed as requested, use a 384-point maximum column width and truncate with an ellipsis. Expanded body cells wrap; headers stay on one line. The footer changes its icon, style and label with the state. The copy menu offers Markdown and CSV, keeps full cell contents, and shows Copied for 1.2 seconds after a successful copy.

T3 3105's component initializes expansion from `wordWrap`, despite its CSS describing collapsed as the default. The user's explicit collapsed default takes precedence here.

Message IDs keep expansion and scroll state across streaming updates and clear it when a row is recycled. Root block boxes let a table toggle reuse unrelated blocks, and a height callback remeasures the affected timeline row. The first on-screen check exposed the missing row-height notification; expanding had drawn over the footer until this callback was added.

The wide-table references use T3's markup, stylesheet and scroll-fade variables in headless Chromium. The native scrollbar uses the shared code scrollbar's 7-point lane. Light and dark reference heights match within 0.02 points. The pixel difference is 4.2 to 5.6 percent, below the test's 8 percent threshold.

Validation:

- The whole suite passed 1,501 tests before the final height callback. The follow-up passed 42 Markdown, code-scroll and timeline-tiling tests, including the callback, Shift-wheel, independent table state and growing rows.
- The sandbox Haiku turn produced a six-column process table with long descriptions. On screen, checked collapsed and expanded cells, horizontal scrolling to the CPU column, thumb dragging, the Markdown/CSV menu and the Copied check. Repeated in stock light/dark and Classic Glass light/dark. The footer stays below the expanded table.
- Reviewed the diff for state recycling, retained layouts, hit regions after scrolling, clipboard escaping and idle work. The change introduces no repeating timer. The existing copy feedback resets once after 1.2 seconds.

Performance: [complete review](../perf/2026-10-17-4e652fa-dirty-w1.md), compared with the last saved run, reports no threshold regressions. Median window launch is 198 ms, idle CPU 0.043 percent, idle footprint 34.2 MB, scrolling CPU 365.4 ms, and streaming CPU 1.2 percent. Markdown layout is 48.6 ms versus 47.9 ms; incremental streaming layout is 0.497 ms versus 0.494 ms. Two scrolling samples recorded about 60 ms stalls where the baseline recorded none; the ranges overlap and the report does not flag them as a regression. Keep this observation visible in the final audit.
