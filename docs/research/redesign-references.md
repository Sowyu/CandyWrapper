# What Capy, Devin and Linear do that Redesign does not

Research for the redesign pass, 2026-11-20. It changes no app code. Images and raw measurements are in `~/CandyWrapper-research/sandbox/redesign-references/<product>/`, with a `sources.txt` per product listing each URL and the date fetched. The scripts that produced the numbers are in `scripts/` in that folder. The images are for private reference and are not in this repository.

## How to read the evidence

Three kinds of evidence are mixed here, and each number says which one it is.

- `img` is measured on a published product screenshot (pixel sampling, then scaled to a 1440-wide window). Accurate to about 1 px. Font sizes from images are estimates.
- `dom` is a computed style read from product UI that the marketing page builds as real HTML (Linear's and Devin's hero windows). Exact.
- `css` is a token or transition from the marketing site's stylesheet. It is the brand's own system, but it is not proof of what the shipped app uses.
- `src` is T3's source at `~/CandyWrapper-research/t3code`. `audit` is `docs/research/redesign-audit-2026-11-20.md` and its images.

Two facts change the framing of the whole task, so they come first.

1. Capy's current published product shots (the 2026 Captains UI) are flat. A light window has three opaque greys, no photo and no blur. Capy does ship an image wallpaper: its changelog says "an image wallpaper keeps up when you resize the sidebar", "Image wallpapers with the dither effect move like the default background" and "The wallpaper stays centered on the panel as the sidebar opens, closes, or resizes". No public image shows how text sits over it. So "photo behind glass" is not something I can measure on Capy. What I can measure is its layout and its flat surfaces, and those are what the user is praising.
2. `docs/decisions.md` (2026-10-21) says Redesign copied an older dark Capy: near-black chrome, `#131314` panel, teal `#2b948b`, a 52pt tab strip and an inset 12pt panel. Today's Capy is light-first with blue. The audit images show a flat right-panel slab and no tab strip or inset card on the thread page, so Redesign kept Capy's colors and, as far as these images show, lost the frame.

# Part A. Layout

## A1. Capy

Source: the 2560x1458 hero poster of capy.ai (`capy/home_hero-poster-desktop.webp`, a 1120 css px window at 2.2857x), `capy/features_captains_hero.webp`, `capy/blog_cloud-phones.webp` (dark), the 860-wide narrow poster, and the capy.ai changelog. All `img` unless marked. Percentages are of window width. Pixel values are scaled to a 1440 window.

```
1440 x ~820 window (hero poster ratio 1120 x 638)
x=0           308                        760                              1432 1440
+-------------+---------------------------+-----------------------------------+--+
| sidebar     |  8pt margin all round the inset card (1px border #e4e4e6, r~12)  |
| #f2f2f4     +---------------------------+-----------------------------------+
| 21.4%       | conversation  #fafafa     | right panel  #ffffff              |
| 308         | 31.4% = 452               | 46.3% = 666                       |
|             +---------------------------+-----------------------------------+
| logo+3 icons| tab "Web [1]" +  $0.41 ...| tabs: Overview | Issues | +   [] [] |  44pt header
|             |---------------------------|-----------------------------------|
| New thread  |                 [bubble]  | Needs you 1  v   (grey bar #f6f6f6)|
| Threads     | Worked for 4s             |  row: title / ACM-128 for Yuzu now |
| Issues  [1] | text lane = full column   | In progress 2 v                    |
| Pull req    | centered status lines     |  row, row                          |
| Automations | "All 3 threads finished"  | Pull requests 1 v                  |
|             |                           |  row                               |
| Captains +  |                           |                                    |
|  Web   [1]  |  +---------------------+  |                                    |
|   child rows|  | composer 93% of col |  |                                    |
|  API   [1]  |  | text / + model eff ^|  |                                    |
|  Infra ...  |  +---------------------+  |                                    |
|  (9 rows)   |   Cloud v          (ring) |                                    |
| avatar+org  |                           |                                    |
+-------------+---------------------------+-----------------------------------+
```

Region shares, measured on the poster:

- The sidebar is 0 to 547 px of 2560, so 21.4%, 308 px at 1440. Its background is the same `#f2f2f4` as the 8pt frame around the card, so the sidebar and the margin read as one surface and the card reads as lifted.
- The inset card runs from x=547 to 2542 and y=17 to 1442. That is a 7.4 css px margin on top, right and bottom (8pt in practice), a 1 px border (`#e4e4e6` left, `#ddd` right) and a faint outer shadow.
- Inside the card the conversation column is 547 to 1352 (31.4%, 452 px) and the right panel 1357 to 2542 (46.3%, 666 px), split by a 1 px `#eaeaea` line. The conversation column is a tone darker (`#fafafa`) than the panel (`#ffffff`).
- By area, the sidebar takes 21.4% of the window, the two content columns 76% and the margins and borders under 3%.
- The conversation has no maximum width in the published shot. The text lane is the column, 345 css px wide with about 13 px of side padding. That is narrow because the right panel is always open in the Captains view. At 1440 with the panel closed I could not see what the lane does. T3's 736 px lane and Redesign's earlier 864 px ("max-w-4xl") are not Capy measurements I can confirm.
- The composer is 320 css px in a 345 px column (93%), 81 px tall (one input line plus a toolbar row). It is white on the `#fafafa` column with a 1 px `#dadada` border and a 6 px soft shadow. It sits about 12 px above a quiet environment row ("Cloud v" on the left, a context ring on the right) that has no fill or border.
- The header is 44 to 45 px tall and is a tab strip, one per column. The left tab is the thread ("Web", an avatar, an unread badge, a "+"), with the cost ("$0.41") and an overflow menu at the column's right edge. The right tab strip holds "Overview", "Issues" and "+", then expand and toggle-panel icons.

