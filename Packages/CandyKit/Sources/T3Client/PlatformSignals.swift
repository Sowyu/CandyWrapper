import AppKit
import Network

/// Feeds the supervisor the events that reveal a dead socket: network path changes, system
/// wake and app activation. All are push notifications, so idle cost is zero.
final class PlatformSignals: @unchecked Sendable {
    // @unchecked: every stored property is set once in init and only read afterwards.
    private let monitor = NWPathMonitor()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(supervisor: ConnectionSupervisor) {
        monitor.pathUpdateHandler = { [weak supervisor] path in
            let online = path.status == .satisfied
            Task { await supervisor?.networkChanged(online: online) }
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
