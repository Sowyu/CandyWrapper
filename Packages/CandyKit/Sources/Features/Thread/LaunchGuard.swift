import AppKit

/// Keeps a thread that froze or crashed CandyWrapper from reopening on every launch. A ```json block with `0-100`
/// once hung the app while showing the last thread, and since launch reopened it, every launch hung again.
///
/// Two markers in the app's own defaults, so test apps with their own bundle ids keep their own:
/// - `launch.running` is written at launch and removed at a normal quit. Left behind, the last run crashed, was force
///   quit or was killed. Any such exit skips the restore once: a broken image froze the app 30 minutes after launch,
///   and reopening the thread that froze it is what locked the user out.
/// - `launch.opening` holds the thread being restored, from just before it opens until it has shown and the main
///   run loop has kept running for `settle` seconds. It only picks the notice's wording.
///
/// A force quit during a slow launch counts as unclean and skips the restore once. Cost: two writes at launch, one
/// timer and one delete after the restore, two deletes at quit.
@MainActor
public final class LaunchGuard {
    public static let shared = LaunchGuard(defaults: .standard)
    static let runningKey = "launch.running"
    static let openingKey = "launch.opening"

    public enum Previous: Equatable {
        case clean
        /// The last run did not quit normally.
        case quitUnexpectedly
        /// The last run did not survive showing this thread.
        case didNotFinishOpening(String)
    }

    /// What the last run left behind.
    public private(set) var previous: Previous = .clean
    /// Shift was held at launch: a manual way past a thread that hangs.
    public private(set) var shiftHeld = false
    private let defaults: UserDefaults
    private let settle: TimeInterval
    private var started = false
    private var opening: String?
    private var settling = false
    private var noticeTaken = false

    init(defaults: UserDefaults, settle: TimeInterval = 5) {
        self.defaults = defaults
        self.settle = settle
    }

    /// Once per launch, after the single-instance hand-off (a second instance shares the first one's defaults).
    public func begin(shiftHeld: Bool) {
        guard !started else { return }
        started = true
        self.shiftHeld = shiftHeld
        if let thread = defaults.string(forKey: Self.openingKey) { previous = .didNotFinishOpening(thread) }
        else if defaults.object(forKey: Self.runningKey) != nil { previous = .quitUnexpectedly }
        defaults.removeObject(forKey: Self.openingKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.runningKey)
    }

    /// Whether launch may reopen the last thread.
    public var restoresLastThread: Bool { previous == .clean && !shiftHeld }

    /// The notice for a restore skipped after an unclean exit, once per launch. `title` is the thread's title.
    public func takeNotice(title: String?) -> String? {
        guard !noticeTaken else { return nil }
        noticeTaken = true
        let name = title.map { "\u{201C}\($0)\u{201D}" }
        switch previous {
        case .clean: return nil
        case .didNotFinishOpening:
            return "CandyWrapper did not finish opening \(name ?? "a thread") last time, so it started on a new thread."
        case .quitUnexpectedly:
            return "CandyWrapper quit unexpectedly last time\(name.map { " with \($0) open" } ?? ""), so it started on a new thread."
        }
    }

    /// Just before launch reopens `thread`.
    public func willRestore(_ thread: String) {
        guard started, opening == nil else { return }
        opening = thread
        defaults.set(thread, forKey: Self.openingKey)
    }

    /// `thread` was laid out on screen. Once the main run loop has run `settle` seconds more, it counts as opened.
    public func shown(_ thread: String) {
        guard opening == thread, !settling else { return }
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            MainActor.assumeIsolated { self?.opened() }
        }
    }

    func opened() {
        guard opening != nil else { return }
        opening = nil
        defaults.removeObject(forKey: Self.openingKey)
    }

    /// A normal quit, from `applicationWillTerminate`.
    public func end() {
        guard started else { return }
        defaults.removeObject(forKey: Self.runningKey)
        defaults.removeObject(forKey: Self.openingKey)
    }
}
