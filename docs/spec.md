# Project spec (verbatim from the user, 2026-10-09)

This is the original brief. Do not edit it. Decisions made since then live in `PROGRESS.md`.

---

# Build an ultrafast, battery-efficient T3 Code client for macOS (no Electron)

## Goal
Build a macOS app that does everything T3 Code does: same features, same sidebar, same workflows and full T3 Connect support. It must **look as close to identical to T3 Code as possible**. Without Electron, it should be much faster, much lighter and much easier on the battery.

It should launch instantly, scroll smoothly, use close to zero CPU when idle, never use the discrete GPU, and barely show up in Activity Monitor's Energy tab. A T3 Code user should not be able to tell it apart from the official app by looking at it, only by how fast it feels.

## Hard rules
- **No Electron, no Chromium, no webviews.** No Electron, CEF, WKWebView-based UI, Tauri, React Native, Flutter or JS UI frameworks. If any part of the plan would ship or launch a browser engine, stop and ask me first.
- **Study the real source first and don't guess.** Clone the official T3 Code repository (pingdotgg/t3code) and read it before writing any app code. Work out the client↔server protocol (WebSocket/RPC schemas, event streams, auth/handshake), the orchestration model (projects, threads, turns, worktrees, providers, approvals, queue) and how T3 Connect works (pairing, auth, remote environments, transport). Write it up in `docs/protocol.md` and treat that file as the contract you build against.
- **Stay protocol-compatible.** Use the same T3 server and the same T3 Connect endpoints as the official app. Threads created in this app must appear correctly in official T3 Code, and the reverse must also work. Ask me before doing anything that would break compatibility.
- **Backend:** T3 Code's backend is a headless Node.js server, separate from Electron. Run it headless as a child process, or connect to an existing or remote server. Never bundle or launch the official Electron app or any part of it.

## Tech stack
- **Swift 6 + AppKit, fully custom-drawn UI.** Don't use stock system controls. Build an in-house component library (buttons, inputs, menus, popovers, tabs, list rows, cards, tooltips, scrollbars) on layer-backed `NSView`s and Core Animation, with TextKit 2 for text. Every component reproduces its T3 Code counterpart.
- Why this stack: the system compositor, App Nap, timer coalescing and integrated-GPU-only rendering give the best battery life on macOS, while custom drawing lets the app match T3 Code's look exactly.
- SwiftUI may be used only for low-traffic screens such as settings, and must still match T3 Code visually. Anything that can grow without limit (timeline, sidebar, diffs, terminal) must be AppKit with view recycling and virtualization.
- Keep dependencies to a minimum and justify each one in writing. Acceptable examples: tree-sitter for syntax highlighting, SwiftTerm for the terminal.
- Minimum macOS version: 14. Universal binary, optimized for Apple Silicon.

## Design: pixel-faithful to T3 Code
The official app is the spec. **Copy it; don't reinterpret, "refine" or "improve" it.**

**Extract the design from the source, not from memory:**
- Pull every design token from the T3 Code repo: Tailwind config, CSS variables, theme files and component styles. That covers colours (dark and light), spacing, radii, border widths and colours, shadows, opacity, font sizes, line heights, font weights, letter spacing and transition durations/easings. Generate a Swift `Tokens` file from them with a script (`scripts/extract-tokens`) so it can be re-run when T3 changes. Don't hand-copy values.
- Use the same fonts as the official app (check what the repo loads). Bundle them if they're not system fonts and the license allows it.
- Use the same icon set the repo uses. Convert those exact SVGs into vector assets; don't substitute SF Symbols or lookalikes.
- Copy all UI text exactly: labels, placeholders, empty states, tooltips, menu items, error messages and keyboard-shortcut hints.

**Match layout and behaviour exactly:**
- Same sidebar width (default, min and max), header heights, panel splits, padding, row heights, list density, message widths, composer size and position, and card/diff/tool-call layouts.
- Same hover, pressed, focus, selected, disabled and loading states for every component.
- Same motion: which elements animate, the duration and easing, what collapses and expands and how. Copy the official values directly. Animate only transforms and opacity via Core Animation, and respect Reduce Motion.
- Same scroll behaviour (sticking to the bottom while streaming, the jump-to-latest button), same context menus, same popover and dropdown placement.
- Same Markdown and code styling: code block chrome, syntax highlighting theme colours, inline code, tables, links and the diff colours/gutters.
- Same window chrome as the official app (traffic-light position, title bar and draggable regions).
- Light and dark themes exactly as T3 Code does them, following the same setting/system behaviour.
- Quality bar: pixel-aligned on Retina, crisp 1 px hairlines, smooth 120 Hz scrolling on ProMotion, no layout jumps while text streams in.

