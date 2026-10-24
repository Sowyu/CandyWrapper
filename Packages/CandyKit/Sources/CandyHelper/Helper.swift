import Foundation
import T3Protocol
import T3Store
import T3Transport

/// The relay the Mac app runs while it's open (OrchestratorRemote and OrchestratorController's event relay), running
/// all the time (docs/orchestrator-helper.md). It holds the "while closed" task like a Mac that never closes, runs the
/// Orchestrator's `orchestrator-call` blocks on the machines they name, and sends every machine's events to it.
@MainActor
final class Helper {
    private let links: [String: MachineLink]
    private let order: [HelperMachine]
    private let homeId: String
    private var snapshots: [String: ShellSnapshot] = [:]
    private var configs: [String: ServerProviderConfig] = [:]
    private var memory = HelperStore.memory

    /// The Orchestrator thread on the home machine, by local id.
    private var orchestrator: String?
    private var discovering = false
    private var topLevelCount = 0
    private var tasks: [ScheduledTask] = []
    private var handoff = OrchestratorHandoff()
    private var taking = false
    private var reportedNoTask = false
    private var tasksReceived = false
    /// From the "CandyWrapper Orchestrator settings" task the clients share (docs/orchestrator.md, "Settings on every
    /// device"); nil until a client wrote one.
    private var settings: OrchestratorConfig?

    private var watched: (generation: Int, running: Bool)?
    private var handled: Set<String> = []
    private var baselines: [String: (generation: Int, threads: [ThreadId: ThreadShell])] = [:]
    private var batch = OrchestratorEventBatch()
    private var flushTask: Task<Void, Never>?

