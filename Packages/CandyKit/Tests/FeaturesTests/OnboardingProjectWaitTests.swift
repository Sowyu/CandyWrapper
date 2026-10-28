import Testing
@testable import Features

@MainActor
struct OnboardingProjectWaitTests {
    @MainActor final class Deadline {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func expire() { continuation?.resume(); continuation = nil }
    }
    @Test func missingProjectStillFinishesAndLateArrivalDoesNotNavigate() async {
        let state = OnboardingProjectWait(), deadline = Deadline()
        var ready = false, results: [Bool] = []
        state.start(open: { ready }, finish: { results.append($0) }, wait: { await deadline.wait() })
        while deadline.continuation == nil { await Task.yield() }
        deadline.expire()
        while results.isEmpty { await Task.yield() }
        #expect(results == [false])
        ready = true
        state.projectChanged()
        #expect(results == [false])
    }
    @Test func arrivalFinishesOnceAndOldDeadlineCannotFinishAnotherImport() async {
        let state = OnboardingProjectWait(), old = Deadline(), next = Deadline()
        var ready = false, results: [Bool] = []
        state.start(open: { ready }, finish: { results.append($0) }, wait: { await old.wait() })
        while old.continuation == nil { await Task.yield() }
        state.start(open: { ready }, finish: { results.append($0) }, wait: { await next.wait() })
        while next.continuation == nil { await Task.yield() }
        old.expire()
        ready = true
        state.projectChanged()
        next.expire()
        await Task.yield()
        #expect(results == [true])
        state.projectChanged()
        #expect(results == [true])
    }
}