Where things live:

- Project and thread navigation is the left sidebar. The 2026 changelog says "Captains and threads in one sidebar", with a Hybrid layout as the default and Split as an option. A setting called "Pages at top" lists Issues and Pull requests as rows above the list. In the hero shot five nav rows (New thread, Threads, Issues, Pull requests, Automations) sit above a "Captains" group with a "+" on the heading.
- The new-thread action is the first nav row, with a "+" at the top of the Captains group. Search is an icon in the sidebar header row beside the layout and collapse icons.
- The thread title is the tab label, not a title bar. There is no separate project or breadcrumb line in the thread header.
- Model and effort sit in the composer toolbar ("Claude Opus 5.5 v", "Medium v"), left of a 28 px blue rounded-square send button. The environment ("Cloud") is the row below the composer. Per-thread model choice is documented in the April 2026 update.
- Run status is inline: a centered grey "Worked for 4s" line and "All 3 threads finished" with a green check, and "Waiting on X and Y" for blocked work. I did not see a stop control or queued messages in any published image, so I cannot place them.
- Child tasks: under the selected Captain ("Web") three indented one-line rows show the child threads, with a short age ("now") on the right. The other Captains are collapsed to one row with an unread badge. So only the selected parent is open.
- Tool calls: the Captains shots show none, only prose with inline chips (issue ids in blue, PR links with a green glyph). The review page (`features_review_guide-hero.webp`) shows code and diffs as a left explanation column about 1/3 wide and a code card about 2/3 wide, with a segmented "Overview | Guide | Diff" control, "Capy Review", "Chat with Capy", "Review", "Merge" in the header and a breadcrumb "Pull requests > title +38 -19".
- Side panels are docked tabs in the right column. The blog shot shows a device tab ("iPhone 17 Pro Max", "Awake 41 min left") in the same strip as Overview. There is an expand-to-full button and a toggle.
- Files and terminal: not visible in any published image. Settings and the account: the account is the sidebar footer (avatar, name "Yuzu", org "Acme", a chevron). Settings is a nav row in the older layout. I could not see more.

Density:

- Sidebar rows are 28.5 css px tall, one line, name left and a badge or age right. Nav pitch is 28.5 px and group rows (Web, API, Infra, Mobile, Data, Security, Docs, GTM) are 28.5 px too. About 10 rows fit in the 638 px poster, which scales to roughly 13 at an 820 px window.
- The right panel uses two-line rows, 46 px pitch: a 14 px title and a 12 px grey meta line ("ACM-128 for Yuzu"). Group headers are 28 px grey bars (`#f6f6f6`, r8) with a count and a chevron.
- Chat text is about 14 px on a 19.3 px line (1.4). Paragraph and status gaps are 28 to 36 px. Status lines are centered, 12 to 13 px, grey.
- Long runs fold: "Worked for 4s" is one collapsed line.

Narrow (`home_hero-poster-narrow.webp`, a ~860 px window): the sidebar disappears entirely and only a toggle icon remains at the top left. The card keeps its 8 px margins and the two columns share the width, conversation 39% (about 324 px) and panel 61%. Nothing else changes, so it is a panel-away layout, not a smaller sidebar.

Decisions that make it work:

1. One frame. The sidebar and the margin share `#f2f2f4` and a 1 px bordered card sits inside, so there is exactly one edge to read (card border at x=547).
2. Three flat greys with 2 to 3% steps: `#f2f2f4` chrome, `#fafafa` reading column, `#ffffff` panel and composer. Depth comes from lightness, not shadow.
3. A 44 px header that is a tab strip. The thread name, cost and menu live in the column they act on, so no control is more than about 330 px from what it controls.
4. A composer at 93% of the column with its environment row below it as plain text. One object, one quiet row.
5. Single-line sidebar rows at 28.5 px with the state (badge, age) on the right. Ten or more threads are visible and the state is findable without opening.
6. Only the selected parent expands its children. Everything else stays one row.
7. Status in the thread is prose and a few centered grey lines, so the column reads top to bottom with no chrome.

## A2. Devin

Source: Devin's home page builds its hero window as real DOM, so these are `dom` values read at a 1440 viewport (`devin/hero-dom-probe.json`, `hero-dom-chain.json`). Dark mode: only an older docs GIF (`devin/docs_devin-progress-tab.gif`) exists, so dark values are not measured. Product shots are marketing and may not match the shipped app.

```
window frame 1019 x 630, r16, fill #f6f6f6 at 95% with blur(2px)
+------+---------------------+-------------------------------------------+
| rail | list column  239    | thread column ~733                         |
| ~42  | (24.6% of card)     |  header: "Security Reviewer > Add ... XL"  |
| home | Bots  + ...         |  messages: lane 522-560 (71-76% of col)   |
| bots | row 28.8 tall       |  user bubble r20 #0000000a, 14/20         |
| shld | Needs you 2         |  Devin 8:05 PM  prose 14/20               |
| bell | Pull requests 2     |  folded steps 13/18 grey 56%              |
| ...  | Sessions            |  PR card  [View PR] dark button r6        |
| srch |  New Ent... features 4                                           |
|      |   rows 25.6 tall    |                                           |
+------+---------------------+---------------+---------------------------+
                                  a 408-wide detail card ("PR Open", title, diff stat, analysis,
                                  test recording) floats over the window's right edge, shadow 0 25 50 -12
```

