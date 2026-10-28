import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// Runs the local T3 server for the window (PROGRESS.md, "Server lifecycle"): shows the cached
/// sidebar first, reuses a running server or starts one, and stops ours when idle or on quit. Its
/// session is the primary environment in `Environments`, platform-managed like T3's.
@MainActor
final class ServerController {
    weak var recoveryUpdater: UpdateController?
    private var lastRecoveryFailure: Date?
    private var recoveryDismissed = false
    private let home: URL
    private let identity: ClientIdentity
    private let credentials = CredentialStore()
    private var cache: ShellCache { environments.cache }
    private let remoteAccess = RemoteAccessSetting()
    private lazy var lifecycle = makeLifecycle()
    private let environments: Environments
    private weak var window: NSWindow?
    private var session: ShellSession?
    private var sessionKey: String?
    private var environmentId: String?
    /// The newest shell for `environmentId`, from the disk cache or the last session.
    private var latest: ShellSnapshot?
    /// `latest` came from the live session, not the disk cache.
    private var latestIsLive = false
    private var reported: LocalServerLifecycle.Activity?
    /// Terminals running a subprocess in an environment; set by the app once the terminal controller exists.
    var runningTerminals: ((String) -> Int)?
    private var activityUpdate: Task<Void, Never>?
    private var connecting = false
    private var connectTask: Task<Void, Never>?
    /// While T3's server on this Mac is up but silent (it migrates its database after an update) or its
    /// service is restarting it, connecting retries on its own, backing off to 30 s, and says so once.
    /// Nothing retries while the window is hidden; showing it connects at once (`windowChanged`).
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(2)
    private var waitingAlert: NSAlert?
    /// While `updateOwnRuntime` swaps the runtime, nothing else starts a server on the home: not before its
    /// database backup is taken, and not while a failed version's restore runs.
    private var updatingRuntime = false
    /// Mirrors the lifecycle phase for the synchronous quit check: our own server is up.
    private var ownsServer = false
    private var pairingDeclined = false
    private var observers: [NSObjectProtocol] = []

    init(environments: Environments, window: NSWindow) {
        self.environments = environments
        self.window = window
        home = Self.home
        identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    private var lastEnvironmentKey: String { Self.lastEnvironmentKey(home) }
    private static func lastEnvironmentKey(_ home: URL) -> String { "localServer.lastEnvironmentId." + home.path }

    /// Development: CANDY_T3_HOME points at a sandbox home instead of ~/.t3.
    /// A test build relaunched by its updater gets no environment; its own defaults can name the home
    /// (`defaults write <test bundle id> CandyT3Home <path>`), so it never falls back to ~/.t3.
    private static var home: URL {
        let development = ProcessInfo.processInfo.environment["CANDY_T3_HOME"]
            ?? (AppDelegate.isTestBuild ? UserDefaults.standard.string(forKey: "CandyT3Home") : nil)
        return development.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? LocalServerDiscovery.defaultHome
    }

    private static var prefetched: ShellCache.Prefetch?

    /// Starts reading the last environment's cached sidebar at the top of launch; `start` picks it up.
    static func prefetchCachedSidebar() {
        guard let id = UserDefaults.standard.string(forKey: lastEnvironmentKey(home)) else { return }
        prefetched = ShellCache().prefetch(environmentId: id)
    }

    /// The environment is the server this app started, not T3's service or desktop app.
    func ownsLocalServer(_ id: String) -> Bool { ownsServer && id == environmentId }

    func start() {
        if let id = UserDefaults.standard.string(forKey: lastEnvironmentKey) { showCached(id) }
        observeWindow()
        connect()
    }

    private func showCached(_ id: String) {
        environmentId = id
        let prefetch = Self.prefetched
        Self.prefetched = nil
        latest = (prefetch?.environmentId == id ? prefetch?.take() : cache.load(environmentId: id))?.snapshot
        latestIsLive = false
        environments.showCachedPrimary(id, latest)
        if latest != nil { LaunchTiming.mark("cached sidebar") }
    }

    // MARK: Connecting

    /// Finds or starts the server and streams its shell. Cheap to call on every wake: a live
    /// session on the same server is left alone.
    func connect() {
        guard !connecting, !updatingRuntime else { return }
        connecting = true
        connectTask = Task {
            defer { connecting = false }
            do {
                guard let (origin, descriptor, token) = try await resolveServer() else { return }
                LaunchTiming.mark("server resolved")
                let id = descriptor.environmentId
                let key = origin.absoluteString + " " + token
                guard key != sessionKey || session == nil else { return }
                if id != environmentId {
                    UserDefaults.standard.set(id, forKey: lastEnvironmentKey)
                    showCached(id)
                }
                startSession(origin: origin, token: token, key: key)
                environments.setPrimaryDescriptor(descriptor)
                if remoteAccess.userChoice == nil { refreshRemoteAccess(origin: origin, token: token) }
            } catch let error as LocalServerDiscoveryError {
                if waitingAlert == nil { waitingAlert = present(error) }
                scheduleRetry()
            } catch {
                present(error)
            }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(30))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let window = self.window, window.occlusionState.contains(.visible) else { return }
            self.connect()
        }
    }

