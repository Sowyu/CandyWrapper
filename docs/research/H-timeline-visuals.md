# H. Timeline and thread view visuals (milestone 4)

Source: T3 Code tag in `T3_VERSION`, `/Users/mrm/CandyWrapper-research/t3code/apps/web/src` (paths below are relative to it) and `design/t3-source/main.css` (cited as `main.css:N`). Values are CSS px. Colors use our `Palette.*` names, light / dark.

## 1. Chat canvas

Citations: `index.css` is T3's uncompiled stylesheet (`apps/web/src/index.css`). `main.css` is its compiled form (one minified line, so line numbers do not apply). Both give the same values; cite `index.css:N` for the rule and trust `docs/design-tokens.md` for resolved colors.

### 1.1 Lane width per chat width setting

The setting is `chatWidth` (`comfortable` default, `wide`, `full`). The app writes it to `<html data-chat-width>` (`routes/__root.tsx:278-281`). It only changes `--chat-content-max-width`:

| Setting | `--chat-content-max-width` | Source |
|---|---|---|
| comfortable | 46rem = 736px (`Tokens.LengthRem.chatContentMaxWidth`) | `index.css:128` |
| wide | 72rem = 1152px | `index.css:2078-2080` |
| full | 100% | `index.css:2082-2084` |

The same variable sizes the timeline lane (`.chat-content-lane`, `index.css:921-926`: centered, `width:100%`, `min-width:0`, `max-width:var(--chat-content-max-width)`), the composer, the thread status line (`ThreadStatusLine.tsx:20`) and the context-compaction divider (`MessagesTimeline.tsx:2120`).

Every timeline row is `div.messages-timeline-row-frame` (`padding-inline:0`, `index.css:928-930`) holding `div.chat-content-lane.overflow-x-clip` (`MessagesTimeline.tsx:1519-1527`). The lane clips horizontal overflow, so nothing may draw outside the 736px column (focus rings and shadows are clipped).

### 1.2 Horizontal padding of the scroll area

`.messages-timeline-scroll` is the scroll container (`MessagesTimeline.tsx:1620`, `overflow-x-hidden overscroll-y-contain`, `scrollbar-gutter-both`). Its inline padding (`index.css:2332-2360`):

- Below 640px viewport width: `0.75rem` = 12px each side.
- At 640px and up: `3rem` = 48px each side.
- Each side then adds `--chat-lane-inset-*` (0 unless a floating preview or details card pushes chat aside) and subtracts `--chat-timeline-gutter`. The gutter is half of `offsetWidth - clientWidth` of the scroller (`ChatCanvas.tsx:84-86`), the scrollbar space reserved on both sides. With the 6px overlay scrollbar (`--app-scrollbar-width`) it is 0 or 3px. Native port: overlay scrollbars give 0.

The composer lane uses the same 12px / 48px (`index.css:2322-2331, 2342-2349`), so message bubbles and composer share edges.

### 1.3 Effective content width

`ChatCanvas` measures a hidden probe (`ChatCanvas.tsx:139-143`): `w-(--chat-content-max-width) min-w-[40rem] box-content ps-3 sm:ps-12`. It reads `padding` = 12 / 48, `maxChatWidth` = 736 (or 1152, or the container width for full), `minChatWidth` = 640 (`40rem`). `resolveChatCanvasLayout` (`chatCanvasLayout.ts:26-60`):

```
centeredWidth = clamp(container.width - 2*padding, 0, maxChatWidth)
laneRight     = detailsCard ? detailsCard.left - 32 : container.width - padding   // 32 = DETAILS_CARD_CLEARANCE
normalWidth   = clamp(laneRight - padding, 0, centeredWidth)
normalLeft    = max(padding, min((container.width - normalWidth)/2, laneRight - normalWidth))
```

Without a preview or card (milestone 4 has neither), the lane is `min(736, W - 2*48)` wide and centered, where W is the chat column width (window minus sidebar minus right panel). At 1100px window with a 232px sidebar (reference 03a), W = 868, lane = 736, 66px side margins beyond the 48 padding. Below 832px column width the lane shrinks to W - 96. Below 640px viewport the padding drops to 12 so the lane is W - 24.

Note `sm` is the Tailwind viewport breakpoint (640px of the window), not the column. A narrow column inside a wide window keeps 48px padding.

### 1.4 Vertical rhythm

- List header spacer: `h-3 sm:h-4` = 12px / 16px above the first row (`MessagesTimeline.tsx:395`). When `topFadeEnabled`, a `--workspace-titlebar-scroll-fade-height` (1.5rem = 24px) spacer is used instead (`:396-398`), and the scroller gets the `topbar-scroll-fade` mask (`index.css:439-475`): top 24px+1px fades with stops transparent 0%, 10%@10%, 30%@24%, 58%@42%, 82%@62%, 96%@82%, black 100%; the last 6px column (scrollbar) stays unmasked.
- List footer: composer inset (height of the floating composer, dynamic) then `h-3 sm:h-4` (`:399-413`). Children (status line, history controls) render above.
- Rows have no `gap`. Each row's own wrapper adds trailing padding (`MessagesTimeline.tsx:2007-2040`):

| Row kind | Bottom padding |
|---|---|
| work, work-live, work-toggle, thinking, subagent group | none (the `WorkLogBlock` supplies it, see 3.5) |
| turn-fold, working | `pb-1.5` = 6px |
| assistant message without meta row (commentary), worktree-setup, event, attempt-fold, html-render, mcp-app | `pb-2` = 8px |
| everything else (user message, final assistant message, assistant-meta, proposed-plan, context-compaction) | `pb-4` = 16px |

- `WorkLogBlock` bottom padding (`WorkLog.tsx:13-24`): `pb-0` when `continues` (another work row follows in the same group) or layout is `group-header`; `pb-1` (4px) for `group-content`; `pb-2` (8px) standalone.
- Virtual list estimate: `estimatedItemSize=90` (`:1580`). Native lists should not copy the estimate, only the measured heights.

### 1.5 Scroll behaviour that affects layout

- Opens scrolled to the end unless a remembered position says otherwise (`initialScrollAtEnd`, `:1583`). Stays pinned when new content arrives (`maintainScrollAtEnd`, threshold 1px).
- `overflow-anchor:none`, `overscroll-y-contain`.
- Scroll offset when jumping to a row from the minimap: `viewOffset: 24`.

(Reference: `design/reference/03a-kitchen-sink-top.light.png`. At 2x the user bubble starts 66px from the column edge on the right and the assistant text at the lane left edge, matching 48px padding plus centering.)


## 2. Thread header

### 2.1 Bar

`<header data-chat-header>` (`ChatView.tsx:11285-11293`) in the web build (non-Electron path), height pinned by `--workspace-topbar-height` = 52px (min and max too). Background `bg-background` (`Palette.background`, `#fcfcfc` / `#0a0a0a`). No bottom border; the timeline scroll-fade mask softens the edge instead. Items center vertically.

- Padding left `--workspace-gutter-start` = 1.25rem = 20px, right `--workspace-gutter-end` = 20px (`ChatView.tsx:11292`). The Electron variant uses `px-3 sm:px-5` (12 / 20px) and is `drag-region`; ignore drag.
- When the sidebar is collapsed (or `max-md` with it expanded) the left padding becomes `--workspace-titlebar-content-left` to clear the native traffic lights (`workspaceTitlebar.ts:1-2`). Native app: the window chrome already owns that space, check against the sidebar-collapsed capture (`31-sidebar-collapsed`).
- `ChatHeader` row (`ChatHeader.tsx:255-261`): `flex flex-1 min-w-0 items-center gap-2 sm:gap-3`, right padding `pr-24` = 96px when the right panel is closed, `pr-10` = 40px when it is open. That space keeps the title clear of the three toggle buttons fixed at the right.

### 2.2 Breadcrumb

`<nav><ol>` (`WorkspaceBreadcrumb.tsx:11-18`): `flex items-center gap-2 sm:gap-3 text-sm`, so 14px / 20px line height, gap 8px below 640px and 12px at 640px and up. The list is `overflow-clip` with a 2px clip margin (`ChatHeader.tsx:264`).

Items (`WorkspaceBreadcrumb.tsx:54-66`): `font-medium` (500). Project item is `shrink-0` and `text-muted-foreground` (`Palette.mutedForeground`, `#71717b` / `#818181`), becomes `text-foreground` on hover over 150ms (`transition-colors`, default easing). The current item (thread title) is `text-foreground` (`#27272a` / `#f5f5f5`), `min-w-10 flex-1`.

Text span (`WorkspaceBreadcrumb.tsx:29-44`): `block truncate`, with `text-box: trim-both cap alphabetic` plus `py-1.5` (6px) when supported. Native: lay out the single line with cap-height centering (the cap height of SF Pro 14px is about 10px, so the box is about 10 + 12 = 22px tall). Truncation is a tail ellipsis.

Project button (`ChatHeader.tsx:272-291`): `inline-flex gap-1.5 rounded-sm` (`Tokens.Radius.sm` = 6px), favicon `size-3.5` = 14px, then name with `max-w-40` = 160px. Click starts a new thread in the project. Focus ring: 2px `--ring`.

Separator: the literal `/` in `text-icon-muted` (`Palette.iconMuted`, `#71717b` / `#818181`), `shrink-0`, same font as the items (500 weight). It sits inside the same 8/12px gaps, so the visible spacing project to slash is 12px and slash to title is 12px.

Title (`ChatHeader.tsx:325-345`): a button around `<h2>` with a trailing chevron: `inline-flex gap-1 rounded-sm`, `ChevronDown` lucide `size-3.5` = 14px, `text-muted-foreground`, opacity 0 and 1 on hover or keyboard focus (`transition-opacity`, 150ms). Draft threads render the title without the button or chevron. Rename mode swaps in a transparent `input`, `text-sm font-medium`, `ring-1 ring-ring/50`, focus `ring-ring`.

Reference check (`03a`, 2x): favicon square at x=504, "demo-repo" muted, "/" muted, title dark and truncated with "..." at 1350px (2000px image scale).

### 2.3 Right-side controls

Fixed at the viewport top-right (`ChatView.tsx:11205-11222`): `top: --workspace-controls-top` (0px), `right: --workspace-controls-right` = 12px, `mr-px`, `h-52px`, `gap-1` (4px) between the optional maximize control and the toggle cluster. `PanelLayoutControls` (`PanelLayoutControls.tsx:76`): `flex gap-1`. Buttons are `Toggle variant="ghost" size="sm"` with 16px lucide icons (`SquareMenuIcon` thread panel, `PanelBottomIcon` terminal, `PanelRightIcon` right panel). Use the milestone 2 `ToggleView` (ghost, sm; sm is `h-8 sm:h-7`, so 28px tall at desktop width). The maximize control (only when the right panel is open) is a `MorphIcon` between `Maximize2` and `Minimize2`, 16px.

These controls are out of scope for the read-only thread view except as layout reservation. Reserve 96px (3 buttons) on the right of the title row.


## 3. Timeline rows

Conventions. `fg` = `Palette.foreground` (`#27272a` / `#f5f5f5`), `muted` = `Palette.mutedForeground` (`#71717b` / `#818181`), `secondaryLabel` = `Palette.secondaryLabel` (same values), `iconMuted` = `Palette.iconMuted` (same values), `border` = `Palette.border` (`#e4e4e7` / `#ffffff0f`). A suffix `/60` means that token at 60% alpha (Tailwind color-mix). Radii: `rounded-md` = `Tokens.Radius.md` = 8px, `rounded-lg` = `Radius.lg` = 10px, `rounded-xl` = 14px, `rounded-2xl` = `Radius._2xl` = 18px, `rounded-3xl` is Tailwind's own 24px unless the theme overrides it (not in `index.css`). Text sizes: `text-3xs` 10px / 14px (`index.css:180-181`), `text-2xs` 11px / 16px (`:178-179`), `text-xs` 12px / 16px, `text-sm` 14px / 20px, `leading-relaxed` 1.625. Interface root size is 16px by default (`DEFAULT_INTERFACE_FONT_SIZE`, `packages/contracts/src/settings.ts:133`), prompt 14px, code 13px (`:149`, applied as `--font-size-code`, `appearanceFonts.ts:121`). If the user changes interface size, every rem value above scales.