- The inner card is 973 x 595 white with r12 on a 1019 x 630 frame, so a 23 px frame on the sides and 17 px top and bottom.
- The list column is 239 px and the thread 733 px. The icon rail is 42 px.
- Sidebar: a "Bots" section (always-on agents), then "Needs you", "Pull requests", then "Sessions" grouped by status or by batch. Section headers are 32 px rows (13/18 weight 500, padding 0 8 0 16). Session rows are 25.6 px with 4 px padding and r6. Bot rows are 28.8 px, two lines (name and a grey summary).
- The thread header holds a breadcrumb (bot > session title) and a size tag. The docs GIF shows tabs "Progress | Shell | Code | Browser" at the top right of the session view. There the composer is a card with a status line on top ("Devin is sleeping") and the placeholder "Message Devin - this won't interrupt its work", which is how queued messages are explained.
- The detail card (PR status, analysis, a recording) is not a side panel. It overlays the right edge of the thread.
- Density: 13 px text on 18 px lines in rows, 14 px on 20 px in messages. Tool steps fold to a single grey 13 px line each ("Explored authentication across 3 repositories +13 -1"), with a green "5 tests passed" as the only colored word.

Decisions: a narrow icon rail plus a 24% list gives two levels of navigation in 280 px. Rows are the smallest on the page (25.6 px) and carry no borders. The thread has no header bar of its own beyond a breadcrumb. Folded steps keep the transcript short. Everything is Inter with a small negative tracking (-0.005em).

## A3. Linear

Source: the hero window on linear.app is real DOM (`linear/hero-dom-probe.json`, `hero-dom-chain.json`), 1440 viewport, `dom`. Layout principles come from Linear's posts "How we redesigned the Linear UI (part II)" (2024-03-28) and "A calmer interface for a product in motion" (2026-03-12).

```
window 1320 x 720 at x=60, bg #090a0b, r12
+-----------------+----------------------------------------------------------+
| sidebar 232     | main panel 1072 x 704, r8, fill white at 1%, 1px border  |
| (17.6%)         | at 5% white, ring 0 0 0 2px black 20%                    |
| rows 28 tall,   | header ~44: "DRV-8852 Faster app launch * ...   1/84 ^ v" |
| gap 2, r8,      | body: content lane ~660 + properties column on the right |
| pad 0 7, 13/510 | floating agent chat 400 x 520, r12, #161718, 1px white 12%|
| selected =      |  shadow 0 2 32 black 25%, bottom-right of the panel      |
| white 4%        |                                                          |
+-----------------+----------------------------------------------------------+
```

- The 2024 post calls it the inverted L: the sidebar and top bar are the chrome that controls the main view. Both redesigns aim to make the chrome recede ("Don't compete for attention you haven't earned", "Structure should be felt not seen").
- The sidebar is 232 px wide with an 8 px inset frame, so rows are 208 wide. Section order: workspace switcher, search and new-issue icons, then nav (Pulse, Inbox, My issues, Reviews), "Workspace" group, "Favorites" group.
- The 2026 refresh made the sidebar "a few notches dimmer", put the tabs in compact rounded icon tabs (not full width), reduced icon use and size, removed colored team icon backgrounds and softened and rounded the borders.
- The in-app agent ("Linear Opus 5.5") is a floating 400 x 520 panel (29% of the window width, 72% of its height) over the bottom-right of the main panel, with a reply box, a "Skills" control, expand and close buttons and a stop button.
- Density: 28 px rows at 13 px weight 510 (nav rows are `rgb(208,214,224)`, the secondary text color). The page title is 16 px on a 28 px line at weight 590. Activity lines are 12 to 13 px grey.
- The tab bar and the panel header sit on one 44 px line.
- Narrow behavior: not measured. The 2024 post says previous/next buttons, history and tabs had to be removable for browsers.

## A4. T3 Code

Source: `src` for numbers, `design/reference-4928/` for images (1100 x 780 window, 2x).

```
1100 x 780 window (1440 in the shares below)
+----------------+---------------------------------------------------------------+
| sidebar 256    | header 52: [project] / [thread title]            [3 toggles]   |
| 17.8%          +---------------------------------------------------------------+
| default 256,   |                                                               |
| min 208, max   |            lane: max 736 (46rem), centered                    |
| viewport-640   |        user bubble right, work log "Working for 6s"           |
| logo row ~52   |                                                               |
| Search + 3 ico |            composer = lane width (736), model + effort + mic  |
| rows ~82 each, |            + stop/send inside it, nothing below               |
| 3 lines:       |                                                               |
| project  time  |                                                               |
| title          |                                                               |
| branch   icon  |                                                               |
| footer icons   |                                                               |
+----------------+---------------------------------------------------------------+
right panel inline above 980 px, a popover below (rightPanelLayout.ts); browser/preview panel default 540, min 360, max 70% of the row
```

- `src`: sidebar default 256 (`threadSidebarWidth.ts:2`), minimum 208, main content minimum 640 (`:4`). The chat lane is `--chat-content-max-width: 46rem` = 736 (`index.css:131`), with Wide at 72rem and Full at 100%. The top bar is `--workspace-topbar-height: 52px`. The details panel is 17.5rem = 280.
- Where things live: search and filter and add-project and new-thread are one row at the top of the sidebar. Settings, pull requests, issues and usage are four footer icons, so they cost no list height. The thread title and project are the header breadcrumb, with panel toggles on the right. Model, effort, mic and stop/send are inside the composer, which is as wide as the lane.
- Status is on the thread row: "Done" (green), "Approval" (amber), "Input" (blue) and "Working 6s" (blue spinner) replace the time on the first line. A thread that needs the user is visible without opening it.
- Density: rows are three lines, about 82 px, so 7 to 8 rows show at 780 px high. The list starts at about 105 px (13% of the height).
- Tool calls fold to "Working for 6s" and "Worked for 3.8s >" with single-line steps inside.
- Narrow: the sidebar stays, and the right panel becomes a popover under 980 px. The main column never goes below 640 because the sidebar's maximum width is the viewport minus 640.

