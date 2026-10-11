import AppKit

/// Runs work right after the current run loop turn has committed its frame, so a keystroke's
/// glyph reaches the screen before the follow-up work that does not change it.
///
/// Core Animation commits in a `beforeWaiting` observer at order 2,000,000. A one-shot observer
/// just after it queues the work on the main queue, which wakes the run loop at once; the work
/// runs on that wake-up and its own changes commit at the end of that turn. Nothing stays
/// installed while idle.
@MainActor public enum AfterCommit {
    private static var pending: [() -> Void] = []
    private static var observer: CFRunLoopObserver?

    public static func run(_ work: @escaping @MainActor () -> Void) {
        pending.append(work)
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001) { _, _ in
            MainActor.assumeIsolated {
                AfterCommit.observer = nil
                let jobs = AfterCommit.pending
                AfterCommit.pending = []
                DispatchQueue.main.async { MainActor.assumeIsolated { jobs.forEach { $0() } } }
            }
        }
        observer = o
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    }
}
