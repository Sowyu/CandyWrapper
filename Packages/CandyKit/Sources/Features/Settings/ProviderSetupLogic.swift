import Foundation
import T3Protocol
import T3Store

/// AddProviderInstanceDialog.tsx:72-109, 315-354 and providerSetup.ts:78-156.
public enum ProviderSetupLogic {
    /// T3 apps/web/src/components/settings/MultipleAccountsNote.tsx:24-45 (3814).
    public static let multipleAccountsFAQ = "https://github.com/pingdotgg/t3code/blob/main/docs/user/faq.md#can-i-add-a-bunch-of-accounts-for-one-provider"
    public static func multipleAccountsMessage(driver: String, providers: [ServerProvider]) -> String? {
        guard let name = ["codex": "Codex", "claudeAgent": "Claude"][driver],
              providers.contains(where: { $0.driver == driver && $0.auth?["status"]?.stringValue == "authenticated" }) else { return nil }
        return "We do not recommend managing multiple \(name) accounts in CandyWrapper."
    }

    public static func instanceID(driver: String, label: String, existing: Set<String>) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = trimmed.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = trimmed.isEmpty || trimmed == ProvidersLogic.label(driver)
            ? (driver == "acpRegistry" ? "acpRegistry_custom" : driver)
            : (slug.isEmpty ? "" : driver + "_" + String(slug.prefix(48)))
        guard !base.isEmpty, existing.contains(base) else { return base }
        var suffix = 2
        while true {
            let tail = "_\(suffix)", candidate = String(base.prefix(64 - tail.count)) + tail
            if !existing.contains(candidate) { return candidate }; suffix += 1
        }
    }
    public static func validation(_ id: String, existing: Set<String>) -> String? {
        if id.isEmpty { return "Instance ID is required." }
        if id.count > 64 { return "Instance ID must be 64 characters or fewer." }
        if id.range(of: "^[a-zA-Z][a-zA-Z0-9_-]*$", options: .regularExpression) == nil {
            return "Instance ID must start with a letter and use only letters, digits, '-', or '_'."
        }
        return existing.contains(id) ? "An instance named '\(id)' already exists." : nil
    }
    public static func create(id: String, driver: String, label: String, config: [String: JSONValue], accent: String? = nil) -> JSONValue {
        var config = config
        if driver == "codex" { config["setupMode"] = .string("existing") }
        var instance: [String: JSONValue] = ["driver": .string(driver), "enabled": .bool(true)]
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { instance["displayName"] = .string(name) }
        if !config.isEmpty { instance["config"] = .object(config) }
        if let accent = ProviderEnvironmentLogic.accentColor(accent) { instance["accentColor"] = .string(accent) }
        return .object(["patch": .object([:]), "providerInstanceMutation": .object([
            "operation": .string("create"), "instanceId": .string(id), "instance": .object(instance)])])
    }
    public static func response(instance: String, state: JSONValue, response: JSONValue) -> JSONValue? {
        guard let flow = state["flowId"]?.stringValue, let interaction = state["interaction"]?["id"]?.stringValue else { return nil }
        return .object(["instanceId": .string(instance), "flowId": .string(flow), "interactionId": .string(interaction), "response": response])
    }
    /// The server offsets use JavaScript string units, including rolling output windows.
    public static func terminalDelta(output: String, offset: Int, previousEnd: Int?) -> TerminalRenderAction? {
        let end = offset
        guard let previousEnd else { return .reset(output) }
        let delta = end - previousEnd
        if delta == 0 { return nil }
        if delta > 0 && delta <= output.utf16.count {
            return .write(String(decoding: output.utf16.suffix(delta), as: UTF16.self))
        }
        return .reset(output)
    }
    public static func terminalResponses(_ data: String) -> [JSONValue] {
        // Split on scalar boundaries so a pasted non-BMP character never becomes invalid UTF-16.
        var chunks: [String] = [], chunk = "", units = 0
        for scalar in data.unicodeScalars {
            let n = scalar.value > 0xffff ? 2 : 1
            if units + n > 4096 { chunks.append(chunk); chunk = ""; units = 0 }
            chunk.unicodeScalars.append(scalar); units += n
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.map { .object(["type": .string("terminal"), "data": .string($0)]) }
    }
}
