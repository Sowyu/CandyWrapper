import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// Runs the local T3 server for the window (PROGRESS.md, "Server lifecycle"): shows the cached
/// sidebar first, reuses a running server or starts one, and stops ours when idle or on quit.
@MainActor
final class ServerController {
    private let home: URL
    private let identity: ClientIdentity
    private let credentials = CredentialStore()
    private let cache = ShellCache()
    private let remoteAccess = RemoteAccessSetting()
    private lazy var lifecycle = makeLifecycle()
    private weak var sidebar: SidebarContentView?
    private weak var window: NSWindow?
    private var session: ShellSession?
    private var sessionKey: String?
    private var environmentId: String?
    /// The newest shell for `environmentId`, from the disk cache or the last session.
    private var latest: ShellSnapshot?
    private var reported: LocalServerLifecycle.Activity?
    private var activityUpdate: Task<Void, Never>?
    private var connecting = false
    /// Mirrors the lifecycle phase for the synchronous quit check.
    private var ownsServer = false
    private var pairingDeclined = false
    private var observers: [NSObjectProtocol] = []

    init(sidebar: SidebarContentView, window: NSWindow) {
        self.sidebar = sidebar
        self.window = window
        // Development: CANDY_T3_HOME points at a sandbox home instead of ~/.t3.
        home = ProcessInfo.processInfo.environment["CANDY_T3_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? LocalServerDiscovery.defaultHome
        identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    private var lastEnvironmentKey: String { "localServer.lastEnvironmentId." + home.path }

    func start() {
        if let id = UserDefaults.standard.string(forKey: lastEnvironmentKey) { showCached(id) }
        observeWindow()
        connect()
    }

    private func showCached(_ id: String) {
        environmentId = id
        latest = cache.load(environmentId: id)?.snapshot
        if let latest { sidebar?.setSnapshot(latest, animated: false) }
    }

    // MARK: Connecting

    /// Finds or starts the server and streams its shell. Cheap to call on every wake: a live
    /// session on the same server is left alone.
    func connect() {
        guard !connecting else { return }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                guard let (origin, id, token) = try await resolveServer() else { return }
                let key = origin.absoluteString + " " + token
                guard key != sessionKey || session == nil else { return }
                if id != environmentId {
                    UserDefaults.standard.set(id, forKey: lastEnvironmentKey)
                    showCached(id)
                }
                startSession(origin: origin, token: token, key: key)
                if remoteAccess.userChoice == nil { refreshRemoteAccess(origin: origin, token: token) }
            } catch {
                present(error)
            }
        }
    }

    private func resolveServer() async throws -> (URL, String, String)? {
        switch try await lifecycle.ensureRunning() {
        case .owned(let server):
            return (server.origin, server.descriptor.environmentId, server.accessToken)
        case .reused(let server):
            let id = server.descriptor.environmentId, credentials = self.credentials
            // Off the main thread: a Keychain access prompt blocks the caller until it's answered.
            if let token = await Task.detached(operation: { try? credentials.load(environmentId: id) }).value {
                return (server.origin, id, token)
            }
            guard let token = await pair(with: server) else { return nil }
            return (server.origin, id, token)
        }
    }

