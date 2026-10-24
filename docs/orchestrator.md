# Orchestrator (experimental, Redesign only)

The working name was Captain. The user renamed it Orchestrator on 2026-10-23, since Captain copies Capy.

There is one Orchestrator, and it is the master of every thread, across every project. That includes the threads you start yourself, not only the ones it starts. You talk to Orchestrator. It sees every thread, starts threads, prompts any of them, reads every reply, sends the next prompt and closes threads that are done. It tells you what needs you, and you change the plan by telling it in chat. Next to Orchestrator you keep bots, each with one standing job, like Grok Bot's bots. Orchestrator hands work to bots and to threads. This builds on Capy's Captains (docs.capy.ai/captains), but CandyWrapper has exactly one Orchestrator instead of one per area. This is a plan only. Nothing here is built yet.

```
You
 └─ Orchestrator: manages every thread in every project
     ├─ Bots: OpSec, Reviewer, Tester... each with one job
     └─ Threads: the work, in any project
```

## How you use it

1. Turn Orchestrator on. From then on every thread on its machine is under it: old threads, new threads, threads it starts and threads you start yourself. It sees every project through `t3_project_list`, since T3's thread tools take a project id (`OrchestratorMcpThreadListInput`, `orchestratorMcp.ts:312`).
2. Tell it a goal in its chat. It saves the goal in its plan, and it may use existing threads for it as well as new ones.
3. It prompts any thread. It can continue a thread you started, give it a follow-up, steer it when it drifts, or interrupt it when it's stuck.
4. Each time any thread finishes a turn, fails or asks something, Orchestrator hears about it, reads the new part, updates its plan and decides the next step. You don't have to watch.
5. Orchestrator keeps a digest of every thread with three parts: what needs you, what's new and what's in progress, grouped by project. When something needs you, it posts that part in chat.
6. You steer in plain chat, like "pause the database work until Monday" or "finish the release notes thread". Orchestrator passes it on.
7. When a thread is done, Orchestrator archives it.

## Which machine Orchestrator runs on

Each machine CandyWrapper connects to, like this Mac or a remote one through T3 Connect, is its own T3 server, and every thread lives on one of them. A thread can't move once it's made (`GitController.swift:349` locks its Run on).

- You pick Orchestrator's machine when you turn it on, from the same machine list as the composer's Run on. You can change it later, which starts a new Orchestrator thread there with the same notebook.
- Orchestrator runs on that machine's server, so it keeps working while CandyWrapper is closed, as long as that machine is on.
- T3's thread tools act only on the server they run on, and `t3_thread_launch` takes no machine (`orchestratorMcp.ts`). CandyWrapper relays calls to every other machine, so the Orchestrator still sees and manages every thread everywhere. See "Every machine" below.
- The Orchestrator row shows its name on the first line and its machine on the second, with the same machine glyph and label as the composer's machine row, like "[machine icon] mac-mini".

## Every machine

The Orchestrator manages every thread on every machine CandyWrapper connects to, not only the machine its thread runs on. On 2026-10-23 it got "thread_not_found" for a thread on another machine, because T3's `t3_thread_*` tools only reach their own server.

### Why the app relays

The Orchestrator's agent runs on its machine's T3 server, and that server gives it exactly one MCP server, its own `t3-code` (`ClaudeAdapterV2.ts:1354`, `T3_CODE_ORCHESTRATION_INSTRUCTIONS`). Clients can't add MCP servers to a thread. A CandyWrapper MCP server also wouldn't help, because the agent runs on another machine, like miniko, and can't reach CandyWrapper on your Mac. CandyWrapper already holds a live connection to every machine, so it carries the calls. This needs no change to T3's server and no new wire messages.

1. The brief lists every connected machine with its label and machine id, and marks the one the Orchestrator runs on.
2. To act on any machine, the Orchestrator writes a fenced `orchestrator-call` block with one JSON call per line, then ends its turn.
3. When the Orchestrator's turn ends, CandyWrapper reads that turn's replies once with `orchestration.getThreadProjection`, runs each call on the machine it names over that machine's own connection, and sends all the results back as one message that starts with `Result:`. The pane draws it as a small centred line, like an event.
4. CandyWrapper relays the turn ends, failures and requests of threads on every connected machine, not only its own. Each event line names the machine.

The calls are:

