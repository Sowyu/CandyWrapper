import AppKit
import Network

/// Feeds the supervisor the events that reveal a dead socket: network path changes, system
/// wake and app activation. All are push notifications, so idle cost is zero.
final class PlatformSignals: @unchecked Sendable {
    // @unchecked: every stored property is set once in init and only read afterwards.
    private let monitor = NWPathMonitor()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// Only the monitor's queue touches it.
    private var lastPath: PathKey?

    init(supervisor: ConnectionSupervisor) {
        monitor.pathUpdateHandler = { [weak self, weak supervisor] path in
            let online = path.status == .satisfied
            let key = PathKey(path)
            // The first update reports the network the session started on.
            let moved = online && self?.lastPath.map { $0 != key } == true
            self?.lastPath = key
            Task {
                await supervisor?.networkChanged(online: online)
                if moved { await supervisor?.networkPathChanged() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.candywrapper.t3.path", qos: .utility))

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

/// What makes one network different from another for a socket: the interfaces in use and their
/// gateways. Updates for cost or constraint flags on the same network compare equal.
// ponytail: two Wi-Fi networks with the same router address look the same; key on the SSID if that shows up
struct PathKey: Equatable {
    let interfaces: [String]
    let gateways: [String]

    init(_ path: NWPath) {
        interfaces = path.availableInterfaces.map(\.name)
        gateways = path.gateways.map { "\($0)" }.sorted()
    }
}
