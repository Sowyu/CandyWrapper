import Foundation

/// A one-shot timer the lifecycle can cancel.
public protocol LifecycleTimer: Sendable {
    func cancel()
}

/// Where the lifecycle gets its timers. Tests inject a manual clock.
public protocol LifecycleScheduler: Sendable {
    /// Runs `action` once, `delay` of wall time from now, give or take `tolerance`.
    func schedule(after delay: Duration, tolerance: Duration, _ action: @escaping @Sendable () -> Void) -> any LifecycleTimer
}

/// Dispatch wall-clock timers: system sleep counts toward the deadline, and the leeway lets the
/// kernel coalesce the wakeup with others.
public struct DispatchLifecycleScheduler: LifecycleScheduler {
    public init() {}

    public func schedule(after delay: Duration, tolerance: Duration, _ action: @escaping @Sendable () -> Void) -> any LifecycleTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(wallDeadline: .now() + delay.timeInterval, repeating: .never, leeway: .milliseconds(Int(tolerance.timeInterval * 1000)))
        timer.setEventHandler(handler: action)
        timer.resume()
        return Timer(source: timer)
    }

    private final class Timer: LifecycleTimer, @unchecked Sendable {
        // @unchecked: DispatchSource is thread safe; the reference never changes.
        let source: DispatchSourceTimer
        init(source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (s, atto) = components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }
}

/// A server the lifecycle started and may stop.
public protocol OwnedLocalServer: AnyObject, Sendable {
    func waitForExit() async
}

extension LaunchedLocalServer: OwnedLocalServer {}