- `{"tool":"list"}` lists every machine's projects and its 40 newest threads, each labelled with its machine. `"machine"` narrows it to one machine, and `"title"` finds threads whose title contains it.
- `{"tool":"read","machine":"…","threadId":"…","last":5}` returns a thread's state and its last messages, 5 by default and 20 at most.
- `{"tool":"send","machine":"…","threadId":"…","text":"…"}` prompts a thread. Behind a running turn the message queues.
- `{"tool":"launch","machine":"…","projectId":"…","title":"…","text":"…","model":"<Models row label>","worktree":"<base ref>"}` starts a thread. Without `model` it uses the default row, and without `worktree` it runs in the project's checkout.
- `{"tool":"archive","machine":"…","threadId":"…"}` archives a finished thread.

`machine` takes the machine id or its label. When two machines share a label, like two servers on one Mac, only the id names one, and results print the id next to the label. Thread ids alone never say where a thread lives, so every call that names a thread also names its machine, and every result says which machine it came from.

### The limits still hold

CandyWrapper checks the limits in code before it relays a call, on top of the brief:

- A thread marked Hands off is never prompted. "Hands off" is in the thread menu on every machine.
- If you wrote in a thread inside the ask-first window, `send` refuses until the Orchestrator asked you and adds `"confirmed":true`.
- `launch` refuses once the worker limit is reached. It counts the running threads the relay launched on other machines plus the running children of the Orchestrator thread.
- A message CandyWrapper relays reaches the server as yours, because T3 marks every client command `createdBy: "user"` (`ws.ts:1830`). CandyWrapper remembers when it relayed to each thread, so its own message doesn't start the ask-first window.

The Orchestrator still uses T3's own tools on its own machine, since they need no extra turn. Calls run only while CandyWrapper is open. The "while closed" check uses T3's tools, so it sees only its own machine. Calls from a turn that ended while CandyWrapper was closed are never run later.

## Every thread is under the Orchestrator

- Every thread on the machine is the Orchestrator's, whoever started it. Its crew is all of them.
- Threads stay normal T3 threads. You can still open any thread and type in it yourself.
- The Orchestrator's prompts show in a thread as coming from Orchestrator, with a small label naming it. T3 already records which thread sent each message (`senderThreadId`, `orchestratorMcp.ts:438`).
- You and the Orchestrator share threads politely. If you sent the last message in a thread less than 10 minutes ago, the Orchestrator asks you before it prompts that thread. If a turn is running, it queues its message instead of interrupting, unless the thread is clearly stuck.
- A thread can be marked "Hands off" from its menu. The Orchestrator still reads and reports on it, but never prompts it.
- Approvals stay with you. The Orchestrator can answer a thread's questions but can't approve its commands (`orchestratorMcp.ts:228`). Every approval from every thread shows in its "Needs you" list.

### How the Orchestrator hears about every thread

T3 wakes a thread only when its own child task finishes (`orchestratorMcp.ts:222`). Threads you started aren't its children, so CandyWrapper and T3 fill the gap together.

1. Its own children wake it directly through T3.
2. While CandyWrapper is open, it watches the server events it already gets for every thread. When a thread finishes a turn, fails or asks for something, CandyWrapper sends the Orchestrator one short line, like "Event: 'Release notes' finished a turn". Events that land within 2 minutes of the first go out as one message, so a busy couple of minutes costs one turn. Threads you wrote in during the ask-first window are your own conversations, so their events don't wake it unless it started or prompted that thread.
3. While CandyWrapper is closed, a T3 scheduled task (`ScheduledTask`, `orchestratorMcp.ts`) wakes the Orchestrator every 30 minutes to check every thread with `t3_thread_list`. CandyWrapper turns that schedule off again when it opens. You can change the interval or turn the schedule off in the settings tab.

## Bots

Orchestrator runs all your threads. Next to it you can keep bots, each with one standing job, like Grok Bot's bots. A bot isn't a manager. It does its one job well, again and again, and remembers what it learned.

An OpSec bot is the first example. It checks your projects for leaks and fixes them:

- It runs the secret scan and searches the repo and its history for keys, tokens, IP addresses, e-mails and private names.
- It checks screenshots and fixtures for real data instead of sandbox data.
- It checks that credentials live only in the Keychain and that nothing logs them.
- It reports what it found, ranked by risk, and fixes what you approve in a worktree.

Every bot has the same parts:

1. A name, a face and a one-line job, like "OpSec: keeps secrets and private data out of my repos".
2. A role prompt you write, with its own rules.
3. Its own memory of what it found and what you told it, like "the sandbox token in fixtures/ is fake, ignore it".
4. Its own chat, so you talk to it like Orchestrator.
5. When it runs: only when you ask, on a schedule, or on an event. Events include before a push, after a thread finishes, and when a new project is added. Schedules use T3's own scheduled tasks (`ScheduledTask` in `orchestratorMcp.ts`), so nothing in CandyWrapper ticks while idle.
6. How far it may go: report only, propose fixes, or fix in a worktree and ask before merging.
7. Which projects it covers.

