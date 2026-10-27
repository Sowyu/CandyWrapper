import AgentConfig
import Foundation

/// What the Connectors tab knows about each machine's MCP servers and skills (docs/connectors.md). The app fills it
/// through `actions`, which run `candywrapper-helper config` in a hidden terminal on that machine; nothing is cached
/// between launches, so the files on each machine stay the only truth.
@MainActor
public final class ConnectorsStore {
    public static let shared = ConnectorsStore()

    public enum MachineState: Equatable, Sendable {
        case loading
        case loaded(AgentConfigSnapshot)
        case failed(String)
    }

    public private(set) var states: [String: MachineState] = [:]
    /// Machines with a change on its way.
    public private(set) var busy: Set<String> = []
    /// Changes sent and not answered yet, per machine. A read that finishes first leaves the machine busy (audit OH-5).
    private var pendingChanges: [String: Int] = [:]

    public struct Actions {
        /// Reads a machine's config; the answer comes back through `set(_:_:)`.
        public var load: ((String) -> Void)?
        /// Applies changes on a machine; the new snapshot or the error comes back through `set(_:_:)`.
        public var apply: ((String, [AgentConfigChange]) -> Void)?
        /// Why the tab can't work in this build, like a missing helper manifest; nil when it can.
        public var unavailable: (() -> String?)?
        public init() {}
    }
    public var actions = Actions()

    private var observers: [(id: Int, block: @MainActor () -> Void)] = []
    private var nextId = 0

    public init() {}

    /// `endsChange`: this answers one of the machine's changes from `apply`, not a read.
    public func set(_ machine: String, _ state: MachineState, endsChange: Bool = false) {
        states[machine] = state
        if endsChange { pendingChanges[machine, default: 1] -= 1 }
        if pendingChanges[machine, default: 0] <= 0 {
            pendingChanges[machine] = nil
            busy.remove(machine)
        }
        notify()
    }

    public func setBusy(_ machine: String) {
        busy.insert(machine)
        notify()
    }

    /// Loads every machine not loaded yet, or all of them with `force`.
    public func load(_ machines: [String], force: Bool = false) {
        for id in machines where force || states[id] == nil || { if case .failed = states[id] { true } else { false } }() {
            states[id] = .loading
            actions.load?(id)
        }
        notify()
    }

    /// Sends each machine its own changes, skipping machines with none.
    public func apply(_ changes: [String: [AgentConfigChange]]) {
        for (machine, list) in changes where !list.isEmpty {
            busy.insert(machine)
            pendingChanges[machine, default: 0] += 1
            actions.apply?(machine, list)
        }
        notify()
    }

    @discardableResult
    public func observe(_ block: @escaping @MainActor () -> Void) -> Int {
        nextId += 1
        observers.append((nextId, block))
        return nextId
    }

    public func removeObserver(_ id: Int) { observers.removeAll { $0.id == id } }

    private func notify() { for o in observers { o.block() } }
}

/// The tab's rows: servers and skills merged by name across agents and, for "Every machine", across machines.
public struct ConnectorRows: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var name: String
        /// A server's URL or command, a skill's description; the first machine's that has one.
        public var detail: String
        /// Each machine's entries for this name, by agent.
        public var entries: [String: [ConfigAgent: Bool]]

        /// The agents that have it on any machine, Claude first.
        public var agents: [ConfigAgent] { ConfigAgent.allCases.filter { a in entries.values.contains { $0[a] != nil } } }
        /// True when every copy of this agent's entry is on, false when every one is off, nil when they differ.
        public func isOn(_ agent: ConfigAgent) -> Bool? { Self.fold(entries.values.compactMap { $0[agent] }) }
        /// The row's switch: the same over every agent and machine.
        public var isOn: Bool? { Self.fold(entries.values.flatMap(\.values)) }

        static func fold(_ values: [Bool]) -> Bool? {
            if values.allSatisfy({ $0 }) { return true }
            if values.allSatisfy({ !$0 }) { return false }
            return nil
        }

        /// The changes that turn it on or off, for `agent` only or for every agent, per machine.
        func changes(to on: Bool, agent: ConfigAgent? = nil, skill: Bool) -> [String: [AgentConfigChange]] {
            var out: [String: [AgentConfigChange]] = [:]
            for (machine, byAgent) in entries {
                for a in ConfigAgent.allCases where agent == nil || a == agent {
                    guard let current = byAgent[a], current != on else { continue }
                    out[machine, default: []].append(skill ? .setSkill(agent: a, name: name, enabled: on) : .setServer(agent: a, name: name, enabled: on))
                }
            }
            return out
        }

        /// Every copy goes: one removal per agent per machine.
        func removals() -> [String: [AgentConfigChange]] {
            entries.mapValues { byAgent in ConfigAgent.allCases.filter { byAgent[$0] != nil }.map { .removeServer(agent: $0, name: name) } }
        }
    }

    public var servers: [Item] = []
    public var skills: [Item] = []
    /// Lines for files that don't parse and machines that didn't answer, with the machine's label in front.
    public var problems: [String] = []

    /// `snapshots` by machine id, in the order the picker lists them; `labels` names them in problems.
    public init(_ snapshots: [(id: String, label: String, state: ConnectorsStore.MachineState)], prefixProblems: Bool) {
        var servers: [String: Item] = [:]
        var skills: [String: Item] = [:]
        for (id, label, state) in snapshots {
            let prefix = prefixProblems ? "\(label): " : ""
            switch state {
            case .loading: continue
            case .failed(let why): problems.append(prefix + why); continue
            case .loaded(let snap):
                problems += snap.problems.map { prefix + $0 }
                for s in snap.servers {
                    servers[s.name, default: Item(name: s.name, detail: s.summary, entries: [:])].entries[id, default: [:]][s.agent] = s.enabled
                }
                for s in snap.skills {
                    var item = skills[s.name, default: Item(name: s.name, detail: s.description, entries: [:])]
                    if item.detail.isEmpty { item.detail = s.description }
                    item.entries[id, default: [:]][s.agent] = s.enabled
                    skills[s.name] = item
                }
            }
        }
        let order: (Item, Item) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.servers = servers.values.sorted(by: order)
        self.skills = skills.values.sorted(by: order)
    }
}