/// Decides when the local server runs (product rules 1 to 6 in PROGRESS.md and the M3 brief):
///
/// 1. Reuse a server already running for the home; never stop or reprioritize it.
/// 2. Otherwise start one on demand.
/// 3. Stop ours on quit (ask first if a run or request is active) and after `idleTimeout` with
///    no visible or key window, no runs, no pending requests and no running terminals.
/// 4. `ensureRunning()` restarts it when the user acts.
/// 5. With remote access on, never idle-stop.
/// 6. Ours runs at background priority while no run is active.
///
/// No polling: one timer per idle deadline, armed when the app goes idle and cancelled when
/// anything wakes it.
public actor ServerLifecycle<Owned: OwnedLocalServer> {
    public struct Activity: Sendable, Equatable {
        public var windowVisible: Bool
        public var windowKey: Bool
        public var activeRuns: Int
        /// Approvals and user-input questions waiting on the user.
        public var pendingRequests: Int
        public var runningTerminals: Int

        public init(windowVisible: Bool = false, windowKey: Bool = false, activeRuns: Int = 0,
                    pendingRequests: Int = 0, runningTerminals: Int = 0) {
            self.windowVisible = windowVisible
            self.windowKey = windowKey
            self.activeRuns = activeRuns
            self.pendingRequests = pendingRequests
            self.runningTerminals = runningTerminals
        }

        public var isIdle: Bool {
            !windowVisible && !windowKey && activeRuns == 0 && pendingRequests == 0 && runningTerminals == 0
        }
    }

    public enum Server: Sendable {
        case reused(RunningLocalServer)
        case owned(Owned)

        public var isOwned: Bool { if case .owned = self { true } else { false } }
    }

    public enum Phase: Sendable, Equatable {
        case stopped, starting, stopping
        case running(owned: Bool)
    }

    public enum QuitDecision: Sendable, Equatable {
        /// Nothing of ours is running.
        case nothingToStop
        /// Stop without asking.
        case stop
        /// A run is active or a request is pending: ask the user, then call `shutdown()`.
        case askUser
    }

    public struct Dependencies: Sendable {
        /// Nil means nobody else runs a server, so start ours. Throws when one exists but can't
        /// be used; starting ours then would mean two servers on one home.
        public var discover: @Sendable () async throws -> RunningLocalServer?
        public var launch: @Sendable () async throws -> Owned
        public var stop: @Sendable (Owned) async -> Void
        public var setBackground: @Sendable (Owned, Bool) -> Void
        public var scheduler: any LifecycleScheduler
        public var onPhase: @Sendable (Phase) -> Void

        public init(discover: @escaping @Sendable () async throws -> RunningLocalServer?,
                    launch: @escaping @Sendable () async throws -> Owned,
                    stop: @escaping @Sendable (Owned) async -> Void,
                    setBackground: @escaping @Sendable (Owned, Bool) -> Void,
                    scheduler: any LifecycleScheduler = DispatchLifecycleScheduler(),
                    onPhase: @escaping @Sendable (Phase) -> Void = { _ in }) {
            self.discover = discover
            self.launch = launch
            self.stop = stop
            self.setBackground = setBackground
            self.scheduler = scheduler
            self.onPhase = onPhase
        }
    }

    private let deps: Dependencies
    public private(set) var idleTimeout: Duration
    public private(set) var remoteAccess: Bool
    public private(set) var activity = Activity()
    public private(set) var phase: Phase = .stopped { didSet { if phase != oldValue { deps.onPhase(phase) } } }
    public private(set) var server: Server?
    /// What we last applied to our server, so transitions only touch the kernel once.
    public private(set) var isBackground: Bool?

    private var startTask: Task<Server, any Error>?
    private var stopTask: Task<Void, Never>?
    private var idleTimer: (any LifecycleTimer)?
    private var idleGeneration = 0

    public init(dependencies: Dependencies, idleTimeout: Duration = .seconds(600), remoteAccess: Bool = false) {
        deps = dependencies
        self.idleTimeout = idleTimeout
        self.remoteAccess = remoteAccess
    }

    /// Whether the idle timer is armed. For tests and diagnostics.
    public var idleTimerArmed: Bool { idleTimer != nil }

    /// Returns the running server, reusing or starting one. Concurrent callers share one start.
    public func ensureRunning() async throws -> Server {
        if case .reused(let running) = server, !LocalServerDiscovery.isProcessAlive(running.runtime.pid) {
            server = nil
            phase = .stopped
        }
        if let server { return server }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.start() }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    public func update(_ activity: Activity) {
        self.activity = activity
        applyPriority()
        reevaluateIdle()
    }

    public func setRemoteAccess(_ on: Bool) {
        remoteAccess = on
        reevaluateIdle()
    }

    public func setIdleTimeout(_ timeout: Duration) {
        idleTimeout = timeout
        cancelIdleTimer()
        reevaluateIdle()
    }

    public func quitDecision() -> QuitDecision {
        let ours = server?.isOwned == true || startTask != nil
        guard ours else { return .nothingToStop }
        return activity.activeRuns > 0 || activity.pendingRequests > 0 ? .askUser : .stop
    }

    /// App quit: stops our server (a pending start finishes first). Leaves a reused one alone.
    public func shutdown() async {
        cancelIdleTimer()
        if let startTask { _ = try? await startTask.value }
        await stopOwned()
    }

    // MARK: - Internals

    private func start() async throws -> Server {
        if let stopTask { await stopTask.value }
        phase = .starting
        let found: RunningLocalServer?
        do {
            found = try await deps.discover()
        } catch {
            phase = .stopped
            throw error
        }
        if let running = found {
            let s = Server.reused(running)
            server = s
            phase = .running(owned: false)
            return s
        }
        let owned: Owned
        do {
            owned = try await deps.launch()
        } catch {
            phase = .stopped
            throw error
        }
        server = .owned(owned)
        isBackground = nil
        phase = .running(owned: true)
        Task { [weak self] in
            await owned.waitForExit()
            await self?.ownedExited(owned)
        }
        applyPriority()
        reevaluateIdle()
        return .owned(owned)
    }

    private func ownedExited(_ owned: Owned) {
        guard case .owned(let current) = server, current === owned else { return }
        server = nil
        isBackground = nil
        cancelIdleTimer()
        phase = .stopped
    }

    private func stopOwned() async {
        if let stopTask { await stopTask.value; return }
        guard let current = server else { return }
        guard case .owned(let owned) = current else {
            server = nil
            phase = .stopped
            return
        }
        server = nil
        isBackground = nil
        cancelIdleTimer()
        phase = .stopping
        let task = Task { await deps.stop(owned) }
        stopTask = task
        await task.value
        stopTask = nil
        if phase == .stopping { phase = .stopped }
    }

    private func applyPriority() {
        guard case .owned(let owned) = server else { return }
        let background = activity.activeRuns == 0
        guard background != isBackground else { return }
        isBackground = background
        deps.setBackground(owned, background)
    }

    private func reevaluateIdle() {
        let shouldArm = server?.isOwned == true && !remoteAccess && activity.isIdle && stopTask == nil
        guard shouldArm else { cancelIdleTimer(); return }
        guard idleTimer == nil else { return }
        idleGeneration += 1
        let generation = idleGeneration
        // A minute late is fine for a 10-minute deadline; the leeway lets the wakeup coalesce.
        let tolerance = min(.seconds(60), idleTimeout / 10)
        idleTimer = deps.scheduler.schedule(after: idleTimeout, tolerance: tolerance) { [weak self] in
            Task { await self?.idleDeadline(generation) }
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
        idleGeneration += 1
    }

    private func idleDeadline(_ generation: Int) async {
        guard generation == idleGeneration, idleTimer != nil else { return }
        idleTimer = nil
        guard server?.isOwned == true, !remoteAccess, activity.isIdle else { return }
        await stopOwned()
    }
}

/// The production lifecycle: discovery and launch against a T3 home.
public typealias LocalServerLifecycle = ServerLifecycle<LaunchedLocalServer>

extension ServerLifecycle where Owned == LaunchedLocalServer {
    /// Wires discovery and the launcher for `home`. `configuration` is evaluated at each start,
    /// so a runtime update between starts picks up the new binary. `ownerRecord` is where the
    /// app remembers the server it started (`LocalServerLauncher.OwnerRecord`).
    public static func live(home: URL, identity: ClientIdentity, credentials: CredentialStore?,
                            configuration: @escaping @Sendable () throws -> LocalServerConfiguration,
                            idleTimeout: Duration = .seconds(600), remoteAccess: Bool, ownerRecord: URL? = nil,
                            onPhase: @escaping @Sendable (Phase) -> Void = { _ in }) -> ServerLifecycle {
        ServerLifecycle(dependencies: Dependencies(
            discover: {
                if let ownerRecord { await LocalServerLauncher.stopOrphan(recordedAt: ownerRecord) }
                return try await LocalServerDiscovery.discover(home: home)
            },
            launch: {
                let server = try await LocalServerLauncher.launch(try configuration(), identity: identity, credentials: credentials)
                if let ownerRecord { LocalServerLauncher.recordOwnership(of: server, at: ownerRecord) }
                return server
            },
            stop: {
                await LocalServerLauncher.stop($0)
                if let ownerRecord { try? FileManager.default.removeItem(at: ownerRecord) }
            },
            setBackground: { LocalServerLauncher.setBackground($1, server: $0) },
            onPhase: onPhase),
            idleTimeout: idleTimeout, remoteAccess: remoteAccess)
    }
}
