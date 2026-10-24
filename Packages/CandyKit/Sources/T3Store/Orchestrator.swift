import Foundation
import T3Protocol

// The Orchestrator (docs/orchestrator.md; phase 1 scope in docs/orchestrator-phase1.md): one ordinary T3 thread per
// machine that manages every other thread there through T3's own thread tools (orchestratorMcp.ts). Everything
// here is CandyWrapper's own and stays on this Mac: the server sees normal threads and normal messages.

/// One row of the Models list: a model from the live catalog and when the Orchestrator should pick it.
public struct OrchestratorModelRow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var instanceId: String
    public var model: String
    public var options: [ProviderOptionSelection]
    public var useWhen: String
    public var notes: String
    public var isDefault: Bool

    public init(id: String = UUID().uuidString.lowercased(), label: String, instanceId: String, model: String,
                options: [ProviderOptionSelection] = [], useWhen: String = "", notes: String = "", isDefault: Bool = false) {
        self.id = id; self.label = label; self.instanceId = instanceId; self.model = model
        self.options = options; self.useWhen = useWhen; self.notes = notes; self.isDefault = isDefault
    }

    public var selection: ModelSelection {
        ModelSelection(instanceId: ProviderInstanceId(rawValue: instanceId), model: model, selections: options)
    }

    /// The spec's four rows (docs/orchestrator.md, "The Models list"). They name catalog ids; a row whose model the
    /// live catalog lacks shows a warning and stays out of the brief.
    public static let defaults: [OrchestratorModelRow] = [
        .init(id: "heavy", label: "Heavy work", instanceId: "claudeAgent", model: "claude-opus-5-5",
              options: [.init(id: "effort", value: .string("high"))],
              useWhen: "Hard tasks: tricky bugs, concurrency, security, migrations, big changes across many files."),
        .init(id: "audits", label: "Audits", instanceId: "codex", model: "gpt-6.1-sol",
              options: [.init(id: "reasoningEffort", value: .string("medium"))],
              useWhen: "Reviewing code or a branch, checking someone else's work, finding problems without changing anything."),
        .init(id: "everyday", label: "Everyday work", instanceId: "claudeAgent", model: "claude-opus-5-5",
              options: [.init(id: "effort", value: .string("medium"))],
              useWhen: "Simpler tasks that still need good judgement: normal features, fixes and edits.", isDefault: true),
        .init(id: "quick", label: "Quick changes", instanceId: "codex", model: "gpt-6.1-sol",
              options: [.init(id: "reasoningEffort", value: .string("high"))],
              useWhen: "Fast, quick changes that don't need the best quality code, like renames, config values and small one-file fixes."),
    ]
}

/// The four notes the Orchestrator keeps (docs/orchestrator.md, "Orchestrator's notebook").
public struct OrchestratorNotebook: Codable, Hashable, Sendable {
    public static let names = ["rules", "crew-rules", "plan", "digest"]
    public var notes: [String: String] = [:]
    public init() {}
    public subscript(name: String) -> String {
        get { notes[name] ?? "" }
        set { notes[name] = newValue.isEmpty ? nil : newValue }
    }
}

/// What CandyWrapper remembers about the Orchestrator on one machine.
public struct OrchestratorMachine: Codable, Hashable, Sendable {
    /// The Orchestrator thread, by the id that machine's server knows.
    public var threadId: String
    /// The brief the thread last got (`OrchestratorBrief.digest`); a different one goes out as "Updated brief".
    public var briefDigest: String
    /// The "while closed" scheduled task on that machine.
    public var scheduledTaskId: String?

    public init(threadId: String, briefDigest: String, scheduledTaskId: String? = nil) {
        self.threadId = threadId; self.briefDigest = briefDigest; self.scheduledTaskId = scheduledTaskId
    }
}

