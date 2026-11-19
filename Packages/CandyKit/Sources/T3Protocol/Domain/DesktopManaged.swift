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
public struct RelayClientInstallStage: OpenStringEnum, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let checking: Self = "checking"
    public static let waitingForLock: Self = "waiting_for_lock"
    public static let downloading: Self = "downloading"
    public static let verifying: Self = "verifying"
    public static let installing: Self = "installing"
    public static let validating: Self = "validating"
    public static let activating: Self = "activating"
    public static let allCases: [Self] = [.checking, .waitingForLock, .downloading, .verifying, .installing, .validating, .activating]

    public var label: String {
        switch self {
        case .checking: "Checking current installation"
        case .waitingForLock: "Waiting for installer"
        case .downloading: "Downloading relay client"
        case .verifying: "Verifying download"
        case .installing: "Installing relay client"
        case .validating: "Validating executable"
        case .activating: "Activating installation"
        default: "Installing relay client"
        }
    }
    /// 1 to 7, as the dialog's "n of 7". A stage this build doesn't know shows as installing.
    public var step: Int { (Self.allCases.firstIndex(of: self) ?? Self.allCases.firstIndex(of: .installing)!) + 1 }
}

/// contracts/relayClient.ts:35-45: `progress` with a stage, or `complete` with the final status.
public struct RelayClientInstallEvent: Decodable, Sendable {
    public let type: String
    public let stage: RelayClientInstallStage?
    public let status: RelayClientInstallStatus?
}
