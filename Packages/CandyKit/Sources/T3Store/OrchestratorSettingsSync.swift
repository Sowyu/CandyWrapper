import Foundation
import T3Protocol

/// The Orchestrator's settings shared by every CandyWrapper client, the Mac app and the Android app, through one disabled
/// scheduled task on the Orchestrator's machine whose prompt holds them as JSON (docs/orchestrator.md, "Settings on
/// every device"). T3 has no free-form store, and both apps already read and write that machine's scheduled tasks.
///
/// Each setting carries when it was last set and by which device, and the newer one wins, setting by setting. Merging
/// is the same on every side, so two devices that edit at once end up with the same settings once each has read the
/// other's write. Device-only state (the toggle, each machine's thread and brief digest, relay bookkeeping, the draft
/// and window layout) stays local.
public enum OrchestratorSettingsSync {
    /// How a client finds the task: by this exact title, with the document as its prompt.
    public static let title = "CandyWrapper Orchestrator settings"
    public static let format = "candywrapper.orchestrator-settings"
    public static let version = 1

    /// Every shared setting, by its key in the document. A value is the setting's JSON as `OrchestratorConfig` encodes it.
    public static let keys = ["name", "prompt", "environmentId", "homeProjectId", "crewLimit", "models", "closedCheckMinutes",
                              "askFirstMinutes", "handsOff", "botShape", "botColor"] + OrchestratorNotebook.names.map { "notebook." + $0 }

    /// When a setting was last set and by which device. The later one wins; on a tie the larger device id does.
    public struct Stamp: Codable, Hashable, Sendable {
        /// Epoch milliseconds on the writing device's clock.
        public var at: Int64
        public var by: String
        public init(at: Int64, by: String) { self.at = at; self.by = by }
        public func beats(_ other: Stamp) -> Bool { at != other.at ? at > other.at : by > other.by }
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var value: JSONValue
        public var at: Int64
        public var by: String
        public init(value: JSONValue, stamp: Stamp) { self.value = value; at = stamp.at; by = stamp.by }
        public var stamp: Stamp { Stamp(at: at, by: by) }
    }

    /// The task's prompt. Keys this version doesn't know are kept as they are, so a newer client's settings survive.
    public struct Document: Codable, Hashable, Sendable {
        public var format = OrchestratorSettingsSync.format
        public var version = OrchestratorSettingsSync.version
        public var settings: [String: Entry] = [:]
        public init(settings: [String: Entry] = [:]) { self.settings = settings }

        /// Nil for a prompt that isn't a settings document.
        public static func parse(_ prompt: String) -> Document? {
            guard let doc = try? JSONDecoder().decode(Document.self, from: Data(prompt.utf8)), doc.format == OrchestratorSettingsSync.format else { return nil }
            return doc
        }

        public var prompt: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    /// Every shared setting's value. `machine` stands in for a nil `environmentId` ("the primary machine"), which means
    /// a different machine on each device, so the document always names the machine.
    public static func values(_ config: OrchestratorConfig, machine: String? = nil) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(config), case .object(let all)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        var out: [String: JSONValue] = [:]
        for key in keys {
            if key.hasPrefix("notebook.") {
                out[key] = .string(config.notebook[String(key.dropFirst("notebook.".count))])
            } else if key == "handsOff", case .array(let ids)? = all[key] {
                // A set encodes in any order.
                out[key] = .array(ids.compactMap(\.stringValue).sorted().map { .string($0) })
            } else if key == "environmentId", config.environmentId == nil {
                out[key] = machine.map { .string($0) } ?? .null
            } else {
                out[key] = all[key] ?? .null
            }
        }
        return out
    }

    /// The config with one setting replaced; unchanged when the value has the wrong type or is out of range.
    static func applying(_ key: String, _ value: JSONValue, to config: OrchestratorConfig) -> OrchestratorConfig {
        if key.hasPrefix("notebook.") {
            guard let text = value.stringValue else { return config }
            var next = config
            next.notebook[String(key.dropFirst("notebook.".count))] = text
            return next
        }
        // OrchestratorConfig's decoder rejects a value of the wrong type.
        guard keys.contains(key), let data = try? JSONEncoder().encode(config),
              case .object(var all)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return config }
        all[key] = value
        guard let encoded = try? JSONEncoder().encode(JSONValue.object(all)),
              let next = try? JSONDecoder().decode(OrchestratorConfig.self, from: encoded) else { return config }
        // A server value is another client's input: keep counts the controls and the scheduler accept.
        guard next.crewLimit >= 1, next.askFirstMinutes >= 0, (next.closedCheckMinutes ?? 1) >= 1 else { return config }
        return next
    }

    /// Stamps for what changed between two configs, as a local edit at `now`.
    public static func stamps(old: OrchestratorConfig, new: OrchestratorConfig, into stamps: [String: Stamp], now: Int64, device: String) -> [String: Stamp] {
        let before = values(old), after = values(new)
        var out = stamps
        for key in keys where before[key] != after[key] { out[key] = Stamp(at: now, by: device) }
        return out
    }

    /// The first sync on a device: every setting you changed from its default counts as set now, so it goes up and
    /// nothing you set is lost. Settings still at their default stay unstamped and take the document's value.
    public static func migrationStamps(_ config: OrchestratorConfig, now: Int64, device: String) -> [String: Stamp] {
        stamps(old: OrchestratorConfig.withEnabled(config.enabled), new: config, into: [:], now: now, device: device)
    }

    public struct Merge: Equatable, Sendable {
        public var config: OrchestratorConfig
        public var stamps: [String: Stamp]
        /// What to write back; nil when the document already has everything.
        public var write: Document?
    }

    /// Merges the documents found on a machine with this device's settings: per setting, the newer stamp wins.
    /// `machine` is the machine the documents live on, which a null `environmentId` in them means. `home` is the
    /// Orchestrator's machine on this device, which its nil `environmentId` means; the same machine unless you just moved it.
    public static func merge(config: OrchestratorConfig, stamps: [String: Stamp], documents: [Document], machine: String,
                             home: String? = nil) -> Merge {
        var remote: [String: Entry] = [:]
        for doc in documents {
            for (key, entry) in doc.settings where remote[key].map({ entry.stamp.beats($0.stamp) }) ?? true { remote[key] = entry }
        }
        var next = config
        var nextStamps = stamps
        var out = remote
        let mine = values(config, machine: home ?? machine)
        for key in keys {
            let local = stamps[key]
            if let entry = remote[key], local.map({ entry.stamp.beats($0) }) ?? true {
                let value = key == "environmentId" && entry.value == .null ? JSONValue.string(machine) : entry.value
                next = applying(key, value, to: next)
                nextStamps[key] = entry.stamp
            } else if let local, remote[key].map({ local.beats($0.stamp) }) ?? true {
                out[key] = Entry(value: mine[key] ?? .null, stamp: local)
            }
        }
        // Several documents (two devices made one at once) become one.
        let current = documents.count == 1 && documents[0].settings == out
        return Merge(config: next, stamps: nextStamps, write: current || (out.isEmpty && documents.isEmpty) ? nil : Document(settings: out))
    }
}

extension OrchestratorConfig {
    /// The defaults with only the toggle carried over, to tell which settings you changed.
    static func withEnabled(_ enabled: Bool) -> OrchestratorConfig {
        var c = OrchestratorConfig()
        c.enabled = enabled
        return c
    }
}