/// The Orchestrator's settings, kept in CandyWrapper's own defaults and never in T3's `settings.json`.
public struct OrchestratorConfig: Codable, Hashable, Sendable {
    /// "Experimental Orchestrator features", Redesign only.
    public var enabled = false
    public var name = "Orchestrator"
    public var prompt = OrchestratorBrief.defaultPrompt
    /// The machine it runs on; nil is the primary machine.
    public var environmentId: String?
    /// The project its thread lives in, by local id; nil is the machine's first project. It still sees every project.
    public var homeProjectId: String?
    public var crewLimit = 4
    public var models = OrchestratorModelRow.defaults
    public var notebook = OrchestratorNotebook()
    /// How often the scheduled task wakes it while CandyWrapper is closed; nil turns the schedule off.
    public var closedCheckMinutes: Int? = 30
    /// How recently you must have written in a thread for it to ask before prompting there.
    public var askFirstMinutes = 10
    /// Scoped thread ids marked Hands off.
    public var handsOff: Set<String> = []
    /// By environment id.
    public var machines: [String: OrchestratorMachine] = [:]
    /// Assistant messages whose memory blocks were saved already, newest last, so a reload saves nothing twice.
    public var savedMemoryMessages: [String] = []
    /// Its bot's shape and colour (`BotShape` and `BotColor` raw values); nil is the default flower in violet.
    public var botShape: Int?
    public var botColor: Int?
    /// When the relay last prompted each thread on any machine, scoped id to epoch ms, for the ask-first rule.
    public var relayedAt: [String: Int64] = [:]
    /// Scoped ids of the threads the relay launched, which count toward the worker limit.
    public var relayWorkers: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, name, prompt, environmentId, homeProjectId, crewLimit, models, notebook, closedCheckMinutes, askFirstMinutes
        case handsOff, machines, savedMemoryMessages, botShape, botColor, relayedAt, relayWorkers
    }

    /// Missing keys keep their defaults, so a newer field never wipes the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrchestratorConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
        environmentId = try c.decodeIfPresent(String.self, forKey: .environmentId)
        homeProjectId = try c.decodeIfPresent(String.self, forKey: .homeProjectId)
        crewLimit = try c.decodeIfPresent(Int.self, forKey: .crewLimit) ?? d.crewLimit
        models = try c.decodeIfPresent([OrchestratorModelRow].self, forKey: .models) ?? d.models
        notebook = try c.decodeIfPresent(OrchestratorNotebook.self, forKey: .notebook) ?? d.notebook
        closedCheckMinutes = c.contains(.closedCheckMinutes) ? try c.decodeIfPresent(Int.self, forKey: .closedCheckMinutes) : d.closedCheckMinutes
        askFirstMinutes = try c.decodeIfPresent(Int.self, forKey: .askFirstMinutes) ?? d.askFirstMinutes
        handsOff = try c.decodeIfPresent(Set<String>.self, forKey: .handsOff) ?? []
        machines = try c.decodeIfPresent([String: OrchestratorMachine].self, forKey: .machines) ?? [:]
        savedMemoryMessages = try c.decodeIfPresent([String].self, forKey: .savedMemoryMessages) ?? []
        botShape = try c.decodeIfPresent(Int.self, forKey: .botShape)
        botColor = try c.decodeIfPresent(Int.self, forKey: .botColor)
        relayedAt = try c.decodeIfPresent([String: Int64].self, forKey: .relayedAt) ?? [:]
        relayWorkers = try c.decodeIfPresent(Set<String>.self, forKey: .relayWorkers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(name, forKey: .name)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(environmentId, forKey: .environmentId)
        try c.encodeIfPresent(homeProjectId, forKey: .homeProjectId)
        try c.encode(crewLimit, forKey: .crewLimit)
        try c.encode(models, forKey: .models)
        try c.encode(notebook, forKey: .notebook)
        try c.encode(closedCheckMinutes, forKey: .closedCheckMinutes)
        try c.encode(askFirstMinutes, forKey: .askFirstMinutes)
        try c.encode(handsOff, forKey: .handsOff)
        try c.encode(machines, forKey: .machines)
        try c.encode(savedMemoryMessages, forKey: .savedMemoryMessages)
        try c.encodeIfPresent(botShape, forKey: .botShape)
        try c.encodeIfPresent(botColor, forKey: .botColor)
        try c.encode(relayedAt, forKey: .relayedAt)
        try c.encode(relayWorkers, forKey: .relayWorkers)
    }

    static let defaultName = "Orchestrator"
    /// The name it goes by: what you typed, else "Orchestrator".
    public var displayName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Self.defaultName : t
    }

    /// The row the Orchestrator itself runs on: the first default row, else the first row.
    public var defaultRow: OrchestratorModelRow? { models.first { $0.isDefault } ?? models.first }

    /// The scoped Orchestrator thread on `environmentId`, if it has one.
    public func threadId(on environmentId: String) -> ThreadId? {
        machines[environmentId].map { ThreadId($0.threadId).scoped(to: environmentId) }
    }

    /// Whether `id` (scoped) is an Orchestrator thread on any machine.
    public func isOrchestrator(_ id: ThreadId) -> Bool {
        guard let env = id.environmentId else { return false }
        return machines[env]?.threadId == id.localId.rawValue
    }

    public func isHandsOff(_ id: ThreadId) -> Bool { handsOff.contains(id.rawValue) }
}

