import Foundation

/// `ProjectCloneSnapshot` (contracts projectClone.ts:34-50): the live progress of a repository clone
/// that backs a newly added project. `subscribeProjectClones` sends every tracked clone first, then
/// the whole list after each change. Servers advertise it with the `projectCloneTracking` capability.
public struct ProjectCloneSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable { case running, done, failed, cancelled }

    public var projectId: String
    public var remoteUrl: String
    public var destinationPath: String
    /// `repository.nameWithOwner` when the server looked the repository up.
    public var nameWithOwner: String?
    public var phase: Phase
    /// `connecting`, `counting`, `receiving`, `resolving` or `checkout`.
    public var stage: String
    public var percent: Int?
    public var detail: String?
    public var error: String?

    public init(projectId: String, remoteUrl: String, destinationPath: String, nameWithOwner: String? = nil, phase: Phase,
                stage: String, percent: Int? = nil, detail: String? = nil, error: String? = nil) {
        self.projectId = projectId; self.remoteUrl = remoteUrl; self.destinationPath = destinationPath
        self.nameWithOwner = nameWithOwner; self.phase = phase; self.stage = stage; self.percent = percent
        self.detail = detail; self.error = error
    }

    public init?(json: JSONValue) {
        guard let projectId = json["projectId"]?.stringValue, let destination = json["destinationPath"]?.stringValue,
              let phase = json["phase"]?.stringValue.flatMap(Phase.init(rawValue:)) else { return nil }
        let percent: Int? = if case .number(let n)? = json["percent"], n.isFinite { Int(min(max(n, 0), 100)) } else { nil }
        self.init(projectId: projectId, remoteUrl: json["remoteUrl"]?.stringValue ?? "", destinationPath: destination,
                  nameWithOwner: json["repository"]?["nameWithOwner"]?.stringValue, phase: phase,
                  stage: json["stage"]?.stringValue ?? "connecting", percent: percent,
                  detail: json["detail"]?.stringValue, error: json["error"]?.stringValue)
    }

    /// `ProjectCloneListEvent`: the list, skipping entries this build cannot read.
    public static func list(_ json: JSONValue) -> [ProjectCloneSnapshot] {
        guard case .array(let items) = json else { return [] }
        return items.compactMap(ProjectCloneSnapshot.init(json:))
    }

    /// `projectCloneDisplayName`: `owner/repo`, else the last folder of the destination.
    public var displayName: String {
        if let nameWithOwner { return nameWithOwner }
        return destinationPath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? destinationPath
    }

    /// `projectCloneProgressSummary`: "Receiving objects · 45% · 12.3 MiB | 5.0 MiB/s".
    public var progressSummary: String {
        let label = switch stage {
        case "counting": "Counting objects"
        case "receiving": "Receiving objects"
        case "resolving": "Resolving deltas"
        case "checkout": "Checking out files"
        default: "Connecting"
        }
        var parts = [label]
        if let percent { parts.append("\(percent)%") }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    /// The toast's `renderKey`: an identical snapshot does not touch the toast.
    public var renderKey: String { "\(phase.rawValue):\(stage):\(percent.map(String.init) ?? ""):\(detail ?? ""):\(error ?? "")" }
}