## A5. Redesign today

From the audit images in `~/CandyWrapper-research/sandbox/redesign-audit-2026-11-20/` (`dark-thread2-window.png`, `dark-right-panel.png`, `dark-narrow-thread.png`, 1100 x 780 and 840 x 780 windows, 1x) and the audit's text.

```
1100 x 780 window, thread page, right panel closed
+--------------+-----------------------------------------------------------------+
| sidebar 256  | [floating header pill, 30pt, top right, over the timeline]      |
| 23.3%        |  no title, no project, no breadcrumb                            |
| flat #0a0a0b |                                                                 |
| logo + toggle| art, scrim 0.35: assistant text and tool rows sit directly on it|
| Search   30  |   user bubbles are solid cards, assistant text has no surface   |
| New thread   |                                                                 |
| Pull req     |        lane ~744 (306 to 1051)                                  |
| Issues       |   +-------------------------------------------------+          |
| Automations  |   | composer  62% glass, r16, ~84 tall               |          |
| Settings 30  |   +-------------------------------------------------+          |
| = 180 total  |   [machine pill 30]                          [context ring]     |
| Threads  [] []                                                                 |
| project 3    |                                                                 |
| row  ~49     |                                                                 |
| row  ~49     |                                                                 |
| Settled (0)  |                                                                 |
| account+CPU  |                                                                 |
+--------------+-----------------------------------------------------------------+
```

With the right panel open at 1100 wide: chat column 360 pt (32.7%), panel 484 pt (44%), a flat slab to the window edge with square corners. The composer is 262 pt wide in that 360 pt column (73%), about 49 pt in from each side. The context ring at the bottom is clipped by the panel in `dark-right-panel.png`.

- Sidebar: six nav rows of 30 pt, 180 pt together. The thread list starts at 352 pt, which is 45% of the window height. Thread rows are two lines (title, then "main · 12m"), pitch about 49 pt, so about 7 fit at 780 pt and 8 at 900. The row's trailing glyph is the provider mark and carries no state.
- The header is a pill at the top right (cost, overflow, image, layout toggles, diff stat, panel toggle). It has no title. Content scrolls under it with no band (audit, "ask me: c" cut mid-word).
- Status: a working thread shows a spinner glyph only. "Approval" or "Input" states are not on the row.
- Right panel: flat slab. Tabs have close buttons that appear on hover (audit).
- Narrow (840 x 780): the sidebar stays at 256 (30.5% of the width) and the content column is 584 pt. The header pill still floats over the thread.

## A6. Region by region comparison

| Region | Redesign | Capy | T3 Code | Cost to the user |
|---|---|---|---|---|
| Sidebar width | 256 (23.3% at 1100) | 308 at 1440 (21.4%), hidden at ~860 | 256 (17.8% at 1440), min 208 | None at 1100. At 840 it takes 30.5% and leaves 584 for the thread, wasted width. |
| Space above the list | 352 pt, 45% of 780 | about 256 of 638, 40% | about 105, 13% | The nav block costs 180 pt, which is 3.7 thread rows. T3 hides the same destinations in four footer icons. |
| Thread row | 2 lines, 49 pt, state glyph is the provider | 1 line, 28.5 pt, badge or age on the right | 3 lines, 82 pt, state label on line one | Redesign hides "needs you" and "done". The user must open a thread to find out. |
| Thread title | none | tab label in a 44 pt strip | breadcrumb in a 52 pt bar | The user cannot tell which thread or project they are in without looking at the sidebar selection. |
| Header | 30 pt pill floating over content | 44 pt strip per column, solid | 52 pt bar, solid | Content scrolls under the pill and is cut mid-word. |
| Text lane | ~744 pt, no surface | column width (345 with the panel open) on a solid `#fafafa` | 736 on solid black | Text over art reads at about 6:1 (sampled) against about 18:1 on the references. |
| Composer | 262 pt in a 360 column (73%) with the panel open; ~84 tall | 320 in 345 (93%), 81 tall | 736, same as the lane (100%) | 98 pt of the 360 column is unused beside the composer. |
| Under the composer | machine pill (30) and context ring, with surfaces | environment row as plain text, 28 pt | nothing | 36 pt of height and two more shapes than Capy needs. |
| Model and mode | inside the composer ("Haiku 5.5 Low") | inside the composer | inside the composer | Same as the references. |
| Right panel | flat slab, 44% of the width, square corners, no inset | inset card, 46%, tab strip, always open | resizable, preview default 540, popover under 980 | The slab ignores the frame the rest of the window uses. 44% is the same as Capy's 46%, so the width is not the problem. |
| Stop and status | spinner glyph, "Worked for" line | prose and centered grey lines | red stop button in the composer, "Working for 6s" | Stop is in the composer in T3 and in Redesign. Same. |
| Subagents or children | not visible in the sandbox | one selected parent open, others collapsed | not in the reference shots | Unknown for Redesign. |
| Tool calls | folded to "Worked for 3.7s", opened rows float on art (audit) | none shown in the published shots | folded to one line, opened rows sit on solid black | An opened command has no container in Redesign. |
| Narrow | sidebar stays, header pill stays | sidebar goes away, two columns keep 8 pt margins | right panel becomes a popover under 980, sidebar capped at viewport minus 640 | See sidebar width. |
| Content against chrome | art everywhere, no stated edge | card 76% of the area, margins under 3% | solid columns | Redesign has no single edge to read. |

## A7. Ranked layout changes for Redesign