// MARK: - Brief

/// The first message of an Orchestrator thread, since T3 has no system prompt (docs/orchestrator.md, "The custom prompt").
public enum OrchestratorBrief {
    /// A brief starts with one of these lines, which Redesign draws as a collapsed card. The official app shows the text.
    public static let firstHeading = "# Orchestrator brief"
    public static let updatedHeading = "# Updated brief"
    /// What follows an updated brief: the message you wrote.
    public static let messageHeading = "# Message"

    public struct Inputs: Sendable {
        public var name: String
        public var machine: String
        /// Each project: its name, id and folder.
        public var projects: [(name: String, id: String, path: String)]
        public var crewLimit: Int
        public var models: [OrchestratorModelRow]
        public var notebook: OrchestratorNotebook
        public var handsOff: [String]
        public var askFirstMinutes: Int
        /// Every machine CandyWrapper connects to. The connected flag stays out of the fingerprint.
        public var machines: [OrchestratorMachineRef]

        public init(name: String, machine: String, projects: [(name: String, id: String, path: String)], crewLimit: Int,
                    models: [OrchestratorModelRow], notebook: OrchestratorNotebook, handsOff: [String], askFirstMinutes: Int,
                    machines: [OrchestratorMachineRef] = []) {
            self.name = name; self.machine = machine; self.projects = projects; self.crewLimit = crewLimit
            self.models = models; self.notebook = notebook; self.handsOff = handsOff; self.askFirstMinutes = askFirstMinutes
            self.machines = machines
        }
    }