Row list, in the order the timeline emits them (`MessagesTimeline.logic.ts` builds `rows`; render switch at `MessagesTimeline.tsx:2001-2083`):

`message(user)`, `turn-fold` ("Worked for 10s"), then hidden or revealed work rows (`work`, `work-toggle`, `work-live`, `thinking`, `event`), `message(assistant)`, `assistant-meta`, `proposed-plan`, `attempt-fold`, `context-compaction`, `working`, `worktree-setup`, `html-render`, `mcp-app`.

### 3.1 User message bubble

`UserTimelineRow`, `MessagesTimeline.tsx:2198-2560`. Row pad-bottom 16px.

- Column: `flex flex-col items-end gap-1` (4px gap). Everything right-aligned to the lane edge.
- Bubble: `relative max-w-[80%] rounded-2xl bg-message p-3 text-message-foreground` (`:2420`). Width is shrink-to-fit up to 80% of the lane (736 x 0.8 = 588.8px at the default width; reference 03a measures 589px). Radius 18px, padding 12px all sides. Fill `Palette.messageSurface` (`#f4f4f5` / `#ffffff0a`), text `Palette.messageForeground` (`#27272a` / `#f5f5f5`). No border, no shadow.
- Screen-reader-only heading "You" (`sr-only`, not drawn).
- Body: `ChatMarkdown` with `className="text-foreground" lineBreaks parseRawHtml={false}` (`:4801-4807`), so it uses the markdown typography of section 4 (14px, see 4.1) with soft line breaks preserved as hard breaks. Inline code inside the bubble keeps the inline-code chip look (reference 03d: `ls` chips with light border).
- Long messages collapse: when the visible text is longer than 600 characters or has more than 8 lines (`MessagesTimeline.logic.ts:2286-2311`), the body clamps to `max-h-44` = 176px with a bottom fade mask `linear-gradient(to bottom, black calc(100% - 1.75rem), transparent)` (28px fade, `:4711-4712`). Under it a footer `mt-1.5` (6px) with a `Button size="xs" variant="ghost-muted" className="-ml-1"` labelled "Show full message" / "Show less" (`:4755-4768`).
- Attachments above the text (`mb-2` = 8px): images in a `grid max-w-[210px] grid-cols-2 gap-2`, each `aspect-[4/3] overflow-hidden rounded-lg border border-border/80 bg-background/70`, `object-cover`. Non-image files: `flex flex-col gap-1` rows, `py-1 text-sm`, file icon + truncated name + `Eye` 16px (preview) and a download `icon-xs ghost-muted` button.
- Optional attribution above the bubble: `me-1 text-2xs text-muted-foreground/70` ("Sent by automation", "Sent by another agent"), `:2364-2400`. Intent marker (`UserMessageIntentMarker`, `:2561`) for non-`turn_start` intents.
- Optional failure chip below: `rounded-full border border-destructive/25 bg-destructive/8 px-1.5 py-0.5 text-3xs font-medium text-destructive` (`:2535`).
- Hover row (below the bubble, same 80% max width): `flex w-full max-w-[80%] items-center justify-end pe-1 text-xs tabular-nums opacity-0 transition-opacity duration-200 group-hover:opacity-100 focus-within:opacity-100` (`:2540`). Contents, gap-2: timestamp `text-muted-foreground text-xs tabular-nums` (`formatDayAwareTimestamp`, tooltip with the full date), then `flex gap-0.5` holding the revert button (only when `revertTurnCount` is a number) and `MessageCopyButton variant="ghost"` (= `Button size="xs" variant="ghost-muted"` with a 12px `Copy` icon that morphs to `Check` in `text-primary` after click, `MessageCopyButton.tsx:41-61`). The row reserves its height at all times (opacity only), so hover never shifts layout. Opacity is forced to 1 on coarse pointers.
- Stable-height rule: the hover row always occupies one `text-xs` line (16px) plus the 4px column gap, so a user row is bubble + 4 + 16 + 16 padding.

### 3.2 Assistant message

`AssistantTimelineRow`, `:2745-2793`.