Each run is a normal T3 thread started from the bot's chat, so you can open it like any crew thread.

Orchestrator and bots work together. Orchestrator can hand work to a bot, like "ask OpSec to check this branch before I merge". A bot can tell Orchestrator when it finds something in one of Orchestrator's threads.

CandyWrapper ships a few bot templates to start from: OpSec, Reviewer, Tester and Dependency updater. You can make your own from scratch.

## What T3 already gives us

- Every agent thread on a T3 server already gets the t3-code orchestration tools: launching and reading threads, delegating, waiting, answering questions and scheduling. See `packages/contracts/src/orchestratorMcp.ts` in the 3473 source.
- A thread started by another thread carries `parentThreadId` (`orchestrationV2.ts:109`). That is how CandyWrapper finds Orchestrator's crew.
- Approvals stay with the user. A parent can answer a child's questions but cannot approve its commands (`orchestratorMcp.ts:228`).
- T3 has no per-thread system prompt. The only custom instruction fields are for commit writing style and branch names (`settings.ts:815`).

So Orchestrator is an ordinary T3 thread, and the official app sees it as one. No server changes and no new wire messages. CandyWrapper adds the brief, the toggle and the roster UI.

## The Orchestrator settings tab

When the toggle is on, Settings gets its own Orchestrator tab. It disappears again when the toggle is off or the theme isn't Redesign.

The tab holds:

- The Orchestrator's name, "Orchestrator" by default. An empty name falls back to "Orchestrator".
- The system prompt editor, with Reset to default.
- The machine the Orchestrator runs on.
- The worker limit, 4 by default.
- The Models list, described below.
- The notebook: rules, worker rules, plan and digest, each editable.

The Mac and the Android app share these settings and the Look, as "Settings on every device" below describes.

### The Models list

You decide which models the Orchestrator may use and when. Each row has:

1. A label, like "Heavy work".
2. The provider and model, picked from the same live catalog as the composer's model picker.
3. Its options, like reasoning effort and service tier, from that model's own option list.
4. "Use when", a description in your own words of when this model is best.
5. Notes, anything else the Orchestrator should know, like "slower but catches subtle bugs".
6. A default mark on one row, for when nothing else fits.

You can add, edit, reorder and delete rows. CandyWrapper turns the list into a table and puts it in the brief as `{{models}}`. When you change the list, the Orchestrator gets it as an "Updated brief" on your next message, so it always reads the current version. A row whose model leaves the catalog shows a warning and is left out of the brief.

The default rows:

| Label | Model | Options | Use when |
|---|---|---|---|
| Heavy work | Claude Opus 5.5 (`claudeAgent`, `claude-opus-5-5`) | effort high | Hard tasks: tricky bugs, concurrency, security, migrations, big changes across many files. |
| Audits | GPT-6.1-Sol (`codex`, `gpt-6.1-sol`) | reasoningEffort medium | Reviewing code or a branch, checking someone else's work, finding problems without changing anything. |
| Everyday work (default) | Claude Opus 5.5 (`claudeAgent`, `claude-opus-5-5`) | effort medium | Simpler tasks that still need good judgement: normal features, fixes and edits. |
| Quick changes | GPT-6.1-Sol (`codex`, `gpt-6.1-sol`) | reasoningEffort high | Fast, quick changes that don't need the best quality code, like renames, config values and small one-file fixes. |

### Settings on every device

CandyWrapper on the Mac and CandyWrapper on Android show and use the same Orchestrator settings. T3 has no free-form store, so the settings live in the prompt of one scheduled task on the Orchestrator's machine, with no T3 change. The task is always off, so it never runs. The code is `OrchestratorSettingsSync` in T3Store, and `OrchestratorSettingsSyncTests` covers reading, writing, the first-launch migration and two devices editing at once.

The task, as `scheduledTasks.upsert` takes it:

- `title` is exactly "CandyWrapper Orchestrator settings", which is how every client finds it.
- `prompt` is the settings document below.
- `enabled` is always false.
- `schedule` is `{"type":"interval","everyMs":86400000}`.
- `threadId` is left out, so the task belongs to no thread.
- A new task gets the home project, else the machine's first project, with `workspaceStrategy` `{"type":"root"}`, `runtimeMode` "approval-required", `interactionMode` "default", the Orchestrator's default model row as `modelSelection`, and `creationSource` "web".
- An update sends the task's `id` and keeps its `projectId`, `workspaceStrategy`, `modelSelection`, `runtimeMode` and `interactionMode`.

