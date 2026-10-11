import Foundation
import T3Protocol

/// MCP Apps host.ts:488-536. Names cannot escape the reader's save destination.
public struct ThreadMcpAppDownload: Sendable, Equatable {
    public let name: String
    public let bytes: Data?
    public let uri: String?
    public static let maximumBytes = 25 * 1024 * 1024
    public static func resourceBytes(_ value: JSONValue) -> Data? {
        if let text = value["text"]?.stringValue { return Data(text.utf8) }
        return value["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }
    }
    public static func read(_ contents: JSONValue?) -> [Self]? {
        guard let contents = contents?.arrayValue, !contents.isEmpty else { return nil }
        var result: [Self] = []
        for entry in contents {
            let resource: JSONValue
            let bytes: Data?, uri: String?
            switch entry["type"]?.stringValue {
            case "resource":
                guard let value = entry["resource"], let data = resourceBytes(value) else { return nil }
                resource = value; bytes = data; uri = nil
            case "resource_link":
                guard let value = entry["uri"]?.stringValue else { return nil }
                resource = entry; uri = value; bytes = nil
            default: return nil
            }
            let raw = resource["name"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? resource["uri"]?.stringValue?.split(whereSeparator: { "/?#".contains($0) }).last.map(String.init) ?? "download"
            let name = String(raw.unicodeScalars.map { scalar -> Character in
                scalar.value < 32 || "\\/:*?\"<>|".unicodeScalars.contains(scalar) ? "-" : Character(scalar)
            }.prefix(200))
            result.append(Self(name: name.isEmpty ? "download" : name, bytes: bytes, uri: uri))
        }
        return result
    }
}
