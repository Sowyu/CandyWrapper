import AppKit
import Sparkle
import DesignSystem
import Features

/// The app updater: T3's `DesktopUpdates` service (apps/desktop/src/updates/DesktopUpdates.ts) and its state
/// machine (updateMachine.ts, ported in `DesktopUpdateState`) on Sparkle 2. Sparkle checks, downloads,
/// verifies the EdDSA signatures of the feed and the archive, swaps the bundle and relaunches; this class
/// is its user driver, so nothing of Sparkle's own UI ever shows. Only GitHub Releases of Sowyu/CandyWrapper
/// feed it (`SUFeedURL`, docs/research/m9-updater-2026-10-11.md).
///
/// T3's two clicks map onto Sparkle's two replies: "Download" answers a found update with `.install`, which
/// downloads and extracts it; "Restart" answers `showReadyToInstallAndRelaunch` with `.install`. A found
/// update is dismissed at once and fetched again on Download, so Sparkle's hourly checks keep running while
/// the pill shows it (a held reply would keep a session open and pause them).
@MainActor
final class UpdateController: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private(set) var state: DesktopUpdateState { didSet { if state != oldValue { observers.forEach { $0() } } } }
    private var observers: [() -> Void] = []
    func observe(_ block: @escaping () -> Void) { observers.append(block); block() }

    /// Set when no feed is configured (development builds): T3's disabled reason (DesktopUpdates.ts:258-273).
    let disabledReason: String?
    private var updater: SPUUpdater?
    private var startTimer: Timer?

    /// Sparkle's reply to a ready-to-install update, held until the user restarts.
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    /// A found update that Sparkle resumed already downloaded (`SPUUserUpdateStageDownloaded`).
    private var resumedReply: ((SPUUserUpdateChoice) -> Void)?
    private var retryTerminate: (() -> Void)?
    /// The action Sparkle is running for us, which decides the `errorContext` of an error.
    private var phase: DesktopUpdateState.ErrorContext?
    /// Download or install asked for while no Sparkle session held the update: the next found update gets `.install`.
    private var wantsDownload = false
    private var wantsInstall = false
    private var checkWaiters: [(DesktopUpdateState) -> Void] = []
    private var downloadWaiter: ((Bool) -> Void)?
    private var installWaiter: (() -> Void)?
    private var checkAfterSession = false
    private var appcastItems: [SUAppcastItem] = []
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    static let channelKey = "desktopUpdate.channel"
    private let defaults = UserDefaults.standard
    private let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    override init() {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        disabledReason = feed.isEmpty ? "Automatic updates are not available because no update feed is configured." : nil
        // CandyWrapper mirrors T3 Code Nightly, so it starts on the nightly track (updateChannels.ts:16-18).
        let channel = DesktopUpdateState.Channel(rawValue: UserDefaults.standard.string(forKey: Self.channelKey) ?? "") ?? .nightly
        state = DesktopUpdateState(currentVersion: currentVersion, channel: channel, enabled: feed.isEmpty == false)
        super.init()
    }

    /// The startup check runs after T3's 15 second delay (`AUTO_UPDATE_STARTUP_DELAY`, DesktopUpdates.ts:50,
    /// 705-718); Sparkle's own hourly timer replaces T3's 4 minute poll (`SUScheduledCheckInterval` 3600).
    func start() {
        guard disabledReason == nil else { return }
        startTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let updater = self.startedUpdater() else { return }
                // Starting may already have run an overdue scheduled check.
                if !updater.sessionInProgress, updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
            }
        }
    }

    private func startedUpdater() -> SPUUpdater? {
        startTimer?.invalidate()
        startTimer = nil
        if let updater { return updater }
        guard disabledReason == nil else { return nil }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try u.start()
        } catch {
            state = state.onCheckFailure(error.localizedDescription, at: Date())
            return nil
        }
        updater = u
        return u
    }

    // MARK: Bridge (ipc.ts:1236-1241)

    /// `check(reason)`: false when updates are off, as `{checked: false}`; the state after the check otherwise.
    func check() async -> (checked: Bool, state: DesktopUpdateState) {
        guard state.enabled, let updater = startedUpdater() else { return (false, state) }
        // DesktopUpdates.ts:419-428: no check while downloading. A held download stays as it is: T3's check
        // keeps `downloaded` whatever it finds (updateMachine.ts:61-143).
        if state.status == .downloading { return (false, state) }
        if installReply != nil || resumedReply != nil { return (true, state) }
        let result = await withCheckedContinuation { (c: CheckedContinuation<DesktopUpdateState, Never>) in
            checkWaiters.append { c.resume(returning: $0) }
            if state.status == .checking, updater.sessionInProgress { return } // a background check is under way
            if updater.sessionInProgress { checkAfterSession = true } else { updater.checkForUpdates() }
        }
        return (true, result)
    }

    /// `downloadUpdate()`: accepted when an update is available; completed once it is downloaded and verified.
    func download() async -> (accepted: Bool, completed: Bool) {
        guard state.enabled, state.status == .available, let updater = startedUpdater() else { return (false, false) }
        state = state.onDownloadStart()
        phase = .download
        wantsDownload = true
        expectedLength = 0
        receivedLength = 0
        let completed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            downloadWaiter = { c.resume(returning: $0) }
            if updater.sessionInProgress { checkAfterSession = true } else { updater.checkForUpdates() }
        }
        return (true, completed)
    }

    /// `installUpdate()`: quits and relaunches through Sparkle. Returns only when the install did not happen.
    func install() async -> (accepted: Bool, completed: Bool) {
        guard state.downloadedVersion != nil, let updater = startedUpdater() else { return (false, false) }
        phase = .install
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            installWaiter = { c.resume() }
            if let reply = installReply ?? resumedReply {
                installReply = nil
                resumedReply = nil
                wantsInstall = true
                reply(.install)
            } else if let retry = retryTerminate {
                retryTerminate = nil
                retry()
            } else {
                wantsInstall = true
                if updater.sessionInProgress { checkAfterSession = true } else { updater.checkForUpdates() }
            }
        }
        return (true, false)
    }

    /// `setUpdateChannel` (DesktopUpdates.ts:966-1013): store the track, start from a fresh state, check again.
    func setChannel(_ channel: DesktopUpdateState.Channel) throws -> DesktopUpdateState {
        if [.checking, .downloading].contains(state.status) || phase == .install {
            let action = state.status == .checking ? "check" : state.status == .downloading ? "download" : "install"
            throw ChannelError(message: "Cannot change the desktop update channel to \(channel.rawValue) while an update \(action) action is in progress.")
        }
        guard channel != state.channel else { return state }
        defaults.set(channel.rawValue, forKey: Self.channelKey)
        state = DesktopUpdateState(currentVersion: currentVersion, channel: channel, enabled: state.enabled)
        guard state.enabled, let updater = startedUpdater() else { return state }
        // A held download belongs to the old track; dismissing keeps it for Sparkle's install on quit.
        let held = installReply ?? resumedReply
        installReply = nil
        resumedReply = nil
        if let held { checkAfterSession = true; held(.dismiss) } else if updater.sessionInProgress { checkAfterSession = true } else { updater.checkForUpdates() }
        return state
    }

    struct ChannelError: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: SPUUpdaterDelegate

    /// Stable is Sparkle's default channel; Nightly adds the `nightly` channel (B7).
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        state.channel == .nightly ? ["nightly"] : []
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        appcastItems = appcast.items
    }

    /// Background checks tell the user driver nothing until they find something; T3's poll shows `checking`.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground, state.status != .checking, !wantsDownload, !wantsInstall {
            phase = .check
            state = state.onCheckStart(Date())
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        cycleFinished(error: error)
    }

    private func cycleFinished(error: Error?) {
        let ns = error as NSError?
        let noUpdate = ns == nil || (ns?.domain == SUSparkleErrorDomain && ns?.code == Int(SUError.noUpdateError.rawValue))
        if state.status == .checking {
            state = noUpdate ? state.onNoUpdate(at: Date()) : state.onCheckFailure(message(ns), at: Date())
            resolveChecks()
        }
        if state.status == .downloading || wantsDownload {
            wantsDownload = false
            state = state.onDownloadFailure(noUpdate ? "The update is no longer available." : message(ns))
            finishDownload(false)
        }
        if phase != .install { phase = nil }
    }

    private func message(_ error: NSError?) -> String {
        error?.localizedDescription ?? "An unexpected error occurred."
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // `SUEnableAutomaticChecks` keeps Sparkle from asking; answer as the Info.plist does if it ever does.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard !wantsDownload, !wantsInstall, state.status != .checking else { return }
        phase = .check
        state = state.onCheckStart(Date())
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state userState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            state = state.onNoUpdate(at: Date())
            return resolveChecks()
        }
        let notes = releaseNotes()
        let stage = userState.stage
        if wantsDownload || wantsInstall { checkAfterSession = false }
        if wantsDownload && stage == .notDownloaded {
            // The Download click: Sparkle downloads, verifies and extracts, then asks to install.
            wantsDownload = false
            state = state.onUpdateAvailable(version, at: Date(), releaseNotes: notes.notes, omittedReleaseCount: notes.omitted).onDownloadStart()
            phase = .download
            return reply(.install)
        }
        state = state.onUpdateAvailable(version, at: Date(), releaseNotes: notes.notes, omittedReleaseCount: notes.omitted)
        if stage == .downloaded || stage == .installing {
            // A download from an earlier session: install is one click away, as after `update-downloaded`.
            state = state.onDownloadComplete(version)
            if wantsInstall || wantsDownload {
                wantsDownload = false
                finishDownload(true)
                if wantsInstall { phase = .install; return reply(.install) }
            }
            resumedReply = reply
        } else {
            reply(.dismiss)
            if wantsDownload { wantsDownload = false; finishDownload(false) }
        }
        resolveChecks()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state = state.onNoUpdate(at: Date())
        resolveChecks()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let text = message(error as NSError)
        switch phase {
        case .download?:
            wantsDownload = false
            state = state.onDownloadFailure(text)
            finishDownload(false)
        case .install?:
            wantsInstall = false
            state = state.onInstallFailure(text)
            finishInstall()
        default:
            state = state.onCheckFailure(text, at: Date())
            resolveChecks()
        }
        phase = nil
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = .download
        if state.status != .downloading { state = state.onDownloadStart() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        let percent = min(100, Double(receivedLength) / Double(expectedLength) * 100)
        if state.shouldBroadcastProgress(percent) { state = state.onDownloadProgress(percent) }
    }

    // T3 has no extract step; the ring stays where the download left it.
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = state.availableVersion ?? state.downloadedVersion ?? ""
        state = state.onDownloadComplete(version)
        if wantsInstall {
            phase = .install
            return reply(.install)
        }
        installReply = reply
        phase = nil
        finishDownload(true)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // The quit was refused (the quit-while-working alert): the next Restart click asks again.
        if !applicationTerminated {
            retryTerminate = retryTerminatingApplication
            wantsInstall = false
            phase = nil
            finishInstall()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func showUpdateInFocus() {
        NSApp.activate()
        resolveChecks()
    }

    func dismissUpdateInstallation() {
        installReply = nil
        resumedReply = nil
        if checkAfterSession {
            checkAfterSession = false
            DispatchQueue.main.async { [weak self] in self?.updater?.checkForUpdates() }
        }
    }

    // MARK: Helpers

    private func resolveChecks() {
        guard state.status != .checking else { return }
        let waiters = checkWaiters
        checkWaiters = []
        waiters.forEach { $0(state) }
    }

    private func finishDownload(_ completed: Bool) {
        let w = downloadWaiter
        downloadWaiter = nil
        w?(completed)
    }

    private func finishInstall() {
        let w = installWaiter
        installWaiter = nil
        w?()
    }

    /// Every release newer than this build that the track can install, newest first, as electron-updater's
    /// `fullChangelog` collects them (DesktopUpdates.ts:394-398). Notes are the GitHub release bodies that
    /// scripts/release copies into each appcast item's description.
    private func releaseNotes() -> (notes: [DesktopUpdateState.ReleaseNote], omitted: Int) {
        let comparator = SUStandardVersionComparator.default
        let allowed: Set<String> = state.channel == .nightly ? ["nightly"] : []
        let newer = appcastItems
            .filter { item in item.channel.map(allowed.contains) ?? true }
            .filter { comparator.compareVersion($0.versionString, toVersion: currentBuild) == .orderedDescending }
            .sorted { comparator.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedDescending }
        return DesktopUpdateReleaseNotes.normalize(newer.map { ($0.displayVersionString, $0.itemDescription) })
    }
}