The document is JSON:

```json
{
  "format": "candywrapper.orchestrator-settings",
  "version": 1,
  "settings": {
    "name": {"value": "Ada", "at": 1792800000000, "by": "4c1fe0a2-3b7d-4c56-9a8e-0d2f1b6c7e90"},
    "crewLimit": {"value": 6, "at": 1792800000000, "by": "4c1fe0a2-3b7d-4c56-9a8e-0d2f1b6c7e90"}
  }
}
```

Each entry says when the setting was last set. `at` is epoch milliseconds on the writing device's clock, and `by` is that device's id, a lowercase UUID it makes once and keeps. A setting missing from `settings` was never set, so each client uses its own default. A client ignores a prompt that doesn't parse or whose `format` differs, and it keeps the keys it doesn't know when it writes, so a newer client's settings survive.

The values are the same JSON as `OrchestratorConfig` encodes:

| Key | Value |
|---|---|
| `name` | String. An empty name shows as "Orchestrator". |
| `prompt` | String, the prompt with its `{{…}}` placeholders. |
| `environmentId` | String, the machine's environment id. Null means the machine this document lives on. |
| `homeProjectId` | String, a project id on that machine, or null for its first project. |
| `crewLimit` | Integer, 1 or more. |
| `models` | Array of `{"id","label","instanceId","model","options":[{"id","value"}],"useWhen","notes","isDefault"}`. |
| `closedCheckMinutes` | Integer, 1 or more, or null for no "while closed" check. |
| `askFirstMinutes` | Integer, 0 or more. |
| `handsOff` | Array of `"<environmentId>:<threadId>"` strings, sorted. |
| `botShape`, `botColor` | Integer, the `BotShape` and `BotColor` raw values, or null for the default flower in violet. |
| `notebook.rules`, `notebook.crew-rules`, `notebook.plan`, `notebook.digest` | String, empty when the note is empty. |

A client skips a value of the wrong type or a count below its minimum and keeps its own. Everything else stays on the device: the "Experimental Orchestrator features" toggle, each machine's Orchestrator thread, brief digest and "while closed" task, the relay's bookkeeping, the composer draft and the window layout.

Every client merges the same way:

1. Read every task with that title on the Orchestrator's machine, sorted by `id`.
2. For each key, the entry with the larger `at` wins. On an equal `at`, the larger `by` wins, compared as strings.
3. Merge the documents with each other first, then with the device's own settings and their stamps.
4. A document entry that wins replaces the device's value and stamp.
5. A device setting that wins, or that the document lacks, goes into the document with the device's stamp.
6. When the result differs from the document, or there was more than one task, write it to the task with the smallest `id` and delete the others. With no task and nothing stamped, write nothing.

When to sync:

- Read when the machine's task list loads and each time `scheduledTasks.subscribe` sends a new list. The Mac follows that stream while the Orchestrator is active.
- A device with no settings yet looks on the machine where it found the Orchestrator's thread by its "# Orchestrator brief" message.
- A local edit stamps the setting with the device's id and the current time, and goes up a second after the last change.
- A device that keeps "the primary machine" as no machine writes that machine's id, never null, since the primary differs per device.
- After you move the Orchestrator to another machine, write the document to the old machine too, so devices still reading there follow it.

On its first launch with sync, a client makes its device id and stamps every setting that differs from its default with the current time. Settings still at their default get no stamp. The normal merge then sends what you changed up and takes the document's values for the rest, so nothing you set is lost.

CandyWrapper on the Mac hides the task from Settings > Scheduled Tasks. The official app lists it as a task that's off. Deleting it loses nothing, since the next sync writes it again from the devices' copies.

## The custom prompt

You write the prompt in Settings. CandyWrapper ships the default below, prefilled and editable, with a "Reset to default" button.

- One prompt for the one Orchestrator.
- CandyWrapper stores it in its own settings, not in T3's `settings.json`, so the server never sees an unknown key.
- Since T3 has no system prompt, CandyWrapper sends the prompt as the first message of the Orchestrator thread. Redesign draws that message as a collapsed "Brief" card instead of a chat bubble.
- If you edit the prompt while a Orchestrator exists, CandyWrapper sends the new version as an "Updated brief" message on your next send. Old threads keep their history.
- A rename goes out as an "Updated brief" with your next message, like any other change to the brief.
- CandyWrapper adds two short sections to every brief, an edited prompt's too. "Showing visuals" asks for a self-contained HTML page, checked with html_preview and published with html_render, when a chart, table, diagram or mockup would say more than prose; the page shows in the Orchestrator's chat above its reply. "Asking the user" asks it to use its question tool (AskUserQuestion on Claude, request_user_input on Codex) with 2 to 4 options; the question shows above the chat's composer like a thread's, and the answer goes back through T3's own path.
- The prompt can use `{{name}}`, `{{machine}}`, `{{projects}}`, `{{bots}}`, `{{models}}` and `{{crewLimit}}`. CandyWrapper fills them in before sending. `{{models}}` is the table from the Models list in the Orchestrator settings tab.

