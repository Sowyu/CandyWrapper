/// The time source behind a debounce or a watchdog. `.continuous` is the real clock; tests pass
/// one they step by hand, so timing tests never depend on how busy the machine is.
public struct SleepClock: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleep: @Sendable (_ duration: Duration, _ tolerance: Duration?) async throws -> Void

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant,
                sleep: @escaping @Sendable (_ duration: Duration, _ tolerance: Duration?) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let continuous = SleepClock(now: { .now }, sleep: { try await Task.sleep(for: $0, tolerance: $1) })
}
