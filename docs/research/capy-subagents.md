# How Capy surfaces subagents

Source: `/Applications/Capy.app/Contents/Resources/renderer/assets/`, minified renderer chunks. Offsets are 0-based character offsets into the file (all ASCII-safe enough to `python -c "s[a:b]"`). I only read the bundle. Nothing was launched.

## Naming

- The user-facing word is "Subagent N" (N is the child's `localIndex`, nested paths look like `1.2`). Sources: `thread-view-BA5gQ-AE.js` 76457, 107763; `palette-CRn_A0Fk.js` 297521.
- Internally a thread is a "jam" (`jamId`), a subagent is a "task" (tab `kind:"task"`, `sectionId:"tasks"`, tools `subagent_create/start/stop/get/list`). `jam-chat-BPNHoOnC.js` 364176-364720.
- "Crew" and "Captain" are a different feature: sibling threads directed by a captain thread. They share the same UI lanes as subagents but are listed separately (`n.tasks` vs `n.crew`, jam-chat 214981).
- Plain text "Task 3" or "Subagent 3" in any message becomes a clickable chip. `chips-CEOAG6CS.js` 117066 (`/(?:Task|Subagent) ([1-9]\d*)/g`), chip label map 135100.
- Settings use "Concurrent subagents" and "Nested levels" limits (`capy-Khogjrwy.js` 12293, 13168). Not relevant to UI.

## Where they appear (five places, no floating window)

1. **Activity strip above the composer** (`jb`, jam-chat 210682-224310). This is the closest thing to a floating panel.
   - Collapsed: one small pill under the scroll area with counts only, e.g. a status dot plus "2" for `running subagent`, a terminal glyph plus count for background commands, a PR check count, live phones. aria-label `"N running subagent"` (214981).
   - Expanded (`expanded` prop, chevron `rotate-180`): a card with one 32px row (`Ib`, 219623) per running subagent: status glyph (`Ct`), "Subagent N", title, model chip (`ex`, provider icon plus model name). Click opens the subagent.
   - Collapsed pill is `absolute inset-x-0 bottom-0` in an `h-0` wrapper, so it overlays the timeline bottom without taking layout space. It shares the row with the scroll-to-bottom pill (`scrollPillHost`, `Pb` with `messagesBelow`).
   - Classes: `Vb = border-(--card-hairline) bg-card shadow-card`, `Hb = h-7 ... text-xs text-muted-foreground`, expand animation `duration-base`/`ease-out-quint`.
2. **"Waiting on" line** (`ty`/`iy`, thread-view 212700-215600, 213660). When the thread status is `waiting` the status area reads like "waiting on Subagent 1, Subagent 2, 3 other subagents". Each name is a button that opens that subagent. Folds after 3 (`Yv = length>3`, text `"N other subagents"`). Also shows "{person} to answer" when a subagent needs the user.
3. **Timeline** (jam-chat `Hy` 185700, dividers `M/P/ke/Ae` 1821):
   - Tool lines for `task_*`/`subagent_*` tools group under kind `task` (dividers 7412) with a verb label ("Creating and starting subagents" etc., jam-chat 364176).
   - Inline "Subagent N" chip: status glyph plus label, a button that opens the child. Hover shows a card (palette `BT` 296900-298900): "Subagent N" or "Side thread", relative time, title, and a footer with status icon and status label.
   - Completion rows (`task_completion` notification, jam-chat 115515; schema `index-DJ95JLkn.js` 662299: `childJamId, localIndex, outcome: completed|failed|stopped, summary`). Row text: "finished", "failed", "stopped" or "needs you"/"answered {name}" (dividers 1900). Tone: success, failure, neutral.
   - Blocked child: notice `task_blocked`, summary "Subagent N needs direction" (dividers 4503).
4. **Right overview panel** (`d_`, thread-view 161975; section 164972). A "Subagents" section (`dt` collapsible, count badge) with a tree of rows (`A_`, 170900): chevron, status glyph, "Subagent N" (tabular), title, task chip, then a second line "provider icon + model name · relative time" plus PR chips. Children nest with `pl-11`, sorted (`M_`), max 3 shown per level, each row draggable (`Km` dnd).
5. **Tab picker "+" menu** (thread-view 107200-114000, `sg`/`cg` at 123862). Section "Subagents" with a submenu per subagent: open its transcript (`rg`), its diffs/desktop (`ig`), its PRs, nested "Subagents", its machine ("N subagents on {machine}" palette 861536). Search keywords "subagents tasks".
   - A subagent opens as a tab `{kind:"task", jamId, localIndex}` labelled "Subagent N" (Wm, 76236). Draggable into any pane.
   - The same list appears in the command palette under "Subagents" (palette 305300-307200), linking to `/thread/$threadId?pane=task:{id}`.

## What each shows

- Title, "Subagent N", status glyph (working, waiting, needs-you, done, failed, idle via `qn`/`Ct`/`yt`), model + provider icon, relative last-activity time, PR chips, machine/previews.
- No cost or token figure on the subagent rows. Progress is only the status glyph. Live output only by opening it.
- Credits: `subagent_credits_ask`/`answered` notifications let a subagent ask the user for budget (jam-chat 92209, 112840).

## Interactions

- Open: click chip, strip row, panel row, palette item, "waiting on" name. All open a `task` tab via `TaskView` (`task-view-EI4HE7dh.js`), the same transcript renderer as a thread (`ce` timeline, read-only sections, `onOpenJam`). Parent link goes through `openJam`.
- Steer: the parent talks to a child with the `message_agent` tool (`to` = index). Children reply to the parent the same way; messages carry `sender.relation = parent|ancestor|captain|peer` (jam-chat 27819-28610). The task tab has no composer in the code I read (task-view is transcript only).
- Stop: parent-side via the `subagent_stop` tool, and thread-level Stop cancels ops (`control` command `stop`, jam-chat 103482). I found no per-row stop button in the strip or panel.
- Jump back: the transcript sits in the same window, so the tab strip is the way back. No explicit "parent" breadcrumb found.

## When scrolled away or in another thread

- Strip pill stays pinned above the composer with the running count and a status dot, wherever the timeline is scrolled.
- Other threads: sidebar rows carry the thread's own status. I found no per-subagent badge in the sidebar list, so subagents are not rows in the sidebar.

# CandyWrapper today (read-only grep of /Users/mrm/CandyWrapper)

- Timeline card: `SubagentCardRowView` (`Features/Thread/SubagentCardRowView.swift:175`) with `SubagentCardLinkView` per agent, pooled adjacent agents, click opens the child thread, live status from `subagentRecords`.
- Subagent thread header: `TimelineParentLinkView.swift:4-16`, a "Subagent of · {parent title}" divider pill.
- Subagent thread composer: `ProviderSubagentBarView.swift` replaces the composer with model, effort, ticking status and "Open parent" (T3 `ProviderSubagentBar.tsx:13`).
- Lineage list: `ThreadLineageSectionView` (`Features/Git/ThreadLineageSectionView.swift:277-330`), titled "Lineage · N running", inside `ThreadDetailsCardView`. Workflow rows in `ThreadLineageWorkflowViews.swift:12`. Controller `Features/Thread/ThreadLineageController.swift:13`.
- Redesign tab-band ⋯ menu: `ThreadPanelView.swift:880-897`, a "Lineage" label plus "Pull requests, automations and lineage" that opens the details card. It only appears when the card `hasRelations`.
- Sidebar: subagent threads are filtered out of the thread list (`T3Store/SidebarModel.swift:413`); `PendingSubagentRequests` (`T3Store/ChildThreadInputs.swift:55`) puts a pending-request marker on the parent row. Menu bar also hides them (`MenuBarMenu.swift:26`).
- Header: `DitherHeaderPillView.swift` and `ThreadCostPillView.swift` mention subagents for totals only (not checked in detail).

# T3 Code's own approach (`~/CandyWrapper-research/t3code/apps/web/src`)

- Lineage panel with per-row hover card, elapsed time and Stop: `components/chat/ThreadRelationshipsControl.tsx:196-579` (`interruptTurn` at 243-390, `canStop` 460, tooltip `SubagentTooltipContent` 497-499, elapsed `deriveSubagentElapsedMs` 538).
- Hover content: `components/chat/SubagentTooltipContent.tsx:34-54`.
- Subagent thread replaces the composer: `components/chat/ProviderSubagentBar.tsx:13-72`, mounted at `components/ChatView.tsx:2381-2382`.
- Banner above the composer when a child needs input: `components/chat/ThreadActivityBanners.tsx:19-30` (`childInputBannerItem`, hidden when the parent is itself waiting).
- Timeline: subagent group rows `components/chat/MessagesTimeline.tsx:1195`, notification link `V2LifecycleRow.tsx` (`SubagentNotificationLink`), `TimelineWorkEntryRow.tsx:467-472` "Open subagent thread".
- Sidebar: subagent threads have no row; an open subagent highlights its nearest non-subagent ancestor (`components/Sidebar.logic.ts:515-531`).

# Options for Redesign, ranked

1. **Composer activity strip (Capy's `jb`)**: collapsed count pill that overlays the bottom of the timeline, expands to one row per running subagent (glyph, "Subagent N", title, model), click opens the child. Best match for "always visible, never in the way" and already close to the user's floating idea; costs one new view plus a status feed from `subagentRecords`/`ThreadRelationships`, and it must stay hidden (zero idle cost) with no running agents.
2. **User's floating panel**: a draggable card over the thread with the same rows plus elapsed time and Stop (borrow T3's `canStop`). Most powerful for steering, but it covers content, needs position/persistence rules, and Capy does not do it, so it is the biggest build.
3. **"Waiting on Subagent 1, 2, +N" status line (Capy `ty`) plus the banner T3 already has**: reuses the existing `childInputBannerItem` path and adds named, clickable subagents when the thread is waiting. Cheapest, but only helps while the parent is blocked, so running-in-background agents stay invisible.
4. **Subagents section in the Redesign ⋯ menu / tab picker (Capy `sg`, palette)**: list the active subagents (Subagent N, title, status dot) directly in the menu instead of hiding them behind "Lineage". Tiny change and discoverable, but needs a click to see anything, so no ambient signal.

Recommendation: do 1 first with 3's wording folded into it (a waiting thread shows the strip expanded), then add Stop per row from 2 if the user wants steering.

Open gaps in this research: I did not find a per-row Stop, a cost figure, or a task-tab composer in Capy's code. Those may live in chunks I did not read (`index-DJ95JLkn.js` is 1.6 MB).
