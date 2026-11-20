import AppKit
import Network

/// Feeds the supervisor the events that reveal a dead socket: network path changes, system
/// wake and app activation. All are push notifications, so idle cost is zero.
final class PlatformSignals: @unchecked Sendable {
    /// Posted on the main queue when a path goes from offline to online, like the browser's `online` event. Each
    /// connection's monitor posts, so observers must treat a repeat as harmless.
    static let networkOnline = NetworkSignals.online
    // @unchecked: the stored properties are set once in init, except `lastPath` and `pathSequence`, which only the
    // monitor's serial queue touches.
    private let monitor = NWPathMonitor()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// Only the monitor's queue touches these two.
    private var lastPath: PathKey?
    private var pathSequence = 0
    /// Only the monitor's queue touches it; nil until the first update, which never counts as coming back.
    private var wasOnline: Bool?

    /// Only `unsatisfied` is offline. `requiresConnection` (a VPN on demand, a cellular path that wakes on use) can
    /// carry a socket, like Chromium's `navigator.onLine`, which T3 reads (apps/web/src/connection/platform.ts:74).
    static func isOnline(_ status: NWPath.Status) -> Bool { status != .unsatisfied }

    init(supervisor: ConnectionSupervisor) {
        monitor.pathUpdateHandler = { [weak self, weak supervisor] path in
            guard let self else { return }
            let online = Self.isOnline(path.status)
            if online, wasOnline == false {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.networkOnline, object: nil) }
            }
            wasOnline = online
            let key = PathKey(path)
            let moved = PathKey.moved(from: lastPath, to: key, online: online)
            lastPath = key
            pathSequence += 1
            // Each update hops to the actor in its own task, so they can land out of order: the sequence keeps a late
            // "offline" from overriding the "online" that followed it.
            let sequence = pathSequence
            Task { await supervisor?.pathUpdated(online: online, moved: moved, sequence: sequence) }
            if moved { Task { @MainActor in InputQuietGate.shared.networkPathChanged() } }
        }
        monitor.start(queue: DispatchQueue(label: "dev.candywrapper.t3.path", qos: .utility))
        Task { @MainActor [weak supervisor] in if let supervisor { InputQuietGate.shared.register(supervisor) } }

        let workspace = NSWorkspace.shared.notificationCenter
        let app = NotificationCenter.default
        tokens = [
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak supervisor] _ in
                Task { await supervisor?.wakeup(.systemWake) }
            }),
            (app, app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak supervisor] _ in
                Task { await supervisor?.wakeup(.applicationActive) }
            }),
            (app, app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak supervisor] _ in
                Task { await supervisor?.applicationResignedActive() }
            }),
        ]
    }

    deinit {
        monitor.cancel()
        for (center, token) in tokens { center.removeObserver(token) }
    }
}

/// App-wide network signals from the connection's path monitor.
public enum NetworkSignals {
    /// A network path came back after being offline (`window` `online`).
    public static let online = Notification.Name("dev.candywrapper.network-online")
}

/// What makes one network different from another for a socket: the interfaces in use and their
/// gateways. Updates for cost or constraint flags on the same network compare equal.
// ponytail: two Wi-Fi networks with the same router address look the same; key on the SSID if that shows up
struct PathKey: Equatable {
    let interfaces: [String]
    let gateways: [String]

    init(_ path: NWPath) {
        self.init(interfaces: path.availableInterfaces.map(\.name), gateways: path.gateways.map { "\($0)" })
    }

    /// Interfaces keep the system's preference order; gateways come in any order.
    init(interfaces: [String], gateways: [String]) {
        self.interfaces = interfaces
        self.gateways = gateways.sorted()
    }

    /// Whether an online update put the socket on another network. The first update reports the
    /// network the session started on, so it isn't a move.
    static func moved(from last: PathKey?, to key: PathKey, online: Bool) -> Bool {
        online && last.map { $0 != key } == true
    }
}