    /// The server answered: the backoff resets and the "keeps trying" alert closes by itself.
    private func stopWaiting() {
        recoveryDismissed = false
        retryTask?.cancel()
        retryTask = nil
        retryDelay = .seconds(2)
        if let alert = waitingAlert, let window, alert.window.sheetParent === window { window.endSheet(alert.window) }
        waitingAlert = nil
    }

    private func resolveServer() async throws -> (URL, EnvironmentDescriptor, String)? {
        try await finishPendingRestore()
        let server = try await lifecycle.ensureRunning()
        // It answered: before any pairing sheet, which would queue behind the "keeps trying" alert.
        stopWaiting()
        switch server {
        case .owned(let server):
            return (server.origin, server.descriptor, server.accessToken)
        case .reused(let server):
            let id = server.descriptor.environmentId, credentials = self.credentials
            // Off the main thread: a Keychain access prompt blocks the caller until it's answered.
            if let token = await Task.detached(operation: { try? credentials.load(environmentId: id) }).value {
                return (server.origin, server.descriptor, token)
            }
            guard let token = await pair(with: server) else { return nil }
            return (server.origin, server.descriptor, token)
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
            guard let binary = LocalServerDiscovery.resolveBinary(home: home, path: Self.userPath) ?? Self.store.active()?.binary else { throw Self.notInstalled }
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
        guard let environmentId else { return }
        session?.stop()
        let session = ShellSession(environmentId: environmentId, baseURL: origin, token: token, cached: latest)
        session.onSnapshot = { [weak self] in self?.shellChanged($0) }
        self.session = session
        sessionKey = key
        environments.setPrimary(session, environmentId: environmentId)
    }

    private func shellChanged(_ snapshot: ShellSnapshot) {
        latest = snapshot
        latestIsLive = true
        LaunchTiming.mark("live sidebar")
        if let environmentId { Task { await cache.noteChanged(snapshot, environmentId: environmentId) } }
        reportActivity()
    }

    /// Our server stopped (idle stop, or it exited): drop the session so it doesn't retry a
    /// server that isn't coming back. The sidebar keeps the last state until the next wake.
    private func phaseChanged() async {
        let phase = await lifecycle.phase
        ownsServer = phase == .running(owned: true)
        // The started server ran its migrations: raise this home's floor and note how far that version goes.
        if ownsServer, !updatingRuntime, let version = Self.startingVersion {
            Self.startingVersion = nil
            let home = self.home
            Task.detached { Self.records.recordStart(version, home: home, migration: HomeRecords.databaseMigration(home: home)) }
        }
        guard phase == .stopping || phase == .stopped, !connecting else { return }
        latestIsLive = false
        session?.stop()
        session = nil
        sessionKey = nil
        environments.setPrimary(nil, environmentId: nil)
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
        // The server leaves background priority while the app is frontmost (ServerLifecycle rule 6).
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportActivity() }
            })
        }
    }

    private func windowChanged() {
        reportActivity()
        // Coming back to the window restarts a server that idle-stopped.
        if let window, window.isKeyWindow || window.occlusionState.contains(.visible) { connect() }
    }

    /// Call when the inputs change; an unchanged report is dropped.
    func reportActivity() {
        let threads = latest?.threads ?? []
        let activity = LocalServerLifecycle.Activity(
            windowVisible: window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false,
            windowKey: window?.isKeyWindow ?? false,
            appActive: NSApp.isActive,
            activeRuns: threads.count { $0.activeRunId != nil },
            pendingRequests: threads.count { $0.pendingRuntimeRequest != nil },
            // Only our own server's environment: other environments' terminals don't keep it up.
            runningTerminals: environmentId.map { runningTerminals?($0) ?? 0 } ?? 0)
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
    ///
    /// A quit that installs an update (`installingUpdate`) hands our server off instead of stopping
    /// it: its runs go on, and the next launch adopts it. A normal quit stops it, and asks first only
    /// when that would stop something: our own server (not one we reused) with a run or a request
    /// on this Mac's environment. Remote and T3 Connect environments never count.
    func shouldTerminate(installingUpdate: Bool = false, asked: Bool = false) -> NSApplication.TerminateReply {
        if !installingUpdate, !asked, quitStopsLocalWork {
            let alert = NSAlert()
            alert.messageText = "Quit while an agent is working?"
            alert.informativeText = "Quitting stops T3 Code's server on this Mac, which interrupts the running work."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        environments.stopAll()
        let cache = self.cache, lifecycle = self.lifecycle
        Task.detached {
            await cache.flush()
            // Stops our server, or hands it off for an update; leaves a reused one alone.
            if installingUpdate { await lifecycle.handOff() } else { await lifecycle.shutdown() }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    var quitStopsLocalWork: Bool {
        guard ownsServer, latestIsLive, let threads = latest?.threads else { return false }
        return threads.contains { $0.activeRunId != nil || $0.pendingRuntimeRequest != nil }
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

    // MARK: Runtimes

    /// CandyWrapper's own runtimes. `CANDY_RUNTIMES` points a development build at another folder.
    nonisolated static let store: RuntimeStore = ProcessInfo.processInfo.environment["CANDY_RUNTIMES"]
        .map { RuntimeStore(root: URL(filePath: $0, directoryHint: .isDirectory)) } ?? .standard
    nonisolated static var records: HomeRecords { HomeRecords(file: store.root.appending(path: "homes.json")) }
    /// The version the last start chose, recorded once that server is up.
    private nonisolated(unsafe) static var startingVersion: String?
    /// Shows install progress; set by the app.
    var onInstallProgress: ((String, RuntimeStore.Progress?) -> Void)?
    var onRuntimeRecovery: ((String) -> Void)?

    /// The T3 Code desktop app's version, when it is installed. It runs its own server on `~/.t3`.
    nonisolated static func desktopAppVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The runtime a start uses (docs/decisions.md, 2026-10-14): T3's installed runtime when newer than
    /// ours, else ours, installing it on first need; never one older than what already used the home.
    nonisolated static func runtime(home: URL, development: Bool, path: String,
                                    progress: @escaping @Sendable (String, RuntimeStore.Progress?) -> Void) async throws -> URL {
        let others = home.standardizedFileURL == LocalServerDiscovery.defaultHome.standardizedFileURL ? [desktopAppVersion()].compactMap { $0 } : []
        let floor = records.floor(home: home, others: others)
        guard let wanted = T3Version(ServerVersionSkewLogic.clientVersion) else { throw ConnectionFailure.blocked(.configuration, "This build names no T3 version to run.") }
        let t3 = LocalServerDiscovery.installedRuntime(home: home)
        // A development home (the sandbox) may run the `t3` on PATH that scripts/run-app links, without a download.
        if development, t3 == nil, store.active() == nil, let binary = LocalServerDiscovery.resolveBinary(home: home, path: path) {
            startingVersion = nil
            return binary
        }
        let (version, binary): (T3Version, URL)
        switch RuntimeChoice.decide(t3: t3, ours: store.active(), wanted: wanted, floor: floor) {
        case .t3(let v, let b), .ours(let v, let b): (version, binary) = (v, b)
        case .install(let v):
            progress(v.raw, .downloading(received: 0, total: nil))
            defer { progress(v.raw, nil) }
            let b: URL
            do { b = try await store.install(v.raw) { progress(v.raw, $0) } } catch {
                throw ConnectionFailure.blocked(.configuration, "Could not install T3 Code \(v) for CandyWrapper: \(error)")
            }
            try store.activate(v.raw)
            (version, binary) = (v, b)
        }
        if let refusal = records.refusal(candidate: version, home: home, floor: floor, migration: HomeRecords.databaseMigration(home: home)) {
            throw ConnectionFailure.blocked(.configuration, refusal)
        }
        startingVersion = version.raw
        return binary
    }

    /// The Restart button for our own server: trial the verified download and restore on failure.
    /// Guarded the way T3's service launcher guards an update (serviceLauncher.ts, 570542662, 3417bc385):
    /// a database backup that won't fit refuses the update before the server stops, the database is
    /// snapshotted while no server runs, and a version that fails to start puts the snapshot back and
    /// starts the previous version again.
    func updateOwnRuntime(to target: String, onStage: @escaping @MainActor (ServerUpdateStage) -> Void) async throws {
        guard ownsServer, !updatingRuntime else { throw RuntimeTrial.Failure("CandyWrapper no longer owns this server.") }
        guard Self.store.binary(target) != nil else { throw RuntimeTrial.Failure("Download the update before restarting.") }
        updatingRuntime = true
        defer {
            Self.startingVersion = nil
            updatingRuntime = false
            connect()
        }
        await connectTask?.value
        let lifecycle = self.lifecycle, home = self.home, identity = self.identity
        let directory = backupDirectory
        onStage(.resuming)
        try await Task.detached {
            try await RuntimeTrial.apply(store: Self.store, home: home, target: target, backupDirectory: directory,
                stop: { await lifecycle.shutdown() },
                startAndConnect: {
                    guard case .owned(let server) = try await lifecycle.ensureRunning() else {
                        throw RuntimeTrial.Failure("Another process started the server.")
                    }
                    guard server.descriptor.serverVersion == target else {
                        throw RuntimeTrial.Failure("The server started on \(server.descriptor.serverVersion) instead of \(target).")
                    }
                    try await RuntimeTrial.verify(server, identity: identity)
                },
                unowned: {
                    LocalServerDiscovery.ownerLockHolder(home: home) == nil && !LocalServerDiscovery.runtimeProcessAlive(home: home)
                })
        }.value
        if let version = Self.startingVersion {
            await Task.detached { Self.records.recordStart(version, home: home, migration: HomeRecords.databaseMigration(home: home)) }.value
        }
    }

    /// The runtime a failed update goes back to: our previous one, or with none, T3's own.
    nonisolated private static func goBack(to previous: String?) throws {
        if let previous { try store.activate(previous) } else { try store.deactivate() }
    }

    private var backupDirectory: URL {
        Self.store.root.appending(path: "db-backup/" + Self.ownerRecordName(home: home), directoryHint: .isDirectory)
    }

    /// A restore that failed or was cut off after an update runs again, and goes back to the runtime from
    /// before, before any server starts on the home, as T3's launcher does (`databaseRestorePending`,
    /// serviceLauncher.ts:580-583). A server another app started meanwhile keeps the database it has
    /// (`#idleWhileStateDirOwned`). Until the backup is gone, no server starts.
    // ponytail: the marker can't tell whether another app's server wrote to the home while CandyWrapper wasn't
    // running, so a crash in the moment between a finished restore and the marker's removal, followed by another
    // app writing, would restore over that; stamp the restored files' identity in the marker if anyone hits it
    private func finishPendingRestore() async throws {
        guard let backup = DatabaseBackup.pending(database: DatabaseBackup.database(home: home), in: backupDirectory) else { return }
        updatingRuntime = true
        defer { updatingRuntime = false; Self.startingVersion = nil }
        let home = self.home
        // A crash may leave our trial process alive. Adopt and verify it before deciding whether
        // its database should be restored. A service owned by another app remains untouched.
        if LocalServerDiscovery.ownerLockHolder(home: home) != nil || LocalServerDiscovery.runtimeProcessAlive(home: home) {
            let running = try await lifecycle.ensureRunning()
            switch running {
            case .owned(let server):
                do {
                    try await RuntimeTrial.verify(server, identity: identity)
                    try backup.discard()
                    let version = server.descriptor.serverVersion
                    await Task.detached { Self.records.recordStart(version, home: home, migration: HomeRecords.databaseMigration(home: home)) }.value
                    return
                } catch {
                    await lifecycle.shutdown()
                }
            case .reused:
                try backup.discard()
                onRuntimeRecovery?("Another server took ownership. CandyWrapper kept its current data and did not roll it back.")
                return
            }
        }
        let failure = await Task.detached { () -> String? in
            do {
                guard LocalServerDiscovery.ownerLockHolder(home: home) == nil, !LocalServerDiscovery.runtimeProcessAlive(home: home) else {
                    return "Another server owns the database."
                }
                try backup.restore()
                try Self.goBack(to: backup.previousRuntime)
                try backup.discard()
                return nil
            } catch { return error.localizedDescription }
        }.value
        if let failure {
            throw ConnectionFailure.blocked(.configuration, "Could not put back the database saved before a T3 Code update: \(failure). The copy is in \(backup.directory.path). CandyWrapper starts no server on this Mac until it is back.")
        }
        onRuntimeRecovery?("CandyWrapper restored the database saved before the interrupted update and went back to the previous runtime.")
    }

    private func makeLifecycle() -> LocalServerLifecycle {
        let home = self.home, path = Self.userPath
        // A development run that names a runtime folder tests the real install, so it skips the PATH shortcut.
        let environment = ProcessInfo.processInfo.environment
        let development = (environment["CANDY_T3_HOME"] != nil || AppDelegate.isTestBuild) && environment["CANDY_RUNTIMES"] == nil
        let log = URL.libraryDirectory.appending(path: "Logs/CandyWrapper/t3-server.log")
        // One record per home, so test builds on other homes never adopt or stop each other's server.
        let record = URL.applicationSupportDirectory.appending(path: "CandyWrapper/" + Self.ownerRecordName(home: home))
        // The server's environment is built from scratch; pass T3's telemetry switch through.
        let telemetry = ProcessInfo.processInfo.environment["T3CODE_TELEMETRY_ENABLED"]
        let progress: @Sendable (String, RuntimeStore.Progress?) -> Void = { [weak self] version, p in
            Task { @MainActor in self?.onInstallProgress?(version, p) }
        }
        return .live(home: home, identity: identity, credentials: credentials, configuration: {
            let binary = try await Self.runtime(home: home, development: development, path: path, progress: progress)
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

    static func ownerRecordName(home: URL) -> String {
        guard home.standardizedFileURL.path != LocalServerDiscovery.defaultHome.standardizedFileURL.path else { return "owned-server.json" }
        // FNV-1a of the path: stable across launches, unlike `hashValue`.
        let hash = home.standardizedFileURL.path.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return "owned-server-\(String(hash, radix: 16)).json"
    }

    @discardableResult
    private func present(_ error: Error) -> NSAlert? {
        guard let window, !recoveryDismissed else { return nil }
        if let waitingAlert { return waitingAlert }
        let alert = NSAlert()
        alert.messageText = error is LocalServerLaunchError ? "CandyWrapper failed to start" : "CandyWrapper could not load"
        let detail: String
        switch error {
        case let e as LocalServerLaunchError: detail = e.description
        case let e as LocalServerDiscoveryError: detail = e.description
        default: detail = ConnectionFailure.classify(error).detail
        }
        alert.informativeText = String(StartupRecovery.redacted(detail).prefix(600))
        alert.addButton(withTitle: "Try again")
        alert.addButton(withTitle: "Close")
        let now = Date()
        let repeated = StartupRecovery.repeats(previous: lastRecoveryFailure, now: now)
        lastRecoveryFailure = now
        let runtime = Self.store.active()
        let installed = LocalServerDiscovery.installedRuntime(home: home)
        let launcher = runtime?.binary ?? installed?.1
        let command = StartupRecovery.triageCommand(launcher: launcher?.path, home: home.path,
                                                    userHome: NSHomeDirectory(), path: Self.userPath)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let report = StartupRecovery.report(error, version: version, runtimeVersion: runtime?.version.raw ?? installed?.0.raw, now: now)
        let recovery = StartupRecoveryView(command: command, report: report, expanded: repeated)
        recovery.onResize = { [weak alert] in alert?.layout() }
        recovery.onUpdate = { [weak self, weak recovery] action in
            guard let updater = self?.recoveryUpdater else { return }
            Task { @MainActor in
                recovery?.setUpdateError(nil)
                switch action {
                case .download:
                    let result = await updater.download()
                    if !result.completed { recovery?.setUpdateError("The update download failed. Try Download update again.") }
                case .install:
                    _ = await updater.install()
                    recovery?.setUpdateError("The update install failed. Try Restart to update again.")
                case .downloading: break
                }
            }
        }
        recoveryUpdater?.observe { [weak recovery, weak updater = recoveryUpdater] in recovery?.setUpdateState(updater?.state) }
        alert.accessoryView = recovery
        waitingAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self else { return }
            if self.waitingAlert === alert { self.waitingAlert = nil }
            // Closing recovery must not reopen it on every automatic connection retry.
            if response == .alertSecondButtonReturn { self.recoveryDismissed = true }
            if response == .alertFirstButtonReturn {
                self.retryTask?.cancel()
                self.connect()
            }
        }
        return alert
    }
}
