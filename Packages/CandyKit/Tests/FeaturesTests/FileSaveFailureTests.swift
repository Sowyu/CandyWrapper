import Foundation
import Testing
@testable import Features

/// What happens to an edit in the file tab when its write fails. T3's `FileSaveCoordinator`
/// (components/files/fileSaveCoordinator.ts) keeps the edit pending and writes again on the next
/// change or flush; it never retries on its own. The app toasts the failure and keeps the text in the
/// tab's buffer (FilesController `edited`), so the user sees it and the edit stays on screen.
@MainActor
struct FileSaveFailureTests {
    /// A coordinator whose debounce never fires: each test runs the write the timer or a flush would run.
    @MainActor final class Fake {
        var writes: [String] = []
        var pending: [Bool] = []
        var results: [Bool]
        var coordinator: FileSaveCoordinator!
        init(results: [Bool]) {
            self.results = results
            coordinator = FileSaveCoordinator(debounce: 3600, persist: { [unowned self] text in
                self.writes.append(text)
                return self.results.isEmpty ? true : self.results.removeFirst()
            }, onPendingChange: { [unowned self] in self.pending.append($0) })
        }
    }

    /// A failed write keeps the edit unsaved and never reports it saved; the next flush (the tab closes
    /// or the thread changes) writes the same text again.
    @Test func failedSaveStaysPendingAndTheNextFlushWritesItAgain() async throws {
        let f = Fake(results: [false, true])
        f.coordinator.change("draft")
        await f.coordinator.persistLatest()
        #expect(f.writes == ["draft"])
        #expect(f.coordinator.hasUnsaved)
        #expect(f.pending == [true])

        f.coordinator.flush()
        try #require(await eventually { f.writes.count == 2 })
        #expect(f.writes == ["draft", "draft"])
        try #require(await eventually { f.pending.last == false })
        #expect(!f.coordinator.hasUnsaved)
    }

    /// The next keystroke after a failure writes the newest text, not the failed one.
    @Test func editAfterFailedSaveWritesTheNewestText() async {
        let f = Fake(results: [false, true])
        f.coordinator.change("a")
        await f.coordinator.persistLatest()
        f.coordinator.change("ab")
        await f.coordinator.persistLatest()
        #expect(f.writes == ["a", "ab"])
        #expect(!f.coordinator.hasUnsaved)
        #expect(f.pending.last == false)
    }

    /// `dispose` writes once and then ignores everything, as T3's does: a failed final write leaves the
    /// edit unsaved and pending is never cleared, so a caller that checks `hasUnsaved` still sees it.
    /// The app never disposes a coordinator with unsaved text; it flushes and keeps the buffer.
    @Test func failedSaveOnDisposeLeavesTheEditMarkedUnsaved() async throws {
        let f = Fake(results: [false])
        f.coordinator.change("last words")
        f.coordinator.dispose()
        try #require(await eventually { f.writes.count == 1 })
        #expect(f.coordinator.hasUnsaved)
        #expect(f.pending == [true])
        // Disposed: a later edit is not taken, so it can't be mistaken for saved either.
        f.coordinator.change("more")
        #expect(f.pending == [true])
        #expect(f.coordinator.hasUnsaved)
    }
}
