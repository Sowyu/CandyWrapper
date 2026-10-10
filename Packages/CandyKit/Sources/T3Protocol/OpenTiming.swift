import Foundation

/// Development: with CANDY_THREAD_TIMING set, prints the stages of opening a thread to stderr as
/// `thread-timing <ms since open> <stage> <detail>`. `begin` starts a measurement at the click;
/// the stages after it come from the socket, the store and the timeline, on any thread.
/// Frames and stages print only while a measurement runs (`begin` until `end`, at most 20 s).
public enum OpenTiming {
    public static let enabled = ProcessInfo.processInfo.environment["CANDY_THREAD_TIMING"] != nil

    private struct State {
        var start: ContinuousClock.Instant?
        var seen = Set<String>()
    }

    private static let state = NSLockedBox(State())

    /// True while a thread open is being measured.
    public static var active: Bool {
        guard enabled else { return false }
        return state.with { s in
            guard let start = s.start else { return false }
            if ContinuousClock.now - start > .seconds(20) { s.start = nil; return false }
            return true
        }
    }

    public static func begin(_ detail: String) {
        guard enabled else { return }
        state.with { $0 = State(start: .now) }
        write(0, "open", detail)
    }

    /// Prints a stage. With `once`, only the first mark of that label per open prints.
    public static func mark(_ label: String, _ detail: String = "", once: Bool = false) {
        guard enabled else { return }
        let elapsed: Duration? = state.with { s in
            guard let start = s.start else { return nil }
            if once, !s.seen.insert(label).inserted { return nil }
            return ContinuousClock.now - start
        }
        guard let elapsed else { return }
        write(ms(elapsed), label, detail)
    }

    public static func end(_ label: String, _ detail: String = "") {
        guard active else { return }
        mark(label, detail)
        state.with { $0.start = nil }
    }

    /// Times `body` and returns its result; the stage line carries the duration.
    public static func measure<T>(_ label: String, _ detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        guard active else { return try body() }
        let start = ContinuousClock.now
        let result = try body()
        mark(label, String(format: "took %.2f ms", ms(ContinuousClock.now - start)) + {
            let d = detail(); return d.isEmpty ? "" : ", " + d
        }())
        return result
    }

    public static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    private static func write(_ ms: Double, _ label: String, _ detail: String) {
        let line = String(format: "thread-timing %8.1f %@ %@\n", ms, label, detail)
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// A value behind a lock, usable from any thread.
final class NSLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
