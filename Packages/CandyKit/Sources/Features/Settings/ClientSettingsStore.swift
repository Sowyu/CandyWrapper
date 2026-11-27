import Foundation
import T3Protocol

/// This device's client settings (`ClientSettingsSchema`), kept in the app's defaults as one JSON
/// document like T3 desktop keeps its client-settings file. Views read `current`; a change notifies
/// every observer once.
@MainActor
public final class ClientSettingsStore {
    /// In-memory for test apps (`--fake-t3-connect`) and test runners. `swift test` and `xctest` keep one defaults
    /// domain across runs and checkouts, so tests would otherwise read whatever an earlier run or the Mac saved.
    public static let shared = ClientSettingsStore(ephemeral: CommandLine.arguments.contains("--fake-t3-connect")
                                                   || ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName))

    static let defaultsKey = "clientSettings.v1"
    private let defaults: UserDefaults
    private let ephemeral: Bool
    public private(set) var readFailed = false
    public private(set) var current: ClientSettings
    private var observers: [(id: Int, block: @MainActor (Set<String>) -> Void)] = []
    private var nextId = 0

    public init(defaults: UserDefaults = .standard, ephemeral: Bool = false) {
        self.defaults = defaults
        self.ephemeral = ephemeral
        var json = ephemeral ? nil : defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONValue(parsing: $0) }
        #if DEBUG
        // `CANDY_CLIENT_SETTINGS='{"redesignGradientAnimate":false}'` seeds a test app's in-memory settings, for snapshots.
        if ephemeral, let seed = ProcessInfo.processInfo.environment["CANDY_CLIENT_SETTINGS"].flatMap({ try? JSONValue(parsing: Data($0.utf8)) }) {
            json = seed
        }
        #endif
        if !ephemeral, let moved = Self.moveStackedPickerDefault(json, defaults: defaults) {
            json = moved
            if let data = try? JSONEncoder().encode(ClientSettings(decoding: moved).encoded) { defaults.set(data, forKey: Self.defaultsKey) }
        }
        current = ClientSettings(decoding: json)
        readFailed = !ephemeral && defaults.data(forKey: Self.defaultsKey) != nil && json?.objectValue == nil
    }

    static let stackedPickerMoveKey = "clientSettings.movedStackedPickerDefault"
    /// `redesignStackedPicker` defaulted to true until 2026-11-21 and now defaults to false. Every save writes every key,
    /// so a stored true can't be told from the old default and moves to the new one, once. A stored false differed from
    /// the old default, so someone chose it, and it stays. Nil when nothing moves.
    static func moveStackedPickerDefault(_ json: JSONValue?, defaults: UserDefaults) -> JSONValue? {
        guard !defaults.bool(forKey: stackedPickerMoveKey) else { return nil }
        defaults.set(true, forKey: stackedPickerMoveKey)
        guard case .object(var o)? = json, o["redesignStackedPicker"] == .bool(true) else { return nil }
        o.removeValue(forKey: "redesignStackedPicker")
        return .object(o)
    }

    public func retryRead() {
        let data = ephemeral ? nil : defaults.data(forKey: Self.defaultsKey)
        let json = data.flatMap { try? JSONValue(parsing: $0) }
        readFailed = data != nil && json?.objectValue == nil
        if !readFailed { current = ClientSettings(decoding: json) }
        for o in observers { o.block(["hydration"]) }
    }

    /// Applies a patch, saves, and tells observers which keys changed.
    public func update(_ patch: [String: JSONValue]) {
        guard !readFailed else { return }
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