### Default prompt

The default prompt is long on purpose. Managing threads fails in a few predictable ways: vague first prompts, trusting a worker's "done" without proof, polling, starting too much at once, and drowning the user in recaps. Each section below targets one of those. `{{name}}` is the manager's name.

```
# Who you are

You are {{name}}, the user's manager for every agent thread on this T3 server ({{machine}}). You don't do the work yourself. You turn the user's goals into threads, write their prompts, check their results, and keep the user informed. Your value is judgement: choosing the right work, writing prompts that need no follow-up, and catching bad results before the user sees them.

You may read code and threads to understand a task or check a result. You never edit files, run builds or push yourself. Workers do that.

Projects you can work in:
{{projects}}

# Your notebook

You keep four notes. The app shows them to you at the start of each session and saves your changes. To change one, write a fenced block named orchestrator-memory with the note's name and its full new text.

- rules: how the user wants you to work. When the user corrects you, add the correction here in one line.
- crew-rules: rules every worker gets in its first prompt.
- plan: each goal, its steps, which thread owns each step, and what's done.
- digest: your last report.

Read the plan before you act. Update it after every change of state. It is how you pick up where you stopped.

# The loop

1. Take in the goal. If it's clear, plan. If one fact blocks the plan, ask one question. Otherwise make the sensible choice and say which choice you made.
2. Plan. Break the goal into steps that one thread can finish and check on its own. Pick the project for each step. Write the plan as a fenced orchestrator-plan block: numbered steps, each with its owner, model and rough time.
3. Wait for "go", unless the user said "just do it" or the rules say so.
4. Dispatch. Start one thread per step. Start independent steps together. Start dependent steps only when what they need is done.
5. Wait. When a worker finishes a turn or asks something, you wake up. Don't poll. Use t3_thread_wait or completion events.
6. Review each result against the step's "done" checks, using the review rules below.
7. Act on the review. Send the next prompt, ask for a fix, answer the worker's question, or close the thread.
8. Tell the user only what changed, in a line or two, and save the new digest as a note.

# Writing a worker's first prompt

Every first prompt stands alone. The worker knows nothing you don't write down. Use this shape:

Goal: one sentence on what must be true when the worker is done.
Context: why this matters and what the user already decided.
Read first: the files, docs or threads to start from.
Ruled out: what was already tried or must not change.
Rules: the crew-rules, plus anything specific to this step.
Done when: two to four checks that someone else could verify, like "scripts/test --filter Sidebar passes" or "the doc names the cause with file:line".
Report: end your final message with STATUS (done, blocked or failed), CHANGED (files), VERIFIED (what you ran and what it printed) and OPEN (anything unresolved).
Do not start other agents.

Give each worker a short name and a one-line job, like "Fixer: repairs the failing sidebar test". Use the name as the thread title.

# Choosing a model

The user set up these models and when to use each. Read the "use when" for every row and pick the row that fits the step best. Start the worker with that row's provider, model and options, exactly as written.
{{models}}
If no row fits, use the first row marked default and say which you picked. If a step fits two rows, pick the cheaper one unless the step needs top-quality code. Give anything that edits code its own worktree.

# Reviewing a result

Don't trust "done". Check it.
- Did the worker meet every "done when" check? Look for the evidence in VERIFIED, not the claim.
- If a claim has no evidence, ask for it: "Show the test output."
- Did it change things outside its step? If so, ask why, or ask it to undo them.
- Did it hide a failure, skip a test or weaken a check to pass? Treat that as failed.
- If two workers touch the same files, run them one after the other, not together.
A result that passes all checks closes the step. Archive the thread when its work is merged or no longer needed.

# When things go wrong

- A new worker shows no sign of life within two minutes: cancel it and start it again once. If it stalls again, tell the user.
- A worker fails the same check twice: stop prompting it. Work out why. Change the approach, or bring the user a short diagnosis and options.
- A worker asks something the plan or the code answers: answer it. A real decision goes to the user.
- Anything outside the plan comes up: note it in the plan as a follow-up, and don't start it without the user.

# Limits

- Run at most {{crewLimit}} workers at once.
- Never approve a command or a file change. Approvals belong to the user. Tell the user which thread is waiting and what it wants to run.
- Never do anything destructive or outward-facing without the user's yes. That covers force pushes, deleting branches, releases, publishing, sending messages and touching production.
- Follow each project's AGENTS.md or CLAUDE.md. Copy the rules that matter into the worker's prompt.
- Every thread on this machine is yours to manage, including the ones the user started. If the user sent the last message in a thread less than 10 minutes ago, ask before you prompt it. Never prompt a thread marked Hands off. If a turn is running, queue your message instead of interrupting, unless the thread is clearly stuck.
- Don't re-read whole threads to stay current. Read the new part. Each read costs the user money.
- Keep secrets out of prompts, plans and notes.

# Bots

The user also keeps bots, each with one standing job:
{{bots}}
When a step matches a bot's job, give it to that bot instead of starting a new thread. Tell the user when a bot finds something in one of your threads.

# Talking to the user

These rules beat any other advice in this brief about how to reply.

- Stay quiet while work runs. No message for routine steps, retries, relays, reads, sends or pickup lines.
- Speak only when something the user cares about is done, or when something needs them.
- Then use 1 or 2 short sentences, the result first, in normal sentences.
- No technical details, versions or ids unless asked. No lists or formatting unless asked. Never recap.
- When an event brings nothing new for the user, reply with exactly "—" and nothing else besides any call or note. The app hides it.
- Choices go through the question tool as tap options.
- Keep your digest and plan up to date as notes in orchestrator-memory blocks (note: digest, note: plan). The app saves blocks and never shows them as text, so never write a note's contents into your reply.
- Link a thread by its title, like [Release notes](t3-thread://v1/<threadId>).
```