    init(machines: [HelperMachine], links: [MachineLink]) {
        order = machines
        homeId = machines.first(where: \.isHome)?.id ?? machines.first?.id ?? ""
        self.links = Dictionary(links.map { ($0.machine.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Runs every machine's connection and reads its events in order, until cancelled.
    func run() async {
        let tasks = links.values.flatMap { link -> [Task<Void, Never>] in
            [Task { await link.run() },
             Task { @MainActor [weak self] in for await event in link.events { self?.handle(link.machine, event) } }]
        }
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    private func label(_ id: String) -> String { order.first { $0.id == id }?.label ?? id }

    // MARK: Events from the machines

    private var states: [String: String] = [:]
    private let startedAt = Date()

    /// `status.json`, for `install` and `status`. Written when a connection changes, not on every push.
    private func setState(_ id: String, _ state: String) {
        guard states[id] != state else { return }
        states[id] = state
        let status = HelperStatus(version: helperVersion, pid: getpid(), startedAt: startedAt, machines: states)
        try? HelperStore.write("status.json", status)
        // Refused everywhere: a clean exit, so the service stays down until a renewal (KeepAlive SuccessfulExit,
        // Restart=on-failure) instead of restarting forever.
        if states.count == links.count, states.values.allSatisfy({ $0 == "rejected" }) {
            log("every machine refused the helper's sign-in; stopping until CandyWrapper renews it")
            exit(0)
        }
    }

    private func handle(_ machine: HelperMachine, _ event: MachineLink.Event) {
        switch event {
        case .connected(_, let config):
            log("connected to \(machine.label)")
            setState(machine.id, "connected")
            configs[machine.id] = config
            if machine.id == homeId { tasksReceived = false }
        case .shell(let generation, let snapshot):
            snapshots[machine.id] = snapshot
            if machine.id == homeId { homeChanged(generation, snapshot) }
            relayEvents(machine.id, generation, snapshot)
        case .tasks(let list):
            tasks = list
            tasksReceived = true
            if orchestrator == nil { discover() }
            tasksChanged()
        case .disconnected(let why):
            if snapshots.removeValue(forKey: machine.id) != nil || states[machine.id] == nil { log("lost \(machine.label): \(why)") }
            setState(machine.id, "offline")
        case .rejected(let why):
            snapshots[machine.id] = nil
            log("\(machine.label) refused the helper's sign-in (\(why)); it needs a renewal from CandyWrapper")
            setState(machine.id, "rejected")
        }
    }

    private func homeChanged(_ generation: Int, _ snapshot: ShellSnapshot) {
        let topLevel = snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil }.count
        defer { topLevelCount = topLevel }
        // Start on the Mac makes a new Orchestrator thread: look again when a top-level thread appears.
        guard let orchestrator else {
            if topLevel > topLevelCount { discover() }
            return
        }
        guard let shell = snapshot.threads.first(where: { $0.id.rawValue == orchestrator }) else { return }
        let running = OrchestratorEvent.running.contains(shell.status)
        defer { watched = (generation, running) }
        guard let was = watched, was.generation == generation, was.running, !running else { return }
        let run = shell.latestRunId
        Task { await runCalls(run: run) }
    }

    // MARK: Finding the Orchestrator

    /// The newest thread whose first message is a brief, as the Mac adopts one (OrchestratorController.adopt).
    private func discover() {
        // The task list says which brief thread the Mac uses, so wait for it as well as the shell.
        guard !discovering, tasksReceived, let link = links[homeId], snapshots[homeId] != nil else { return }
        discovering = true
        Task {
            defer { discovering = false }
            let found = await findOrchestrator(link)
            guard !found, orchestrator == nil else { return }
            // Not there yet, or the server was busy: look again in a while, as long as it stays unknown.
            log("no Orchestrator thread on \(label(homeId)) yet; looking again in 30 s")
            try? await Task.sleep(for: .seconds(30))
            discovering = false
            if orchestrator == nil { discover() }
        }
    }

    private func findOrchestrator(_ link: MachineLink) async -> Bool {
        let matches: [ThreadSearchMatch]
        do {
            matches = try await link.request("orchestration.searchThreads", .object(["query": .string("Orchestrator brief")]))
                .decode(as: ThreadSearchResult.self).matches
        } catch {
            log("couldn't search \(label(homeId))'s threads: \(MachineLink.describe(error))")
            return false
        }
        // The shell as it is now: the one when the search started may have been an early, partial one.
        guard let snapshot = snapshots[homeId] else { return false }
        let live = Dictionary(snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil }
            .map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        // A thread a check task points at is the one the Mac uses; then the newest.
        let checked = Set(tasks.filter { $0.prompt.hasPrefix("Scheduled check:") }.compactMap(\.threadId))
        func rank(_ id: String) -> (Int, Int64) { (checked.contains(id) ? 1 : 0, live[id]?.updatedAt.epochMs ?? 0) }
        let briefs = OrchestratorHandoff.briefThreads(matches)
        guard let local = briefs.filter({ live[$0] != nil }).max(by: { rank($0) < rank($1) }) else { return false }
        orchestrator = local
        log("found the Orchestrator thread “\(live[local]?.title ?? local)” (\(local)) on \(label(homeId))")
        tasksChanged()
        return true
    }

    // MARK: The "while closed" task

    /// The task carries the settings, and whoever wrote it last holds it. The helper always takes it back
    /// (`OrchestratorHandoff.verdict`): the Mac stands by while the helper is connected and the phone relays only
    /// while the task is on.
    private func tasksChanged() {
        // Read only: every synced setting wins over the defaults, and the helper never writes the document.
        let documents = tasks.filter { $0.title == OrchestratorSettingsSync.title }.compactMap { OrchestratorSettingsSync.Document.parse($0.prompt) }
        if !documents.isEmpty {
            let merged = OrchestratorSettingsSync.merge(config: OrchestratorConfig(), stamps: [:], documents: documents, machine: homeId).config
            if merged != settings {
                settings = merged
                log("read CandyWrapper's settings: \(merged.handsOff.count) Hands off, worker limit \(merged.crewLimit)")
            }
        }
        guard let orchestrator else { return }
        let task = tasks.first { $0.threadId == orchestrator && $0.prompt.hasPrefix("Scheduled check:") }
        if task == nil, !reportedNoTask {
            reportedNoTask = true
            log("no \"while closed\" task for the Orchestrator among \(tasks.count) tasks yet; nothing to hold")
        }
        guard let task, !taking, handoff.verdict(task: task) == .resync else { return }
        taking = true
        Task {
            defer { taking = false }
            do {
                let result = try await links[homeId]?.request("scheduledTasks.setEnabled", .object(["id": .string(task.id), "enabled": .bool(false)]))
                handoff.wrote(updatedAt: result?["task"]?["updatedAt"]?.stringValue)
                log("holding the \"while closed\" task")
            } catch {
                log("couldn't hold the \"while closed\" task: \(MachineLink.describe(error))")
            }
        }
    }

    /// On a clean stop: the schedule takes over, as when the Mac quits. Left off when the user turned the check off.
    func handBack() async {
        guard let orchestrator, let link = links[homeId],
              let task = tasks.first(where: { $0.threadId == orchestrator && $0.prompt.hasPrefix("Scheduled check:") }) else { return }
        guard settings?.closedCheckMinutes != nil else { return }
        do {
            _ = try await link.request("scheduledTasks.setEnabled", .object(["id": .string(task.id), "enabled": .bool(true)]))
            log("handed the \"while closed\" task back to the schedule")
        } catch {
            log("couldn't hand the task back: \(MachineLink.describe(error))")
        }
    }

    // MARK: Calls

    private func runCalls(run: RunId?) async {
        // As the Mac and the phone do: wait, so another relay's "Result:" can land, and run only unanswered calls.
        try? await Task.sleep(for: OrchestratorHandoff.callDelay)
        guard let orchestrator, let link = links[homeId],
              let json = try? await link.request("orchestration.getThreadProjection", .object(["threadId": .string(orchestrator)])),
              let projection = try? json.decode(as: ThreadProjection.self) else { return }
        let mine = projection.messages.filter { $0.role == "assistant" && !$0.streaming && (run == nil || $0.runId == run) }
        let replies = OrchestratorHandoff.unansweredReplies(projection.messages, run: run, handled: handled)
        handled.formUnion(mine.map(\.id.rawValue))
        let calls = replies.sorted { ($0.createdAt.epochMs ?? 0) < ($1.createdAt.epochMs ?? 0) }.flatMap { OrchestratorReply.parse($0.text).calls }
        guard !calls.isEmpty else { return }
        log("running \(calls.count) call\(calls.count == 1 ? "" : "s"): \(calls.map { $0.tool?.rawValue ?? "?" }.joined(separator: ", "))")
        // Without the Hands off list and the limits nothing may act; reading would be fine, but one clear answer is safer.
        guard settings != nil else {
            send(OrchestratorRelay.resultPrefix + "refused: the helper hasn't got CandyWrapper's settings (Hands off and limits) yet. Ask the user to open CandyWrapper once.")
            return
        }
        if let text = await OrchestratorRelay(host: host()).run(calls) { send(text) }
    }

    private func host() -> OrchestratorRelayHost {
        OrchestratorRelayHost(
            machines: { [weak self] in self?.machineRefs() ?? [] },
            snapshot: { [weak self] in self?.snapshots[$0] },
            request: { [weak self] machine, method, payload in
                guard let link = self?.links[machine] else { throw HelperError("no machine \(machine)") }
                do { return try await link.request(method, payload) } catch let e as RPCClientError {
                    throw HelperError(e.typedError?.message ?? e.description)
                }
            },
            config: { [weak self] in self?.config() ?? OrchestratorConfig() },
            update: { [weak self] change in self?.update(change) },
            rows: { [weak self] in self?.rows($0) ?? [] },
            runtimeMode: { [weak self] in self?.configs[$0]?.settings.defaultRuntimeMode.rawValue ?? "full-access" },
            orchestrator: { [weak self] in self.flatMap { s in s.orchestrator.map { ThreadId($0).scoped(to: s.homeId) } } })
    }

    private func machineRefs() -> [OrchestratorMachineRef] {
        order.map { OrchestratorMachineRef(id: $0.id, label: $0.label, isHome: $0.id == homeId, connected: snapshots[$0.id] != nil) }
            .sorted { $0.isHome && !$1.isHome }
    }

    private func config() -> OrchestratorConfig {
        var c = settings ?? OrchestratorConfig()
        c.relayedAt = memory.relayedAt
        c.relayWorkers = memory.relayWorkers
        return c
    }

    private func update(_ change: (inout OrchestratorConfig) -> Void) {
        var c = config()
        change(&c)
        let next = HelperMemory(relayedAt: c.relayedAt, relayWorkers: c.relayWorkers)
        guard next != memory else { return }
        memory = next
        do { try HelperStore.write("memory.json", memory) } catch { log("couldn't save memory.json: \(error)") }
    }

    /// The Models rows this machine's catalog offers, as the Mac's `availableRows`.
    private func rows(_ machine: String) -> [OrchestratorModelRow] {
        let all = (settings ?? OrchestratorConfig()).models
        guard let providers = configs[machine]?.providers else { return all }
        let catalog = ProviderCatalog(providers)
        return all.filter { catalog.entry(ProviderInstanceId(rawValue: $0.instanceId))?.model($0.model) != nil }
    }

    /// One message to the Orchestrator; behind a running turn it queues.
    private func send(_ text: String) {
        guard let orchestrator, let link = links[homeId],
              let shell = snapshots[homeId]?.threads.first(where: { $0.id.rawValue == orchestrator }) else { return }
        let payload = OrchestratorRelayHost.message(orchestrator, text, shell.modelSelection, OrchestratorEvent.running.contains(shell.status))
        Task {
            do { _ = try await link.request("orchestration.dispatchCommand", payload) } catch {
                log("couldn't reach the Orchestrator: \(MachineLink.describe(error))")
            }
        }
    }

    // MARK: Events

    /// Diffs a machine's threads against its last state on the same connection and batches turn ends, failures and
    /// requests, as the Mac's event relay does.
    private func relayEvents(_ machine: String, _ generation: Int, _ snapshot: ShellSnapshot) {
        let current = snapshot.threads.map { t -> ThreadShell in var s = t; s.id = t.id.scoped(to: machine); return s }
        let old = baselines[machine]
        baselines[machine] = (generation, Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        // The first state of a connection is the baseline; nothing in it is news.
        guard let orchestrator, let old, old.generation == generation else { return }
        let config = config()
        let events = OrchestratorEvent.diff(old: old.threads, new: current, orchestrator: ThreadId(orchestrator).scoped(to: homeId),
                                            handsOff: { config.isHandsOff($0) }, windowMinutes: config.askFirstMinutes, now: Date(),
                                            relayedAt: { config.relayedAt[$0.rawValue] },
                                            machine: machine == homeId ? nil : label(machine))
        guard let deadline = batch.add(events, now: Date()) else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        let live = Set(snapshots.flatMap { machine, snapshot in
            snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map { $0.id.scoped(to: machine) }
        })
        guard let text = batch.flush(now: Date().addingTimeInterval(0.001), keep: { live.contains($0.threadId) }) else { return }
        log("sending \(text.split(separator: "\n").count) event line(s)")
        send(text)
    }
}
