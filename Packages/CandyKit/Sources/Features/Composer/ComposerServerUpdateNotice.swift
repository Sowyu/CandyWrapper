import Foundation
import T3Protocol

/// The composer's server version item (ChatView.tsx:3143-3222, ComposerServerUpdateStatus.tsx:10-65,
/// ServerUpdateAction.tsx:33-44): "Server update available" with its versions as tooltip, then
/// "Updating server" and "Downloading…" under a spinner, or "Could not update server" and the reason.
/// The app's updater owns the state; the composer only presents it.
public struct ComposerServerUpdateNotice: Equatable {
    public enum Status: Equatable {
        /// `serverVersion → clientVersion` in the title's tooltip.
        case available(serverVersion: String, clientVersion: String)
        case running(ServerUpdateStage)
        case failed(String)
    }
    public var serverLabel: String
    public var status: Status
    /// `serverUpdateGuidance`, shown while idle for a server that can't take "Update" from here.
    public var guidance: String?
    /// The update button's label ("Update", "Retry", or a copy command), nil for none.
    public var action: String?
    /// "Dismiss update notice". Never while an update runs.
    public var dismissible: Bool
    /// The update needs `environment:maintain`; a copy command never does.
    public var actionEnabled: Bool
    /// The button's `title`, like "Disconnect server"'s.
    public var actionTooltip: String?

    public init(serverLabel: String = "server", status: Status, guidance: String? = nil, action: String? = nil, actionEnabled: Bool = true,
                actionTooltip: String? = nil, dismissible: Bool? = nil) {
        self.serverLabel = serverLabel; self.status = status; self.guidance = guidance; self.action = action; self.actionEnabled = actionEnabled
        self.actionTooltip = actionTooltip
        if case .running = status { self.dismissible = false } else { self.dismissible = dismissible ?? true }
    }

    public var title: String {
        switch status {
        case .available: "Server update available"
        case .running: "Updating \(serverLabel)"
        case .failed: "Could not update \(serverLabel)"
        }
    }
    public var detail: String {
        switch status {
        case .available(let server, let client): "\(serverLabel) \(server) → \(client)"
        case .running(let stage): ServerUpdateCopy.stageLabel(stage)
        case .failed(let message): message
        }
    }
    @MainActor var content: ComposerNoticeBannerView.Content {
        let dismiss = dismissible ? "Dismiss update notice" : nil
        switch status {
        case .available:
            return .init(variant: .neutral, icon: .download, title: title, description: guidance, actions: action.map { [$0] } ?? [],
                         dismissLabel: dismiss, priority: .notice, titleTooltip: detail)
        case .running:
            // Update progress outranks passive notices. Its only action is "Disconnect server".
            // The stage or the failure is the plain description (ChatView.tsx:2325-2332, a261a71817).
            return .init(variant: .neutral, icon: .download, title: title, description: detail, actions: action.map { [$0] } ?? [],
                         priority: .urgent, spinner: true, actionTooltip: actionTooltip)
        case .failed:
            return .init(variant: .error, icon: .circleAlert, title: title, description: detail, actions: action.map { [$0] } ?? [],
                         dismissLabel: dismiss, priority: .notice, iconIsError: true)
        }
    }
}
