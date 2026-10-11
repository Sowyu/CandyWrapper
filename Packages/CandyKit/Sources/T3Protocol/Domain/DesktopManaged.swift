import Foundation

/// contracts/relayClient.ts:3-20. The environment server owns installation and activation.
public struct RelayClientInstallStatus: Codable, Equatable, Sendable {
    /// `available`, `missing` or `unsupported`.
    public var status: String
    public var version: String
    public var platform: String?
    public var arch: String?
    public init(status: String, version: String, platform: String? = nil, arch: String? = nil) {
        self.status = status; self.version = version; self.platform = platform; self.arch = arch
    }
    /// linkEnvironment.ts:61-64,99-101.
    public var unsupportedMessage: String {
        "T3 Code cannot install the relay client automatically on \(platform ?? "unknown")-\(arch ?? "unknown")."
    }
}

/// contracts/relayClient.ts:23-31 with the labels of RelayClientInstallDialog.tsx:21-32.
public enum RelayClientInstallStage: String, Codable, CaseIterable, Sendable {
    case checking, waitingForLock = "waiting_for_lock", downloading, verifying, installing, validating, activating
    public var label: String {
        switch self {
        case .checking: "Checking current installation"
        case .waitingForLock: "Waiting for installer"
        case .downloading: "Downloading relay client"
        case .verifying: "Verifying download"
        case .installing: "Installing relay client"
        case .validating: "Validating executable"
        case .activating: "Activating installation"
        }
    }
    /// 1 to 7, as the dialog's "n of 7".
    public var step: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

/// contracts/relayClient.ts:35-45: `progress` with a stage, or `complete` with the final status.
public struct RelayClientInstallEvent: Decodable, Sendable {
    public let type: String
    public let stage: RelayClientInstallStage?
    public let status: RelayClientInstallStatus?
}
