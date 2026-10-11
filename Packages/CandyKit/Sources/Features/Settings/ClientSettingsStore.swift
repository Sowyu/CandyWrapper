import Foundation
import T3Protocol

/// This device's client settings (`ClientSettingsSchema`), kept in the app's defaults as one JSON
/// document like T3 desktop keeps its client-settings file. Views read `current`; a change notifies
/// every observer once.
@MainActor
public final class ClientSettingsStore {
    public static let shared = ClientSettingsStore(ephemeral: CommandLine.arguments.contains("--fake-t3-connect"))

    static let defaultsKey = "clientSettings.v1"
    private let defaults: UserDefaults
    private let ephemeral: Bool
    public private(set) var current: ClientSettings
    private var observers: [(id: Int, block: @MainActor (Set<String>) -> Void)] = []
    private var nextId = 0

    public init(defaults: UserDefaults = .standard, ephemeral: Bool = false) {
        self.defaults = defaults
        self.ephemeral = ephemeral
        let json = ephemeral ? nil : defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONValue(parsing: $0) }
        current = ClientSettings(decoding: json)
    }

    /// Applies a patch, saves, and tells observers which keys changed.
    public func update(_ patch: [String: JSONValue]) {
        let changed = current.apply(patch)
        guard !changed.isEmpty else { return }
        if !ephemeral, let data = try? JSONEncoder().encode(current.encoded) { defaults.set(data, forKey: Self.defaultsKey) }
        for o in observers { o.block(changed) }
    }

    /// Calls `block` with the changed keys after every update. Returns a token for `removeObserver`.
    @discardableResult
    public func observe(_ block: @escaping @MainActor (Set<String>) -> Void) -> Int {
        nextId += 1
        observers.append((nextId, block))
        return nextId
    }

    public func removeObserver(_ id: Int) { observers.removeAll { $0.id == id } }
}
