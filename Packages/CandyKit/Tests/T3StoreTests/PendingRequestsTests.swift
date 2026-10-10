import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The `runtime-request.respond` and `thread.user-input.dismiss` commands a transcript sent.
private func sentRequestCommands(_ name: String) throws -> [JSONValue] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/transcripts/\(name)")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["dir"] as? String == "send", let body = record["body"] as? [String: Any],
              body["tag"] as? String == "orchestration.dispatchCommand", let payload = body["payload"] as? [String: Any],
              ["runtime-request.respond", "thread.user-input.dismiss"].contains(payload["type"] as? String ?? "")
        else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

/// Replays a stream chunk by chunk and keeps every distinct pending state, in order.
private func pendingStates(_ stream: RecordedThreadStream) -> [PendingRequests] {
    var reducer = ThreadReducer(threadId: stream.threadId)
    var states: [PendingRequests] = []
    for chunk in stream.chunks {
        reducer.apply(chunk)
        guard let projection = reducer.projection else { continue }
        let pending = PendingRequests.derive(projection)
        if states.last != pending { states.append(pending) }
    }
    return states
}

private func commandId(_ v: JSONValue) -> String { v["commandId"]?.stringValue ?? "" }

private func question(_ id: String, multi: Bool = false, custom: Bool? = nil, initial: String? = nil, options: [String] = ["A", "B"]) -> UserInputQuestion {
    UserInputQuestion(id: id, header: id.uppercased(), question: "\(id)?", options: options.map { .init(label: $0, description: "\($0) text") },
                      multiSelect: multi, allowCustomAnswer: custom, initialAnswer: initial)
}

@Suite struct PendingRequestsTests {
    @Test func turn2ShowsEachFileApprovalThenNothing() throws {
        let stream = try #require(try recordedThreadStreams("03-turn2.jsonl").first)
        let states = pendingStates(stream)
        let shown = states.map { $0.activeApproval.map { "\($0.label): \($0.detailText)" } ?? "none" }
        #expect(shown == ["none", "File change approval: notes.md", "none", "File change approval: hello.py", "none"])
        let approval = try #require(states[1].activeApproval)
        #expect(approval.canRespond && approval.options == nil)
        #expect(approval.buttonOptions.map(\.label) == ["Decline", "Approve"])
        #expect(approval.menuOptions.map(\.label) == ["Cancel", "Always allow this session"])

        // The recorded commands are exactly what the builder makes (commandId aside).
        let sent = try sentRequestCommands("03-turn2.jsonl")
        #expect(sent.count == 2)
        #expect(sent[0] == RuntimeRequestCommands.respond(threadId: stream.threadId, requestId: approval.requestId, decision: .accept, commandId: commandId(sent[0])))
        #expect(sent[1] == RuntimeRequestCommands.respond(threadId: stream.threadId, requestId: states[3].activeApproval!.requestId, decision: .accept, commandId: commandId(sent[1])))
    }

    @Test func settledThreadsHaveNoPendingRequests() throws {
        // 04 holds the 05 and 06 reference threads after their provider sessions closed (cancelled).
        for stream in try recordedThreadStreams("04-threads.jsonl") {
            let projection = try #require(replay(stream).projection)
            #expect(PendingRequests.derive(projection).isEmpty)
        }
    }