1. Show the thread title and project in a 44 to 52 pt header band on the thread page. References are 44 (Capy, Linear) and 52 (T3), Redesign is 0. Clear improvement.
2. Put a solid or at least 0.92 band behind the header and stop the timeline at its bottom edge. The 30 pt pill currently cuts text mid-word. Clear improvement.
3. Put the assistant text lane on a reading surface. Capy, Devin and Linear all draw it on `#fafafa`, `#ffffff` and `#090a0b`, at about 18:1, while Redesign reads at about 6:1. Clear improvement. How much art stays visible is a matter of taste, so show a picture with the panel at 0.92 and the art left in the 8 pt margin and the sidebar.
4. Show thread state on the sidebar row. T3 puts Done, Approval, Input and Working on line one. Redesign shows a provider glyph that carries no information. Clear improvement.
5. Widen the composer to the column minus 16 pt per side. At a 360 pt column this takes it from 262 to 328 pt, and Capy is at 93%. Clear improvement.
6. Make the right panel an inset card: 8 pt margin, 12 pt corners, a 44 pt tab header. Capy's panel is a bordered card inside an 8 pt frame. A matter of taste, show a picture first, because it changes how the art reads at the right edge.
7. Collapse the sidebar below about 900 pt wide. At 840 it takes 30.5% of the window, which leaves 584, and Capy shows a full-width pair of columns at about 860. Clear improvement for narrow windows.
8. Cut the nav block from 180 pt to about 60 pt: keep Search and New thread, move Pull requests, Issues, Automations and Settings to four footer icons as T3 does. The list then starts at about 230 pt, not 352, and shows 2 or 3 more rows. A matter of taste, because Capy keeps them as rows and the user liked that, so show a picture.
9. Drop the surface from the machine pill and the context ring and set them as 12 px grey text in a 28 pt row, as Capy does with "Cloud". Saves a shape and 8 pt. Matter of taste.
10. Make thread rows one line with the state or age on the right, 28.5 pt, and put the branch in the hover tooltip. 13 rows fit in a 780 pt window against about 7 today. Matter of taste, since T3, which the user prefers, uses three lines.
11. Open child threads only under the selected parent. Capy shows three rows under "Web" and nothing under the others. Clear improvement where it applies, but I could not see Redesign's child list in the sandbox.
12. Give an opened command or table the same card as a code block. Redesign has two treatments today (audit). Clear improvement.

# Part B. Styling

## B1. Capy

All `img` from the hero poster and blog shots unless marked `css`. Hex values are sampled at flat regions, so they are within a few units. Text sizes are estimates from line pitch and x-height.

| Property | Light (measured) | Dark (measured) | Source |
|---|---|---|---|
| Family | Inter. Mono: DM Mono for code, abcSocialMono for marketing display | same | `css` font stacks on capy.ai |
| Body in thread | about 14 px, line 19.3 px (1.4), weight 400 | same | img |
| Sidebar rows, nav | about 13 px, weight 500 | not measured | img estimate |
| Secondary and meta | about 12 px, weight 400 | not measured | img estimate |
| Headings in panel groups | about 13 px, weight 500 on a grey bar | not measured | img |
| Neutral ramp | `#f2f2f4` chrome and sidebar; `#fafafa` thread column; `#ffffff` panel, composer, cards; `#f6f6f6` group bars; `#eeeeee` user bubble; `#e5e5e7` selected row; `#eaeaea` dividers; `#e4e4e6`/`#dddddd` card edge | `#090b0c` tab strip; `#111317` panel and column; `#24252b` user bubble | img (light from `home_hero-poster-desktop`, dark from `blog_cloud-phones`) |
| Accent | blue `#4761cc` on the send button, unread badges and links (`#2f459b` text) | blue badge, green status dot | img. Marketing border blue `rgb(68,113,208)` (`css`) |
| Where accent shows | send button, unread count badge, issue and PR links. Green only for done and PR glyphs. Red only for needs-you. | same | img |
| Text contrast | primary `#111113` on `#fafafa` 18.1:1; secondary about `#7a7a7c` on `#f2f2f4` 3.8:1, about `#7d7d7d` on white 4.1:1 | not measured | computed from samples (antialiasing makes the secondary lighter than real, true value near 4.3:1) |
| Radii | 6 (chips), 8 (rows, send button, group bars), 12 (card, composer, bubble) | same | `css` counts: 6 px x71, 12 px x40, 8 px x36, 16 px x6; img |
| Border | 1 px `lab(0 0 0 / 0.08)` (17 uses), `/ 0.11` (7) | not measured | `css` |
| Shadow | card: `0 0 0 .5px rgba(0,0,0,.09), 0 3px 6px -2px rgba(0,0,0,.02), 0 1px 1px rgba(0,0,0,.04)` (16 uses). Composer measured as a 1 px `#dadada` ring and a 6 px fall to the background | none visible | `css`, img |
| Icons | outline with a light duotone fill, about 16 px, stroke about 1.5 | same | img estimate |
| Hover and selected | selected row `#e5e5e7` on `#f2f2f4` (about 5.5% black), no border, r8, 8 px side inset | not measured | img |
| Focus | not visible in any image | | |
| Motion | color, background, border 150 ms `cubic-bezier(0,0,.2,1)` (38 uses) or 100 ms `(.4,0,.2,1)` (21); opacity 200 ms `(.4,0,.2,1)` (64) | | `css` transitions |

Text over imagery: no image shows it. Capy's thread column and panel are opaque `#fafafa` and `#fff` in every published shot. The wallpaper is confirmed to exist and to be centered on the panel, but I could not see a scrim, a surface or a blur on it. The dark blog shot (`blog_cloud-phones`) puts the opaque `#111317` window on a purple dither texture, which is the same pattern: the texture is outside the reading surface.

What produces the premium impression:

