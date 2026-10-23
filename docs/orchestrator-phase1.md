# Orchestrator phase 1: build brief

Goal: In the Redesign theme, "Experimental Orchestrator features" turns on the Orchestrator, the master of every thread on its machine. You talk to it in an iMessage-style chat. It sees and prompts every thread, including the ones you start yourself, picks models from a list you control in Settings, and pins itself as a live 3D bot at the top of the sidebar. Official T3 Code still sees only normal threads.

## Read first

1. `AGENTS.md` and `PROGRESS.md`. Take the open task "Orchestrator phase 1" in `PROGRESS.md` before you start.
2. `docs/orchestrator.md`, the spec. Where it describes more than this brief, this brief sets the phase 1 scope.
3. `docs/decisions.md`, the 2026-10-23 entries.
4. T3's source at `~/CandyWrapper-research/t3code`, at the tag in `T3_VERSION`:
   - `packages/contracts/src/orchestratorMcp.ts`. Thread tools at :312, `senderThreadId` at :438, a parent waking on its child at :222, no parent approval authority at :228, and `ScheduledTask`.
   - `packages/contracts/src/orchestrationV2.ts:109` for `parentThreadId`.
5. CandyWrapper code to build on:
   - `Features/Thread/ThreadPanelView.swift:1528-1600`, the composer row.
   - `Features/Thread/DitherWaitingView.swift`.
   - `Features/Composer/DitherDeviceRowView.swift`.
   - `App/Sources/GitController.swift:340-390`, Run on and machines.
   - `Features/Settings/AppearanceSettingsView.swift`.
   - `DesignSystem/Theme/ThemeRuntime.swift`, for `isDither`.
   - The Redesign cost pill's subagent cost math.

## Build

1. Add the toggle "Experimental Orchestrator features" under the theme picker. Show it only while Redesign is the theme, and leave it off by default. When it's off, create no views and hold no state.
2. Add an Orchestrator tab to Settings, shown only while the toggle is on. Follow "The Orchestrator settings tab" in the spec. It holds the prompt editor with Reset, the machine, the worker limit (default 4), the Models list with the four default rows, the notebook, the "while closed" check interval (default 30 minutes, can be off) and the 10-minute "ask first" window. Store all of it in CandyWrapper's settings, never in T3's `settings.json`.
3. Make each Orchestrator an ordinary T3 thread on the chosen machine, one per machine. Fill the prompt's placeholders (name, machine, projects, bots, models, crewLimit) and send it as the first message, drawn as a collapsed "Brief" card. Changes to the prompt or the Models list go out as an "Updated brief" with the next message.
4. Make it the master of every thread. Follow "Every thread is under the Orchestrator" in the spec: it may prompt any thread, asks first when you wrote in the last 10 minutes, never prompts a thread marked Hands off, and queues instead of interrupting. Add "Hands off" to the thread menu.
5. Wire up the events. Its own children wake it through T3. While CandyWrapper is open, send the Orchestrator one short line when any other thread finishes a turn, fails or asks for something. Batch events that land within 30 seconds into one message. While CandyWrapper is closed, a T3 scheduled task wakes it on the set interval to check every thread. CandyWrapper turns that schedule off when it opens.
6. Pin the Orchestrator row at the top of the Redesign sidebar, with its bot, its machine and a needs-you count. Threads are never drawn as bots. Every thread row keeps T3's own look, icons and status, exactly as with the toggle off. Only the Orchestrator, and the standing bots in phase 2, get bot faces.
7. Build the Orchestrator pane. The chat follows "The chat looks like iMessage" in the spec. The Overview tab shows the top 5 needs-you items and a live card per thread, built from server events only. Skip the Digest tab.
8. Take `orchestrator-plan` and `orchestrator-memory` fenced blocks out of replies. A plan becomes a checklist with each step linked to its thread. Memory goes to the notebook with a "Saved to memory" chip and Undo. The official app sees plain text.
9. Show every thread's approvals and questions in a "Needs you" card, using T3's own Allow and Deny path. The Orchestrator never approves.
10. Draw the Orchestrator's bot, and the bot drawing for phase 2's standing bots, as "The bots" section says: 3D solids in one flat colour, printed capsule eyes, 14 shapes, 11 colours, and spring head turns that follow the pointer. Clamp the eyes off the edge, with turn limits precomputed per shape. Use Core Animation layers and respect Reduce Motion.

Not in phase 1: standing bots like OpSec, bot schedules, the Digest tab, and showing several machines' Orchestrators together.

## Rules

- Stay wire compatible. No new wire messages, no server changes and no unknown settings keys. Ask the user before anything that risks it.
- Idle costs zero. Nothing ticks or polls while idle. Animate only while state changes, and hidden views hold nothing. The event relay reacts to server pushes and never polls.
- The default themes don't change. Every `*FidelityTests` suite passes untouched.
- Work only against the sandbox. Use `claude-haiku-5-5` with tiny prompts, at most about 10 real turns, and set the sandbox Orchestrator's model rows to Haiku while testing. Never touch `~/.t3` or the live server.
- Take the Models list from the live catalog. `gpt-6.1-sol` and `claude-opus-5-5` must be offered, and nothing is hardcoded.
- Mark shortcuts with `// ponytail: <ceiling>, <upgrade trigger>`.
- Commit each piece as it works, as `feat(orchestrator): ...`. Rebase on `origin/main` and push to `main`. No AI attribution.
- Do not start other agents.

## Done when

1. `scripts/test` passes in full. That includes a new test that sweeps every bot shape through 315 yaw and pitch poses and fails if an eye comes within the margin, and tests for the event batching and the 10-minute ask-first rule.
2. `scripts/perf-review` against the last saved run shows no idle regression with the toggle on and the Orchestrator idle.
3. On screen against the sandbox, with the screen lock taken:
   1. Turn on the toggle and add a model row.
   2. Start the Orchestrator.
   3. Start a thread yourself and let it finish. Check that the Orchestrator hears about it and prompts it.
   4. Give the Orchestrator a two-step goal and watch it start a thread, prompt it twice and archive it.
   5. Mark a thread Hands off and check that the Orchestrator leaves it alone.
   6. Check that an approval shows in Needs you.
   7. Take a screenshot of each step.

## Report

End with these four parts:

- STATUS.
- CHANGED, the files.
- VERIFIED, the commands, their results and the screenshot paths.
- OPEN, anything unresolved and what phase 2 needs.
