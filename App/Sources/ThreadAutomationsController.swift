import AppKit
import DesignSystem
import Features
import T3Protocol

/// The thread details card's Automations (ThreadAutomationsPanel.tsx): follows the open thread's environment's
/// task list, shows the tasks bound to the thread, and runs, pauses and resumes them. Edit and the settings
/// glyph open Settings > Scheduled Tasks.
@MainActor
final class ThreadAutomationsController {
    private let panel: ThreadPanelView
    private let environments: Environments
    var openThreadId: (() -> ThreadId?)?
    /// Opens Settings > Scheduled Tasks for an environment, with a task's editor when given.
    var openSettings: ((String, String?) -> Void)?
    private var busy: String?

    init(panel: ThreadPanelView, environments: Environments) {
        self.panel = panel
        self.environments = environments
        let view = panel.detailsCard.automations
        view.onManage = { [weak self] in
            guard let self, let id = self.openThreadId?(), let env = id.environmentId else { return }
            self.openSettings?(env, nil)
        }
        view.onEdit = { [weak self] t in
            guard let self, let id = self.openThreadId?(), let env = id.environmentId else { return }
            self.openSettings?(env, t.id)
        }
        view.onRun = { [weak self] t in self?.act(t, "scheduledTasks.runNow", .object(["id": .string(t.id)]), failure: "Could not run automation") }
        // Partial update: only the enabled flag changes, so a toggle never reverts edits made elsewhere.
        view.onToggle = { [weak self] t, on in
            self?.act(t, "scheduledTasks.setEnabled", .object(["id": .string(t.id), "enabled": .bool(on)]), failure: "Could not update automation")
        }
        _ = ScheduledTasksStore.shared.observe { [weak self] in self?.sync() }
    }

    func sync() {
        let id = openThreadId?()
        ScheduledTasksStore.shared.watch("thread", id?.environmentId.map { [$0] } ?? [])
        let view = panel.detailsCard.automations
        guard let id, let env = id.environmentId else { view.tasks = []; view.error = nil; panel.detailsCard.automationsChanged(); return }
        switch ScheduledTasksStore.shared.lists[env] {
        case .loaded(let tasks):
            view.error = nil
            view.tasks = tasks.filter { $0.threadId == id.localId.rawValue }
        case .failed(let e):
            view.error = e
            view.tasks = []
        default:
            view.error = nil
            view.tasks = []
        }
        view.busyTaskId = busy
        panel.detailsCard.automationsChanged()
    }

    private func act(_ t: ScheduledTask, _ method: String, _ payload: JSONValue, failure: String) {
        guard busy == nil, let env = openThreadId?()?.environmentId else { return }
        busy = t.id
        sync()
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.environments.request(env, method, payload) } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                _ = self.panel.toasts.show(ToastView(title: failure, message: message, kind: .error))
            }
            self.busy = nil
            self.sync()
        }
    }
}
