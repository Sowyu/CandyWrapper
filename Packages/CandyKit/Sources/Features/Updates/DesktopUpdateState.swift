import Foundation

/// T3's `DesktopUpdateState` (packages/contracts/src/ipc.ts:270-287) without the Intel-on-Apple-Silicon
/// fields: CandyWrapper ships arm64 only, so `SidebarUpdateArchitectureWarning` never shows.
public struct DesktopUpdateState: Equatable, Sendable {
    /// ipc.ts:71-80.
    public enum Status: String, Sendable { case disabled, idle, checking, upToDate = "up-to-date", available, downloading, downloaded, error }
    /// `latest` shows as "Stable" (updateChannels.ts:1-18).
    public enum Channel: String, Sendable { case latest, nightly }
    public enum ErrorContext: String, Sendable { case check, download, install }

    public struct ReleaseNote: Equatable, Sendable {
        public var version: String
        public var items: [String]
        public var totalItems: Int
        public init(version: String, items: [String], totalItems: Int) {
            self.version = version; self.items = items; self.totalItems = totalItems
        }
    }

    /// The native server restart keeps the app open while the desktop update UI is pending.
    public var isRestarting = false
    public var enabled = false
    public var status: Status = .disabled
    public var channel: Channel
    public var currentVersion: String
    public var availableVersion: String?
    public var downloadedVersion: String?
    public var releaseNotes: [ReleaseNote] = []
    public var omittedReleaseCount = 0
    public var downloadPercent: Double?
    public var checkedAt: Date?
    public var message: String?
    public var errorContext: ErrorContext?
    public var canRetry = false

    /// `createInitialDesktopUpdateState` (updateMachine.ts:18-41) and `createBaseUpdateState`
    /// (DesktopUpdates.ts:214-224): idle when enabled, else disabled.
    public init(currentVersion: String, channel: Channel, enabled: Bool) {
        self.currentVersion = currentVersion
        self.channel = channel
        self.enabled = enabled
        status = enabled ? .idle : .disabled
    }
}

// MARK: Transitions (apps/desktop/src/updates/updateMachine.ts)

public extension DesktopUpdateState {
    /// updateMachine.ts:43-59.
    func onCheckStart(_ at: Date) -> Self {
        var s = self
        let hasDownload = downloadedVersion != nil
        s.status = .checking
        s.checkedAt = at
        if !hasDownload { s.releaseNotes = []; s.omittedReleaseCount = 0 }
        s.message = nil
        s.downloadPercent = hasDownload ? 100 : nil
        s.errorContext = nil
        s.canRetry = false
        return s
    }

    /// updateMachine.ts:61-87.
    func onCheckFailure(_ message: String, at: Date) -> Self {
        var s = self
        s.checkedAt = at
        s.canRetry = true
        if downloadedVersion != nil {
            s.status = .downloaded; s.message = nil; s.downloadPercent = 100; s.errorContext = nil
        } else {
            s.status = .error; s.message = message; s.downloadPercent = nil; s.errorContext = .check
        }
        return s
    }

    /// updateMachine.ts:89-111.
    func onUpdateAvailable(_ version: String, at: Date, releaseNotes notes: [ReleaseNote] = [], omittedReleaseCount omitted: Int = 0) -> Self {
        var s = self
        let isDownloaded = downloadedVersion == version
        let preserveNotes = isDownloaded && notes.isEmpty
        s.status = isDownloaded ? .downloaded : .available
        s.availableVersion = version
        s.downloadedVersion = isDownloaded ? version : nil
        if !preserveNotes { s.releaseNotes = notes; s.omittedReleaseCount = omitted }
        s.downloadPercent = isDownloaded ? 100 : nil
        s.checkedAt = at
        s.message = nil
        s.errorContext = nil
        s.canRetry = isDownloaded
        return s
    }

    /// updateMachine.ts:113-143.
    func onNoUpdate(at: Date) -> Self {
        var s = self
        s.checkedAt = at
        s.message = nil
        s.errorContext = nil
        if let downloaded = downloadedVersion {
            s.status = .downloaded; s.availableVersion = downloaded; s.downloadPercent = 100; s.canRetry = true
        } else {
            s.status = .upToDate; s.availableVersion = nil; s.downloadedVersion = nil
            s.releaseNotes = []; s.omittedReleaseCount = 0; s.downloadPercent = nil; s.canRetry = false
        }
        return s
    }

    /// updateMachine.ts:145-156.
    func onDownloadStart() -> Self {
        var s = self
        s.status = .downloading; s.downloadPercent = 0; s.message = nil; s.errorContext = nil; s.canRetry = false
        return s
    }

    /// updateMachine.ts:158-170: back to `available` when a version is known, so the user can retry.
    func onDownloadFailure(_ message: String) -> Self {
        var s = self
        s.status = availableVersion != nil ? .available : .error
        s.message = message
        s.downloadPercent = nil
        s.errorContext = .download
        s.canRetry = availableVersion != nil
        return s
    }

    /// updateMachine.ts:172-184.
    func onDownloadProgress(_ percent: Double) -> Self {
        var s = self
        s.status = .downloading; s.downloadPercent = percent; s.message = nil; s.errorContext = nil; s.canRetry = false
        return s
    }

    /// updateMachine.ts:186-200.
    func onDownloadComplete(_ version: String) -> Self {
        var s = self
        s.status = .downloaded; s.availableVersion = version; s.downloadedVersion = version
        s.downloadPercent = 100; s.message = nil; s.errorContext = nil; s.canRetry = true
        return s
    }