1. The sidebar and the outer margin are one color and the card is a different one, so there is one edge.
2. Three greys 2 to 3% apart for chrome, reading and raised surfaces, not borders and shadows.
3. Primary text at 18:1 and secondary at about 4:1, so hierarchy comes from tone and not from size.
4. One blue, used for a handful of things (send, badges, links).
5. Radii from a set of three (6, 8, 12) and one card shadow recipe of a ring and two whispers.
6. Short transitions (100 to 150 ms, ease-out) on color only.

## B2. Devin

`dom` from the hero window at devin.ai (light only). Dark mode is not measured.

| Property | Value | Source |
|---|---|---|
| Family | Inter (lowercase `inter` in the stack), `skandia` for marketing headlines only (20/24), `SFMono-Regular` 12/18 for code | dom, css |
| Sizes | rows 13/18 weight 400 or 500, letter spacing -0.065 px; messages and section titles 14/20 weight 400 or 500, -0.07 px; secondary 12/16 | dom |
| Neutral ramp (light) | window frame `#f6f6f6` at 95% (`oklab(.979 0 0 / .95)`) with `blur(2px)`; card `#ffffff`; hover and bubble `rgba(0,0,0,.04)`; primary button `#363636` | dom |
| Text | primary `#191919`; secondary `rgba(25,25,25,.56)` which is about `#7e7e7e` on white | dom |
| Contrast | primary 17.6:1, secondary 4.1:1 | computed |
| Accent | text accent and blue/purple/green/orange text tokens exist (`--text-blue` and others); the hero uses green only for "5 tests passed" and the PR-open label, and a near-black button for the primary action | dom, css |
| Radii | 6 (rows, button, 69 uses), 12 (card, 10), 16 (frame, 7), 20 (message bubble), 4, 10, 14, pill | dom, css |
| Border | 1 px `rgba(0,0,0,.08)` (16 uses), `.06` (14), `.04` | css |
| Shadow | card `0 1px 2px rgba(0,0,0,.05)`; floating card `0 25px 50px -12px rgba(0,0,0,.25)` | css |
| Hover and selected | rgba(0,0,0,.04) fill, r6, 4 px padding | dom |
| Motion | 150 ms `cubic-bezier(.4,0,.2,1)` (12), 100 ms `(0,0,.2,1)`, 200 and 300 ms for opacity, 1.8 s for ambient fades | css |
| Icons | not measured, outline | |

Text over imagery: the frame behind the app is a soft 95% fill with a 2 px blur over an abstract gradient background; the reading card inside is opaque white. The 408 px detail card that overlaps the window edge has its own opaque fill and the 25/50/-12 shadow. The abstract background images (`new-home/frontier-models/background-*`, `graphic-backgrounds/vellum-blur-2.webp`) are marketing art.

Decisions that make it premium:

1. A smaller type scale (12, 13, 14) with a tiny negative tracking and weights of only 400 and 500.
2. The 56% secondary and 4% hover, so every state is the same ink at a different alpha.
3. Rows without borders, 25.6 to 32 px.
4. A near-black primary button, so the interface stays monochrome.
5. Three radii of 6, 12 and 20 (bubbles are the only large ones).
6. The frame is the only translucent thing and it is almost opaque (95%, 2 px blur).

## B3. Linear

Colors are from the marketing stylesheet tokens (`css`), which Linear's 2024 post says are the same theme generator as the app (base, accent and contrast, built in LCH). Component values are `dom` from the hero window. Light and dark values are listed in the same row.

| Property | Dark | Light | Source |
|---|---|---|---|
| Family | Inter Variable, features `cv01`, `ss03`; weights 300, 400, 510, 590, 680; Berkeley Mono for code (14/24) | same | css |
| Sizes | rows 13/normal weight 510; titles 16/28 weight 590; small 12 to 13; micro 11 to 12; body 15 to 16 on marketing | same | dom, css |
| Neutral ramp | `#08090a` page, `#0f1011` panel, `#141516` level 2, `#191a1b` level 3, `#1c1c1f` secondary, `#232326` tertiary, `#28282c` quaternary; window `#090a0b`; floating chat `#161718` | `#ffffff`, `#f8f8f8`, `#f4f4f4`, `#f0f0f0`; `#f9f8f9`, `#f4f2f4`, `#eeedef`, `#e9e8ea` | css, dom |
| Text | `#f7f8f8` primary, `#d0d6e0` secondary, `#8a8f98` tertiary, `#62666d` quaternary | `#282a30`, `#3c4149`, `#6f6e77`, `#86848d` | css |
| Contrast on `#08090a` | 18.7, 13.6, 6.1, 3.5 | not computed | computed |
| Accent | `#7170ff` (hover `#828fff`, tint `#18182f`); brand `#5e6ad2` | `#7070ff` brand, hover `#8989f0`, tint `#f1f1ff` | css |
| Where accent shows | selection, links, primary actions, status colors per item (yellow in progress, green plan, gold build). The hero shows status icons in color and everything else grey | | dom, img |
| Radii | 8 (rows and inputs), 12 (window, floating panel), 9999 (pills), 4 and 6 (small) | | dom, css |
| Border | `rgba(255,255,255,.08)` (66 uses), `.12` (11), `.05` (3) and solid `#23252a`, `#34343a`, `#3e3e44` in three steps | `#e9e8ea`, `#e4e2e4`, `#dcdbdd` | css |
| Shadow | ring `0 0 0 1px rgba(0,0,0,.2)`; inset hairline `0 0 0 .5px rgba(255,255,255,.08)`; floating `0 2px 32px rgba(0,0,0,.25)` with a 1 px `.12` border; menus `0 8px 32px #08090a0d` | | css, dom |
| Icons | outline, the 2026 refresh reduced their number and size and removed colored backgrounds from team icons | | blog post |
| Hover and selected | selected row `rgba(255,255,255,.04)`, r8, 7 px side padding, gap 8 | | dom |
| Glass | header blur 20 px (`--header-blur`), menus `#ffffffe6` (90% white), anchor glass `#00000014` | | css |
| Motion | color 100 ms `cubic-bezier(.25,.46,.45,.94)` (187 uses) or `ease`; filter and transform 160 ms; background 400 ms ease-out | | css |

