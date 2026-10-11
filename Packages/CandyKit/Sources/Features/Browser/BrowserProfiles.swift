import Foundation
import T3Protocol

/// browserProfile.ts:25-111. Built-ins cannot be shadowed; user profiles are persistent.
public enum BrowserProfiles {
    public static func resolved(_ settings: ClientSettings) -> [JSONValue] {
        var seen: Set<String> = ["default", "incognito"]
        var profiles: [JSONValue] = [profile("default", "Default", "persistent"), profile("incognito", "Incognito", "incognito")]
        for item in (settings["browserProfiles"].arrayValue ?? []).prefix(24) {
            guard let id = item["id"]?.stringValue, !id.isEmpty, id.count <= 64,
                  id.rangeOfCharacter(from: .controlCharacters) == nil, seen.insert(id).inserted,
                  let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            profiles.append(profile(id, String(name.prefix(48)), "persistent"))
        }
        return profiles
    }
    public static func defaultId(_ settings: ClientSettings) -> String {
        let id = settings.string("browserDefaultProfileId")
        return id != "incognito" && resolved(settings).contains { $0["id"]?.stringValue == id } ? id : "default"
    }
    public static func profile(_ id: String, _ name: String, _ kind: String = "persistent") -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "kind": .string(kind)])
    }
}
