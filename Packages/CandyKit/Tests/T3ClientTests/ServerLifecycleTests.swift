import Foundation
import Testing
@testable import T3Client
import T3Protocol

/// A manual clock: timers fire only when the test advances time.
final class ManualScheduler: LifecycleScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Duration = .zero
    private var timers: [(id: Int, deadline: Duration, tolerance: Duration, action: @Sendable () -> Void)] = []
    private var nextId = 0

    final class Handle: LifecycleTimer, @unchecked Sendable {
        let cancelAction: () -> Void
        init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
        func cancel() { cancelAction() }
    }

    func schedule(after delay: Duration, tolerance: Duration, _ action: @escaping @Sendable () -> Void) -> any LifecycleTimer {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        let id = nextId
        timers.append((id, now + delay, tolerance, action))
        return Handle { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.timers.removeAll { $0.id == id }
        }
    }

    var armed: Int { lock.lock(); defer { lock.unlock() }; return timers.count }
    var lastTolerance: Duration? { lock.lock(); defer { lock.unlock() }; return timers.last?.tolerance }

    func advance(by d: Duration) {
        lock.lock()
        now += d
        let due = timers.filter { $0.deadline <= now }
        timers.removeAll { $0.deadline <= now }
        lock.unlock()
        for t in due { t.action() }
    }
}

final class FakeServer: OwnedLocalServer, @unchecked Sendable {
    let id: Int
    private let lock = NSLock()
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(id: Int) { self.id = id }

