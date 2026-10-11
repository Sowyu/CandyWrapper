import AppKit
import Features
import T3Client
import T3Protocol

/// Live scheduled task lists per environment (`scheduledTasks.subscribe`: a snapshot, then the whole list
/// after every change). Settings > Scheduled Tasks watches the scope's environments; the thread details card
/// watches the open thread's. A list is followed only while someone watches it.
@MainActor
final class ScheduledTasksStore {
    static let shared = ScheduledTasksStore()
    var environments: Environments?
    private(set) var lists: [String: ScheduledTaskListLoad] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Watchers by name, each with the environments it wants.
    private var watchers: [String: Set<String>] = [:]
    private var observers: [UUID: @MainActor () -> Void] = [:]

    func observe(_ change: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    /// Sets what one watcher follows; an empty set stops it.
    func watch(_ watcher: String, _ ids: Set<String>) {
        watchers[watcher] = ids.isEmpty ? nil : ids
        let wanted = watchers.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks[id] = nil
            lists[id] = nil
        }
        for id in wanted where tasks[id] == nil { subscribe(id) }
    }

    private func subscribe(_ id: String) {
        guard let shell = environments?.session(id) else { return }
        lists[id] = lists[id] ?? .loading
        tasks[id] = shell.supervisor.subscribe("scheduledTasks.subscribe", payload: { .object([:]) }, handler: { [weak self] event in
            await MainActor.run {
                guard let self else { return }
                switch event {
                case .value(let json): self.lists[id] = .loaded(ScheduledTask.list(json))
                case .interrupted(let error):
                    if case .loaded = self.lists[id] {} else { self.lists[id] = .failed(error.typedError?.message ?? "\(error)") }
                default: return
                }
                self.observers.values.forEach { $0() }
            }
        })
    }

    /// An environment without a session when it was first watched subscribes once it has one.
    func environmentsChanged() {
        let wanted = watchers.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for id in wanted where tasks[id] == nil { subscribe(id) }
    }
}