**Where a web effect is expensive** (e.g. `backdrop-filter` blur, large blurred shadows, gradient animations, looping spinners): reproduce the *look* with a cheap native equivalent, such as a pre-rendered or static shadow image, a solid colour with matching perceived tone, a cached blur, or an indicator that only ticks occasionally. Record each substitution in `docs/design.md` with a side-by-side screenshot. Fidelity matters most, but never at the cost of the idle/battery targets.

**Process:**
- Run the official T3 Code app side by side throughout development and capture reference screenshots of every screen and state, in both themes, at the same window size. Store them in `design/reference/`.
- `docs/design.md`: token sheet, component inventory (each official component → its native counterpart) and the list of substitutions.
- A hidden "component gallery" window that shows every component in every state in both themes.

## Feature parity checklist
Check each item against the actual T3 Code source and UI, and add anything missing from this list:

**Sidebar**
- Projects with add, remove and reorder
- Threads grouped under projects, with title, status (idle, running, awaiting approval, error), unread/activity indicators and relative timestamps
- Worktree/branch indicator and linked PR status where T3 shows them
- New, rename, archive, delete, fork and search/filter threads
- Collapsible, resizable and fully keyboard navigable
- T3 Connect remote environments/devices, shown the way the official app shows them

**Thread view**
- Streaming assistant output with Markdown (code blocks, tables, lists, links)
- Tool calls, commands and file edits shown as collapsible cards
- Inline diffs (unified and split) and a changes panel
- Approval prompts and pending user-input requests
- Plan mode/plan display, if T3 has them
- Interrupt, steer and the message queue (queue, edit, reorder, cancel)
- Composer with model/provider picker, runtime and permission modes, attachments (drag-drop and paste), slash commands and @-mentions if supported, and multi-line editing
- Token/usage/context indicators if shown

**Other surfaces**
- Integrated terminal panel(s) per thread/worktree
- Git actions (branch, commit, push, create PR, worktrees)
- Settings: providers, models, keybindings, appearance, connection
- Command palette and every T3 Code keyboard shortcut, with the same defaults
- Notifications when a thread finishes or needs approval, plus a dock badge

**T3 Connect**
- Sign in/pair exactly as the official app does
- List and connect to remote environments; drive remote threads with full parity
- Reconnect with backoff and resume event streams without duplicating or losing events; show connection status the way T3 Code does
- Store credentials in the Keychain only

## Performance and battery targets (hard requirements, measured on Apple Silicon)
| Metric | Target |
|---|---|
| Cold launch to interactive sidebar | < 300 ms |
| Idle CPU, window visible, no active turns | ~0% |
| Idle wakeups, app process | < 1/sec average |
| CPU while streaming one turn | < 5% of one core |
| Activity Monitor "Energy Impact", idle | ~0 |
| Activity Monitor "Energy Impact", streaming | Under 1/5 of the official app's |
| Discrete GPU | Never activated (`NSSupportsAutomaticGraphicsSwitching = YES`) |
| RAM, fresh launch | < 80 MB (app process) |
| RAM, 50 threads + one 2,000-message thread open | < 200 MB (app process) |
| Scrolling a 2,000-message thread | Steady 120 fps, no frame > 16 ms |
| Keypress to glyph on screen in the composer | < 16 ms |
| App bundle size | < 25 MB (excluding the server runtime and bundled fonts) |

Also measure the official app on the same machine and workload, and record both side by side in `docs/benchmarks.md`, including the server process's CPU and wakeups.

