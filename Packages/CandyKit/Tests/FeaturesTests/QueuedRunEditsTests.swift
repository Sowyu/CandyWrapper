import Testing
import T3Protocol
@testable import Features

struct QueuedRunEditsTests {
    @Test func editsSurviveNavigationAndSettleOnce() {
        var state = QueuedRunEdits()
        let a = ThreadId("a"), b = ThreadId("b"), run = RunId("r")
        state.begin(thread: a, run: run, text: "original")
        state.update(a, text: "changed")
        state.begin(thread: b, run: run, text: "other thread")
        #expect(state.edit(a)?.text == "changed")
        #expect(state.takeExited(a, queuedRuns: nil) == nil)
        #expect(state.takeExited(a, queuedRuns: [run]) == nil)
        #expect(state.takeExited(a, queuedRuns: [])?.text == "changed")
        #expect(state.takeExited(a, queuedRuns: []) == nil)
        #expect(state.edit(b)?.text == "other thread")
    }
    @Test func staleSaveCannotClearAReopenedEditAndKeepsItsClaim() throws {
        var state = QueuedRunEdits()
        let thread = ThreadId("t"), run = RunId("r")
        state.begin(thread: thread, run: run, text: "old")
        let saving = state.startSave(thread)
        let saved = try #require(saving)
        state.end(thread)
        state.begin(thread: thread, run: run, text: "new")
        #expect(state.isSaving(thread))
        #expect(state.startSave(thread) == nil)
        let ignored = !state.finishSave(saved, succeeded: true)
        #expect(ignored)
        #expect(state.edit(thread)?.text == "new")
        #expect(!state.isSaving(thread))
        let savingNext = state.startSave(thread)
        let next = try #require(savingNext)
        let duplicateIgnored = !state.finishSave(saved, succeeded: true)
        #expect(duplicateIgnored)
        #expect(state.isSaving(thread))
        let finished = state.finishSave(next, succeeded: true)
        #expect(finished)
        #expect(state.edit(thread) == nil)
    }
    @Test func savePausesRecoveryAndFailureResumesIt() throws {
        var state = QueuedRunEdits()
        let thread = ThreadId("t")
        state.begin(thread: thread, run: RunId("r"), text: "text")
        let saving = state.startSave(thread)
        let edit = try #require(saving)
        #expect(state.takeExited(thread, queuedRuns: []) == nil)
        let finished = state.finishSave(edit, succeeded: false)
        #expect(finished)
        #expect(state.takeExited(thread, queuedRuns: []) == edit)
    }
}