    /// A server this app didn't start (T3 Code's own app or service) needs this app paired once,
    /// which adds a device record to that T3 home. Ask first, once per launch.
    private func pair(with server: RunningLocalServer) async -> String? {
        guard !pairingDeclined, let window else { return nil }
        let alert = NSAlert()
        alert.messageText = "Connect to T3 Code on this Mac?"
        alert.informativeText = "T3 Code is already running. CandyWrapper pairs with it the way a new device does. Your projects and threads stay where they are."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Not Now")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else {
            pairingDeclined = true
            return nil
        }
        do {
            guard let binary = LocalServerDiscovery.resolveBinary(home: home, path: Self.userPath) else { throw Self.notInstalled }
            let code = try await LocalServerLauncher.mintPairingCode(binary: binary, home: home, path: Self.userPath)
            let (_, result) = try await EnvironmentHTTP(baseURL: server.origin).pair(code: code, identity: identity)
            let credentials = self.credentials, id = server.descriptor.environmentId
            await Task.detached { try? credentials.save(token: result.accessToken, environmentId: id) }.value
            return result.accessToken
        } catch {
            present(error)
            return nil
        }
    }

    private func startSession(origin: URL, token: String, key: String) {
        guard let sidebar else { return }
        session?.stop()
        let session = ShellSession(baseURL: origin, token: token, sidebar: sidebar, cached: latest)
        session.onSnapshot = { [weak self] in self?.shellChanged($0) }
        session.start()
        self.session = session
        sessionKey = key
    }

    private func shellChanged(_ snapshot: ShellSnapshot) {
        latest = snapshot
        if let environmentId { Task { await cache.noteChanged(snapshot, environmentId: environmentId) } }
        reportActivity()
    }

    /// Our server stopped (idle stop, or it exited): drop the session so it doesn't retry a
    /// server that isn't coming back. The sidebar keeps the last state until the next wake.
    private func phaseChanged() async {
        let phase = await lifecycle.phase
        ownsServer = phase == .starting || phase == .running(owned: true) || phase == .stopping
        guard phase == .stopping || phase == .stopped, !connecting else { return }
        session?.stop()
        session = nil
        sessionKey = nil
    }

    // MARK: Activity

    private func observeWindow() {
        guard let window else { return }
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged() }
            })
        }
    }

    private func windowChanged() {
        reportActivity()
        // Coming back to the window restarts a server that idle-stopped.
        if let window, window.isKeyWindow || window.occlusionState.contains(.visible) { connect() }
    }

    private func reportActivity() {
        let threads = latest?.threads ?? []
        let activity = LocalServerLifecycle.Activity(
            windowVisible: window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false,
            windowKey: window?.isKeyWindow ?? false,
            activeRuns: threads.count { $0.activeRunId != nil },
            pendingRequests: threads.count { $0.pendingRuntimeRequest != nil },
            // ponytail: no terminals yet, count them when the terminal drawer lands
            runningTerminals: 0)
        guard activity != reported else { return }
        reported = activity
        // Chained so the lifecycle sees updates in order.
        let previous = activityUpdate, lifecycle = self.lifecycle
        activityUpdate = Task { await previous?.value; await lifecycle.update(activity) }
    }

    // MARK: Remote access

    var allowsRemoteAccess: Bool { remoteAccess.isOn }

    func setAllowsRemoteAccess(_ on: Bool) {
        remoteAccess.userChoice = on
        let lifecycle = self.lifecycle
        Task { await lifecycle.setRemoteAccess(on) }
    }

    /// Until the user chooses, remote access follows whether T3 Connect is linked.
    private func refreshRemoteAccess(origin: URL, token: String) {
        let setting = remoteAccess, lifecycle = self.lifecycle
        Task {
            guard let on = try? await setting.refresh(http: EnvironmentHTTP(baseURL: origin), token: token) else { return }
            await lifecycle.setRemoteAccess(on)
        }
    }

    // MARK: Quit

    /// AppKit may call this from inside a main-queue block (a Task, or `asyncAfter`), where
    /// main-actor work can't run until we return. So the decision is synchronous, the shutdown
    /// runs off the main actor, and the reply goes through the run loop.
    func shouldTerminate() -> NSApplication.TerminateReply {
        if ownsServer, let activity = reported, activity.activeRuns > 0 || activity.pendingRequests > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit while an agent is working?"
            alert.informativeText = "Quitting stops T3 Code's server on this Mac, which interrupts the running work."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        session?.stop()
        let cache = self.cache, lifecycle = self.lifecycle
        Task.detached {
            await cache.flush()
            // Stops our server; leaves a reused one alone.
            await lifecycle.shutdown()
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    // MARK: Setup

    private static let notInstalled = ConnectionFailure.blocked(.configuration, "T3 Code isn't installed on this Mac. Install it, then reopen CandyWrapper.")

    /// Apps opened from the Dock get a bare PATH, so the usual install directories follow it and
    /// `t3` and the provider CLIs resolve. The server adds its login shell's PATH on top
    /// (apps/server/src/os-jank.ts:20-35).
    private static let userPath: String = {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let usual = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return (inherited + usual).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    private func makeLifecycle() -> LocalServerLifecycle {
        let home = self.home, path = Self.userPath, notInstalled = Self.notInstalled
        let log = URL.libraryDirectory.appending(path: "Logs/CandyWrapper/t3-server.log")
        let record = URL.applicationSupportDirectory.appending(path: "CandyWrapper/owned-server.json")
        // The server's environment is built from scratch; pass T3's telemetry switch through.
        let telemetry = ProcessInfo.processInfo.environment["T3CODE_TELEMETRY_ENABLED"]
        return .live(home: home, identity: identity, credentials: credentials, configuration: {
            guard let binary = LocalServerDiscovery.resolveBinary(home: home, path: path) else { throw notInstalled }
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            var config = LocalServerConfiguration(binary: binary, home: home, path: path)
            // ponytail: append-only log, rotate it if it grows past a few MB
            config.logFile = log
            if let telemetry { config.extraEnvironment["T3CODE_TELEMETRY_ENABLED"] = telemetry }
            return config
        }, remoteAccess: remoteAccess.isOn, ownerRecord: record, onPhase: { [weak self] _ in
            Task { @MainActor in await self?.phaseChanged() }
        })
    }

    private func present(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't reach T3 Code"
        switch error {
        case let e as LocalServerLaunchError: alert.informativeText = e.description
        case let e as LocalServerDiscoveryError: alert.informativeText = e.description
        default: alert.informativeText = ConnectionFailure.classify(error).detail
        }
        alert.beginSheetModal(for: window)
    }
}
