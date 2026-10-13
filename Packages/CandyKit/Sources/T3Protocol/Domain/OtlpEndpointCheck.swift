import Foundation

/// `OtlpEndpointCheckResult` (contracts server.ts:370-379, 2994): what the server saw when it sent an empty
/// export to an endpoint. `server.checkOtlpEndpoint {signal, url}` answers it. Servers advertise the call
/// with the `otlpEndpointCheck` capability.
public enum OtlpEndpointCheckResult: Sendable, Equatable {
    case accepted(latencyMs: Double)
    case rejected(status: Int)
    case unreachable(timedOut: Bool)

    public init?(json: JSONValue) {
        switch json["_tag"]?.stringValue {
        case "Accepted": self = .accepted(latencyMs: json["latencyMs"]?.doubleValue ?? 0)
        case "Rejected": self = .rejected(status: json["status"]?.intValue ?? 0)
        case "Unreachable": self = .unreachable(timedOut: json["timedOut"]?.boolValue ?? false)
        default: return nil
        }
    }

    /// `OtlpEndpointCheckInput` (server.ts:363-367). `signal` is `traces`, `metrics` or `logs`.
    public static func input(signal: String, url: String) -> JSONValue { .object(["signal": .string(signal), "url": .string(url)]) }

    /// `isHttpUrl`: the server checks only http and https endpoints.
    public static func isHttpURL(_ url: String) -> Bool {
        url.range(of: #"^https?://."#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The status beside an endpoint field (`endpointStatus`, TelemetryExportSettings.tsx:29-42).
    public enum Tone: Sendable, Equatable { case off, checking, success, failure }
    public struct Status: Sendable, Equatable {
        public var label: String
        public var tone: Tone
    }

    /// `check` is the latest check of this field: the URL it checked and its result, nil while it runs.
    public static func status(url: String, check: (url: String, result: OtlpEndpointCheckResult?)?) -> Status {
        if url.isEmpty { return Status(label: "Off", tone: .off) }
        guard let check, check.url == url else { return Status(label: "Not checked", tone: .off) }
        switch check.result {
        case nil: return Status(label: "Checking…", tone: .checking)
        case .accepted(let ms): return Status(label: "Connected · \(Int(ms.rounded())) ms", tone: .success)
        case .rejected(let status): return Status(label: "Rejected · HTTP \(status)", tone: .failure)
        case .unreachable(let timedOut): return Status(label: timedOut ? "Timed out" : "Unreachable", tone: .failure)
        }
    }
}
