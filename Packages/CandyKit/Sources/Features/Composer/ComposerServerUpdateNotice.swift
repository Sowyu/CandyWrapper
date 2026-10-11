import Foundation

/// ComposerServerUpdateStatus.tsx:34-74 and ServerUpdateAction.tsx:33-44; stack priority from ChatView.tsx:3156.
/// The updater owns this state; the composer only presents it.
public struct ComposerServerUpdateNotice: Equatable {
    public enum Stage: String { case downloading, installing, resuming }
    public enum Status: Equatable { case running(Stage), failed(String) }
    public var serverLabel: String
    public var status: Status
    public init(serverLabel: String = "server", status: Status) { self.serverLabel = serverLabel; self.status = status }
    public var title: String {
        switch status { case .running: "Updating \(serverLabel)"; case .failed: "Could not update \(serverLabel)" }
    }
    public var detail: String {
        switch status {
        case .running(.downloading), .running(.installing): "Downloading…"
        case .running(.resuming): "Restarting…"
        case .failed(let message): message
        }
    }
    @MainActor var content: ComposerNoticeBannerView.Content {
        switch status {
        case .running: .init(variant: .neutral, icon: .download, title: title, description: "· " + detail, priority: .urgent)
        case .failed: .init(variant: .error, icon: .circleAlert, title: title, description: "· " + detail, priority: .notice)
        }
    }
}
