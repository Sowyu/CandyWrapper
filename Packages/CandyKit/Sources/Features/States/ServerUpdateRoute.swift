import Foundation

/// Redesign's route out of a page a server is too old for: the server's name, and whether this app can update it
/// in place. Without that grant the button opens Environments, where each server's update lives.
public struct ServerUpdateRoute: Equatable, Sendable {
    public var environment: String
    public var canUpdate: Bool

    public init(environment: String, canUpdate: Bool) {
        self.environment = environment
        self.canUpdate = canUpdate
    }

    public var buttonTitle: String { canUpdate ? "Update \(environment)" : "Open Environments" }

    /// Names the server and the feature it lacks, and where the update is.
    public func message(for feature: String) -> String {
        canUpdate ? "The T3 Code server on \(environment) is too old for \(feature). Update it to use them here."
            : "The T3 Code server on \(environment) is too old for \(feature). Update it from Environments."
    }
}