    @Test func everyDecisionAndAnAnswerMatchTheRecording() throws {
        let streams = try recordedThreadStreams("06-requests.jsonl")
        #expect(streams.count == 2)
        let approvalStates = pendingStates(streams[0]).compactMap(\.activeApproval)
        #expect(approvalStates.map(\.detailText) == ["a.txt", "a.txt", "b.txt"])
        let sent = try sentRequestCommands("06-requests.jsonl")
        #expect(sent.count == 4)
        for (i, decision) in [ApprovalDecision.decline, .cancel, .acceptForSession].enumerated() {
            #expect(sent[i] == RuntimeRequestCommands.respond(threadId: streams[0].threadId, requestId: approvalStates[i].requestId,
                                                              decision: decision, commandId: commandId(sent[i])))
        }

        // The question: a multi-select one and a single-select one, answered with two options and free text.
        let input = try #require(pendingStates(streams[1]).compactMap(\.activeUserInput).first)
        #expect(input.canRespond && !input.dismissible)
        #expect(input.questions.map(\.header) == ["Features", "Format"])
        #expect(input.questions.map(\.multiSelect) == [true, false])
        var session = UserInputSession(input)
        #expect(session.primaryLabel(compact: false, responding: false) == "Next question" && !session.canPressPrimary)
        #expect(session.select("Logging") == nil)
        #expect(session.select("Caching") == nil)
        #expect(session.canPressPrimary)
        #expect(session.advance() == .moved)
        #expect(session.primaryLabel(compact: false, responding: false) == "Submit answers" && session.showsPrevious)
        session.setCustomAnswer("My own answer")
        guard case .submit(let answers) = session.advance() else { Issue.record("expected a submit"); return }
        #expect(sent[3] == RuntimeRequestCommands.respond(threadId: streams[1].threadId, requestId: input.requestId,
                                                          answers: answers, commandId: commandId(sent[3])))
        // Once answered, nothing is pending and the timeline item carries the answer.
        let projection = try #require(replay(streams[1]).projection)
        #expect(PendingRequests.derive(projection).isEmpty)
        let item = try #require(projection.turnItems.last { $0.type == .userInputRequest })
        #expect(item.questionAnswer?["answers"] == .object(answers.mapValues(\.json)))
    }

    @Test func derivationRules() {
        func request(_ id: String, _ kind: RuntimeRequestKind, at: String, capability: String = "live", status: String = "pending") -> RuntimeRequest {
            decode(RuntimeRequest.self, """
            {"id":"\(id)","kind":"\(kind.rawValue)","status":"\(status)","createdAt":"\(at)","resolvedAt":null,
             "responseCapability":{"type":"\(capability)"}}
            """)
        }
        let items = [
            turnItem(#"{"id":"i1","type":"approval_request","requestId":"r2","requestKind":"command","prompt":"old"}"#),
            turnItem(#"{"id":"i2","type":"approval_request","requestId":"r2","requestKind":"command","prompt":"ls -la","options":[{"decision":"acceptAlways","label":"Always","warning":"Careful"},{"decision":"accept","label":"Yes"}]}"#),
            turnItem(#"{"id":"i3","type":"user_input_request","requestId":"q1","responseMode":"message","questions":[{"id":"a","header":"H","question":"Q","options":[]}]}"#),
        ]
        let pending = PendingRequests.derive(requests: [
            request("r2", .command, at: "2026-01-01T00:00:02Z"),
            request("r1", .fileRead, at: "2026-01-01T00:00:01Z", capability: "not_resumable"),
            request("r3", .authRefresh, at: "2026-01-01T00:00:00Z"),
            request("r4", .permission, at: "2026-01-01T00:00:00Z", status: "resolved"),
            request("q0", .userInput, at: "2026-01-01T00:00:00Z"), // no item: skipped
            request("q1", .userInput, at: "2026-01-01T00:00:03Z", capability: "message"),
        ], turnItems: items)
        #expect(pending.approvals.map(\.requestId) == ["r1", "r2"])
        #expect(pending.approvals[0].detailText == "Provider process is gone — interrupt or restart the run to respond.")
        #expect(pending.approvals[1].detail == "ls -la" && pending.approvals[1].label == "Command approval")
        #expect(pending.approvals[1].buttonOptions.map(\.label) == ["Yes"])
        #expect(pending.approvals[1].menuOptions == [ApprovalOption(.acceptAlways, "Always", warning: "Careful")])
        #expect(pending.userInputs.map(\.requestId) == ["q1"] && pending.userInputs[0].dismissible && pending.userInputs[0].canRespond)
        #expect(RuntimeRequestCommands.dismiss(threadId: "t", requestId: "q1", commandId: "c") == .object([
            "type": .string("thread.user-input.dismiss"), "commandId": .string("c"), "threadId": .string("t"), "requestId": .string("q1")]))
    }

    // Port of apps/web/src/pendingUserInput.test.ts.
    @Test func answerResolution() {
        let q = question("q")
        #expect(UserInputAnswers.resolve(q, UserInputDraft(selectedOptionValues: ["A"], customAnswer: " mine ")) == .text("mine"))
        #expect(UserInputAnswers.resolve(q, UserInputDraft(selectedOptionValues: ["Z", "B"])) == .text("B"))
        #expect(UserInputAnswers.resolve(q, UserInputDraft(customAnswer: "   ")) == nil)
        #expect(UserInputAnswers.resolve(question("m", multi: true), UserInputDraft(selectedOptionValues: ["B", "A", "B"])) == .values(["B", "A"]))
        #expect(UserInputAnswers.resolve(question("c", custom: false), UserInputDraft(customAnswer: "x")) == nil)
        // An initial answer makes the text literal: whitespace and empty kept.
        let literal = question("l", initial: " seed ")
        #expect(UserInputAnswers.resolve(literal, UserInputDraft(customAnswer: " edited ")) == .text(" edited "))
        #expect(UserInputAnswers.seed([literal, q], [:]) == ["l": UserInputDraft(customAnswer: " seed ")])
        var files = UserInputDraft()
        files.attachmentCount = 1
        #expect(UserInputAnswers.resolve(q, files) == .text(""))
    }

    @Test func toggleAndCustomTextInteract() {
        let single = question("s"), multi = question("m", multi: true)
        #expect(UserInputAnswers.toggle(single, UserInputDraft(selectedOptionValues: ["A"]), "B") == UserInputDraft(selectedOptionValues: ["B"], customAnswer: ""))
        #expect(UserInputAnswers.toggle(multi, UserInputDraft(selectedOptionValues: ["A"]), "A") == UserInputDraft(customAnswer: ""))
        #expect(UserInputAnswers.setCustomAnswer(UserInputDraft(selectedOptionValues: ["A"]), "x", question: single) == UserInputDraft(customAnswer: "x"))
        #expect(UserInputAnswers.setCustomAnswer(UserInputDraft(selectedOptionValues: ["A"]), " ", question: single) == UserInputDraft(selectedOptionValues: ["A"], customAnswer: " "))
        #expect(UserInputAnswers.carryDisplaced("draft  \n", " typed ") == "draft\n\ntyped")
        #expect(UserInputAnswers.carryDisplaced("", "typed") == "typed")
        #expect(UserInputAnswers.carryDisplaced("draft", "  ") == "draft")
    }

    @Test func sessionFlow() {
        let request = PendingUserInput(requestId: "r", createdAt: nil, questions: [question("a"), question("b")],
                                       responseCapability: "live", dismissible: false)
        var session = UserInputSession(request)
        session.setCustomAnswer("typed")
        #expect(session.select("A") == "typed")
        #expect(session.progress.resolvedAnswer == .text("A"))
        #expect(session.advance() == .moved)
        #expect(session.advance() == .blocked) // last question unanswered
        #expect(session.primaryLabel(compact: true, responding: false) == "Submit")
        #expect(session.primaryLabel(compact: false, responding: true) == "Submitting...")
        _ = session.select("B")
        #expect(session.advance() == .submit(["a": .text("A"), "b": .text("B")]))
        session.previous()
        #expect(session.progress.questionIndex == 0 && !session.showsPrevious)

        var gone = UserInputSession(PendingUserInput(requestId: "r", createdAt: nil, questions: [question("a")],
                                                     responseCapability: "not_resumable", dismissible: false))
        _ = gone.select("A")
        #expect(gone.advance() == .blocked && !gone.canPressPrimary)
    }
}
