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

    /// B3: a card with `fields` answers `values` keyed by name, once every field has a value; one without answers
    /// `secret` as before. Cases from T3's secretRequest.test.ts:31-68.
    @Test func multiFieldSecretRequestsAnswerValues() throws {
        let item = turnItem(#"{"id":"item","threadId":"thread","type":"secret_request","label":"Login","reason":"","delivery":"file","secretStatus":"pending","fields":[{"name":"email","label":"Email","secret":false},{"name":"password","label":"Password"}]}"#)
        let fields = try #require(item.secretRequestFields)
        let inputs = SecretRequests.inputs(label: "Login", placeholder: nil, fields: fields)
        #expect(inputs.map(\.key) == ["email", "password"] && inputs.map(\.secret) == [false, true])
        let sent = SecretRequests.answerInput(threadId: "thread", itemId: "item", fields: fields,
                                              .values(["email": "a@acme.dev ", "password": "pw"]))
        #expect(sent?["answer"] == .object(["type": .string("save"), "values": .object(["email": .string("a@acme.dev"), "password": .string("pw")])]))
        #expect(SecretRequests.answerInput(threadId: "thread", itemId: "item", fields: fields, .values(["email": "a@acme.dev"])) == nil)
        let named = [TurnItem.SecretRequestField(name: "constructor", label: "Key")]
        #expect(SecretRequests.answerInput(threadId: "t", itemId: "i", fields: named, .values([:])) == nil)
        #expect(SecretRequests.privacyNote(delivery: "file", multiple: true) == "Kept out of chat, in private files this agent's commands can read for 24 hours")

        // A 4928 card has no fields and keeps the single-secret answer.
        let single = SecretRequests.inputs(label: "Token", placeholder: nil, fields: nil)
        #expect(single == [SecretRequests.Input(key: "", label: "Token", placeholder: "Paste the secret", secret: true)])
        #expect(SecretRequests.answerInput(threadId: "t", itemId: "i", .values(["": " t "]))?["answer"]
            == .object(["type": .string("save"), "secret": .string("t")]))
    }
}