    /// The prompt with its placeholders filled, then the notebook and how CandyWrapper reads the fenced blocks.
    public static func render(_ prompt: String, _ i: Inputs) -> String {
        let projects = i.projects.isEmpty ? "- (none yet)" : i.projects.map { "- \($0.name) (projectId \($0.id)): \($0.path)" }.joined(separator: "\n")
        var text = prompt
        for (key, value) in [("name", i.name), ("machine", i.machine), ("projects", projects), ("bots", "- (none yet)"),
                             ("models", modelsTable(i.models)), ("crewLimit", "\(i.crewLimit)")] {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        var notes = ["# Your notebook today", ""]
        for name in OrchestratorNotebook.names {
            let body = i.notebook[name].trimmingCharacters(in: .whitespacesAndNewlines)
            notes.append("## \(name)")
            notes.append(body.isEmpty ? "(empty)" : body)
            notes.append("")
        }
        let handsOff = i.handsOff.isEmpty ? "None." : i.handsOff.map { "- \($0)" }.joined(separator: "\n")
        let app = """
        # How the app talks to you

        - Lines that start with "Event:" come from the app, not the user. Each names a thread that finished a turn, failed or needs something.
        - The app marks threads you must not prompt with "Hands off", and threads the user wrote in during the last \(i.askFirstMinutes) minutes with "ask first".
        - To save a note, write a fenced block named orchestrator-memory whose first line is `note: <name>` (rules, crew-rules, plan or digest), then the note's full new text.
        - Write plans as a fenced orchestrator-plan block with one numbered step per line, each with its thread link once it has one. Mark a finished step with [x].

        Threads marked Hands off right now:
        \(handsOff)

        \(visualsSection)

        \(questionsSection)
        """
        // Last, so the voice rules are the final word. Any copy in the prompt goes, since saved prompts carry older rules.
        return withoutVoice(text).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + notes.joined(separator: "\n") + "\n" + app
            + (i.machines.count > 1 ? "\n\n" + otherMachines(i) : "") + "\n\n" + voiceSection
    }

    /// The prompt without its "# Talking to the user" sections, each up to the next top-level heading.
    static func withoutVoice(_ prompt: String) -> String {
        var kept: [Substring] = []
        var skipping = false
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") { skipping = line == "# Talking to the user" }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// How to reach threads on machines other than its own (docs/orchestrator.md, "Every machine").
    static func otherMachines(_ i: Inputs) -> String {
        """
        # Every machine

        You manage the threads on every machine CandyWrapper connects to. Your t3_thread and t3_project tools reach only \(i.machine), so a thread on another machine reads as thread_not_found there. The machines:
        \(OrchestratorMachineRef.briefList(i.machines))

        To act on any machine, write a fenced block named orchestrator-call with one JSON object per line, then end your turn. CandyWrapper runs each call on the machine it names and sends the results back as your next message, one part per call starting with "Result:". A thread id alone doesn't say where a thread lives, so every call that names a thread also names its "machine", by id or label.

        - {"tool":"list"} lists every machine's projects and its 40 newest threads. Add "machine" for one machine and "title" to find threads by title.
        - {"tool":"read","machine":"<machine>","threadId":"<id>","last":5} returns the thread's state and its last messages, up to 20.
        - {"tool":"send","machine":"<machine>","threadId":"<id>","text":"<prompt>"} prompts it. Behind a running turn it queues.
        - {"tool":"launch","machine":"<machine>","projectId":"<id>","title":"<name>","text":"<first prompt>","model":"<Models row label>","worktree":"<base ref>"} starts a worker. Leave out model for the default row and worktree to run in the project's checkout.
        - {"tool":"archive","machine":"<machine>","threadId":"<id>"} archives a finished thread.

        The same limits hold on every machine, and CandyWrapper enforces them: it refuses to prompt a Hands off thread, it refuses an ask-first thread until you asked the user and send again with "confirmed":true, and it refuses a launch once \(i.crewLimit) workers run across all machines. On \(i.machine) itself, keep using your t3 tools. Calls run only while CandyWrapper is open. Event lines name the machine of any thread that isn't on \(i.machine).
        """
    }

    /// How it talks to you: in the default prompt, and added to any brief whose prompt lacks it, so an edited or older
    /// prompt gets it too. It comes last, so it wins over older advice on replies.
    public static let voiceSection = """
    # Talking to the user

    These rules beat any other advice in this brief about how to reply.

    - Stay quiet while work runs. No message for routine steps, retries, relays, reads, sends or pickup lines.
    - Speak only when something the user cares about is done, or when something needs them.
    - Then use 1 or 2 short sentences, the result first, in normal sentences.
    - No technical details, versions or ids unless asked. No lists or formatting unless asked. Never recap.
    - An event with nothing new for the user gets no reply text at all, just the call or note.
    - Choices go through the question tool as tap options.
    - Keep your digest and plan up to date as notes in orchestrator-memory blocks (note: digest, note: plan). The app saves blocks and never shows them as text, so never write a note's contents into your reply.
    - Link a thread by its title, like [Release notes](t3-thread://v1/<threadId>).
    """

    /// Added to every brief, so prompts edited before these existed still get them.
    public static let visualsSection = """
    # Showing visuals

    When a chart, table, diagram or mockup would say more than prose, build a self-contained HTML page, check it with html_preview, then publish it with html_render before your reply. The user sees the page in your chat above your reply, so don't describe it again; add only what it doesn't say.
    """

    public static let questionsSection = """
    # Asking the user

    When you need the user to choose, ask with your question tool instead of in prose: AskUserQuestion on Claude, request_user_input on Codex. Offer 2 to 4 short options; the user can always type their own answer instead. Ask one question at a time, and only when the plan needs their decision.
    """

    /// `{{models}}`: one table row per model, the default marked. Rows the caller found missing are left out before this.
    public static func modelsTable(_ rows: [OrchestratorModelRow]) -> String {
        guard !rows.isEmpty else { return "(no models set up; use the thread's default model)" }
        var lines = ["| Label | Provider | Model | Options | Use when | Notes |", "|---|---|---|---|---|---|"]
        let defaultId = rows.first { $0.isDefault }?.id ?? rows[0].id
        for r in rows {
            let options = r.options.isEmpty ? "defaults" : r.options.map { "\($0.id) \($0.value.string ?? ($0.value.bool == true ? "on" : "off"))" }
                .joined(separator: ", ")
            let label = r.id == defaultId ? "\(r.label) (default)" : r.label
            lines.append("| \(cell(label)) | \(cell(r.instanceId)) | \(cell(r.model)) | \(cell(options)) | \(cell(r.useWhen)) | \(cell(r.notes)) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// A short stable fingerprint of a rendered brief, to tell whether the thread already has this version.
    public static func digest(_ brief: String) -> String {
        // FNV-1a, 64-bit: stable across launches, unlike `hashValue`.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in brief.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// Whether the thread needs an updated brief: the prompt, models, limits, projects and Hands off decide it. The
    /// notebook stays out, since the Orchestrator writes most of it itself.
    // ponytail: notebook edits in Settings wait for the next session's brief; fold them in if the user edits notes there often
    public static func fingerprint(_ prompt: String, _ i: Inputs) -> String {
        var bare = i
        bare.notebook = OrchestratorNotebook()
        // A machine going offline and back sends no brief.
        bare.machines = i.machines.map { var m = $0; m.connected = true; return m }
        return digest(render(prompt, bare))
    }

    public static func first(_ brief: String) -> String { "\(firstHeading)\n\n\(brief)" }

    /// Your message with the updated brief in front of it.
    public static func updated(_ brief: String, message: String) -> String {
        "\(updatedHeading)\n\n\(brief)\n\n\(messageHeading)\n\n\(message)"
    }

    /// Splits a user message into its brief and the rest, for drawing.
    public static func split(_ text: String) -> (brief: String?, updated: Bool, message: String) {
        if text.hasPrefix(firstHeading + "\n") { return (String(text.dropFirst(firstHeading.count)).trimmingCharacters(in: .whitespacesAndNewlines), false, "") }
        guard text.hasPrefix(updatedHeading + "\n") else { return (nil, false, text) }
        let body = String(text.dropFirst(updatedHeading.count))
        guard let r = body.range(of: "\n\n\(messageHeading)\n\n", options: .backwards) else {
            return (body.trimmingCharacters(in: .whitespacesAndNewlines), true, "")
        }
        return (String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), true, String(body[r.upperBound...]))
    }

    /// The prompt the "while closed" scheduled task sends.
    public static let scheduledCheckPrompt = """
    Scheduled check: CandyWrapper is closed. List every thread on this machine with t3_thread_list (each project), read only what changed since your last look, update your plan, and take the next step where one is due. Follow the Hands off and ask-first rules from your brief.
    """

    /// The task's prompt: the check, then the settings the relay checks, which the helper and the check itself read
    /// (docs/orchestrator-helper.md, section 5). A brief reaches the thread only with your next message; the task is
    /// rewritten as soon as a setting changes and costs no turn.
    public static func scheduledCheck(settings: OrchestratorRelaySettings) -> String {
        scheduledCheckPrompt + "\n\nCandyWrapper's current Hands off list and limits, which win over your brief's:\n\n" + settings.block
    }

    /// The spec's default prompt (docs/orchestrator.md, "Default prompt").
    public static let defaultPrompt = """
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

    \(voiceSection)
    """
}

// MARK: - Sharing threads politely

/// Whether the Orchestrator may prompt a thread (docs/orchestrator.md, "Every thread is under the Orchestrator").
public enum OrchestratorPermission: Equatable, Sendable {
    case free
    /// You wrote the thread's last prompt this many whole minutes ago, inside the ask-first window.
    case askFirst(minutesAgo: Int)
    case handsOff

    /// Hands off wins; then "ask first" while your own message is the thread's last prompt and is younger than the
    /// window. A prompt from another thread after yours (`latestUserMessageAt` past `latestUserAuthoredMessageAt`,
    /// ProjectionStore.ts:1622-1624) means you already said go. So does a relayed prompt at or after yours
    /// (`relayedAtMs`): the server records those as yours too, since every client command is `createdBy: "user"`.
    public static func of(_ thread: ThreadShell, handsOff: Bool, windowMinutes: Int, now: Date, relayedAtMs: Int64? = nil) -> Self {
        if handsOff { return .handsOff }
        guard windowMinutes > 0, let authored = thread.latestUserAuthoredMessageAt?.epochMs else { return .free }
        if let latest = thread.latestUserMessageAt?.epochMs, latest > authored { return .free }
        // ponytail: 5 s of clock skew between this Mac and the thread's machine; compare message ids if a machine drifts more
        if let relayed = relayedAtMs, authored <= relayed + 5_000 { return .free }
        let ageMs = Int64(now.timeIntervalSince1970 * 1000) - authored
        guard ageMs < Int64(windowMinutes) * 60_000 else { return .free }
        return .askFirst(minutesAgo: max(0, Int(ageMs / 60_000)))
    }

    /// The note an event line carries, if any.
    public var note: String? {
        switch self {
        case .free: nil
        case .askFirst(let m): m == 0 ? "the user wrote there just now, so ask first" : "the user wrote there \(m) min ago, so ask first"
        case .handsOff: "Hands off: report only, never prompt it"
        }
    }
}

// MARK: - Events

/// Something a thread did that the Orchestrator should hear about.
public struct OrchestratorEvent: Hashable, Sendable {
    public enum Kind: String, Sendable { case finished, failed, needsYou }
    public var threadId: ThreadId
    public var title: String
    public var kind: Kind
    public var permission: OrchestratorPermission
    /// The machine's label when the thread isn't on the Orchestrator's own machine.
    public var machine: String?

    public init(threadId: ThreadId, title: String, kind: Kind, permission: OrchestratorPermission, machine: String? = nil) {
        self.threadId = threadId; self.title = title; self.kind = kind; self.permission = permission; self.machine = machine
    }

    public static func == (l: Self, r: Self) -> Bool { l.threadId == r.threadId && l.kind == r.kind }
    public func hash(into h: inout Hasher) { h.combine(threadId); h.combine(kind) }

    /// "Event: “Release notes” finished a turn (t3-thread://v1/abc). The user wrote there 3 min ago, so ask first."
    public var line: String {
        let what = switch kind {
        case .finished: "finished a turn"
        case .failed: "failed"
        case .needsYou: "is waiting on an approval or a question"
        }
        let note = permission.note.map { " \($0.prefix(1).uppercased())\($0.dropFirst())." } ?? ""
        let on = machine.map { " on \($0) (machine \(threadId.environmentId ?? ""))" } ?? ""
        return "Event: “\(title)”\(on) \(what) (t3-thread://v1/\(threadId.localId.rawValue)).\(note)"
    }

    public static let running: Set<ThreadStatus> = [.preparing, .queued, .starting, .running, .waiting]

    /// What changed between two shell states of the machine's threads. Skips the Orchestrator, archived and deleted
    /// threads, and threads with a parent: T3 wakes a parent when its own child finishes (orchestratorMcp.ts:222).
    public static func diff(old: [ThreadId: ThreadShell], new: [ThreadShell], orchestrator: ThreadId,
                            handsOff: (ThreadId) -> Bool, windowMinutes: Int, now: Date,
                            relayedAt: (ThreadId) -> Int64? = { _ in nil }, machine: String? = nil) -> [OrchestratorEvent] {
        var out: [OrchestratorEvent] = []
        for t in new where t.id != orchestrator && t.archivedAt == nil && t.deletedAt == nil && t.lineage.parentThreadId == nil {
            guard let before = old[t.id] else { continue }
            var kinds: [Kind] = []
            let wasRunning = running.contains(before.status), isRunning = running.contains(t.status)
            if t.status == .failed, before.status != .failed { kinds.append(.failed) }
            else if wasRunning, !isRunning, t.status == .completed || t.status == .idle { kinds.append(.finished) }
            if let r = t.pendingRuntimeRequest, r.id != before.pendingRuntimeRequest?.id { kinds.append(.needsYou) }
            guard !kinds.isEmpty else { continue }
            let permission = OrchestratorPermission.of(t, handsOff: handsOff(t.id), windowMinutes: windowMinutes, now: now, relayedAtMs: relayedAt(t.id))
            for k in kinds { out.append(.init(threadId: t.id, title: t.title, kind: k, permission: permission, machine: machine)) }
        }
        return out
    }
}

/// Events that land within one window go out as one message (docs/orchestrator.md: "a busy minute costs one turn").
/// The first event opens the window; everything until it closes joins that message. Nothing ticks between events:
/// the caller arms a single one-shot timer for `deadline`.
public struct OrchestratorEventBatch: Sendable {
    public let window: TimeInterval
    public private(set) var pending: [OrchestratorEvent] = []
    public private(set) var deadline: Date?

    public init(window: TimeInterval = 30) { self.window = window }

    /// Adds events and returns the deadline to arm when this opened the window, else nil (a timer is already armed).
    public mutating func add(_ events: [OrchestratorEvent], now: Date) -> Date? {
        guard !events.isEmpty else { return nil }
        for e in events {
            // A newer state of the same thread and kind replaces the older line.
            if let i = pending.firstIndex(of: e) { pending[i] = e } else { pending.append(e) }
        }
        guard deadline == nil else { return nil }
        deadline = now.addingTimeInterval(window)
        return deadline
    }

    /// The message to send once the window closed, else nil. Empties the batch. `keep` drops events that went stale
    /// inside the window, like a turn end of a thread the Orchestrator archived meanwhile.
    public mutating func flush(now: Date, keep: (OrchestratorEvent) -> Bool = { _ in true }) -> String? {
        guard let deadline, now >= deadline else { return nil }
        self.deadline = nil
        defer { pending = [] }
        let lines = pending.filter(keep).map(\.line)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Drops everything, as when the Orchestrator turns off.
    public mutating func reset() { pending = []; deadline = nil }

    /// Whether a message is an event message the app sent.
    public static func isEventMessage(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("Event: ") }
    }
}

// MARK: - Relay settings

/// What a relay checks before it acts: the worker limit, the ask-first window, Hands off and the Models rows. The Mac
/// writes them into the "while closed" task as a fenced `orchestrator-config` block; the helper reads them there.
public struct OrchestratorRelaySettings: Codable, Equatable, Sendable {
    public static let fence = "orchestrator-config"

    public var crewLimit: Int
    public var askFirstMinutes: Int
    /// Scoped thread ids.
    public var handsOff: [String]
    /// Every row; each relay keeps the ones a machine's catalog offers.
    public var models: [OrchestratorModelRow]
    public var closedCheckMinutes: Int?

    public init(_ config: OrchestratorConfig) {
        crewLimit = config.crewLimit
        askFirstMinutes = config.askFirstMinutes
        handsOff = config.handsOff.sorted()
        models = config.models
        closedCheckMinutes = config.closedCheckMinutes
    }

    /// Onto a config: the relay's own memory (`relayedAt`, `relayWorkers`) stays.
    public func apply(to config: inout OrchestratorConfig) {
        config.crewLimit = crewLimit
        config.askFirstMinutes = askFirstMinutes
        config.handsOff = Set(handsOff)
        config.models = models
        config.closedCheckMinutes = closedCheckMinutes
    }

    public var block: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "```\(Self.fence)\n\(json)\n```"
    }

    /// The last block in `text`, nil when there is none or it doesn't decode.
    public static func parse(_ text: String) -> Self? {
        guard let start = text.range(of: "```\(fence)\n", options: .backwards),
              let end = text.range(of: "\n```", range: start.upperBound..<text.endIndex) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text[start.upperBound..<end.lowerBound].utf8))
    }
}