Text over imagery: none. Translucency is limited to the header (20 px blur), menus (90% fill) and a few inset hairlines. In the October 2025 liquid glass post Linear says it rebuilt glass for mobile and draws the line between Aqua (translucent, tactile) and ProKit ("flatter gradients and sharper edges" for "information-dense workflows where clarity and control are more important than visual flourish"). That is the closest published guidance for a photo-behind-glass app: glass on chrome, flat on the reading surface.

Decisions that make it premium:

1. Chrome that recedes. The sidebar is dimmer than the content (2026 post) and rows are secondary-colored until selected.
2. Borders at 8% alpha in three steps, with fewer separators and rounded ends.
3. Three theme inputs (base, accent, contrast) produce every neutral, so no one-off greys exist.
4. One weight between regular and medium (510) and one size for rows (13).
5. Rows at 28 px with 2 px gaps and 8 px radii in an 8 px inset frame.
6. The accent is rare, and status colors appear only as small icons.

## B4. What the three share, and what differs

Shared:

- Inter at 12, 13 and 14 px with weights 400 and 500 (Linear 510). Row text is 13.
- A reading surface that is opaque, in a flat grey 2 to 3% from the chrome. Chrome is the same color as the margin or darker.
- Primary text at 17 to 19:1 and secondary at 4 to 6:1.
- Rows of 25 to 29 px, radius 6 to 8, with a fill of about 4% ink as the selected or hover state and no border.
- Three radii: 6 or 8, 12, and a larger one for the window or bubbles.
- Borders at 6 to 11% alpha.
- One accent used sparingly. Capy blue, Linear violet, Devin none (near-black button).
- Transitions of 100 to 150 ms with `cubic-bezier(0,0,.2,1)` or `(.4,0,.2,1)`.
- Folded run detail: "Worked for 4s", "Explored authentication...", "Worked for 10 sec".

The safest to adopt is the shared set above, because every product agrees on it.

Where they differ:

- Capy's frame is an inset bordered card. Linear's is an inset panel with a 1% fill and a 5% border on a darker window. Devin's is a card inside a 95% translucent frame. For an app with a photo behind it, Devin's frame is the closest match: the only translucent part is the frame, and the reading card is opaque.
- Accent: Capy blue is the most visible and works as the send button; Linear violet is the most restrained.
- Secondary text: Linear uses four named steps, Devin one alpha (56%), Capy one grey. One alpha is simplest and fits a theme over an image.
- Fonts: Linear and Devin ship Inter plus tracking and variable features. Capy ships Inter. None of them is a custom face for the UI, only for marketing headlines (`skandia`, `Tiempos`).

