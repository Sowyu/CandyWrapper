import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SettingsScopeLifetimeTests {
    @MainActor final class Gate {
        var continuation: CheckedContinuation<JSONValue, Never>?
        func wait() async -> JSONValue { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(returning: .object(["signaled": .bool(true)])); continuation = nil }
    }
    private func scope(_ id: String) -> SettingsScopeState {
        SettingsScopeState(environments: [SettingsScopeEnvironment(id: id, label: id, settings: ServerSettingsValues(.object([:])))], primaryId: id)
    }
    @Test func aLateLinkedTaskDoesNotReplaceTheOpenEditor() async {
        let context = SettingsPageContext()
        context.scope = scope("a")
        var hosts: [ModalHost] = []
        context.presentDialog = { dialog in let host = ModalHost(panel: dialog); hosts.append(host); return host }
        let page = ScheduledTasksSettingsView(context: context)
        page.openEditor(environmentId: "a", task: nil)
        #expect(hosts.count == 1)
        let task = ScheduledTask(id: "linked", title: "Linked", prompt: "prompt", schedule: .fixedTime(timeOfDay: "09:00", weekdays: [1]), projectId: "p")
        context.scheduledTasks = ["a": .loaded([task])]
        page.linkedTask = ("a", task.id)
        page.refresh()
        await Task.yield()
        #expect(hosts.count == 1)
        for host in hosts { host.close(animated: false) }
    }
    @Test func aSignalFromThePreviousMachineCannotClearTheNextMachinesPendingSignal() async {
        let context = SettingsPageContext(), old = Gate(), next = Gate()
        context.scope = scope("a")
        context.request = { env, method, _ in
            if method == "server.signalProcess" { return await (env == "a" ? old : next).wait() }
            return .object([:])
        }
        let page = DiagnosticsSettingsView(context: context)
        page.refresh()
        let proc: JSONValue = .object(["pid": .number(123), "startTimeMs": .number(10)])
        page.signal(proc, "SIGINT")
        while old.continuation == nil { await Task.yield() }
        context.scope = scope("b")
        page.refresh()
        #expect(page.signaling == nil)
        page.signal(proc, "SIGINT")
        while next.continuation == nil { await Task.yield() }
        old.finish()
        await Task.yield()
        #expect(page.signaling == 123)
        next.finish()
        while page.signaling != nil { await Task.yield() }
    }
}