- Wrapper `relative min-w-0 px-1 py-0.5`: 4px horizontal, 2px vertical padding around the markdown. So prose starts 4px inside the lane (reference 03d: lane edge 565, text 572 in 2000px image = 4px).
- Content: `ChatMarkdown` (section 4), `headingLevelOffset=3`, `lineBreaks` only if `shouldPreserveAssistantLineBreaks(text)`.
- Empty finished response: literal "(empty response)".
- After the markdown: `AssistantChangedFilesSection` (3.9) when the turn changed files, then (only when `showAssistantMeta`) the meta row with `mt-1.5`.
- Bottom padding of the row: 16px normally. Commentary messages (assistant text that is not the turn's terminal message, so `showAssistantMeta` is false) get 8px (`:2010-2025`).
- The row has `group/assistant`, which drives the meta hover.

### 3.3 Assistant meta row

`AssistantMessageMeta`, `:2860-2912`. Two forms:

1. Inline inside the message row (`mt-1.5`), hidden until hover: `flex items-center gap-2 text-xs tabular-nums transition-opacity duration-200 opacity-0 group-hover/assistant:opacity-100 focus-within:opacity-100`.
2. Standalone `assistant-meta` row (`:2841-2858`, wrapper `px-1`, row `mt-0.5`, `alwaysVisible`, opacity 1). The reducer emits this when the message is separated from its meta (for example when an expanded work group sits between).

Contents left to right, `gap-2` (8px), all left-aligned: optional status pill (`rounded-full border border-border/70 px-1.5 py-0.5 font-mono text-3xs text-muted-foreground`, only when the item status is not `completed`), copy button (`MessageCopyButton variant="ghost"`, only when the message is final and not streaming), fork button (`GitFork` 12px in `Button size="xs" variant="ghost"`, only for supported provider items), timestamp (`text-muted-foreground text-xs tabular-nums`, hidden while streaming, uses `message.updatedAt`). Copy button tooltip "Copy message"; fork tooltip "Fork from this response".

### 3.4 Thinking row

Two states. Both are `WorkLogRow`s inside a `WorkLogBlock` (3.5). Both render through `LiveActivityRow` (`:3811-3848`): `relative min-h-6 w-fit max-w-full min-w-0 overflow-hidden rounded-md text-sm leading-relaxed`.

Live "Thinking" row (`ThinkingTimelineRow`, `:3791-3809`, shown while the run is working and no tool is running):

- Icon: lucide `brain`, 16px (`size-4`), stroke width 2, inside a 24px square cell (`WorkLogLine` icon slot `size-6`, `WorkLog.tsx:60`). Icon color `iconMuted`, drawn at 70% opacity and darkened 40% in light mode (`opacity-70 light:brightness-60`, `:4978-4979`).
- Label "Thinking", `text-sm` 14px, `secondaryLabel`, tail truncated.
- Animation: the label gets `live-tool-shine` or the shimmer overlay, see 3.5 and section 8.
- When it belongs to a group (`groupId` defined) the whole row is a `<button>` with `min-h-6 w-full rounded-md`, focus ring `ring-2 ring-inset ring-ring/70`; click toggles the group.

Thought preview above the live status line (`LiveWorkEntryTimelineRow`, `:3960-4049`): when the latest thought has text, a wrapped `WorkLogRow` shows the first sentence: brain icon (16px, `iconMuted`), label `line-clamp-4` (max 4 lines, 22.75px each) in `secondaryLabel`, aligned `items-start` so the icon stays beside line one. Then the status row below it. In reference 01 (`01-running-turn`): "No tools needed here, just a story." at y=407 and "Thinking" at y=458 (2000px image), 28 CSS px apart, matching 24px min height plus the 2px `py-0.5` of each standalone row... the exact gap is 25.5 css px; measure in the browser.

Completed thought rows (inside an expanded group): label "Thought" or the thought's first sentence (markdown stripped by `remarkThoughtPreview`, `:5307-5327`), brain icon, chevron at the right. Expanded, the body is `ReasoningTraceContent` (`:5329-5352`): `WorkLogDetails kind="text"` = `ms-7` (28px) `flex max-h-96 flex-col gap-3 overflow-auto px-0.5 py-1 select-text` holding `ChatMarkdown className="text-foreground" lineBreaks`. Max height 384px, then it scrolls inside.

### 3.5 Working indicator and live activity

`WorkingTimelineRow`, `:3705-3743`. Row: `border-b border-border/60 pb-2 pt-1` (border `border` at 60%, 1px, spans the full lane width; top 4px pad, bottom 8px pad), wrapper pad-bottom 6px. Inner: `flex h-6 min-w-0 items-baseline gap-2 px-1 text-sm leading-relaxed text-muted-foreground tabular-nums`. So 24px line, 4px side padding, 14px `muted` text, tabular figures.

Label: "Working for 4s" where the time ticks once a second (`setInterval 1000`, `:3496-3517`). Format `formatWorkingTimer`: under 60s `Ns`, otherwise `formatDuration` (`packages/shared/src/orchestrationTiming.ts:36-52`: `1h 2m 3s`, zero parts omitted). Without a start time the label is "Working...". During worktree setup it reads "Setting up worktree…", while compacting "Compacting…" with a 12px `minimize-2` icon at `gap-1.5`; those two labels (and only those) get the shimmer overlay:

- Overlay `ActivityShimmerOverlay` (`:3681-3692`): a copy of the label in `text-foreground` clipped to a moving 72px (4.5rem) soft window. Mask stops across 72px: transparent 0, 12% alpha at 10.8px, 55% at 25.2px, 100% at 36px, 55% at 46.8px, 12% at 61.2px, transparent at 72px (`index.css:574-613`). The overlay is `calc(100% + 144px)` wide, starts at `-72px`, and translates from `translateX(0)` to `translateX(100%)` over 2.2s linear, infinite; the inner copy counter-translates so the text stays still (`index.css:556-572, 615-630`). Reduced motion: overlay opacity 0.
- Animation only runs while the element is visible (`animation-play-state: var(--visible-animation-state, paused)`, set by `observeVisibleAnimation`, an IntersectionObserver).

Native port of the shimmer: draw the base text in `muted`, then draw the same text in `fg` through a horizontal gradient mask 72px wide sliding left to right over (text width + 72px) in 2.2s linear.

Reference 01 (light): "Working for 4s" at x=572/2000 (4px in), a 1px line under it spanning x=563..1900.

`live-tool-shine` (a different effect, for the active tool label and group header, `index.css:521-548`): the label is painted `color: transparent` with `background-clip:text` using two backgrounds, a 72px-wide `linear-gradient(to right, transparent, contrast-foreground, transparent)` over a solid `contrast-secondary-label` (`#71717b` / `#818181`). `background-position` animates from `-72px 0` to `calc(100% + 72px) 0` over 2.2s with `steps(30)` timing, infinite. The result is a 30-step bright band sweeping across the label. Applied to the label span of the running tool row (`LiveActivityContent` when `active && !shimmer`, `:3894`) and to the group header when `active` (`:4143`). Only with `prefers-reduced-motion: no-preference`.

### 3.6 Work log group and "Worked for" fold

There are two layers of folding.

Layer 1, the turn fold (`TurnFoldTimelineRow`, `:2699-2721`). A settled turn collapses everything between the user prompt and the final assistant message behind one row (`deriveTurnFolds`, `MessagesTimeline.logic.ts:960-1145`). Label strings (`:1127-1134`): `Worked for 1m 12s`, `Worked` (no duration), `You stopped after 4s`, `You stopped this response`. Duration uses the 4s / 1m 12s format above, from the run's `startedAt` to `completedAt` or, for older turns, first to last entry timestamp.

- Container `group/timeline-row relative flex items-center gap-1 border-b border-border/60 pb-2 pe-0.5 pt-1`: a 1px bottom border (`border` at 60%, full lane width), 4px above and 8px below the content, 2px right padding. Wrapper adds `pb-1.5` (6px) under the border.
- Button `flex items-center gap-1 rounded-md px-1 text-sm leading-relaxed text-muted-foreground tabular-nums`, hover `text-foreground` over 150ms (`transition-colors`). Content: label, then a 14px chevron (`size-3.5`, `MorphIcon`) that is `chevron-right` collapsed and `chevron-down` expanded. Gap 4px. Focus: 2px inset ring `ring/70`.
- Timestamp at the far right (`ms-auto`), `text-muted-foreground text-xs tabular-nums`, invisible until the row is hovered or focused (`opacity-0` to `opacity-100`, absolute to static swap, `:2682`).
- Reference 03d: "Worked for 10s >" text at x=572 (4px in), y=455 (image px), rule at y=491 from x=563 to x=1900. So the rule is 1px at lane left to lane right, text baseline area 36 image px above it.
- Expanding reveals the folded rows in place (work rows, thinking, the commentary assistant messages). There is no height animation in the list; rows are inserted (see 8).

Layer 2, a work group inside a turn (live or expanded). Rows `work-toggle`, `work-live`, `work`:

- `work-toggle` (`WorkGroupToggleTimelineRow`, `:4094-4112`, `WorkGroupHeader` `:4114-4151`): a `WorkLogButton` row. Left icon (16px, `iconMuted`, 70% opacity), label = group summary ("Ran 3 commands", "Read 2 files and changed 1 file", "Thought (x2)", "Used 5 tools", see `summarizeToolGroup`, `packages/client-runtime/src/work-log/presentation.ts:645-745`), hover-only timestamp at the right. No chevron on the header; expansion state is shown by the rows below it.
- Summary icon by kind (`toolGroupSummaryIconName`, `:4051-4092`): pull-request kinds `git-pull-request` glyph, read `eye`, edit `square-pen`, command `terminal`, thread-create the T3 wordmark, browser custom `BrowserAppIcon`, device `smartphone`, search `globe`, code-search `search`, other `wrench`, dynamic-tool and update and mixed `hammer`, reasoning `brain`, agent-tool `bot`, tone-tool `zap`.
- Expanded group: header row (`layout="group-header"`, no bottom padding), then the entries in a scroller (`ExpandedWorkGroupEntries`, `:3521-3677`): `WorkLogList` (`flex flex-col`, rows `py-0` so each is exactly 24px), `max-height: calc(min(18rem, 50dvh) + expandedRowsExtraHeight)` (288px or half the viewport height, whichever is smaller, plus the added height of any expanded entries so opening an entry does not shrink the visible rows), `overflow-x-hidden rounded-md`, `scroll-py-6`, `scrollbar-gutter-stable`, top and bottom edge fades from `getVirtualizedScrollFadeClassName` when scrollable (find its mask in the browser; see section 9). `WorkLogBlock` bottom padding is 4px (`group-content`) after the list and 0 after the header.
- Collapsed single tool: a group with exactly one tool-like entry renders just that entry as a `work` row (`SimpleWorkEntryRow`), labelled by `singleToolCallLabel` (the tool's display name), no summary header.

### 3.7 Tool call and work log entries

`WorkEntryLogRow`, `:5384-5777`. The geometry comes from `WorkLog.tsx`:

- Row (`useRowClassName`, `WorkLog.tsx:92-100`): `relative w-full min-w-0 rounded-md px-0.5 text-left transition-colors`, `py-0` inside a group list, `py-0.5` standalone (2px top and bottom). Clickable rows get `cursor-pointer` and a 2px inset focus ring (`ring/70`). No hover background.
- Line (`WorkLogLine`, `WorkLog.tsx:52-76`): `flex min-h-6 min-w-0 gap-1.5 text-sm leading-relaxed select-none`. Height 24px minimum. Icon cell `size-6` (24px) centered; gap 6px; label `flex-1 min-w-0 truncate` (tail ellipsis) in `secondaryLabel`; trailing slot at the right. `wrapLabel` rows (errors, thoughts) use `items-start` and no truncation.
- Icon: 16px lucide, `stroke-2`, in a `size-4` box, `iconMuted`, with `opacity-70` and (light theme only) `brightness-60` for muted icons. Icons by entry type (`workEntryIconName`, `:5267-5303`, `WorkEntryIcon` `:5127-5168`): command `terminal`, file read `eye`, file edit `square-pen`, web search `globe`, code search `search`, dynamic tool `wrench`, sub-agent `bot`, user-input or approval request `message-circle`, notification failed `circle-alert`, notification monitor `eye`, background task `zap`, reasoning `brain`, error tone `circle-alert`, info tone `check`, default tone `zap`, plus the Pull request glyph, `smartphone` for device, custom browser glyph (24x24 viewBox, stroke 1.9, round caps), T3 wordmark. MCP or integration tools may carry their own icon (website favicon at 32px, themed logo, or native app icon) drawn in a 16px `rounded-xs` (2px) box on `background`, 70% opacity when muted; computer-use shows a gradient mark at 20px.
- Label text: `text-sm leading-relaxed` truncate; color `secondaryLabel` for tool-like entries, `foreground/80` for non-tool entries, `warning` (medium weight) for runtime warnings, `destructive` (medium weight) for severe failures. A user-question row shows the question in label color and the answer after it at `gap-1.5` in `foreground` (collapsed) or `muted` (expanded).
- Failed tool (routine): the icon turns `text-tool-error-icon/40` (`Palette.toolErrorIcon` `#fb2c36` / `#fca5a5` at 40% alpha). Icons that cannot be tinted (images, gradient marks) get a trailing 12px `x` in the same color. Severe failures switch to `circle-alert` in `destructive` plus a medium-weight `destructive` label.
- Trailing slot, right to left: chevron cell `size-4` holding `chevron-right` 12px (`size-3`) in `iconMuted` at 70% opacity, rotating 90deg when expanded over 200ms (`transition-transform duration-200`); the cell is `invisible` (still reserving 16px) when the entry has nothing to expand. Left of it the hover-only timestamp (`xs`, `muted`). Left of that optional "Open chat" text button (`text-sm text-primary hover:underline`, `rounded-sm`) for created threads, or an `InlineButton` "Open subagent".
- Click or Enter or Space toggles the entry. The expanded state is remembered while the group exists.

Expanded content (`WorkLogDetails`, `WorkLog.tsx:120-141`):

| Kind | Used for | Box |
|---|---|---|
| text | reasoning body | `ms-7` (28px) `flex flex-col gap-3 max-h-96 overflow-auto px-0.5 py-1 select-text` |
| panel | tool output and inspector | `mt-0.5 mb-1.5`, no indent |
| media | viewed image | `mt-1` |

Details swallow clicks, so a click inside does not collapse the row.

Panel content, two producers:

1. Plain body (legacy entries without a projected item, and reads and skills): `<pre>` with `max-h-64` (256px) `overflow-auto whitespace-pre-wrap break-words font-mono text-secondary-label leading-relaxed select-text`, font size `--font-size-code` (13px default; falls back to `text-2xs` 11px if unset) (`:5264-5265`). Blocks are separated by a blank line: tool input JSON (`Tool input\n{...}`), the raw command, the detail text, then changed file paths. Duplicates of the visible label are dropped.
2. Item inspector (`V2ItemInspector.tsx:222-424`), the normal path for server data. Root `space-y-2 text-xs` (8px between blocks, 12px base). Mono blocks use `font-mono 13px leading-relaxed whitespace-pre-wrap break-words select-text` (`:81`).
   - Command execution (`ToolCallBody`, `:192-220`): `space-y-1.5` (6px). First the command in `ShellCommandBlock`: highlighted bash tokens in `foreground/85` (see section 5). Then optional arg lines (`key` in `muted`, value `foreground/85`), then the output in `text-muted-foreground`, `max-h-80` (320px) `overflow-auto`. Exit code line `exit N` in `destructive` when non-zero. States: "Loading output…" muted italic, "Couldn't load output: ..." destructive, "No output." muted italic.
   - File change: a `flex-wrap gap-2` header with the workspace-relative path (mono `muted`), `+N` in `Palette.success` and `-N` in `destructive`, and an "Open diff" `Button size="xs" variant="outline"`. Failed changes show the raw diff text (`max-h-80`, muted mono). A change list `space-y-1 font-mono muted`.
   - Reasoning: `rounded-md border border-border/45 bg-muted/15 p-2 italic text-muted-foreground` around markdown.
   - Search results: `space-y-1` list; titles `font-medium foreground` with a 12px `external-link` icon, snippets `muted`.
   - Tool JSON args: pretty-printed with Shiki JSON tokens (`resolveDiffThemeName`).

Reference: 03d shows only the collapsed fold; no expanded tool card exists in the captures. Capture one in the browser before signing off (section 9).

### 3.8 Turn event, error and lifecycle rows

`V2EventTimelineRow`, `:3079-3270`, for server events that are not messages or tools. Presentation tone picks colors (`v2EventPresentation`, `:2998`).

- Failed-run error inside a work group: `WorkLogRow` with `circle-alert` 16px (`destructive`, or `warning` for usage limit), label `text-sm font-medium` in the same color, always-visible timestamp, and for non-warnings a message paragraph `ms-7 whitespace-pre-wrap break-words py-1 text-sm leading-relaxed text-foreground/80`. Optional "Retry" `Button size="xs" variant="outline"` with `rotate-ccw` icon inside `ms-7 pb-1` (`:5420-5495`).
- Disclosure card for `error` items (`<details>`): `group rounded-md border`, with tone fill: warning `border-warning/25 bg-warning/5`, danger `border-destructive/25 bg-destructive/5`, success `border-success/20 bg-success/5`. Summary `flex items-center gap-2 px-2.5 py-1.5 text-xs`: 14px icon in tone color, label `font-medium text-foreground/90`, status pill (`rounded-full border px-1.5 py-0.5 font-mono text-3xs`, `destructive/40` border when failed), detail `flex-1 truncate text-muted-foreground/65`, visibility pill, 12px chevron-down (rotates 180deg when open, `transition-transform` 150ms). Open body: `border-t border-border/45 px-3 py-2 ps-8`.
- Other event card: `<section class="rounded-lg border px-3 py-2">` with the same tones plus muted `border-border/60 bg-card/30`; icon 14px at `mt-0.5`, label `text-xs font-medium text-foreground/90`, detail `mt-1 text-xs leading-relaxed text-muted-foreground` markdown.
- Event rows have 8px bottom padding.
- Thread-level error banner above the composer (`ThreadErrorBanner.tsx:55-87`): `mx-auto w-fit max-w-[min(48rem,calc(100%-2rem))] pt-3`, an `Alert` (`variant` error or warning, `surface="glass"`, `controlAlignment="first-line"`) with a 16px `circle-alert`, description `line-clamp-3`, and a dismiss `Button size="icon-xs" variant="ghost"` with `x`. Use the milestone 2 `AlertView`.
- Lifecycle rows (`V2LifecycleRow.tsx`, 622 lines: handoff, checkpoint, thread created and similar) are not covered here; section 9.

### 3.9 Changed files card (under an assistant message)

`ChangedFilesCard`, `chat/ChangedFilesTree.tsx:24-140`. Appears after the markdown when the run changed files.

- Container `@container/changed-files mt-4 rounded-lg bg-secondary dark:bg-input/20`: 16px above, radius 10px, fill `Palette.secondary` (`#fafafa` / `#ffffff08`) in light, `input` at 20% (`#ffffff14` x 0.2, so about 4% white) in dark. No border.
- Header `sticky top-2 z-10 flex items-center justify-between gap-2 rounded-t-lg px-3 py-2`, fill `secondary` in light and `background` with a `input/20` gradient overlay in dark. Left: "N changed files" `text-xs font-medium foreground`, then `+A -D` (`DiffStatLabel` inline: `gap-1`, mono, `+` in `Palette.diffAddition`, `-` in `Palette.diffDeletion`, `leading-4`). Right: `gap-1` buttons, "Collapse or expand all folders" `icon-xs ghost-muted` with 12px `chevrons-down-up` / `chevrons-up-down` (only when there are directories), and "Open diff" `size="xs" ghost-muted` with a 12px `file-diff` icon and the words "Open diff" (shown only when the card is at least 24rem wide).
- Tree body `p-2` (8px). Rows are buttons `flex w-full items-center gap-2 rounded-md py-1.5 pr-2`, hover `bg-accent/60` (`transition-colors`), left padding `8 + depth*14` px. Directory row: chevron-right 14px (`muted/70`, rotates 90deg when open, `transition-transform`), folder icon 14px (`folder` open / `folder-closed`, `muted/75`), name `font-mono text-2xs` in `muted/90` (hover `foreground/90`), stat `ml-auto font-mono text-3xs tabular-nums`. File row: 14px spacer when any directory exists, file-type icon (`PierreEntryIcon`, 14px, `muted/70`), name `font-mono text-xs foreground/85` (hover `foreground`) middle-truncated, stat at right. Stat columns in the tree use the aligned layout: `grid-cols-[4ch_4ch] gap-2 text-right`. Click opens the turn diff on that file.

### 3.10 Attempt fold and superseded runs

`AttemptFoldTimelineRow`, `:2723-2743`. A full-width button `flex w-full items-center gap-2 rounded-md border border-border/60 bg-muted/20 px-2.5 py-2 text-left transition-colors hover:bg-muted/35`: 14px chevron (`muted`, right or down), label "Superseded attempt" `text-xs font-medium foreground/80`, then "Partial output retained" `text-2xs muted`. Height about 36px (12px tall text line 16 + 2*8 + 2 border). Bottom padding 8px. Focus ring 2px inset.

### 3.11 Context compaction divider and system dividers

`ContextCompactionTimelineRow`, `:2111-2143`: `role="separator"`, `flex w-full items-center gap-3 py-1 text-xs text-muted-foreground`: a 1px rule (`h-px flex-1 bg-border/70`), a label cluster (12px `minimize-2` icon, 6px gap, text), another rule. The row is in the lane (max width 736px) and has 16px bottom padding. While `active` the label gets the shimmer overlay (3.5). Label text comes from `row.label` ("Context compacted" style strings from the reducer; check `MessagesTimeline.logic.ts` near the `context-compaction` builder before drawing).

`TimelineSystemDivider.tsx:19-66` (used by other surfaces): `flex items-center gap-2 py-2 text-2xs text-muted-foreground` (danger: `destructive`), rules `h-px flex-1 bg-border/70`, centered pill `gap-1.5 rounded-full px-2 py-1`, icon 12px, label `font-medium`, detail `opacity-70` after `"· "`, max 320px. With an action it becomes a button `rounded-full border border-border/70 bg-background px-2.5 py-1 hover:bg-muted` (150ms colors).

### 3.12 Proposed plan card

`ProposedPlanCard.tsx:164-243`, in a row wrapper `min-w-0 px-1 py-0.5`.

- Card `rounded-3xl border border-border/80 bg-card/70 p-4 sm:p-5`: 24px radius (Tailwind default for `3xl`), 1px `border` at 80%, fill `Palette.card` (`#ffffff` / `#111111`) at 70%, padding 16px (20px at 640px+).
- Header `flex flex-wrap items-center justify-between gap-3`: left `Badge variant="secondary"` "Plan" then `h3` title `truncate text-sm font-medium foreground`; right `Button size="icon-xs" variant="outline"` with a 16px `ellipsis` opening a menu (Copy to clipboard, Download as markdown, Save to workspace).
- Body `mt-4`: `ChatMarkdown headingLevelOffset=3`. Collapsed when long: `max-h-104` (416px) `overflow-hidden`, with a bottom fade `h-24` (96px) `bg-linear-to-t from-card/95 via-card/80 to-transparent`, and a centered `Button size="sm" variant="outline"` "Expand plan" / "Collapse plan" with `mt-4`.
- No reference screenshot exists (reference README item 25).


### 3.13 Timeline minimap

`TimelineMinimap`, `MessagesTimeline.tsx:1706-1950`. A strip of short bars at the left edge of the chat canvas, one per user message, with a hover preview. Shown only when the pointer is fine (not touch), the thread has at least 2 user messages (`TIMELINE_MINIMAP_MIN_ITEMS`, `MessagesTimeline.logic.ts:289`) and there is at least a little side gutter.

- Container `absolute inset-y-0 left-0 z-40 w-18` (72px), `pointer-events-none`. Opacity 1 when the side gutter is at least 48px (`TIMELINE_MINIMAP_PERSISTENT_GUTTER`), else 0 and fades in over 150ms on hover or focus.
- Rail: `absolute top-1/2 left-3 -translate-y-1/2` (12px from the left edge), height `min((n-1) x 8px, 100vh - 18rem)`, hit strip at most 40px wide (22rem while a preview is open).
- Each bar: `h-0.5` (2px), `w-6` (24px), `rounded-full`, origin left, `bg-muted-foreground` at 35% (75% for the bar under the pointer), scaled on x by distance from the pointer (1, 0.667, 0.417, then 0.333). Bars in view get an overlay `bg-foreground/90`, opacity 0 to 1 over 150ms. Transform and opacity transitions are 150ms (`transition-transform duration-150`). A 1px guide line `absolute top-0 left-3 h-full w-px bg-border/15`.
- Preview popover (`left-8 w-80`, 320px): `dropdown-glass block rounded-xl p-3 shadow-xl shadow-black/25`; title `text-sm font-medium leading-5` truncated on one line; excerpt `mt-1 max-h-[3.75rem] text-muted-foreground text-sm leading-5` (3 lines). Previous and next arrows (`chevron-up` / `chevron-down`, 16px, `foreground/90`) sit 2px beyond the rail ends.
- Reference `10` shows the minimap at x=495 (2000px scale) as three short grey bars.
- Optional for milestone 4. Build after the rows.

## 4. Markdown

Source of every rule below: the `.chat-markdown` block of `apps/web/src/index.css:1759-2073` (compiled into `main.css`) plus the component overrides in `ChatMarkdown.tsx`. Colors named `contrast-*` resolve to the same values as their plain twin (see `docs/design-tokens.md`: `--contrast-foreground` equals `--foreground`, `--contrast-border` equals `--border`, `--contrast-muted-foreground` equals `--muted-foreground`, except in the sidebar subtree, which this view does not use).

### 4.1 Root

`<div class="chat-markdown w-full min-w-0 text-sm leading-relaxed text-foreground/80 [overflow-wrap:anywhere] [word-break:break-word]">` (`ChatMarkdown.tsx:3416-3420`).

- Font: system sans (`Tokens.Raw.fontSans`), 14px, line height 1.625 = 22.75px.
- Text color: `Palette.foreground` at 80% alpha (`text-foreground/[calc(80%+var(--appearance-contrast-boost)/5)]`, boost default 0%). So assistant body text is `#27272a` at 0.8 on `#fcfcfc` and `#f5f5f5` at 0.8 on `#0a0a0a`. User bubbles, reasoning bodies and plan cards override with `text-foreground` (100%) (`MessagesTimeline.tsx:4802`, `:5337`).
- Wrapping: break anywhere when a word overflows (`overflow-wrap:anywhere`), otherwise at word boundaries.
- First child has `margin-top:0`, last child `margin-bottom:0` (`index.css:1764-1770`).
- Streaming: while `isStreaming`, each newly inserted top-level block fades from opacity 0 to 1 over 600ms `ease-out` (`index.css:2011-2021`), once, only on insertion. Reduced motion: none.
- Block spacing: paragraphs, lists, blockquotes, `pre`, and the table container have `margin: 0.65rem 0` = 10.4px top and bottom (`index.css:1772-1781`). Adjacent margins collapse to the larger one (CSS block margin collapsing), so two paragraphs sit 10.4px apart, not 20.8px. Nested lists keep the same 10.4px margins inside the `li`.

### 4.2 Paragraph, inline text

- `p`: root font, margin as above. `strong` is `font-weight: bolder` (700 from a 400 parent, Tailwind preflight), `em` italic, `del` strikethrough, `sup`/`sub` per preflight. Soft line breaks render as hard `<br>` only for user messages and when `shouldPreserveAssistantLineBreaks` is true (`remark-breaks`, `ChatMarkdown.tsx:3403-3407`).
- Skill mentions (`$skill-name`) in text become inline chips via `renderSkillInlineMarkdownChildren` (`SkillInlineText.tsx`, not covered; section 9).

### 4.3 Headings

All headings (`index.css:1783-1815`): `margin: 1.25rem 0 0.5rem` (20px above, 8px below), `font-weight: 600`, `line-height: 1.3`, color `--contrast-foreground` (full `fg`, not the 80% of body text). The tag stays `h1` to `h6`; `headingLevelOffset=3` only sets `aria-level` (`ChatMarkdown.tsx:2788-2802`), not size.

| Level | Font size | Line height (px) | Color |
|---|---|---|---|
| h1 | 1.25rem = 20px | 26 | `fg` |
| h2 | 1.125rem = 18px | 23.4 | `fg` |
| h3 | 1rem = 16px | 20.8 | `fg` |
| h4 | 0.875rem = 14px | 18.2 | `fg` |
| h5 | 0.875rem = 14px | 18.2 | `fg` |
| h6 | 0.875rem = 14px | 18.2 | `mutedForeground` |

Heading ids are generated GitHub-style (`rehypeHeadingIds`, `:1837`); anchor links scroll inside the thread.
Reference: 03a "Demo heading" (h1) and "Setup checklist" (h2).

### 4.4 Lists

- `ul` (`index.css:1817-1824`): `padding-left: 1.25rem` (20px), `list-style: disc`; nested `ul ul` is `circle`, `ul ul ul` is `square` (`:1847-1853`). Marker color follows the text color. Markers are outside the content box (the 20px gutter holds them).
- `ol` (`:1831-1835`): `padding-left: var(--list-gutter, 1.25rem)`, `decimal`, markers use tabular figures. If the widest marker has two or more characters, the renderer sets `--list-gutter: (digits + 2)ch` inline (`ChatMarkdown.tsx:394-404`, `:2848-2857`): 10 to 99 items gives `4ch`, 100 or more `5ch`. Nested `ol ol` is `lower-alpha`, `ol ol ol` `lower-roman` (`:1855-1861`).
- `li + li { margin-top: 0.25rem }` (4px, `:1863`). A `li` with a paragraph child ("loose list") also gets the paragraph's 10.4px margins, collapsing with the 4px.
- Task lists (`:1868-1877`): `li.task-list-item` has `list-style: none`; the checkbox is a native `<input type="checkbox" disabled readonly>` with `margin: 0 0.35em 0.15em calc(-1 * var(--list-gutter, 1.25rem))` and `vertical-align: middle`. So the box sits where the bullet would, 20px left of the text, with 0.35em = 4.9px between box and label. Chromium draws it 13x13 with its disabled look (checked: grey fill and white check; unchecked: grey border). Reference 03a shows both. A native build should draw a 13x13 box, radius 2px, and measure colors in the browser (section 9). In threads that allow editing, the toggle is live (`onTaskListChange`); the read-only view never needs it.
- Reference 03d: an ordered list whose items start with inline code chips. The numbers use the body color and sit in the 20px gutter, right-aligned against the text.

### 4.5 Blockquote and GitHub alerts

Blockquote (`index.css:1900-1904`): `border-left: 2px solid --contrast-border` (`Palette.border`), `padding-left: 0.8rem` (12.8px), text color `--contrast-muted-foreground` (`muted`), margin 10.4px. No background, no radius.

GitHub alerts (`> [!NOTE]` etc., detected by remark and passed as `data-alert`) render a `<div role="note" class="my-1 border-l-2 pl-3">` (`ChatMarkdown.tsx:2830-2848`): `my-1` = 4px vertical margin, 2px left border, 12px left padding, no fill. The body is ordinary text in the 80% color (not muted). Title line `flex items-center gap-1.5 font-medium` with a 14px (`size-3.5`) lucide icon, then the label:

| Alert | Icon | Border (alpha 70%) | Title color light / dark |
|---|---|---|---|
| Note | `info` | blue-500 `#2b7fff` | blue-600 `#155dfc` / blue-400 `#51a2ff` |
| Tip | `lightbulb` | emerald-500 `#00bc7d` | emerald-600 `#009966` / emerald-400 `#00d492` |
| Important | `message-square-warning` | purple-500 `#ad46ff` | purple-600 `#9810fa` / purple-400 `#c27aff` |
| Warning | `triangle-alert` | amber-500 `#fd9a00` | amber-600 `#e17100` / amber-500 `#fd9a00` |
| Caution | `octagon-alert` | red-500 `#fb2c36` | red-600 `#e7000b` / red-400 `#ff6467` |

(Base colors from `docs/design-tokens.md`, `Tokens.baseColors["blue-500"]` and so on.) The title is excluded from find (`data-thread-find-ignore`).

### 4.6 Horizontal rule

Plain `<hr>`: Tailwind preflight (`height:0; color:inherit; border-top-width:1px`) and the global `border-color: var(--border)` (`index.css:685`). So a 1px line in `Palette.border` (`#e4e4e7` / `#ffffff0f`), full width, margin 0 (the `0.65rem` hr margin in `main.css` belongs to `.composer-tiptap hr`, `index.css:1920`). Adjacent paragraph margins (10.4px) provide the spacing. Verify in the browser (section 9).

### 4.7 Links

(`index.css:1883-1898`, `ChatMarkdown.tsx:1218-1270`, `:2810+`)

- `a`: `text-decoration: none`, color `--info-foreground` (`Palette.infoForeground`: `#1447e6` / `#51a2ff`).
- Hover or keyboard focus: a dotted underline drawn as a background: `radial-gradient(circle, currentcolor 0.75px, transparent 1px)` repeated along x, positioned `left bottom`, size `4px 2px` (so 2px-tall dots every 4px along the baseline of the line box).
- External `http(s)` links get a 14px favicon (or GitHub logo or globe) before the text: `ms-[0.25em] me-[0.2em] inline-flex size-[14px] [vertical-align:-0.125em]`, favicon `rounded-sm`.
- Links whose text is a file path, and inline code that looks like a file path, become file chips (class `chat-markdown-file-link`): a pill with a file-type icon and the path, with its own color and focus ring (`MarkdownFileLink`, `:1931-2265`). Not covered further; section 9.
- Footnotes: `section[data-footnotes]` gets `margin-top 1.25rem`, 1px top border, `padding-top .75rem`, muted 12px text; refs are 11px semibold, 16px min width (`index.css:1924-1950`).

### 4.8 Inline code

`.chat-markdown :not(pre) > code` (`index.css:1952-1959`): mono (`--font-mono`), `font-size: 0.75rem` = 12px (it does not follow the code-size setting), color `--contrast-foreground` (`fg`), `background: var(--muted)` (`Palette.muted`: `#fafafa` / `#ffffff08`), `border: 1px solid --contrast-border` (`Palette.border`), `border-radius: 0.375rem` = 6px, `padding: 0.1rem 0.35rem` = 1.6px 5.6px. It flows inline with the paragraph line box, so the chip is shorter than the line (18px of text plus padding, border). In the user bubble (reference 03d) the chips are `#fafafa` on `#f4f4f5`, hardly visible except for the border.

### 4.9 Images and media

- `img`: `display:inline-block` (`index.css:1879`). Standalone images hold a 16:9 slot until decoded: `aspect-video w-full overflow-hidden bg-muted/60 max-w-[min(100%,30rem)] rounded-lg border border-border/40` (`ChatMarkdown.tsx:1270-1390`). Decoded size: `h-auto w-auto object-contain`, `max-h-[30rem]` (480px), `max-w-[min(100%,30rem)]` (480px). Frame radius `rounded-lg` = 10px, 1px border `border` at 40%. Click expands into a dialog. Failed loads show a `triangle-alert` 14px with a label in `text-xs text-muted-foreground`.
- Video uses the same bounds. Workspace images (paths resolved against the project) use the same frame.

### 4.10 Tables

`MarkdownTable` (`ChatMarkdown.tsx:559-685`, CSS `index.css:2028-2067`). Container `.chat-markdown-table-container`, margin 10.4px 0.

- Scroll area: horizontal `ScrollArea` with edge fade (`scrollFade`), `w-full max-w-full`. Table `width:100%; min-width:max-content; border-collapse:collapse`, font 12px (`0.75rem`), line-height inherited 1.625 (19.5px).
- Cells: `padding: 0.45rem 0.75rem` (7.2px 12px), left-aligned. Header cells: `padding-block: 0.55rem` (8.8px), `font-weight: 600`, `white-space: nowrap`, bottom border 1px `Palette.border` at 60%. Body cells: bottom border 1px `Palette.border` at 60% (the last row has one too). No vertical rules, no zebra, no header fill, no outer border.
- Row height: header 19.5 + 17.6 + 1 = 38.1px; body 19.5 + 14.4 + 1 = 34.9px (reference 03a: 35.2px).
- Collapsed mode (default `wordWrap` setting is true, see `packages/contracts/src/settings.ts:506`, so the table starts expanded): cells truncate to `max-width: 24rem` (384px) with `text-overflow: ellipsis` and `white-space: nowrap`. Expanded: cells wrap at 24rem with `overflow-wrap: anywhere`.
- Footer row under the table (`mt-0.5` = 2px, `flex justify-between`): left a 24px `icon-xs` button toggling expand (`maximize-2` / `minimize-2`, 12px; `ghost-muted`, or `secondary` when pressed), right a 24px `icon-xs ghost-muted` copy button (12px `copy`, morphs to `check` for 1.2s) opening a menu "Copy as Markdown" / "Copy as CSV". In reference 03a the compress icon sits at x=593 and the copy icon at x=1872 (2000px scale) directly under the last row.

### 4.11 Code blocks

Frame (`MarkdownCodeBlockFrame`, `ChatMarkdown.tsx:750-804`):

`chat-markdown-codeblock my-[0.65rem] overflow-hidden rounded-lg border border-border/70 bg-secondary leading-snug dark:border-transparent dark:bg-input/32`

- Margin 10.4px vertical. Radius `rounded-lg` = 10px. Light: 1px `Palette.border` at 70% border, fill `Palette.secondary` `#fafafa`. Dark: no border, fill `Palette.input` at 32% (`#ffffff14` x 0.32, about 2% white on `#0a0a0a`).
- Line height `leading-snug` = 1.375, so 13px code gives 17.875px lines (reference 03a: 17.6px between lines).
- Header row: `flex items-center justify-between gap-2 pt-1.5 pr-1.5 pb-0 pl-3 select-none`, so 6px top, 6px right, 0 bottom, 12px left; height is set by the 24px action buttons (about 30px total). Header text color `--contrast-foreground` at 72% (`color-mix(... 72%, transparent)`, `index.css:1987-1989`).
- Title: `inline-flex items-center gap-1.5 font-mono text-2xs` (11px mono). For known languages only the file-type icon is drawn (14px `size-3.5`, from the pierre icon set, tooltip shows the language id); for unknown languages the language id text; a fence with `title=` or `file=` metadata shows icon plus file name, tail truncated. In reference 03a the Python logo (colored) is at the left.
- Actions (`flex items-center gap-0.5`, toolbar): optional wrap toggle (`wrap-text` 12px, `icon-xs`, `secondary` fill when on, `ghost-muted` when off), optional "Run in terminal" (`play` 12px, only shell fences with a trailing newline and a handler; not in a read-only view), copy (`copy` / `check`, 12px, 1.2s). 24px buttons, 2px apart. Wrap defaults on (`wordWrap` setting).
- Body: the highlighted `<pre>` (`index.css:1961-1976, 1991-2007`): `margin 0; border none; radius 0; background transparent; padding 0.8rem 0.9rem` = 12.8px top and bottom, 14.4px left and right; `overflow-x:auto` with a thin scrollbar; `max-width:100%`. With wrap on (`data-wrap="true"`): `white-space: pre-wrap; overflow-wrap: anywhere`, so no horizontal scroll. With wrap off: horizontal scroll, scrollbar height 7px, thumb a full pill in `Palette.border` at 78%, transparent track.
- Code text: mono, `font-size: var(--font-size-code)` = 13px default (`index.css:1706-1709`), color from Shiki per token (section 5), tab size browser default (8).
- Total block height for n lines: 1 + 30 (header) + 12.8 + 17.875n + 12.8 + 1 (borders in light). Reference 03a Python block: 2 lines.
- No line numbers, no active-line highlight, no gutter.
- Fences with an unknown language fall back to plain text with the default foreground. Mermaid fences render diagrams once the response settles (`MarkdownMermaidCodeBlock`, `:1013`), with a code toggle; WKWebView-scoped, not milestone 4.

### 4.12 Details and HTML

`<details>` renders `MarkdownDetails` (`:687-745`): `my-2 border-y border-border/60` (8px margins, 1px top and bottom border at 60%), trigger `flex w-full items-center gap-2 py-2 text-sm font-medium text-foreground` with a 16px `chevron-right` in `muted` that rotates 90deg open (`transition-transform` 150ms), panel `pb-3 ps-6` (12px bottom, 24px left) text at the 80% color. Raw HTML in assistant text is parsed (`parseRawHtml` default true) and sanitized; user messages show raw HTML as literal text.

### 4.13 Quick reference of spacing

| Between | Gap (px) |
|---|---|
| paragraph, paragraph | 10.4 |
| paragraph, list | 10.4 |
| list item, list item (tight) | 4 |
| any block, h1 to h6 | 20 above (collapses with the block's own 10.4) |
| heading, next block | 8 (collapses with 10.4, so 10.4 for p and lists) |
| block, code block | 10.4 |
| block, table | 10.4 |
| table, footer buttons | 2 |


## 5. Syntax highlighting

### 5.1 Themes

- Names: `pierre-light` and `pierre-dark`, from `@pierre/diffs` (`apps/web/src/lib/diffRendering.ts:5-14`, `resolveDiffThemeName`). Both chat code blocks and the diff panel use the same pair (`ChatMarkdown.tsx` passes `resolveDiffThemeName(resolvedTheme)`, `DiffPanel.tsx` passes the same to `FileDiff`). The theme follows the app's resolved light or dark theme. Variants named `-soft`, `-vibrant`, `-protanopia-deuteranopia` and `-tritanopia` ship in the bundle; nothing in the thread view or diff panel code selects them, so use the plain pair.
- Engine: `shiki-wasm` (Oniguruma WASM), forced in `lib/syntaxHighlighting.ts:16`. A native port can use a TextMate grammar engine with the same grammars, or the pierre theme JSON below with any Shiki-compatible tokenizer. The theme files were read from the installed app's bundle (`app.asar`, `apps/server/dist/client/assets/pierre-light-*.js` and `pierre-dark-*.js`); both have 248 token rules with identical scopes.

### 5.2 How token colors reach the DOM

1. `getSyntaxHighlighterPromise(language)` (`syntaxHighlighting.ts:20-40`) calls `getSharedHighlighter({themes:[dark, light], langs:[language]})`, a shared singleton that loads each grammar the first time a fence uses it. A language Shiki does not know falls back to `text`.
2. Chat blocks call `highlighter.codeToHtml(code, {lang, theme})` (`ChatMarkdown.tsx:1141-1190`), or `codeToHast` while streaming. Shiki emits `<pre class="shiki pierre-light" style="background-color:#ffffff;color:#0a0a0a"><code><span class="line"><span style="color:#d32a61">def</span>...`. Each token is an inline `style="color:#rrggbb"` span; italic scopes add `font-style:italic`. The result is cached (LRU, 500 entries or 50 MB) and inserted with `dangerouslySetInnerHTML`.
3. `.chat-markdown-shiki .shiki { background: transparent !important }` (`index.css:2003-2005`) drops Shiki's background so the frame's `bg-secondary` shows. The `<pre>` foreground (`#0a0a0a` light, `#fafafa` dark) is the default color for tokens without a scope.
4. Tool call commands and JSON use `highlighter.codeToTokens` and draw `<span style="color:...">` per token (`HighlightedTokens.tsx`, `V2ItemInspector.tsx:45-64`), with `fontStyle` bit flags 1 italic, 2 bold, 4 underline (`HighlightedTokens.tsx:15-23`).
5. Dark mode needs no CSS variable switch; the theme name changes and the block re-highlights.

### 5.3 Token colors (the scopes that matter for chat)

Values are `light / dark`. Default text `#0a0a0a / #fafafa`. Editor background in the theme (overridden to transparent) `#ffffff / #0a0a0a`. Italic only where marked.

| Scope family | Light | Dark |
|---|---|---|
| comment, punctuation.definition.comment, quote text | `#737373` | `#737373` |
| string, string punctuation | `#199f43` | `#5ecc71` |
| number, boolean, language constants (`true`, `None`) | `#1ca1c7` | `#68cdf2` |
| other constants, parameter-like constants | `#d5a910` | `#ffd452` |
| keyword, control, storage, `def`, `return`, `const` | `#d32a61` | `#ff678d` |
| function names and calls | `#693acf` | `#9d6afb` |
| type, class, support.type | `#a631be` | `#d568ea` |
| variable, property, object key | `#d47628` | `#ffa359` |
| parameter (function parameter) | `#636363` | `#a3a3a3` |
| namespace, module, language variable (`self`, `this`) | `#d5901c` | `#ffab16` |
| operators (arithmetic, comparison, assignment) | `#08c0ef` | `#08c0ef` |
| plain operators, punctuation, braces, delimiters | `#636363` | `#636363` |
| decorator, `@` | `#1a85d4` | `#69b1ff` |
| tag name (HTML) | `#d5512f` | `#ff855e` |
| attribute name, CSS class selector | `#18a46c` | `#60d199` |
| regex | `#17a5af` | `#64d1db` |
| escape sequences | `#16a994` | `#61d5c0` |
| JSON property name | `#d5512f` | `#ff855e` |
| JSON string value | `#199f43` | `#5ecc71` |
| markdown heading | `#d5512f` | `#ff855e` |
| markdown bold text | `#d5a910` | `#ffd452` |
| markdown italic | `#d32a61` italic | `#ff678d` italic |
| diff inserted line text | `#199f43` | `#5ecc71` |
| diff deleted line text | `#d5512f` | `#ff855e` |
| invalid | `#0a0a0a` | `#fafafa` |

Python example from reference 03a (light): `def` and `return` are `#d32a61`, `greet` `#693acf`, `name` `#d47628`... the screenshot shows `name` orange, `str` cyan `#08c0ef` (support.type.python), `->` `#08c0ef`, `f"hello, {name}"` string `#199f43`. Pull the full 248 rules with the extraction script before porting (the list above is the subset for chat; the complete scope list is the JSON in the bundle).

Editor-level colors in the same files that the diff panel reads (7.x): `diffEditor.insertedTextBackground` `#18a46c33 / #07c4801a`, `diffEditor.deletedTextBackground` `#d52c3633 / #ff2e3f1a`, `editorLineNumber.foreground` `#737373 / #737373`, `editor.lineHighlightBackground` `#dfebff8c / #19283c8c`, `editorIndentGuide.background` `#e5e5e5 / #1d1d1d`, `gitDecoration.addedResourceForeground` `- / #07c480`.

### 5.4 Languages loaded by default

None up front. The shared highlighter starts with the two themes and zero languages, then adds a grammar when a fence first needs it (`getSharedHighlighter({langs:[language]})`). The language id comes from the fence info string (`language-xxx` class, `extractFenceLanguage`, `ChatMarkdown.tsx:442-447`). Any grammar in Shiki's bundled set works (`@pierre/diffs` resolves ids and aliases). The command inspector additionally loads `shellscript` and `powershell` (`commandHighlightLanguage`), and every language found in embedded heredoc scripts (`lib/embeddedScripts`). The diff panel loads the language of each file from its extension. If the grammar fails to load the block renders as `text` with no token colors.

For the native app that means: ship a grammar set covering at least the common ids (`ts`, `tsx`, `js`, `jsx`, `json`, `bash`/`sh`/`zsh`/`shellscript`, `python`, `swift`, `rust`, `go`, `html`, `css`, `yaml`, `toml`, `markdown`, `diff`, `sql`), and render other ids as plain text.


## 6. Thread status line and scroll-to-bottom pill

### 6.1 Thread status line

`ThreadStatusLine.tsx:14-29`. One quiet line after the last message, used for settled, snoozed, or just-woken thread state. It renders in the list footer, above the composer inset spacer (`TimelineListFooter`, `MessagesTimeline.tsx:399-413`).

- Container `mx-auto flex w-full min-w-0 max-w-(--chat-content-max-width) items-center gap-1.5 px-4 pb-2 text-muted-foreground text-xs [&_svg]:size-3.5 [&_svg]:shrink-0`. Lane width as in section 1, 16px side padding, 8px bottom padding, 6px gap, 12px `muted` text (line height 16px), icons 14px.
- Content: icon (caller supplied), label (`min-w-0 truncate`), a `·` separator (`aria-hidden`), then an `InlineButton tone="muted"` with the action label ("Reopen", "Wake" style strings come from the caller in `ChatView.tsx`). `InlineButton` is a text-style button (underline on hover, muted tone); use the milestone 2 button and check its source `ui/button.tsx` (`InlineButton`) before drawing.
- It is not part of milestone 4 unless the thread is settled or snoozed in the data.

### 6.2 Scroll-to-end pill

`ChatView.tsx:11481-11502`.

- Wrapper: `chat-scroll-to-bottom pointer-events-none absolute z-30 flex justify-center py-1.5`, `bottom: scrollToEndClearance + 4px`. It spans the chat canvas width (insets are 0 without a floating preview, `index.css:2338-2341`) and centers the button. `scrollToEndClearance` is the height of the composer overlay plus its banners (`ChatView.tsx:7016-7022`), so the pill floats 4px above the composer's top edge, plus the wrapper's own 6px bottom padding. Without a composer (milestone 4 as specified) use `bottom = 4px + 6px` above the canvas bottom.
- Button: `Button size="xs" variant="glass"`: `h-6` (24px, `sm:h-6`), `px 7px` (8px - 1px border), `gap-1` (4px), text `text-xs` 12px weight 500 in `foreground`, `rounded-full`, border 1px `border` at 60% (hover: full `border`), `shadow-sm`, fill `surface-glass`: `Palette.background` at 80% (`--glass-opacity` 80%) with `backdrop-filter: blur(12px) saturate(1.14)` (`index.css:334-342`; our substitution is a solid 80% fill, see `docs/design.md`). Icon: lucide `chevron-down` 14px (`size-3.5`), `--control-icon-color` = `mutedForeground`. Label "Scroll to end". The button has the 0.97 press scale shared by all buttons (`button.tsx:11`).
- Visibility: shown when the user has scrolled away from the live edge (`!followEnd`, `ChatView.tsx:6833`). Showing is debounced 150ms so it does not flash while a thread opens (`:6342-6347`); hiding is immediate. Hidden while thread find is open. Appearance and disappearance have no transition.
- Click: `scrollToEnd(true)`, a smooth scroll to the bottom. The pointerdown default is prevented so focus stays where it was.

### 6.3 Thread find bar

Not drawn in milestone 4. `ThreadFindBar.tsx` reserves `THREAD_FIND_BAR_RESERVED_HEIGHT` at the top of the canvas when open (section 9).


## 7. Diff panel

Sources: `DiffPanel.tsx`, `DiffPanelShell.tsx`, `diffs/StyledDiffCodeView.tsx`, `diffs/DiffFileTree.tsx`, `lib/diffRendering.ts:315-378`, and the viewer's own stylesheet from `@pierre/diffs` 1.5.2. The library is not in the research clone (no `node_modules`), so its CSS was read from the compiled bundle of the installed app (`apps/server/dist/client/assets/getDiffFileInput-*.js`, string `Je`, 31 KB). Cite it as "pierre CSS". Reference captures show only collapsed file lists (`09`, `10`), so every body value below is computed from CSS, not measured from pixels. Section 9 lists what to verify.

### 7.1 Panel shell and header rows

`DiffPanelShell.tsx:5-47`.

- Inline mode (right panel): `flex h-full min-w-0 flex-col bg-background w-[42vw] min-w-[360px] max-w-[560px] shrink-0 border-l border-border`. Other modes are `w-full`. Background `Palette.background`.
- The panel sits inside a right-panel tab strip (reference `09`: a tab "Diff" with a file-diff icon, a `+` button, and maximize, bottom-panel and right-panel toggles at the right). Tab strip is outside these files (`RightPanelTabs.tsx`).
- Header row (web, non-Electron path, `DiffPanelShell.tsx:8-21`): `flex h-10 min-h-10 shrink-0 items-center justify-between gap-2 border-b border-border/60 bg-background px-4` = 40px high, 16px side padding, bottom border `border` at 60%. In an inline right panel that is mounted as a tab (`data-preview-panel-mode="inline"`) the row becomes `h-7 min-h-7 mb-3` with a transparent border (`index.css:912-918`: height 28px, 12px below). Reference `10` shows this variant: the controls row is centered at y=119 (2000px scale) under the tab strip.
- Left cluster (`flex min-w-0 flex-1 items-center gap-3`): scope dropdown `Button size="xs" variant="secondary"` (24px high, 12px text) with the label ("Changes", "Uncommitted", "Latest turn", "Turn N") truncated and a 14px `chevron-down` at 70% opacity. For the "Changes" (branch) scope a base-ref line follows: `text-xs muted` with `head -> arrow-right (14px, 70%) [base ref ghost-muted xs button with chevron-down]`.
- Right cluster (`flex shrink-0 items-center gap-1`), in order: line stat `+A -D` (`DiffStatLabel layout="inline"`, `mr-1 text-2xs` = 11px, `+` in `Palette.diffAddition` `#00bc7d`, `-` in `Palette.diffDeletion` `#fb2c36` / `#fb414a`, mono, tabular, `gap-1`); refresh `Button size="icon-sm" variant="ghost"` (28px) with a refresh icon that spins while refreshing; collapse or expand all files `icon-sm ghost` with a 14px `chevrons-down-up` or `chevrons-up-down` `MorphIcon`; segmented `ToggleGroup` with two `Toggle`s (`variant="segmented"`: 24px high, `px-2.5`, `rounded-md`, 12px text; `rows-3` unified, `columns-2` split, 14px icons); then three `Toggle variant="ghost" size="sm"` (28px): `text-wrap` (line wrapping, default on), `pilcrow` (hide whitespace changes), `folder-tree` (file tree). Reference `10` matches this order: +21k -0, refresh, chevrons, [rows3 | columns2], wrap, pilcrow, tree.
- Truncated, failed or empty states: a centered `text-xs text-muted-foreground/70` message; loading uses skeleton rows (`DiffPanelLoadingState`, `DiffPanelShell.tsx:104-116`: file header skeleton `h-8` rows with pill skeletons, a 24px separator skeleton, code line skeletons `h-2.5` pills at `space-y-2 px-3 py-2`).
- Patch too big: `border-b border-border/70 bg-muted/40 px-3 py-1.5 text-2xs text-muted-foreground`.

### 7.2 File list (collapsed files)

The body is a virtualized `CodeView` (`StyledDiffCodeView`) inside `.diff-render-surface`; the host element is a custom element with a shadow root. The surface sets `--code-background: var(--background)`, so it is `Palette.background` (`#fcfcfc` / `#0a0a0a`) and the text is `--code-foreground` (`Palette.codeForeground`: `#27272a` / `#f5f5f5`). No border or radius on the host (`index.css:2101-2107`). The file tree, when open, is an `aside` `w-[min(16rem,40%)] min-w-40 border-l border-border/60` to the right.

Item metrics given to the virtualizer (`StyledDiffCodeView.tsx:301-313`): file header 32px, hunk separator 24px, spacing 0, paddingTop 0, paddingBottom 8px.

File header (one per file, sticky at top of the scroll area, `z-index 4`; pierre `[data-diffs-header]` plus T3 overrides `StyledDiffCodeView.tsx:79-95`):

- Height `min-height: 32px`; `padding-block: 6px`; `padding-inline: 8px 12px` (left, right); `font-family: var(--font-sans)`; `font-size: 12px`; `line-height: 1`; `align-items: center`. Background `--code-background`. Border bottom transparent. `gap: 8px` between children (pierre `--diffs-gap-fallback`, row flex).
- Hover: background unchanged plus `box-shadow: inset 3px 0 color-mix(in srgb, code-foreground 24%, transparent)`, a 3px left bar in foreground at 24%.
- Children left to right:
  1. Collapse toggle (`renderHeaderPrefix`, `DiffPanel.tsx:123-164`): `Button size="icon-micro" variant="ghost"` = 20px square, `rounded-sm` (6px), `-ms-0.5` (2px negative margin), holding a 16px `chevron-right` (collapsed) or `chevron-down` (expanded) `MorphIcon` colored by change type: new `--diffs-addition-base`, deleted `--diffs-deletion-base`, modified or renamed `--diffs-modified-base`, otherwise `muted` at 80%.
  2. Change icon: a pierre SVG (`diffs-icon-symbol-added | modified | deleted | moved ...`, 16x16 viewBox, `fill: currentColor`): circled plus for new files (green, as in reference `10`), circled dot for modified, circled minus for deleted, duo and fill variants in the sprite. Colors: new `--diffs-addition-base`, deleted `--diffs-deletion-base`, change and renames `--diffs-modified-base`, plain file at 60% opacity. Size 16px (assumed; the SVG has no explicit size in the pierre CSS I extracted, check in the browser).
  3. File name (`[data-title]`): sans 12px, line-height 16px (override so descenders are not clipped), `white-space: nowrap`, `direction: rtl; text-overflow: ellipsis; overflow: hidden`, which truncates the START of a long path with a leading ellipsis (reference `10`: `...s/research/recovered/thread-project-commands.md`). `cursor: pointer`, hover color `color-mix(srgb, code-foreground 84%, primary)` over 120ms ease (`transition: color 120ms ease`). Rename: `prev-name` at 70% opacity, a short arrow icon, then the new name.
  4. Copy path button (`DiffFilePathCopyButton`): `icon-micro ghost-muted` 20px, 12px `copy` icon that morphs to `check` in `Palette.success`.
  5. Optional status button (`DiffFileStatus`): `icon-micro ghost-muted`, 12px `rotate-cw` (retry on error) or `info` (truncated preview).
  6. Right-aligned metadata (`[data-metadata]`, `gap: 1ch`, tabular nums): for the git-backed (lazy) source T3 hides pierre's counts and draws `DiffStatLabel` in aligned layout (`inline-grid grid-cols-[4ch_4ch] gap-2 text-right tabular-nums`, mono, `+N` in `Palette.diffAddition`, `-N` in `Palette.diffDeletion`, counts compacted: 1.2k, 21k, `formatCompactDiffCount`). Otherwise pierre's own counts: mono 11px, `--diffs-addition-base` / `--diffs-deletion-base`.
- Whole header is clickable: click on the name opens the file in the editor, click elsewhere toggles collapse (`DiffPanel.tsx:1107-1160`). Buttons in the header keep their own action.
- Collapsed rows are exactly the header, 32px, no separator between files and no border. Reference `10`: rows at 58px spacing in the 2000px image = 32px.
- Fade-in on expand: the body (`[data-diff]`, `[data-file]`) fades from opacity 0 to 1 over 200ms `ease-out` (`@starting-style`, `StyledDiffCodeView.tsx:268-280`). Collapsing cuts immediately. Reduced motion: none.

### 7.3 Diff body options

From `DiffPanel.tsx:1226-1236` and pierre defaults (`getOptionsWithDefaults`, bundle offset 102726):

| Option | Value |
|---|---|
| `diffStyle` | `unified` when the layout toggle is "stacked" (the default, `DEFAULT_DIFF_LAYOUT = "stacked"`, `packages/contracts/src/settings.ts:55`), `split` otherwise; reference `09` is split, `10` unified |
| `lineDiffType` | `none`, so there is no word-level or character-level highlighting inside changed lines |
| `overflow` | `wrap` when the wrap toggle is on (default `wordWrap` true), else `scroll` |
| `diffIndicators` | pierre default `bars` |
| `hunkSeparators` | pierre default `line-info` |
| `collapsedContextThreshold` | 1 (pierre default) |
| `expansionLineCount` | 100 lines per click on a separator |
| `disableLineNumbers` | false |
| `stickyHeaders` | true |
| theme | `pierre-light` / `pierre-dark` (section 5) |
| code font | `--diffs-font-family` = `--font-mono` (default stack `"SF Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace`), `--diffs-font-size` = the code size setting = 13px, `line-height` 20px (`--diffs-line-height` default; T3 never sets it), `tab-size: 2` |

Whitespace toggle (`diffIgnoreWhitespace`) filters the patch before parsing, no visual change.

### 7.4 Body geometry (unified)

Per file: header (32px), then `[data-code]`, a CSS grid of two columns: `[data-gutter]` (column 1) and `[data-content]` (column 2). `padding-top: 0` when a header precedes it, `padding-bottom: 8px` (`--diffs-gap-fallback`) minus the 6px scrollbar gutter when scrollable.

- Rows are 20px tall (one line, `min-height: 1lh`); in wrap mode a wrapped line grows by 20px per visual line (`white-space: pre-wrap; word-break: break-word`).
- Line cell `[data-line]`: `padding-inline: 1ch` (one `0` glyph width of the code font, about 7.8px for 13px Menlo or SF Mono 7.9px), position relative.
- Number cell `[data-column-number]`: `box-sizing: content-box; text-align: right; padding-left: 2ch; padding-inline-end 1ch; border-right: 2px solid var(--diffs-bg)`, content `min-width: max(3ch, digits of the largest line number)` (`--diffs-min-number-column-width-default`). Number text color `--diffs-fg-number` = Lab mix of the theme foreground at 65% with the background (light `#565656`, dark `#9d9d9d`, computed); on added lines `--diffs-addition-base` (light `#0dbe4e`, dark `#5ecc71`), on deleted lines `--diffs-deletion-base` (light `#ff2e3f`, dark `#ff6762`). Numbers are not selectable.
- Gutter background `--diffs-bg`; it is sticky at `left: 0` in scroll mode.
- Change bars (`diffIndicators=bars`): a 4px wide, full-height bar at the left edge of each changed line's number cell. Additions: solid `--diffs-addition-base`. Deletions: a 1px-period striped bar alternating `--diffs-deletion-base` and the line's deletion background (`repeating 2px gradient`, `pierre CSS` "bars" block). Context lines have no bar.
- Unified shows deletion lines first, then addition lines, within a hunk, each with its own old or new line number in the single gutter (pierre unified puts both numbers? In pierre's unified mode a changed line shows one number: the old number for deletions and the new for additions; verify in the browser).

### 7.5 Line backgrounds and colors (computed)

`diffRendering.ts:315-378` overrides pierre's tints with mixes against the surface color. Pierre then mixes in Lab: `computed line bg = lab-mix(surface, X%, target)` with X = 88 light or 80 dark for line cells and 91 light or 85 dark for number cells. `--diff-addition` is `Palette.diffAddition` (`#00bc7d` both themes), `--diff-deletion` is `Palette.diffDeletion` (`#fb2c36` light, `#fb414a` dark). Surface: `#fcfcfc` light, `#0a0a0a` dark. Results (I computed these with a Lab mixer; verify against pixels):

| Element | Light | Dark |
|---|---|---|
| context line and gutter background | `#fcfcfc` | `#0a0a0a` |
| added line background | `#eef8f4` | `#0e1713` |
| added line number cell background | `#eff9f4` | `#0f1713` |
| deleted line background | `#fef0f0` | `#1c100f` |
| deleted line number cell background | `#fef0f0` | `#1b110f` |
| hunk separator band (`--diffs-bg-separator`) | `#f1f1f2` | `#161616` |
| split-view empty buffer stripes (`--diffs-bg-buffer`) | `#e7e7e7` | `#212121` |
| hover on a context row (`--diffs-bg-hover`) | surface 94% + foreground 6% (about `#efefef`) | about `#1d1d1d` |
| hover on added or deleted row | the line target mixed in at 97% light, 91% dark (about 3% to 9% more tint) | |
| word emphasis (only if `lineDiffType` were on; it is off) | `#caefe3` / `#fcd2d4` | `#082e21` / `#3a1517` |

The tints are subtle by design. Code text color comes from the Shiki tokens (section 5); token backgrounds are transparent.

Selected lines (review comments): `--diffs-line-bg` = surface 88%/80% mixed with `--diffs-modified-base` (`#009fff` light, `#69b1ff` dark) per `StyledDiffCodeView.tsx:13-52`, plus a 4px `--diffs-modified-base` bar on the number cell. Comment annotations (`DiffCommentAnnotation.tsx`) are not covered (section 9).

### 7.6 Hunk separators

`[data-separator="line-info"]` with T3's overrides (`StyledDiffCodeView.tsx:97-186`):

- Height 24px, `margin-block: 0`, background `--code-background`. Wrapper `padding-inline: 8px 12px`.
- Content: `display:flex; align-items:center; gap: 8px`; text in the sans font, 11px, no underline, color `color-mix(srgb, code-foreground 52%, code-background)`. Layout is `———— N unmodified lines ————`: a 1px rule (`::before`) filling the left, the label, a 1px rule (`::after`) filling the right; rule color `color-mix(srgb, code-background 92%, code-foreground)`. The label reads "N unmodified lines" (pierre text).
- Only the gutter column is drawn in split mode for the additions side; the separator spans the full width in unified.
- Interactive: the whole band is clickable (cursor pointer) and expands 100 more lines in the direction of the hidden range; hover or focus raises the text to 76% foreground and the rules to `code-background 84% / foreground 16%`. The pierre expand buttons are visually hidden (1px clip) but keyboard reachable.
- First separator in a file has no top margin; last none at the bottom.

### 7.7 Split layout

`diffStyle: split`, wrap mode (`data-diff-type="split" data-overflow="wrap"`): a four-column grid `[del gutter | del content | add gutter | add content]`, each content column `1fr`. Rules: `[data-deletions] [data-content] { border-right: 1px solid var(--diffs-bg) }`, `[data-additions] [data-gutter] { border-left: 1px solid var(--diffs-bg) }`, i.e. a 2px seam in the surface color between the halves. Rows align by line; where one side has no line the other shows a buffer cell: `[data-content-buffer]` with a diagonal pattern, `repeating-linear-gradient(-45deg, transparent 0 4.24px, bufferColor 4.24px 5.66px)` on an 8x8 tile offset 5px, and the gutter side `data-gutter-buffer` with background `--diffs-bg-context-gutter` (light `#f7f7f7`, dark `#0d0d0d`). Scroll mode uses two independently scrolling halves (`grid-template-columns: 1fr 1fr`, 1px seams). Each half has its own number cells with the same geometry as 7.4. Reference `09` shows split selected in the toggle.

### 7.8 File tree (optional)

`DiffFileTree.tsx`, Pierre trees (`@pierre/trees` 1.0.0-beta.6): `density: "compact"`, `flattenEmptyDirectories: true`, `initialExpansion: "open"`, own icon set (`T3_PIERRE_ICONS`), no search. Aside `w-[min(16rem,40%)] min-w-40 shrink-0 border-l border-border/60`, header `h-10 border-b border-border/60 px-2 text-xs muted` with "Files" (`font-medium foreground`) and the count (`ml-auto tabular-nums`). Tree row metrics and git status colors come from the Trees stylesheet (`PIERRE_TREE_UNSAFE_CSS`, `lib/pierreTree*`), not read here. Off by default; skip for milestone 4.


## 8. Motion

Default Tailwind transition (`transition-colors`, `transition-opacity`, `transition-transform`, `transition-[...]` without a custom timing) uses 150ms and `cubic-bezier(0.4, 0, 0.2, 1)` (`Tokens.Duration.defaultTransitionDuration`, `Tokens.Easing.defaultTransitionTimingFunction`). Entries below say "150ms default" when they use it. Reduced Motion: every looping animation and fade below is removed or frozen.

| What | Property | Duration and easing | Source |
|---|---|---|---|
| Work log row focus or color changes | colors | 150ms default | `WorkLog.tsx:93` |
| Turn fold button hover (`muted` to `foreground`) | color | 150ms default | `MessagesTimeline.tsx:2708` |
| Chevron in tool entry rotating 0 to 90deg | transform | 200ms default easing (`duration-200`) | `:5718` |
| User message hover row (timestamp, copy, revert) | opacity | 200ms default easing | `:2540` |
| Assistant meta row reveal | opacity | 200ms default easing | `:2870` |
| Timestamp reveal in work rows and fold rows | opacity | instant (no transition class; swaps `absolute` to `static` and `opacity-0` to `100`) | `:2682` |
| Thread title chevron | opacity | 150ms default | `ChatHeader.tsx:341` |
| Breadcrumb project hover | color | 150ms default | `ChatHeader.tsx:279` |
| Attempt fold hover | background | 150ms default | `:2731` |
| System divider action hover | background | 150ms default | `TimelineSystemDivider.tsx:44` |
| Changed files rows hover, chevron rotate | background, transform | 150ms default | `ChangedFilesTree.tsx` |
| Event disclosure chevron | transform | 150ms default | `:3156` |
| Markdown details chevron | transform | 150ms default | `ChatMarkdown.tsx:722` |
| Live tool label shine | background-position | 2.2s `steps(30)`, infinite, only while visible and when motion is allowed | `index.css:545` |
| Working, compacting, worktree setup shimmer overlay | transform | 2.2s linear, infinite, only while visible | `index.css:604, 617` |
| Working timer text | content | updates every 1000ms, no animation | `MessagesTimeline.tsx:3496` |
| Streaming block fade-in | opacity 0 to 1 | 600ms `ease-out`, once per inserted block | `index.css:2011-2021` |
| Copy button icon swap (copy to check) | `MorphIcon` path morph | `MorphIcon.tsx` (milestone 2 component) | `MessageCopyButton.tsx:55` |
| Collapsed user message fade | none (static mask) | | `:4711` |
| Scroll to end pill | none on show or hide | show debounced 150ms | `ChatView.tsx:6342` |
| Scroll to end on click | scroll | smooth scroll to the end (browser smooth, no custom curve) | `ChatView.tsx` `scrollToEnd(true)` |
| Streaming follow (new content while running) | scroll | animated "glide" to the end (LegendList `animated: true`), only while working and motion allowed; otherwise instant | `:433-436`, `:1597-1604` |
| Minimap bars | transform, opacity | 150ms | `:1887, 1897` |
| Minimap container | opacity | 150ms | `:1790` |
| Diff file body appear | opacity | 200ms `ease-out`, on mount only | `StyledDiffCodeView.tsx:268-280` |
| Diff title hover | color | 120ms `ease` | `StyledDiffCodeView.tsx:255` |
| Diff header hover bar | box-shadow | none | `:93` |
| Button press scale | scale 0.97 | `transition-[box-shadow,scale]` 150ms default | `ui/button.tsx:11` |
| Tooltips on header, copy and icon buttons | | milestone 2 `TooltipView` | |
| Panel padding slide (header) | padding-left | `--panel-animation-duration` with `ease-out`, only when panel animations are on (right panel open or close); value not found in `index.css`, set at runtime | `WorkspacePageHeader.tsx:21`, `ChatView.tsx:11288` |

Not animated: work group expand or collapse (rows appear and disappear in the virtual list), turn fold expand, tool entry expand (the `WorkLogDetails` box mounts), plan card expand, table expand, code block wrap toggle.


## 9. Gaps

Everything here is unresolved or inferred. Measure it in the sandbox web client (headless Chrome at 2x, `scripts/capture-reference` style) before drawing.

1. No expanded tool card is in the reference set. Capture a thread with an expanded command entry (expanded `ls`), a file edit entry, a reasoning entry, and a group with 3+ tools (`work-toggle` open with the 288px scroller) in light and dark. This fixes: exact paddings of `WorkLogDetails kind="panel"`, mono output color and line height, the scroller edge fades (`virtualized-scroll-fade`, mask defined in `index.css` near `.virtualized-scroll-fade`, not read), and the visual state of icon brightness (`opacity-70 light:brightness-60`).
2. `light:` is a custom Tailwind variant (light theme only). Its definition was not read; confirm `brightness-60` applies to icons in light mode by sampling an icon pixel.
3. Message and code text rendering: confirm the mono font. `--font-mono` defaults to `"SF Mono", "SFMono-Regular", Menlo, ...` (`appearanceFonts.ts:25`), so on a Mac with SF Mono the code is SF Mono, not Menlo. `docs/design.md` says Menlo from this headless machine; that is a capture artifact. SF Mono has no `0` slash while Menlo does; reference `10` shows slashed zeros (`-0`), so that capture used a Menlo-like font.
4. Task list checkboxes (native, disabled): sample the real pixels in 03a for box size, border, fill, and check color in light and dark.
5. `hr` margin: confirm 0 vs 10.4px with a thread that has `---` between paragraphs.
6. Thread find bar, find highlights (`MarkdownFindContext`), assistant citation chips and the citation comment editor, selection toolbar, skill chips (`SkillInlineText`), file link chips (`MarkdownFileLink`), `MarkdownThreadLink`, `ContextChip`, user message context chips (`UserMessageContextReferenceChip`, `UserMessagePreviewAnnotationDetails`), review comment cards (`UserMessageReviewCommentCard`), `V2LifecycleRow` (622 lines), `V2SubagentGroup`, `WorktreeSetupCard`, `SecretRequestCard`, HTML render and MCP app frames, `QuestionAnswerHistory`, Mermaid, `HtmlRenderFrame`, expanded image dialog. All exist in the timeline; none were read. Pull them in when the data requires them.
7. Diff body values are computed, not measured. Capture an expanded file in unified and split, light and dark, with an addition, a deletion, a modified pair and a hunk separator, then sample: line backgrounds against the table in 7.5, the number cell colors, the bar colors, the separator text, row height 20px, `1ch` padding, the header icon size, and the deletion stripe pattern. Also confirm that unified mode shows one number column (old number on deleted lines, new on added) versus two.
8. Pierre defaults I inferred from the bundle: `diffIndicators: "bars"`, `hunkSeparators: "line-info"`. React `CodeView` may override defaults; the bundle's `getOptionsWithDefaults` is for `FileDiff`. Check `data-indicators` on a rendered file.
9. Right panel tab strip and header variant: the `h-7 mb-3` inline variant (`index.css:912-918`) vs the `h-10` header. Capture both states and measure the control row's top and height.
10. `scrollbar-gutter-both` on the timeline (`MessagesTimeline.tsx:1621`) is not defined in `index.css`; it may be a Tailwind plugin or custom utility. On macOS with overlay scrollbars it has no effect, but check whether a classic scrollbar setting shifts the lane by `--chat-timeline-gutter`.
11. The scroll-to-end pill position depends on the composer height; milestone 4 has no composer, so decide the bottom inset (suggest 10px: 4px offset plus 6px wrapper padding).
12. Sizes where I assumed Chromium's default metrics: native checkbox, `details` marker, default `strong` weight (`bolder` resolves to 700 against weight 400 text; with weight 500 parents it also resolves to 700), `mark`, `kbd`, `sup`.
13. Text details: Core Text measures 0.1 to 0.3px wider than Chromium (`docs/design.md`). Wrapped markdown paragraphs should be checked against the reference for identical line breaks, as the milestone 2 `TextBlockView` already does.
14. Timestamps: `formatDayAwareTimestamp` and `formatChatTimestampTooltip` (`timestampFormat.ts`) were not read; they depend on the `timestampFormat` setting (12h or 24h or locale). Read before building the hover row.
15. The relative "Worked for" duration uses `formatDuration` (`packages/shared/src/orchestrationTiming.ts:36`): under 1s `Nms`, under 10s one decimal (`4.2s`), under 60s whole seconds, then `1h 2m 3s` with zero parts dropped. The live "Working for" timer uses its own `formatWorkingTimer` (`MessagesTimeline.tsx:3477`): whole seconds under a minute (`4s`), then `formatDuration`.
16. Row `thinking` vs `work-live` ordering and which rows exist in a finished thread depends on `deriveTurnFolds` and the reducer in `MessagesTimeline.logic.ts` (2300+ lines). Port its logic from that file, not from the visuals here.
17. Dark-mode `bg-input/32` for code blocks and `dark:bg-input/20` for the changed files card use the `input` token's alpha (`#ffffff14`) multiplied by 0.32 or 0.2 (Tailwind `color/32` is `color-mix(in oklab, color 32%, transparent)`); confirm the composited color by sampling.
18. Panel header label for the scope dropdown, empty and error copy of the diff panel, and the exact strings for status line actions were taken from source and may change with the version.

