import Foundation

/// Finds an idle socket that died without a close on the user's next input, with no timer. T3 pings every 5 s and
/// drops a socket after 15 s without a frame (client-runtime rpc/protocol.ts:10-12); CandyWrapper keeps idle wakeups at
/// zero, so it asks instead when someone is there to see the answer.
///
/// The window routes every key, click, scroll and pointer entry through `noteInput`. While the sockets are healthy
/// that is one comparison against `nextCheck`. Past it, each registered supervisor whose socket has been silent for
/// `ConnectionSupervisor.inputQuietThreshold` probes it with the silent socket check, and `nextCheck` moves to when
/// the first socket would next be silent that long. The same moment runs the route checks (`observeQuietInput`).
@MainActor
public final class InputQuietGate {
    public static let shared = InputQuietGate()

    /// `ProcessInfo.systemUptime` seconds, the clock of `NSEvent.timestamp`.
    private(set) var nextCheck: TimeInterval = 0
    private var supervisors: [ObjectIdentifier: Weak] = [:]
    private var quietObservers: [UUID: @MainActor () -> Void] = [:]
    private var pathObservers: [UUID: @MainActor () -> Void] = [:]
    let threshold: Duration

    private struct Weak { weak var supervisor: ConnectionSupervisor? }

    init(threshold: Duration = ConnectionSupervisor.inputQuietThreshold) { self.threshold = threshold }

    public func register(_ supervisor: ConnectionSupervisor) {
        supervisors[ObjectIdentifier(supervisor)] = Weak(supervisor: supervisor)
    }

    /// Runs after input that found a socket silent past the threshold: the moment to look for a better route.
    @discardableResult
    public func observeQuietInput(_ body: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); quietObservers[id] = body; return id
    }

    /// Runs when NWPathMonitor reports another network.
    @discardableResult
    public func observePathChanges(_ body: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); pathObservers[id] = body; return id
    }

    func networkPathChanged() { for o in pathObservers.values { o() } }

    /// One user input at `uptime` (`NSEvent.timestamp`).
    public func noteInput(at uptime: TimeInterval) {
        guard uptime >= nextCheck else { return }
        startCheck(at: uptime)
    }

    /// The slow path, at most once per quiet stretch per socket.
    func check(at uptime: TimeInterval) async {
        nextCheck = .infinity
        supervisors = supervisors.filter { $0.value.supervisor != nil }
        let live = supervisors.values.compactMap(\.supervisor)
        let threshold = threshold
        var soonest = threshold
        var anyQuiet = false
        for supervisor in live {
            guard let answer = await supervisor.inputAfterQuiet(threshold: threshold) else { continue }
            if answer.probed { anyQuiet = true }
            soonest = min(soonest, answer.recheckIn)
        }
        nextCheck = uptime + Double(soonest.components.seconds) + Double(soonest.components.attoseconds) / 1e18
        if anyQuiet { for o in quietObservers.values { o() } }
    }

    private func startCheck(at uptime: TimeInterval) {
        Task { await check(at: uptime) }
    }
}