## Required performance and battery techniques
- **Zero work when idle:** no polling, no repeating timers, no idle animations, no frame loops. Everything is event-driven from server push events and FSEvents. The display link runs only while something is actually changing on screen.
- **Batch streaming updates:** buffer incoming deltas and apply them at most once per frame. On battery or in Low Power Mode, apply them at most ~30 times a second.
- **Incremental Markdown:** parse and lay out only the tail that's streaming, and cache layout for finished messages.
- **Virtualize everything:** timeline, sidebar and diffs recycle views, and off-screen content is never laid out. Large tool outputs and diffs follow T3 Code's collapsed/expanded defaults and are laid out lazily.
- **Lazy syntax highlighting:** only visible code blocks, off the main thread, cached.
- **Stay off the main thread:** JSON decoding, diffing and highlighting run on background actors. The main thread only applies prepared view models.
- **Cheap rendering:** layer-backed views with `layerContentsRedrawPolicy = .onSetNeedsDisplay`, opaque layers wherever possible, invalidating only the regions that changed. No live large blurs, no offscreen-rendered shadows (set `shadowPath`), no full-window redraws.
- **Bounded memory:** keep a windowed message cache per thread and page in older messages on demand. Release view state for inactive threads. Downsample attachment thumbnails.
- **OS cooperation:** let App Nap kick in when the window is hidden and no turn is running. Use `.utility`/`.background` QoS for non-UI work, and set timer tolerances (≥10%) on any timer that must exist. Respond to Low Power Mode and thermal state.
- **Server process:** start the server lazily, give it a low QoS when idle, shut it down cleanly on quit, and measure its idle wakeups too.
- **Performance HUD:** a hidden toggleable overlay showing CPU, RAM, frame time, wakeups/sec and events/sec.

## Architecture
```
App (AppKit lifecycle)
├── ConnectionLayer   – WebSocket/RPC client, T3 Connect auth, reconnect/resume, typed messages from docs/protocol.md
├── Store             – single source of truth (actor), normalized projects/threads/messages/approvals; emits fine-grained diffs
├── ServerManager     – spawns, monitors and restarts the local headless T3 server, or targets remote/Connect
├── DesignSystem      – generated tokens, fonts, icons, custom components, component gallery
├── Features/
│   ├── Sidebar
│   ├── Timeline      – virtualized, incremental Markdown, tool/diff cards
│   ├── Composer
│   ├── Diff
│   ├── Terminal
│   ├── CommandPalette
│   └── Settings
└── Shared/           – Markdown renderer, syntax highlighter, keybinding system
```
Keep the protocol model types in a separate Swift package, tested against recorded real server transcripts.

## Milestones (demo each one before starting the next)
1. **Research:** `docs/protocol.md`, `docs/parity-checklist.md` (each feature with a ✅/⏳ column), reference screenshots in `design/reference/`, plus a baseline of the official app's performance and energy in `docs/benchmarks.md`.
2. **Design system:** token extraction script, fonts, icons, every core component, and the component gallery matching reference screenshots in both themes. I sign off visually before feature work starts.
3. **Skeleton:** app starts or connects to the server, and the sidebar shows real projects and threads.
4. **Read-only thread view:** virtualized timeline with real history, tool cards and diffs.
5. **Interactive:** composer, streaming, interrupt, approvals, queue and model picker.
6. **T3 Connect:** pairing, remote environments, reconnect/resume.
7. **The rest:** terminal, git/PR actions, command palette, keybindings, settings, notifications.
8. **Performance and battery pass:** Instruments (Time Profiler, Allocations, Leaks, Core Animation, Energy Log, System Trace for wakeups) until every target is met, with before/after numbers.
9. **Polish and packaging:** full visual fidelity pass against the reference screenshots, signed and notarized DMG, lightweight auto-update (Sparkle), state restoration.

## Testing
- Unit tests for protocol encoding/decoding using recorded transcripts, and for the store's reducers.
- Integration test against a real headless server: create a project, start a thread, stream a turn, approve, interrupt.
- Cross-compatibility test with official T3 Code in both directions.
- **Visual fidelity tests:** automated snapshot tests that render each screen/state at the reference window size and compare it pixel by pixel against `design/reference/`. Fail above a small threshold, except for documented substitutions. Generate an HTML report showing reference / ours / diff overlay for each screen.
- Perf regression suite (XCTest `measure`): launch time, scrolling and streaming throughput on a synthetic 2,000-message thread, failing on regression.
- 8-hour soak test with periodic turns: memory stays flat, no leaks, idle wakeups stay under target.
- Battery test: one hour of a scripted typical session on battery, with energy compared against the official app.

## Deliverables
- Project that builds with `xcodebuild` from a clean checkout
- `docs/protocol.md`, `parity-checklist.md`, `design.md`, `benchmarks.md`, `architecture.md`
- `scripts/extract-tokens` and `design/reference/`
- README covering build, run, local/remote server, T3 Connect setup and known gaps

## Non-goals
- Changing T3's server or protocol
- Visual redesigns or "improvements" over T3 Code's look
- Windows/Linux support
- New features beyond the official app (put ideas in `docs/ideas.md`)
