import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Store-side wire changes between nightly 4928 and 5258 (docs/research/nightly-diff-5258-wire.md).
@Suite struct Nightly5258StoreTests {
    /// B2: a workflow agent step's shell decodes its run and stays out of thread lists (orchestrationV2.ts:2436).
    @Test func aWorkflowStepShellIsNotListed() throws {
        var json = baseThreadJSON
        json.removeLast() // "}"
        json += #","workflowRun":{"environmentId":"e1","runId":"wr1","workflow":"release","step":"build"}}"#
        json = json.replacingOccurrences(of: #""rootThreadId":"#, with: #""workflowStep":true,"rootThreadId":"#)
        let step = try JSONDecoder().decode(ThreadShell.self, from: Data(json.utf8))
        #expect(step.workflowRun?.step == "build")
        #expect(step.lineage.workflowStep == true && !step.lineage.isListed)
        let plain = try JSONDecoder().decode(ThreadShell.self, from: Data(baseThreadJSON.utf8))
        #expect(plain.workflowRun == nil && plain.lineage.isListed)
    }
}