CandyWrapper uses the system UI font, which is SF Pro. SF is close to Inter at 13 and 14 px, so use `NSFont.systemFont(ofSize: 13, weight: .medium)` for rows, add -0.005em tracking at 13 and 14 (Devin's -0.065 and -0.07 px), and keep weights to regular and medium. No licensed font is needed.

## B5. Redesign against the references

Redesign's values come from the audit's token inventory and from the pixel samples of its window screenshots.

| Property | Redesign now | References | Gap |
|---|---|---|---|
| Reading surface | art with scrim 0.35 (dark), 0.65 to 0.92 (light); assistant text has no surface | opaque, flat | sampled text contrast is 6.0 to 6.3:1 dark and 6.7:1 light against 17.6 to 18.7:1 |
| Neutral ramp, dark | `#0a0a0b` sidebar, `#131314` composer and panel, `#202021` selected | Linear `#08090a`, `#0f1011`, `#141516`, `#191a1b` | similar, but selected is a 5.5% step above chrome vs Linear's 4% overlay |
| Neutral ramp, light | `#ececec` sidebar, `#e5e5e5` composer, scrim veil over art | Capy `#f2f2f4`, `#fafafa`, `#ffffff` | Redesign's light has no white surface, so the composer is darker than the page |
| Accent | teal `#2b948b` on send, focus ring, underline, file chip, green and coral status | one blue on send, badges, links | 4 or more accent uses against 3 |
| Text sizes | 6 in Redesign arms, 13 in shared views (9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 30) | 3 to 4 (12, 13, 14, 16) | 13 distinct vs 4 |
| Radii | 9 named (8, 12, 16, 10, 3, 3.5, 1.5, 4, circle) | 3 (6 or 8, 12, 16) | 9 vs 3 |
| Border alpha | 0.08, 0.07, 0.05 and `contrastBorder` 0.6 | one at 0.08 | 4 vs 1, and 0.6 is 7 times stronger |
| Shadows | 7 recipes reachable, 51 `BoxShadow` lines inherited | 1 to 2 | 7 vs 2 |
| Surface fills | 0.62, 0.86, 0.4, 0.01, 1 and 3 hover fills (0.035, 0.055, 0.08) plus 0.04 and 0.065 | 1 hover fill (0.04) | 6 vs 1 fills, 5 vs 1 hovers |
| Blur | 12 pt | Linear header 20 px, Devin 2 px | within range, but 12 is too low for a text-bearing glass |
| Motion | 150 ms `(0.23,1,0.32,1)` for pills, 10 curves and 14 durations (0.1 to 0.9 s) inherited | 100 and 150 ms on 2 curves | 14 durations vs 3 |

## B6. Twelve styling recommendations, ranked by how much each closes the gap

1. Put the thread lane, tool output and tables on one reading surface at 0.92 opacity (`#131314` dark, `#fafafa` light) with a 12 pt corner and 8 pt inset, so primary text moves from about 6:1 to about 15:1 and the art stays in the margin, sidebar and new-thread page.
2. Use one border alpha, 0.08 white in dark and 0.08 black in light, for every card, popover and divider, and drop 0.05, 0.07 and `contrastBorder` 0.6.
3. Cut shadows to two: a card of `0 0 0 .5px rgba(0,0,0,.09), 0 1px 1px rgba(0,0,0,.04), 0 3px 6px -2px rgba(0,0,0,.02)` and a floating one of `0 2px 32px rgba(0,0,0,.25)` with a 1 px 0.12 border.
4. Limit text to 12, 13, 14, 16 and 22 pt, with rows at 13 pt medium, the thread at 14 pt on a 20 pt line and meta at 12 pt on 16.
5. Use one secondary-text alpha, 0.62 (about 4.9:1 on white and on `#131314`), and 0.4 only for timestamps.
6. Make selected rows white 4% in dark and black 5.5% in light with an 8 pt radius, and hover half of that (2% and 3%), replacing all nine hover fills.
7. Keep glass for chrome only (header band, composer, popovers, palette) at fill 0.78 dark and 0.82 light with a 20 pt blur, and have every popup use it, including the model picker.
8. Limit the radii to 8 (rows, buttons), 12 (cards, menus) and 16 (window, composer) and remove 10, 3.5 and 1.5.
9. Use the accent for the send button, the unread badge and links only, and draw status in neutral ink with a 6 pt colored dot at most.
10. Set hover and focus color changes to 100 ms and opening to 150 ms, both on `cubic-bezier(0,0,.2,1)`, and retire the other 9 curves.
11. In light mode use the Capy ramp: `#f2f2f4` for sidebar and margin, `#fafafa` for the thread, `#ffffff` for the composer and panel, with a 1 px `#dadada` composer border, and stop veiling the art at 0.77.
12. Dim the sidebar one notch: rows at secondary ink (`#d0d6e0` in dark, 0.62 alpha in light), icons at 14 pt with a 1.5 pt stroke, and primary ink only on the selected row.

## B7. The five largest gaps

1. Text over art reads at 6.0 to 6.3:1 in dark against 17.6 to 18.7:1 on all three references, because the scrim is 0.35 and assistant text has no surface.
2. The thread has no title: 0 pt of header against 44 pt (Capy and Linear) and 52 pt (T3), and the floating 30 pt pill cuts text under it.
3. The composer is 262 pt in a 360 pt column (73%) when the right panel is open, against 93% at Capy and 100% at T3, with 36 pt of extra pills below it.
4. The list starts 352 pt down (45% of a 780 pt window) against 105 pt in T3 (13%), because six nav rows take 180 pt, and the rows carry no state where T3 shows Done, Approval and Input.
5. Token sprawl: 7 shadow recipes, 13 type sizes, 9 radii and 6 fill opacities, against 1 to 2 shadows, 3 to 4 sizes and 3 radii.

# Part C. What I could not verify

- I did not open any of the three apps. Every Capy number comes from published images and the Linear and Devin numbers come from marketing pages. Marketing imagery is usually idealized: sample data, no scrollbars, no long threads.
- Capy: the hero poster, the Captains and review images and the blog images are the only app shots. The light layout (sidebar 21.4%, conversation 31.4%, panel 46.3%) is read from the poster and could be a staged proportion. I saw no dark Capy window beyond the cloud-phones crop, no focus ring, no stop button, no queued messages, no file tree, no terminal and no tool-call rows. Font sizes are estimates from line pitch.
- Capy's wallpaper: the changelog confirms it and says it is centered on the panel. I could not see any image of text over it, so the scrim, blur and surface recommendations are inferred from Linear and Devin, not measured on Capy.
- Capy's own thread width at 1440 with the panel closed is unknown. The earlier 864 px figure in `ThreadFindBarView.swift` cites "max-w-4xl" and I could not confirm it.
- Devin: only the hero window's light mode is measured. Dark mode comes from an old docs GIF (the 2025 Devin 2.0 UI), so dark tokens, the tab strip and the composer card may not match the current app. The 408 px detail card width is read off a screenshot.
- Linear: the hero window is marketing DOM. The colors are the marketing site's tokens. Linear's 2024 post says the app uses the same generator, but I did not see the app. Narrow behavior was not measured.
- T3: right panel width for the diff panel was not found. I measured only the preview panel (default 540, min 360, max 70%). Redesign's measurements are from 1x screenshots at 1100 and 840 wide, not 1440.
- Contrast numbers on Redesign use a handful of sampled pixels on a busy photo, so they are indicative (6 to 7:1), not a worst case. The audit says some muted text falls under 4.5:1, which I did not re-measure.
- No product video was available without signing in, so I measured no motion from video. Motion numbers are marketing-site CSS transitions.
- I did not sign in anywhere and made no accounts. Linear's and Devin's help pages were not read beyond the session-tool docs.

## Images

Best three per product, all under `~/CandyWrapper-research/sandbox/redesign-references/`:

- Capy: `capy/home_hero-poster-desktop.webp`, `capy/features_captains_hero.webp`, `capy/blog_cloud-phones.webp`. Also `capy/features_review_guide-hero.webp` for code and diff.
- Devin: `devin/home-hero-app-y440.png`, `devin/home-light-top.png`, `devin/docs_devin-progress-tab.gif`.
- Linear: `linear/home-hero-app-y500.png`, `linear/home-dark-top.png`, `linear/post_67561b_3904x2720.avif`.