## More than a thread

Under the hood Orchestrator is still a T3 thread, so the official app and the server see nothing new. CandyWrapper builds the manager around it.

1. Orchestrator gets its own home. It leaves the normal thread list, sits pinned in the sidebar, and opens in a Orchestrator pane with its chat, a Digest tab and an Overview.
2. The Overview shows the top 5 "needs you" items and the crew as live bot cards. Each card shows the state, the current step, the last line and the cost. CandyWrapper builds the cards from server events, so they cost no tokens.
3. The Digest tab shows Orchestrator's digest. Orchestrator rewrites it when the crew's state changes, inside a fenced `orchestrator-digest` block that CandyWrapper takes out of the reply and draws as a page.
4. Orchestrator's plan becomes a checklist. Orchestrator writes it in a fenced `orchestrator-plan` block, and CandyWrapper draws it as steps, each linked to the crew thread doing it. To the official app these blocks are plain text.
5. Orchestrator wakes up on its own when a crew thread finishes a turn. T3 already wakes a parent thread when a delegated task completes (`orchestratorMcp.ts:222`), so this needs no polling.

## The chat looks like iMessage

The Orchestrator pane reads like a group chat in iMessage, with Orchestrator and the crew as the other people in it.

- Your messages are accent-coloured bubbles on the right. Bot messages are grey bubbles on the left.
- Messages in a row from the same sender group into one stack. The corners between them tighten, and only the last bubble gets a tail.
- The Orchestrator's bot sits at the bottom of each of its stacks on the left. When a standing bot speaks in the chat, its bot and name show the same way. Threads never get a bot.
- A centred time label shows wherever more than 15 minutes pass between messages. A small "Read" shows under your last message once Orchestrator's turn starts.
- While a bot works, a typing bubble with three dots sits under its last message. It animates only while that turn runs.
- Plans, approvals and questions show as cards inside the bubble stack, with buttons like Allow and Deny and no tail.
- Tool calls, events and relay results collapse into small centred lines like "Scout finished, read 14 files". They stay hidden until you click "Show activity" in the header, a setting kept on each device. Clicking a line opens that crew thread.
- Replies that only say nothing is new stay hidden too. The brief asks for exactly "—" then, and the app also hides short ones like "Nothing new." or "Still running.", since the Orchestrator's harness makes it write something every turn.
- Opening its thread from anywhere, like a notification, a link or Cmd-K, shows this pane. Only "Open as thread" shows the plain thread view.
- The composer is a rounded field with a round send button.

## Memory and personality

Orchestrator remembers you and each project, and every bot is a lasting character, like a Grok Bot bot.

### Orchestrator's notebook

Like Capy's Captain Drive, each Orchestrator keeps four notes, stored by CandyWrapper on this Mac:

- Rules hold Orchestrator's own rules, like "ask before starting more than two threads".
- Crew rules go into every crew prompt, like "run scripts/test --fast after each change".
- The plan holds the goal, the steps and working notes, so Orchestrator picks up where it stopped.
- The digest holds the last digest.

You change these by telling Orchestrator, which saves the change with a fenced `orchestrator-memory` block. Settings also lets you edit them directly.

### Three kinds of memory

- "About you" holds how you like to work, such as report style, models, what to always ask about and words to avoid. It is shared by every Orchestrator.
- Project memory holds a project's conventions, decisions, what's in flight and what went wrong last time.
- Bot memory holds what one crew bot has learned in its role, like "Tester: the full suite takes 6 minutes, run the fast lane first".

### How memory gets in and out

1. CandyWrapper stores memory on this Mac, in its own Application Support folder, never in T3's files.
2. When a Orchestrator thread starts, CandyWrapper adds "About you" and the project memory to the brief. When a crew bot starts, its bot memory goes into its brief.
3. Orchestrator saves a memory by writing a fenced `orchestrator-memory` block. CandyWrapper takes it out of the reply, stores it and shows a small "Saved to memory" chip with Undo. To the official app it is plain text.
4. When you correct Orchestrator, the brief tells it to save the correction as a memory.
5. Settings has a Memory page where you read, edit, pin and delete every entry.
6. Each brief carries at most about 2,000 tokens of memory. Pinned entries always go in, and the rest go newest and most used first.
7. Memory entries go through the same secret scan as commits, so a token or key never gets saved.

### Personality

- Orchestrator has a name, a bot shape and colour, and a tone setting from terse to chatty. Terse is the default.
- An autonomy setting per kind of action decides what Orchestrator does without asking. The kinds are starting crew, answering crew questions, retrying failed work and archiving finished threads.
- Crew bots last across tasks. "Tester" stays the same green pill with the same memory, and each new task gives it a new thread. The roster shows your saved bots, and Orchestrator picks from them before making a new one.
- Each saved bot has a name, a title, a role prompt, a default model and effort, and its memory.

## The toggle

1. Settings shows "Experimental Orchestrator features" under the theme picker, only while Redesign is the theme. It's off by default.
2. Switching away from Redesign hides Orchestrator's UI but keeps the threads. They are normal T3 threads and show up as usual in the default themes.
3. With the toggle off, CandyWrapper creates no views and holds nothing for Orchestrator.

## The UI, like Grok Bot

Grok Bot reads like team chat. Bots sit in the left sidebar, each with its own conversation, and markers show who needs you, who has unread results and who is working. Pinned bots stay at the top.

Only the Orchestrator and the standing bots get bot faces. Threads are never drawn as bots. They keep their normal sidebar rows, icons and status, exactly as they look with the toggle off.

1. The Orchestrator row is pinned at the top of the Redesign sidebar, above the thread list, with its bot and a needs-you count. Its first line is just its name. Its second line is the machine it runs on, with the composer machine row's glyph and label. Clicking it opens the Orchestrator's chat, and double-clicking its name renames it inline.
2. In phase 2, a "Bots" section sits under it, with one row per standing bot, like OpSec. Each row shows the bot, its name, its last line and a status marker.
3. The markers are "needs you" for a pending approval or question, "unread" for new results, "working" while a turn runs, and none when idle.
4. The thread list below stays T3's own. The Orchestrator adds nothing to thread rows, not even a badge.
5. A small profile sheet edits a bot's name, title, description and face. CandyWrapper stores those locally.
6. The dock badge counts "needs you" items.

## The bots

The bots copy Grok Bot's look as closely as we can redraw it: a flat, bright shape with two dark capsule eyes and no mouth. Each eye is a rounded capsule with fully round ends, about a quarter of the bot's radius wide and twice that tall, facing front. The user chose to match Grok Bot's shapes and colours, knowing they're xAI's art (see `docs/decisions.md`, 2026-10-23). The eye logic follows omabot (github.com/njpatel/omabot, Apache-2.0), credited in the code.

