import Testing
import T3Protocol
@testable import Features

struct TriageLogicTests {
    @Test func targetKeepsOnScreenMachineAndFallsBackOnlyWithoutOne() {
        let supports: (String) -> Bool = { $0 == "new" }
        #expect(TriageLogic.environment(onScreen: "old", primary: "new", connected: ["new"], supports: supports) == "old")
        #expect(TriageLogic.environment(onScreen: nil, primary: "old", connected: ["old", "new"], supports: supports) == "new")
        #expect(TriageLogic.environment(onScreen: nil, primary: "old", connected: ["old"], supports: supports) == nil)
    }
    @Test @MainActor func unsupportedServersSendNothingAndNavigationPreventsOpening() async throws {
        var calls: [String] = [], here = true
        let prepare: () async throws -> String = { calls.append("prepare"); return "playbook" }
        let scratch: () async throws -> ProjectId = { calls.append("scratch"); here = false; return ProjectId("p") }
        let show: (ProjectId, String) -> Void = { _, _ in calls.append("show") }
        try await TriageLogic.prepare(supported: false, prepare: prepare, scratch: scratch, stillHere: { here }, show: show)
        #expect(calls.isEmpty)
        try await TriageLogic.prepare(supported: true, prepare: prepare, scratch: scratch, stillHere: { here }, show: show)
        #expect(calls == ["prepare", "scratch"])
        calls = []
        try await TriageLogic.prepare(supported: true, prepare: prepare, scratch: { ProjectId("p") }, stillHere: { true }, show: { id, prompt in
            #expect(id == ProjectId("p")); #expect(prompt == "playbook"); calls.append("show")
        })
        #expect(calls == ["prepare", "show"])
    }
}