    var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }

    func waitForExit() async {
        await withCheckedContinuation { c in
            lock.lock()
            if exited { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    func exit() {
        lock.lock()
        exited = true
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume() }
    }
}

actor Recorder {
    var launches = 0
    var handedOff: [Int] = []
    var adoptable: FakeServer?
    func handOff(_ s: FakeServer) { handedOff.append(s.id) }
    func set(adoptable: FakeServer?) { self.adoptable = adoptable }
    func adopt() -> FakeServer? { defer { adoptable = nil }; return adoptable }
    var stops: [Int] = []
    var priority: [(Int, Bool)] = []
    var running: RunningLocalServer?
    var failNextLaunch = false
    var launchGate: CheckedContinuation<Void, Never>?
    var holdLaunch = false

    func launch() async throws -> FakeServer {
        launches += 1
        if failNextLaunch { failNextLaunch = false; throw LocalServerLaunchError.notReady }
        if holdLaunch { await withCheckedContinuation { launchGate = $0 } }
        return FakeServer(id: launches)
    }
    func release() { launchGate?.resume(); launchGate = nil; holdLaunch = false }
    func stop(_ s: FakeServer) { stops.append(s.id); s.exit() }
    func setBackground(_ s: FakeServer, _ bg: Bool) { priority.append((s.id, bg)) }
    func set(running: RunningLocalServer?) { self.running = running }
    func set(failNextLaunch: Bool) { self.failNextLaunch = failNextLaunch }
    func set(holdLaunch: Bool) { self.holdLaunch = holdLaunch }
}

typealias Lifecycle = ServerLifecycle<FakeServer>

actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

struct ServerLifecycleTests {
    let scheduler = ManualScheduler()
    let rec = Recorder()

    func make(idle: Duration = .seconds(600), remote: Bool = false) -> Lifecycle {
        let rec = self.rec
        return Lifecycle(dependencies: .init(
            discover: { await rec.running },
            launch: { try await rec.launch() },
            stop: { await rec.stop($0) },
            setBackground: { s, bg in Task { await rec.setBackground(s, bg) } },
            adopt: { await rec.adopt() },
            handOff: { s in Task { await rec.handOff(s) } },
            scheduler: scheduler), idleTimeout: idle, remoteAccess: remote)
    }

    // An update quit hands the server off; the next launch adopts it and the idle rules apply again.
    @Test func updateQuitHandsOffAndTheNextLaunchAdopts() async throws {
        let old = make()
        guard case .owned(let server) = try await old.ensureRunning() else { Issue.record("not owned"); return }
        await old.update(.init(windowVisible: true, activeRuns: 1))
        await old.handOff()
        #expect(await eventually { await rec.handedOff == [server.id] })
        #expect(await rec.stops.isEmpty)
        #expect(!server.hasExited)
        #expect(await old.phase == .stopped)

        await rec.set(adoptable: server)
        let new = make()
        let adopted = try await new.ensureRunning()
        guard case .owned(let same) = adopted else { Issue.record("not adopted"); return }
        #expect(same === server)
        #expect(await rec.launches == 1, "no second server")
        await new.update(.init(activeRuns: 0))
        #expect(await new.idleTimerArmed)
        scheduler.advance(by: .seconds(600))
        #expect(await eventually { await rec.stops == [server.id] })
    }

    static func liveLookingServer() throws -> RunningLocalServer {
        let descriptor = try JSONDecoder().decode(EnvironmentDescriptor.self, from: Data(
            #"{"environmentId":"env","label":"Mac","serverVersion":"0.0.46","orchestrationProtocolVersion":2,"capabilities":{}}"#.utf8))
        // Our own pid stands in for a live server process.
        let runtime = ServerRuntimeState(version: 1, pid: getpid(), host: nil, port: 3773,
                                         origin: "http://127.0.0.1:3773", devUrl: nil, startedAt: "x", serviceManaged: true)
        return RunningLocalServer(runtime: runtime, origin: URL(string: runtime.origin)!, descriptor: descriptor)
    }

    // Rule 1
    @Test func reusesARunningServerAndNeverStopsOrReprioritizesIt() async throws {
        await rec.set(running: try Self.liveLookingServer())
        let lc = make()
        let server = try await lc.ensureRunning()
        #expect(!server.isOwned)
        #expect(await lc.phase == .running(owned: false))
        await lc.update(.init(activeRuns: 0))
        #expect(!(await lc.idleTimerArmed))
        scheduler.advance(by: .seconds(3600))
        #expect(await lc.quitDecision() == .nothingToStop)
        await lc.shutdown()
        await settle()
        #expect(await rec.launches == 0)
        #expect(await rec.stops.isEmpty)
        #expect(await rec.priority.isEmpty)
    }

    // Rule 2 and 6
    @Test func startsOnDemandOnceAndRunsInBackgroundUntilARunStarts() async throws {
        await rec.set(holdLaunch: true)
        let lc = make()
        async let a = lc.ensureRunning()
        async let b = lc.ensureRunning()
        #expect(await eventually { await rec.launchGate != nil })
        #expect(await lc.phase == .starting)
        await rec.release()
        let (sa, sb) = try await (a, b)
        #expect(sa.isOwned && sb.isOwned)
        #expect(await rec.launches == 1)
        #expect(await eventually { await rec.priority.map(\.1) == [true] })

        await lc.update(.init(windowVisible: true, windowKey: true, activeRuns: 1))
        #expect(await eventually { await rec.priority.map(\.1) == [true, false] })
        // A second run and a window change do not touch priority again.
        await lc.update(.init(windowVisible: true, activeRuns: 2))
        await lc.update(.init(windowVisible: true, activeRuns: 0))
        #expect(await eventually { await rec.priority.map(\.1) == [true, false, true] })
    }

    @Test func runsAtNormalPriorityWhileTheAppIsActive() async throws {
        let lc = make()
        _ = try await lc.ensureRunning()
        #expect(await eventually { await rec.priority.map(\.1) == [true] })
        await lc.update(.init(windowVisible: true, windowKey: true, appActive: true))
        #expect(await eventually { await rec.priority.map(\.1) == [true, false] })
        await lc.update(.init(windowVisible: true))
        #expect(await eventually { await rec.priority.map(\.1) == [true, false, true] })
    }

    @Test func aFailedLaunchLeavesItStoppedAndTheNextActionRetries() async throws {
        await rec.set(failNextLaunch: true)
        let lc = make()
        await #expect(throws: LocalServerLaunchError.self) { try await lc.ensureRunning() }
        #expect(await lc.phase == .stopped)
        #expect(try await lc.ensureRunning().isOwned)
        #expect(await rec.launches == 2)
    }

    // 570542662: a server that took the home between discovery and our start refuses ours with exit 78.
    @Test func aHomeTakenDuringOurStartIsReused() async throws {
        let rec = self.rec, other = try Self.liveLookingServer()
        let discoveries = Counter()
        let lc = Lifecycle(dependencies: .init(
            discover: { await discoveries.next() == 1 ? nil : other },
            launch: { _ = try await rec.launch(); throw LocalServerLaunchError.stateDirOwned(home: "/tmp/home") },
            stop: { await rec.stop($0) },
            setBackground: { _, _ in },
            scheduler: scheduler), idleTimeout: .seconds(600), remoteAccess: false)
        let server = try await lc.ensureRunning()
        #expect(!server.isOwned)
        #expect(await lc.phase == .running(owned: false))
        #expect(await rec.launches == 1)
        #expect(LocalServerLaunchError.stateDirOwned(home: "/h").description.hasPrefix("A T3 Code server already owns /h."))
    }

    @Test func aServerThatCantBeUsedIsNeverJoinedByOurs() async throws {
        let rec = self.rec
        let lc = Lifecycle(dependencies: .init(
            discover: { throw LocalServerDiscoveryError.unresponsive },
            launch: { try await rec.launch() },
            stop: { await rec.stop($0) },
            setBackground: { _, _ in },
            scheduler: scheduler), idleTimeout: .seconds(600), remoteAccess: false)
        await #expect(throws: LocalServerDiscoveryError.unresponsive) { try await lc.ensureRunning() }
        #expect(await lc.phase == .stopped)
        #expect(await rec.launches == 0)
    }

    // Rule 3b: idle stop, one timer per deadline
    @Test func stopsAfterIdleMinutesWithOneTimer() async throws {
        let lc = make(idle: .seconds(600))
        await lc.update(.init(windowVisible: true, windowKey: true))
        _ = try await lc.ensureRunning()
        #expect(scheduler.armed == 0)

        await lc.update(.init(windowVisible: false))
        #expect(scheduler.armed == 1)
        #expect(scheduler.lastTolerance == .seconds(60))
        // Repeated idle updates keep the same deadline instead of re-arming.
        await lc.update(.init())
        #expect(scheduler.armed == 1)
        scheduler.advance(by: .seconds(599))
        await settle()
        #expect(await rec.stops.isEmpty)
        scheduler.advance(by: .seconds(1))
        #expect(await eventually { await rec.stops == [1] })
        #expect(await eventually { await lc.phase == .stopped })
        #expect(scheduler.armed == 0)
    }

    @Test(arguments: [
        Lifecycle.Activity(windowVisible: true),
        Lifecycle.Activity(windowKey: true),
        Lifecycle.Activity(activeRuns: 1),
        Lifecycle.Activity(pendingRequests: 1),
        Lifecycle.Activity(runningTerminals: 1),
    ])
    func anyActivityCancelsTheIdleTimer(_ busy: Lifecycle.Activity) async throws {
        let lc = make()
        _ = try await lc.ensureRunning()
        await lc.update(.init())
        #expect(scheduler.armed == 1)
        scheduler.advance(by: .seconds(300))
        await lc.update(busy)
        #expect(scheduler.armed == 0)
        scheduler.advance(by: .seconds(3600))
        await lc.update(.init())
        // Idle again: a fresh full-length deadline.
        scheduler.advance(by: .seconds(599))
        await settle()
        #expect(await rec.stops.isEmpty)
        scheduler.advance(by: .seconds(1))
        #expect(await eventually { await rec.stops == [1] })
    }

    /// A hidden app with a terminal running a build and no agent run keeps its server, then idle-stops once the build ends.
    @Test func aRunningTerminalAloneKeepsTheServerUp() async throws {
        let lc = make()
        _ = try await lc.ensureRunning()
        await lc.update(.init(runningTerminals: 1))
        #expect(scheduler.armed == 0)
        scheduler.advance(by: .seconds(3600))
        await settle()
        #expect(await rec.stops.isEmpty)
        await lc.update(.init())
        #expect(scheduler.armed == 1)
        scheduler.advance(by: .seconds(600))
        #expect(await eventually { await rec.stops == [1] })
    }

    // Rule 4
    @Test func restartsTransparentlyAfterAnIdleStop() async throws {
        let lc = make(idle: .seconds(60))
        _ = try await lc.ensureRunning()
        await lc.update(.init())
        scheduler.advance(by: .seconds(60))
        #expect(await eventually { await lc.phase == .stopped })
        await lc.update(.init(windowVisible: true, windowKey: true))
        let again = try await lc.ensureRunning()
        guard case .owned(let s) = again else { Issue.record("expected owned"); return }
        #expect(s.id == 2)
        #expect(await rec.launches == 2)
    }

    @Test func rediscoversBeforeRestarting() async throws {
        let lc = make(idle: .seconds(60))
        _ = try await lc.ensureRunning()
        await lc.update(.init())
        scheduler.advance(by: .seconds(60))
        #expect(await eventually { await lc.phase == .stopped })
        // The user started T3's own service meanwhile: reuse it instead of a second server.
        await rec.set(running: try Self.liveLookingServer())
        #expect(!(try await lc.ensureRunning().isOwned))
        #expect(await rec.launches == 1)
    }

    @Test func anUnexpectedExitIsNoticedAndTheNextActionRestarts() async throws {
        let lc = make()
        guard case .owned(let s) = try await lc.ensureRunning() else { Issue.record("expected owned"); return }
        await lc.update(.init())
        s.exit()
        #expect(await eventually { await lc.phase == .stopped })
        #expect(scheduler.armed == 0)
        _ = try await lc.ensureRunning()
        #expect(await rec.launches == 2)
    }

    // Rule 5
    @Test func remoteAccessNeverIdleStops() async throws {
        let lc = make(remote: true)
        _ = try await lc.ensureRunning()
        await lc.update(.init())
        #expect(scheduler.armed == 0)
        scheduler.advance(by: .seconds(86_400))
        await lc.setRemoteAccess(false)
        #expect(scheduler.armed == 1)
        await lc.setRemoteAccess(true)
        #expect(scheduler.armed == 0)
        await settle()
        #expect(await rec.stops.isEmpty)
    }

    // Rule 3a
    @Test func quitAsksWhenARunOrRequestIsActiveThenStops() async throws {
        let lc = make()
        #expect(await lc.quitDecision() == .nothingToStop)
        _ = try await lc.ensureRunning()
        await lc.update(.init(windowVisible: true))
        #expect(await lc.quitDecision() == .stop)
        await lc.update(.init(windowVisible: true, activeRuns: 1))
        #expect(await lc.quitDecision() == .askUser)
        await lc.update(.init(windowVisible: true, pendingRequests: 1))
        #expect(await lc.quitDecision() == .askUser)
        await lc.update(.init(windowVisible: true, runningTerminals: 1))
        #expect(await lc.quitDecision() == .stop)
        await lc.shutdown()
        #expect(await rec.stops == [1])
        #expect(await lc.phase == .stopped)
        #expect(await lc.quitDecision() == .nothingToStop)
    }

    @Test func shutdownDuringAStartWaitsThenStops() async throws {
        await rec.set(holdLaunch: true)
        let lc = make()
        let start = Task { try await lc.ensureRunning() }
        #expect(await eventually { await rec.launchGate != nil })
        #expect(await lc.quitDecision() == .stop)
        let quit = Task { await lc.shutdown() }
        await rec.release()
        _ = try await start.value
        await quit.value
        #expect(await rec.stops == [1])
    }

    /// Only that the real timer fires. "A cancelled timer never fires" is Dispatch's promise, and a
    /// sleep-then-check here could only pass vacuously.
    @Test func dispatchSchedulerFires() async {
        let fired = Recorder()
        let timer = DispatchLifecycleScheduler().schedule(after: .milliseconds(10), tolerance: .milliseconds(5)) {
            Task { await fired.set(failNextLaunch: true) }
        }
        #expect(await eventually(seconds: 30) { await fired.failNextLaunch })
        timer.cancel()
    }
}

@Suite struct OrphanServerTests {
    @Test func stopsTheRecordedServerOnlyWhenItsAppIsGone() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let server = try #require(ProcessIdentity.of(sleeper.processIdentifier))
        let url = FileManager.default.temporaryDirectory.appending(path: "owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // The app that started it is still running: not an orphan.
        let me = try #require(ProcessIdentity.of(getpid()))
        try JSONEncoder().encode(LocalServerLauncher.OwnerRecord(server: server, owner: me)).write(to: url)
        await LocalServerLauncher.stopOrphan(recordedAt: url, timeout: .seconds(30))
        #expect(server.isAlive)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Same pid, different start time: that app is gone.
        let gone = ProcessIdentity(pid: getpid(), startTime: 1)
        try JSONEncoder().encode(LocalServerLauncher.OwnerRecord(server: server, owner: gone)).write(to: url)
        await LocalServerLauncher.stopOrphan(recordedAt: url, timeout: .seconds(30))
        sleeper.waitUntilExit()
        #expect(sleeper.terminationReason == .uncaughtSignal)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func leavesAHandedOffServerRunning() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let server = try #require(ProcessIdentity.of(sleeper.processIdentifier))
        let url = FileManager.default.temporaryDirectory.appending(path: "owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let gone = ProcessIdentity(pid: getpid(), startTime: 1)
        try JSONEncoder().encode(LocalServerLauncher.OwnerRecord(server: server, owner: gone, handoff: true)).write(to: url)
        await LocalServerLauncher.stopOrphan(recordedAt: url, timeout: .seconds(30))
        #expect(server.isAlive)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // The handed-off server died before anyone came back: the record goes, nothing is adopted.
        sleeper.terminate()
        sleeper.waitUntilExit()
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        let adopted = await LocalServerLauncher.adopt(recordedAt: url, home: home, identity: ClientIdentity(appVersion: "0"),
                                                      credentials: nil, configuration: { throw CancellationError() })
        #expect(adopted == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// An adopted server is launchd's child: no waitpid, its exit event is the exit.
    @Test func watchesAServerItDidNotSpawn() async throws {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 60 >/dev/null 2>&1 & echo $!"]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let identity = try #require(ProcessIdentity.of(pid))
        defer { identity.signal(SIGKILL) }
        let watcher = ChildExitWatcher(adopting: identity)
        #expect(watcher.exitStatus == nil)
        identity.signal(SIGTERM)
        #expect(await watcher.waitForExit(timeout: .seconds(30)))
    }
}