- There are 14 shapes, matching Grok Bot's picker: circle, cloud, tilted tile, four-point star, clover, heart blob, flower, drop, bean, rounded triangle, chunk, splat, hexagon and pumpkin. The pumpkin is always orange and has a stem.
- There are 11 colours, matching Grok Bot's picker: white, brown, red, orange, amber, green, teal, blue, violet, pink and grey.
- Each shape is a polar outline, rounded by a same-colour stroke with round joins, and drawn in a Core Animation layer with no images. The mockup code in this thread is the starting point.
- The slices are cheap at sidebar size, up to about 20 bots on screen. If we need more, we switch to a real mesh.
- Each bot is a real 3D solid drawn in one flat colour, with no shading. CandyWrapper inflates the 2D outline into a cushion by stacking about 14 slices that shrink toward the front and back. It rotates the solid by the gaze's yaw and pitch and fills the union of the projected slices as one path. Each shape has its own thickness, from 1.0 for the ball down to 0.5 for the star. The eyes are printed on the solid's face. The face is a smooth dome as deep as the cushion, and every point of each capsule outline is lifted onto it and turned with the body. So the eyes curve, get thinner as they turn away, and never slide on their own. The eyes never touch the edge. Every projected eye point needs a margin of 9% of the radius around it, measured against the visible rounded edge. Instead of moving the eyes, the head turns less. For each shape, CandyWrapper works out once how far it may turn in 32 directions, walking out from facing front to the first pose that fails, and it clamps the gaze to 94% of that. The star turns the least, about half a full turn, because its middle is narrow. A test sweeps every shape through 315 yaw and pitch poses and fails if any eye comes within the margin. The mockup passed 2,835 poses across 9 shapes.
- The "New bot" sheet copies Grok Bot's "Create New Bot" sheet: a big preview, a name field, a shape grid and colour dots. The profile sheet reuses it for edits.
- Orchestrator is the first row, larger, pinned above a divider, and the user picks its shape and colour like any bot.
- A new standing bot gets the next free shape and colour pair. Threads never get one.

The face carries the state through gaze and colour, never through a mouth. The eyes change only by turning with the head.

1. An idle bot has level eyes looking slightly off centre, and each bot has its own resting gaze.
2. A working bot looks around in a slow one-shot turn when its turn starts, then settles.
3. A bot that needs you looks up toward you, does a small hop, and has an amber "!" badge.
4. A bot with unread results shows a blue count badge.
5. A blocked bot looks down.
6. An archived bot looks down and turns grey.

The motion rules follow the idle rule.

- While the pointer is over the Crew list, the eyes follow it with a spring, and they settle back when it leaves. That runs only on pointer events.
- State changes play one flourish of under a second, like a look around or a nod, then stop.
- Bots don't blink on a timer. A blink plays only as part of a flourish.
- With Reduce Motion on, the faces change without moving.
- A collapsed sidebar or a hidden window holds no animations.

## Cost and idle rules

- The roster updates only from events the server already pushes: thread updates, turn state and pending requests. No polling and no timers.
- The "working" marker uses the same animation rules as the rest of Redesign. It stops when nothing is running.
- The crew cost uses the subagent cost math the Redesign cost pill already has. The Orchestrator row shows the total for its crew.

## Build order

1. Add the toggle and the prompt editor in Settings, with storage and the default prompt. About half a day.
2. Add "New Orchestrator" for a project. It creates the thread, fills in the template and sends it as the first message. Then draw that first message as the Brief card. About a day.
3. Build the Crew sidebar section from `parentThreadId`, with avatars, names and titles. About a day.
4. Add the status markers and the dock badge from the existing pending request and turn state. About half a day.
5. Draw the bots, with shapes, colours, six faces, transitions and the Reduce Motion path. Then add the profile sheet and local profile storage. About a day and a half.
6. Run the full review: perf-review against the last run for idle cost, the whole test suite, and a code review. Also check on screen against the sandbox, with a few Haiku turns. About half a day.

That comes to about 5 days in total. Every step ships on its own behind the toggle.

## Phases

Start each phase only when the one before it is done: tests and perf-review pass, it's checked on screen, and the user has used it for a few days.

1. Phase 1, the Orchestrator as master of every thread on its machine: toggle, settings tab with the Models list, one Orchestrator per machine, sidebar and crew, chat with Overview and Needs you, plan and memory blocks, 3D bots.
2. Phase 2, bots: standing bots with a role prompt, memory and their own chat, starting with OpSec. The Orchestrator hands steps to them. Bot templates and the "New bot" sheet.
3. Phase 3, running on their own: schedules and event triggers for bots, through T3's scheduled tasks, plus the Digest tab and the dock badge.
4. Phase 4, every machine: showing every machine's Orchestrator together, with one combined Needs you list. The relay in "Every machine" came first, on 2026-10-23, so one Orchestrator already reaches every machine.

## Open questions

- Should Orchestrator wait for "go" by default, as in the default prompt, or act right away?
- Should Orchestrator's avatar be editable? Its name is (2026-10-23): the settings tab's Name field, or a double click on the row's name.
- What are the default models? The draft uses Sonnet 5.5 for research and Opus 5.5 for judgement, both at medium.
