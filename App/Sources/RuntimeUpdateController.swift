import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// Independent updates for the server CandyWrapper owns. No repeating timer, automatic download,
/// or automatic install (T3 DesktopUpdates.ts:52-53,1053-1054 at 3234).
@MainActor
final class RuntimeUpdateController {
    struct Context: Equatable { var environmentId: String; var version: String }
    private let current: () -> Context?
    private let isExternal: () -> Bool
    private let restart: (String) async throws -> Void
    private weak var window: NSWindow?
    private let launchedAt = Date()
    private var lastCheck: Date?
    private var startup: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private var confirming = false
    private var observers: [() -> Void] = []
    private(set) var environmentId: String?
    private(set) var state = DesktopUpdateState(currentVersion: "", channel: .nightly, enabled: false) {
        didSet { if state != oldValue { observers.forEach { $0() } } }
    }
    var onNotice: ((String, String, Bool) -> Void)?
    var busy: Bool { task != nil || confirming || state.isRestarting }

    init(window: NSWindow, current: @escaping () -> Context?, isExternal: @escaping () -> Bool, restart: @escaping (String) async throws -> Void) {
        self.window = window; self.current = current; self.isExternal = isExternal; self.restart = restart
    }
    isolated deinit {
        startup?.cancel(); task?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }
    func observe(_ receive: @escaping () -> Void) { observers.append(receive) }
    func start() {
        guard startup == nil, activation == nil else { return }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        startup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.checkIfDue()
            self?.startup = nil
        }
        contextChanged()
    }
    func contextChanged() {
        guard !busy else { return }
        guard let context = current() else {
            // A restart temporarily has no welcome. Keep its result while reconnecting, and
            // clear it only when a connected server is known to belong to another process.
            guard isExternal() else { return }
            environmentId = nil
            state = DesktopUpdateState(currentVersion: "", channel: .nightly, enabled: false)
            return
        }
        adopt(context)
        // A slow initial server start can finish after the launch delay. Its connection completes the
        // one launch check; later connection/config changes never become an implicit polling schedule.
        if lastCheck == nil { checkIfDue() }
    }
    private func adopt(_ context: Context) {
        if environmentId != context.environmentId || state.currentVersion != context.version || !state.enabled {
            environmentId = context.environmentId
            var next = DesktopUpdateState(currentVersion: context.version,
                channel: RuntimeUpdatePolicy.channel(for: context.version) == .nightly ? .nightly : .latest, enabled: true)
            if let downloaded = ServerController.store.state().downloaded,
               let target = T3Version(downloaded), let running = T3Version(context.version), target > running,
               ServerController.store.binary(downloaded) != nil {
                next = next.onDownloadComplete(downloaded)
            }
            state = next
        }
    }
    func checkIfDue(manual: Bool = false) {
        let now = Date()
        guard let context = current(), !busy, manual || RuntimeUpdatePolicy.shouldCheck(now: now, launchedAt: launchedAt,
            lastCheck: lastCheck, owned: true, busy: false) else { return }
        lastCheck = now
        adopt(context)
        state.currentVersion = context.version
        state = state.onCheckStart(now)
        let channel = RuntimeUpdatePolicy.channel(for: context.version)
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; contextChanged() }
            do {
                let releases = try await RuntimeRelease.fetch(channel: channel)
                guard current() == context else { return }
                if let update = RuntimeUpdatePolicy.update(current: context.version, releases: releases) {
                    state = state.onUpdateAvailable(update.version, at: now)
                    if ServerController.store.state().downloaded == update.version, ServerController.store.binary(update.version) != nil {
                        state = state.onDownloadComplete(update.version)
                    }
                } else { state = state.onNoUpdate(at: now) }
            } catch {
                state = state.onCheckFailure(error.localizedDescription, at: now)
            }
        }
    }
    func request() {
        guard !busy, current()?.environmentId == environmentId else { return }
        switch DesktopUpdateLogic.buttonAction(state) {
        case .download: download()
        case .install:
            guard let target = state.downloadedVersion, let window else { return }
            confirming = true
            let copy = DesktopUpdateLogic.installConfirmationMessage(state, appName: "the server")
            ConfirmCopy.present(copy, destructive: false, in: window) { [weak self] yes in
                guard let self else { return }
                confirming = false
                if yes { install(target) }
            }
        case .none: checkIfDue(manual: true)
        }
    }
    private func download() {
        guard let target = state.availableVersion else { return }
        state = state.onDownloadStart()
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; contextChanged() }
            do {
                _ = try await ServerController.store.install(target) { [weak self] progress in
                    guard case .downloading(let received, let total?) = progress, total > 0 else { return }
                    let percent = min(100, Double(received) * 100 / Double(total))
                    Task { @MainActor in
                        guard let self, self.state.status == .downloading, self.state.shouldBroadcastProgress(percent) else { return }
                        self.state = self.state.onDownloadProgress(percent)
                    }
                }
                try ServerController.store.markDownloaded(target)
                state = state.onDownloadComplete(target)
                onNotice?("Update downloaded", "Restart the server from the update button to install it.", false)
            } catch {
                state = state.onDownloadFailure(error.localizedDescription)
                onNotice?("Could not download update", error.localizedDescription, true)
            }
        }
    }
    private func install(_ target: String) {
        guard !busy, current()?.environmentId == environmentId else { return }
        state.isRestarting = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; state.isRestarting = false }
            do {
                try await restart(target)
                var next = DesktopUpdateState(currentVersion: target, channel: state.channel, enabled: true)
                next.status = .upToDate; next.checkedAt = state.checkedAt
                state = next
            } catch {
                state = state.onInstallFailure(error.localizedDescription)
                onNotice?("Could not install update", error.localizedDescription, true)
            }
        }
    }
}