    /// updateMachine.ts:202-213.
    func onInstallFailure(_ message: String) -> Self {
        var s = self
        s.status = .downloaded; s.message = message; s.errorContext = .install; s.canRetry = true
        return s
    }

    /// `shouldBroadcastDownloadProgress` (DesktopUpdates.ts:230-246): only each 10 percent step, and 100.
    func shouldBroadcastProgress(_ next: Double) -> Bool {
        guard status == .downloading, let current = downloadPercent else { return true }
        return floor(current / 10) != floor(next / 10) || next == 100
    }
}

// MARK: UI logic (apps/web/src/components/desktopUpdate.logic.ts)

public enum DesktopUpdateLogic {
    public enum ButtonAction: Sendable { case download, install, none }

    /// T3 links to pingdotgg/t3code (desktopUpdate.logic.ts:5-6); CandyWrapper's releases live here.
    public static let releaseHistoryURL = "https://github.com/Sowyu/CandyWrapper/releases"

    /// desktopUpdate.logic.ts:13-15.
    public static func downloadedVersion(_ s: DesktopUpdateState) -> String? { s.downloadedVersion ?? s.availableVersion }

    /// desktopUpdate.logic.ts:18-22.
    public static func releaseURL(_ version: String?) -> String? {
        guard let v = version?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        let encoded = v.addingPercentEncoding(withAllowedCharacters: .urlUnreservedJS) ?? v
        return "\(releaseHistoryURL)/tag/v\(encoded)"
    }

    /// desktopUpdate.logic.ts:28-48.
    public static func buttonAction(_ s: DesktopUpdateState) -> ButtonAction {
        if s.downloadedVersion != nil,
           s.status == .downloaded || (s.status == .error && (s.errorContext == nil || s.errorContext == .install)) {
            return .install
        }
        if s.status == .available { return .download }
        if s.status == .error, s.errorContext == .download, s.availableVersion != nil { return .download }
        return .none
    }

    /// desktopUpdate.logic.ts:54-56.
    public static func isButtonDisabled(_ s: DesktopUpdateState?) -> Bool { s?.status == .downloading || s?.isRestarting == true }

    /// desktopUpdate.logic.ts:73-98.
    public static func buttonTooltip(_ s: DesktopUpdateState) -> String {
        if s.isRestarting { return "Restarting…" }
        switch s.status {
        case .available: return "Update \(s.availableVersion ?? "available") ready to download"
        case .downloading:
            let progress = s.downloadPercent.map { " (\(Int(floor($0)))%)" } ?? ""
            return "Downloading update\(progress)"
        case .downloaded: return "Update \(s.downloadedVersion ?? s.availableVersion ?? "ready") downloaded. Click to restart and install."
        case .error:
            if s.errorContext == .download, let v = s.availableVersion { return "Download failed for \(v). Click to retry." }
            if s.errorContext == .install, let v = s.downloadedVersion { return "Install failed for \(v). Click to retry." }
            if let v = s.downloadedVersion { return "Update \(v) downloaded. Click to restart and install." }
            return s.message ?? "Update failed"
        default: return "Up to date"
        }
    }

    /// desktopUpdate.logic.ts:100-105, with this app's name in place of T3 Code.
    public static func installConfirmationMessage(_ s: DesktopUpdateState, appName: String = "CandyWrapper") -> String {
        let version = s.downloadedVersion ?? s.availableVersion
        return "Install update\(version.map { " \($0)" } ?? "") and restart \(appName)?\n\nAny running tasks will be interrupted. Make sure you're ready before continuing."
    }

    /// `getDesktopUpdateActionError` (desktopUpdate.logic.ts:107-112): the message of an accepted action that
    /// did not complete.
    public static func actionError(accepted: Bool, completed: Bool, state: DesktopUpdateState) -> String? {
        guard accepted, !completed, let m = state.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
        return m
    }

    /// desktopUpdate.logic.ts:118-123.
    public static func canCheck(_ s: DesktopUpdateState?) -> Bool {
        guard let s, s.enabled else { return false }
        return !s.isRestarting && s.status != .checking && s.status != .downloading && s.status != .disabled
    }

    /// `shouldUseSidebarUpdateReleaseNotesPopover` (SidebarUpdatePill.tsx:39-44).
    public static func showsReleaseNotesPopover(showUpdateDetails: Bool, _ s: DesktopUpdateState?) -> Bool {
        showUpdateDetails && s?.channel == .nightly && !(s?.releaseNotes.isEmpty ?? true)
    }

    /// The Settings Version row (SettingsPanels.tsx:399-426): button label, description, disabled.
    public static func settingsButton(_ s: DesktopUpdateState?) -> (label: String, description: String, disabled: Bool) {
        if s?.isRestarting == true { return ("Restarting…", "Restarting…", true) }
        let action = s.map(buttonAction) ?? .none
        let label: String = switch action {
        case .download: "Download"
        case .install: "Install"
        case .none:
            switch s?.status {
            case .checking: "Checking…"
            case .downloading: "Downloading…"
            case .upToDate: "Up to Date"
            default: "Check for Updates"
            }
        }
        let description = action == .none ? "Current version of the application." : "Update available."
        let disabled = action == .none ? !canCheck(s) : isButtonDisabled(s)
        return (label, description, disabled)
    }
}

extension CharacterSet {
    /// What `encodeURIComponent` leaves alone.
    static let urlUnreservedJS = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}
